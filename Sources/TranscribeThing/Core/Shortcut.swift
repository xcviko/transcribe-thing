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

    /// Some key press triggers both: the same key, the same modifier families, and sides that can coincide
    /// (`.either` meets anything; left and right never meet). ⌥ and Right ⌥ overlap; Left ⌥ and Right ⌥ don't.
    func overlaps(_ other: Shortcut) -> Bool {
        guard keyCode == other.keyCode, modifiers.count == other.modifiers.count else { return false }
        return zip(modifiers, other.modifiers).allSatisfy { a, b in
            a.modifier == b.modifier && Self.sidesMeet(a.side, b.side)
        }
    }

    /// Modifier-only, and held on the way to `other` (a larger modifier-only chord): a chord that fires on
    /// press would fire here before `other` is complete.
    func isHeldOnTheWay(to other: Shortcut) -> Bool {
        guard isModifierOnly, other.isModifierOnly, modifiers.count < other.modifiers.count else { return false }
        return modifiers.allSatisfy { mine in
            other.modifiers.contains { $0.modifier == mine.modifier && Self.sidesMeet($0.side, mine.side) }
        }
    }

    private static func sidesMeet(_ a: Side, _ b: Side) -> Bool {
        a == .either || b == .either || a == b
    }

    // MARK: Display conveniences

    var displayTokens: [String] { ShortcutFormatter.tokens(self) }
    var compactDescription: String { ShortcutFormatter.compact(self) }
    var spokenDescription: String { ShortcutFormatter.spoken(self) }
    var keycaps: [Keycap] { ShortcutFormatter.keycaps(self) }
}

// MARK: - Actions and bindings

enum ShortcutAction: String, Codable, CaseIterable, Sendable, Identifiable, CodingKeyRepresentable {
    case pushToTalk, handsFree, cancel, pasteLast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pushToTalk: "Push to talk"
        case .handsFree: "Hands-free"
        case .cancel: "Cancel"
        case .pasteLast: "Paste last transcript"
        }
    }

    var subtitle: String {
        switch self {
        case .pushToTalk: "Hold to record, let go to paste."
        case .handsFree: "Tap to start. Tap again to finish."
        case .cancel: "Discard the current recording."
        case .pasteLast: "Paste your most recent transcript again. It stays on the clipboard."
        }
    }

    var symbolName: String {
        switch self {
        case .pushToTalk: "mic.fill"
        case .handsFree: "lock.fill"
        case .cancel: "xmark"
        case .pasteLast: "doc.on.clipboard"
        }
    }

    var defaultShortcut: Shortcut { ShortcutBindings.defaults[self] ?? .fn }
}

/// Action → shortcut map. Encodes as a flat JSON object keyed by action in declaration order,
/// with `null` for a deliberately unbound action. A missing key decodes to the default, so new
/// actions added later get their default binding instead of silently being unbound. A key for an action
/// that no longer exists (copyLast, retired for paste last) is ignored, and the other bindings survive.
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
    ])

    subscript(_ action: ShortcutAction) -> Shortcut? {
        get { bindings[action] }
        set { bindings[action] = newValue }
    }

    /// First other action (in declaration order) whose shortcut some key press would trigger together with
    /// this one (⌥ and Right ⌥ clash as much as two identical shortcuts do).
    func conflict(for shortcut: Shortcut, excluding: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != excluding && bindings[$0]?.overlaps(shortcut) == true }
    }

    /// A modifier-only binding other than push to talk fires the moment its keys are held, so it must not be
    /// the start of another modifier-only binding: that one would fire it first. Push to talk as the start
    /// of another chord is intended (fn, then fn ⌃ for hands-free). Returns the action that clashes, and
    /// whether `shortcut` is the shorter one.
    func prefixClash(for shortcut: Shortcut, as action: ShortcutAction) -> (other: ShortcutAction, isShorter: Bool)? {
        for other in ShortcutAction.allCases where other != action {
            guard let theirs = bindings[other] else { continue }
            if action != .pushToTalk, shortcut.isHeldOnTheWay(to: theirs) { return (other, true) }
            if other != .pushToTalk, theirs.isHeldOnTheWay(to: shortcut) { return (other, false) }
        }
        return nil
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

    /// Letters, digits and punctuation: keys that type a character.
    static func isCharacterKey(_ keyCode: UInt16) -> Bool { ansiFallback[keyCode] != nil }

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

/// Why a binding may get in the way. It never blocks saving: the recorder saves the shortcut and shows
/// this underneath, one line plus an optional second.
struct ShortcutWarning: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// macOS or apps react to the same combination (only symbolic hot keys that are on right now).
        case systemShortcut
        /// Pressed while typing: a plain key, ⇧ or ⌥ with a key, or ⇧ alone.
        case typing
        /// Esc for something other than cancel: apps stop getting it.
        case escape
        /// F1–F12 control brightness and volume on Apple keyboards.
        case mediaKey
        /// A lone ⌘, ⌥ or ⌃ is part of other shortcuts; the right-hand key rarely is.
        case loneModifier
        /// "Press 🌐 key to" also does something when fn is pressed on its own.
        case globeKey
    }

    var kind: Kind
    var text: String
    var detail: String?

    init(_ kind: Kind, _ text: String, detail: String? = nil) {
        self.kind = kind
        self.text = text
        self.detail = detail
    }
}

