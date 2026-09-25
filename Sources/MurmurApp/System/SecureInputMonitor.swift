import Foundation
import Observation

// STUB (FOUNDATION): SYSTEM replaces this with IsSecureEventInputEnabled polling.
@MainActor @Observable
final class SecureInputMonitor {
    private(set) var isActive = false
    private(set) var owningAppName: String?

    init() {}

    func start() {}

    static func preview(active: Bool = false, owningAppName: String? = nil) -> SecureInputMonitor {
        let monitor = SecureInputMonitor()
        monitor.isActive = active
        monitor.owningAppName = owningAppName
        return monitor
    }
}
