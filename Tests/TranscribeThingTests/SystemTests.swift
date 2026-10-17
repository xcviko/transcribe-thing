import AppKit
import Carbon.HIToolbox
import Foundation
import os
import Testing
@testable import TranscribeThing

// MARK: - Synthetic keyboard for the router

/// Drives `HotkeyRouter` with normalized key events the way the tap would see them: modifier transitions as
/// flagsChanged with device-dependent side bits, Fn tracked from keycode 63, keyDowns carrying the held flags.
private struct Keyboard {
    enum Modifier: CaseIterable {
        case fn, leftCommand, rightCommand, leftOption, rightOption, leftControl, rightControl, leftShift, rightShift

        var keyCode: UInt16 {
            switch self {
            case .fn: KeyCode.function
            case .leftCommand: KeyCode.command
            case .rightCommand: KeyCode.rightCommand
            case .leftOption: KeyCode.option
            case .rightOption: KeyCode.rightOption
            case .leftControl: KeyCode.control
            case .rightControl: KeyCode.rightControl
            case .leftShift: KeyCode.shift
            case .rightShift: KeyCode.rightShift
            }
        }

        var flags: UInt64 {
            switch self {
            case .fn: CGEventFlags.maskSecondaryFn.rawValue
            case .leftCommand: CGEventFlags.maskCommand.rawValue | DeviceModifierMask.leftCommand
            case .rightCommand: CGEventFlags.maskCommand.rawValue | DeviceModifierMask.rightCommand
            case .leftOption: CGEventFlags.maskAlternate.rawValue | DeviceModifierMask.leftOption
            case .rightOption: CGEventFlags.maskAlternate.rawValue | DeviceModifierMask.rightOption
            case .leftControl: CGEventFlags.maskControl.rawValue | DeviceModifierMask.leftControl
            case .rightControl: CGEventFlags.maskControl.rawValue | DeviceModifierMask.rightControl
            case .leftShift: CGEventFlags.maskShift.rawValue | DeviceModifierMask.leftShift
            case .rightShift: CGEventFlags.maskShift.rawValue | DeviceModifierMask.rightShift
            }
        }
    }

    var router = HotkeyRouter()
    var config = HotkeyRouter.Config()
    private(set) var held: Set<Modifier> = []

    init(bindings: ShortcutBindings = .defaults) {
        config.bindings = bindings
    }

    var flags: UInt64 { held.reduce(0) { $0 | $1.flags } }

    @discardableResult
    mutating func press(_ modifier: Modifier) -> HotkeyRouter.Decision {
        held.insert(modifier)
        return send(HotkeyInput(kind: .flagsChanged, keyCode: modifier.keyCode, flags: flags))
    }

    @discardableResult
    mutating func release(_ modifier: Modifier) -> HotkeyRouter.Decision {
        held.remove(modifier)
        // The family bit stays set while the other side is still down (real hardware behaves the same).
        return send(HotkeyInput(kind: .flagsChanged, keyCode: modifier.keyCode, flags: flags))
    }

    /// `fnFlagged`: arrows, F-keys and navigation keys report `.maskSecondaryFn` without Fn being held.
    @discardableResult
    mutating func down(_ key: Int, isRepeat: Bool = false, fnFlagged: Bool = false,
                       synthetic: Bool = false) -> HotkeyRouter.Decision {
        let extra = fnFlagged ? CGEventFlags.maskSecondaryFn.rawValue : 0
        return send(HotkeyInput(kind: .keyDown, keyCode: UInt16(key), flags: flags | extra,
                                isRepeat: isRepeat, isSynthetic: synthetic))
    }

    @discardableResult
    mutating func up(_ key: Int, fnFlagged: Bool = false) -> HotkeyRouter.Decision {
        let extra = fnFlagged ? CGEventFlags.maskSecondaryFn.rawValue : 0
        return send(HotkeyInput(kind: .keyUp, keyCode: UInt16(key), flags: flags | extra))
    }

    @discardableResult
    mutating func click() -> HotkeyRouter.Decision {
        send(HotkeyInput(kind: .mouseDown, flags: flags))
    }

    mutating func send(_ input: HotkeyInput) -> HotkeyRouter.Decision {
        router.handle(input, config: config)
    }
}

private func bindings(_ changes: [ShortcutAction: Shortcut?]) -> ShortcutBindings {
    var result = ShortcutBindings.defaults
    for (action, shortcut) in changes { result[action] = shortcut }
    return result
}

// MARK: - HotkeyRouter

@Suite struct HotkeyRouterTests {
    @Test func fnHoldAndReleaseIsPushToTalk() {
        var kb = Keyboard()
        let down = kb.press(.fn)
        #expect(down.events == [.pttDown])
        #expect(!down.swallow)
        let up = kb.release(.fn)
        #expect(up.events == [.pttUp])
        #expect(!up.swallow)
    }

    @Test func quickFnTapStillReportsDownAndUp() {
        // Tap vs hold is timing, which belongs to DictationMachine.
        var kb = Keyboard()
        #expect(kb.press(.fn).events == [.pttDown])
        #expect(kb.release(.fn).events == [.pttUp])
        #expect(kb.press(.fn).events == [.pttDown])
        #expect(kb.release(.fn).events == [.pttUp])
    }

    @Test func fnSpaceFromIdleStartsHandsFreeAndSwallowsSpace() {
        var kb = Keyboard()
        #expect(kb.press(.fn).events == [.pttDown])
        let space = kb.down(kVK_Space)
        #expect(space.events == [.handsFreeToggle])
        #expect(space.swallow)
        let repeated = kb.down(kVK_Space, isRepeat: true)
        #expect(repeated.events.isEmpty)
        #expect(repeated.swallow)
        let spaceUp = kb.up(kVK_Space)
        #expect(spaceUp.events.isEmpty)
        #expect(spaceUp.swallow)
        // Releasing the fn that locked it is not a push-to-talk release.
        #expect(kb.release(.fn).events.isEmpty)
    }

    /// A combination macOS also listens to (input sources) works like any other once it's bound: the session
    /// tap sees the chord key first and swallows it.
    @Test func controlSpaceAsHandsFreeFiresAndSwallowsSpace() {
        var kb = Keyboard(bindings: bindings([.handsFree: Shortcut(modifiers: [.init(.control)], keyCode: KeyCode.space)]))
        #expect(kb.press(.leftControl).events.isEmpty)
        let space = kb.down(kVK_Space)
        #expect(space.events == [.handsFreeToggle])
        #expect(space.swallow)
        let repeated = kb.down(kVK_Space, isRepeat: true)
        #expect(repeated.events.isEmpty)
        #expect(repeated.swallow)
        #expect(kb.up(kVK_Space).swallow)
        #expect(kb.release(.leftControl).events.isEmpty)
        // Combinations ignore sides: Right ⌃ Space fires it again.
        kb.press(.rightControl)
        #expect(kb.down(kVK_Space).events == [.handsFreeToggle])
        kb.up(kVK_Space)
        kb.release(.rightControl)
        // A plain Space still types, and fn Space is no longer hands-free.
        let plain = kb.down(kVK_Space)
        #expect(plain.events.isEmpty)
        #expect(!plain.swallow)
        kb.up(kVK_Space)
        #expect(kb.press(.fn).events == [.pttDown])
        let fnSpace = kb.down(kVK_Space)
        #expect(fnSpace.events == [.pttInterrupted])
        #expect(!fnSpace.swallow)
    }

    @Test func commandSpaceAsPushToTalkHoldsUntilSpaceIsReleased() {
        var kb = Keyboard(bindings: bindings([.pushToTalk: Shortcut(modifiers: [.init(.command)], keyCode: KeyCode.space)]))
        #expect(kb.press(.leftCommand).events.isEmpty)
        let down = kb.down(kVK_Space)
        #expect(down.events == [.pttDown])
        #expect(down.swallow)
        let repeated = kb.down(kVK_Space, isRepeat: true)
        #expect(repeated.events.isEmpty)
        #expect(repeated.swallow)
        // Letting go of ⌘ first doesn't end it; Space does.
        #expect(kb.release(.leftCommand).events.isEmpty)
        #expect(kb.down(kVK_Space, isRepeat: true).swallow)
        let up = kb.up(kVK_Space)
        #expect(up.events == [.pttUp])
        #expect(up.swallow)
        // Other ⌘ shortcuts pass through, and it works again.
        kb.press(.leftCommand)
        let copy = kb.down(kVK_ANSI_C)
        #expect(copy.events.isEmpty)
        #expect(!copy.swallow)
        kb.up(kVK_ANSI_C)
        #expect(kb.down(kVK_Space).events == [.pttDown])
        kb.release(.leftCommand)
        #expect(kb.up(kVK_Space).events == [.pttUp])
    }

    @Test func spaceWhileHoldingFnFiresAgainWithoutReleasingFn() {
        var kb = Keyboard()
        kb.press(.fn)
        #expect(kb.down(kVK_Space).events == [.handsFreeToggle])
        kb.up(kVK_Space)
        // Still holding fn: a second Space is the chord again (which the machine ignores while hands-free).
        let again = kb.down(kVK_Space)
        #expect(again.events == [.handsFreeToggle])
        #expect(again.swallow)
        kb.up(kVK_Space)
        #expect(kb.release(.fn).events.isEmpty)
        // Fully released: fn works as push to talk again.
        #expect(kb.press(.fn).events == [.pttDown])
    }

    /// While hands-free records, the chord does nothing (the machine ignores it) but never reaches the app underneath,
    /// and releasing the fn it was pressed with is no push-to-talk release, which would finish the recording.
    @Test(arguments: [Shortcut.fnSpace, Shortcut(modifiers: [.init(.control), .init(.option)], keyCode: KeyCode.space)])
    func theHandsFreeChordIsSwallowedDuringARecording(_ handsFree: Shortcut) {
        var kb = Keyboard(bindings: bindings([.handsFree: handsFree]))
        kb.config.isRecording = true
        kb.config.isBusy = true
        let modifiers: [Keyboard.Modifier] = handsFree == .fnSpace ? [.fn] : [.leftControl, .leftOption]
        for modifier in modifiers { kb.press(modifier) }
        let space = kb.down(kVK_Space)
        #expect(space.events == [.handsFreeToggle])
        #expect(space.swallow)
        #expect(kb.down(kVK_Space, isRepeat: true).swallow)
        #expect(kb.up(kVK_Space).swallow)
        for modifier in modifiers { #expect(kb.release(modifier).events.isEmpty) }
    }

    @Test func fnArrowInterruptsAndTheArrowPassesThrough() {
        var kb = Keyboard()
        kb.press(.fn)
        let arrow = kb.down(kVK_LeftArrow, fnFlagged: true)
        #expect(arrow.events == [.pttInterrupted])
        #expect(!arrow.swallow)
        #expect(!kb.up(kVK_LeftArrow, fnFlagged: true).swallow)
        #expect(kb.release(.fn).events.isEmpty)
        #expect(kb.press(.fn).events == [.pttDown])
    }

    @Test func fnThenShiftInterruptsAndBlocksUntilEverythingIsReleased() {
        var kb = Keyboard()
        #expect(kb.press(.fn).events == [.pttDown])
        #expect(kb.press(.leftShift).events == [.pttInterrupted])
        // fn alone is held again, but that came from a release: no re-arm.
        #expect(kb.release(.leftShift).events.isEmpty)
        #expect(kb.release(.fn).events.isEmpty)
        #expect(kb.press(.fn).events == [.pttDown])
    }

    /// While dictating, fn P is Polish, swallowed, and the hold goes on.
    @Test func thePolishKeyWhileHoldingTheKey() {
        var kb = Keyboard()
        #expect(ShortcutBindings.defaults[.polish] == .fnP)
        #expect(kb.press(.fn).events == [.pttDown])
        let polish = kb.down(kVK_ANSI_P, fnFlagged: true)
        #expect(polish.events == [.polish] && polish.swallow)
        // Held down, its autorepeats turn Polish on and off on Gemini (`polishRepeat`).
        #expect(kb.down(kVK_ANSI_P, isRepeat: true, fnFlagged: true).events == [.polishRepeat])
        #expect(kb.down(kVK_ANSI_P, isRepeat: true, fnFlagged: true).events == [.polishRepeat])
        #expect(kb.up(kVK_ANSI_P, fnFlagged: true).swallow)
        #expect(kb.release(.fn).events == [.pttUp], "still the dictation's hold")
        // With fn up, P is P.
        let plain = kb.down(kVK_ANSI_P, fnFlagged: false)
        #expect(plain.events.isEmpty && !plain.swallow)
    }

    /// The polish key is the tap's during any dictation, Gemini or not (the controller says what it does there): the
    /// hold goes on. Outside a dictation, P is P.
    @Test func thePolishKeyIsTakenOnAnyModel() {
        var kb = Keyboard()
        #expect(kb.press(.fn).events == [.pttDown])
        let polish = kb.down(kVK_ANSI_P, fnFlagged: true)
        #expect(polish.events == [.polish] && polish.swallow)
        kb.up(kVK_ANSI_P, fnFlagged: true)
        #expect(kb.release(.fn).events == [.pttUp])
        #expect(!kb.down(kVK_ANSI_P).swallow)
    }

    /// A laptop keyboard sends fn ↩ as Keypad Enter: bound to fn ↩ (Polish's old default), it's Polish all the same,
    /// in hands-free too, and recording it in Shortcuts gives fn ↩.
    @Test func fnReturnArrivesAsKeypadEnter() {
        var kb = Keyboard(bindings: bindings([.polish: .fnReturn]))
        #expect(kb.press(.fn).events == [.pttDown])
        let enter = kb.down(kVK_ANSI_KeypadEnter, fnFlagged: true)
        #expect(enter.events == [.polish] && enter.swallow)
        #expect(kb.up(kVK_ANSI_KeypadEnter, fnFlagged: true).swallow)
        #expect(kb.release(.fn).events == [.pttUp])

        // Hands-free: fn's release before Enter's still leaves Enter's keyUp swallowed (it's the same key).
        kb.config.isRecording = true
        kb.press(.fn)
        #expect(kb.down(kVK_ANSI_KeypadEnter, fnFlagged: true).events == [.polish])
        kb.release(.fn)
        #expect(kb.up(kVK_ANSI_KeypadEnter).swallow, "no stray keyUp reaches the app")

        var capture = ShortcutCaptureEngine(action: .polish)
        _ = capture.flagsChanged(keyCode: KeyCode.function, rawFlags: CGEventFlags.maskSecondaryFn.rawValue)
        let recorded = capture.keyDown(keyCode: UInt16(kVK_ANSI_KeypadEnter),
                                       rawFlags: CGEventFlags.maskSecondaryFn.rawValue, isRepeat: false)
        #expect(recorded == .commit(.fnReturn))
    }

    /// With Polish Selection's card up, ↩ pastes it and Esc closes it, swallowed. ⌘↩ stays the app's, ↩ goes to the app
    /// while a dictation records, and Esc cancels a busy dictation first.
    @Test func theCardTakesReturnAndEscape() {
        var kb = Keyboard()
        kb.config.cardPaste = true
        kb.config.cardClose = true
        let paste = kb.down(kVK_Return)
        #expect(paste.events == [.cardPaste] && paste.swallow)
        #expect(kb.down(kVK_Return, isRepeat: true).events.isEmpty, "one paste per press")
        #expect(kb.up(kVK_Return).swallow)
        let close = kb.down(kVK_Escape)
        #expect(close.events == [.cardClose] && close.swallow)
        kb.up(kVK_Escape)
        kb.press(.leftCommand)
        #expect(!kb.down(kVK_Return).swallow)
        kb.up(kVK_Return)
        kb.release(.leftCommand)
        kb.config.isRecording = true
        kb.config.isBusy = true
        #expect(!kb.down(kVK_Return).swallow)
        kb.up(kVK_Return)
        #expect(kb.down(kVK_Escape).events == [.cancel])
        kb.up(kVK_Escape)
        kb.config = HotkeyRouter.Config()
        kb.config.cardClose = true
        #expect(!kb.down(kVK_Return).swallow, "an answer was copied: ↩ is the app's again")
        kb.up(kVK_Return)
        #expect(kb.down(kVK_Escape).events == [.cardClose])
    }

    /// A key the user bound themselves stays theirs while a card is up: bare Keypad Enter for Paste Last.
    @Test func theCardsKeysYieldToTheUsersBindings() {
        let keypadEnter = Shortcut(modifiers: [], keyCode: UInt16(kVK_ANSI_KeypadEnter))
        var kb = Keyboard(bindings: bindings([.pasteLast: keypadEnter]))
        kb.config.cardPaste = true
        kb.config.cardClose = true
        #expect(kb.down(kVK_ANSI_KeypadEnter).events == [.pasteLast])
        kb.up(kVK_ANSI_KeypadEnter)
        #expect(kb.down(kVK_Return).events == [.cardPaste])
    }

    /// The keypad's own Enter, without fn, stays a key of its own: a shortcut on it fires on it and not on Return,
    /// and recording it in Shortcuts gives Keypad Enter.
    @Test func keypadEnterWithoutFnIsItsOwnKey() {
        let keypadEnter = Shortcut(modifiers: [], keyCode: UInt16(kVK_ANSI_KeypadEnter))
        var kb = Keyboard(bindings: bindings([.pasteLast: keypadEnter]))
        let enter = kb.down(kVK_ANSI_KeypadEnter)
        #expect(enter.events == [.pasteLast] && enter.swallow)
        #expect(kb.up(kVK_ANSI_KeypadEnter).swallow)
        let returnKey = kb.down(kVK_Return)
        #expect(returnKey.events.isEmpty && !returnKey.swallow)

        var capture = ShortcutCaptureEngine(action: .pasteLast)
        #expect(capture.keyDown(keyCode: UInt16(kVK_ANSI_KeypadEnter), rawFlags: 0, isRepeat: false)
                == .commit(keypadEnter))
    }

