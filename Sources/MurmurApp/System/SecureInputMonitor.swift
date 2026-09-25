import AppKit
import Carbon.HIToolbox
import IOKit
import Observation

/// Secure Event Input (a focused password field, Terminal's Secure Keyboard Entry, a misbehaving app)
/// stops keyboard events from reaching our tap, so hotkeys silently stop working while it is on.
@MainActor @Observable
final class SecureInputMonitor {
    private(set) var isActive = false
    /// Best guess only: the PID macOS reports is often just the frontmost app.
    private(set) var owningAppName: String?

    /// "possibly Google Chrome", for UI copy.
    var ownerHint: String? { owningAppName.map { "possibly \($0)" } }

    @ObservationIgnored private let isPreview: Bool
    @ObservationIgnored private var timer: DispatchSourceTimer?

    init() {
        isPreview = false
    }

    private init(preview: Void) {
        isPreview = true
    }

    static func preview(active: Bool = false, owningAppName: String? = nil) -> SecureInputMonitor {
        let monitor = SecureInputMonitor(preview: ())
        monitor.isActive = active
        monitor.owningAppName = active ? owningAppName : nil
        return monitor
    }

    /// Polls every 2 s on a utility queue; the main actor hears about changes only.
    func start() {
        guard !isPreview, timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.murmur.secure-input", qos: .utility))
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(250))
        timer.setEventHandler(handler: Self.pollHandler(WeakSecureInput(self)))
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    fileprivate func apply(_ state: SecureInputState) {
        if isActive != state.active { isActive = state.active }
        if owningAppName != state.owner { owningAppName = state.owner }
    }

    /// Built in a nonisolated context: the handler runs on the timer queue, never on the main actor.
    nonisolated private static func pollHandler(_ box: WeakSecureInput) -> @Sendable () -> Void {
        let last = LastState()
        return {
            let state = SecureInputState.current()
            guard last.swap(state) != state else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { box.monitor?.apply(state) }
            }
        }
    }
}

struct SecureInputState: Equatable, Sendable {
    var active: Bool
    var owner: String?

    static func current() -> SecureInputState {
        let active = IsSecureEventInputEnabled()
        return SecureInputState(active: active, owner: active ? secureInputOwnerName() : nil)
    }

    /// `kCGSSessionSecureInputPID` in IORegistry root "IOConsoleUsers" (undocumented). On macOS 26.6 the key
    /// appears exactly while secure input is on.
    static func secureInputOwnerName() -> String? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] else { return nil }
        for user in users {
            if let pid = (user["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value {
                return NSRunningApplication(processIdentifier: pid)?.localizedName
            }
        }
        return nil
    }
}

private final class WeakSecureInput: @unchecked Sendable {
    // Assigned once on the main actor, read only in main-queue blocks.
    weak var monitor: SecureInputMonitor?

    init(_ monitor: SecureInputMonitor) {
        self.monitor = monitor
    }
}

/// Last reported state; touched only from the timer's serial queue.
private final class LastState: @unchecked Sendable {
    private var value: SecureInputState?

    func swap(_ new: SecureInputState) -> SecureInputState? {
        defer { value = new }
        return value
    }
}
