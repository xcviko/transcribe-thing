import Foundation

// STUB (FOUNDATION): SYSTEM replaces this with the event-tap monitor.
enum HotkeyEvent: Equatable, Sendable {
    case pttDown, pttUp, pttInterrupted, handsFreeToggle, cancel, pasteLast, copyLast
}

@MainActor
final class HotkeyMonitor {
    private let settings: AppSettings

    var onEvent: ((HotkeyEvent) -> Void)?
    /// Swallow the cancel key only while busy.
    var isBusy = false
    private(set) var isRunning = false
    /// Physical key transitions for the onboarding keyboard (fn/space/esc/⌘/⌥/⌃).
    var onRawKey: ((RawKeyEvent) -> Void)?
    var onTapAvailabilityChanged: ((Bool) -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// False if the event tap cannot be created (no permission).
    @discardableResult
    func start() -> Bool { false }
    func stop() { isRunning = false }
    /// While the shortcut recorder is capturing.
    func suspend() {}
    func resume() {}

    static func preview() -> HotkeyMonitor {
        HotkeyMonitor(settings: .inMemory())
    }
}
