import CoreGraphics
import Foundation

/// Pure capture rules for the shortcut recorder, fed with key codes and raw modifier flags
/// (`NSEvent.modifierFlags.rawValue` shares the NX_* bit layout with `CGEventFlags`, device bits included).
///
/// - Modifier-only: the largest set held during the gesture is committed once everything is released. Held longer
///   than `DoubleTap.maxHold`, at once; a quicker tap waits `DoubleTap.maxGap` for a second (`pendingTap`), and the
///   same keys pressed again in time commit the double tap on that press. Without one, `tapWindowEnded()` commits the
///   single press. Other keys pressed in the window start over: the latest gesture wins.
/// - Combination: committed on the first non-modifier keyDown, with the modifiers held at that moment.
/// - Bare Esc cancels recording.
/// - Bare ⌫ or ⌦ clears the binding for actions that may be left unbound.
struct ShortcutCaptureEngine: Equatable, Sendable {
    enum Result: Equatable, Sendable { case none, commit(Shortcut), cancel, clear }

    /// A quick tap of modifiers, let go, that may get a second.
    struct PendingTap: Equatable, Sendable {
        var keys: ModifierSnapshot
        var releasedAt: TimeInterval

        var shortcut: Shortcut { Shortcut(modifiers: ShortcutCaptureEngine.modifierOnlyKeys(keys)) }
    }

    let action: ShortcutAction
    /// What is physically held right now, as the modifier-only shortcut it would become; while a tap waits for its
    /// second, that tap.
    private(set) var held: Shortcut?
    /// Set when a quick tap was let go: the recorder calls `tapWindowEnded()` `DoubleTap.maxGap` later.
    private(set) var pendingTap: PendingTap?

    private var functionDown = false
    private var largest = ModifierSnapshot()
    /// When the modifier gesture in progress began (its first press); nil with nothing held.
    private var gestureStartedAt: TimeInterval?

    init(action: ShortcutAction) {
        self.action = action
    }

    /// Actions that still work without a shortcut (pill click, menu bar, the pill's model chip) or are optional.
    static func canClear(_ action: ShortcutAction) -> Bool {
        switch action {
        case .handsFree, .pasteLast, .switchModel, .polish, .addToDictionary, .translate: true
        case .pushToTalk: false
        }
    }

    /// `time`: when the change came, in seconds (`NSEvent.timestamp`).
    mutating func flagsChanged(keyCode: UInt16, rawFlags: UInt64, at time: TimeInterval) -> Result {
        if keyCode == KeyCode.function {
            functionDown = rawFlags & CGEventFlags.maskSecondaryFn.rawValue != 0
        }
        let snapshot = ModifierSnapshot(rawFlags: rawFlags, functionDown: functionDown)
        if gestureStartedAt == nil, !snapshot.isEmpty {
            gestureStartedAt = time
            // Its window ended before its timer came: that tap was a single press, and this one comes after it.
            if let tap = pendingTap, time - tap.releasedAt > DoubleTap.maxGap { return finish(.commit(tap.shortcut)) }
        }
        if let tap = pendingTap, !snapshot.isEmpty {
            if snapshot == tap.keys { return finish(.commit(tap.shortcut.doubleTap)) }
            // Keys the tap didn't have: something new. The same keys so far may still become its second tap.
            if !snapshot.isSubset(of: tap.keys) { pendingTap = nil }
        }
        // Same size but different keys (Left ⌥ swapped for Right ⌥): the latest press wins.
        if snapshot.count >= largest.count, snapshot.count > 0 { largest = snapshot }
        held = snapshot.isEmpty ? pendingTap?.shortcut : Shortcut(modifiers: Self.modifierOnlyKeys(snapshot))

        guard snapshot.isEmpty, largest.count > 0, let startedAt = gestureStartedAt else { return .none }
        let keys = largest
        largest = ModifierSnapshot()
        gestureStartedAt = nil
        guard time - startedAt < DoubleTap.maxHold else {
            return finish(.commit(Shortcut(modifiers: Self.modifierOnlyKeys(keys))))
        }
        // A quick tap: a second may follow.
        pendingTap = PendingTap(keys: keys, releasedAt: time)
        held = pendingTap?.shortcut
        return .none
    }

    /// `DoubleTap.maxGap` after `pendingTap` was let go without a second: it was a single press. While keys are down
    /// again (a chord's second tap on its way), the gesture decides.
    mutating func tapWindowEnded() -> Result {
        guard let tap = pendingTap, gestureStartedAt == nil else { return .none }
        return finish(.commit(tap.shortcut))
    }

