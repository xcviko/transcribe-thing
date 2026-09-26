import CoreGraphics
import Foundation

/// A keyboard or mouse event reduced to what `HotkeyRouter` needs, so the decision logic runs without CGEvents.
struct HotkeyInput: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case flagsChanged, keyDown, keyUp, mouseDown }

    var kind: Kind
    var keyCode: UInt16
    /// Raw `CGEventFlags` bits, including the device-dependent left/right bits.
    var flags: UInt64
    var isRepeat: Bool
    /// Posted by transcribe-thing itself (the synthetic ⌘V); ignored entirely.
    var isSynthetic: Bool

    init(kind: Kind, keyCode: UInt16 = 0, flags: UInt64 = 0, isRepeat: Bool = false, isSynthetic: Bool = false) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
        self.isRepeat = isRepeat
        self.isSynthetic = isSynthetic
    }
}

/// Pure, dictation-agnostic hotkey recognizer. It only recognizes key gestures and decides which events
/// to swallow; what a gesture means for recording lives in `DictationMachine`.
///
/// Rules (SPEC §5.3, macos-input.md §4):
/// - Modifier events are never swallowed.
/// - Fn goes down only on flagsChanged with keycode 63: arrows, F-keys and navigation keys carry
///   `.maskSecondaryFn` without Fn being held. Its absence is not ambiguous, though: Fn held puts the bit
///   on every keyboard event, so an event without it means Fn is up even if its release never arrived.
/// - A modifier-only PTT arms on a key *press* that produces an exact match, never on the release of an
///   extra modifier (⌘ up while fn stays down after ⌘fnV must not start a dictation).
/// - Anything else while a modifier-only PTT is held interrupts it, and the PTT stays blocked until every
///   modifier is up. The interrupting key passes through, so ⌘C with a Right-⌘ PTT still copies.
/// - A key-based PTT (F13, ⌃⌥D) is not interrupted by other keys: it is unambiguous.
/// - Swallowed keys also have their autorepeats and keyUp swallowed.
struct HotkeyRouter: Equatable, Sendable {
    struct Config: Equatable, Sendable {
        var bindings: ShortcutBindings = .defaults
        /// Recording or transcribing: the cancel key is live (and swallowed) only then.
        var isBusy = false
        /// While the shortcut recorder captures keys: nothing fires and nothing is swallowed.
        var isSuspended = false
        /// Forward raw key transitions (onboarding keyboard illustration).
        var forwardsRawKeys = false
    }

    struct Decision: Equatable, Sendable {
        var events: [HotkeyEvent] = []
        var swallow = false
        var rawKey: RawKeyEvent?
    }

    enum Gesture: Equatable, Sendable {
        case idle
        case holdingModifiers
        case holdingKey(UInt16)
    }

    private(set) var gesture: Gesture = .idle
    private(set) var modifiers = ModifierSnapshot()
    private(set) var functionDown = false
    private(set) var blockedUntilModifiersReleased = false
    private(set) var swallowedKeys: Set<UInt16> = []
    /// Modifier-only bindings (other than PTT) that already fired during the current hold.
    private var firedModifierChords: Set<ShortcutAction> = []

    init() {}

    private static let functionMask = CGEventFlags.maskSecondaryFn.rawValue

    // MARK: Events

    mutating func handle(_ input: HotkeyInput, config: Config) -> Decision {
        if input.isSynthetic { return Decision() }
        switch input.kind {
        case .flagsChanged: return flagsChanged(input, config)
        case .keyDown: return keyDown(input, config)
        case .keyUp: return keyUp(input, config)
        case .mouseDown: return mouseDown(config)
        }
    }

    /// After the tap was re-enabled events may have been missed: rebuild modifier state from the session
    /// table and end a PTT whose key is no longer down. `isKeyDown` answers for a virtual key code.
    mutating func resynchronize(flags: UInt64, config: Config, isKeyDown: (UInt16) -> Bool) -> [HotkeyEvent] {
        functionDown = flags & Self.functionMask != 0
        modifiers = ModifierSnapshot(rawFlags: flags, functionDown: functionDown)
        swallowedKeys = swallowedKeys.filter(isKeyDown)
        firedModifierChords.removeAll()
        var events: [HotkeyEvent] = []
        switch gesture {
        case .idle:
            break
        case .holdingModifiers:
            if !(config.bindings[.pushToTalk]?.requiredModifiersHeld(modifiers) ?? false) {
                gesture = .idle
                events.append(.pttUp)
            }
        case .holdingKey(let key):
            if !isKeyDown(key) {
                gesture = .idle
                events.append(.pttUp)
            }
        }
        if modifiers.isEmpty { blockedUntilModifiersReleased = false }
        return events
    }