struct ShortcutValidation: Equatable, Sendable {
    /// Why it can't work at all: nothing was pressed, or another action uses it (or starts with it).
    var errors: [String] = []
    /// Why it may get in the way, most specific first. Never blocks saving.
    var warnings: [ShortcutWarning] = []
    /// Another action already bound to this shortcut (offer "Swap").
    var conflict: ShortcutAction?

    var isAcceptable: Bool { errors.isEmpty }
}

/// The keyboard settings that decide which warnings apply.
struct SystemKeyboardState: Equatable, Sendable {
    /// Keyboard Settings › Keyboard Shortcuts entries that are on right now.
    var hotKeys: [SystemSymbolicHotKeys.HotKey]
    /// "Press 🌐 key to"; nil when never changed (behaves like Emoji & Symbols).
    var fnUsage: FnKeyAdvisor.Usage?
    /// "Use F1, F2, etc. keys as standard function keys".
    var functionKeysAreStandard: Bool

    /// This Mac's settings, read on every call: they can change while the app runs.
    static var current: SystemKeyboardState {
        SystemKeyboardState(hotKeys: SystemSymbolicHotKeys.active(in: SystemSymbolicHotKeys.readPreferences()),
                            fnUsage: FnKeyAdvisor.usage,
                            functionKeysAreStandard: FnKeyAdvisor.functionKeysAreStandard)
    }
}

/// Anything can be bound. Only an empty shortcut and a clash with another transcribe-thing action are errors
/// (the recorder offers Swap for a duplicate); everything else that may get in the way is a warning.
enum ShortcutValidator {
    /// Who else reacts to a combination Keyboard Settings can't turn off.
    enum Owner: Sendable { case macOS, apps }

    /// Combinations macOS or apps always react to. Not exhaustive. Those Keyboard Settings can turn off are
    /// `SystemSymbolicHotKeys` and warn only while they are on (⌘Space, ⌃Space, screenshots, …).
    static let fixedShortcuts: [(shortcut: Shortcut, owner: Owner, purpose: String)] = {
        func combo(_ modifiers: [Shortcut.Modifier], _ key: Int) -> Shortcut {
            Shortcut(modifiers: modifiers.map { .init($0) }, keyCode: UInt16(key))
        }
        return [
            (combo([.command], kVK_Tab), .macOS, "the app switcher"),
            (combo([.control, .command], kVK_Space), .macOS, "Emoji & Symbols"),
            (combo([.option, .command], kVK_Escape), .macOS, "Force Quit"),
            (combo([.control, .command], kVK_ANSI_Q), .macOS, "locking the screen"),
            (combo([.function], kVK_ANSI_E), .macOS, "Emoji & Symbols"),
            (combo([.function], kVK_ANSI_F), .macOS, "full screen"),
            (combo([.function], kVK_ANSI_Q), .macOS, "Quick Note"),
            (combo([.function], kVK_ANSI_N), .macOS, "Notification Center"),
            (combo([.function], kVK_ANSI_C), .macOS, "Control Center"),
            (combo([.function], kVK_ANSI_A), .macOS, "the Dock"),
            (combo([.command], kVK_ANSI_Q), .apps, "Quit"),
            (combo([.command], kVK_ANSI_W), .apps, "Close Window"),
            (combo([.command], kVK_ANSI_H), .apps, "Hide"),
            (combo([.command], kVK_ANSI_M), .apps, "Minimize"),
            (combo([.command], kVK_ANSI_C), .apps, "Copy"),
            (combo([.command], kVK_ANSI_V), .apps, "Paste"),
            (combo([.command], kVK_ANSI_X), .apps, "Cut"),
            (combo([.command], kVK_ANSI_Z), .apps, "Undo"),
            (combo([.command], kVK_ANSI_A), .apps, "Select All"),
            (combo([.command], kVK_ANSI_S), .apps, "Save"),
        ]
    }()

