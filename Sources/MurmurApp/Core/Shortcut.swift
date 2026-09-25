import Carbon.HIToolbox
import CoreGraphics
import Foundation
import IOKit.hidsystem

// Shortcut model, display and validation. UI-free and safe to use from the event-tap thread
// (only `KeyNames.printable` touches Text Input Sources, and it does so on the main thread only).

// MARK: - Key codes (Carbon HIToolbox Events.h, kVK_*)

enum KeyCode {
    static let function = UInt16(kVK_Function)          // 63
    static let command = UInt16(kVK_Command)            // 55 (left)
    static let rightCommand = UInt16(kVK_RightCommand)  // 54
    static let shift = UInt16(kVK_Shift)                // 56 (left)
    static let rightShift = UInt16(kVK_RightShift)      // 60
    static let option = UInt16(kVK_Option)              // 58 (left)
    static let rightOption = UInt16(kVK_RightOption)    // 61
    static let control = UInt16(kVK_Control)            // 59 (left)
    static let rightControl = UInt16(kVK_RightControl)  // 62
    static let capsLock = UInt16(kVK_CapsLock)          // 57
    static let space = UInt16(kVK_Space)                // 49
    static let escape = UInt16(kVK_Escape)              // 53
    static let returnKey = UInt16(kVK_Return)           // 36
    static let tab = UInt16(kVK_Tab)                    // 48
    static let delete = UInt16(kVK_Delete)              // 51
    static let forwardDelete = UInt16(kVK_ForwardDelete) // 117
    static let ansiV = UInt16(kVK_ANSI_V)               // 9
    static let ansiC = UInt16(kVK_ANSI_C)               // 8
    static let f13 = UInt16(kVK_F13)                    // 105

    /// Key codes that arrive as flagsChanged (never keyDown/keyUp).
    static let modifierKeyCodes: Set<UInt16> = [
        function, command, rightCommand, shift, rightShift,
        option, rightOption, control, rightControl, capsLock,
    ]
}

// MARK: - Device-dependent modifier bits (IOKit/hidsystem/IOLLEvent.h)

enum DeviceModifierMask {
    static let leftControl = UInt64(NX_DEVICELCTLKEYMASK)     // 0x0001
    static let leftShift = UInt64(NX_DEVICELSHIFTKEYMASK)     // 0x0002
    static let rightShift = UInt64(NX_DEVICERSHIFTKEYMASK)    // 0x0004
    static let leftCommand = UInt64(NX_DEVICELCMDKEYMASK)     // 0x0008
    static let rightCommand = UInt64(NX_DEVICERCMDKEYMASK)    // 0x0010
    static let leftOption = UInt64(NX_DEVICELALTKEYMASK)      // 0x0020
    static let rightOption = UInt64(NX_DEVICERALTKEYMASK)     // 0x0040
    static let rightControl = UInt64(NX_DEVICERCTLKEYMASK)    // 0x2000
}

// MARK: - Physical modifier state

/// Which modifier keys are physically down, side-aware.
/// Fn must be tracked from flagsChanged keycode 63 only: keyDown events for arrows, F-keys and
/// navigation keys carry `.maskSecondaryFn` even when Fn is not held.
struct ModifierSnapshot: Equatable, Sendable {
    var leftControl = false, rightControl = false
    var leftOption = false, rightOption = false
    var leftShift = false, rightShift = false
    var leftCommand = false, rightCommand = false
    var function = false

    init() {}

    init(flags: CGEventFlags, functionDown: Bool) {
        self.init(rawFlags: flags.rawValue, functionDown: functionDown)
    }