    mutating func keyDown(keyCode: UInt16, rawFlags: UInt64, isRepeat: Bool) -> Result {
        guard !isRepeat else { return .none }
        // Fn keeps its tracked value: arrows and F-keys report the Fn flag without Fn being held.
        let snapshot = ModifierSnapshot(rawFlags: rawFlags, functionDown: functionDown)
        if snapshot.isEmpty && keyCode == KeyCode.escape {
            reset()
            return .cancel
        }
        if snapshot.isEmpty && (keyCode == KeyCode.delete || keyCode == KeyCode.forwardDelete) && Self.canClear(action) {
            reset()
            return .clear
        }
        // fn ↩ on a laptop keyboard arrives as Keypad Enter; `Shortcut` records it as fn ↩.
        let shortcut = Shortcut(modifiers: Self.comboKeys(snapshot), keyCode: keyCode)
        reset()
        return .commit(shortcut)
    }

    mutating func reset() {
        largest = ModifierSnapshot()
        held = nil
        pendingTap = nil
        gestureStartedAt = nil
    }

    private mutating func finish(_ result: Result) -> Result {
        reset()
        return result
    }

    /// Modifier-only shortcuts keep a Right-side key (Right ⌥ is the classic PTT); a left key means "either",
    /// so the shortcut works with whichever hand.
    static func modifierOnlyKeys(_ snapshot: ModifierSnapshot) -> [Shortcut.ModifierKey] {
        snapshot.asModifierKeys.map { key in
            key.side == .right ? key : Shortcut.ModifierKey(key.modifier, .either)
        }
    }

    /// Combinations ignore sides: ⌘V pressed with the right ⌘ is still ⌘V.
    static func comboKeys(_ snapshot: ModifierSnapshot) -> [Shortcut.ModifierKey] {
        snapshot.asModifierKeys.map { Shortcut.ModifierKey($0.modifier, .either) }
    }
}

/// What the recorder does with a captured shortcut: save it (maybe with a warning), offer Swap, or, when it
/// can't work (another action uses it or starts with it), keep the old one.
enum ShortcutEdit {
    enum Outcome: Equatable, Sendable {
        case unchanged
        /// Saved; `warning` is why it may get in the way.
        case apply(warning: ShortcutWarning?)
        case reject(String)
        /// Another action uses it and could take this action's current shortcut instead.
        case offerSwap(ShortcutAction)
    }

    /// `bindings` holds every action's saved shortcut; `swapAllowed` is false when the other binding can't be
    /// written (no settings) or this action has nothing to give back.
    static func evaluate(_ shortcut: Shortcut, for action: ShortcutAction, bindings: ShortcutBindings,
                         swapAllowed: Bool, system: SystemKeyboardState = .current) -> Outcome {
        guard shortcut != bindings[action] else { return .unchanged }
        let validation = ShortcutValidator.validate(shortcut, for: action, bindings: bindings, system: system)
        guard let other = validation.conflict else {
            if let error = validation.errors.first { return .reject(error) }
            return .apply(warning: validation.warnings.first)
        }
        // Validate again without the clashing binding to see whether anything else is wrong.
        var withoutOther = bindings
        withoutOther[other] = nil
        if let error = ShortcutValidator.validate(shortcut, for: action, bindings: withoutOther, system: system).errors.first {
            return .reject(error)
        }
        guard swapAllowed, let mine = bindings[action] else {
            return .reject("\(other.title) already uses this shortcut.")
        }
        var afterSwap = withoutOther
        afterSwap[action] = shortcut
        guard ShortcutValidator.validate(mine, for: other, bindings: afterSwap, system: system).errors.isEmpty else {
            return .reject("\(other.title) already uses this shortcut.")
        }
        return .offerSwap(other)
    }

    /// The warning to show once Swap is done: this action's new shortcut first, then the one `other` received.
    static func warningAfterSwap(_ swapped: ShortcutBindings, action: ShortcutAction, other: ShortcutAction,
                                 system: SystemKeyboardState = .current) -> ShortcutWarning? {
        for owner in [action, other] {
            guard let shortcut = swapped[owner] else { continue }
            if let warning = ShortcutValidator.validate(shortcut, for: owner, bindings: swapped, system: system).warnings.first {
                return warning
            }
        }
        return nil
    }

    /// A lone ⌘, ⌥ or ⌃ (either side, or the left one) gets in the way of typing; the right-hand key
    /// alone rarely does. Returns that right-hand binding, or nil when there is nothing better to offer.
    static func betterSide(for shortcut: Shortcut) -> Shortcut? {
        guard shortcut.keyCode == nil, shortcut.modifiers.count == 1, let only = shortcut.modifiers.first,
              [.command, .option, .control].contains(only.modifier), only.side != .right else { return nil }
        return Shortcut(modifiers: [.init(only.modifier, .right)])
    }

    /// The bindings after Swap: `action` takes `shortcut`, `other` takes what `action` had.
    static func swapping(_ bindings: ShortcutBindings, action: ShortcutAction, to shortcut: Shortcut,
                         with other: ShortcutAction) -> ShortcutBindings {
        var result = bindings
        result[other] = bindings[action]
        result[action] = shortcut
        return result
    }
}
