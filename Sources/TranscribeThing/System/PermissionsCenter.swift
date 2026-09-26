import AppKit
import ApplicationServices
import AVFoundation
import Observation
import os
import Security

enum PermissionState: Equatable, Sendable { case granted, denied, notDetermined }

enum FnKeyUsage: Equatable, Sendable {
    case doNothing
    /// "Emoji & Symbols", "Input Sources", "Dictation"
    case other(String)
    case unknown
}

/// Microphone + Accessibility (which also covers the active event tap and posting ⌘V).
/// Input Monitoring isn't needed for an active tap; `HotkeyMonitor` asks for it only as a fallback.
///
/// Every probe runs off the main thread: `AVCaptureDevice.authorizationStatus` costs about 25 ms per call.
@MainActor @Observable
final class PermissionsCenter {
    private(set) var microphone: PermissionState = .notDetermined
    private(set) var accessibility: PermissionState = .notDetermined
    private(set) var fnKeyUsage: FnKeyUsage = .unknown
    /// Listed in System Settings but `AXIsProcessTrusted()` is false: an ad-hoc rebuild changed the cdhash
    /// that TCC pinned. Fix: remove transcribe-thing from the Accessibility list and add it again.
    private(set) var accessibilityLikelyStale = false
    /// The microphone is blocked by a profile (MDM or Screen Time): no prompt, no settings toggle.
    private(set) var microphoneRestricted = false
    /// At least one refresh has landed.
    private(set) var hasLoaded = false
    @ObservationIgnored var onAccessibilityGranted: (() -> Void)?

    var allRequiredGranted: Bool { microphone == .granted && accessibility == .granted }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isPreview: Bool
    @ObservationIgnored private var refreshInFlight = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var pollTimer: Timer?
    /// Why the timer runs; the fastest reason wins. A permissions UI on screen (`startPolling`):
    @ObservationIgnored private var uiPollInterval: TimeInterval?
    /// The app is waiting for a grant in the background (`pollInBackground`), e.g. the event tap is down:
    @ObservationIgnored private var pollsInBackground = false
    /// The user was just sent to grant these (`requestAccessibility`, or their pane opened from a card or a
    /// toast): fast until that permission is granted or the date passes. transcribe-thing usually stays in the
    /// background meanwhile, so no activation tells it the grant happened.
    @ObservationIgnored private var grantWatch: [SettingsPane: Date] = [:]
    @ObservationIgnored private var observers: [AnyObject] = []

    private static let lastTrustedCDHashKey = "tt.permissions.lastTrustedCDHash"
    private static let requestedAccessibilityKey = "tt.permissions.requestedAccessibility"
    /// While a permissions UI is on screen or the user just asked for access: grants show up at once.
    nonisolated static let fastPollInterval: TimeInterval = 0.5
    /// Background waiting. Returning to transcribe-thing and the Accessibility-list notification refresh at once
    /// anyway, and the event tap retries every 3 s by itself; this only catches what they miss.
    nonisolated static let backgroundPollInterval: TimeInterval = 3
    /// When everything required is granted, polling relaxes to this (revocation and Globe-key changes).
    nonisolated static let relaxedPollInterval: TimeInterval = 5
    /// How long a grant the user was sent to give is watched for at the fast pace.
    nonisolated static let grantWatchDuration: TimeInterval = 180

    init() {
        self.defaults = .standard
        self.isPreview = false
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.isPreview = false
    }

    private init(preview: Void) {
        self.defaults = UserDefaults(suiteName: "tt.preview.permissions") ?? .standard
        self.isPreview = true
    }

    static func preview(mic: PermissionState, ax: PermissionState) -> PermissionsCenter {
        let center = PermissionsCenter(preview: ())
        center.microphone = mic
        center.accessibility = ax
        center.fnKeyUsage = .doNothing
        center.hasLoaded = true
        return center
    }

    /// Snapshots/tests: every published field.
    static func preview(mic: PermissionState, ax: PermissionState, fnKeyUsage: FnKeyUsage,
                        accessibilityLikelyStale: Bool = false) -> PermissionsCenter {
        let center = preview(mic: mic, ax: ax)
        center.fnKeyUsage = fnKeyUsage
        center.accessibilityLikelyStale = accessibilityLikelyStale
        return center
    }

