import AppKit
import CoreGraphics
import Foundation
import Observation
import os

enum HotkeyEvent: Equatable, Sendable {
    case pttDown, pttUp, pttInterrupted, handsFreeToggle, cancel, pasteLast
    /// The switch model shortcut, during a dictation.
    case cycleEngine
    /// Its key held down: an autorepeat, which steps on at the controller's pace.
    case cycleEngineRepeat
}

/// Marker written into `kCGEventSourceUserData` of every event transcribe-thing synthesizes (the ⌘V paste),
/// so our own tap lets them through untouched.
enum SyntheticEvent {
    static let tag: Int64 = 0x5454_4E47  // "TTNG"
}

/// Global hotkeys on an active session event tap. Dictation-agnostic: it reports key gestures
/// (`HotkeyEvent`) and leaves their meaning to `DictationMachine`.
///
/// The tap runs on its own high-priority thread with its own run loop, because an active tap is
/// synchronous: a busy main thread would delay every keystroke system-wide. Decisions are made there by
/// `HotkeyRouter`; results hop to the main actor.
@MainActor
final class HotkeyMonitor {
    nonisolated static let syntheticEventTag: Int64 = SyntheticEvent.tag

    var onEvent: ((HotkeyEvent) -> Void)?
    /// Swallow the cancel key only while busy.
    var isBusy = false {
        didSet { if isBusy != oldValue { pushConfig() } }
    }
    /// Swallow the switch model shortcut only while a dictation records.
    var isRecording = false {
        didSet { if isRecording != oldValue { pushConfig() } }
    }
    /// The tap thread is running (it keeps retrying tap creation until permission arrives).
    private(set) var isRunning = false
    /// The event tap is installed and receiving events.
    private(set) var isTapActive = false
    /// Physical key transitions for the onboarding keyboard (fn/space/esc/⌘/⌥/⌃/⇧ and keys used by bindings).
    var onRawKey: ((RawKeyEvent) -> Void)? {
        didSet { if (onRawKey == nil) != (oldValue == nil) { pushConfig() } }
    }
    var onTapAvailabilityChanged: ((Bool) -> Void)?

    var isSuspended: Bool { suspendCount > 0 }

    private let settings: AppSettings
    private let isPreview: Bool
    private var engine: HotkeyTapEngine?
    private var suspendCount = 0
    private var isObservingSettings = false
    private var requestedFallbackAccess = false

    init(settings: AppSettings) {
        self.settings = settings
        self.isPreview = false
    }

    private init(previewSettings: AppSettings) {
        self.settings = previewSettings
        self.isPreview = true
    }

    static func preview() -> HotkeyMonitor {
        HotkeyMonitor(previewSettings: .inMemory())
    }

    // MARK: Lifecycle

    /// Starts the tap thread and returns whether the tap is live. When it isn't (no permission yet) the
    /// thread keeps retrying every 3 s and reports through `onTapAvailabilityChanged`. Calling it again
    /// while running retries immediately (e.g. right after Accessibility was granted).
    @discardableResult
    func start() -> Bool {
        guard !isPreview else { return false }
        if let engine {
            let ok = engine.retryNow()
            applyAvailability(ok, notify: true)
            return ok
        }
        observeSettings()
        let engine = HotkeyTapEngine(config: currentConfig(), sink: Self.makeSink(WeakMonitor(self)))
        self.engine = engine
        isRunning = true
        let ok = engine.start()
        applyAvailability(ok, notify: false)
        if !ok { requestFallbackAccessIfNeeded() }
        Log.hotkey.info("Hotkey monitor started, tap \(ok ? "active" : "unavailable", privacy: .public)")
        return ok
    }

    func stop() {
        engine?.stop()
        engine = nil
        isRunning = false
        isTapActive = false
    }

    /// While the shortcut recorder is capturing. Calls nest: each `suspend()` needs one `resume()`.
    func suspend() {
        suspendCount += 1
        if suspendCount == 1 { pushConfig() }
    }

    func resume() {
        guard suspendCount > 0 else { return }
        suspendCount -= 1
        if suspendCount == 0 { pushConfig() }
    }

    // MARK: Config

    private func currentConfig() -> HotkeyRouter.Config {
        HotkeyRouter.Config(bindings: settings.shortcuts, isBusy: isBusy, isRecording: isRecording,
                            switchesModels: !settings.switchEngines.isEmpty,
                            isSuspended: suspendCount > 0, forwardsRawKeys: onRawKey != nil)
    }

