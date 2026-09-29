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

    @Test func fnSpaceFromIdleTogglesHandsFreeAndSwallowsSpace() {
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
    @Test func controlSpaceAsHandsFreeTogglesAndSwallowsSpace() {
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
        // Combinations ignore sides: Right ⌃ Space toggles it again.
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

    @Test func spaceWhileHoldingFnTogglesAgainWithoutReleasingFn() {
        var kb = Keyboard()
        kb.press(.fn)
        #expect(kb.down(kVK_Space).events == [.handsFreeToggle])
        kb.up(kVK_Space)
        // Still holding fn: a second Space stops hands-free.
        let again = kb.down(kVK_Space)
        #expect(again.events == [.handsFreeToggle])
        #expect(again.swallow)
        kb.up(kVK_Space)
        #expect(kb.release(.fn).events.isEmpty)
        // Fully released: fn works as push to talk again.
        #expect(kb.press(.fn).events == [.pttDown])
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
        // F13 reports the Fn flag without Fn being held.
        #expect(engine.keyDown(keyCode: KeyCode.f13, rawFlags: CGEventFlags.maskSecondaryFn.rawValue, isRepeat: false)
            == .commit(.f13))
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
                     frontmost: pid_t? = 42, canPost: Bool = true, posts: Bool = true,
                     targetReadsAfter: TimeInterval? = 0.01) -> Rig {
        let pasteboard = privatePasteboard()
        let name = pasteboard.name
        let log = PasteLog()
        let box = FocusBox(focus)
        let target = TargetLog()
        let system = TextInserter.System(
            frontmostPID: { frontmost },
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
            frontmostPID: { nil }, canPostEvents: { false }, modifiersHeld: { false },
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
        #expect(await rig.inserter.insert("dictated", expectedPID: expected) == .pasted)
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
        #expect(await rig.inserter.insert("dictated", expectedPID: 42) == .pasted)
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
        #expect(await rig.inserter.insert("dictated", expectedPID: 42) == .pasted)
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
        #expect(await rig.inserter.insert("dictated", expectedPID: 42) == .pasted)
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
        #expect(await rig.inserter.insert("dictated", expectedPID: 42) == .pasted)
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
        #expect(await rig.inserter.insert("dictated", expectedPID: 42) == .pasted)
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
        #expect(await rig.inserter.insert("dictated", expectedPID: 42) == .pasted)
        #expect(rig.pasteboard.string(forType: .string) == "dictated")
        try await waitUntil { contents(of: rig.pasteboard) == before }
    }

    @Test func anEmptyClipboardIsPutBackEmpty() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        rig.pasteboard.clearContents()
        #expect(await rig.inserter.insert("dictated", expectedPID: 42) == .pasted)
        #expect(rig.pasteboard.string(forType: .string) == "dictated")
        try await waitUntil { rig.pasteboard.pasteboardItems?.isEmpty == true }
    }

    /// The smart leading space goes to the paste, and the clipboard still comes back as it was.
    @Test func theSmartSpaceIsOnlyForThePaste() async throws {
        let rig = rig(focus: Self.afterAWord)
        defer { rig.pasteboard.releaseGlobally() }
        copyString("original", to: rig)
        #expect(await rig.inserter.insert("next words", expectedPID: 42) == .pasted)
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
        #expect(await rig.inserter.insert("first", expectedPID: 42) == .pasted)
        #expect(await rig.inserter.insert("second", expectedPID: 42) == .pasted)
        #expect(rig.pasteboard.string(forType: .string) == "second")
        try await waitUntil { contents(of: rig.pasteboard) == before }
        try await settle()
        #expect(contents(of: rig.pasteboard) == before, "the first paste's restore doesn't run later")
    }

    @Test func aNewCopyDuringTheDelayWins() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        copyString("original", to: rig)
        #expect(await rig.inserter.insert("dictated", expectedPID: 42) == .pasted)
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
        #expect(await rig.inserter.insert("first", expectedPID: 42) == .pasted)
        copyString("copied in between", to: rig)
        #expect(await rig.inserter.insert("second", expectedPID: 42) == .pasted)
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
        #expect(await rig.inserter.insert("dictated", expectedPID: 42) == .pasted)
        rig.inserter.flushPendingRestore()
        #expect(contents(of: rig.pasteboard) == before)
    }

    @Test func quittingAfterANewCopyLeavesIt() async {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        rig.inserter.restoreDelay = .seconds(5)
        copyString("original", to: rig)
        #expect(await rig.inserter.insert("dictated", expectedPID: 42) == .pasted)
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
        #expect(await rig.inserter.insert("dictated", expectedPID: 42) == .pasted)
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
        #expect(await rig.inserter.insert("dictated", expectedPID: 42) == .pasted)
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

        #expect(await rig.inserter.insert("dictated", expectedPID: 42) == .pasted)
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
        #expect(await rig.inserter.insert("dictated", expectedPID: 42) == .pasted)
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
        #expect(await rig.inserter.insert("dictated", expectedPID: 42) == .pasted)
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
        if case .failed = await rig.inserter.insert("dictated", expectedPID: 42) {} else {
            Issue.record("Expected a failure when ⌘V can't be sent")
        }
        #expect(contents(of: rig.pasteboard) == before)
    }

    @Test func secureFieldIsRefusedAndTheClipboardLeftAlone() async {
        let rig = rig(focus: FocusInfo(pid: 42, subrole: "AXSecureTextField", editability: .editable, isSecure: true))
        defer { rig.pasteboard.releaseGlobally() }
        copyString("user clipboard", to: rig)
        #expect(await rig.inserter.insert("not a password", expectedPID: 42) == .noEditableTarget)
        #expect(rig.log.codes.isEmpty)
        #expect(rig.pasteboard.string(forType: .string) == "user clipboard")
    }

    @Test func nonTextFocusIsNotPastedNorCopied() async {
        let rig = rig(focus: FocusInfo(pid: 42, role: "AXButton", editability: .notEditable))
        defer { rig.pasteboard.releaseGlobally() }
        copyScreenshotAndFile(to: rig.pasteboard)
        let before = contents(of: rig.pasteboard)
        #expect(await rig.inserter.insert("hello", expectedPID: 42) == .noEditableTarget)
        #expect(rig.log.codes.isEmpty)
        #expect(contents(of: rig.pasteboard) == before)
    }

    /// A paste refused in between touches nothing: the pending restore still brings the user's clipboard back.
    @Test func aRefusedPasteLeavesAPendingRestoreAlone() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        rig.inserter.restoreDelay = .milliseconds(500)
        copyString("original", to: rig)
        #expect(await rig.inserter.insert("first", expectedPID: 42) == .pasted)
        rig.focus.focus = FocusInfo(pid: 42, editability: .notEditable)
        #expect(await rig.inserter.insert("second", expectedPID: 42) == .noEditableTarget)
        #expect(rig.pasteboard.string(forType: .string) == "first")
        try await waitUntil { rig.pasteboard.string(forType: .string) == "original" }
    }

    @Test func unknownFocusPastesAnyway() async throws {
        let rig = rig(focus: FocusInfo(pid: 42, role: "AXWebArea", editability: .unknown))
        defer { rig.pasteboard.releaseGlobally() }
        #expect(await rig.inserter.insert("hello", expectedPID: 42) == .pasted)
        #expect(rig.log.codes == [9])
        try await settle()
    }

    @Test func anotherAppInFrontIsATargetChange() async {
        let rig = rig(frontmost: 7)
        defer { rig.pasteboard.releaseGlobally() }
        copyString("untouched", to: rig)
        #expect(await rig.inserter.insert("hello", expectedPID: 42) == .targetChanged)
        #expect(rig.log.codes.isEmpty)
        #expect(rig.pasteboard.string(forType: .string) == "untouched")
    }

    /// The card that follows offers Copy; nothing goes on the clipboard unasked.
    @Test(arguments: [false, true])
    func withoutPermissionNothingIsPastedOrCopied(_ pasteHere: Bool) async {
        let rig = rig(canPost: false)
        defer { rig.pasteboard.releaseGlobally() }
        copyString("user clipboard", to: rig)
        let outcome = await (pasteHere ? rig.inserter.pasteNow("hello") : rig.inserter.insert("hello", expectedPID: 42))
        #expect(outcome == .accessibilityMissing)
        #expect(rig.log.codes.isEmpty)
        #expect(rig.pasteboard.string(forType: .string) == "user clipboard")
    }

    /// Accessibility granted after launch: the preflight still says no, but the live event tap proves the grant.
    @Test func aRunningEventTapOverridesAStalePreflight() async throws {
        let rig = rig(canPost: false)
        defer { rig.pasteboard.releaseGlobally() }
        rig.inserter.eventTapActive = { true }
        #expect(await rig.inserter.insert("hello", expectedPID: 42) == .pasted)
        #expect(rig.log.codes == [9])
        try await settle()
    }

    @Test func pasteNowSkipsFocusAndTargetChecks() async throws {
        let rig = rig(focus: FocusInfo(pid: 1, editability: .notEditable), frontmost: 7)
        defer { rig.pasteboard.releaseGlobally() }
        #expect(await rig.inserter.pasteNow("hello") == .pasted)
        #expect(rig.log.codes == [9])
        try await settle()
    }

    @Test func emptyTextFails() async {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        if case .failed = await rig.inserter.insert("", expectedPID: 42) {} else {
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
            frontmostPID: { 42 },
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

        async let first = inserter.insert("first", expectedPID: 42)
        async let second = inserter.insert("second", expectedPID: 42)
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
    private let quiet = SystemKeyboardState(hotKeys: [], fnUsage: .doNothing, functionKeysAreStandard: false)
    /// Every default macOS shortcut on.
    private let stock = SystemKeyboardState(hotKeys: SystemSymbolicHotKeys.active(in: nil), fnUsage: .doNothing,
                                            functionKeysAreStandard: false)

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

        // Hands-free: a plain Space steps, fn+Space still stops.
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
