import AppKit
import Carbon.HIToolbox
import Foundation
import os
import Testing
@testable import MurmurApp

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

    @Test func copyLastNeedsLeftControl() {
        var kb = Keyboard()
        kb.press(.leftControl)
        kb.press(.leftCommand)
        let c = kb.down(kVK_ANSI_C)
        #expect(c.events == [.copyLast])
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

    @Test func mouseClickWhileHoldingModifierPushToTalkInterrupts() {
        var kb = Keyboard(bindings: bindings([.pushToTalk: .rightCommand]))
        kb.press(.rightCommand)
        #expect(kb.click().events == [.pttInterrupted])
        #expect(kb.release(.rightCommand).events.isEmpty)
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

    @Test func escapeIsRecordableOnlyForCancel() {
        var cancel = ShortcutCaptureEngine(action: .cancel)
        #expect(cancel.keyDown(keyCode: KeyCode.escape, rawFlags: 0, isRepeat: false) == .commit(.escape))
        var ptt = ShortcutCaptureEngine(action: .handsFree)
        #expect(ptt.keyDown(keyCode: KeyCode.escape, rawFlags: 0, isRepeat: false) == .cancel)
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
    NSPasteboard(name: NSPasteboard.Name("dev.murmur.tests.\(UUID().uuidString)"))
}

@MainActor
@Suite struct PasteboardSnapshotTests {
    @Test func roundTripsEveryItemAndType() throws {
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("hello", forType: .string)
        first.setString("<b>hello</b>", forType: .html)
        let second = NSPasteboardItem()
        second.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("dev.murmur.test.binary"))
        pb.clearContents()
        pb.writeObjects([first, second])

        let snapshot = try #require(PasteboardSnapshot.capture(pb))
        #expect(snapshot.items.count == 2)
        #expect(!snapshot.containsConcealed)

        pb.clearContents()
        pb.setString("transcript", forType: .string)
        snapshot.restore(to: pb)

        let items = try #require(pb.pasteboardItems)
        #expect(items.count == 2)
        #expect(items[0].string(forType: .string) == "hello")
        #expect(items[0].string(forType: .html) == "<b>hello</b>")
        #expect(items[1].data(forType: NSPasteboard.PasteboardType("dev.murmur.test.binary")) == Data([1, 2, 3]))
    }

    @Test func detectsConcealedContent() throws {
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("s3cret", forType: .string)
        item.setData(Data(), forType: PasteboardSnapshot.concealedType)
        pb.clearContents()
        pb.writeObjects([item])
        #expect(try #require(PasteboardSnapshot.capture(pb)).containsConcealed)
    }

    @Test func slowUniversalClipboardIsLeftOut() {
        let remote = PasteboardSnapshot.remoteClipboardType
        #expect(PasteboardSnapshot.isSlowRemote(types: [[remote, NSPasteboard.PasteboardType("public.png")]]))
        #expect(PasteboardSnapshot.isSlowRemote(types: [[remote], [.tiff]]))
        // Remote text is small: still restored.
        #expect(!PasteboardSnapshot.isSlowRemote(types: [[remote, .string, .rtf, .html, PasteboardSnapshot.transientType]]))
        // Local images are read locally.
        #expect(!PasteboardSnapshot.isSlowRemote(types: [[.png, .tiff]]))

        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setData(Data([0x89, 0x50]), forType: .png)
        item.setData(Data(), forType: remote)
        pb.clearContents()
        pb.writeObjects([item])
        #expect(PasteboardSnapshot.capture(pb) == nil)
    }

    @Test func refusesOversizedContents() {
        let pb = privatePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString(String(repeating: "x", count: 2_000), forType: .string)
        #expect(PasteboardSnapshot.capture(pb, maxBytes: 1_000) == nil)
    }
}

// MARK: - TextInserter pipeline (fake system, private pasteboard)

private final class PasteLog: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [CGKeyCode]())
    func record(_ code: CGKeyCode) { lock.withLock { $0.append(code) } }
    var codes: [CGKeyCode] { lock.withLock { $0 } }
}

@MainActor
@Suite struct TextInserterTests {
    private struct Rig {
        let inserter: TextInserter
        let pasteboard: NSPasteboard
        let log: PasteLog
        let settings: AppSettings
    }