    // MARK: Refresh

    func refresh() {
        guard !isPreview else { return }
        installObserversIfNeeded()
        guard !refreshInFlight else {
            refreshAgain = true
            return
        }
        refreshInFlight = true
        Task { [weak self] in
            let probe = await Task.detached(priority: .utility) { PermissionProbe.capture() }.value
            self?.apply(probe)
        }
    }

    private func apply(_ probe: PermissionProbe) {
        refreshInFlight = false
        let wasAccessibility = accessibility
        let firstLoad = !hasLoaded

        if microphone != probe.microphone { microphone = probe.microphone }
        if microphoneRestricted != probe.microphoneRestricted { microphoneRestricted = probe.microphoneRestricted }
        if fnKeyUsage != probe.fnKeyUsage { fnKeyUsage = probe.fnKeyUsage }

        let lastTrusted = defaults.string(forKey: Self.lastTrustedCDHashKey)
        let newAccessibility: PermissionState
        var stale = false
        if probe.accessibilityTrusted {
            if let hash = probe.cdhash, hash != lastTrusted { defaults.set(hash, forKey: Self.lastTrustedCDHashKey) }
            newAccessibility = .granted
        } else {
            stale = lastTrusted != nil && probe.cdhash != nil && lastTrusted != probe.cdhash
            let everAsked = defaults.bool(forKey: Self.requestedAccessibilityKey) || lastTrusted != nil
            newAccessibility = everAsked ? .denied : .notDetermined
        }
        if accessibility != newAccessibility { accessibility = newAccessibility }
        if accessibilityLikelyStale != stale { accessibilityLikelyStale = stale }
        if !hasLoaded { hasLoaded = true }

        if !firstLoad, wasAccessibility != .granted, newAccessibility == .granted {
            Log.app.info("Accessibility granted")
            onAccessibilityGranted?()
        }
        adjustPolling()
        if refreshAgain {
            refreshAgain = false
            refresh()
        }
    }

    // MARK: Polling

    /// Fast polling while a permissions UI is on screen (relaxed to every 5 s once everything is granted).
    /// Call `stopPolling()` when that UI goes away.
    func startPolling(interval: TimeInterval = PermissionsCenter.fastPollInterval) {
        guard !isPreview else { return }
        uiPollInterval = max(0.2, interval)
        adjustPolling()
        refresh()
    }

    /// The permissions UI went away. Background polling, if requested, carries on at its own pace.
    func stopPolling() {
        uiPollInterval = nil
        grantWatch.removeAll()
        adjustPolling()
    }

    /// Slow polling for as long as the app runs, while it can't work without a grant (event tap down).
    func pollInBackground() {
        guard !isPreview else { return }
        pollsInBackground = true
        adjustPolling()
        refresh()
    }

    var isPolling: Bool { pollTimer != nil }

    /// nil = no polling. Pure so the policy is testable.
    nonisolated static func pollInterval(ui: TimeInterval?, background: Bool, awaitingGrant: Bool,
                                         allGranted: Bool) -> TimeInterval? {
        var wanted: TimeInterval?
        if let ui { wanted = ui }
        if awaitingGrant { wanted = min(wanted ?? fastPollInterval, fastPollInterval) }
        if background { wanted = min(wanted ?? backgroundPollInterval, backgroundPollInterval) }
        guard let wanted else { return nil }
        return allGranted ? max(wanted, relaxedPollInterval) : wanted
    }

    private var effectivePollInterval: TimeInterval? {
        let now = Date()
        grantWatch = grantWatch.filter { pane, until in until > now && state(of: pane) != .granted }
        return Self.pollInterval(ui: uiPollInterval, background: pollsInBackground,
                                 awaitingGrant: !grantWatch.isEmpty, allGranted: allRequiredGranted)
    }

    private func state(of pane: SettingsPane) -> PermissionState? {
        switch pane {
        case .microphone: microphone
        case .accessibility: accessibility
        case .inputMonitoring, .keyboard, .sound, .storage: nil
        }
    }