    /// `bindings` supplies the other actions for duplicate detection; `system` decides which warnings apply.
    static func validate(_ s: Shortcut, for action: ShortcutAction, bindings: ShortcutBindings = .defaults,
                         system: SystemKeyboardState = .current) -> ShortcutValidation {
        var v = ShortcutValidation()
        if s.isEmpty {
            v.errors.append("Press a key or a key combination.")
            return v
        }
        v.warnings = warnings(for: s, action: action, system: system)

        if let other = bindings.conflict(for: s, excluding: action) {
            v.conflict = other
            v.errors.append("Already used for \(other.title.lowercased()).")
        } else if let clash = bindings.prefixClash(for: s, as: action), let theirs = bindings[clash.other] {
            // The PTT modifiers being a prefix of the hands-free chord is intended (fn / fn+Space).
            let name = "\(clash.other.title.lowercased()) (\(theirs.compactDescription))"
            v.errors.append(clash.isShorter
                ? "This is part of \(name) and would go off every time you press that."
                : "This starts with \(name), which would go off first.")
        }
        return v
    }

    /// Everything that may get in the way, most specific first. The router swallows a bound key everywhere
    /// (Esc for cancel only while busy), so "apps won't get it" is literal.
    static func warnings(for s: Shortcut, action: ShortcutAction, system: SystemKeyboardState) -> [ShortcutWarning] {
        var out: [ShortcutWarning] = []
        let mods = Set(s.modifiers.map(\.modifier))
        let combo = s.compactDescription
        let appsLoseIt = "Apps won’t get \(combo) while it’s bound here."

        if let hotKey = system.hotKeys.first(where: { $0.matches(s) }) {
            let text = hotKey.purpose.map { "macOS also uses \(combo) for \($0)." }
                ?? "macOS also uses \(combo) for a shortcut in Keyboard Settings."
            out.append(ShortcutWarning(.systemShortcut, text,
                                       detail: "Turn it off in Keyboard Settings › Keyboard Shortcuts if you don’t use it."))
        } else if let fixed = fixedShortcuts.first(where: { $0.shortcut.keyCode == s.keyCode && $0.shortcut.modifiers == s.modifiers }) {
            switch fixed.owner {
            case .macOS:
                out.append(ShortcutWarning(.systemShortcut, "macOS also uses \(combo) for \(fixed.purpose)."))
            case .apps:
                out.append(ShortcutWarning(.systemShortcut, "Apps use \(combo) for \(fixed.purpose).", detail: appsLoseIt))
            }
        } else if let key = s.keyCode, s.modifiers == [.init(.command)], KeyNames.isCharacterKey(key) {
            out.append(ShortcutWarning(.systemShortcut, "Apps often use \(combo) for their own commands.", detail: appsLoseIt))
        }

        if let key = s.keyCode {
            let typesText = mods.isDisjoint(with: [.control, .command, .function])
            if key == KeyCode.escape {
                if mods.isEmpty && action != .cancel {
                    out.append(ShortcutWarning(.escape, "Apps won’t get Esc while it’s bound here."))
                }
            } else if typesText && !KeyNames.functionKeys.contains(key) {
                out.append(ShortcutWarning(.typing, "This will fire while you type.", detail: appsLoseIt))
            }
            if KeyNames.mediaFunctionKeys.contains(key), !mods.contains(.function), !system.functionKeysAreStandard {
                out.append(ShortcutWarning(.mediaKey, "On Apple keyboards \(KeyNames.name(for: key)) is a media key.",
                                           detail: "Turn on “Use F1, F2, etc. keys as standard function keys” in Keyboard Settings."))
            }
        } else if s.modifiers.count == 1, let only = s.modifiers.first {
            switch (only.modifier, only.side) {
            case (.shift, _):
                out.append(ShortcutWarning(.typing, "⇧ alone is pressed all the time while typing."))
            case (.command, .either), (.command, .left):
                out.append(ShortcutWarning(.loneModifier, "⌘ alone is part of most shortcuts.",
                                           detail: "Right ⌘ is rarely used and works better."))
            case (.option, .either), (.option, .left):
                out.append(ShortcutWarning(.loneModifier, "⌥ alone types special characters.",
                                           detail: "Right ⌥ works better."))
            case (.control, .either), (.control, .left):
                out.append(ShortcutWarning(.loneModifier, "⌃ alone is common in terminals and editors.",
                                           detail: "Right ⌃ or fn works better."))
            default:
                break
            }
        }

        if s.isModifierOnly && mods.contains(.function) {
            out.append(contentsOf: FnKeyAdvisor.warnings(for: system.fnUsage))
        }
        return out
    }
}