    /// Works for both `CGEventFlags.rawValue` and `NSEvent.ModifierFlags.rawValue`
    /// (same NX_* bit layout, including the device-dependent low bits).
    init(rawFlags raw: UInt64, functionDown: Bool) {
        func sides(_ family: UInt64, _ left: UInt64, _ right: UInt64) -> (Bool, Bool) {
            guard raw & family != 0 else { return (false, false) }
            let l = raw & left != 0, r = raw & right != 0
            // Synthetic events often carry only the device-independent bit: treat it as the left key.
            return (l || r) ? (l, r) : (true, false)
        }
        (leftControl, rightControl) = sides(CGEventFlags.maskControl.rawValue, DeviceModifierMask.leftControl, DeviceModifierMask.rightControl)
        (leftOption, rightOption) = sides(CGEventFlags.maskAlternate.rawValue, DeviceModifierMask.leftOption, DeviceModifierMask.rightOption)
        (leftShift, rightShift) = sides(CGEventFlags.maskShift.rawValue, DeviceModifierMask.leftShift, DeviceModifierMask.rightShift)
        (leftCommand, rightCommand) = sides(CGEventFlags.maskCommand.rawValue, DeviceModifierMask.leftCommand, DeviceModifierMask.rightCommand)
        function = functionDown
    }

    var isEmpty: Bool { self == ModifierSnapshot() }

    func sides(of modifier: Shortcut.Modifier) -> (left: Bool, right: Bool) {
        switch modifier {
        case .function: (function, false)
        case .control: (leftControl, rightControl)
        case .option: (leftOption, rightOption)
        case .shift: (leftShift, rightShift)
        case .command: (leftCommand, rightCommand)
        }
    }

    /// The held set expressed as shortcut modifiers (both sides held => `.either`).
    var asModifierKeys: [Shortcut.ModifierKey] {
        Shortcut.Modifier.allCases.compactMap { m in
            let (l, r) = sides(of: m)
            switch (l, r) {
            case (false, false): return nil
            case (true, true): return .init(m, .either)
            case (true, false): return .init(m, m == .function ? .either : .left)
            case (false, true): return .init(m, .right)
            }
        }
    }

    var count: Int {
        [leftControl, rightControl, leftOption, rightOption, leftShift, rightShift,
         leftCommand, rightCommand, function].filter { $0 }.count
    }
}

// MARK: - Shortcut model

/// A rebindable shortcut: modifier-only (fn, Right ⌥, ⌃⌥), modifier + key (fn Space, ⌃⌘V) or a single key (F13, Esc).
/// JSON for fn+Space: `{"modifiers":[{"modifier":"function","side":"either"}],"keyCode":49}`.
struct Shortcut: Codable, Hashable, Sendable {
    /// Declaration order is display order: fn first, then Apple's ⌃⌥⇧⌘.
    enum Modifier: String, Codable, CaseIterable, Sendable {
        case function, control, option, shift, command
    }

    enum Side: String, Codable, Sendable {
        case either, left, right
    }

    struct ModifierKey: Codable, Hashable, Sendable {
        var modifier: Modifier
        var side: Side

        init(_ modifier: Modifier, _ side: Side = .either) {
            self.modifier = modifier
            // Fn has no left/right variant.
            self.side = modifier == .function ? .either : side
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(try c.decode(Modifier.self, forKey: .modifier),
                      try c.decodeIfPresent(Side.self, forKey: .side) ?? .either)
        }
    }

    /// Normalized: at most one entry per modifier family, sorted in display order.
    private(set) var modifiers: [ModifierKey]
    /// nil means a modifier-only shortcut.
    private(set) var keyCode: UInt16?

    init(modifiers: [ModifierKey], keyCode: UInt16? = nil) {
        var byFamily: [Modifier: Side] = [:]
        for mk in modifiers {
            if let existing = byFamily[mk.modifier], existing != mk.side {
                byFamily[mk.modifier] = .either      // left + right => either
            } else {
                byFamily[mk.modifier] = mk.side
            }
        }
        self.modifiers = Modifier.allCases.compactMap { m in byFamily[m].map { ModifierKey(m, $0) } }
        self.keyCode = keyCode
    }

    private enum CodingKeys: String, CodingKey { case modifiers, keyCode }

