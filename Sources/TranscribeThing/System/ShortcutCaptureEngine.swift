import CoreGraphics
import Foundation

/// Pure capture rules for the shortcut recorder, fed with key codes and raw modifier flags
/// (`NSEvent.modifierFlags.rawValue` shares the NX_* bit layout with `CGEventFlags`, device bits included).
///
/// - Modifier-only: the largest set held during the gesture is committed once everything is released.
/// - Combination: committed on the first non-modifier keyDown, with the modifiers held at that moment.
/// - Bare Esc cancels recording, except for the cancel action, where Esc is the key being recorded.
/// - Bare ⌫ or ⌦ clears the binding for actions that may be left unbound.
struct ShortcutCaptureEngine: Equatable, Sendable {
    enum Result: Equatable, Sendable { case none, commit(Shortcut), cancel, clear }

    let action: ShortcutAction
    /// What is physically held right now, as the modifier-only shortcut it would become.
    private(set) var held: Shortcut?

    private var functionDown = false
    private var largest = ModifierSnapshot()

    init(action: ShortcutAction) {
        self.action = action
    }

    /// Actions that still work without a shortcut (pill click, menu bar).
    static func canClear(_ action: ShortcutAction) -> Bool {
        switch action {
        case .handsFree, .pasteLast: true
        case .pushToTalk, .cancel: false
        }
    }

    mutating func flagsChanged(keyCode: UInt16, rawFlags: UInt64) -> Result {
        if keyCode == KeyCode.function {
            functionDown = rawFlags & CGEventFlags.maskSecondaryFn.rawValue != 0
        }
        let snapshot = ModifierSnapshot(rawFlags: rawFlags, functionDown: functionDown)
        // Same size but different keys (Left ⌥ swapped for Right ⌥): the latest press wins.
        if snapshot.count >= largest.count, snapshot.count > 0 { largest = snapshot }
        held = snapshot.isEmpty ? nil : Shortcut(modifiers: Self.modifierOnlyKeys(snapshot))

        if snapshot.isEmpty, largest.count > 0 {
            let shortcut = Shortcut(modifiers: Self.modifierOnlyKeys(largest))
            reset()
            return .commit(shortcut)
        }
        return .none
    }

    mutating func keyDown(keyCode: UInt16, rawFlags: UInt64, isRepeat: Bool) -> Result {
        guard !isRepeat else { return .none }
        // Fn keeps its tracked value: arrows and F-keys report the Fn flag without Fn being held.
        let snapshot = ModifierSnapshot(rawFlags: rawFlags, functionDown: functionDown)
        if snapshot.isEmpty && keyCode == KeyCode.escape {
            reset()
            return action == .cancel ? .commit(.escape) : .cancel
        }
        if snapshot.isEmpty && (keyCode == KeyCode.delete || keyCode == KeyCode.forwardDelete) && Self.canClear(action) {
            reset()
            return .clear
        }
        let shortcut = Shortcut(modifiers: Self.comboKeys(snapshot), keyCode: keyCode)
        reset()
        return .commit(shortcut)
    }

    mutating func reset() {
        largest = ModifierSnapshot()
        held = nil
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