/// Keyboard Settings › Keyboard Shortcuts, from ~/Library/Preferences/com.apple.symbolichotkeys.plist.
/// Undocumented format: `AppleSymbolicHotKeys` maps an id to `enabled` and `value.parameters` =
/// [character, virtual key code, NSEvent-style modifier mask], 65535 = none. An id the plist doesn't list,
/// or lists as on without a value, uses its macOS default.
enum SystemSymbolicHotKeys {
    struct HotKey: Equatable, Sendable {
        var id: Int
        var keyCode: UInt16
        /// ⇧⌃⌥⌘ plus the function bit, which macOS stores for arrows and F-keys (and for fn combos).
        var modifierMask: UInt64

        init(id: Int, keyCode: UInt16, modifierMask: UInt64) {
            self.id = id
            self.keyCode = keyCode
            self.modifierMask = modifierMask & SystemSymbolicHotKeys.relevantMask
        }

        /// What it does, for "macOS also uses ⌃Space for input sources."; nil for ids we don't know.
        var purpose: String? { SystemSymbolicHotKeys.purpose(of: id) }

        func matches(_ s: Shortcut) -> Bool {
            s.keyCode == keyCode && SystemSymbolicHotKeys.modifierMask(for: s) == modifierMask
        }
    }

    private static let shift = CGEventFlags.maskShift.rawValue
    private static let control = CGEventFlags.maskControl.rawValue
    private static let option = CGEventFlags.maskAlternate.rawValue
    private static let command = CGEventFlags.maskCommand.rawValue
    private static let function = CGEventFlags.maskSecondaryFn.rawValue
    static let relevantMask = shift | control | option | command | function

    /// macOS defaults (all on out of the box) for the ids that commonly meet a dictation shortcut.
    static let defaults: [HotKey] = [
        HotKey(id: 27, keyCode: UInt16(kVK_ANSI_Grave), modifierMask: command),
        HotKey(id: 28, keyCode: UInt16(kVK_ANSI_3), modifierMask: shift | command),
        HotKey(id: 29, keyCode: UInt16(kVK_ANSI_3), modifierMask: shift | control | command),
        HotKey(id: 30, keyCode: UInt16(kVK_ANSI_4), modifierMask: shift | command),
        HotKey(id: 31, keyCode: UInt16(kVK_ANSI_4), modifierMask: shift | control | command),
        HotKey(id: 32, keyCode: UInt16(kVK_UpArrow), modifierMask: control | function),
        HotKey(id: 33, keyCode: UInt16(kVK_DownArrow), modifierMask: control | function),
        HotKey(id: 36, keyCode: UInt16(kVK_F11), modifierMask: function),
        HotKey(id: 52, keyCode: UInt16(kVK_ANSI_D), modifierMask: option | command),
        HotKey(id: 60, keyCode: UInt16(kVK_Space), modifierMask: control),
        HotKey(id: 61, keyCode: UInt16(kVK_Space), modifierMask: control | option),
        HotKey(id: 64, keyCode: UInt16(kVK_Space), modifierMask: command),
        HotKey(id: 65, keyCode: UInt16(kVK_Space), modifierMask: option | command),
        HotKey(id: 79, keyCode: UInt16(kVK_LeftArrow), modifierMask: control | function),
        HotKey(id: 81, keyCode: UInt16(kVK_RightArrow), modifierMask: control | function),
        HotKey(id: 98, keyCode: UInt16(kVK_ANSI_Slash), modifierMask: shift | command),
        HotKey(id: 184, keyCode: UInt16(kVK_ANSI_5), modifierMask: shift | command),
    ]