    @Test func shiftThenFnNeverTriggers() {
        var kb = Keyboard()
        #expect(kb.press(.leftShift).events.isEmpty)
        #expect(kb.press(.fn).events.isEmpty)
        #expect(kb.release(.leftShift).events.isEmpty)
        #expect(kb.release(.fn).events.isEmpty)
    }

    @Test func commandFnVPastesLastWithoutStartingADictation() {
        var kb = Keyboard()
        #expect(kb.press(.leftCommand).events.isEmpty)
        #expect(kb.press(.fn).events.isEmpty)
        let v = kb.down(kVK_ANSI_V)
        #expect(v.events == [.pasteLast])
        #expect(v.swallow)
        #expect(kb.down(kVK_ANSI_V, isRepeat: true).events.isEmpty)
        #expect(kb.up(kVK_ANSI_V).swallow)
        // ⌘ up leaves fn alone held: a release, so it must not arm push to talk.
        #expect(kb.release(.leftCommand).events.isEmpty)
        #expect(kb.release(.fn).events.isEmpty)
    }

    @Test func fnFirstThenCommandVInterruptsThenPastes() {
        var kb = Keyboard()
        #expect(kb.press(.fn).events == [.pttDown])
        #expect(kb.press(.leftCommand).events == [.pttInterrupted])
        let v = kb.down(kVK_ANSI_V)
        #expect(v.events == [.pasteLast])
        #expect(v.swallow)
    }

    @Test func plainCommandVIsNotOurs() {
        var kb = Keyboard()
        kb.press(.leftCommand)
        let v = kb.down(kVK_ANSI_V)
        #expect(v.events.isEmpty)
        #expect(!v.swallow)
    }

    @Test func aSidedKeyShortcutNeedsItsSide() {
        var bindings = ShortcutBindings.defaults
        bindings[.pasteLast] = Shortcut(modifiers: [.init(.command), .init(.control, .left)], keyCode: KeyCode.ansiC)
        var kb = Keyboard(bindings: bindings)
        kb.press(.leftControl)
        kb.press(.leftCommand)
        let c = kb.down(kVK_ANSI_C)
        #expect(c.events == [.pasteLast])
        #expect(c.swallow)
        kb.up(kVK_ANSI_C)
        kb.release(.leftControl)
        kb.press(.rightControl)
        let rightC = kb.down(kVK_ANSI_C)
        #expect(rightC.events.isEmpty)
        #expect(!rightC.swallow)
    }

    @Test func escapeIsOnlyCanceledAndSwallowedWhileBusy() {
        var kb = Keyboard()
        let idle = kb.down(kVK_Escape)
        #expect(idle.events.isEmpty)
        #expect(!idle.swallow)
        #expect(!kb.up(kVK_Escape).swallow)

        kb.config.isBusy = true
        let busy = kb.down(kVK_Escape)
        #expect(busy.events == [.cancel])
        #expect(busy.swallow)
        let repeated = kb.down(kVK_Escape, isRepeat: true)
        #expect(repeated.events.isEmpty)
        #expect(repeated.swallow)
        #expect(kb.up(kVK_Escape).swallow)
    }

    /// Cancel was once rebindable: a key an older build stored for it (F13) does nothing now, and Esc still cancels.
    @Test func aStoredCustomCancelDoesNothingEscStillCancels() throws {
        let stored = #"{"cancel":{"keyCode":105,"modifiers":[]}}"#
        var kb = Keyboard(bindings: try JSONDecoder().decode(ShortcutBindings.self, from: Data(stored.utf8)))
        kb.config.isBusy = true
        let f13 = kb.down(kVK_F13, fnFlagged: true)
        #expect(f13.events.isEmpty)
        #expect(!f13.swallow)
        kb.up(kVK_F13, fnFlagged: true)
        let esc = kb.down(kVK_Escape)
        #expect(esc.events == [.cancel])
        #expect(esc.swallow)
    }

    @Test func escapeWhileHoldingFnCancelsBeforeTheAppReportsBusy() {
        var kb = Keyboard()
        #expect(kb.press(.fn).events == [.pttDown])
        let esc = kb.down(kVK_Escape)
        #expect(esc.events == [.cancel])
        #expect(esc.swallow)
        kb.up(kVK_Escape)
        #expect(kb.release(.fn).events.isEmpty)
    }

    @Test func escapeWithFnStillHeldAfterLockingCancels() {
        var kb = Keyboard()
        kb.press(.fn)
        kb.down(kVK_Space)
        kb.up(kVK_Space)
        kb.config.isBusy = true
        let esc = kb.down(kVK_Escape)
        #expect(esc.events == [.cancel])
        #expect(esc.swallow)
    }

    @Test func swallowedKeyWhoseKeyUpWasLostIsEvaluatedAgain() {
        var kb = Keyboard()
        kb.press(.fn)
        #expect(kb.down(kVK_Space).events == [.handsFreeToggle])
        kb.release(.fn)
        // The Space keyUp never arrived; a fresh press without fn is ordinary typing.
        let space = kb.down(kVK_Space)
        #expect(space.events.isEmpty)
        #expect(!space.swallow)
    }

    @Test func rightOptionPushToTalkIgnoresLeftOption() {
        var kb = Keyboard(bindings: bindings([.pushToTalk: .rightOption]))
        #expect(kb.press(.leftOption).events.isEmpty)
        #expect(kb.release(.leftOption).events.isEmpty)
        #expect(kb.press(.rightOption).events == [.pttDown])
        #expect(kb.release(.rightOption).events == [.pttUp])
        // Left ⌥ held, then Right ⌥: not an exact match.
        kb.press(.leftOption)
        #expect(kb.press(.rightOption).events.isEmpty)
    }

    @Test func rightCommandPushToTalkLetsCommandCThrough() {
        var kb = Keyboard(bindings: bindings([.pushToTalk: .rightCommand]))
        #expect(kb.press(.rightCommand).events == [.pttDown])
        let c = kb.down(kVK_ANSI_C)
        #expect(c.events == [.pttInterrupted])
        #expect(!c.swallow)
        #expect(kb.release(.rightCommand).events.isEmpty)
    }

    @Test func keyBasedPushToTalkWithF13() {
        var kb = Keyboard(bindings: bindings([.pushToTalk: .f13]))
        let down = kb.down(kVK_F13, fnFlagged: true)
        #expect(down.events == [.pttDown])
        #expect(down.swallow)
        let repeated = kb.down(kVK_F13, isRepeat: true, fnFlagged: true)
        #expect(repeated.events.isEmpty)
        #expect(repeated.swallow)
        // Other keys don't interrupt an unambiguous key PTT.
        let typing = kb.down(kVK_ANSI_A)
        #expect(typing.events.isEmpty)
        #expect(!typing.swallow)
        kb.up(kVK_ANSI_A)
        let up = kb.up(kVK_F13, fnFlagged: true)
        #expect(up.events == [.pttUp])
        #expect(up.swallow)
    }

    /// F5 as push to talk, sent the way Karabiner sends a real F5 on an Apple keyboard (fn held around it, so the
    /// Mac doesn't take it for its Dictation key), and the way a keyboard with standard F-keys sends it (no fn):
    /// both are F5.
    @Test func anFKeyIsItselfWithOrWithoutFn() {
        let f5 = Shortcut(modifiers: [.init(.function)], keyCode: UInt16(kVK_F5))
        #expect(f5 == Shortcut(modifiers: [], keyCode: UInt16(kVK_F5)), "recorded as F5, not fn F5")
        var viaKarabiner = Keyboard(bindings: bindings([.pushToTalk: f5]))
        viaKarabiner.press(.fn)
        let down = viaKarabiner.down(kVK_F5, fnFlagged: true)
        #expect(down.events == [.pttDown] && down.swallow)
        let up = viaKarabiner.up(kVK_F5, fnFlagged: true)
        #expect(up.events == [.pttUp])
        viaKarabiner.release(.fn)

        var standard = Keyboard(bindings: bindings([.pushToTalk: f5]))
        #expect(standard.down(kVK_F5, fnFlagged: true).events == [.pttDown])
        #expect(standard.up(kVK_F5, fnFlagged: true).events == [.pttUp])
    }

    /// Clicking into another field while holding the key is part of dictating: the hold goes on.
    @Test func mouseClickWhileHoldingModifierPushToTalkGoesOn() {
        var kb = Keyboard(bindings: bindings([.pushToTalk: .rightCommand]))
        kb.press(.rightCommand)
        #expect(kb.click().events.isEmpty)
        #expect(kb.release(.rightCommand).events == [.pttUp])
        var fn = Keyboard()
        fn.press(.fn)
        #expect(fn.click().events.isEmpty)
        #expect(fn.release(.fn).events == [.pttUp])
    }

    @Test func syntheticEventsAreIgnoredEntirely() {
        var kb = Keyboard()
        kb.config.isBusy = true
        let pasted = kb.down(kVK_Escape, synthetic: true)
        #expect(pasted == HotkeyRouter.Decision())
        let flags = CGEventFlags.maskCommand.rawValue | DeviceModifierMask.leftCommand
        _ = kb.send(HotkeyInput(kind: .flagsChanged, keyCode: KeyCode.command, flags: flags, isSynthetic: true))
        #expect(kb.router.modifiers.isEmpty)
    }

    @Test func suspendedRouterNeitherFiresNorSwallows() {
        var kb = Keyboard()
        kb.config.isSuspended = true
        #expect(kb.press(.fn).events.isEmpty)
        let space = kb.down(kVK_Space)
        #expect(space.events.isEmpty)
        #expect(!space.swallow)
    }

    @Test func suspendingDuringAHoldEndsTheGesture() {
        var kb = Keyboard()
        #expect(kb.press(.fn).events == [.pttDown])
        kb.config.isSuspended = true
        #expect(kb.down(kVK_ANSI_A).events == [.pttInterrupted])
        #expect(kb.release(.fn).events.isEmpty)
    }

    @Test func modifierOnlyHandsFreeFiresOnPressAndWinsOverInterruption() {
        let handsFree = Shortcut(modifiers: [.init(.function), .init(.option, .right)])
        var kb = Keyboard(bindings: bindings([.handsFree: handsFree]))
        #expect(kb.press(.fn).events == [.pttDown])
        #expect(kb.press(.rightOption).events == [.handsFreeToggle])
        #expect(kb.release(.rightOption).events.isEmpty)
        #expect(kb.release(.fn).events.isEmpty)
    }

    @Test func rawKeysAreForwardedOnlyWhenAsked() {
        var kb = Keyboard()
        #expect(kb.press(.fn).rawKey == nil)
        kb.release(.fn)
        kb.config.forwardsRawKeys = true
        #expect(kb.press(.fn).rawKey == RawKeyEvent(key: .fn, isDown: true))
        #expect(kb.down(kVK_Space).rawKey == RawKeyEvent(key: .space, isDown: true))
        #expect(kb.up(kVK_Space).rawKey == RawKeyEvent(key: .space, isDown: false))
        #expect(kb.release(.fn).rawKey == RawKeyEvent(key: .fn, isDown: false))
        #expect(kb.press(.rightCommand).rawKey == RawKeyEvent(key: .command, isDown: true))
        // Ordinary typing never leaves the tap thread.
        #expect(kb.down(kVK_ANSI_Q).rawKey == nil)
    }

    @Test func resynchronizeReleasesAPushToTalkWhoseKeyIsUp() {
        var kb = Keyboard()
        kb.press(.fn)
        let events = kb.router.resynchronize(flags: 0, config: kb.config) { _ in false }
        #expect(events == [.pttUp])
        #expect(kb.router.gesture == .idle)
    }

    @Test func lostFnReleaseHealsOnTheNextKey() {
        var kb = Keyboard()
        #expect(kb.press(.fn).events == [.pttDown])
        // The fn release never reaches the tap: the next key arrives without the Fn bit.
        let space = kb.send(HotkeyInput(kind: .keyDown, keyCode: UInt16(kVK_Space), flags: 0))
        #expect(space.events == [.pttUp], "the hold ends as a release, not as fn+Space")
        #expect(!space.swallow)
        #expect(!kb.router.functionDown)
        // ⌘V without the Fn bit is a plain paste, not ⌘fnV.
        let paste = kb.send(HotkeyInput(kind: .keyDown, keyCode: UInt16(kVK_ANSI_V),
                                        flags: Keyboard.Modifier.leftCommand.flags))
        #expect(paste.events.isEmpty)
        #expect(!paste.swallow)
    }

    @Test func lostFnReleaseHealsOnAModifierChange() {
        var kb = Keyboard()
        #expect(kb.press(.fn).events == [.pttDown])
        let shift = kb.send(HotkeyInput(kind: .flagsChanged, keyCode: KeyCode.shift,
                                        flags: Keyboard.Modifier.leftShift.flags))
        #expect(shift.events == [.pttUp])
        #expect(!kb.router.functionDown)
    }

