import AppKit

/// Builds transcribe-thing's menu (SPEC §4.14). The status item shows it with "Quit transcribe-thing"; the pill's right-click
/// menu is the same menu without it.
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

        let isHandsFree = isLocked(env.dictation.machine.capture)
        menu.addItem(MenuActionItem(title: isHandsFree ? "Finish Dictation" : "Start Hands-free Dictation",
                                    shortcut: settings.shortcuts[.handsFree]) { [weak env] in
            env?.dictation.toggleHandsFree()
        })
        if env.dictation.machine.isRecording {
            menu.addItem(MenuActionItem(title: "Cancel Dictation", shortcut: settings.shortcuts[.cancel]) { [weak env] in
                env?.dictation.cancelCurrent()
            })
        }
        let hasLast = env.history.lastSuccessfulText != nil
        let paste = MenuActionItem(title: "Paste Last Transcript", shortcut: settings.shortcuts[.pasteLast]) { [weak env] in
            env?.dictation.pasteLast()
        }
        paste.isEnabled = hasLast
        menu.addItem(paste)
        let copy = MenuActionItem(title: "Copy Last Transcript", shortcut: settings.shortcuts[.copyLast]) { [weak env] in
            env?.dictation.copyLast()
        }
        copy.isEnabled = hasLast
        menu.addItem(copy)
        menu.addItem(.separator())

        menu.addItem(submenuItem("Model", symbol: "square.stack.3d.up", modelMenu(env)))
        menu.addItem(submenuItem("Microphone", symbol: "mic", microphoneMenu(env)))
        menu.addItem(submenuItem("Show Pill", symbol: "capsule", pillMenu(env)))
        let hidden = settings.isPillTemporarilyHidden()
        let hide = MenuActionItem(title: hidden ? "Show Pill Now" : "Hide Pill for 1 Hour") { [weak env] in
            guard let env else { return }
            if env.settings.isPillTemporarilyHidden() {
                env.settings.pillHiddenUntil = nil
            } else {
                // PillController posts the "Pill hidden for an hour · Show Now" toast itself.
                env.settings.hidePill()
            }
        }
        hide.isEnabled = settings.pillMode != .never
        menu.addItem(hide)
        menu.addItem(.separator())

        menu.addItem(MenuActionItem(title: "Open transcribe-thing…") { [weak env] in env?.windows.showHub(.home) })
        let prefs = MenuActionItem(title: "Settings…") { [weak env] in env?.windows.showHub(.general) }
        prefs.keyEquivalent = ","
        prefs.keyEquivalentModifierMask = [.command]
        menu.addItem(prefs)

        if includeQuit {
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "Quit transcribe-thing", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

    // MARK: - Status line

    private func statusItem(_ env: AppEnvironment) -> NSMenuItem {
        let status = Self.engineStatus(env.settings.selectedEngine, models: env.models, account: env.account)
        let activity: String? = switch env.dictation.activity {
        case .recording: "Listening…"
        case .processing: "Transcribing…"
        case .idle: nil
        }
        let item = NSMenuItem(title: "\(env.settings.selectedEngine.displayName) · \(activity ?? status.text)",
                              action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.image = Self.dot(activity == nil ? status.color : .systemRed)
        return item
    }

    struct EngineStatus {
        var text: String
        var color: NSColor
        /// Can dictate with it now (or it will be ready by the time the recording ends).
        var isUsable: Bool
    }

    static func engineStatus(_ engine: EngineID, models: ModelStore, account: OpenRouterAccount) -> EngineStatus {
        if engine.isLocal {
            switch models.state(of: engine) {
            case .ready, .installed:
                return EngineStatus(text: "Ready", color: Palette.success, isUsable: true)
            case .preparing:
                return EngineStatus(text: "Optimizing…", color: Palette.warning, isUsable: true)
            case .downloading(let progress):
                return EngineStatus(text: "Downloading \(progress.percent)%", color: Palette.accent, isUsable: true)
            case .notInstalled:
                return EngineStatus(text: "Not downloaded", color: Palette.danger, isUsable: false)
            case .failed:
                return EngineStatus(text: "Needs attention", color: Palette.danger, isUsable: false)
            }
        }
        switch account.status {
        case .valid:
            return EngineStatus(text: "Ready", color: Palette.success, isUsable: true)
        case .checking:
            return EngineStatus(text: "Checking key…", color: Palette.warning, isUsable: true)
        case .missing:
            return EngineStatus(text: "Key needed", color: Palette.danger, isUsable: false)
        case .invalid:
            return EngineStatus(text: "Key rejected", color: Palette.danger, isUsable: false)
        case .noCredit:
            return EngineStatus(text: account.status.isKeyLimitReached ? "Key limit reached" : "Out of credit",
                                color: Palette.danger, isUsable: true)
        case .offline:
            return EngineStatus(text: "Offline", color: Palette.warning, isUsable: true)
        case .failed:
            return EngineStatus(text: "Couldn’t check key", color: Palette.warning, isUsable: true)
        }
    }

    // MARK: - Submenus

    private func modelMenu(_ env: AppEnvironment) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for engine in EngineID.allCases {
            let status = Self.engineStatus(engine, models: env.models, account: env.account)
            let item = MenuActionItem(title: engine.displayName) { [weak env] in
                env?.models.select(engine)
            }
            item.state = env.settings.selectedEngine == engine ? .on : .off
            item.isEnabled = status.isUsable
            if !status.isUsable || status.text != "Ready" {
                item.attributedTitle = Self.titleWithSuffix(engine.displayName, suffix: status.text)
            }
            item.image = Self.symbol(engine.symbolName)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(MenuActionItem(title: "Manage Models…") { [weak env] in env?.windows.showHub(.models) })
        return menu
    }

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

    private func pillMenu(_ env: AppEnvironment) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let titles: [(PillMode, String)] = [(.always, "Always"), (.whileDictating, "While Dictating"), (.never, "Never")]
        for (mode, title) in titles {
            let item = MenuActionItem(title: title) { [weak env] in
                env?.settings.pillMode = mode
                env?.settings.pillHiddenUntil = nil
            }
            item.state = env.settings.pillMode == mode ? .on : .off
            menu.addItem(item)
        }
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

    private static func titleWithSuffix(_ title: String, suffix: String) -> NSAttributedString {
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

    /// NSMenu can draw fn (globe), ⌘ ⌥ ⌃ ⇧ with a key; modifier-only shortcuts have no menu form.
    static func keyEquivalent(for shortcut: Shortcut) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard let code = shortcut.keyCode else { return nil }
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