    /// The tap went away (stopped or permission revoked). A PTT in progress can never be released now.
    mutating func reset() -> [HotkeyEvent] {
        let wasHolding = gesture != .idle
        self = HotkeyRouter()
        return wasHolding ? [.pttInterrupted] : []
    }

    // MARK: flagsChanged

    private mutating func flagsChanged(_ input: HotkeyInput, _ config: Config) -> Decision {
        let previous = modifiers
        if input.keyCode == KeyCode.function || input.flags & Self.functionMask == 0 {
            functionDown = input.flags & Self.functionMask != 0
        }
        modifiers = ModifierSnapshot(rawFlags: input.flags, functionDown: functionDown)
        let isPress = Self.isPress(input, functionDown: functionDown,
                                   countWentUp: modifiers.count > previous.count)

        var decision = Decision()
        if config.forwardsRawKeys, modifiers != previous {
            decision.rawKey = Self.rawModifierEvent(keyCode: input.keyCode, modifiers: modifiers)
        }
        if modifiers.isEmpty { blockedUntilModifiersReleased = false }
        firedModifierChords = firedModifierChords.filter {
            config.bindings[$0]?.modifiersMatchExactly(modifiers) == true
        }
        if config.isSuspended {
            endGestureForSuspension(&decision)
            return decision
        }

        if isPress, let action = modifierChordMatch(config), !firedModifierChords.contains(action) {
            firedModifierChords.insert(action)
            fireChord(action, into: &decision)
            return decision
        }

        guard let ptt = config.bindings[.pushToTalk], ptt.isModifierOnly else { return decision }
        switch gesture {
        case .idle:
            if isPress, !blockedUntilModifiersReleased, ptt.modifiersMatchExactly(modifiers) {
                gesture = .holdingModifiers
                decision.events.append(.pttDown)
            }
        case .holdingModifiers:
            if ptt.modifiersMatchExactly(modifiers) { break }
            gesture = .idle
            if ptt.requiredModifiersHeld(modifiers) {
                blockedUntilModifiersReleased = true
                decision.events.append(.pttInterrupted)
            } else {
                decision.events.append(.pttUp)
            }
        case .holdingKey:
            break
        }
        return decision
    }

    /// A non-PTT binding that is modifier-only and matches the held set exactly.
    private func modifierChordMatch(_ config: Config) -> ShortcutAction? {
        let candidates: [ShortcutAction] = [.handsFree, .pasteLast, .copyLast, .cancel]
        return candidates.first { action in
            guard let shortcut = config.bindings[action], shortcut.isModifierOnly,
                  shortcut.modifiersMatchExactly(modifiers) else { return false }
            return action != .cancel || isBusy(config)
        }
    }

    // MARK: keyDown / keyUp