    private func rig(focus: FocusInfo = FocusInfo(pid: 42, editability: .editable),
                     frontmost: pid_t? = 42, canPost: Bool = true,
                     restoreClipboard: Bool = true) -> Rig {
        let settings = AppSettings.inMemory()
        settings.restoreClipboard = restoreClipboard
        let pasteboard = privatePasteboard()
        let log = PasteLog()
        let system = TextInserter.System(
            frontmostPID: { frontmost },
            canPostEvents: { canPost },
            modifiersHeld: { false },
            inspectFocus: { focus },
            pasteKeyCode: { 9 },
            postPaste: { code in
                log.record(code)
                return true
            })
        let inserter = TextInserter(settings: settings, pasteboard: pasteboard, system: system)
        inserter.restoreDelay = .milliseconds(40)
        return Rig(inserter: inserter, pasteboard: pasteboard, log: log, settings: settings)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    @Test func pastesWithSmartSpaceThenRestoresTheClipboard() async throws {
        let rig = rig(focus: FocusInfo(pid: 42, editability: .editable, precedingCharacter: "d"))
        defer { rig.pasteboard.releaseGlobally() }
        rig.pasteboard.clearContents()
        rig.pasteboard.setString("user clipboard", forType: .string)

        let outcome = await rig.inserter.insert("next words", expectedPID: 42)
        #expect(outcome == .pasted)
        #expect(rig.log.codes == [9])
        #expect(rig.pasteboard.string(forType: .string) == " next words")
        let types = rig.pasteboard.pasteboardItems?.first?.types ?? []
        #expect(types.contains(PasteboardSnapshot.transientType))
        #expect(types.contains(PasteboardSnapshot.concealedType))

        try await settle()
        #expect(rig.pasteboard.string(forType: .string) == "user clipboard")
    }

    @Test func backToBackPastesRestoreTheUsersClipboardNotTheFirstTranscript() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        rig.pasteboard.clearContents()
        rig.pasteboard.setString("original", forType: .string)
        rig.inserter.restoreDelay = .milliseconds(120)

        #expect(await rig.inserter.insert("first", expectedPID: 42) == .pasted)
        #expect(await rig.inserter.insert("second", expectedPID: 42) == .pasted)
        #expect(rig.pasteboard.string(forType: .string) == "second")
        try await Task.sleep(for: .milliseconds(250))
        #expect(rig.pasteboard.string(forType: .string) == "original")
    }