    // Decoding goes through the normalizing init so hand-edited or older JSON can't produce duplicates.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(modifiers: try c.decodeIfPresent([ModifierKey].self, forKey: .modifiers) ?? [],
                  keyCode: try c.decodeIfPresent(UInt16.self, forKey: .keyCode))
    }

    var isModifierOnly: Bool { keyCode == nil && !modifiers.isEmpty }
    var isEmpty: Bool { modifiers.isEmpty && keyCode == nil }
    func contains(_ modifier: Modifier) -> Bool { modifiers.contains { $0.modifier == modifier } }
    var usesFunctionKey: Bool { contains(.function) }

    // MARK: Well-known shortcuts

    static let fn = Shortcut(modifiers: [.init(.function)])
    static let fnSpace = Shortcut(modifiers: [.init(.function)], keyCode: KeyCode.space)
    static let escape = Shortcut(modifiers: [], keyCode: KeyCode.escape)
    static let commandFnV = Shortcut(modifiers: [.init(.command), .init(.function)], keyCode: KeyCode.ansiV)
    static let commandLeftControlC = Shortcut(modifiers: [.init(.command), .init(.control, .left)], keyCode: KeyCode.ansiC)
    static let rightOption = Shortcut(modifiers: [.init(.option, .right)])
    static let rightCommand = Shortcut(modifiers: [.init(.command, .right)])
    static let f13 = Shortcut(modifiers: [], keyCode: KeyCode.f13)

    // MARK: Matching

    /// Exactly the required modifiers are down (respecting sides) and nothing else.
    func modifiersMatchExactly(_ s: ModifierSnapshot) -> Bool {
        for m in Modifier.allCases {
            let (l, r) = s.sides(of: m)
            guard let req = modifiers.first(where: { $0.modifier == m }) else {
                if l || r { return false }
                continue
            }
            switch req.side {
            case .either: if !(l || r) { return false }
            case .left: if !l || r { return false }
            case .right: if !r || l { return false }
            }
        }
        return true
    }

    /// All required modifiers are down (extra modifiers allowed).
    func requiredModifiersHeld(_ s: ModifierSnapshot) -> Bool {
        modifiers.allSatisfy { req in
            let (l, r) = s.sides(of: req.modifier)
            switch req.side {
            case .either: return l || r
            case .left: return l
            case .right: return r
            }
        }
    }

    /// Key event matches this key-based shortcut exactly (key code + exact modifiers).
    func matches(keyCode code: UInt16, modifiers snapshot: ModifierSnapshot) -> Bool {
        keyCode == code && modifiersMatchExactly(snapshot)
    }

    // MARK: Display conveniences

    var displayTokens: [String] { ShortcutFormatter.tokens(self) }
    var compactDescription: String { ShortcutFormatter.compact(self) }
    var spokenDescription: String { ShortcutFormatter.spoken(self) }
    var keycaps: [Keycap] { ShortcutFormatter.keycaps(self) }
}

// MARK: - Actions and bindings

enum ShortcutAction: String, Codable, CaseIterable, Sendable, Identifiable, CodingKeyRepresentable {
    case pushToTalk, handsFree, cancel, pasteLast, copyLast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pushToTalk: "Push to talk"
        case .handsFree: "Hands-free"
        case .cancel: "Cancel"
        case .pasteLast: "Paste last transcript"
        case .copyLast: "Copy last transcript"
        }
    }

    var subtitle: String {
        switch self {
        case .pushToTalk: "Hold to record, let go to paste."
        case .handsFree: "Tap to start. Tap again to finish."
        case .cancel: "Discard the current recording."
        case .pasteLast: "Paste your most recent transcript again."
        case .copyLast: "Copy your most recent transcript."
        }
    }

    var symbolName: String {
        switch self {
        case .pushToTalk: "mic.fill"
        case .handsFree: "lock.fill"
        case .cancel: "xmark"
        case .pasteLast: "doc.on.clipboard"
        case .copyLast: "doc.on.doc"
        }
    }

    var defaultShortcut: Shortcut { ShortcutBindings.defaults[self] ?? .fn }
}

