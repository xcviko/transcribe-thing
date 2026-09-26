import AppKit
import Observation
import SwiftUI

/// Owns the Hub and onboarding windows (plain `NSWindow` + `NSHostingController`) and the activation
/// policy: `.regular` while a transcribe-thing window is visible or the Dock icon is on, `.accessory` otherwise.
@MainActor @Observable
final class WindowCoordinator: NSObject, NSWindowDelegate {
    static let hubSize = CGSize(width: 980, height: 680)
    static let hubMinimumSize = CGSize(width: 820, height: 560)
    static let onboardingSize = CGSize(width: 820, height: 600)

    /// Selected Hub page; HubView binds to it so `showHub(_:)` can switch pages of an open window.
    var hubSection: HubSection = .home

    @ObservationIgnored weak var environment: AppEnvironment?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var hubWindow: NSWindow?
    @ObservationIgnored private var onboardingWindow: NSWindow?
    /// The app that was frontmost before we opened a window; focus goes back to it when we step aside.
    @ObservationIgnored private var previousApp: NSRunningApplication?

    init(settings: AppSettings) {
        self.settings = settings
    }

    var hasVisibleWindow: Bool {
        [hubWindow, onboardingWindow].contains { $0?.isVisible == true }
    }

    var isOnboardingVisible: Bool { onboardingWindow?.isVisible == true }

    /// Onboarding is the window the user is typing into (transcribe-thing active, onboarding key).
    var isOnboardingFocused: Bool { NSApp.isActive && onboardingWindow?.isKeyWindow == true }

    func showOnboarding() {
        guard let env = environment else { return }
        let window = onboardingWindow ?? makeOnboardingWindow(env)
        onboardingWindow = window
        present(window)
    }

    func showHub(_ section: HubSection?) {
        if let section { hubSection = section }
        guard let env = environment else { return }
        let window = hubWindow ?? makeHubWindow(env)
        hubWindow = window
        present(window)
    }

    func closeOnboarding() {
        onboardingWindow?.close()
    }

    func closeHub() {
        hubWindow?.close()
    }

    /// Dock icon: shown while any transcribe-thing window is open, or always when the user asked for it.
    func updateActivationPolicy() {
        let wantsRegular = hasVisibleWindow || settings.showDockIcon
        let policy: NSApplication.ActivationPolicy = wantsRegular ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    // MARK: - Windows

    private func makeHubWindow(_ env: AppEnvironment) -> NSWindow {
        // The host pauses global hotkeys while a shortcut recorder captures keys (pressing fn to rebind
        // must not start a dictation) and gives recorders the bindings for conflict checks and Swap.
        let root = HubView(env: env)
            .shortcutRecorderHost(hotkeys: env.hotkeys, settings: env.settings)
            .appTheme()
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "transcribe-thing"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.hubMinimumSize
        window.setContentSize(Self.hubSize)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("TranscribeThingHubWindow")
        return window
    }

    private func makeOnboardingWindow(_ env: AppEnvironment) -> NSWindow {
        let hosting = NSHostingController(rootView: OnboardingView(env: env).appTheme())
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.title = "Welcome to transcribe-thing"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setContentSize(Self.onboardingSize)
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.delegate = self
        window.center()
        return window
    }

    /// Order matters: become a regular app (Dock icon, main menu), show the window, then activate.
    private func present(_ window: NSWindow) {
        if let front = NSWorkspace.shared.frontmostApplication, front != .current {
            previousApp = front
        }
        NSApp.setActivationPolicy(.regular)
        window.collectionBehavior.insert(.moveToActiveSpace)
        // An agent app launched from Terminal or Finder is not activated for us, and activation is
        // cooperative since macOS 14: makeKeyAndOrderFront alone can leave the window behind the active app.
        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate()
        DispatchQueue.main.async { [weak window] in
            MainActor.assumeIsolated {
                guard let window, window.isVisible, !NSApp.isActive else { return }
                window.orderFrontRegardless()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        // Drop the window and its SwiftUI tree so the agent stays light in the background.
        if closing === hubWindow { hubWindow = nil }
        if closing === onboardingWindow { onboardingWindow = nil }
        // The closing window still counts as visible during willClose.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.didCloseWindow() }
        }
    }

    private func didCloseWindow() {
        guard !hasVisibleWindow else { return }
        updateActivationPolicy()
        if !settings.showDockIcon, let previous = previousApp, !previous.isTerminated {
            NSApp.yieldActivation(to: previous)
            previous.activate()
        }
        previousApp = nil
    }
}
