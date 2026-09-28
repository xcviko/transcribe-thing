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

    /// A quick fn+Tab isn't a tap: the model it chose would be dropped, and a following fn press would lock
    /// hands-free on the main model. It cancels quietly instead, like fn+←.
    @Test func aQuickReleaseAfterSwitchingCancelsQuietly() {
        var m = T.arming()
        #expect(m.handle(.cycleEngine, now: 10.0625) == [.cycleEngine])
        #expect(m.handle(.pttUp, now: 10.09375)
            == [.cancelTimer(.arming), .cancelCapture(keepForUndo: false, notify: false), .showPill(.rest)])
        #expect(m.capture == .idle)
        #expect(m.handle(.pttDown, now: 10.25).contains(.startCapture), "no double-press: a fresh hold")
        #expect(m.capture == .arming(downAt: 10.25))

        var listening = T.listening()
        _ = listening.handle(.cycleEngine, now: 10.1875)
        #expect(listening.handle(.pttUp, now: 10.25)
            == [.cancelCapture(keepForUndo: false, notify: false), .showPill(.rest)])
        #expect(listening.capture == .idle)
    }

    @Test func aHoldAfterSwitchingStillTranscribesAndTheNextTapIsATap() {
        var m = T.listening()
        _ = m.handle(.cycleEngine, now: 10.5)
        #expect(m.handle(.pttUp, now: 12).contains(.stopCaptureAndTranscribe(mode: .pushToTalk)))
        _ = m.handle(.pttDown, now: 20)
        _ = m.handle(.pttUp, now: 20.0625)
        #expect(m.capture == .tapPending(firstDownAt: 20), "the switch belonged to the last press only")
    }

    @Test(arguments: ["idle", "tapPending"])
    func withoutARecordingNothingHappens(_ name: String) {
        var m = T.state(name)
        let before = m.capture
        #expect(m.handle(.cycleEngine, now: 40).isEmpty)
        #expect(m.capture == before)
    }
}

// MARK: - Switch model: shortcut model and validation

@Suite struct SwitchModelShortcutTests {
    static let quiet = ShortcutPolicyTests.stock(fnUsage: .doNothing)

    @Test func theChipCallsTheMainModelJustParakeet() {
        #expect(EngineID.parakeet.chipName == "Parakeet")
        #expect(EngineID.parakeetCloud.chipName == "Parakeet")
        #expect(EngineID.geminiFlash.chipName == "Gemini 3.8 Flash")
    }