/// Action → shortcut map. Encodes as a flat JSON object keyed by action in declaration order,
/// with `null` for a deliberately unbound action. A missing key decodes to the default, so new
/// actions added later get their default binding instead of silently being unbound.
struct ShortcutBindings: Codable, Equatable, Sendable {
    var bindings: [ShortcutAction: Shortcut]

    init(bindings: [ShortcutAction: Shortcut]) {
        self.bindings = bindings
    }

    /// The user's own Wispr Flow configuration.
    static let defaults = ShortcutBindings(bindings: [
        .pushToTalk: .fn,
        .handsFree: .fnSpace,
        .cancel: .escape,
        .pasteLast: .commandFnV,
        .copyLast: .commandLeftControlC,
    ])

    subscript(_ action: ShortcutAction) -> Shortcut? {
        get { bindings[action] }
        set { bindings[action] = newValue }
    }

    /// First other action (in declaration order) already bound to the same shortcut.
    func conflict(for shortcut: Shortcut, excluding: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != excluding && bindings[$0] == shortcut }
    }

    /// Exchanges two bindings (the "Swap" answer to a conflict).
    mutating func swap(_ a: ShortcutAction, _ b: ShortcutAction) {
        let first = bindings[a]
        bindings[a] = bindings[b]
        bindings[b] = first
    }

    private struct ActionKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ action: ShortcutAction) { stringValue = action.rawValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ActionKey.self)
        for action in ShortcutAction.allCases {
            if let shortcut = bindings[action] {
                try c.encode(shortcut, forKey: ActionKey(action))
            } else {
                try c.encodeNil(forKey: ActionKey(action))
            }
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ActionKey.self)
        var result = Self.defaults.bindings
        for action in ShortcutAction.allCases {
            let key = ActionKey(action)
            guard c.contains(key) else { continue }
            if try c.decodeNil(forKey: key) {
                result[action] = nil
            } else {
                result[action] = try c.decode(Shortcut.self, forKey: key)
            }
        }
        bindings = result
    }
}

// MARK: - Display

enum FunctionKeyStyle: String, Codable, Sendable { case fn, globe, globeFn }

/// One key cap as drawn by `KeyChip`: "fn" with a globe, "⌘", "space", "esc", "V", or "⌃" with a "left" caption.
struct Keycap: Hashable, Sendable {
    var label: String
    var systemImage: String?
    var side: Shortcut.Side = .either
    var isWide = false

    var sideCaption: String? {
        switch side {
        case .either: nil
        case .left: "left"
        case .right: "right"
        }
    }
}

enum ShortcutFormatter {
    static func symbol(_ m: Shortcut.Modifier, style: FunctionKeyStyle = .fn) -> String {
        switch m {
        case .function:
            switch style {
            case .fn: "fn"
            case .globe: "🌐"
            case .globeFn: "🌐 fn"
            }
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }

    static func word(_ m: Shortcut.Modifier, style: FunctionKeyStyle = .fn) -> String {
        switch m {
        case .function: style == .fn ? "Fn" : "Globe"
        case .control: "Control"
        case .option: "Option"
        case .shift: "Shift"
        case .command: "Command"
        }
    }

    /// Keycap tokens: ["fn", "Space"], ["Right ⌥"], ["⌃", "⌘", "V"].
    static func tokens(_ s: Shortcut, style: FunctionKeyStyle = .fn) -> [String] {
        var out = s.modifiers.map { mk -> String in
            switch mk.side {
            case .either: symbol(mk.modifier, style: style)
            case .left: "Left \(symbol(mk.modifier, style: style))"
            case .right: "Right \(symbol(mk.modifier, style: style))"
            }
        }
        if let k = s.keyCode { out.append(KeyNames.name(for: k)) }
        return out
    }

    /// Menu-style string: "⌃⌘V", "fn Space", "Right ⌥".
    static func compact(_ s: Shortcut, style: FunctionKeyStyle = .fn) -> String {
        let t = tokens(s, style: style)
        let allSymbols = s.modifiers.allSatisfy { $0.side == .either && $0.modifier != .function }
        if allSymbols, s.keyCode != nil, !s.modifiers.isEmpty { return t.joined() }
        return t.joined(separator: " ")
    }

    /// Words for VoiceOver and tooltips: "Right Option", "Fn + Space".
    static func spoken(_ s: Shortcut, style: FunctionKeyStyle = .fn) -> String {
        var parts = s.modifiers.map { mk -> String in
            switch mk.side {
            case .either: word(mk.modifier, style: style)
            case .left: "Left \(word(mk.modifier, style: style))"
            case .right: "Right \(word(mk.modifier, style: style))"
            }
        }
        if let k = s.keyCode { parts.append(KeyNames.spokenName(for: k)) }
        return parts.joined(separator: " + ")
    }

    /// Structured caps for the chip renderer.
    static func keycaps(_ s: Shortcut) -> [Keycap] {
        var caps = s.modifiers.map { mk -> Keycap in
            if mk.modifier == .function {
                return Keycap(label: "fn", systemImage: "globe")
            }
            return Keycap(label: symbol(mk.modifier), side: mk.side)
        }
        if let k = s.keyCode {
            caps.append(Keycap(label: KeyNames.keycapLabel(for: k), isWide: k == KeyCode.space))
        }
        return caps
    }
}

/// Human-readable names for virtual key codes.
enum KeyNames {
    private struct Names { let symbol: String; let spoken: String; let keycap: String }