    private func pushConfig() {
        engine?.update(currentConfig())
    }

    /// Bindings (and the extra models taking part in Switch model) edited in the Hub or onboarding take effect on
    /// the next keystroke.
    private func observeSettings() {
        guard !isObservingSettings else { return }
        isObservingSettings = true
        trackBindings()
    }

    private func trackBindings() {
        withObservationTracking {
            _ = settings.shortcuts
            _ = settings.switchEngines
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.pushConfig()
                self?.trackBindings()
            }
        }
    }

    // MARK: Output from the tap thread

    fileprivate func deliver(_ output: HotkeyTapEngine.Output) {
        switch output {
        case .decision(let events, let raw):
            if let raw { onRawKey?(raw) }
            for event in events { onEvent?(event) }
        case .availability(let available):
            applyAvailability(available, notify: true)
        }
    }

    private func applyAvailability(_ available: Bool, notify: Bool) {
        let changed = available != isTapActive
        isTapActive = available
        if changed && notify {
            Log.hotkey.info("Event tap \(available ? "available" : "unavailable", privacy: .public)")
            onTapAvailabilityChanged?(available)
        }
    }

    /// Accessibility normally covers the active tap. If it is granted and the tap still can't be created,
    /// ask for the narrower event permissions once (each shows a system prompt at most once).
    private func requestFallbackAccessIfNeeded() {
        guard !requestedFallbackAccess else { return }
        requestedFallbackAccess = true
        Task.detached(priority: .utility) {
            // Only when Accessibility is granted and the tap still fails; otherwise these would prompt at launch.
            guard AXIsProcessTrusted() else { return }
            if !CGPreflightPostEventAccess() { _ = CGRequestPostEventAccess() }
            if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        }
    }

    /// Built in a nonisolated context so the closure the tap thread calls is never main-actor isolated.
    nonisolated private static func makeSink(_ box: WeakMonitor) -> @Sendable (HotkeyTapEngine.Output) -> Void {
        { output in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { box.monitor?.deliver(output) }
            }
        }
    }
}

private final class WeakMonitor: @unchecked Sendable {
    // Written once on the main actor, read only inside main-queue blocks.
    weak var monitor: HotkeyMonitor?

    init(_ monitor: HotkeyMonitor) {
        self.monitor = monitor
    }
}

/// CFRunLoop is thread-safe for PerformBlock/WakeUp; the box only carries it across a Sendable boundary.
private struct RunLoopBox: @unchecked Sendable {
    let value: CFRunLoop
}

// MARK: - Tap engine (tap thread)

/// Owns the CGEventTap, its thread and the router state. Everything except `start`, `stop`, `retryNow`
/// and `update` runs on the tap thread.
final class HotkeyTapEngine: @unchecked Sendable {
    enum Output: Sendable {
        case decision([HotkeyEvent], RawKeyEvent?)
        case availability(Bool)
    }

    private let config: OSAllocatedUnfairLock<HotkeyRouter.Config>
    private let sink: @Sendable (Output) -> Void
    private let healthInterval: TimeInterval
    private let tapActive = OSAllocatedUnfairLock(initialState: false)

    // Owner-thread state (main actor).
    private var thread: Thread?
    // Published by the tap thread before `start()` returns; afterwards read-only from other threads.
    private var runLoop: CFRunLoop?

    // Tap-thread state.
    private var router = HotkeyRouter()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var healthTimer: CFRunLoopTimer?
    private var reportedAvailability: Bool?

    init(config: HotkeyRouter.Config, healthInterval: TimeInterval = 3,
         sink: @escaping @Sendable (Output) -> Void) {
        self.config = OSAllocatedUnfairLock(initialState: config)
        self.healthInterval = healthInterval
        self.sink = sink
    }

    // No teardown in deinit: the thread closure retains the engine until `stop()`, so the unretained
    // pointer handed to the C callback can never dangle.

    func update(_ newConfig: HotkeyRouter.Config) {
        config.withLock { $0 = newConfig }
    }

    var isActive: Bool { tapActive.withLock { $0 } }

    // MARK: Lifecycle (owner thread)

    func start() -> Bool {
        guard thread == nil else { return isActive }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()!
            self.runLoop = loop
            let ok = self.createTap()
            self.report(ok)
            self.installHealthTimer(on: loop)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "transcribe-thing.HotkeyTap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        ready.wait()
        return isActive
    }