    @Test func fnFlaggedKeysDontInventAnFnPress() {
        var kb = Keyboard()
        #expect(kb.down(kVK_LeftArrow, fnFlagged: true).events.isEmpty)
        #expect(!kb.router.functionDown)
    }

    @Test func foreignSyntheticPasteDoesntSwallowTheNextPTTPress() {
        var kb = Keyboard()
        // A clipboard manager posts V with only the device-independent ⌘ bit; no ⌘ flagsChanged follows.
        _ = kb.send(HotkeyInput(kind: .keyDown, keyCode: UInt16(kVK_ANSI_V), flags: CGEventFlags.maskCommand.rawValue))
        _ = kb.send(HotkeyInput(kind: .keyUp, keyCode: UInt16(kVK_ANSI_V), flags: CGEventFlags.maskCommand.rawValue))
        #expect(kb.press(.fn).events == [.pttDown])
        #expect(kb.release(.fn).events == [.pttUp])
    }

    @Test func releasingOneSideOfAHeldPairIsNotAPress() {
        let handsFree = Shortcut(modifiers: [.init(.command, .left)])
        var kb = Keyboard(bindings: bindings([.handsFree: handsFree]))
        #expect(kb.press(.rightCommand).events.isEmpty)
        #expect(kb.press(.leftCommand).events.isEmpty)
        // Left ⌘ alone is held now, but that came from a release (the ⌘ family bit is still set).
        #expect(kb.release(.rightCommand).events.isEmpty)
        #expect(kb.release(.leftCommand).events.isEmpty)
        #expect(kb.press(.leftCommand).events == [.handsFreeToggle])
    }

    @Test func resetInterruptsAHoldInProgress() {
        var kb = Keyboard()
        kb.press(.fn)
        #expect(kb.router.reset() == [.pttInterrupted])
        #expect(kb.router.reset().isEmpty)
    }
}

// MARK: - Held-key shortcuts (F5 Space)

/// Push to talk on F5, and the rest pressed off it the way fn's are pressed off fn: F5 Space, F5 P, F5 ↩…
@Suite struct HeldKeyChordRouterTests {
    static let f5 = Shortcut(modifiers: [], keyCode: KeyCode.f5)
    static func onF5(_ key: Int) -> Shortcut { Shortcut(heldKeyCode: KeyCode.f5, modifiers: [], keyCode: UInt16(key)) }

    /// What the Shortcuts page makes of the defaults once push to talk is F5.
    static var bindingsOnF5: ShortcutBindings {
        var bindings = ShortcutBindings.defaults
        bindings[.pushToTalk] = f5
        _ = bindings.moveOntoTalkKey(from: .fn, system: SystemKeyboardState(hotKeys: [], fnUsage: .doNothing))
        return bindings
    }

    /// The router's events played into the machine, as the controller does.
    static func machineInput(_ event: HotkeyEvent) -> DictationMachine.Input? {
        switch event {
        case .pttDown: .pttDown
        case .pttUp: .pttUp
        case .pttInterrupted: .pttInterrupted
        case .handsFreeToggle: .handsFreeToggle
        case .cancel: .cancel
        case .polish: .polish
        case .translate: .translate
        case .send: .send
        case .cycleEngine: .cycleEngine
        default: nil
        }
    }

    @Test func theBindingsAreOnF5() {
        let bindings = Self.bindingsOnF5
        #expect(bindings[.handsFree] == Self.onF5(kVK_Space))
        #expect(bindings[.polish] == Self.onF5(kVK_ANSI_P))
        #expect(bindings[.send] == Self.onF5(kVK_Return))
    }

    /// F5 down starts push to talk; Space while it's held turns that dictation hands-free and is swallowed (with its
    /// autorepeats and release); F5's release then ends nothing. Exactly fn Space with fn.
    @Test func f5SpaceTurnsTheHeldDictationHandsFree() {
        var kb = Keyboard(bindings: Self.bindingsOnF5)
        var machine = DictationMachine()
        func play(_ decision: HotkeyRouter.Decision, at t: TimeInterval) {
            for event in decision.events { if let input = Self.machineInput(event) { _ = machine.handle(input, now: t) } }
        }
        let down = kb.down(kVK_F5, fnFlagged: true)
        #expect(down.events == [.pttDown] && down.swallow)
        play(down, at: 0)
        let space = kb.down(kVK_Space)
        #expect(space.events == [.handsFreeToggle] && space.swallow)
        play(space, at: 0.4)
        let repeated = kb.down(kVK_Space, isRepeat: true)
        #expect(repeated.events.isEmpty && repeated.swallow)
        #expect(kb.up(kVK_Space).swallow)
        let up = kb.up(kVK_F5, fnFlagged: true)
        #expect(up.events.isEmpty && up.swallow, "F5's release doesn't end hands-free")
        play(up, at: 1)
        #expect(machine.mode == .handsFree && machine.isRecording)
    }

    /// The same with fn held around F5 (Karabiner sends a real F5 that way): fn Space is still F5 Space.
    @Test func f5SpaceWithFnHeldAroundF5() {
        var kb = Keyboard(bindings: Self.bindingsOnF5)
        kb.press(.fn)
        #expect(kb.down(kVK_F5, fnFlagged: true).events == [.pttDown])
        let space = kb.down(kVK_Space, fnFlagged: true)
        #expect(space.events == [.handsFreeToggle] && space.swallow)
        kb.up(kVK_Space, fnFlagged: true)
        // Hands-free now records (the monitor says so), with F5 and its fn still held.
        kb.config.isRecording = true
        kb.config.isBusy = true
        let polish = kb.down(kVK_ANSI_P, fnFlagged: true)
        #expect(polish.events == [.polish] && polish.swallow)
        kb.up(kVK_ANSI_P, fnFlagged: true)
        // Esc with that fn still cancels.
        let esc = kb.down(kVK_Escape, fnFlagged: true)
        #expect(esc.events == [.cancel] && esc.swallow)
    }

    /// Other keys while F5 is held type, as they did, and don't end the hold.
    @Test func otherKeysStillType() {
        var kb = Keyboard(bindings: Self.bindingsOnF5)
        #expect(kb.down(kVK_F5, fnFlagged: true).events == [.pttDown])
        for key in [kVK_ANSI_A, kVK_ANSI_X, kVK_ANSI_1] {
            let typed = kb.down(key)
            #expect(typed.events.isEmpty && !typed.swallow, "key \(key) types")
            #expect(!kb.up(key).swallow)
        }
        #expect(kb.up(kVK_F5, fnFlagged: true).events == [.pttUp], "the hold went on")
    }

    /// Without F5 held, Space, P and ↩ are the app's, during a dictation too.
    @Test func withoutF5TheKeysAreTheApps() {
        var kb = Keyboard(bindings: Self.bindingsOnF5)
        for key in [kVK_Space, kVK_ANSI_P, kVK_Return] {
            let typed = kb.down(key)
            #expect(typed.events.isEmpty && !typed.swallow, "key \(key) outside a dictation")
            kb.up(key)
        }
        kb.config.isRecording = true
        kb.config.isBusy = true
        for key in [kVK_Space, kVK_ANSI_P, kVK_ANSI_T, kVK_Return, kVK_Tab] {
            let typed = kb.down(key)
            #expect(typed.events.isEmpty && !typed.swallow, "key \(key) during hands-free without F5")
            kb.up(key)
        }
    }

    /// From idle, F5 Space is what fn Space is with fn: push to talk starts, then goes hands-free.
    @Test func f5SpaceFromIdle() {
        var kb = Keyboard(bindings: Self.bindingsOnF5)
        var events: [HotkeyEvent] = []
        events += kb.down(kVK_F5).events
        events += kb.down(kVK_Space).events
        events += kb.up(kVK_Space).events
        events += kb.up(kVK_F5).events
        var fn = Keyboard()
        var fnEvents: [HotkeyEvent] = []
        fnEvents += fn.press(.fn).events
        fnEvents += fn.down(kVK_Space, fnFlagged: true).events
        fnEvents += fn.up(kVK_Space, fnFlagged: true).events
        fnEvents += fn.release(.fn).events
        #expect(events == [.pttDown, .handsFreeToggle])
        #expect(events == fnEvents)
    }

    /// F5 P, F5 T, F5 ↩ and F5 Tab during the hold: Polish, Translate, Send and Switch model, swallowed, and the hold
    /// goes on, as fn P and the rest do with fn. F5 D is held for the selection, as fn D is.
    @Test func duringDictationKeysOffF5() {
        let cases: [(key: Int, event: HotkeyEvent)] = [
            (kVK_ANSI_P, .polish), (kVK_ANSI_T, .translate), (kVK_Return, .send), (kVK_Tab, .cycleEngine),
        ]
        for (key, event) in cases {
            var kb = Keyboard(bindings: Self.bindingsOnF5)
            kb.down(kVK_F5, fnFlagged: true)
            let pressed = kb.down(key)
            #expect(pressed.events == [event] && pressed.swallow, "F5 + key \(key)")
            #expect(kb.up(key).swallow)
            #expect(kb.up(kVK_F5, fnFlagged: true).events == [.pttUp], "the hold went on after key \(key)")

            var fn = Keyboard()
            fn.press(.fn)
            #expect(fn.down(key, fnFlagged: true).events == [event], "fn + key \(key) does the same")
        }
        var kb = Keyboard(bindings: Self.bindingsOnF5)
        kb.down(kVK_F5, fnFlagged: true)
        let d = kb.down(kVK_ANSI_D)
        #expect(d.swallow)
        guard case .heldForSelection(.addToDictionary, let stroke) = d.events.first else {
            Issue.record("expected heldForSelection, got \(d.events)")
            return
        }
        #expect(stroke.interruptsHold, "as fn D with fn: a selection it can't read ends the hold")
        // Polish held down turns Polish on and off at every autorepeat, as fn P held does.
        kb.up(kVK_ANSI_D)
        kb.down(kVK_ANSI_P)
        #expect(kb.down(kVK_ANSI_P, isRepeat: true).events == [.polishRepeat])
    }

    /// In hands-free, F5 down is a push-to-talk press (its release would finish), F5 P polishes, and F5 Space keeps
    /// recording: the same inputs fn gives the machine.
    @Test func inHandsFreeF5IsWhatFnIs() {
        var kb = Keyboard(bindings: Self.bindingsOnF5)
        kb.config.isRecording = true
        kb.config.isBusy = true
        #expect(kb.down(kVK_F5, fnFlagged: true).events == [.pttDown])
        #expect(kb.down(kVK_ANSI_P).events == [.polish])
        kb.up(kVK_ANSI_P)
        #expect(kb.down(kVK_Space).events == [.handsFreeToggle])
        kb.up(kVK_Space)
        #expect(kb.up(kVK_F5, fnFlagged: true).events.isEmpty)

        var machine = DictationMachine()
        _ = machine.handle(.handsFreeToggle, now: 0)
        _ = machine.handle(.pttDown, now: 1)
        _ = machine.handle(.handsFreeToggle, now: 1.1)
        #expect(machine.mode == .handsFree, "F5 Space in hands-free keeps recording")
    }

    /// A chord's key with another F-key held is nobody's: F6 Space isn't F5 Space.
    @Test func aChordNeedsItsOwnKeyHeld() {
        var kb = Keyboard(bindings: Self.bindingsOnF5)
        kb.down(kVK_F6, fnFlagged: true)
        let space = kb.down(kVK_Space)
        #expect(space.events.isEmpty && !space.swallow, "F6 isn't F5")
    }
}

// MARK: - Shortcut capture (recorder)

@Suite struct ShortcutCaptureEngineTests {
    private func flags(_ modifiers: [Keyboard.Modifier]) -> UInt64 {
        modifiers.reduce(0) { $0 | $1.flags }
    }

