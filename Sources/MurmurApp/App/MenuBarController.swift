import AppKit

// FOUNDATION first cut; SHELL owns this (full menu per SPEC §4.14).
@MainActor
final class MenuBarController: NSObject {
    weak var environment: AppEnvironment?
    private var statusItem: NSStatusItem?

    override init() {
        super.init()
    }

    func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Murmur")
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Murmur…", action: #selector(openHub), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openHub() { environment?.windows.showHub(.home) }
    @objc private func openSettings() { environment?.windows.showHub(.general) }
}