    func stop() {
        guard let loop = runLoop else {
            thread = nil
            return
        }
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [self] in
            if let timer = self.healthTimer { CFRunLoopTimerInvalidate(timer) }
            self.healthTimer = nil
            self.destroyTap()
            CFRunLoopStop(CFRunLoopGetCurrent())
            done.signal()
        }
        CFRunLoopWakeUp(loop)
        _ = done.wait(timeout: .now() + 1)
        runLoop = nil
        thread = nil
    }

    /// Tries to create the tap right away (on the tap thread) and waits briefly for the answer.
    func retryNow() -> Bool {
        guard let loop = runLoop else { return false }
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [self] in
            if self.tap == nil { self.report(self.createTap()) }
            done.signal()
        }
        CFRunLoopWakeUp(loop)
        _ = done.wait(timeout: .now() + 0.5)
        return isActive
    }

    // MARK: Tap installation (tap thread)

    private static let eventMask: CGEventMask = {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    }()

    private func createTap() -> Bool {
        guard tap == nil, let loop = runLoop else { return tap != nil }
        // An untrusted tapCreate makes macOS show its own "control this computer" prompt, which would pop
        // up at launch and every retry. Ask quietly first; the prompt belongs to onboarding's Permissions step.
        guard AXIsProcessTrusted() else { return false }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<HotkeyTapEngine>.fromOpaque(userInfo).takeUnretainedValue()
            return engine.handle(type: type, event: event)
        }
        // Keyboard bits are stripped from the mask when permission is missing at creation time, which
        // leaves it empty and makes tapCreate return nil (CGEvent.h). Hence the retry after a grant.
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                             options: .defaultTap, eventsOfInterest: Self.eventMask,
                                             callback: callback,
                                             userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(loop, newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        tap = newTap
        source = newSource
        tapActive.withLock { $0 = true }
        resynchronize()
        return true
    }

    private func destroyTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source, let runLoop { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
        tapActive.withLock { $0 = false }
        let events = router.reset()
        if !events.isEmpty { sink(.decision(events, nil)) }
    }

    private func report(_ available: Bool) {
        guard reportedAvailability != available else { return }
        reportedAvailability = available
        sink(.availability(available))
    }

    private func installHealthTimer(on loop: CFRunLoop) {
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + healthInterval,
                                                    healthInterval, 0, 0) { [weak self] _ in
            self?.healthCheck()
        }
        CFRunLoopAddTimer(loop, timer, .commonModes)
        healthTimer = timer
    }

    private func healthCheck() {
        guard let tap else {
            if createTap() { report(true) }
            return
        }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            resynchronize()
        }
        // AXIsProcessTrusted() is cached in-process and has been reported to stay true after revocation,
        // while a throwaway active tap can only be created while we still hold the privilege. An active tap
        // left installed after revocation has been reported to wedge input, so ours goes when the probe fails.
        // The probe runs off the tap thread so keystrokes are never delayed by it.
        guard let runLoop else { return }
        let box = RunLoopBox(value: runLoop)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let probe = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(1) << CGEventType.keyUp.rawValue,
                                          callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                                          userInfo: nil)
            if let probe {
                CFMachPortInvalidate(probe)
                return
            }
            CFRunLoopPerformBlock(box.value, CFRunLoopMode.commonModes.rawValue) {
                guard let self, self.tap != nil else { return }
                self.destroyTap()
                self.report(false)
            }
            CFRunLoopWakeUp(box.value)
        }
    }

    // MARK: Events (tap thread: no I/O, no logging, no waiting on main)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let kind: HotkeyInput.Kind
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            resynchronize()
            return pass
        case .flagsChanged: kind = .flagsChanged
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .mouseDown
        default: return pass
        }
        let isKeyboard = kind != .mouseDown
        let input = HotkeyInput(
            kind: kind,
            keyCode: isKeyboard ? UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)) : 0,
            flags: event.flags.rawValue,
            isRepeat: isKeyboard && event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            isSynthetic: event.getIntegerValueField(.eventSourceUserData) == SyntheticEvent.tag)
        let current = config.withLock { $0 }
        let decision = router.handle(input, config: current)
        if !decision.events.isEmpty || decision.rawKey != nil {
            sink(.decision(decision.events, decision.rawKey))
        }
        return decision.swallow ? nil : pass
    }

    /// Up/down events may have been missed while the tap was off: rebuild from the session state table.
    private func resynchronize() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let current = config.withLock { $0 }
        let events = router.resynchronize(flags: flags.rawValue, config: current) { key in
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key))
        }
        if !events.isEmpty { sink(.decision(events, nil)) }
    }
}