    @Test func modifierOnlyCommitsLargestSetOnFullRelease() {
        var engine = ShortcutCaptureEngine(action: .pushToTalk)
        #expect(engine.flagsChanged(keyCode: KeyCode.control, rawFlags: flags([.leftControl])) == .none)
        #expect(engine.flagsChanged(keyCode: KeyCode.option, rawFlags: flags([.leftControl, .leftOption])) == .none)
        #expect(engine.held == Shortcut(modifiers: [.init(.control), .init(.option)]))
        #expect(engine.flagsChanged(keyCode: KeyCode.control, rawFlags: flags([.leftOption])) == .none)
        #expect(engine.flagsChanged(keyCode: KeyCode.option, rawFlags: 0)
            == .commit(Shortcut(modifiers: [.init(.control), .init(.option)])))
        #expect(engine.held == nil)
    }

    @Test func rightOptionKeepsItsSide() {
        var engine = ShortcutCaptureEngine(action: .pushToTalk)
        _ = engine.flagsChanged(keyCode: KeyCode.rightOption, rawFlags: flags([.rightOption]))
        #expect(engine.flagsChanged(keyCode: KeyCode.rightOption, rawFlags: 0) == .commit(.rightOption))
    }

    @Test func fnAloneAndFnSpace() {
        var engine = ShortcutCaptureEngine(action: .pushToTalk)
        _ = engine.flagsChanged(keyCode: KeyCode.function, rawFlags: flags([.fn]))
        #expect(engine.flagsChanged(keyCode: KeyCode.function, rawFlags: 0) == .commit(.fn))

        var handsFree = ShortcutCaptureEngine(action: .handsFree)
        _ = handsFree.flagsChanged(keyCode: KeyCode.function, rawFlags: flags([.fn]))
        #expect(handsFree.keyDown(keyCode: KeyCode.space, rawFlags: flags([.fn]), isRepeat: false) == .commit(.fnSpace))
    }

    @Test func combinationsIgnoreSidesAndFnFlaggedKeys() {
        var engine = ShortcutCaptureEngine(action: .pasteLast)
        let rightCommand = flags([.rightCommand])
        #expect(engine.keyDown(keyCode: KeyCode.ansiV, rawFlags: rightCommand, isRepeat: false)
            == .commit(Shortcut(modifiers: [.init(.command)], keyCode: KeyCode.ansiV)))
        // F13 reports the Fn flag without Fn being held. It may be the start of F13 Space: its release commits it.
        #expect(engine.keyDown(keyCode: KeyCode.f13, rawFlags: CGEventFlags.maskSecondaryFn.rawValue, isRepeat: false)
            == .none)
        #expect(engine.held == .f13)
        #expect(engine.keyUp(keyCode: KeyCode.f13) == .commit(.f13))
        // Push to talk is one key on its own: F13 commits on the press.
        var ptt = ShortcutCaptureEngine(action: .pushToTalk)
        #expect(ptt.keyDown(keyCode: KeyCode.f13, rawFlags: CGEventFlags.maskSecondaryFn.rawValue, isRepeat: false)
            == .commit(.f13))
    }

    /// F5 held, then Space: F5 Space. F5 alone, let go: F5. With fn held around F5 (Karabiner), the same.
    @Test func aHeldFKeyThenAKeyIsAChord() {
        let fnFlag = CGEventFlags.maskSecondaryFn.rawValue
        let f5Space = Shortcut(heldKeyCode: KeyCode.f5, modifiers: [], keyCode: KeyCode.space)
        var engine = ShortcutCaptureEngine(action: .handsFree)
        #expect(engine.keyDown(keyCode: KeyCode.f5, rawFlags: fnFlag, isRepeat: false) == .none)
        #expect(engine.held == Shortcut(modifiers: [], keyCode: KeyCode.f5), "F5 shows while it's held")
        #expect(engine.keyDown(keyCode: KeyCode.f5, rawFlags: fnFlag, isRepeat: true) == .none)
        #expect(engine.keyDown(keyCode: KeyCode.space, rawFlags: 0, isRepeat: false) == .commit(f5Space))
        #expect(engine.held == nil)

        var alone = ShortcutCaptureEngine(action: .handsFree)
        _ = alone.keyDown(keyCode: KeyCode.f5, rawFlags: fnFlag, isRepeat: false)
        #expect(alone.keyUp(keyCode: KeyCode.space) == .none, "another key's release changes nothing")
        #expect(alone.keyUp(keyCode: KeyCode.f5) == .commit(Shortcut(modifiers: [], keyCode: KeyCode.f5)))

        var karabiner = ShortcutCaptureEngine(action: .handsFree)
        #expect(karabiner.flagsChanged(keyCode: KeyCode.function, rawFlags: fnFlag) == .none)
        _ = karabiner.keyDown(keyCode: KeyCode.f5, rawFlags: fnFlag, isRepeat: false)
        #expect(karabiner.keyDown(keyCode: KeyCode.space, rawFlags: fnFlag, isRepeat: false) == .commit(f5Space))
        // fn let go before F5: nothing is committed as fn alone, and F5's release is F5.
        var fnFirst = ShortcutCaptureEngine(action: .polish)
        _ = fnFirst.flagsChanged(keyCode: KeyCode.function, rawFlags: fnFlag)
        _ = fnFirst.keyDown(keyCode: KeyCode.f5, rawFlags: fnFlag, isRepeat: false)
        #expect(fnFirst.flagsChanged(keyCode: KeyCode.function, rawFlags: 0) == .none)
        #expect(fnFirst.keyUp(keyCode: KeyCode.f5) == .commit(Shortcut(modifiers: [], keyCode: KeyCode.f5)))

        // A modifier with the second key: F5 ⌥Space.
        var option = ShortcutCaptureEngine(action: .handsFree)
        _ = option.keyDown(keyCode: KeyCode.f5, rawFlags: 0, isRepeat: false)
        #expect(option.flagsChanged(keyCode: KeyCode.option, rawFlags: flags([.leftOption])) == .none)
        #expect(option.keyDown(keyCode: KeyCode.space, rawFlags: flags([.leftOption]), isRepeat: false)
            == .commit(Shortcut(heldKeyCode: KeyCode.f5, modifiers: [.init(.option)], keyCode: KeyCode.space)))
    }

    /// With F5 held, Esc still stops recording and ⌫ still clears: they don't become F5 Esc or F5 ⌫.
    @Test func escAndDeleteKeepTheirMeaningWithAKeyHeld() {
        let fnFlag = CGEventFlags.maskSecondaryFn.rawValue
        var esc = ShortcutCaptureEngine(action: .handsFree)
        _ = esc.flagsChanged(keyCode: KeyCode.function, rawFlags: fnFlag)
        _ = esc.keyDown(keyCode: KeyCode.f5, rawFlags: fnFlag, isRepeat: false)
        #expect(esc.keyDown(keyCode: KeyCode.escape, rawFlags: fnFlag, isRepeat: false) == .cancel)
        var delete = ShortcutCaptureEngine(action: .handsFree)
        _ = delete.keyDown(keyCode: KeyCode.f5, rawFlags: 0, isRepeat: false)
        #expect(delete.keyDown(keyCode: KeyCode.delete, rawFlags: 0, isRepeat: false) == .clear)
    }

    /// Only F-keys wait: a key that types commits on the press, as before.
    @Test func keysThatTypeCommitOnThePress() {
        var engine = ShortcutCaptureEngine(action: .handsFree)
        #expect(engine.keyDown(keyCode: KeyCode.space, rawFlags: 0, isRepeat: false)
            == .commit(Shortcut(modifiers: [], keyCode: KeyCode.space)))
    }

    @Test(arguments: ShortcutAction.allCases)
    func bareEscapeStopsRecording(_ action: ShortcutAction) {
        var engine = ShortcutCaptureEngine(action: action)
        #expect(engine.keyDown(keyCode: KeyCode.escape, rawFlags: 0, isRepeat: false) == .cancel)
    }

    @Test func deleteClearsOnlyOptionalActions() {
        var paste = ShortcutCaptureEngine(action: .pasteLast)
        #expect(paste.keyDown(keyCode: KeyCode.delete, rawFlags: 0, isRepeat: false) == .clear)
        var ptt = ShortcutCaptureEngine(action: .pushToTalk)
        #expect(ptt.keyDown(keyCode: KeyCode.delete, rawFlags: 0, isRepeat: false)
            == .commit(Shortcut(modifiers: [], keyCode: KeyCode.delete)))
    }

    @Test func repeatsAreIgnored() {
        var engine = ShortcutCaptureEngine(action: .pasteLast)
        #expect(engine.keyDown(keyCode: KeyCode.ansiV, rawFlags: flags([.leftCommand]), isRepeat: true) == .none)
    }
}

// MARK: - Text insertion helpers

@Suite struct LeadingSpaceTests {
    @Test(arguments: [
        ("a", "hello", true),
        (".", "Next sentence", true),
        (",", "and more", true),
        ("я", "привет", true),
        (" ", "hello", false),
        ("\n", "hello", false),
        ("(", "aside", false),
        ("\"", "quoted", false),
        ("«", "цитата", false),
        ("/", "path", false),
        ("a", ", then", false),
        ("a", ".", false),
        ("a", ")", false),
        ("a", "%", false),
        ("a", " already spaced", false),
        ("a", "", false),
    ] as [(String, String, Bool)])
    func leadingSpace(previous: String, text: String, expected: Bool) {
        #expect(TextInserter.needsLeadingSpace(after: Character(previous), before: text) == expected)
    }
}

@MainActor
@Suite struct PasteKeyResolverTests {
    @Test func currentLayoutPastesWithKeyCodeNine() {
        // This Mac types in RussianWin and ABC; both carry a Latin ⌘ layer.
        #expect(PasteKeyResolver.resolveCurrent() == 9)
    }

    @Test func russianUsesTheLatinCommandLayer() throws {
        let russian = try #require(PasteKeyResolver.layout(id: "com.apple.keylayout.RussianWin"))
        #expect(PasteKeyResolver.resolve(source: russian) == 9)
    }

    @Test func dvorakMovesV() throws {
        let dvorak = try #require(PasteKeyResolver.layout(id: "com.apple.keylayout.Dvorak"))
        #expect(PasteKeyResolver.resolve(source: dvorak) == 47)
    }
}

// MARK: - Pasteboard

/// A private, uniquely named pasteboard: the user's clipboard is never touched.
@MainActor
private func privatePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("dev.transcribe-thing.tests.\(UUID().uuidString)"))
}

// MARK: - TextInserter pipeline (fake system, private pasteboard)

private final class PasteLog: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [CGKeyCode]())
    func record(_ code: CGKeyCode) { lock.withLock { $0.append(code) } }
    var codes: [CGKeyCode] { lock.withLock { $0 } }
}

/// What the fake target got when it read the clipboard for ⌘V.
private final class TargetLog: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [String?]())
    func record(_ text: String?) { lock.withLock { $0.append(text) } }
    var reads: [String?] { lock.withLock { $0 } }
}

/// A type another app provides only when it's read, the way apps put large data on the clipboard: its name as data
/// after `delay` to render it, or nothing at all with `provides` off (asked again at every read).
final class LazyType: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    private let delay: TimeInterval
    private let provides: Bool
    init(delay: TimeInterval = 0, provides: Bool = true) {
        self.delay = delay
        self.provides = provides
    }
    var requests: Int { lock.withLock { $0 } }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        lock.withLock { $0 += 1 }
        Thread.sleep(forTimeInterval: delay)
        if provides { item.setData(Data(type.rawValue.utf8), forType: type) }
    }
}

/// The focus the fake system reports; a test can move it between pastes.
private final class FocusBox: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<FocusInfo>
    init(_ focus: FocusInfo) { lock = OSAllocatedUnfairLock(initialState: focus) }
    var focus: FocusInfo {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

/// Each item's types with their data, item by item: equal when a restore put back exactly what was there.
@MainActor
private func contents(of pasteboard: NSPasteboard) -> [[String: Data]] {
    (pasteboard.pasteboardItems ?? []).map { item in
        Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } })
    }
}

/// A screenshot next to its caption, then a file with an app's own type: what a paste must put back.
@MainActor
private func copyScreenshotAndFile(to pasteboard: NSPasteboard) {
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
    for x in 0..<8 { image.setColor(NSColor(deviceRed: 0.2, green: 0.7, blue: CGFloat(x) / 8, alpha: 1), atX: x, y: x) }
    let screenshot = NSPasteboardItem()
    screenshot.setData(image.representation(using: .png, properties: [:])!, forType: .png)
    screenshot.setData(image.tiffRepresentation!, forType: .tiff)
    screenshot.setString("Screenshot 2026-09-29", forType: .string)
    let file = NSPasteboardItem()
    file.setString("file:///Users/me/Desktop/notes.txt", forType: .fileURL)
    file.setData(Data([0xCA, 0xFE, 0x00, 0x01]), forType: NSPasteboard.PasteboardType("com.example.editor.selection"))
    pasteboard.clearContents()
    _ = pasteboard.writeObjects([screenshot, file])
}

// MARK: - Copying the selection (fake ⌘C, private pasteboard)

@MainActor
@Suite struct SelectionCopyTests {
    /// An inserter whose ⌘C has the app put `copies` on the clipboard a moment later (and VS Code's own type with
    /// `editorData`), as an app would; nil copies nothing.
    private func inserter(_ pasteboard: NSPasteboard, canPost: Bool = true, copies: String?,
                          editorData: String? = nil) -> TextInserter {
        let name = pasteboard.name
        let system = TextInserter.System(
            canPostEvents: { canPost }, modifiersHeld: { false },
            inspectFocus: { FocusInfo(pid: 42, editability: .editable) }, pasteKeyCode: { 9 },
            postPaste: { _ in true }, copyKeyCode: { 8 },
            postCopy: { _ in
                guard let copies else { return true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    let pasteboard = NSPasteboard(name: name)
                    pasteboard.clearContents()
                    let item = NSPasteboardItem()
                    item.setString(copies, forType: .string)
                    if let editorData, let utf16 = editorData.data(using: .utf16LittleEndian) {
                        // Chromium keeps a page's own clipboard types in one of its own, as UTF-16.
                        item.setData(utf16, forType: NSPasteboard.PasteboardType("org.chromium.web-custom-data"))
                    }
                    _ = pasteboard.writeObjects([item])
                }
                return true
            })
        let inserter = TextInserter(pasteboard: pasteboard, system: system)
        inserter.copyTimeout = .milliseconds(200)
        return inserter
    }

    private func keep(_ text: String, on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// What ⌘C copied comes back, and the clipboard goes back to what it held, marked so clipboard managers don't
    /// take it for a new copy.
    @Test func itCopiesTheSelectionAndPutsTheClipboardBack() async {
        let pasteboard = privatePasteboard()
        copyScreenshotAndFile(to: pasteboard)
        let before = contents(of: pasteboard)
        #expect(await inserter(pasteboard, copies: "selected words").copySelection() == .text("selected words"))
        let marker = PasteboardMarkers.transientType.rawValue
        #expect(contents(of: pasteboard).map { $0.filter { $0.key != marker } } == before)
        #expect(pasteboard.pasteboardItems?.allSatisfy { $0.types.contains(PasteboardMarkers.transientType) } == true)
    }

    /// ⌘C copied nothing: nothing was selected, and the clipboard wasn't touched.
    @Test func nothingCopiedIsNothingSelected() async {
        let pasteboard = privatePasteboard()
        keep("kept", on: pasteboard)
        let count = pasteboard.changeCount
        #expect(await inserter(pasteboard, copies: nil).copySelection() == .nothing)
        #expect(pasteboard.changeCount == count && pasteboard.string(forType: .string) == "kept")
    }

    /// VS Code copies the whole line when nothing is selected, and says so: that's nothing selected.
    @Test func vsCodesWholeLineIsNothingSelected() async {
        let pasteboard = privatePasteboard()
        keep("kept", on: pasteboard)
        let editorData = #"{"version":1,"isFromEmptySelection":true,"multicursorText":null,"mode":"swift"}"#
        let inserter = inserter(pasteboard, copies: "    let line = 1\n", editorData: editorData)
        #expect(await inserter.copySelection() == .nothing)
        #expect(pasteboard.string(forType: .string) == "kept")
    }

    @Test func withoutPermissionItIsntTried() async {
        let pasteboard = privatePasteboard()
        keep("kept", on: pasteboard)
        #expect(await inserter(pasteboard, canPost: false, copies: "x").copySelection() == .unavailable)
        #expect(pasteboard.string(forType: .string) == "kept")
    }
}

@MainActor
@Suite struct TextInserterTests {
    private struct Rig {
        let inserter: TextInserter
        let pasteboard: NSPasteboard
        let log: PasteLog
        let focus: FocusBox
        let target: TargetLog
    }

    /// After "d": the paste gets a smart leading space.
    private static let afterAWord = FocusInfo(pid: 42, editability: .editable, precedingCharacter: "d")
    private static let restoreDelay = Duration.milliseconds(150)

    /// `targetReadsAfter`: seconds after ⌘V the target reads the clipboard, on the main thread like an app (nil: it
    /// never does).
    private func rig(focus: FocusInfo = FocusInfo(pid: 42, editability: .editable),
                     canPost: Bool = true, posts: Bool = true,
                     targetReadsAfter: TimeInterval? = 0.01) -> Rig {
        let pasteboard = privatePasteboard()
        let name = pasteboard.name
        let log = PasteLog()
        let box = FocusBox(focus)
        let target = TargetLog()
        let system = TextInserter.System(
            canPostEvents: { canPost },
            modifiersHeld: { false },
            inspectFocus: { box.focus },
            pasteKeyCode: { 9 },
            postPaste: { code in
                log.record(code)
                if posts, let targetReadsAfter {
                    DispatchQueue.main.asyncAfter(deadline: .now() + targetReadsAfter) {
                        target.record(NSPasteboard(name: name).string(forType: .string))
                    }
                }
                return posts
            })
        let inserter = TextInserter(pasteboard: pasteboard, system: system)
        inserter.restoreDelay = Self.restoreDelay
        inserter.unreadTimeout = .seconds(1)
        return Rig(inserter: inserter, pasteboard: pasteboard, log: log, focus: box, target: target)
    }

    private func types(_ rig: Rig) -> [NSPasteboard.PasteboardType] {
        rig.pasteboard.pasteboardItems?.first?.types ?? []
    }

    private func copyString(_ string: String, to rig: Rig) {
        rig.pasteboard.clearContents()
        rig.pasteboard.setString(string, forType: .string)
    }

    /// Past the moment a restore would have happened.
    private func settle() async throws {
        try await Task.sleep(for: Self.restoreDelay + .milliseconds(150))
    }

    /// The timings the app runs with: see `TextInserter.restoreDelay` for where they come from.
    @Test func theAppWaitsForTheTargetWithin400MillisecondsAnd8Seconds() {
        let inserter = TextInserter(pasteboard: privatePasteboard(), system: .init(
            canPostEvents: { false }, modifiersHeld: { false },
            inspectFocus: { .unknown }, pasteKeyCode: { 9 }, postPaste: { _ in false }))
        #expect(inserter.restoreDelay == .milliseconds(400))
        #expect(inserter.readGrace == .milliseconds(200))
        #expect(inserter.unreadTimeout == .seconds(8))
    }

