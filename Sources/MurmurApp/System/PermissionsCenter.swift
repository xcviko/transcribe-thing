import Foundation
import Observation

// STUB (FOUNDATION): SYSTEM replaces this with TCC polling and requests.
enum PermissionState: Equatable, Sendable { case granted, denied, notDetermined }

enum FnKeyUsage: Equatable, Sendable {
    case doNothing
    /// "Emoji & Symbols", "Input Sources", "Dictation"
    case other(String)
    case unknown
}

@MainActor @Observable
final class PermissionsCenter {
    private(set) var microphone: PermissionState = .notDetermined
    private(set) var accessibility: PermissionState = .notDetermined
    private(set) var fnKeyUsage: FnKeyUsage = .unknown
    /// Listed in System Settings but AXIsProcessTrusted() is false (ad-hoc rebuild).
    private(set) var accessibilityLikelyStale = false
    @ObservationIgnored var onAccessibilityGranted: (() -> Void)?

    init() {}

    static func preview(mic: PermissionState, ax: PermissionState) -> PermissionsCenter {
        let center = PermissionsCenter()
        center.microphone = mic
        center.accessibility = ax
        center.fnKeyUsage = .doNothing
        return center
    }

    var allRequiredGranted: Bool { microphone == .granted && accessibility == .granted }

    func refresh() {}
    func startPolling(interval: TimeInterval = 0.5) {}
    func stopPolling() {}
    func requestMicrophone() async -> Bool { microphone == .granted }
    func requestAccessibility() {}
    func open(_ pane: SettingsPane) {}
}
