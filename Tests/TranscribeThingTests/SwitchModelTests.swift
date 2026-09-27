import Carbon.HIToolbox
import Foundation
import Testing
@testable import TranscribeThing

// MARK: - Switch model: the machine

@Suite struct SwitchModelMachineTests {
    typealias M = DictationMachine
    typealias T = DictationMachineTests

    @Test(arguments: ["arming", "listening", "locked"])
    func cyclingNeverChangesARecording(_ name: String) {
        var m = T.state(name)
        let before = m.capture
        #expect(m.handle(.cycleEngine, now: 40) == [.cycleEngine])
        #expect(m.capture == before)
    }

    /// fn+Tab in hands-free: the fn press armed stop-on-release, the Tab makes it a combo, so releasing fn goes on.
    @Test func inHandsFreeTheFnPressIsNoLongerAStop() {
        var m = T.stopPending()
        #expect(m.handle(.cycleEngine, now: 31) == [.cycleEngine])
        #expect(m.capture == .locked(startedAt: T.t0))
        #expect(m.handle(.pttUp, now: 32).isEmpty)
        #expect(m.capture == .locked(startedAt: T.t0))
        // A lone fn press still sends.
        _ = m.handle(.pttDown, now: 40)
        #expect(m.handle(.pttUp, now: 40.1).contains(.stopCaptureAndTranscribe(mode: .handsFree)))
    }

    @Test(arguments: ["idle", "tapPending"])
    func withoutARecordingNothingHappens(_ name: String) {
        var m = T.state(name)
        let before = m.capture
        #expect(m.handle(.cycleEngine, now: 40).isEmpty)
        #expect(m.capture == before)
    }

    @Test func aNewLimitIsMeasuredFromTheRecordingsStart() {
        var m = T.listening()
        #expect(m.changeLimit(to: 420, now: 100) == [.schedule(.limitWarning, after: 270), .schedule(.limit, after: 330)])
        #expect(m.config.maxDuration == 420)
        #expect(m.changeLimit(to: 420, now: 101).isEmpty, "unchanged")

        var arming = T.arming()
        #expect(arming.changeLimit(to: 420, now: 10.05).isEmpty, "arming schedules them when it confirms")
        #expect(arming.handle(.timer(.arming), now: T.armedAt).contains(.schedule(.limit, after: 420 - (T.armedAt - T.t0))))
    }
}

// MARK: - Switch model: shortcut model and validation

@Suite struct SwitchModelShortcutTests {
    static let quiet = ShortcutPolicyTests.stock(fnUsage: .doNothing)

    @Test func itIsARebindableActionWithFnTabByDefault() {
        #expect(ShortcutAction.switchModel.title == "Switch model")
        #expect(ShortcutAction.switchModel.defaultShortcut == .fnTab)
        #expect(ShortcutBindings.defaults[.switchModel] == Shortcut(modifiers: [.init(.function)], keyCode: KeyCode.tab))
        #expect(ShortcutAction.switchModel.isDuringDictation && ShortcutAction.cancel.isDuringDictation)
        #expect(!ShortcutAction.pushToTalk.isDuringDictation)
    }

    @Test func storedBindingsWithoutItGetTheDefault() throws {
        let stored = #"{"cancel":{"keyCode":53,"modifiers":[]},"handsFree":null,"pasteLast":null,"#
            + #""pushToTalk":{"modifiers":[{"modifier":"option","side":"right"}]}}"#
        let decoded = try JSONDecoder().decode(ShortcutBindings.self, from: Data(stored.utf8))
        #expect(decoded[.switchModel] == .fnTab)
        #expect(decoded[.pushToTalk] == .rightOption)
        #expect(decoded[.handsFree] == nil && decoded[.pasteLast] == nil, "deliberately unbound stays unbound")

        var unbound = ShortcutBindings.defaults
        unbound[.switchModel] = nil
        #expect(try JSONDecoder().decode(ShortcutBindings.self, from: JSONEncoder().encode(unbound))[.switchModel] == nil)
    }

