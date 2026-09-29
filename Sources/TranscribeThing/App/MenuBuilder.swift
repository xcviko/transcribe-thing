import AppKit

/// Builds transcribe-thing's menu (SPEC §4.14). The status item shows it with "Quit"; the pill's right-click menu is the
/// same menu without it.
@MainActor
final class MenuBuilder {
    weak var environment: AppEnvironment?

    init(environment: AppEnvironment? = nil) {
        self.environment = environment
    }

    func makeMenu(includeQuit: Bool) -> NSMenu {
        let menu = NSMenu(title: "transcribe-thing")
        populate(menu, includeQuit: includeQuit)
        return menu
    }

    /// Rebuilds `menu` in place from the current state (called every time the menu opens).
    func populate(_ menu: NSMenu, includeQuit: Bool) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        guard let env = environment else { return }
        let settings = env.settings

        menu.addItem(statusItem(env))
        menu.addItem(.separator())

        // The only menu way to stop a dictation, so these show up while one runs.
        if isLocked(env.dictation.machine.capture) {
            menu.addItem(MenuActionItem(title: "Finish Dictation", shortcut: settings.shortcuts[.handsFree]) { [weak env] in
                env?.dictation.toggleHandsFree()
            })
        }
        if env.dictation.machine.isRecording {
            menu.addItem(MenuActionItem(title: "Cancel Dictation", shortcut: .escape) { [weak env] in
                env?.dictation.cancelCurrent()
            })
        }
        let paste = MenuActionItem(title: "Paste Last Transcript", shortcut: settings.shortcuts[.pasteLast]) { [weak env] in
            env?.dictation.pasteLast()
        }
        paste.isEnabled = env.history.lastSuccessfulText != nil
        menu.addItem(paste)
        menu.addItem(.separator())

        menu.addItem(submenuItem("Microphone", symbol: "mic", microphoneMenu(env)))
        menu.addItem(.separator())

        menu.addItem(MenuActionItem(title: "Settings…") { [weak env] in env?.windows.showHub(.home) })
        if let update = updateItem(env) { menu.addItem(update) }