    /// Polls fast until `pane`'s permission is granted (3 min at most).
    private func watchForGrant(of pane: SettingsPane) {
        guard state(of: pane) != nil else { return }
        grantWatch[pane] = Date().addingTimeInterval(Self.grantWatchDuration)
        adjustPolling()
    }

    private func schedulePollTimer(interval: TimeInterval) {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollTick() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func pollTick() {
        adjustPolling()
        guard pollTimer != nil else { return }
        refresh()
    }

    private func adjustPolling() {
        guard let interval = effectivePollInterval else {
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }
        if let timer = pollTimer, abs(timer.timeInterval - interval) <= 0.01 { return }
        schedulePollTimer(interval: interval)
    }

    /// Returning from System Settings is the usual moment a grant happens; the AX list change posts an
    /// (undocumented) distributed notification too. Both only trigger an immediate refresh.
    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        observers.append(MainNotificationObserver(center: NotificationCenter.default,
                                                  name: NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.refresh()
        })
        observers.append(MainDistributedObserver(name: Notification.Name("com.apple.accessibility.api")) { [weak self] in
            self?.refresh()
        })
    }

    // MARK: Requests

    /// Shows the system prompt the first time. When access was denied before, opens the Microphone pane
    /// instead (the prompt never appears again, and the grant is watched for) and returns false.
    func requestMicrophone() async -> Bool {
        guard !isPreview else { return microphone == .granted }
        let status = await Task.detached(priority: .userInitiated) {
            AVCaptureDevice.authorizationStatus(for: .audio)
        }.value
        switch status {
        case .authorized:
            microphone = .granted
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphone = granted ? .granted : .denied
            refresh()
            return granted
        case .denied:
            microphone = .denied
            open(.microphone)
            return false
        case .restricted:
            microphone = .denied
            microphoneRestricted = true
            return false
        @unknown default:
            refresh()
            return false
        }
    }

    /// First time: the system prompt (which adds transcribe-thing to the list and links to Settings). After that the
    /// prompt never shows again, so the Accessibility pane opens directly. Polls fast until granted (3 min at most).
    func requestAccessibility() {
        guard !isPreview else { return }
        let askedBefore = defaults.bool(forKey: Self.requestedAccessibilityKey)
        defaults.set(true, forKey: Self.requestedAccessibilityKey)
        // == kAXTrustedCheckOptionPrompt, which imports as a mutable global.
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if !trusted && (askedBefore || accessibilityLikelyStale) { open(.accessibility) }
        watchForGrant(of: .accessibility)
        refresh()
    }

    /// Opens the pane. For Microphone and Accessibility it also watches for the grant, so a toast's
    /// "Open Settings" is noticed without transcribe-thing being activated again.
    func open(_ pane: SettingsPane) {
        guard !isPreview else { return }
        if !NSWorkspace.shared.open(pane.url) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
        }
        watchForGrant(of: pane)
    }
}

// MARK: - Probe (off the main thread)

struct PermissionProbe: Sendable {
    var microphone: PermissionState
    var microphoneRestricted: Bool
    var accessibilityTrusted: Bool
    var cdhash: String?
    var fnKeyUsage: FnKeyUsage

    static func capture() -> PermissionProbe {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let microphone: PermissionState = switch micStatus {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
        return PermissionProbe(
            microphone: microphone,
            microphoneRestricted: micStatus == .restricted,
            accessibilityTrusted: AXIsProcessTrusted(),
            cdhash: CodeIdentity.cdhash,
            fnKeyUsage: Self.fnKeyUsage(FnKeyAdvisor.usage))
    }

    static func fnKeyUsage(_ usage: FnKeyAdvisor.Usage?) -> FnKeyUsage {
        guard let usage else { return .unknown }
        return usage == .doNothing ? .doNothing : .other(usage.shortName)
    }
}

/// The running binary's code-directory hash. With an ad-hoc signature it changes on every build, and TCC
/// pins grants to it, which is how a still-ticked Accessibility row stops working after a rebuild.
enum CodeIdentity {
    static let cdhash: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let data = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }()
}