    @Test func clashesWithOtherActionsAreErrors() {
        let taken = ShortcutValidator.validate(.fnSpace, for: .switchModel, bindings: .defaults, system: Self.quiet)
        #expect(taken.conflict == .handsFree)
        #expect(ShortcutValidator.validate(.fnTab, for: .handsFree, bindings: .defaults, system: Self.quiet).conflict == .switchModel)
        #expect(ShortcutEdit.evaluate(.fnSpace, for: .switchModel, bindings: .defaults, swapAllowed: true, system: Self.quiet)
            == .offerSwap(.handsFree))

        let custom = Shortcut(modifiers: [.init(.command), .init(.shift)], keyCode: UInt16(kVK_ANSI_M))
        #expect(ShortcutValidator.validate(custom, for: .switchModel, bindings: .defaults, system: Self.quiet).isAcceptable)
        #expect(ShortcutValidator.validate(.rightCommand, for: .switchModel, bindings: .defaults, system: Self.quiet).isAcceptable)
    }

    /// Like Esc for cancel, a plain key for switch model only goes to it during a dictation: no typing warning.
    @Test func aPlainKeyIsFineForADuringDictationAction() {
        let tab = Shortcut(modifiers: [], keyCode: KeyCode.tab)
        let forSwitch = ShortcutValidator.validate(tab, for: .switchModel, bindings: .defaults, system: Self.quiet)
        #expect(forSwitch.isAcceptable)
        #expect(!forSwitch.warnings.contains { $0.kind == .typing })
        let forPaste = ShortcutValidator.validate(tab, for: .pasteLast, bindings: .defaults, system: Self.quiet)
        #expect(forPaste.warnings.contains { $0.kind == .typing })
    }

    @Test func theRecorderCapturesAndClearsIt() {
        var engine = ShortcutCaptureEngine(action: .switchModel)
        let fn = CGEventFlags.maskSecondaryFn.rawValue
        _ = engine.flagsChanged(keyCode: KeyCode.function, rawFlags: fn)
        #expect(engine.keyDown(keyCode: KeyCode.tab, rawFlags: fn, isRepeat: false) == .commit(.fnTab))
        _ = engine.flagsChanged(keyCode: KeyCode.function, rawFlags: 0)
        #expect(ShortcutCaptureEngine.canClear(.switchModel))
        #expect(engine.keyDown(keyCode: KeyCode.delete, rawFlags: 0, isRepeat: false) == .clear)
    }
}

// MARK: - Switch model: the controller

@MainActor
@Suite(.serialized) struct SwitchModelControllerTests {
    typealias Rig = DictationResumeTests.Rig

    final class Cues {
        var played: [SoundEffect] = []
    }

    static func make(key: KeyStatus = .valid(KeyInfo())) -> (Rig, Cues) {
        let rig = Rig(keyStatus: key)
        let cues = Cues()
        rig.h.controller.playCueOverride = { cues.played.append($0) }
        return (rig, cues)
    }

    /// Push-to-talk held past the confirm delay.
    static func hold(_ rig: Rig) {
        rig.h.controller.handle(.pttDown)
        rig.h.controller.send(.timer(.arming))
    }

    @Test func eachPressStepsMainThenFlashThenProThenMain() async throws {
        let (rig, cues) = Self.make()
        let c = rig.h.controller
        Self.hold(rig)
        #expect(c.effectiveEngine == .parakeet && c.engineOverride == nil)
        #expect(rig.h.pill.sessionEngine == nil)
        var engines: [EngineID] = []
        for _ in 0..<4 {
            c.handle(.cycleEngine)
            engines.append(c.effectiveEngine)
            #expect(rig.h.pill.sessionEngine == c.engineOverride)
        }
        #expect(engines == [.geminiFlash, .geminiPro, .parakeet, .geminiFlash])
        #expect(rig.h.pill.engineChipPulse == 4, "back to the main model pulses too")
        #expect(cues.played.filter { $0 == .modelSwitch }.count == 4)
        #expect(c.machine.capture.isListeningOrLocked, "switching never stops the recording")

        // Released: Gemini Flash transcribes, and the chip stays until the text lands.
        var used: [EngineID] = []
        rig.result = { _, engine in
            used.append(engine)
            try await Task.sleep(for: .milliseconds(80))
            return "long talk"
        }
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        rig.now += 2
        c.handle(.pttUp)
        #expect(c.engineOverride == nil, "the dictation is over")
        #expect(rig.h.pill.phase == .processing)
        #expect(rig.h.pill.sessionEngine == .geminiFlash)
        try await waitUntil { rig.pasted == ["long talk"] && c.machine.activeJobs == 0 }
        #expect(used == [.geminiFlash])
        #expect(rig.h.history.entries.first?.engine == .geminiFlash, "history records the engine used")
        #expect(rig.h.pill.sessionEngine == nil)

        // The next dictation starts on the main model.
        Self.hold(rig)
        #expect(c.effectiveEngine == .parakeet)
        #expect(rig.h.pill.sessionEngine == nil)
        c.send(.pillCancel)
    }