        if includeQuit {
            menu.addItem(.separator())
            // No ⌘Q: quitting takes a deliberate click.
            let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            quit.target = NSApp
            menu.addItem(quit)
        }
    }

    private func isLocked(_ capture: DictationMachine.Capture) -> Bool {
        switch capture {
        case .locked, .lockedStopPending: true
        default: false
        }
    }

    // MARK: - Updates

    /// "Update to 0.3.0…" with a badge while an update waits (and reminders are on); nothing otherwise.
    private func updateItem(_ env: AppEnvironment) -> NSMenuItem? {
        let updates = env.updates
        guard updates.showsBadge, let available = updates.availableUpdate else { return nil }
        let item = MenuActionItem(title: "Update to \(available.version)…") { [weak env] in
            env?.windows.showHub(.softwareUpdate)
        }
        item.badge = .updates(count: 1)
        return item
    }

    // MARK: - Status line

    /// "Parakeet v3 · Ready", "Gemini 3.8 Flash · Needs key": the main model, or what the app is doing.
    private func statusItem(_ env: AppEnvironment) -> NSMenuItem {
        let main = env.settings.lineup.main, parakeet = env.settings.parakeetEngine
        let status = Self.status(of: main, parakeet: parakeet, models: env.models, account: env.account)
        let activity: String? = switch env.dictation.activity {
        case .recording: "Listening…"
        case .processing: "Transcribing…"
        case .idle: nil
        }
        let item = NSMenuItem(title: "\(main.title(parakeet: parakeet)) · \(activity ?? status.text)",
                              action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.image = Self.dot(activity == nil ? status.color : .systemRed)
        return item
    }

    struct EngineStatus {
        var text: String
        var color: NSColor
    }

    /// A model's status: its engine's, and for clean-up Parakeet's until it's ready, then the OpenRouter key's.
    static func status(of choice: ModelChoice, parakeet: EngineID, models: ModelStore,
                       account: OpenRouterAccount) -> EngineStatus {
        let transcriber = engineStatus(choice.engine(parakeet: parakeet), models: models, account: account)
        guard choice.cleansUp, transcriber.text == "Ready" else { return transcriber }
        return engineStatus(.geminiFlash, models: models, account: account)
    }

    static func engineStatus(_ engine: EngineID, models: ModelStore, account: OpenRouterAccount) -> EngineStatus {
        if engine.isLocal {
            switch models.state(of: engine) {
            case .ready, .installed:
                return EngineStatus(text: "Ready", color: Palette.success)
            case .preparing:
                return EngineStatus(text: "Optimizing…", color: Palette.warning)
            case .downloading(let progress):
                return EngineStatus(text: "Downloading \(progress.percent)%", color: Palette.accent)
            case .notInstalled:
                return EngineStatus(text: "Not downloaded", color: Palette.danger)
            case .failed:
                return EngineStatus(text: "Needs attention", color: Palette.danger)
            }
        }
        switch account.status {
        case .valid:
            return EngineStatus(text: "Ready", color: Palette.success)
        case .checking:
            return EngineStatus(text: "Checking key…", color: Palette.warning)
        case .missing:
            return EngineStatus(text: "Needs key", color: Palette.danger)
        case .invalid:
            return EngineStatus(text: "Key rejected", color: Palette.danger)
        case .noCredit:
            return EngineStatus(text: account.status.isKeyLimitReached ? "Key limit reached" : "Out of credit",
                                color: Palette.danger)
        case .offline:
            return EngineStatus(text: "Offline", color: Palette.warning)
        case .failed:
            return EngineStatus(text: "Couldn’t check key", color: Palette.warning)
        }
    }

    // MARK: - Submenus

    private func microphoneMenu(_ env: AppEnvironment) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let selected = env.settings.microphoneUID
        let defaultName = env.devices.device(uid: env.devices.defaultDeviceUID)?.name
        let automatic = MenuActionItem(title: "Automatic (System Default)") { [weak env] in
            env?.settings.microphoneUID = nil
        }
        if let defaultName {
            automatic.attributedTitle = Self.titleWithSuffix("Automatic (System Default)", suffix: defaultName)
        }
        automatic.state = selected == nil ? .on : .off
        menu.addItem(automatic)

        let devices = env.devices.devices.filter { $0.transport != .virtual || $0.id == selected }
        if !devices.isEmpty { menu.addItem(.separator()) }
        for device in devices {
            let item = MenuActionItem(title: device.name) { [weak env] in
                env?.settings.microphoneUID = device.id
            }
            item.state = device.id == selected ? .on : .off
            item.isEnabled = device.isAvailable
            if !device.isAvailable {
                item.attributedTitle = Self.titleWithSuffix(device.name, suffix: "Unavailable")
            }
            item.image = Self.symbol(Self.symbolName(for: device.transport))
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(MenuActionItem(title: "Microphone Settings…") { [weak env] in env?.windows.showHub(.microphone) })
        return menu
    }

    // MARK: - Helpers

    private func submenuItem(_ title: String, symbol: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.image = Self.symbol(symbol)
        return item
    }

    static func symbolName(for transport: AudioInputDevice.Transport) -> String {
        switch transport {
        case .builtIn: "laptopcomputer"
        case .bluetooth: "headphones"
        case .usb: "mic"
        case .aggregate, .virtual, .other: "waveform"
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    /// `title` with a secondary suffix: "Automatic (System Default)  MacBook Pro Microphone", "Gemini 3.8 Flash
    /// Needs key".
    static func titleWithSuffix(_ title: String, suffix: String) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let result = NSMutableAttributedString(string: title, attributes: [.font: font])
        result.append(NSAttributedString(string: "  \(suffix)", attributes: [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return result
    }

    /// A small filled circle for the status line.
    static func dot(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 3.5, y: rect.midY - 3.5, width: 7, height: 7)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// A menu item that runs a closure. Shortcut hints are display-only: status and pill menus never
/// receive key equivalents while closed, and our global shortcuts are handled by the event tap.
final class MenuActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, shortcut: Shortcut? = nil, action: @escaping @MainActor () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let shortcut, let equivalent = Self.keyEquivalent(for: shortcut) {
            keyEquivalent = equivalent.key
            keyEquivalentModifierMask = equivalent.modifiers
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        MainActor.assumeIsolated { handler() }
    }

    /// The hint only when the menu draws the shortcut faithfully: ⌘ ⌥ ⌃ ⇧ with a key. The menu drops fn
    /// (⌘ fn V would read "⌘V", which is a normal paste) and can't tell left from right, and modifier-only
    /// shortcuts have no menu form: those get no hint rather than a wrong one.
    static func keyEquivalent(for shortcut: Shortcut) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard let code = shortcut.keyCode, !shortcut.usesFunctionKey,
              shortcut.modifiers.allSatisfy({ $0.side == .either }) else { return nil }
        let key: String
        switch code {
        case KeyCode.space: key = " "
        case KeyCode.escape: key = "\u{1b}"
        case KeyCode.returnKey: key = "\r"
        case KeyCode.tab: key = "\t"
        case KeyCode.delete: key = "\u{8}"
        default:
            guard let printable = KeyNames.printable(code), printable.count == 1 else { return nil }
            key = printable.lowercased()
        }
        var modifiers: NSEvent.ModifierFlags = []
        for modifier in shortcut.modifiers {
            switch modifier.modifier {
            case .function: modifiers.insert(.function)
            case .control: modifiers.insert(.control)
            case .option: modifiers.insert(.option)
            case .shift: modifiers.insert(.shift)
            case .command: modifiers.insert(.command)
            }
        }
        return (key, modifiers)
    }
}