    /// A dictation's paste, and paste last's: ⌘V gets the text, then the clipboard is as it was.
    @Test(arguments: [pid_t?.some(42), nil])
    func everyPastePutsTheClipboardBack(_ expected: pid_t?) async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        copyString("original", to: rig)
        #expect(await rig.inserter.insert("dictated") == .pasted)
        #expect(rig.log.codes == [9])
        #expect(rig.pasteboard.string(forType: .string) == "dictated", "what ⌘V pastes")
        try await waitUntil { rig.pasteboard.string(forType: .string) == "original" }
        #expect(!types(rig).contains(PasteboardMarkers.transientType))
    }

    @Test func pasteHerePutsTheClipboardBack() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        copyString("original", to: rig)
        #expect(await rig.inserter.pasteNow("pasted here") == .pasted)
        #expect(rig.pasteboard.string(forType: .string) == "pasted here")
        try await waitUntil { rig.pasteboard.string(forType: .string) == "original" }
    }

    /// Clipboard managers skip the text (it's only there for the ⌘V), and Universal Clipboard doesn't carry it.
    @Test func thePastedTextIsMarkedTransient() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        copyString("original", to: rig)
        #expect(await rig.inserter.insert("dictated") == .pasted)
        let item = try #require(rig.pasteboard.pasteboardItems?.first)
        for marker in [PasteboardMarkers.transientType, PasteboardMarkers.concealedType,
                       PasteboardMarkers.autoGeneratedType] {
            #expect(item.types.contains(marker), "\(marker.rawValue)")
        }
        #expect(item.string(forType: PasteboardMarkers.sourceType)?.isEmpty == false)
        try await waitUntil { rig.pasteboard.string(forType: .string) == "original" }
    }

    /// Not restored before `restoreDelay`: the target may still be reading the text.
    @Test func theRestoreWaitsForTheDelay() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        rig.inserter.restoreDelay = .milliseconds(400)
        copyString("original", to: rig)
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await rig.inserter.insert("dictated") == .pasted)
        try await Task.sleep(for: .milliseconds(150))
        // A loaded machine may wake this test past the floor.
        if clock.now - start < .milliseconds(400) {
            #expect(rig.pasteboard.string(forType: .string) == "dictated")
        }
        try await waitUntil { rig.pasteboard.string(forType: .string) == "original" }
        #expect(clock.now - start >= .milliseconds(400))
    }

    /// A target busy for a second (a page pladder measured at 1.0 s) reads ⌘V's clipboard after the 400 ms floor: it
    /// still gets the transcript, and the clipboard comes back after it has.
    @Test func aBusyTargetThatReadsAfterASecondStillGetsTheTranscript() async throws {
        let rig = rig(targetReadsAfter: 1.0)
        defer { rig.pasteboard.releaseGlobally() }
        rig.inserter.restoreDelay = .milliseconds(400)
        rig.inserter.unreadTimeout = .seconds(8)
        copyString("previous clipboard", to: rig)
        #expect(await rig.inserter.insert("dictated") == .pasted)
        try await waitUntil { !rig.target.reads.isEmpty }
        #expect(rig.target.reads == ["dictated"], "the busy target pasted \(rig.target.reads)")
        try await waitUntil { rig.pasteboard.string(forType: .string) == "previous clipboard" }
    }

    /// After the target's read the clipboard stays as it is for `readGrace`, for a target that reads again.
    @Test func theClipboardComesBackAGraceAfterTheTargetReadsIt() async throws {
        let rig = rig(targetReadsAfter: 0.2)
        defer { rig.pasteboard.releaseGlobally() }
        rig.inserter.restoreDelay = .milliseconds(50)
        rig.inserter.readGrace = .milliseconds(300)
        copyString("original", to: rig)
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await rig.inserter.insert("dictated") == .pasted)
        try await waitUntil { !rig.target.reads.isEmpty }
        // The read came 200 ms after ⌘V at the earliest, so the grace runs past 500 ms; a loaded machine may wake
        // this test later.
        if clock.now - start < .milliseconds(500) {
            #expect(rig.pasteboard.string(forType: .string) == "dictated", "a second read in the grace still gets it")
        }
        try await waitUntil { rig.pasteboard.string(forType: .string) == "original" }
        #expect(clock.now - start >= .milliseconds(500))
    }

    /// Nothing read the text (⌘V went where nothing takes a paste): the clipboard comes back after `unreadTimeout`.
    @Test func aTextNobodyReadsIsReplacedAfterTheUnreadTimeout() async throws {
        let rig = rig(targetReadsAfter: nil)
        defer { rig.pasteboard.releaseGlobally() }
        rig.inserter.restoreDelay = .milliseconds(50)
        rig.inserter.unreadTimeout = .milliseconds(800)
        copyString("original", to: rig)
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await rig.inserter.insert("dictated") == .pasted)
        // Only the change count is watched: reading the text would count as the target's read.
        let ours = rig.pasteboard.changeCount
        try await Task.sleep(for: .milliseconds(300))
        // A loaded machine may wake this test past the timeout.
        if clock.now - start < .milliseconds(800) {
            #expect(rig.pasteboard.changeCount == ours, "past the floor, still waiting for a read")
        }
        try await waitUntil { rig.pasteboard.changeCount != ours }
        #expect(clock.now - start >= .milliseconds(800))
        #expect(rig.pasteboard.string(forType: .string) == "original")
    }

    /// Images, several items and an app's own types come back byte for byte.
    @Test func aScreenshotAndAFileComeBackExactly() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        copyScreenshotAndFile(to: rig.pasteboard)
        let before = contents(of: rig.pasteboard)
        #expect(before.count == 2)
        #expect(await rig.inserter.insert("dictated") == .pasted)
        #expect(rig.pasteboard.string(forType: .string) == "dictated")
        try await waitUntil { contents(of: rig.pasteboard) == before }
    }

    @Test func anEmptyClipboardIsPutBackEmpty() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        rig.pasteboard.clearContents()
        #expect(await rig.inserter.insert("dictated") == .pasted)
        #expect(rig.pasteboard.string(forType: .string) == "dictated")
        try await waitUntil { rig.pasteboard.pasteboardItems?.isEmpty == true }
    }

    /// The smart leading space goes to the paste, and the clipboard still comes back as it was.
    @Test func theSmartSpaceIsOnlyForThePaste() async throws {
        let rig = rig(focus: Self.afterAWord)
        defer { rig.pasteboard.releaseGlobally() }
        copyString("original", to: rig)
        #expect(await rig.inserter.insert("next words") == .pasted)
        #expect(rig.pasteboard.string(forType: .string) == " next words", "what ⌘V pastes")
        try await waitUntil { rig.pasteboard.string(forType: .string) == "original" }
    }

    /// The second paste finds the first one's text on the clipboard: the user's own clipboard comes back, not it.
    @Test func backToBackPastesPutBackTheClipboardFromBeforeTheFirst() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        rig.inserter.restoreDelay = .milliseconds(500)
        copyScreenshotAndFile(to: rig.pasteboard)
        let before = contents(of: rig.pasteboard)
        #expect(await rig.inserter.insert("first") == .pasted)
        #expect(await rig.inserter.insert("second") == .pasted)
        #expect(rig.pasteboard.string(forType: .string) == "second")
        try await waitUntil { contents(of: rig.pasteboard) == before }
        try await settle()
        #expect(contents(of: rig.pasteboard) == before, "the first paste's restore doesn't run later")
    }

    @Test func aNewCopyDuringTheDelayWins() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        copyString("original", to: rig)
        #expect(await rig.inserter.insert("dictated") == .pasted)
        copyString("copied meanwhile", to: rig)
        try await settle()
        #expect(rig.pasteboard.string(forType: .string) == "copied meanwhile")
    }

    /// A copy made between two pastes is what the second one puts back, not the clipboard from before the first.
    @Test func aCopyBetweenTwoPastesIsWhatComesBack() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        rig.inserter.restoreDelay = .milliseconds(300)
        copyString("before", to: rig)
        #expect(await rig.inserter.insert("first") == .pasted)
        copyString("copied in between", to: rig)
        #expect(await rig.inserter.insert("second") == .pasted)
        try await waitUntil { rig.pasteboard.string(forType: .string) == "copied in between" }
        try await settle()
        #expect(rig.pasteboard.string(forType: .string) == "copied in between")
    }

    /// The app quitting while a restore waits: the clipboard comes back then, not never.
    @Test func quittingPutsTheClipboardBackAtOnce() async {
        let rig = rig(targetReadsAfter: nil)
        defer { rig.pasteboard.releaseGlobally() }
        rig.inserter.restoreDelay = .seconds(5)
        copyScreenshotAndFile(to: rig.pasteboard)
        let before = contents(of: rig.pasteboard)
        #expect(await rig.inserter.insert("dictated") == .pasted)
        rig.inserter.flushPendingRestore()
        #expect(contents(of: rig.pasteboard) == before)
    }

    @Test func quittingAfterANewCopyLeavesIt() async {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        rig.inserter.restoreDelay = .seconds(5)
        copyString("original", to: rig)
        #expect(await rig.inserter.insert("dictated") == .pasted)
        copyString("copied meanwhile", to: rig)
        rig.inserter.flushPendingRestore()
        #expect(rig.pasteboard.string(forType: .string) == "copied meanwhile")
    }

    /// Read while the dictation was transcribed: the paste doesn't read the clipboard again (a type the app can't
    /// render is asked for once), and that snapshot comes back.
    @Test func aClipboardReadAheadIsNotReadAgainAtThePaste() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        let unrendered = LazyType(provides: false)
        let item = NSPasteboardItem()
        item.setString("original", forType: .string)
        item.setDataProvider(unrendered, forTypes: [NSPasteboard.PasteboardType("com.example.canvas")])
        rig.pasteboard.clearContents()
        rig.pasteboard.writeObjects([item])
        rig.inserter.prepareToPaste()
        #expect(unrendered.requests == 1)
        #expect(await rig.inserter.insert("dictated") == .pasted)
        #expect(unrendered.requests == 1, "the paste used the snapshot taken ahead")
        #expect(rig.pasteboard.string(forType: .string) == "dictated")
        try await waitUntil { rig.pasteboard.string(forType: .string) == "original" }
    }

    /// Copied while the dictation was transcribed: the paste reads the clipboard again, and that copy comes back.
    @Test func aCopyAfterTheReadAheadIsWhatComesBack() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        copyString("original", to: rig)
        rig.inserter.prepareToPaste()
        copyString("copied while transcribing", to: rig)
        #expect(await rig.inserter.insert("dictated") == .pasted)
        #expect(rig.pasteboard.string(forType: .string) == "dictated")
        try await waitUntil { rig.pasteboard.string(forType: .string) == "copied while transcribing" }
    }

    /// Copy (History, the cards) is the one way a transcript stays on the clipboard, even right after a paste.
    @Test func anExplicitCopyStays() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        copyString("original", to: rig)
        rig.inserter.copy("copied")
        try await settle()
        #expect(rig.pasteboard.string(forType: .string) == "copied")

        #expect(await rig.inserter.insert("dictated") == .pasted)
        rig.inserter.copy("copied from the card")
        try await settle()
        #expect(rig.pasteboard.string(forType: .string) == "copied from the card")
        #expect(!types(rig).contains(PasteboardMarkers.transientType))
        #expect(!types(rig).contains(PasteboardMarkers.concealedType))
    }

    /// A password manager's copy isn't put back: it would outlive the manager's own clearing.
    @Test func aConcealedClipboardIsClearedNotPutBack() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        let secret = NSPasteboardItem()
        secret.setString("hunter2", forType: .string)
        secret.setData(Data(), forType: PasteboardMarkers.concealedType)
        rig.pasteboard.clearContents()
        rig.pasteboard.writeObjects([secret])
        #expect(await rig.inserter.insert("dictated") == .pasted)
        #expect(rig.pasteboard.string(forType: .string) == "dictated")
        try await waitUntil { rig.pasteboard.pasteboardItems?.isEmpty == true }
    }

    /// A Universal Clipboard photo would first come over from the other device: not read, so the pasted text stays.
    @Test func aClipboardThatCantBeKeptKeepsThePastedText() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        let remote = NSPasteboardItem()
        remote.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        remote.setData(Data(), forType: PasteboardSnapshot.remoteClipboardType)
        rig.pasteboard.clearContents()
        rig.pasteboard.writeObjects([remote])
        #expect(await rig.inserter.insert("dictated") == .pasted)
        try await settle()
        #expect(rig.pasteboard.string(forType: .string) == "dictated")
        #expect(types(rig).contains(PasteboardMarkers.transientType))
    }

    /// ⌘V couldn't be sent: the clipboard is back at once, images and all.
    @Test func aPasteThatFailsPutsTheClipboardBackAtOnce() async {
        let rig = rig(posts: false)
        defer { rig.pasteboard.releaseGlobally() }
        copyScreenshotAndFile(to: rig.pasteboard)
        let before = contents(of: rig.pasteboard)
        if case .failed = await rig.inserter.insert("dictated") {} else {
            Issue.record("Expected a failure when ⌘V can't be sent")
        }
        #expect(contents(of: rig.pasteboard) == before)
    }

    @Test func secureFieldIsRefusedAndTheClipboardLeftAlone() async {
        let rig = rig(focus: FocusInfo(pid: 42, subrole: "AXSecureTextField", editability: .editable, isSecure: true))
        defer { rig.pasteboard.releaseGlobally() }
        copyString("user clipboard", to: rig)
        #expect(await rig.inserter.insert("not a password") == .passwordField)
        #expect(rig.log.codes.isEmpty)
        #expect(rig.pasteboard.string(forType: .string) == "user clipboard")
    }

    /// Whether a text field has the cursor can't be told everywhere (Chrome doesn't say), so it's never guessed: a
    /// button in focus gets the ⌘V as anything else does.
    @Test func anyFocusButAPasswordFieldGetsThePaste() async throws {
        let rig = rig(focus: FocusInfo(pid: 42, role: "AXButton", editability: .notEditable))
        defer { rig.pasteboard.releaseGlobally() }
        #expect(await rig.inserter.insert("hello") == .pasted)
        #expect(rig.log.codes == [9])
        try await settle()
    }

    /// A paste refused in between touches nothing: the pending restore still brings the user's clipboard back.
    @Test func aRefusedPasteLeavesAPendingRestoreAlone() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        rig.inserter.restoreDelay = .milliseconds(500)
        copyString("original", to: rig)
        #expect(await rig.inserter.insert("first") == .pasted)
        rig.focus.focus = FocusInfo(pid: 42, subrole: "AXSecureTextField", editability: .editable, isSecure: true)
        #expect(await rig.inserter.insert("second") == .passwordField)
        #expect(rig.pasteboard.string(forType: .string) == "first")
        try await waitUntil { rig.pasteboard.string(forType: .string) == "original" }
    }

    @Test func unknownFocusPastesAnyway() async throws {
        let rig = rig(focus: FocusInfo(pid: 42, role: "AXWebArea", editability: .unknown))
        defer { rig.pasteboard.releaseGlobally() }
        #expect(await rig.inserter.insert("hello") == .pasted)
        #expect(rig.log.codes == [9])
        try await settle()
    }

    /// The card that follows offers Copy; nothing goes on the clipboard unasked.
    @Test(arguments: [false, true])
    func withoutPermissionNothingIsPastedOrCopied(_ pasteHere: Bool) async {
        let rig = rig(canPost: false)
        defer { rig.pasteboard.releaseGlobally() }
        copyString("user clipboard", to: rig)
        let outcome = await (pasteHere ? rig.inserter.pasteNow("hello") : rig.inserter.insert("hello"))
        #expect(outcome == .accessibilityMissing)
        #expect(rig.log.codes.isEmpty)
        #expect(rig.pasteboard.string(forType: .string) == "user clipboard")
    }

    /// Accessibility granted after launch: the preflight still says no, but the live event tap proves the grant.
    @Test func aRunningEventTapOverridesAStalePreflight() async throws {
        let rig = rig(canPost: false)
        defer { rig.pasteboard.releaseGlobally() }
        rig.inserter.eventTapActive = { true }
        #expect(await rig.inserter.insert("hello") == .pasted)
        #expect(rig.log.codes == [9])
        try await settle()
    }

    @Test func pasteNowSkipsTheFocusCheck() async throws {
        let rig = rig(focus: FocusInfo(pid: 1, editability: .notEditable))
        defer { rig.pasteboard.releaseGlobally() }
        #expect(await rig.inserter.pasteNow("hello") == .pasted)
        #expect(rig.log.codes == [9])
        try await settle()
    }

    @Test func emptyTextFails() async {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        if case .failed = await rig.inserter.insert("") {} else {
            Issue.record("Expected a failure for empty text")
        }
    }
}