    @Test func aNewCopyDuringTheDelayWins() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        rig.pasteboard.clearContents()
        rig.pasteboard.setString("original", forType: .string)
        #expect(await rig.inserter.insert("dictated", expectedPID: 42) == .pasted)
        rig.pasteboard.clearContents()
        rig.pasteboard.setString("copied meanwhile", forType: .string)
        try await settle()
        #expect(rig.pasteboard.string(forType: .string) == "copied meanwhile")
    }

    @Test func concealedOriginalIsClearedInsteadOfRestored() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        let secret = NSPasteboardItem()
        secret.setString("hunter2", forType: .string)
        secret.setData(Data(), forType: PasteboardSnapshot.concealedType)
        rig.pasteboard.clearContents()
        rig.pasteboard.writeObjects([secret])

        #expect(await rig.inserter.insert("hello", expectedPID: 42) == .pasted)
        try await settle()
        #expect(rig.pasteboard.string(forType: .string) == nil)
    }

    @Test func restoreClipboardOffLeavesAPlainCopy() async throws {
        let rig = rig(restoreClipboard: false)
        defer { rig.pasteboard.releaseGlobally() }
        rig.pasteboard.clearContents()
        rig.pasteboard.setString("original", forType: .string)
        #expect(await rig.inserter.insert("keep me", expectedPID: 42) == .pasted)
        try await settle()
        #expect(rig.pasteboard.string(forType: .string) == "keep me")
        let types = rig.pasteboard.pasteboardItems?.first?.types ?? []
        #expect(!types.contains(PasteboardSnapshot.transientType))
    }

    @Test func secureFieldIsRefusedAndTheClipboardLeftAlone() async {
        let rig = rig(focus: FocusInfo(pid: 42, subrole: "AXSecureTextField", editability: .editable, isSecure: true))
        defer { rig.pasteboard.releaseGlobally() }
        rig.pasteboard.clearContents()
        rig.pasteboard.setString("user clipboard", forType: .string)
        #expect(await rig.inserter.insert("not a password", expectedPID: 42) == .noEditableTarget)
        #expect(rig.log.codes.isEmpty)
        #expect(rig.pasteboard.string(forType: .string) == "user clipboard")
    }

    @Test func nonTextFocusIsNotPastedNorCopied() async {
        let rig = rig(focus: FocusInfo(pid: 42, role: "AXButton", editability: .notEditable))
        defer { rig.pasteboard.releaseGlobally() }
        rig.pasteboard.clearContents()
        rig.pasteboard.setString("user clipboard", forType: .string)
        #expect(await rig.inserter.insert("hello", expectedPID: 42) == .noEditableTarget)
        #expect(rig.log.codes.isEmpty)
        #expect(rig.pasteboard.string(forType: .string) == "user clipboard")
    }

    @Test func noTargetDoesntCutAPendingRestoreShort() async throws {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        rig.pasteboard.clearContents()
        rig.pasteboard.setString("original", forType: .string)
        #expect(await rig.inserter.insert("first", expectedPID: 42) == .pasted)
        let noTarget = TextInserter(settings: rig.settings, pasteboard: rig.pasteboard, system: .init(
            frontmostPID: { 42 }, canPostEvents: { true }, modifiersHeld: { false },
            inspectFocus: { FocusInfo(pid: 42, editability: .notEditable) }, pasteKeyCode: { 9 },
            postPaste: { _ in true }))
        #expect(await noTarget.insert("second", expectedPID: 42) == .noEditableTarget)
        try await settle()
        #expect(rig.pasteboard.string(forType: .string) == "original")
    }

    @Test func unknownFocusPastesAnyway() async {
        let rig = rig(focus: FocusInfo(pid: 42, role: "AXWebArea", editability: .unknown))
        defer { rig.pasteboard.releaseGlobally() }
        #expect(await rig.inserter.insert("hello", expectedPID: 42) == .pasted)
        #expect(rig.log.codes == [9])
    }

    @Test func anotherAppInFrontIsATargetChange() async {
        let rig = rig(frontmost: 7)
        defer { rig.pasteboard.releaseGlobally() }
        rig.pasteboard.clearContents()
        rig.pasteboard.setString("untouched", forType: .string)
        #expect(await rig.inserter.insert("hello", expectedPID: 42) == .targetChanged)
        #expect(rig.log.codes.isEmpty)
        #expect(rig.pasteboard.string(forType: .string) == "untouched")
    }

    @Test func withoutPermissionTheTextIsCopied() async {
        let rig = rig(canPost: false)
        defer { rig.pasteboard.releaseGlobally() }
        #expect(await rig.inserter.insert("hello", expectedPID: 42) == .accessibilityMissing)
        #expect(rig.log.codes.isEmpty)
        #expect(rig.pasteboard.string(forType: .string) == "hello")
    }

    @Test func pasteNowSkipsFocusAndTargetChecks() async {
        let rig = rig(focus: FocusInfo(pid: 1, editability: .notEditable), frontmost: 7)
        defer { rig.pasteboard.releaseGlobally() }
        #expect(await rig.inserter.pasteNow("hello") == .pasted)
        #expect(rig.log.codes == [9])
    }

    @Test func emptyTextFails() async {
        let rig = rig()
        defer { rig.pasteboard.releaseGlobally() }
        if case .failed = await rig.inserter.insert("", expectedPID: 42) {} else {
            Issue.record("Expected a failure for empty text")
        }
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

/// `MURMUR_SNAPSHOT_DIR=<dir> swift test --filter SystemSnapshotTests` renders the recorder gallery.
@MainActor
@Suite struct SystemSnapshotTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MURMUR_SNAPSHOT_DIR"] != nil))
    func renderRecorderGallery() throws {
        let dir = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MURMUR_SNAPSHOT_DIR"]))
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
    @Test func overlappingInsertionsRunOneAtATimeAndKeepTheOriginalClipboard() async throws {
        let settings = AppSettings.inMemory()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.murmur.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let log = PasteLog()
        let system = TextInserter.System(
            frontmostPID: { 42 },
            canPostEvents: { true },
            modifiersHeld: { false },
            inspectFocus: {
                try? await Task.sleep(for: .milliseconds(30))
                return FocusInfo(pid: 42, editability: .editable)
            },
            pasteKeyCode: { 9 },
            postPaste: { code in
                log.record(code)
                return true
            })
        let inserter = TextInserter(settings: settings, pasteboard: pasteboard, system: system)
        inserter.restoreDelay = .milliseconds(60)

        async let first = inserter.insert("first", expectedPID: 42)
        async let second = inserter.insert("second", expectedPID: 42)
        let outcomes = await [first, second]
        #expect(outcomes == [.pasted, .pasted])
        #expect(log.codes == [9, 9])
        try await Task.sleep(for: .milliseconds(200))
        #expect(pasteboard.string(forType: .string) == "original")
    }
}

@Suite struct ShortcutEditTests {
    private let defaults = ShortcutBindings.defaults

    @Test func sameShortcutIsUnchanged() {
        #expect(ShortcutEdit.evaluate(.fn, for: .pushToTalk, bindings: defaults, swapAllowed: true) == .unchanged)
    }

    @Test func rightOptionIsAppliedCleanly() {
        #expect(ShortcutEdit.evaluate(.rightOption, for: .pushToTalk, bindings: defaults, swapAllowed: true)
            == .apply(warning: nil))
    }

    @Test func plainOptionAppliesWithAWarning() {
        let outcome = ShortcutEdit.evaluate(Shortcut(modifiers: [.init(.option)]), for: .pushToTalk,
                                            bindings: defaults, swapAllowed: true)
        guard case .apply(let warning?) = outcome else {
            Issue.record("Expected a warning, got \(outcome)")
            return
        }
        #expect(warning.contains("Right ⌥"))
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

    @Test func systemComboIsRejected() {
        let spotlight = Shortcut(modifiers: [.init(.command)], keyCode: KeyCode.space)
        guard case .reject = ShortcutEdit.evaluate(spotlight, for: .handsFree, bindings: defaults, swapAllowed: true) else {
            Issue.record("⌘Space must be rejected")
            return
        }
    }

    @Test func escapeOnlyForCancel() {
        guard case .reject = ShortcutEdit.evaluate(.escape, for: .pasteLast, bindings: defaults, swapAllowed: true) else {
            Issue.record("Esc must be rejected outside cancel")
            return
        }
    }

    @Test func conflictOffersSwapWhenTheOtherActionCanTakeOurs() {
        #expect(ShortcutEdit.evaluate(.fnSpace, for: .pasteLast, bindings: defaults, swapAllowed: true)
            == .offerSwap(.handsFree))
        #expect(ShortcutEdit.evaluate(.fnSpace, for: .pasteLast, bindings: defaults, swapAllowed: false)
            == .reject("Hands-free already uses this shortcut."))
    }

    @Test func noSwapWhenTheOtherActionCantTakeOurs() {
        // Push to talk would receive Esc, which is reserved for cancel.
        #expect(ShortcutEdit.evaluate(.fn, for: .cancel, bindings: defaults, swapAllowed: true)
            == .reject("Push to talk already uses this shortcut."))
    }

    @Test func sidesThatCanMeetConflict() {
        // Right ⌥ push to talk (onboarding's alternative) and a lone ⌥ recorded for hands-free.
        let rightOptionPTT = bindings([.pushToTalk: .rightOption])
        let option = Shortcut(modifiers: [.init(.option)])
        #expect(ShortcutValidator.validate(option, for: .handsFree, bindings: rightOptionPTT).conflict == .pushToTalk)
        #expect(ShortcutValidator.validate(Shortcut(modifiers: [.init(.option, .left)]), for: .handsFree,
                                           bindings: rightOptionPTT).conflict == nil)
        // ⌃⌘C (either side) would make copy last (⌘ left⌃ C) unreachable.
        let controlCommandC = Shortcut(modifiers: [.init(.control), .init(.command)], keyCode: KeyCode.ansiC)
        #expect(ShortcutValidator.validate(controlCommandC, for: .pasteLast, bindings: defaults).conflict == .copyLast)
    }

    @Test func aChordMustNotStartAnotherModifierOnlyBinding() {
        let controlOption = Shortcut(modifiers: [.init(.control), .init(.option)])
        let control = Shortcut(modifiers: [.init(.control, .right)])
        // Hands-free ⌃ would fire on the way to a ⌃⌥ push to talk.
        let ptt = bindings([.pushToTalk: controlOption])
        guard case .reject = ShortcutEdit.evaluate(control, for: .handsFree, bindings: ptt, swapAllowed: true) else {
            Issue.record("a prefix of push to talk must be rejected")
            return
        }
        // And the other way round: push to talk ⌃⌥ while hands-free is ⌃.
        let handsFree = bindings([.handsFree: control])
        guard case .reject = ShortcutEdit.evaluate(controlOption, for: .pushToTalk, bindings: handsFree, swapAllowed: true) else {
            Issue.record("push to talk must not start with another modifier-only binding")
            return
        }
        // Push to talk as the start of a modifier-only hands-free is intended.
        let fnControl = Shortcut(modifiers: [.init(.function), .init(.control)])
        guard case .apply = ShortcutEdit.evaluate(fnControl, for: .handsFree, bindings: defaults, swapAllowed: true) else {
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
