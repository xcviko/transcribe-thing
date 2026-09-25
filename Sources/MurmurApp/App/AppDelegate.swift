import AppKit

// FOUNDATION first cut; SHELL owns this (single instance, main menu, reopen handling).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var environment: AppEnvironment?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = AppEnvironment.live()
        environment = env
        env.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        environment?.windows.showHub(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