@MainActor
@Suite struct PasteboardSnapshotTests {
    @Test func aFilePromiseIsLeftOutAndTheRestOfItsItemKept() throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setData(Data([1, 2, 3]), forType: .png)
        item.setData(Data([4]), forType: NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"))
        item.setString("public.jpeg", forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"))
        let promiseOnly = NSPasteboardItem()
        promiseOnly.setString("file:///x", forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item, promiseOnly])

        let snapshot = try #require(PasteboardSnapshot.capture(pasteboard))
        #expect(snapshot.items.count == 1, "an item with nothing but its promise goes")
        #expect(snapshot.items.first?.entries.map(\.type) == [.png])
    }

    @Test func moreThanTheBudgetIsNotKept() {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(Data(count: 64), forType: .tiff)
        #expect(PasteboardSnapshot.capture(pasteboard, maxBytes: 32) == nil)
        #expect(PasteboardSnapshot.capture(pasteboard, maxBytes: 64) != nil)
    }

    @Test func onlyUniversalClipboardImagesAndFilesAreSlow() {
        let remote = PasteboardSnapshot.remoteClipboardType
        #expect(PasteboardSnapshot.isSlowRemote(types: [[remote, .png]]))
        #expect(PasteboardSnapshot.isSlowRemote(types: [[remote, .fileURL, .pdf]]))
        #expect(PasteboardSnapshot.isSlowRemote(types: [[remote, .fileURL]]), "a file URL is a URL, but its file comes over")
        #expect(!PasteboardSnapshot.isSlowRemote(types: [[remote, .string, .URL, .rtf]]))
        #expect(!PasteboardSnapshot.isSlowRemote(types: [[.png, .tiff], [.fileURL]]))
    }

    /// Types an app renders only when read, one after another: reading stops once it has taken too long.
    @Test func readingStopsAtTheTimeLimit() throws {
        func slowCanvas() -> NSPasteboard {
            let pasteboard = privatePasteboard()
            let item = NSPasteboardItem()
            for name in ["com.example.canvas.a", "com.example.canvas.b", "com.example.canvas.c"] {
                item.setDataProvider(LazyType(delay: 0.06), forTypes: [NSPasteboard.PasteboardType(name)])
            }
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
            return pasteboard
        }
        let slow = slowCanvas()
        defer { slow.releaseGlobally() }
        #expect(PasteboardSnapshot.capture(slow, timeLimit: .milliseconds(100)) == nil)
        let inTime = slowCanvas()
        defer { inTime.releaseGlobally() }
        let snapshot = try #require(PasteboardSnapshot.capture(inTime, timeLimit: .seconds(1)))
        #expect(snapshot.items.first?.entries.count == 3)
    }

    @Test func aPrivatePasteboardMayBeRead() {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        #expect(PasteboardSnapshot.mayRead(pasteboard))
    }
}

// MARK: - Permissions, secure input, login item (pure / preview parts)

@MainActor
@Suite struct SystemServiceTests {
    @Test func fnUsageMapping() {
        #expect(PermissionProbe.fnKeyUsage(.doNothing) == .doNothing)
        #expect(PermissionProbe.fnKeyUsage(.showEmojiAndSymbols) == .other("Emoji & Symbols"))
        #expect(PermissionProbe.fnKeyUsage(.changeInputSource) == .other("Input Sources"))
        #expect(PermissionProbe.fnKeyUsage(.startDictation) == .other("Dictation"))
        #expect(PermissionProbe.fnKeyUsage(nil) == .unknown)
    }

    @Test func previewPermissionsAreInert() {
        let center = PermissionsCenter.preview(mic: .granted, ax: .denied)
        center.refresh()
        center.startPolling()
        #expect(!center.isPolling)
        #expect(!center.allRequiredGranted)
        #expect(PermissionsCenter.preview(mic: .granted, ax: .granted).allRequiredGranted)
    }

    @Test func pollingIsFastOnlyWhileAPermissionsUIOrARequestNeedsIt() {
        typealias P = PermissionsCenter
        #expect(P.pollInterval(ui: nil, background: false, awaitingGrant: false, allGranted: false) == nil)
        #expect(P.pollInterval(ui: nil, background: true, awaitingGrant: false, allGranted: false)
            == P.backgroundPollInterval)
        #expect(P.pollInterval(ui: 0.5, background: true, awaitingGrant: false, allGranted: false) == 0.5)
        #expect(P.pollInterval(ui: nil, background: true, awaitingGrant: true, allGranted: false) == 0.5)
        #expect(P.pollInterval(ui: nil, background: true, awaitingGrant: false, allGranted: true) == 5)
        #expect(P.pollInterval(ui: 0.5, background: false, awaitingGrant: false, allGranted: true) == 5)
    }

    @Test func previewSecureInput() {
        let monitor = SecureInputMonitor.preview(active: true, owningAppName: "Terminal")
        #expect(monitor.isActive)
        #expect(monitor.ownerHint == "possibly Terminal")
        #expect(SecureInputMonitor.preview().owningAppName == nil)
    }

    @Test func previewLaunchAtLogin() throws {
        let login = LaunchAtLogin.preview()
        #expect(!login.isEnabled)
        try login.set(true)
        #expect(login.isEnabled)
        #expect(LaunchAtLogin.preview(status: .requiresApproval).requiresApproval)
    }

    @Test func previewHotkeyMonitorNeverStartsATap() {
        let monitor = HotkeyMonitor.preview()
        #expect(!monitor.start())
        #expect(!monitor.isRunning)
        monitor.suspend()
        monitor.suspend()
        monitor.resume()
        #expect(monitor.isSuspended)
        monitor.resume()
        monitor.resume()
        #expect(!monitor.isSuspended)
    }

    @Test func codeIdentityIsStable() {
        #expect(CodeIdentity.cdhash == CodeIdentity.cdhash)
    }
}

// MARK: - Snapshots (opt-in)

/// `TRANSCRIBE_THING_SNAPSHOT_DIR=<dir> swift test --filter SystemSnapshotTests` renders the recorder gallery.
@MainActor
@Suite struct SystemSnapshotTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRANSCRIBE_THING_SNAPSHOT_DIR"] != nil))
    func renderRecorderGallery() throws {
        let dir = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TRANSCRIBE_THING_SNAPSHOT_DIR"]))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for entry in ShortcutRecorderSnapshots.entries {
            for (label, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = try #require(NSAppearance(named: name))
                let png = try #require(SnapshotRunner.render(entry, appearance: appearance))
                try png.write(to: dir.appendingPathComponent("\(entry.name)-\(label).png"))
            }
        }
    }
}

@MainActor
@Suite struct TextInserterOrderingTests {
    @MainActor private final class Seen { var texts: [String?] = [] }

    /// Each ⌘V goes out with its own text on the clipboard, and the clipboard from before both comes back.
    @Test func overlappingInsertionsRunOneAtATimeAndPutTheClipboardBack() async throws {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let log = PasteLog()
        let seen = Seen()
        let system = TextInserter.System(
            canPostEvents: { true },
            modifiersHeld: { false },
            inspectFocus: {
                try? await Task.sleep(for: .milliseconds(30))
                return FocusInfo(pid: 42, editability: .editable)
            },
            pasteKeyCode: {
                seen.texts.append(pasteboard.string(forType: .string))
                return 9
            },
            postPaste: { code in
                log.record(code)
                return true
            })
        let inserter = TextInserter(pasteboard: pasteboard, system: system)
        inserter.restoreDelay = .milliseconds(60)

        async let first = inserter.insert("first")
        async let second = inserter.insert("second")
        let outcomes = await [first, second]
        #expect(outcomes == [.pasted, .pasted])
        #expect(log.codes == [9, 9])
        #expect(seen.texts.compactMap { $0 }.sorted() == ["first", "second"], "either may go first, each with its own text")
        try await waitUntil { pasteboard.string(forType: .string) == "original" }
        try await Task.sleep(for: .milliseconds(150))
        #expect(pasteboard.string(forType: .string) == "original")
    }
}

@Suite struct ShortcutEditTests {
    private let defaults = ShortcutBindings.defaults
    /// Every macOS shortcut off, 🌐 does nothing.
    private let quiet = SystemKeyboardState(hotKeys: [], fnUsage: .doNothing)
    /// Every default macOS shortcut on.
    private let stock = SystemKeyboardState(hotKeys: SystemSymbolicHotKeys.active(in: nil), fnUsage: .doNothing)

    private func evaluate(_ shortcut: Shortcut, for action: ShortcutAction, bindings: ShortcutBindings? = nil,
                          swapAllowed: Bool = true, system: SystemKeyboardState? = nil) -> ShortcutEdit.Outcome {
        ShortcutEdit.evaluate(shortcut, for: action, bindings: bindings ?? defaults, swapAllowed: swapAllowed,
                              system: system ?? quiet)
    }

    @Test func sameShortcutIsUnchanged() {
        #expect(evaluate(.fn, for: .pushToTalk) == .unchanged)
    }

    @Test func rightOptionIsAppliedCleanly() {
        #expect(evaluate(.rightOption, for: .pushToTalk) == .apply(warning: nil))
    }

    @Test func plainOptionAppliesWithAWarning() {
        let outcome = evaluate(Shortcut(modifiers: [.init(.option)]), for: .pushToTalk)
        guard case .apply(let warning?) = outcome else {
            Issue.record("Expected a warning, got \(outcome)")
            return
        }
        #expect(warning.kind == .loneModifier)
        #expect(warning.detail?.contains("Right ⌥") == true)
    }

    @Test func loneModifiersSuggestTheRightHandKey() {
        #expect(ShortcutEdit.betterSide(for: Shortcut(modifiers: [.init(.option)])) == .rightOption)
        #expect(ShortcutEdit.betterSide(for: Shortcut(modifiers: [.init(.command, .left)]))
            == Shortcut(modifiers: [.init(.command, .right)]))
        #expect(ShortcutEdit.betterSide(for: Shortcut(modifiers: [.init(.control)]))
            == Shortcut(modifiers: [.init(.control, .right)]))
        // Nothing better to offer: already right-handed, fn, shift, chords and key combos.
        #expect(ShortcutEdit.betterSide(for: .rightOption) == nil)
        #expect(ShortcutEdit.betterSide(for: .fn) == nil)
        #expect(ShortcutEdit.betterSide(for: Shortcut(modifiers: [.init(.shift)])) == nil)
        #expect(ShortcutEdit.betterSide(for: Shortcut(modifiers: [.init(.control), .init(.option)])) == nil)
        #expect(ShortcutEdit.betterSide(for: .fnSpace) == nil)
    }

    @Test func systemCombosAreSavedAndWarnOnlyWhileMacOSUsesThem() {
        let controlSpace = Shortcut(modifiers: [.init(.control)], keyCode: KeyCode.space)
        #expect(evaluate(controlSpace, for: .handsFree, system: quiet) == .apply(warning: nil))
        guard case .apply(let warning?) = evaluate(controlSpace, for: .handsFree, system: stock) else {
            Issue.record("⌃Space must be saved with a warning while input-source switching is on")
            return
        }
        #expect(warning.kind == .systemShortcut)
        #expect(warning.text == "macOS also uses ⌃Space for input sources.")

        let spotlight = Shortcut(modifiers: [.init(.command)], keyCode: KeyCode.space)
        #expect(evaluate(spotlight, for: .pushToTalk, system: quiet) == .apply(warning: nil))
        guard case .apply(.some) = evaluate(spotlight, for: .pushToTalk, system: stock) else {
            Issue.record("⌘Space must be saved with a warning while Spotlight uses it")
            return
        }
    }

    @Test func escapeIsSavedWithAWarning() {
        guard case .apply(let warning?) = evaluate(.escape, for: .pasteLast) else {
            Issue.record("Esc must be saved with a warning")
            return
        }
        #expect(warning.kind == .escape)
    }

    @Test func conflictOffersSwapWhenTheOtherActionCanTakeOurs() {
        #expect(evaluate(.fnSpace, for: .pasteLast) == .offerSwap(.handsFree))
        #expect(evaluate(.fnSpace, for: .pasteLast, swapAllowed: false)
            == .reject("Hands-free already uses this shortcut."))
        // Paste last may take fn: push to talk gets ⌘ fn V.
        #expect(evaluate(.fn, for: .pasteLast) == .offerSwap(.pushToTalk))
    }

    @Test func noSwapWhenTheOtherActionCantTakeOurs() {
        // Paste last is ⌃, hands-free ⌃⌥: switch model taking ⌃ would go off on the way to hands-free.
        var bindings = defaults
        bindings[.handsFree] = Shortcut(modifiers: [.init(.control), .init(.option)])
        bindings[.pasteLast] = Shortcut(modifiers: [.init(.control)])
        #expect(evaluate(.fnTab, for: .pasteLast, bindings: bindings)
            == .reject("Switch model already uses this shortcut."))
    }

    @Test func swapWarnsAboutEitherNewBinding() {
        // Paste last, on Esc, takes fn: push to talk gets Esc.
        var escapePaste = defaults
        escapePaste[.pasteLast] = .escape
        let swapped = ShortcutEdit.swapping(escapePaste, action: .pasteLast, to: .fn, with: .pushToTalk)
        #expect(ShortcutEdit.warningAfterSwap(swapped, action: .pasteLast, other: .pushToTalk, system: quiet)?.kind
                == .escape)
        let clean = ShortcutEdit.swapping(defaults, action: .pasteLast, to: .fnSpace, with: .handsFree)
        #expect(ShortcutEdit.warningAfterSwap(clean, action: .pasteLast, other: .handsFree, system: quiet) == nil)
    }

    @Test func sidesThatCanMeetConflict() {
        // Right ⌥ push to talk (onboarding's alternative) and a lone ⌥ recorded for hands-free.
        let rightOptionPTT = bindings([.pushToTalk: .rightOption])
        let option = Shortcut(modifiers: [.init(.option)])
        #expect(ShortcutValidator.validate(option, for: .handsFree, bindings: rightOptionPTT, system: quiet).conflict
            == .pushToTalk)
        #expect(ShortcutValidator.validate(Shortcut(modifiers: [.init(.option, .left)]), for: .handsFree,
                                           bindings: rightOptionPTT, system: quiet).conflict == nil)
        // ⌃⌘C (either side) would make a ⌘ left⌃ C paste last unreachable.
        let sidedPasteLast = bindings([.pasteLast: Shortcut(modifiers: [.init(.command), .init(.control, .left)],
                                                            keyCode: KeyCode.ansiC)])
        let controlCommandC = Shortcut(modifiers: [.init(.control), .init(.command)], keyCode: KeyCode.ansiC)
        #expect(ShortcutValidator.validate(controlCommandC, for: .handsFree, bindings: sidedPasteLast, system: quiet).conflict
            == .pasteLast)
    }

    @Test func aChordMustNotStartAnotherModifierOnlyBinding() {
        let controlOption = Shortcut(modifiers: [.init(.control), .init(.option)])
        let control = Shortcut(modifiers: [.init(.control, .right)])
        // Hands-free ⌃ would fire on the way to a ⌃⌥ push to talk.
        let ptt = bindings([.pushToTalk: controlOption])
        guard case .reject = evaluate(control, for: .handsFree, bindings: ptt) else {
            Issue.record("a prefix of push to talk must be rejected")
            return
        }
        // And the other way round: push to talk ⌃⌥ while hands-free is ⌃.
        let handsFree = bindings([.handsFree: control])
        guard case .reject = evaluate(controlOption, for: .pushToTalk, bindings: handsFree) else {
            Issue.record("push to talk must not start with another modifier-only binding")
            return
        }
        // Push to talk as the start of a modifier-only hands-free is intended.
        let fnControl = Shortcut(modifiers: [.init(.function), .init(.control)])
        guard case .apply = evaluate(fnControl, for: .handsFree) else {
            Issue.record("fn ⌃ for hands-free next to an fn push to talk must be accepted")
            return
        }
    }

    @Test func swappingExchangesBothBindings() {
        let swapped = ShortcutEdit.swapping(defaults, action: .pasteLast, to: .fnSpace, with: .handsFree)
        #expect(swapped[.pasteLast] == .fnSpace)
        #expect(swapped[.handsFree] == .commandFnV)
    }
}