    @Test func onlyTheExtraModelsTakingPartAreInTheCycle() {
        let (rig, cues) = Self.make()
        let c = rig.h.controller
        rig.h.settings.switchEngines = [.geminiPro]
        c.send(.handsFreeToggle)
        c.cycleEngine()
        #expect(c.effectiveEngine == .geminiPro)
        c.cycleEngine()
        #expect(c.effectiveEngine == .parakeet)

        rig.h.settings.switchEngines = []
        #expect(!c.canSwitchModels)
        c.cycleEngine()
        #expect(c.effectiveEngine == .parakeet)
        #expect(rig.notice(DictationController.switchModelNoticeKey) == nil, "nothing to switch to, nothing to say")
        #expect(cues.played.filter { $0 == .modelSwitch }.count == 2)
        c.send(.pillCancel)
    }

    @Test(arguments: [KeyStatus.missing, .invalid("Revoked"), .noCredit(nil)])
    func withoutAUsableKeyThePillShakesAndSaysWhy(_ key: KeyStatus) throws {
        let (rig, cues) = Self.make(key: key)
        let c = rig.h.controller
        var opened: [HubSection] = []
        c.openHub = { opened.append($0) }
        c.send(.handsFreeToggle)
        #expect(!c.canSwitchModels)
        let shakes = rig.h.pill.shakeCount
        c.cycleEngine()
        #expect(c.effectiveEngine == .parakeet)
        #expect(c.machine.capture.isListeningOrLocked)
        #expect(rig.h.pill.shakeCount == shakes + 1)
        #expect(!cues.played.contains(.modelSwitch))
        let notice = try #require(rig.notice(DictationController.switchModelNoticeKey))
        if case .noCredit = key {
            #expect(notice.title == "Gemini needs OpenRouter credit")
            #expect(notice.primaryAction?.kind == .openURL(OpenRouterLinks.credits))
        } else {
            #expect(notice.title == "Gemini needs an OpenRouter key")
            #expect(notice.primaryAction?.title == "Add Key")
            try rig.click(.openHub(.models), in: DictationController.switchModelNoticeKey)
            #expect(opened == [.models])
        }
        c.send(.pillCancel)
    }

