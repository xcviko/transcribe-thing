import AppKit
import Observation
import SwiftUI

// FOUNDATION first cut; SHELL owns this.
@MainActor @Observable
final class WindowCoordinator: NSObject, NSWindowDelegate {
    /// Selected Hub page; HubView binds to it so `showHub(_:)` can switch pages of an open window.
    var hubSection: HubSection = .home

    @ObservationIgnored weak var environment: AppEnvironment?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var hubWindow: NSWindow?
    @ObservationIgnored private var onboardingWindow: NSWindow?

    init(settings: AppSettings) {
        self.settings = settings
    }

    var hasVisibleWindow: Bool {
        [hubWindow, onboardingWindow].contains { $0?.isVisible == true }
    }

    func showOnboarding() {
        guard let env = environment else { return }
        let window = onboardingWindow ?? makeWindow(title: "Welcome to Murmur", size: CGSize(width: 820, height: 600),
                                                    resizable: false, root: OnboardingView(env: env))
        onboardingWindow = window
        present(window)
    }

    func showHub(_ section: HubSection?) {
        if let section { hubSection = section }
        guard let env = environment else { return }
        let window = hubWindow ?? makeWindow(title: "Murmur", size: CGSize(width: 980, height: 680),
                                             resizable: true, root: HubView(env: env))
        hubWindow = window
        present(window)
    }

    func closeOnboarding() {
        onboardingWindow?.close()
    }

    func updateActivationPolicy() {
        let regular = hasVisibleWindow || settings.showDockIcon
        NSApp.setActivationPolicy(regular ? .regular : .accessory)
    }

    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow<V: View>(title: String, size: CGSize, resizable: Bool, root: V) -> NSWindow {
        let hosting = NSHostingController(rootView: root.murmurTheme())
        let window = NSWindow(contentViewController: hosting)
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { mask.insert(.resizable) }
        window.styleMask = mask
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(size)
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === hubWindow { hubWindow = nil }
        if closing === onboardingWindow { onboardingWindow = nil }
        // The closing window still counts as visible during willClose.
        DispatchQueue.main.async { [weak self] in self?.updateActivationPolicy() }
    }
}