// MARK: - Switch model in the router

/// The switch model shortcut is live only during a dictation, never ends the push-to-talk hold, and tolerates
/// the PTT's modifiers still being held, whatever it is bound to.
@Suite struct SwitchModelRouterTests {
    @Test func fnTabWhileHoldingFnCyclesAndTheHoldGoesOn() {
        var kb = Keyboard()
        #expect(kb.press(.fn).events == [.pttDown])
        let tab = kb.down(kVK_Tab)
        #expect(tab.events == [.cycleEngine])
        #expect(tab.swallow)
        let repeated = kb.down(kVK_Tab, isRepeat: true)
        #expect(repeated.events == [.cycleEngineRepeat], "held down, it keeps stepping (at the controller's pace)")
        #expect(repeated.swallow)
        #expect(kb.up(kVK_Tab).swallow)
        #expect(kb.down(kVK_Tab).events == [.cycleEngine], "every press steps")
        kb.up(kVK_Tab)
        #expect(kb.release(.fn).events == [.pttUp], "releasing fn still ends the dictation, not an interruption")
    }

    @Test func otherFnCombosStillInterrupt() {
        var kb = Keyboard()
        kb.press(.fn)
        let left = kb.down(kVK_LeftArrow, fnFlagged: true)
        #expect(left.events == [.pttInterrupted])
        #expect(!left.swallow)
        kb.up(kVK_LeftArrow, fnFlagged: true)
        kb.release(.fn)
        kb.press(.fn)
        #expect(kb.press(.leftCommand).events == [.pttInterrupted], "an extra modifier fn+Tab doesn't use")
    }

    @Test func tabWithoutFnAndOutsideADictationPassesThrough() {
        var kb = Keyboard()
        let idle = kb.down(kVK_Tab)
        #expect(idle.events.isEmpty && !idle.swallow)
        kb.up(kVK_Tab)
        // Hands-free is recording, fn is up: a plain Tab types.
        kb.config.isRecording = true
        let plain = kb.down(kVK_Tab)
        #expect(plain.events.isEmpty && !plain.swallow)
        #expect(!kb.up(kVK_Tab).swallow)
    }

    /// Hands-free: fn goes down (the machine arms stop-on-release), Tab steps, fn comes up again.
    @Test func handsFreeFnTabCycles() {
        var kb = Keyboard()
        kb.config.isRecording = true
        #expect(kb.press(.fn).events == [.pttDown])
        #expect(kb.down(kVK_Tab).events == [.cycleEngine])
        kb.up(kVK_Tab)
        #expect(kb.release(.fn).events == [.pttUp])
    }

    @Test func aCycleOfOneMeansTabIsNotIntercepted() {
        var kb = Keyboard()
        kb.config.switchesModels = false
        kb.press(.fn)
        let tab = kb.down(kVK_Tab)
        #expect(tab.events == [.pttInterrupted])
        #expect(!tab.swallow)
    }

    @Test func aCustomComboWorksWithFnStillHeld() {
        let commandShiftM = Shortcut(modifiers: [.init(.command), .init(.shift)], keyCode: UInt16(kVK_ANSI_M))
        var kb = Keyboard(bindings: bindings([.switchModel: commandShiftM]))
        #expect(kb.press(.fn).events == [.pttDown])
        #expect(kb.press(.leftCommand).events.isEmpty, "⌘ may be on the way to ⌘⇧M")
        #expect(kb.press(.leftShift).events.isEmpty)
        let m = kb.down(kVK_ANSI_M)
        #expect(m.events == [.cycleEngine])
        #expect(m.swallow)
        kb.up(kVK_ANSI_M)
        #expect(kb.release(.leftShift).events.isEmpty)
        #expect(kb.release(.leftCommand).events.isEmpty)
        #expect(kb.release(.fn).events == [.pttUp])

        // ⌘C on the way isn't it: that interrupts, and C reaches the app.
        kb.press(.fn)
        kb.press(.leftCommand)
        let copy = kb.down(kVK_ANSI_C)
        #expect(copy.events == [.pttInterrupted])
        #expect(!copy.swallow)
        kb.up(kVK_ANSI_C)
        kb.release(.leftCommand)
        kb.release(.fn)

        // Fn fn Tab is no longer anything special.
        kb.press(.fn)
        #expect(kb.down(kVK_Tab).events == [.pttInterrupted])
        kb.up(kVK_Tab)
        kb.release(.fn)

        // Hands-free: ⌘⇧M steps; outside a dictation it reaches the app.
        kb.config.isRecording = true
        kb.press(.leftCommand)
        kb.press(.leftShift)
        #expect(kb.down(kVK_ANSI_M).events == [.cycleEngine])
        kb.up(kVK_ANSI_M)
        kb.config.isRecording = false
        let outside = kb.down(kVK_ANSI_M)
        #expect(outside.events.isEmpty && !outside.swallow)
    }

    @Test func aModifierOnlyChordWorksDuringPushToTalkAndHandsFree() {
        var kb = Keyboard(bindings: bindings([.switchModel: .rightCommand]))
        kb.press(.fn)
        #expect(kb.press(.rightCommand).events == [.cycleEngine])
        #expect(kb.release(.rightCommand).events.isEmpty)
        #expect(kb.press(.rightCommand).events == [.cycleEngine], "pressed again, it steps again")
        kb.release(.rightCommand)
        #expect(kb.release(.fn).events == [.pttUp])

        kb.config.isRecording = true
        #expect(kb.press(.rightCommand).events == [.cycleEngine])
        kb.release(.rightCommand)
        kb.config.isRecording = false
        #expect(kb.press(.rightCommand).events.isEmpty)
    }

    /// A modifier-only chord that starts with the PTT's own fn.
    @Test func anFnChordAsTheSwitchKeyWorksWithFnPushToTalk() {
        let fnControl = Shortcut(modifiers: [.init(.function), .init(.control)])
        var kb = Keyboard(bindings: bindings([.switchModel: fnControl]))
        #expect(kb.press(.fn).events == [.pttDown])
        #expect(kb.press(.leftControl).events == [.cycleEngine])
        #expect(kb.release(.leftControl).events.isEmpty)
        #expect(kb.release(.fn).events == [.pttUp])
    }

    @Test func fnTabWorksWithAnotherPushToTalkHeld() {
        var kb = Keyboard(bindings: bindings([.pushToTalk: .rightOption]))
        #expect(kb.press(.rightOption).events == [.pttDown])
        #expect(kb.press(.fn).events.isEmpty, "fn is on the way to fn+Tab")
        #expect(kb.down(kVK_Tab).events == [.cycleEngine])
        kb.up(kVK_Tab)
        #expect(kb.release(.fn).events.isEmpty)
        #expect(kb.release(.rightOption).events == [.pttUp])
    }

    /// A switch key without modifiers still leaves fn+Space to hands-free: the exact match wins over the loose one
    /// that sets the held fn aside.
    @Test func aPlainSwitchKeyLeavesTheHandsFreeChordAlone() {
        let space = Shortcut(modifiers: [], keyCode: KeyCode.space)
        #expect(ShortcutValidator.validate(space, for: .switchModel).errors.isEmpty, "the validator accepts it")
        var kb = Keyboard(bindings: bindings([.switchModel: space]))
        #expect(kb.press(.fn).events == [.pttDown])
        #expect(kb.down(kVK_Space).events == [.handsFreeToggle], "fn+Space while holding fn locks hands-free")
        kb.up(kVK_Space)
        kb.release(.fn)

        // Hands-free: a plain Space steps, fn+Space is still the hands-free chord.
        kb.config.isRecording = true
        let plain = kb.down(kVK_Space)
        #expect(plain.events == [.cycleEngine])
        #expect(plain.swallow)
        kb.up(kVK_Space)
        #expect(kb.press(.fn).events == [.pttDown])
        #expect(kb.down(kVK_Space).events == [.handsFreeToggle])
    }

    @Test func nothingFiresWhileTheRecorderCaptures() {
        var kb = Keyboard()
        kb.config.isRecording = true
        kb.config.isSuspended = true
        kb.press(.fn)
        let tab = kb.down(kVK_Tab)
        #expect(tab.events.isEmpty && !tab.swallow)
    }
}

// MARK: - Holding a modifier-only Switch model

/// `Keyboard` with the tap engine's repeat timer on a fake clock: a `.start` schedules ticks (after the delay, then
/// every interval), `.stop` cancels them, and `advance(to:)` feeds the router the ticks that fall due. Times are in ms.
private struct ClockedKeyboard {
    var kb: Keyboard
    private(set) var now = 0
    private var nextTick: Int?
    private var interval = 0
    /// Every event, with the time it came.
    private(set) var log: [Stamped] = []

    struct Stamped: Equatable, CustomStringConvertible {
        var at: Int
        var event: HotkeyEvent
        var description: String { "\(at): \(event)" }
    }

    init(bindings: ShortcutBindings, keyRepeat: KeyRepeat? = KeyRepeat(delay: 0.25, interval: 0.05)) {
        kb = Keyboard(bindings: bindings)
        kb.config.keyRepeat = keyRepeat
    }

    var isTicking: Bool { nextTick != nil }

    @discardableResult mutating func press(_ m: Keyboard.Modifier) -> HotkeyRouter.Decision { apply(kb.press(m)) }
    @discardableResult mutating func release(_ m: Keyboard.Modifier) -> HotkeyRouter.Decision { apply(kb.release(m)) }
    @discardableResult mutating func down(_ key: Int, isRepeat: Bool = false) -> HotkeyRouter.Decision {
        apply(kb.down(key, isRepeat: isRepeat))
    }
    @discardableResult mutating func up(_ key: Int) -> HotkeyRouter.Decision { apply(kb.up(key)) }
    @discardableResult mutating func click() -> HotkeyRouter.Decision { apply(kb.click()) }

    /// Moves the clock to `ms`, firing every tick due on the way.
    mutating func advance(to ms: Int) {
        while let tick = nextTick, tick <= ms {
            now = tick
            nextTick = tick + interval
            apply(kb.send(HotkeyInput(kind: .repeatTick)))
        }
        now = ms
    }

    /// The events logged from `ms` on.
    func events(from ms: Int) -> [Stamped] { log.filter { $0.at >= ms } }

    @discardableResult
    private mutating func apply(_ decision: HotkeyRouter.Decision) -> HotkeyRouter.Decision {
        log += decision.events.map { Stamped(at: now, event: $0) }
        switch decision.repeatTimer {
        case .start(let keyRepeat):
            nextTick = now + Int((keyRepeat.delay * 1000).rounded())
            interval = Int((keyRepeat.interval * 1000).rounded())
        case .stop: nextTick = nil
        case nil: break
        }
        return decision
    }
}

/// Modifiers don't autorepeat: a modifier-only Switch model held steps on at the keyboard's repeat pace, on the
/// engine's timer, the way fn Tab held steps on at every autorepeat.
@Suite struct HeldSwitchModelRouterTests {
    /// The user's own bindings: push to talk is Right ⌃ alone, Switch model is Right ⌃ + ⌘, the rest are ⌃ + a key.
    private static let usersBindings: ShortcutBindings = {
        let json = """
        {"addToDictionary":{"keyCode":2,"modifiers":[{"modifier":"control","side":"either"}]},\
        "handsFree":{"keyCode":49,"modifiers":[{"modifier":"control","side":"either"}]},\
        "pasteLast":{"keyCode":9,"modifiers":[{"modifier":"control","side":"either"}]},\
        "polish":{"keyCode":35,"modifiers":[{"modifier":"control","side":"either"}]},\
        "pushToTalk":{"modifiers":[{"modifier":"control","side":"right"}]},\
        "switchModel":{"modifiers":[{"modifier":"control","side":"right"},{"modifier":"command","side":"either"}]},\
        "translate":{"keyCode":17,"modifiers":[{"modifier":"control","side":"either"}]}}
        """
        return try! JSONDecoder().decode(ShortcutBindings.self, from: Data(json.utf8))
    }()

    private func steps(_ log: [ClockedKeyboard.Stamped]) -> [Int] {
        log.filter { $0.event == .cycleEngineRepeat }.map(\.at)
    }

    @Test func theUsersBindingsAreWhatTheyLookLike() {
        #expect(Self.usersBindings[.pushToTalk] == Shortcut(modifiers: [.init(.control, .right)]))
        #expect(Self.usersBindings[.switchModel] == Shortcut(modifiers: [.init(.control, .right), .init(.command)]))
        #expect(Self.usersBindings[.switchModel]?.isModifierOnly == true)
    }

