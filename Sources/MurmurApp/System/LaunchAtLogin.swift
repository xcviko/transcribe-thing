import Foundation
import Observation

// STUB (FOUNDATION): SYSTEM replaces this with SMAppService.mainApp.
@MainActor @Observable
final class LaunchAtLogin {
    private var enabled = false

    init() {}

    var isEnabled: Bool { enabled }

    func set(_ on: Bool) throws {
        enabled = on
    }

    static func preview() -> LaunchAtLogin {
        LaunchAtLogin()
    }
}