    private mutating func keyDown(_ input: HotkeyInput, _ config: Config) -> Decision {
        let key = input.keyCode
        // A fresh press of a key we think is still down means its keyUp was lost: evaluate it again.
        if !input.isRepeat { swallowedKeys.remove(key) }
        var decision = Decision()
        // Fn's release was lost if this key arrives without the Fn bit (see type docs): end the hold it
        // left behind before the key is matched with a phantom Fn (Space as fn+Space, ⌘V as ⌘fnV).
        let lostFunctionRelease = functionDown && input.flags & Self.functionMask == 0
        if lostFunctionRelease { functionDown = false }
        // Key events carry authoritative device bits; Fn keeps its tracked value (see type docs).
        modifiers = ModifierSnapshot(rawFlags: input.flags, functionDown: functionDown)
        if lostFunctionRelease {
            if modifiers.isEmpty { blockedUntilModifiersReleased = false }
            if gesture == .holdingModifiers, !(config.bindings[.pushToTalk]?.requiredModifiersHeld(modifiers) ?? false) {
                gesture = .idle
                decision.events.append(.pttUp)
            }
        }

        if config.forwardsRawKeys, !input.isRepeat, Self.isIllustrated(key, config) {
            decision.rawKey = RawKeyEvent(key: RawKeyEvent.Key(keyCode: key), isDown: true)
        }
        if swallowedKeys.contains(key) {
            decision.swallow = true
            return decision
        }
        if config.isSuspended {
            endGestureForSuspension(&decision)
            return decision
        }

        let bindings = config.bindings
        if isBusy(config), let cancel = bindings[.cancel], cancel.keyCode == key, cancelModifiersMatch(cancel, bindings) {
            consume(key, into: &decision)
            if !input.isRepeat { fireChord(.cancel, into: &decision) }
            return decision
        }
        if let handsFree = bindings[.handsFree], handsFree.matches(keyCode: key, modifiers: modifiers) {
            consume(key, into: &decision)
            if !input.isRepeat { fireChord(.handsFree, into: &decision) }
            return decision
        }
        for action in [ShortcutAction.pasteLast, .copyLast] {
            guard let shortcut = bindings[action], shortcut.matches(keyCode: key, modifiers: modifiers) else { continue }
            consume(key, into: &decision)
            if !input.isRepeat { fireChord(action, into: &decision) }
            return decision
        }
        if let ptt = bindings[.pushToTalk], ptt.keyCode == key, ptt.modifiersMatchExactly(modifiers) {
            consume(key, into: &decision)
            if !input.isRepeat, gesture == .idle {
                gesture = .holdingKey(key)
                decision.events.append(.pttDown)
            }
            return decision
        }

        if gesture == .holdingModifiers {
            gesture = .idle
            blockedUntilModifiersReleased = true
            decision.events.append(.pttInterrupted)
        }
        return decision
    }

    private mutating func keyUp(_ input: HotkeyInput, _ config: Config) -> Decision {
        let key = input.keyCode
        var decision = Decision()
        if config.forwardsRawKeys, Self.isIllustrated(key, config) {
            decision.rawKey = RawKeyEvent(key: RawKeyEvent.Key(keyCode: key), isDown: false)
        }
        guard swallowedKeys.remove(key) != nil else { return decision }
        decision.swallow = true
        if gesture == .holdingKey(key) {
            gesture = .idle
            decision.events.append(.pttUp)
        }
        return decision
    }

    private mutating func mouseDown(_ config: Config) -> Decision {
        var decision = Decision()
        guard !config.isSuspended else {
            endGestureForSuspension(&decision)
            return decision
        }
        // ⌘-click, ⌥-click, ⌃-click with a modifier-only PTT.
        if gesture == .holdingModifiers {
            gesture = .idle
            blockedUntilModifiersReleased = true
            decision.events.append(.pttInterrupted)
        }
        return decision
    }

    // MARK: Helpers

    /// Whether a flagsChanged is its key going down, read from that key's own bit in the new flags.
    /// Comparing with the previous snapshot goes wrong after a foreign synthetic keyDown (a clipboard
    /// manager's ⌘V) left `modifiers` holding a key that isn't down.
    private static func isPress(_ input: HotkeyInput, functionDown: Bool, countWentUp: Bool) -> Bool {
        let family: CGEventFlags, own: UInt64, other: UInt64
        switch input.keyCode {
        case KeyCode.function: return functionDown
        case KeyCode.command: (family, own, other) = (.maskCommand, DeviceModifierMask.leftCommand, DeviceModifierMask.rightCommand)
        case KeyCode.rightCommand: (family, own, other) = (.maskCommand, DeviceModifierMask.rightCommand, DeviceModifierMask.leftCommand)
        case KeyCode.option: (family, own, other) = (.maskAlternate, DeviceModifierMask.leftOption, DeviceModifierMask.rightOption)
        case KeyCode.rightOption: (family, own, other) = (.maskAlternate, DeviceModifierMask.rightOption, DeviceModifierMask.leftOption)
        case KeyCode.control: (family, own, other) = (.maskControl, DeviceModifierMask.leftControl, DeviceModifierMask.rightControl)
        case KeyCode.rightControl: (family, own, other) = (.maskControl, DeviceModifierMask.rightControl, DeviceModifierMask.leftControl)
        case KeyCode.shift: (family, own, other) = (.maskShift, DeviceModifierMask.leftShift, DeviceModifierMask.rightShift)
        case KeyCode.rightShift: (family, own, other) = (.maskShift, DeviceModifierMask.rightShift, DeviceModifierMask.leftShift)
        default: return countWentUp
        }
        let flags = input.flags
        guard flags & family.rawValue != 0 else { return false }
        if flags & own != 0 { return true }
        if flags & other != 0 { return false }
        // Only the family bit (some synthetic events): fall back to the count.
        return countWentUp
    }