    @Test func heldItStepsAtOnceThenAtTheKeyboardsRepeatPaceUntilReleased() {
        var kb = ClockedKeyboard(bindings: Self.usersBindings)
        #expect(kb.press(.rightControl).events == [.pttDown])
        kb.advance(to: 1000)
        let press = kb.press(.leftCommand)
        #expect(press.events == [.cycleEngine], "the first step comes on the press, as before")
        #expect(press.repeatTimer == .start(KeyRepeat(delay: 0.25, interval: 0.05)))
        #expect(!press.swallow, "modifier events are never swallowed")
        kb.advance(to: 1249)
        #expect(kb.events(from: 1001).isEmpty, "nothing before the keyboard's delay until repeat")
        kb.advance(to: 1400)
        #expect(steps(kb.events(from: 1001)) == [1250, 1300, 1350, 1400])
        #expect(kb.events(from: 1001).allSatisfy { $0.event == .cycleEngineRepeat })

        let release = kb.release(.leftCommand)
        #expect(release.events.isEmpty, "letting go of ⌘ doesn't end the dictation")
        #expect(release.repeatTimer == .stop)
        kb.advance(to: 3000)
        #expect(steps(kb.events(from: 1401)).isEmpty)

        // Right ⌃ is still push to talk: ⌘ again steps again, and releasing ⌃ ends the dictation.
        #expect(kb.press(.leftCommand).events == [.cycleEngine])
        kb.advance(to: 3250)
        #expect(steps(kb.events(from: 3000)) == [3250])
        kb.release(.leftCommand)
        #expect(kb.release(.rightControl).events == [.pttUp])
        #expect(!kb.isTicking)
    }

    @Test func releasingControlFirstEndsTheDictationAndTheSteps() {
        var kb = ClockedKeyboard(bindings: Self.usersBindings)
        kb.press(.rightControl)
        kb.press(.rightCommand)
        kb.advance(to: 300)
        #expect(steps(kb.log) == [250, 300])
        let release = kb.release(.rightControl)
        #expect(release.events == [.pttUp], "releasing the push-to-talk key ends the dictation as before")
        #expect(release.repeatTimer == .stop)
        kb.advance(to: 2000)
        #expect(steps(kb.log) == [250, 300])
    }

    @Test func pushToTalkAloneNeverTicks() {
        var kb = ClockedKeyboard(bindings: Self.usersBindings)
        let press = kb.press(.rightControl)
        #expect(press.events == [.pttDown])
        #expect(press.repeatTimer == nil)
        kb.advance(to: 2000)
        #expect(kb.release(.rightControl).events == [.pttUp])
        #expect(kb.log.map(\.event) == [.pttDown, .pttUp])
    }

    @Test func anotherKeyOrAClickStopsIt() {
        var kb = ClockedKeyboard(bindings: Self.usersBindings)
        kb.press(.rightControl)
        kb.press(.leftCommand)
        kb.advance(to: 250)
        #expect(kb.down(kVK_ANSI_A).repeatTimer == .stop, "another key is something else")
        kb.up(kVK_ANSI_A)
        kb.advance(to: 1000)
        #expect(steps(kb.log) == [250])
        kb.release(.leftCommand)
        kb.release(.rightControl)

        // A click (opening the pill's model menu, say) stops it; the dictation goes on.
        kb.advance(to: 2000)
        kb.press(.rightControl)
        kb.press(.leftCommand)
        let click = kb.click()
        #expect(click.events.isEmpty)
        #expect(click.repeatTimer == .stop)
        kb.advance(to: 3000)
        #expect(steps(kb.events(from: 2000)).isEmpty)
        kb.release(.leftCommand)
        #expect(kb.release(.rightControl).events == [.pttUp])
    }

    @Test func anExtraModifierStopsItAndLettingGoOfItDoesntRestartIt() {
        var kb = ClockedKeyboard(bindings: Self.usersBindings)
        kb.press(.rightControl)
        kb.press(.leftCommand)
        #expect(kb.press(.leftShift).repeatTimer == .stop)
        #expect(kb.release(.leftShift).repeatTimer == nil)
        kb.advance(to: 2000)
        #expect(steps(kb.log).isEmpty)
    }

    @Test func noStepsOnceTheDictationEnds() {
        // Hands-free (no push to talk held) with a Right ⌘ Switch model.
        var kb = ClockedKeyboard(bindings: bindings([.switchModel: .rightCommand]))
        kb.kb.config.isRecording = true
        #expect(kb.press(.rightCommand).events == [.cycleEngine])
        kb.advance(to: 300)
        #expect(steps(kb.log) == [250, 300])
        // The dictation stops while ⌘ is still down: the next tick steps no more and stops the timer.
        kb.kb.config.isRecording = false
        kb.advance(to: 2000)
        #expect(steps(kb.log) == [250, 300])
        #expect(!kb.isTicking)
        kb.release(.rightCommand)

        // Outside a dictation the chord is the app's: nothing fires, nothing ticks.
        let outside = kb.press(.rightCommand)
        #expect(outside.events.isEmpty)
        #expect(outside.repeatTimer == nil)
        kb.advance(to: 4000)
        #expect(steps(kb.log) == [250, 300])
    }

    @Test func theRecorderCapturingStopsIt() {
        var kb = ClockedKeyboard(bindings: Self.usersBindings)
        kb.press(.rightControl)
        kb.press(.leftCommand)
        kb.kb.config.isSuspended = true
        kb.advance(to: 1000)
        #expect(steps(kb.log).isEmpty)
        #expect(!kb.isTicking)
    }

    @Test func aStateResetStopsTheTimerOnItsNextTick() {
        var kb = ClockedKeyboard(bindings: Self.usersBindings)
        kb.press(.rightControl)
        kb.press(.leftCommand)
        _ = kb.kb.router.reset()
        kb.advance(to: 1000)
        #expect(steps(kb.log).isEmpty)
        #expect(!kb.isTicking)
    }

    @Test func withKeyRepeatOffItStepsOncePerPress() {
        var kb = ClockedKeyboard(bindings: Self.usersBindings, keyRepeat: nil)
        kb.press(.rightControl)
        let press = kb.press(.leftCommand)
        #expect(press.events == [.cycleEngine])
        #expect(press.repeatTimer == nil)
        kb.advance(to: 2000)
        #expect(steps(kb.log).isEmpty)
    }

    @Test func aCycleOfOneNeitherStepsNorTicks() {
        var kb = ClockedKeyboard(bindings: Self.usersBindings)
        kb.kb.config.switchesModels = false
        kb.press(.rightControl)
        let press = kb.press(.leftCommand)
        #expect(press.repeatTimer == nil)
        #expect(!press.events.contains(.cycleEngine))
    }

    /// fn Tab keeps the keyboard's own autorepeat: no timer.
    @Test func keyedFnTabStillRidesTheKeyboardsAutorepeat() {
        var kb = ClockedKeyboard(bindings: .defaults)
        kb.press(.fn)
        let tab = kb.down(kVK_Tab)
        #expect(tab.events == [.cycleEngine])
        #expect(tab.repeatTimer == nil)
        kb.advance(to: 1000)
        #expect(steps(kb.log).isEmpty, "no ticks of our own")
        let repeated = kb.down(kVK_Tab, isRepeat: true)
        #expect(repeated.events == [.cycleEngineRepeat])
        #expect(repeated.repeatTimer == nil)
        kb.up(kVK_Tab)
        #expect(kb.release(.fn).events == [.pttUp])
        #expect(!kb.isTicking)
    }

    @Test func theSystemsTimingIsClampedAndOffMeansNoRepeat() {
        #expect(KeyRepeat(systemDelay: 0.225, interval: 0.03) == KeyRepeat(delay: 0.225, interval: 0.05))
        #expect(KeyRepeat(systemDelay: 0.01, interval: 0.5) == KeyRepeat(delay: 0.1, interval: 0.5))
        #expect(KeyRepeat(systemDelay: 0.5, interval: 4500) == nil)
        #expect(KeyRepeat(systemDelay: .infinity, interval: 0.1) == nil)
    }
}

// MARK: - Pasted text

@Suite struct PastedTextTests {
    private func prepare(_ text: String, space: Bool = false, period: Bool = false) -> String {
        PastedText.prepare(text, addsSpace: space, removesFinalPeriod: period)
    }

    @Test func aSingleFinalPeriodGoes() {
        #expect(prepare("Hello.", period: true) == "Hello")
        #expect(prepare("Два предложения. Второе.", period: true) == "Два предложения. Второе")
    }

    /// An ellipsis, a question, an exclamation, a quote closing after the period and a lone period stay.
    @Test(arguments: ["Wait...", "Wait..", "Really?", "Wow!", "Hi…", ".", "", #"He said "hi.""#])
    func everythingElseStays(_ text: String) {
        #expect(prepare(text, period: true) == text)
    }

    @Test func aSpaceGoesAfterAnyText() {
        #expect(prepare("Hello", space: true) == "Hello ")
        #expect(prepare("Hello.", space: true) == "Hello. ")
        #expect(prepare("", space: true) == "", "nothing to follow")
    }

    @Test func bothTogether() {
        #expect(prepare("Hello.", space: true, period: true) == "Hello ")
        #expect(prepare("Really?", space: true, period: true) == "Really? ")
    }

    @Test(arguments: ["Hello.", "Wait...", " spaced ", ""])
    func bothOffChangeNothing(_ text: String) {
        #expect(prepare(text) == text)
    }
}

// MARK: - Add to dictionary's key

@Suite struct AddToDictionaryRouterTests {
    /// During a dictation fn D is always held, on any model, for the controller to read what's selected right then;
    /// unbound (or between dictations) it's the app's.
    @Test func fnDIsHeldDuringADictation() {
        var kb = Keyboard()
        #expect(kb.press(.fn).events == [.pttDown])
        let held = kb.down(kVK_ANSI_D, fnFlagged: true)
        #expect(held.swallow)
        if case .heldForSelection(.addToDictionary, let key) = held.events.first {
            #expect(key.keyCode == UInt16(kVK_ANSI_D))
        } else {
            Issue.record("expected heldForSelection, got \(held.events)")
        }
        #expect(kb.up(kVK_ANSI_D, fnFlagged: true).swallow)
        kb.release(.fn)
        #expect(!kb.down(kVK_ANSI_D).swallow, "between dictations D is just D")
        kb.up(kVK_ANSI_D)

        kb.config.bindings[.addToDictionary] = nil
        kb.press(.fn)
        #expect(!kb.down(kVK_ANSI_D, fnFlagged: true).swallow)
    }
}

// MARK: - Return in hands-free

@MainActor
@Suite(.serialized) struct ReturnInHandsFreeTests {
    /// Return and Keypad Enter during a hands-free dictation are the app's: the tap neither takes them nor reports
    /// anything, and the dictation records on. Only fn and the pill's check button finish it.
    @Test func returnDuringHandsFreeGoesToTheApp() {
        let (rig, _) = SwitchModelControllerTests.make()
        let c = rig.h.controller
        c.send(.handsFreeToggle)
        #expect(c.machine.mode == .handsFree && c.machine.isRecording)
        var kb = Keyboard()
        kb.config = rig.h.hotkeys.currentConfig()
        #expect(kb.config.isRecording && kb.config.isBusy)
        for key in [kVK_Return, kVK_ANSI_KeypadEnter] {
            let down = kb.down(key)
            #expect(down.events.isEmpty && !down.swallow, "key \(key) reaches the app")
            #expect(!kb.down(key, isRepeat: true).swallow)
            #expect(!kb.up(key).swallow)
        }
        #expect(c.machine.mode == .handsFree && c.machine.isRecording, "still recording")
        c.send(.pillCancel)
    }
}

// MARK: - Send

@Suite struct SendRouterTests {
    /// Right ⌃ to talk, Send on ⌃↩ (what the user's saved bindings load as).
    private static var rightControl: ShortcutBindings {
        bindings([.pushToTalk: SendShortcutTests.rightControl, .send: SendShortcutTests.controlReturn])
    }

    /// fn ↩ while holding fn: Send, swallowed, the hold going on. A laptop's fn ↩ comes as Keypad Enter. Held down, it
    /// doesn't turn Send on and off: its autorepeats are swallowed and say nothing.
    @Test(arguments: [kVK_Return, kVK_ANSI_KeypadEnter])
    func fnReturnWhileHoldingFn(_ key: Int) {
        var kb = Keyboard()
        #expect(kb.press(.fn).events == [.pttDown])
        let send = kb.down(key, fnFlagged: true)
        #expect(send.events == [.send] && send.swallow)
        for _ in 0..<3 {
            let repeated = kb.down(key, isRepeat: true, fnFlagged: true)
            #expect(repeated.events.isEmpty && repeated.swallow)
        }
        #expect(kb.up(key, fnFlagged: true).swallow)
        #expect(kb.release(.fn).events == [.pttUp], "still the dictation's hold")
    }

    /// The user's keys: Right ⌃ held, ↩ is Send; in hands-free, ⌃↩ with either ⌃. Outside a dictation ⌃↩ is the app's.
    @Test func controlReturnWithRightControlToTalk() {
        var kb = Keyboard(bindings: Self.rightControl)
        let outside = kb.down(kVK_Return)
        #expect(outside.events.isEmpty && !outside.swallow, "plain ↩ outside a dictation")
        kb.up(kVK_Return)
        kb.press(.leftControl)
        let notRecording = kb.down(kVK_Return)
        #expect(notRecording.events.isEmpty && !notRecording.swallow, "⌃↩ reaches the app outside a dictation")
        kb.up(kVK_Return)
        kb.release(.leftControl)

        #expect(kb.press(.rightControl).events == [.pttDown])
        let send = kb.down(kVK_Return)
        #expect(send.events == [.send] && send.swallow)
        #expect(kb.up(kVK_Return).swallow)
        #expect(kb.release(.rightControl).events == [.pttUp])

        kb.config.isRecording = true
        kb.press(.leftControl)
        let handsFree = kb.down(kVK_Return)
        #expect(handsFree.events == [.send] && handsFree.swallow, "hands-free: left ⌃ ↩ too")
        #expect(kb.down(kVK_Return, isRepeat: true).events.isEmpty)
        kb.up(kVK_Return)
        kb.release(.leftControl)
        // Plain ↩ during hands-free stays the app's: only the binding is taken.
        let plain = kb.down(kVK_Return)
        #expect(plain.events.isEmpty && !plain.swallow)
    }

    /// Send's own Return (tagged as ours) passes straight through, even while a dictation records and a card is up.
    @Test func ourReturnPassesThrough() {
        var kb = Keyboard()
        kb.config.isRecording = true
        kb.config.cardPaste = true
        kb.press(.fn)
        let ours = kb.down(kVK_Return, synthetic: true)
        #expect(ours.events.isEmpty && !ours.swallow)
    }

    /// Unbound, nothing is taken.
    @Test func unboundItIsNeverTaken() {
        var kb = Keyboard(bindings: bindings([.send: nil]))
        #expect(kb.press(.fn).events == [.pttDown])
        let enter = kb.down(kVK_ANSI_KeypadEnter, fnFlagged: true)
        #expect(!enter.events.contains(.send))
    }

    /// The machine hands the key on from every recording state, and fn ↩'s fn press doesn't finish hands-free.
    @Test func theMachineHandsItOn() {
        var machine = DictationMachine()
        _ = machine.handle(.pttDown, now: 0)
        #expect(machine.handle(.send, now: 0.05) == [.send], "arming")
        _ = machine.handle(.timer(.arming), now: 0.12)
        #expect(machine.handle(.send, now: 0.5) == [.send], "push-to-talk")
        _ = machine.handle(.handsFreeToggle, now: 0.6)
        #expect(machine.handle(.send, now: 1) == [.send], "hands-free")
        _ = machine.handle(.pttDown, now: 1.1)
        #expect(machine.handle(.send, now: 1.2) == [.send])
        _ = machine.handle(.pttUp, now: 1.3)
        #expect(machine.capture.isListeningOrLocked)
        var idle = DictationMachine()
        #expect(idle.handle(.send, now: 0).isEmpty)
    }
}