    private static let special: [UInt16: Names] = {
        var d: [Int: Names] = [
            kVK_Space: Names(symbol: "Space", spoken: "Space", keycap: "space"),
            kVK_Return: Names(symbol: "↩", spoken: "Return", keycap: "return"),
            kVK_Tab: Names(symbol: "⇥", spoken: "Tab", keycap: "tab"),
            kVK_Delete: Names(symbol: "⌫", spoken: "Delete", keycap: "delete"),
            kVK_ForwardDelete: Names(symbol: "⌦", spoken: "Forward Delete", keycap: "⌦"),
            kVK_Escape: Names(symbol: "Esc", spoken: "Escape", keycap: "esc"),
            kVK_LeftArrow: Names(symbol: "←", spoken: "Left Arrow", keycap: "←"),
            kVK_RightArrow: Names(symbol: "→", spoken: "Right Arrow", keycap: "→"),
            kVK_UpArrow: Names(symbol: "↑", spoken: "Up Arrow", keycap: "↑"),
            kVK_DownArrow: Names(symbol: "↓", spoken: "Down Arrow", keycap: "↓"),
            kVK_Home: Names(symbol: "↖", spoken: "Home", keycap: "home"),
            kVK_End: Names(symbol: "↘", spoken: "End", keycap: "end"),
            kVK_PageUp: Names(symbol: "⇞", spoken: "Page Up", keycap: "⇞"),
            kVK_PageDown: Names(symbol: "⇟", spoken: "Page Down", keycap: "⇟"),
            kVK_Help: Names(symbol: "Help", spoken: "Help", keycap: "help"),
            kVK_ANSI_KeypadEnter: Names(symbol: "⌤", spoken: "Keypad Enter", keycap: "enter"),
            kVK_ANSI_KeypadClear: Names(symbol: "⌧", spoken: "Clear", keycap: "clear"),
        ]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, code) in fKeys.enumerated() {
            let name = "F\(i + 1)"
            d[code] = Names(symbol: name, spoken: name, keycap: name)
        }
        return Dictionary(uniqueKeysWithValues: d.map { (UInt16($0.key), $0.value) })
    }()