    /// Undo of a canceled dictation continues it, with the model it had.
    @Test func undoKeepsTheDictationsModel() async throws {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        Self.hold(rig)
        c.handle(.cycleEngine)
        #expect(c.effectiveEngine == .geminiFlash)
        rig.now += 2
        c.handle(.cancel)
        #expect(c.effectiveEngine == .parakeet)

        rig.now += 1
        try rig.click(.undoCancel, in: "dictation.canceled")
        #expect(c.machine.capture.isListeningOrLocked)
        #expect(c.effectiveEngine == .geminiFlash)
        #expect(rig.h.pill.sessionEngine == .geminiFlash)
        #expect(rig.h.pill.limitSeconds == 420)

        var used: [EngineID] = []
        rig.result = { _, engine in
            used.append(engine)
            return "resumed"
        }
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 1)
        rig.now += 1
        c.send(.pillStop)
        try await waitUntil { rig.pasted == ["resumed"] && c.machine.activeJobs == 0 }
        #expect(used == [.geminiFlash])
        #expect(c.effectiveEngine == .parakeet)
    }

    /// Hands-free: fn down, Tab, fn up. The recording goes on; a lone fn press later still sends.
    @Test func handsFreeFnTabDoesntStop() {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        c.send(.handsFreeToggle)
        c.handle(.pttDown)
        c.handle(.cycleEngine)
        c.handle(.pttUp)
        #expect(c.machine.capture.isListeningOrLocked)
        #expect(c.effectiveEngine == .geminiFlash)
        c.handle(.pttDown)
        c.handle(.pttUp)
        #expect(c.machine.capture == .idle)
    }

    @Test func thePillsMenuPicksAModelForThisDictation() {
        let (rig, cues) = Self.make()
        let c = rig.h.controller
        c.selectEngineForCurrentDictation(.geminiPro)
        #expect(c.engineOverride == nil, "no dictation, nothing to pick for")
        c.send(.handsFreeToggle)
        c.selectEngineForCurrentDictation(.geminiPro)
        #expect(c.effectiveEngine == .geminiPro)
        #expect(rig.h.pill.sessionEngine == .geminiPro)
        c.selectEngineForCurrentDictation(.geminiPro)
        c.selectEngineForCurrentDictation(rig.h.settings.selectedEngine)
        #expect(c.engineOverride == nil)
        #expect(rig.h.pill.engineChipPulse == 2)
        #expect(cues.played.filter { $0 == .modelSwitch }.count == 2)
        c.send(.pillCancel)
    }

    /// Gemini takes about 7 minutes per request: switching to it shortens the limit, switching back restores it,
    /// and a recording already too long for it stays where it is.
    @Test func theLimitFollowsTheModel() {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        c.runsTimers = false
        c.send(.handsFreeToggle)
        rig.now += 100
        c.cycleEngine()
        #expect(rig.h.pill.limitSeconds == 420)
        c.cycleEngine()
        c.cycleEngine()
        #expect(c.effectiveEngine == .parakeet)
        #expect(rig.h.pill.limitSeconds == 1200)

        rig.now += 315
        let shakes = rig.h.pill.shakeCount
        c.cycleEngine()
        #expect(c.effectiveEngine == .parakeet)
        #expect(rig.h.pill.shakeCount == shakes + 1)
        #expect(rig.notice(DictationController.switchModelNoticeKey)?.title == "Too long for Gemini")
        c.send(.pillCancel)
    }

    @Test func theHintShowsForTheFirstThreeLongHolds() {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        c.runsTimers = false
        var shown: [Bool] = []
        for _ in 0..<4 {
            Self.hold(rig)
            rig.now += 1
            c.showSwitchHintIfDue()
            #expect(!rig.h.pill.showsTabHint, "not before 1.5 s")
            rig.now += 0.6
            c.showSwitchHintIfDue()
            shown.append(rig.h.pill.showsTabHint)
            c.handle(.cancel)
            #expect(!rig.h.pill.showsTabHint, "it goes with the hold")
        }
        #expect(shown == [true, true, true, false])
        #expect(rig.h.settings.switchHintShownCount == 3)
    }

    @Test func usingTheShortcutEndsTheHints() {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        c.runsTimers = false
        Self.hold(rig)
        rig.now += 2
        c.showSwitchHintIfDue()
        #expect(rig.h.pill.showsTabHint)
        c.handle(.cycleEngine)
        #expect(!rig.h.pill.showsTabHint)
        #expect(rig.h.settings.switchHintShownCount == AppSettings.switchHintLimit)
        c.handle(.cancel)
    }

    @Test func noHintWithoutAUsableKeyOrExtraModel() {
        for (key, engines) in [(KeyStatus.missing, EngineID.switchCandidates), (.valid(KeyInfo()), [])] {
            let (rig, _) = Self.make(key: key)
            let c = rig.h.controller
            c.runsTimers = false
            rig.h.settings.switchEngines = engines
            Self.hold(rig)
            rig.now += 2
            c.showSwitchHintIfDue()
            #expect(!rig.h.pill.showsTabHint)
            c.handle(.cancel)
        }
    }

    @Test func theMonitorKnowsWhenADictationRecords() {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        #expect(!rig.h.hotkeys.isRecording)
        c.send(.handsFreeToggle)
        #expect(rig.h.hotkeys.isRecording)
        c.send(.pillCancel)
        #expect(!rig.h.hotkeys.isRecording)
    }
}
