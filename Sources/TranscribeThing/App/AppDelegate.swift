import AppKit

/// AppKit lifecycle for an agent app that hosts SwiftUI windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var environment: AppEnvironment?
    private var showObserver: (any NSObjectProtocol)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Two copies (say build/ and /Applications) would both grab the hotkeys and paste twice.
        if SingleInstance.handOffIfAlreadyRunning() {
            exit(0)
        }
        NSApp.mainMenu = MainMenu.make(
            openSettings: { [weak self] in self?.environment?.windows.showHub(.general) },
            openHub: { [weak self] in self?.showMainWindow() })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = AppEnvironment.live()
        environment = env
        env.start()
        showObserver = SingleInstance.observeShowRequests { [weak self] in self?.showMainWindow() }
    }

    /// Dock icon clicked, or transcribe-thing opened again from Finder/Spotlight while running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        environment?.stop()
    }

    private func showMainWindow() {
        guard let env = environment else { return }
        if env.settings.onboardingCompleted {
            env.windows.showHub(nil)
        } else {
            env.windows.showOnboarding()
        }
    }
}

// MARK: - Main menu

/// Visible only while transcribe-thing is a regular app (a window is open). The Edit menu is what makes ⌘C/⌘V/⌘A
/// work in text fields (pasting the OpenRouter key) under an AppKit lifecycle.
@MainActor
enum MainMenu {
    static func make(openSettings: @escaping @MainActor () -> Void, openHub: @escaping @MainActor () -> Void) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "transcribe-thing")
        app.addItem(withTitle: "About transcribe-thing", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let settings = MenuActionItem(title: "Settings…", action: openSettings)
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = [.command]
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide transcribe-thing", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        // No ⌘Q, as in the status menu: quitting takes a deliberate click.
        app.addItem(withTitle: "Quit transcribe-thing", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        addSubmenu(app, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pasteMatch = edit.addItem(withTitle: "Paste and Match Style",
                                      action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pasteMatch.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(edit, to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(MenuActionItem(title: "transcribe-thing", action: openHub))
        window.addItem(.separator())
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        addSubmenu(window, to: main)
        NSApp.windowsMenu = window

        return main
    }

    private static func addSubmenu(_ submenu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }
}

// MARK: - Single instance

enum SingleInstance {
    static let bundleIdentifier = "dev.transcribe-thing.app"
    static let showRequest = Notification.Name("dev.transcribe-thing.app.show")

    /// True when another transcribe-thing instance is already running; it was asked to show its window.
    @MainActor
    static func handOffIfAlreadyRunning() -> Bool {
        // The bare binary from .build has no bundle id: it's a development run, allow it.
        guard let id = Bundle.main.bundleIdentifier, id == bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        guard let other = others.first else { return false }
        DistributedNotificationCenter.default().postNotificationName(showRequest, object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
        other.activate()
        return true
    }

    static func observeShowRequests(_ handler: @escaping @MainActor () -> Void) -> any NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: showRequest, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