    static func purpose(of id: Int) -> String? {
        switch id {
        case 7...13, 57: "keyboard navigation"
        case 27: "switching windows"
        case 28...31, 184: "screenshots"
        case 32: "Mission Control"
        case 33: "app windows"
        case 36: "Show Desktop"
        case 52: "hiding the Dock"
        case 59: "VoiceOver"
        case 60, 61: "input sources"
        case 64: "Spotlight"
        case 65: "Finder search"
        case 79...82, 118...133: "switching Spaces"
        case 98: "the Help menu"
        default: nil
        }
    }

    /// The `AppleSymbolicHotKeys` dictionary; nil when it can't be read (then every default applies).
    static func readPreferences() -> [String: Any]? {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any]
    }

    /// The hot keys that are on, from `preferences` laid over the macOS defaults, in id order.
    static func active(in preferences: [String: Any]?) -> [HotKey] {
        var result: [HotKey] = []
        var listed = Set<Int>()
        for (key, value) in preferences ?? [:] {
            guard let id = Int(key), let entry = value as? [String: Any] else { continue }
            listed.insert(id)
            guard bool(entry["enabled"]) == true else { continue }
            let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int]
            if let parameters, parameters.count >= 3 {
                let code = parameters[1]
                guard code != 65535, (0...Int(UInt16.max)).contains(code) else { continue }
                result.append(HotKey(id: id, keyCode: UInt16(code), modifierMask: UInt64(truncatingIfNeeded: parameters[2])))
            } else if let fallback = defaults.first(where: { $0.id == id }) {
                result.append(fallback)
            }
        }
        result += defaults.filter { !listed.contains($0.id) }
        return result.sorted { $0.id < $1.id }
    }

    /// The mask macOS would store for `s`: the function bit comes with fn itself and with the keys that
    /// always report it (arrows, F-keys, navigation keys).
    static func modifierMask(for s: Shortcut) -> UInt64 {
        var mask: UInt64 = 0
        for key in s.modifiers {
            switch key.modifier {
            case .shift: mask |= shift
            case .control: mask |= control
            case .option: mask |= option
            case .command: mask |= command
            case .function: mask |= function
            }
        }
        if let code = s.keyCode, KeyNames.fnFlaggedKeys.contains(code) { mask |= function }
        return mask
    }

    /// Settings written by different macOS versions store `enabled` as a boolean or as 0/1.
    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool: b
        case let n as NSNumber: n.boolValue
        case let i as Int: i != 0
        default: nil
        }
    }
}

/// Globe/Fn key system behavior (com.apple.HIToolbox AppleFnUsageType) and the F-key mode.
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

    /// "Use F1, F2, etc. keys as standard function keys" (global com.apple.keyboard.fnState, off by default).
    static var functionKeysAreStandard: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return CFPreferencesCopyAppValue("com.apple.keyboard.fnState" as CFString, kCFPreferencesAnyApplication)
            as? Bool ?? false
    }

    /// For a binding that is fn on its own (or fn with other modifiers): what else pressing fn does.
    static func warnings(for usage: Usage?) -> [ShortcutWarning] {
        let fix = "Set “Press 🌐 key to” to Do Nothing in Keyboard Settings."
        switch usage {
        case .doNothing?:
            return []
        case .changeInputSource?:
            return [ShortcutWarning(.globeKey, "The 🌐 key also switches input sources.", detail: fix)]
        case .showEmojiAndSymbols?, nil:
            return [ShortcutWarning(.globeKey, "The 🌐 key may also open Emoji & Symbols.", detail: fix)]
        case .startDictation?:
            return [ShortcutWarning(.globeKey, "Pressing 🌐 twice may also start Apple Dictation.", detail: fix)]
        }
    }
}