    private func isBusy(_ config: Config) -> Bool {
        // A held PTT means a capture is starting even if the app hasn't reported busy yet.
        config.isBusy || gesture != .idle
    }

    private mutating func consume(_ key: UInt16, into decision: inout Decision) {
        swallowedKeys.insert(key)
        decision.swallow = true
    }

    /// Emits a non-PTT action and ends a PTT hold it interrupted. Hands-free wins over interruption:
    /// the machine turns the running PTT capture into a locked one.
    private mutating func fireChord(_ action: ShortcutAction, into decision: inout Decision) {
        let event: HotkeyEvent
        switch action {
        case .handsFree: event = .handsFreeToggle
        case .cancel: event = .cancel
        case .pasteLast: event = .pasteLast
        case .copyLast: event = .copyLast
        case .pushToTalk: return
        }
        if gesture != .idle, action == .pasteLast || action == .copyLast {
            decision.events.append(.pttInterrupted)
        }
        if gesture != .idle { gesture = .idle }
        blockedUntilModifiersReleased = !modifiers.isEmpty
        decision.events.append(event)
    }

    private mutating func endGestureForSuspension(_ decision: inout Decision) {
        guard gesture != .idle else { return }
        gesture = .idle
        blockedUntilModifiersReleased = !modifiers.isEmpty
        decision.events.append(.pttInterrupted)
    }

    /// Esc while fn is still held (PTT or the hands-free chord's modifier) is still a cancel.
    private func cancelModifiersMatch(_ cancel: Shortcut, _ bindings: ShortcutBindings) -> Bool {
        if cancel.modifiersMatchExactly(modifiers) { return true }
        var ignorable = Set<Shortcut.Modifier>()
        for action in [ShortcutAction.pushToTalk, .handsFree] {
            guard let shortcut = bindings[action], shortcut.requiredModifiersHeld(modifiers) else { continue }
            ignorable.formUnion(shortcut.modifiers.map(\.modifier))
        }
        ignorable.subtract(cancel.modifiers.map(\.modifier))
        guard !ignorable.isEmpty else { return false }
        return cancel.modifiersMatchExactly(modifiers.clearing(ignorable))
    }

    /// Space, Esc and any key used by a binding; other keystrokes never leave the tap thread.
    private static func isIllustrated(_ key: UInt16, _ config: Config) -> Bool {
        if key == KeyCode.space || key == KeyCode.escape { return true }
        return config.bindings.bindings.values.contains { $0.keyCode == key }
    }

    private static func rawModifierEvent(keyCode: UInt16, modifiers: ModifierSnapshot) -> RawKeyEvent? {
        let key = RawKeyEvent.Key(keyCode: keyCode)
        let isDown: Bool
        switch keyCode {
        case KeyCode.function: isDown = modifiers.function
        case KeyCode.command: isDown = modifiers.leftCommand
        case KeyCode.rightCommand: isDown = modifiers.rightCommand
        case KeyCode.option: isDown = modifiers.leftOption
        case KeyCode.rightOption: isDown = modifiers.rightOption
        case KeyCode.control: isDown = modifiers.leftControl
        case KeyCode.rightControl: isDown = modifiers.rightControl
        case KeyCode.shift: isDown = modifiers.leftShift
        case KeyCode.rightShift: isDown = modifiers.rightShift
        default: return nil
        }
        return RawKeyEvent(key: key, isDown: isDown)
    }
}

private extension ModifierSnapshot {
    func clearing(_ families: Set<Shortcut.Modifier>) -> ModifierSnapshot {
        var copy = self
        for family in families {
            switch family {
            case .function: copy.function = false
            case .control: copy.leftControl = false; copy.rightControl = false
            case .option: copy.leftOption = false; copy.rightOption = false
            case .shift: copy.leftShift = false; copy.rightShift = false
            case .command: copy.leftCommand = false; copy.rightCommand = false
            }
        }
        return copy
    }
}