    @Test func itIsARebindableActionWithFnTabByDefault() {
        #expect(ShortcutAction.switchModel.title == "Switch model")
        #expect(ShortcutAction.switchModel.defaultShortcut == .fnTab)
        #expect(ShortcutBindings.defaults[.switchModel] == Shortcut(modifiers: [.init(.function)], keyCode: KeyCode.tab))
        #expect(ShortcutAction.switchModel.isDuringDictation)
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

    @Test func eachPressStepsMainThenCleanupThenFlashThenMain() async throws {
        let (rig, cues) = Self.make()
        let c = rig.h.controller
        Self.hold(rig)
        #expect(c.effectiveEngine == .parakeet && c.modelOverride == nil)
        #expect(rig.h.pill.sessionModel == nil)
        var choices: [ModelChoice?] = []
        for _ in 0..<5 {
            c.handle(.cycleEngine)
            choices.append(c.modelOverride)
            #expect(rig.h.pill.sessionModel == c.modelOverride)
        }
        #expect(choices == [.cleanup, .engine(.geminiFlash), nil, .cleanup, .engine(.geminiFlash)])
        #expect(c.effectiveEngine == .geminiFlash)
        #expect(rig.h.pill.engineChipPulse == 5, "back to the main model pulses too")
        #expect(cues.played.filter { $0 == .modelSwitch }.count == 5)
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
        #expect(c.modelOverride == nil, "the dictation is over")
        #expect(rig.h.pill.phase == .processing)
        #expect(rig.h.pill.sessionModel == .engine(.geminiFlash))
        try await waitUntil { rig.pasted == ["long talk"] && c.machine.activeJobs == 0 }
        #expect(used == [.geminiFlash])
        #expect(rig.h.history.entries.first?.engine == .geminiFlash, "history records the engine used")
        #expect(rig.h.pill.sessionModel == nil)

        // The next dictation starts on the main model.
        Self.hold(rig)
        #expect(c.effectiveEngine == .parakeet && c.modelOverride == nil)
        #expect(rig.h.pill.sessionModel == nil)
        c.send(.pillCancel)
    }

    @Test func onlyTheExtraModelsTakingPartAreInTheCycle() {
        let (rig, cues) = Self.make()
        let c = rig.h.controller
        rig.h.settings.switchCleanup = false
        rig.h.settings.switchEngines = [.geminiFlash]
        c.send(.handsFreeToggle)
        c.cycleEngine()
        #expect(c.effectiveEngine == .geminiFlash)
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
            #expect(notice.title == "Clean-up and Gemini need OpenRouter credit")
            #expect(notice.primaryAction?.kind == .openURL(OpenRouterLinks.credits))
        } else {
            #expect(notice.title == "Clean-up and Gemini need an OpenRouter key")
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
        rig.h.settings.switchCleanup = false
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
        #expect(rig.h.pill.sessionModel == .engine(.geminiFlash))

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

    /// Tidies whatever it's given into "Clean.", as the selected clean-up model.
    static func cleansUp(_ rig: Rig, into text: String = "Clean.", asked: @escaping (String) -> Void = { _ in }) {
        rig.h.controller.cleanupOverride = { raw, source in
            asked(raw)
            return TranscriptResult(text: text, engine: source, processingTime: 0.1)
        }
    }

    /// The first press puts the dictation on clean-up: the main model transcribes, the clean-up model tidies what's
    /// pasted, and the chip says so until the text lands. The next dictation isn't cleaned up.
    @Test func cleanupTidiesThisDictationOnly() async throws {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        var asked: [String] = []
        Self.cleansUp(rig) { asked.append($0) }
        var used: [EngineID] = []
        rig.result = { _, engine in
            used.append(engine)
            try await Task.sleep(for: .milliseconds(60))
            return "um raw words"
        }
        Self.hold(rig)
        c.handle(.cycleEngine)
        #expect(c.modelOverride == .cleanup && c.effectiveEngine == .parakeet)
        #expect(rig.h.pill.sessionModel == .cleanup)
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        rig.now += 2
        c.handle(.pttUp)
        #expect(rig.h.pill.sessionModel == .cleanup, "the chip stays while it's transcribed and tidied")
        try await waitUntil { rig.pasted == ["Clean."] && c.machine.activeJobs == 0 }
        #expect(used == [.parakeet] && asked == ["um raw words"])
        #expect(rig.h.history.entries.first?.currentKind == .cleanup(of: .parakeet, by: .gpt6Luna))
        #expect(rig.h.pill.sessionModel == nil)

        // The next dictation is on the main model alone.
        rig.result = { _, _ in "plain words" }
        Self.hold(rig)
        #expect(c.modelOverride == nil)
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        rig.now += 2
        c.handle(.pttUp)
        try await waitUntil { rig.pasted.count == 2 && c.machine.activeJobs == 0 }
        #expect(rig.pasted.last == "plain words" && asked.count == 1)
    }

    /// Undo of a canceled dictation on clean-up picks it up on clean-up again.
    @Test func undoKeepsCleanup() async throws {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        Self.cleansUp(rig)
        rig.result = { _, _ in "resumed raw" }
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        Self.hold(rig)
        c.handle(.cycleEngine)
        rig.now += 2
        c.handle(.cancel)
        #expect(c.modelOverride == nil)

        rig.now += 1
        try rig.click(.undoCancel, in: "dictation.canceled")
        #expect(c.modelOverride == .cleanup)
        #expect(rig.h.pill.sessionModel == .cleanup)
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 1)
        rig.now += 1
        c.send(.pillStop)
        try await waitUntil { rig.pasted == ["Clean."] && c.machine.activeJobs == 0 }
    }

    /// A recording has no length limit: an hour in, the shortcut still steps to Gemini like at the start.
    @Test func anHourLongRecordingStillStepsToGemini() {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        c.runsTimers = false
        rig.h.settings.switchCleanup = false
        c.send(.handsFreeToggle)
        rig.now += 3600
        let shakes = rig.h.pill.shakeCount
        c.cycleEngine()
        #expect(c.effectiveEngine == .geminiFlash)
        #expect(rig.h.pill.shakeCount == shakes && rig.notice(DictationController.switchModelNoticeKey) == nil)
        c.send(.pillCancel)
    }

    /// Tab held down steps on at every autorepeat of the keyboard, however fast, a tick each time.
    @Test func holdingTheKeyStepsAtEveryAutorepeat() {
        let (rig, cues) = Self.make()
        let c = rig.h.controller
        Self.hold(rig)
        c.handle(.cycleEngine)
        #expect(c.modelOverride == .cleanup)
        var steps: [ModelChoice?] = []
        for _ in 0..<5 {
            rig.now += 0.03
            c.handle(.cycleEngineRepeat)
            steps.append(c.modelOverride)
        }
        #expect(steps == [.engine(.geminiFlash), nil, .cleanup, .engine(.geminiFlash), nil])
        #expect(cues.played.filter { $0 == .modelSwitch }.count == 6)
        #expect(c.machine.capture.isListeningOrLocked)
        c.handle(.cancel)
        c.handle(.cycleEngineRepeat)
        #expect(c.modelOverride == nil, "no dictation, nothing to step")
    }

    /// The tick has voices of its own, so ticks at 30 ms ring over each other; other cues restart.
    @Test func theTickRingsOverItself() {
        #expect(Double(AVCueOutput.voices(for: .modelSwitch)) * 0.03 > 0.07, "enough voices for a 70 ms tick every 30 ms")
        #expect(SoundEffect.allCases.filter { $0 != .modelSwitch }.allSatisfy { AVCueOutput.voices(for: $0) == 1 })
    }

    /// A held key that can't step (no usable key) says so once, at the press.
    @Test func aHeldKeyThatCantStepStaysQuiet() {
        let (rig, cues) = Self.make(key: .missing)
        let c = rig.h.controller
        c.runsTimers = false
        c.send(.handsFreeToggle)
        let shakes = rig.h.pill.shakeCount
        c.cycleEngine()
        #expect(rig.h.pill.shakeCount == shakes + 1)
        for _ in 0..<3 {
            rig.now += 0.2
            c.handle(.cycleEngineRepeat)
        }
        #expect(rig.h.pill.shakeCount == shakes + 1)
        #expect(!cues.played.contains(.modelSwitch))
        c.send(.pillCancel)
    }

    /// Clean-up alone takes part: the notice without a key names it, not Gemini.
    @Test func theKeyNoticeNamesWhatTakesPart() {
        #expect(DictationController.switchWithoutKeyNotice(.missing, choices: [.cleanup]).title
            == "Clean-up needs an OpenRouter key")
        #expect(DictationController.switchWithoutKeyNotice(.missing, choices: [.engine(.geminiFlash)]).title
            == "Gemini needs an OpenRouter key")
        #expect(DictationController.switchWithoutKeyNotice(.noCredit(nil), choices: [.cleanup, .engine(.geminiFlash)]).title
            == "Clean-up and Gemini need OpenRouter credit")
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
        #expect(c.modelOverride == .cleanup)
        c.handle(.pttDown)
        c.handle(.pttUp)
        #expect(c.machine.capture == .idle)
    }

    @Test func thePillsMenuPicksAModelForThisDictation() {
        let (rig, cues) = Self.make()
        let c = rig.h.controller
        #expect(rig.h.pill.menuChoices == [.engine(.parakeet), .cleanup, .engine(.geminiFlash)])
        c.selectModelForCurrentDictation(.engine(.geminiFlash))
        #expect(c.modelOverride == nil, "no dictation, nothing to pick for")
        c.send(.handsFreeToggle)
        c.selectModelForCurrentDictation(.engine(.geminiFlash))
        #expect(c.effectiveEngine == .geminiFlash)
        #expect(rig.h.pill.sessionModel == .engine(.geminiFlash))
        c.selectModelForCurrentDictation(.engine(.geminiFlash))
        c.selectModelForCurrentDictation(.cleanup)
        #expect(c.modelOverride == .cleanup && c.effectiveEngine == .parakeet)
        #expect(rig.h.pill.sessionModel == .cleanup)
        c.selectModelForCurrentDictation(.engine(rig.h.settings.selectedEngine))
        #expect(c.modelOverride == nil)
        #expect(rig.h.pill.engineChipPulse == 3)
        #expect(cues.played.filter { $0 == .modelSwitch }.count == 3)
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
            rig.h.settings.switchCleanup = key == .missing
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