    /// US ANSI legends, used off the main thread and when no ASCII-capable layout can be read.
    private static let ansiFallback: [UInt16: String] = {
        let pairs: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
            (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
            (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
            (kVK_ANSI_Z, "Z"), (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"),
            (kVK_ANSI_9, "9"), (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["),
            (kVK_ANSI_RightBracket, "]"), (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Semicolon, ";"),
            (kVK_ANSI_Quote, "'"), (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"),
            (kVK_ANSI_Grave, "`"),
        ]
        return Dictionary(uniqueKeysWithValues: pairs.map { (UInt16($0.0), $0.1) })
    }()

    static let functionKeys: Set<UInt16> = Set([
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ].map { UInt16($0) })

    /// F1–F12 are media keys on Apple keyboards unless com.apple.keyboard.fnState is on.
    static let mediaFunctionKeys: Set<UInt16> = Set([
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
    ].map { UInt16($0) })

    /// Keys whose keyDown carries `.maskSecondaryFn` even without Fn physically held.
    static let fnFlaggedKeys: Set<UInt16> = functionKeys.union([
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End,
        kVK_PageUp, kVK_PageDown, kVK_ForwardDelete, kVK_Help,
    ].map { UInt16($0) })

    static func name(for keyCode: UInt16) -> String {
        if let s = special[keyCode] { return s.symbol }
        return printable(keyCode)?.uppercased() ?? "Key \(keyCode)"
    }

    static func spokenName(for keyCode: UInt16) -> String {
        if let s = special[keyCode] { return s.spoken }
        return printable(keyCode)?.uppercased() ?? "Key \(keyCode)"
    }

    static func keycapLabel(for keyCode: UInt16) -> String {
        if let s = special[keyCode] { return s.keycap }
        return printable(keyCode)?.uppercased() ?? "\(keyCode)"
    }

    /// Character the key produces in the current ASCII-capable layout, so shortcuts show Latin
    /// letters even while the user types in Russian. Text Input Sources are main-thread only.
    static func printable(_ keyCode: UInt16) -> String? {
        if Thread.isMainThread,
           let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let s = KeyboardLayout.translate(keyCode: keyCode, carbonModifiers: 0, source: src),
           !s.isEmpty,
           s.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespaces.contains($0) }) {
            return s
        }
        return ansiFallback[keyCode]
    }
}

/// UCKeyTranslate wrapper.
enum KeyboardLayout {
    /// `carbonModifiers`: Carbon-style modifier bits (cmdKey, shiftKey, optionKey, controlKey from Events.h).
    static func translate(keyCode: UInt16, carbonModifiers: UInt32, source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout -> String? in
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown),
                                        (carbonModifiers >> 8) & 0xFF, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                        &deadKeyState, chars.count, &length, &chars)
            guard status == noErr else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}

// MARK: - Validation

struct ShortcutValidation: Equatable, Sendable {
    var errors: [String] = []
    var warnings: [String] = []
    /// Another action already bound to this shortcut (offer "Swap").
    var conflict: ShortcutAction?

    var isAcceptable: Bool { errors.isEmpty }
}

enum ShortcutValidator {
    /// Well-known system combos. Not exhaustive; `SystemSymbolicHotKeys` covers the user's enabled ones.
    static let reserved: [(Shortcut, String)] = [
        (Shortcut(modifiers: [.init(.command)], keyCode: UInt16(kVK_Space)), "Spotlight"),
        (Shortcut(modifiers: [.init(.control)], keyCode: UInt16(kVK_Space)), "switching input sources"),
        (Shortcut(modifiers: [.init(.control), .init(.option)], keyCode: UInt16(kVK_Space)), "switching input sources"),
        (Shortcut(modifiers: [.init(.control), .init(.command)], keyCode: UInt16(kVK_Space)), "Emoji & Symbols"),
        (Shortcut(modifiers: [.init(.command)], keyCode: UInt16(kVK_Tab)), "the app switcher"),
        (Shortcut(modifiers: [.init(.command)], keyCode: UInt16(kVK_ANSI_Grave)), "cycling windows"),
        (Shortcut(modifiers: [.init(.command)], keyCode: UInt16(kVK_ANSI_Q)), "Quit"),
        (Shortcut(modifiers: [.init(.command)], keyCode: UInt16(kVK_ANSI_W)), "Close Window"),
        (Shortcut(modifiers: [.init(.command)], keyCode: UInt16(kVK_ANSI_H)), "Hide"),
        (Shortcut(modifiers: [.init(.command)], keyCode: UInt16(kVK_ANSI_M)), "Minimize"),
        (Shortcut(modifiers: [.init(.command)], keyCode: UInt16(kVK_ANSI_V)), "Paste"),
        (Shortcut(modifiers: [.init(.command)], keyCode: UInt16(kVK_ANSI_C)), "Copy"),
        (Shortcut(modifiers: [.init(.command), .init(.option)], keyCode: UInt16(kVK_Escape)), "Force Quit"),
        (Shortcut(modifiers: [.init(.control), .init(.command)], keyCode: UInt16(kVK_ANSI_Q)), "Lock Screen"),
        (Shortcut(modifiers: [.init(.shift), .init(.command)], keyCode: UInt16(kVK_ANSI_3)), "screenshots"),
        (Shortcut(modifiers: [.init(.shift), .init(.command)], keyCode: UInt16(kVK_ANSI_4)), "screenshots"),
        (Shortcut(modifiers: [.init(.shift), .init(.command)], keyCode: UInt16(kVK_ANSI_5)), "the screenshot toolbar"),
        (Shortcut(modifiers: [.init(.function)], keyCode: UInt16(kVK_ANSI_E)), "Emoji & Symbols"),
        (Shortcut(modifiers: [.init(.function)], keyCode: UInt16(kVK_ANSI_F)), "full screen"),
        (Shortcut(modifiers: [.init(.function)], keyCode: UInt16(kVK_ANSI_Q)), "Quick Note"),
        (Shortcut(modifiers: [.init(.function)], keyCode: UInt16(kVK_ANSI_N)), "Notification Center"),
        (Shortcut(modifiers: [.init(.function)], keyCode: UInt16(kVK_ANSI_C)), "Control Center"),
        (Shortcut(modifiers: [.init(.function)], keyCode: UInt16(kVK_ANSI_A)), "the Dock"),
    ]

    /// `bindings` supplies the other actions for duplicate detection.
    static func validate(_ s: Shortcut, for action: ShortcutAction,
                         bindings: ShortcutBindings = .defaults) -> ShortcutValidation {
        var v = ShortcutValidation()
        if s.isEmpty {
            v.errors.append("Press a key or a key combination.")
            return v
        }

        let mods = Set(s.modifiers.map(\.modifier))
        let hasCommandOrControl = mods.contains(.command) || mods.contains(.control)

        if let key = s.keyCode {
            let isFunctionKey = KeyNames.functionKeys.contains(key)
            let isBareEscape = key == KeyCode.escape && mods.isEmpty
            if key == KeyCode.escape && action != .cancel {
                v.errors.append("Esc is reserved for canceling a recording.")
            } else if mods.isEmpty && !isFunctionKey && !isBareEscape {
                v.errors.append("A single key would get in the way of typing. Add ⌃ or ⌘, or use F13–F20.")
            } else if !mods.isEmpty && !hasCommandOrControl && !mods.contains(.function) && !isFunctionKey {
                // ⌥ is a dead-key/diacritic layer in many layouts and ⇧ types capitals.
                v.errors.append("⇧ or ⌥ with a key types characters. Add ⌃, ⌘ or fn.")
            }
            if mods.isEmpty && KeyNames.mediaFunctionKeys.contains(key) {
                v.warnings.append("On Apple keyboards F1–F12 control brightness and volume unless “Use F1, F2, etc. keys as standard function keys” is on.")
            }
        } else if s.modifiers.count == 1, let only = s.modifiers.first {
            switch (only.modifier, only.side) {
            case (.shift, _):
                v.errors.append("Shift alone is pressed all the time while typing.")
            case (.command, .either), (.command, .left):
                v.warnings.append("⌘ alone is part of most shortcuts. Right ⌘ is rarely used and works better.")
            case (.option, .either), (.option, .left):
                v.warnings.append("⌥ alone types special characters. Right ⌥ works better.")
            case (.control, .either), (.control, .left):
                v.warnings.append("⌃ alone is common in terminals and editors. Try Right ⌃ or fn.")
            default:
                break
            }
        }

        if s.isModifierOnly && mods.contains(.function) {
            v.warnings.append(contentsOf: FnKeyAdvisor.warnings())
        }

        if let hit = reserved.first(where: { $0.0.keyCode == s.keyCode && $0.0.modifiers == s.modifiers }) {
            v.errors.append("macOS already uses this for \(hit.1).")
        } else if !SystemSymbolicHotKeys.conflicts(with: s).isEmpty {
            v.warnings.append("This may clash with a shortcut that’s turned on in Keyboard Settings.")
        }

        if let other = bindings.conflict(for: s, excluding: action) {
            v.conflict = other
            v.errors.append("Already used for \(other.title.lowercased()).")
        }
        // The PTT modifiers being a prefix of the hands-free chord is intended (fn / fn+Space).
        return v
    }
}

/// Reads ~/Library/Preferences/com.apple.symbolichotkeys.plist (undocumented format:
/// parameters = [asciiCode, virtualKeyCode, NSEvent-style modifier mask], 65535 = unset).
enum SystemSymbolicHotKeys {
    static func conflicts(with s: Shortcut) -> [String] {
        guard let key = s.keyCode,
              let dict = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                                   "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        else { return [] }
        let relevantMask = CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue
        var mask: UInt64 = 0
        for mk in s.modifiers {
            switch mk.modifier {
            case .shift: mask |= CGEventFlags.maskShift.rawValue
            case .control: mask |= CGEventFlags.maskControl.rawValue
            case .option: mask |= CGEventFlags.maskAlternate.rawValue
            case .command: mask |= CGEventFlags.maskCommand.rawValue
            case .function: break
            }
        }
        var hits: [String] = []
        for (id, value) in dict {
            guard let entry = value as? [String: Any],
                  (entry["enabled"] as? Bool) == true,
                  let v = entry["value"] as? [String: Any],
                  let params = v["parameters"] as? [Int], params.count >= 3,
                  params[1] != 65535, params[1] >= 0, params[1] <= Int(UInt16.max)
            else { continue }
            if UInt16(params[1]) == key && UInt64(truncatingIfNeeded: params[2]) & relevantMask == mask {
                hits.append(id)
            }
        }
        return hits.sorted()
    }
}

/// Globe/Fn key system behavior (com.apple.HIToolbox AppleFnUsageType).
enum FnKeyAdvisor {
    enum Usage: Int, Sendable {
        case doNothing = 0, changeInputSource = 1, showEmojiAndSymbols = 2, startDictation = 3

        /// Matches the wording of "Press 🌐 key to" in Keyboard settings.
        var settingName: String {
            switch self {
            case .doNothing: "Do Nothing"
            case .changeInputSource: "Change Input Source"
            case .showEmojiAndSymbols: "Show Emoji & Symbols"
            case .startDictation: "Start Dictation"
            }
        }

        var shortName: String {
            switch self {
            case .doNothing: "Nothing"
            case .changeInputSource: "Input Sources"
            case .showEmojiAndSymbols: "Emoji & Symbols"
            case .startDictation: "Dictation"
            }
        }
    }

    /// nil when the key is absent (system default, which behaves like Emoji & Symbols).
    static var usage: Usage? {
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        guard let v = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString,
                                                "com.apple.HIToolbox" as CFString) as? Int
        else { return nil }
        return Usage(rawValue: v)
    }

    static func warnings() -> [String] { warnings(for: usage) }

    static func warnings(for usage: Usage?) -> [String] {
        switch usage {
        case .doNothing?:
            return []
        case .changeInputSource?:
            return ["“Press 🌐 key to” is set to Change Input Source, so every fn press also switches your keyboard layout. Set it to Do Nothing in Keyboard Settings."]
        case .showEmojiAndSymbols?, nil:
            return ["“Press 🌐 key to” may open Emoji & Symbols after you dictate. Set it to Do Nothing in Keyboard Settings."]
        case .startDictation?:
            return ["“Press 🌐 key to” is set to Start Dictation, so quick repeated dictations may open Apple Dictation. Set it to Do Nothing in Keyboard Settings."]
        }
    }
}
