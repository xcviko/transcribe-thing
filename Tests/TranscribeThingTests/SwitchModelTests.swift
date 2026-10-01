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

    /// The chip names Parakeet just "Parakeet" wherever it runs, and clean-up by its model after the wand (headed by
    /// Parakeet's name).
    @Test func theChipNamesEachModel() {
        #expect(ModelChoice.parakeet.chipName == "Parakeet")
        #expect(ModelChoice.cleanup.chipName == "GPT-6 Luna")
        #expect(ModelChoice.gemini.chipName == "Gemini 3.8 Flash")
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

    static func make(key: KeyStatus = .valid(KeyInfo()),
                     models: [EngineID: LocalModelState] = [.parakeet: .ready]) -> (Rig, Cues) {
        let rig = Rig(keyStatus: key, models: models)
        let cues = Cues()
        rig.h.controller.playCueOverride = { cues.played.append($0) }
        return (rig, cues)
    }

    /// Push-to-talk held past the confirm delay.
    static func hold(_ rig: Rig) {
        rig.h.controller.handle(.pttDown)
        rig.h.controller.send(.timer(.arming))
    }

    /// Releases the push-to-talk hold after two seconds of speech and waits for its text.
    static func release(_ rig: Rig) async throws {
        let pasted = rig.pasted.count
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        rig.now += 2
        rig.h.controller.handle(.pttUp)
        try await waitUntil { rig.pasted.count == pasted + 1 && rig.h.controller.machine.activeJobs == 0 }
    }

    /// The presses step from the main model through the lineup's order and back; each dictation goes to the model it
    /// was on when released.
    @Test func eachPressStepsThroughTheLineupFromTheMainModel() async throws {
        let (rig, cues) = Self.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .gemini
        Self.cleansUp(rig)
        var used: [EngineID] = []
        rig.result = { _, engine in
            used.append(engine)
            return "words"
        }
        Self.hold(rig)
        #expect(c.modelOverride == nil && c.effectiveChoice == .gemini && c.effectiveEngine == .geminiFlash)
        var choices: [ModelChoice?] = []
        for _ in 0..<3 {
            c.handle(.cycleEngine)
            choices.append(c.modelOverride)
            #expect(rig.h.pill.sessionModel == c.effectiveChoice)
        }
        #expect(choices == [.parakeet, .cleanup, nil])
        #expect(rig.h.pill.engineChipPulse == 3, "back to the main model pulses too")
        #expect(cues.played.filter { $0 == .modelSwitch }.count == 3)
        #expect(c.machine.capture.isListeningOrLocked, "switching never stops the recording")
        try await Self.release(rig)

        Self.hold(rig)
        c.handle(.cycleEngine)
        try await Self.release(rig)
        Self.hold(rig)
        #expect(c.modelOverride == nil && c.effectiveChoice == .gemini, "each dictation starts on the main model")
        c.handle(.cycleEngine)
        c.handle(.cycleEngine)
        try await Self.release(rig)

        #expect(used == [.geminiFlash, .parakeet, .parakeet])
        #expect(rig.pasted == ["words", "words", "Clean."])
        let entries = rig.h.history.entries.sorted { $0.createdAt < $1.createdAt }
        #expect(entries.map(\.engine) == [.geminiFlash, .parakeet, .parakeet], "history records the engine used")
        #expect(entries.last?.currentKind == .cleanup(of: .parakeet, by: .gpt6Luna))
    }

    @Test func theOrderOfModelsIsTheOrderOfSteps() {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        rig.h.settings.lineup.move(.gemini, to: 1)
        c.send(.handsFreeToggle)
        var choices: [ModelChoice?] = []
        for _ in 0..<3 {
            c.cycleEngine()
            choices.append(c.modelOverride)
        }
        #expect(choices == [.gemini, .cleanup, nil])
        c.send(.pillCancel)
    }

    @Test func aModelSwitchedOffIsNotAStep() {
        let (rig, cues) = Self.make()
        let c = rig.h.controller
        rig.h.settings.lineup.setSwitchable(.cleanup, false)
        c.send(.handsFreeToggle)
        c.cycleEngine()
        #expect(c.effectiveEngine == .geminiFlash)
        c.cycleEngine()
        #expect(c.effectiveEngine == .parakeet && c.modelOverride == nil)

        rig.h.settings.lineup.setSwitchable(.gemini, false)
        #expect(!c.canSwitchModels)
        let shakes = rig.h.pill.shakeCount
        c.cycleEngine()
        #expect(c.effectiveEngine == .parakeet)
        #expect(rig.notice(DictationController.switchModelNoticeKey) == nil, "nothing to switch to, nothing to say")
        #expect(rig.h.pill.shakeCount == shakes)
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
            #expect(notice.body == "Add credit to switch models.")
            #expect(notice.primaryAction?.kind == .openURL(OpenRouterLinks.credits))
        } else {
            #expect(notice.title == "Clean-up and Gemini need an OpenRouter key")
            #expect(notice.primaryAction?.title == "Add Key")
            try rig.click(.openHub(.models), in: DictationController.switchModelNoticeKey)
            #expect(opened == [.models])
        }
        c.send(.pillCancel)
    }

    /// A model that can't take the dictation now is stepped over; with none to land on, the press is rejected with
    /// the reason.
    @Test func aStepThatCantRunIsSkipped() throws {
        // Parakeet on this Mac as the main model, and no credit for clean-up or Gemini.
        let (broke, _) = Self.make(key: .noCredit(nil))
        broke.h.controller.send(.handsFreeToggle)
        let shakes = broke.h.pill.shakeCount
        broke.h.controller.cycleEngine()
        #expect(broke.h.controller.modelOverride == nil && broke.h.pill.shakeCount == shakes + 1)
        #expect(broke.notice(DictationController.switchModelNoticeKey)?.title
            == "Clean-up and Gemini need OpenRouter credit")
        broke.h.controller.send(.pillCancel)

        // Gemini as the main model, Parakeet on this Mac not downloaded: Parakeet and clean-up can't run.
        let (bare, _) = Self.make(models: [.parakeet: .notInstalled])
        bare.h.settings.lineup.main = .gemini
        bare.h.controller.send(.handsFreeToggle)
        #expect(bare.h.settings.lineup.cycle == [.gemini, .parakeet, .cleanup])
        #expect(!bare.h.controller.canSwitchModels)
        let bareShakes = bare.h.pill.shakeCount
        bare.h.controller.cycleEngine()
        #expect(bare.h.controller.modelOverride == nil && bare.h.pill.shakeCount == bareShakes + 1)
        let notice = try #require(bare.notice(DictationController.switchModelNoticeKey))
        #expect(notice.title == "Parakeet v3 isn’t downloaded yet")
        #expect(notice.actions.first?.kind == .download(.parakeet))
        bare.h.controller.send(.pillCancel)

        // Gemini as the main model and no credit: Parakeet on this Mac still answers, clean-up is stepped over.
        let (skip, cues) = Self.make(key: .noCredit(nil))
        skip.h.settings.lineup.main = .gemini
        skip.h.controller.send(.handsFreeToggle)
        let skipShakes = skip.h.pill.shakeCount
        skip.h.controller.cycleEngine()
        #expect(skip.h.controller.modelOverride == .parakeet)
        skip.h.controller.cycleEngine()
        #expect(skip.h.controller.modelOverride == nil, "past clean-up, back to Gemini")
        #expect(skip.h.pill.shakeCount == skipShakes && skip.notice(DictationController.switchModelNoticeKey) == nil)
        #expect(cues.played.filter { $0 == .modelSwitch }.count == 2)
        skip.h.controller.send(.pillCancel)
    }

    /// With the main model alone taking part, fn+Tab isn't taken from the app, and the pill has no hint for it.
    @Test func aCycleOfOneLeavesTheShortcutAlone() {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        c.runsTimers = false
        let monitor = HotkeyMonitor(settings: rig.h.settings)
        #expect(monitor.currentConfig().switchesModels)
        rig.h.settings.lineup.setSwitchable(.cleanup, false)
        rig.h.settings.lineup.setSwitchable(.gemini, false)
        #expect(!monitor.currentConfig().switchesModels)
        Self.hold(rig)
        rig.now += 2
        c.showSwitchHintIfDue()
        #expect(!rig.h.pill.showsTabHint)
        c.handle(.cancel)
    }

    /// Clean-up alone after the main model is a step too: the shortcut is intercepted for it.
    @Test func aCleanupOnlyCycleInterceptsTheShortcut() {
        let settings = AppSettings.inMemory()
        settings.lineup.setSwitchable(.gemini, false)
        #expect(settings.lineup.cycle == [.parakeet, .cleanup])
        #expect(HotkeyMonitor(settings: settings).currentConfig().switchesModels)
    }

    /// Color means the model, whichever is main: a Gemini main model tints the pill while it listens and while it
    /// transcribes; switched to Parakeet, the pill is plain.
    @Test func eachModelTintsThePillWhateverTheMainModel() async throws {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .gemini
        rig.result = { _, _ in
            try await Task.sleep(for: .milliseconds(80))
            return "long talk"
        }
        Self.hold(rig)
        #expect(rig.h.pill.sessionModel == .gemini)
        #expect(PillPalette.accent(for: rig.h.pill.sessionModel, in: rig.h.pill.settings.modelColors) != nil)
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        rig.now += 2
        c.handle(.pttUp)
        #expect(rig.h.pill.phase == .processing)
        #expect(rig.h.pill.sessionModel == .gemini, "the tint stays while it transcribes")
        try await waitUntil { rig.pasted == ["long talk"] && c.machine.activeJobs == 0 }
        #expect(rig.h.pill.sessionModel == nil)

        Self.hold(rig)
        c.handle(.cycleEngine)
        #expect(c.modelOverride == .parakeet && rig.h.pill.sessionModel == .parakeet)
        #expect(PillPalette.accent(for: rig.h.pill.sessionModel, in: rig.h.pill.settings.modelColors) == nil)
        c.handle(.cancel)
    }

    /// A color picked in Models is the one the pill wears for that model's dictations, whichever is main: the pill
    /// reads it from the settings the Hub writes.
    @Test func aColorPickedInModelsTintsItsDictations() {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .gemini
        rig.h.settings.modelColors[.parakeet] = .teal
        rig.h.settings.modelColors[.gemini] = .graphite
        Self.hold(rig)
        #expect(rig.h.pill.sessionModel == .gemini)
        #expect(PillPalette.accent(for: rig.h.pill.sessionModel, in: rig.h.pill.settings.modelColors) == nil,
                "graphite is the plain pill")
        c.handle(.cycleEngine)
        #expect(rig.h.pill.sessionModel == .parakeet)
        #expect(PillPalette.accent(for: rig.h.pill.sessionModel, in: rig.h.pill.settings.modelColors)
                == PillPalette.accent(for: ModelColor.teal))
        c.handle(.cancel)
    }

    /// Gemini as the main model without a key: the dictation is refused, and "Use Parakeet v3" makes Parakeet the
    /// main model.
    @Test func aGeminiMainModelWithoutAKeyOffersParakeet() throws {
        let (rig, _) = Self.make(key: .missing)
        let c = rig.h.controller
        rig.h.settings.lineup.main = .gemini
        c.send(.handsFreeToggle)
        #expect(rig.h.recorder.starts == 0)
        let notice = try #require(rig.h.toasts.notices.first)
        #expect(notice.actions.contains { $0.kind == .selectEngine(.parakeet) })
        try rig.click(.selectEngine(.parakeet), in: notice.dedupeKey)
        #expect(rig.h.settings.lineup.main == .parakeet)
        #expect(rig.notice("engine.selected")?.title == "Now using Parakeet v3")
        #expect(rig.h.settings.lineup.isSwitchable(.gemini), "Gemini stays a step")
    }

    /// Undo of a canceled dictation continues it, with the model it had.
    @Test func undoKeepsTheDictationsModel() async throws {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .gemini
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        Self.hold(rig)
        c.handle(.cycleEngine)
        #expect(c.modelOverride == .parakeet && c.effectiveEngine == .parakeet)
        rig.now += 2
        c.handle(.cancel)
        #expect(c.modelOverride == nil && c.effectiveEngine == .geminiFlash)

        rig.now += 1
        try rig.click(.undoCancel, in: "dictation.canceled")
        #expect(c.machine.capture.isListeningOrLocked)
        #expect(c.modelOverride == .parakeet)
        #expect(rig.h.pill.sessionModel == .parakeet)

        var used: [EngineID] = []
        rig.result = { _, engine in
            used.append(engine)
            return "resumed"
        }
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 1)
        rig.now += 1
        c.send(.pillStop)
        try await waitUntil { rig.pasted == ["resumed"] && c.machine.activeJobs == 0 }
        #expect(used == [.parakeet])
        #expect(c.effectiveEngine == .geminiFlash)
    }

    // MARK: Hands-free's model

    /// Hands-free switches to the model picked for it in Models, as Switch model would: the dictation goes there and
    /// the chip names it, with the lock cue as the one sound. Holding the key stays on the main model.
    @Test func handsFreeSwitchesToItsModel() async throws {
        let (rig, cues) = Self.make()
        let c = rig.h.controller
        rig.h.settings.handsFreeModel = .gemini
        var used: [EngineID] = []
        rig.result = { _, engine in
            used.append(engine)
            return "words"
        }
        let pulses = rig.h.pill.engineChipPulse
        c.send(.handsFreeToggle)
        #expect(c.modelOverride == .gemini && c.effectiveEngine == .geminiFlash)
        #expect(rig.h.pill.sessionModel == .gemini, "the pill wears Gemini's color at once")
        #expect(rig.h.pill.engineChipPulse == pulses + 1)
        #expect(cues.played == [.lock], "one sound: no Switch model tick")
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        rig.now += 2
        c.send(.pillStop)
        try await waitUntil { rig.pasted == ["words"] && c.machine.activeJobs == 0 }

        Self.hold(rig)
        #expect(c.modelOverride == nil && c.effectiveEngine == .parakeet)
        try await Self.release(rig)
        #expect(used == [.geminiFlash, .parakeet])
    }

    /// Space while holding the key goes hands-free too, and switches the same way.
    @Test func goingHandsFreeFromAHoldSwitchesToo() {
        let (rig, cues) = Self.make()
        rig.h.settings.handsFreeModel = .gemini
        Self.hold(rig)
        rig.h.controller.handle(.handsFreeToggle)
        #expect(rig.h.controller.modelOverride == .gemini)
        #expect(cues.played.last == .lock && !cues.played.contains(.modelSwitch))
        rig.h.controller.send(.pillCancel)
    }

    /// A model already picked for this dictation stays, and the main model has nothing to switch to: no tick.
    @Test func handsFreeLeavesAPickedOrMainModelAlone() async throws {
        let (rig, cues) = Self.make()
        let c = rig.h.controller
        rig.h.settings.handsFreeModel = .gemini
        Self.hold(rig)
        c.handle(.cycleEngine)
        #expect(c.modelOverride == .cleanup)
        c.handle(.handsFreeToggle)
        try await Task.sleep(for: .milliseconds(300))
        #expect(c.modelOverride == .cleanup)
        #expect(cues.played.filter { $0 == .modelSwitch }.count == 1, "only fn ⇥'s own tick")
        c.send(.pillCancel)

        let (main, mainCues) = Self.make()
        main.h.settings.lineup.main = .gemini
        main.h.settings.handsFreeModel = .gemini
        main.h.controller.send(.handsFreeToggle)
        try await Task.sleep(for: .milliseconds(300))
        #expect(main.h.controller.modelOverride == nil && main.h.controller.effectiveEngine == .geminiFlash)
        #expect(!mainCues.played.contains(.modelSwitch))
        main.h.controller.send(.pillCancel)
    }

    /// A model that can't take the dictation now is refused as Switch model would refuse it: it stays on the main
    /// model, the pill shakes, and a notice says why.
    @Test func aHandsFreeModelThatCantRunIsRefused() {
        let (rig, _) = Self.make(key: .noCredit(nil))
        rig.h.settings.handsFreeModel = .gemini
        let shakes = rig.h.pill.shakeCount
        rig.h.controller.send(.handsFreeToggle)
        #expect(rig.h.controller.modelOverride == nil && rig.h.controller.effectiveEngine == .parakeet)
        #expect(rig.h.pill.shakeCount == shakes + 1)
        #expect(rig.notice(DictationController.switchModelNoticeKey) != nil)
        rig.h.controller.send(.pillCancel)
    }

    /// fn ⇥ back to the main model is a pick too: hands-free leaves the dictation there.
    @Test func handsFreeLeavesTheMainModelPickedWithSwitchModel() {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        rig.h.settings.handsFreeModel = .gemini
        Self.hold(rig)
        for _ in rig.h.settings.lineup.cycle { c.handle(.cycleEngine) }
        #expect(c.modelOverride == nil, "around the cycle and back on Parakeet")
        c.handle(.handsFreeToggle)
        #expect(c.modelOverride == nil && c.effectiveEngine == .parakeet)
        c.send(.pillCancel)
    }

    /// Polish turned on while holding the key keeps the dictation on Gemini: hands-free doesn't take it away.
    @Test func handsFreeKeepsAPolishingDictationOnGemini() {
        let (rig, cues) = Self.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .gemini
        rig.h.settings.handsFreeModel = .parakeet
        Self.hold(rig)
        c.handle(.polish)
        c.handle(.handsFreeToggle)
        #expect(c.effectiveChoice == .gemini && c.isPolishing)
        #expect(!cues.played.contains(.polishOff))
        c.send(.pillCancel)
    }

    /// The main model can't take a dictation (Gemini without a key) but hands-free's can: fn Space records on it,
    /// from the hands-free key alone and from fn's press (refused for Gemini) followed by Space.
    @Test func handsFreeStartsOnItsModelWhenTheMainOneCant() {
        let (rig, _) = Self.make(key: .missing)
        let c = rig.h.controller
        rig.h.settings.lineup.main = .gemini
        rig.h.settings.handsFreeModel = .parakeet
        c.send(.handsFreeToggle)
        #expect(c.machine.capture.isListeningOrLocked && c.effectiveEngine == .parakeet)
        c.send(.pillCancel)

        c.handle(.pttDown)
        c.handle(.handsFreeToggle)
        #expect(c.machine.capture.isListeningOrLocked && c.effectiveEngine == .parakeet)
        #expect(rig.h.toasts.notices.allSatisfy { $0.style == .info }, "nothing refused")
        c.send(.pillCancel)
    }

    /// Hands-free's model is one Switch model reaches: one that becomes the main model, or that Switch model stops
    /// reaching, is forgotten.
    @Test func handsFreesModelIsOneOfTheCycle() {
        let (rig, _) = Self.make()
        let settings = rig.h.settings
        settings.handsFreeModel = .gemini
        #expect(settings.handsFreeChoice == .gemini)
        settings.lineup.setSwitchable(.gemini, false)
        #expect(settings.handsFreeModel == nil && settings.handsFreeChoice == nil)
        settings.lineup.setSwitchable(.gemini, true)
        #expect(settings.handsFreeChoice == nil, "back in the cycle, but not picked again")
        settings.handsFreeModel = .gemini
        settings.lineup.main = .gemini
        settings.lineup.main = .parakeet
        #expect(settings.handsFreeModel == nil, "it was the main model meanwhile")
    }

    /// Undo goes on hands-free with the model the canceled dictation had, not hands-free's.
    @Test func undoKeepsItsModelOverHandsFrees() throws {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        rig.h.settings.handsFreeModel = .gemini
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        Self.hold(rig)
        rig.now += 2
        c.handle(.cancel)
        rig.now += 1
        try rig.click(.undoCancel, in: "dictation.canceled")
        #expect(c.machine.capture.isListeningOrLocked)
        #expect(c.modelOverride == nil && c.effectiveEngine == .parakeet)
        c.send(.pillCancel)
    }

    /// Tidies whatever it's given into "Clean.", as the selected clean-up model.
    static func cleansUp(_ rig: Rig, into text: String = "Clean.", asked: @escaping (String) -> Void = { _ in }) {
        rig.h.controller.cleanupOverride = { raw, source in
            asked(raw)
            return TranscriptResult(text: text, engine: source, processingTime: 0.1)
        }
    }

    /// The first press puts the dictation on clean-up: Parakeet transcribes, the clean-up model tidies what's pasted,
    /// and the chip says so until the text lands. The next dictation isn't cleaned up.
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

        // The next dictation is on Parakeet alone.
        rig.result = { _, _ in "plain words" }
        Self.hold(rig)
        #expect(c.modelOverride == nil)
        try await Self.release(rig)
        #expect(rig.pasted.last == "plain words" && asked.count == 1)
    }

    /// Clean-up as the main model tidies every dictation.
    @Test func aCleanupMainModelTidiesEveryDictation() async throws {
        let (rig, _) = Self.make()
        rig.h.settings.lineup.main = .cleanup
        Self.cleansUp(rig)
        rig.result = { _, _ in "um raw" }
        Self.hold(rig)
        #expect(rig.h.pill.sessionModel == .cleanup)
        try await Self.release(rig)
        Self.hold(rig)
        try await Self.release(rig)
        #expect(rig.pasted == ["Clean.", "Clean."])
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
        rig.h.settings.lineup.setSwitchable(.cleanup, false)
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
        #expect(steps == [.gemini, nil, .cleanup, .gemini, nil])
        #expect(cues.played.filter { $0 == .modelSwitch }.count == 6)
        #expect(c.machine.capture.isListeningOrLocked)
        c.handle(.cancel)
        c.handle(.cycleEngineRepeat)
        #expect(c.modelOverride == nil, "no dictation, nothing to step")
    }

    /// The tick and Polish's drops have voices of their own, so held at 30 ms they ring over each other; other cues
    /// restart.
    @Test func theTickRingsOverItself() {
        #expect(Double(AVCueOutput.voices(for: .modelSwitch)) * 0.03 > 0.07, "enough voices for a 70 ms tick every 30 ms")
        // On and off take turns: each drop comes back every other repeat, 60 ms apart.
        for drop in [SoundEffect.polishOn, .polishOff] {
            #expect(Double(AVCueOutput.voices(for: drop)) * 0.06 > 0.09, "enough voices for a 90 ms drop every 60 ms")
        }
        let held: Set<SoundEffect> = [.modelSwitch, .polishOn, .polishOff]
        #expect(SoundEffect.allCases.filter { !held.contains($0) }.allSatisfy { AVCueOutput.voices(for: $0) == 1 })
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

    /// The notice without a key names what it keeps out of reach, in cycle order.
    @Test func theKeyNoticeNamesWhatItBlocks() {
        #expect(DictationController.switchWithoutKeyNotice(.missing, blocked: [.cleanup]).title
            == "Clean-up needs an OpenRouter key")
        #expect(DictationController.switchWithoutKeyNotice(.missing, blocked: [.gemini]).title
            == "Gemini needs an OpenRouter key")
        #expect(DictationController.switchWithoutKeyNotice(.missing, blocked: [.parakeet]).title
            == "Parakeet needs an OpenRouter key")
        #expect(DictationController.switchWithoutKeyNotice(.noCredit(nil), blocked: [.cleanup, .gemini]).title
            == "Clean-up and Gemini need OpenRouter credit")
        let all = DictationController.switchWithoutKeyNotice(.invalid("401"), blocked: [.parakeet, .cleanup, .gemini])
        #expect(all.title == "Parakeet, Clean-up and Gemini need an OpenRouter key")
        #expect(all.body == "OpenRouter rejected yours. Update it to switch models.")
        #expect(DictationController.switchWithoutKeyNotice(.missing, blocked: [.gemini]).body
            == "Add one to switch models while dictating.")
        #expect(DictationController.switchWithoutKeyNotice(.failed("unreadable"), blocked: [.gemini]).body
            == "\(Brand.name) can’t read yours. Check it to switch models.")
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

    @Test func thePillsMenuPicksAModelForThisDictation() throws {
        let (rig, cues) = Self.make()
        let c = rig.h.controller
        c.start()
        #expect(rig.h.pill.menuChoices == [.parakeet, .cleanup, .gemini])
        c.selectModelForCurrentDictation(.gemini)
        #expect(c.modelOverride == nil, "no dictation, nothing to pick for")
        c.send(.handsFreeToggle)
        c.selectModelForCurrentDictation(.gemini)
        #expect(c.effectiveEngine == .geminiFlash)
        #expect(rig.h.pill.sessionModel == .gemini)
        c.selectModelForCurrentDictation(.gemini)
        c.selectModelForCurrentDictation(.cleanup)
        #expect(c.modelOverride == .cleanup && c.effectiveEngine == .parakeet)
        #expect(rig.h.pill.sessionModel == .cleanup)
        c.selectModelForCurrentDictation(rig.h.settings.lineup.main)
        #expect(c.modelOverride == nil)
        #expect(rig.h.pill.engineChipPulse == 3)
        #expect(cues.played.filter { $0 == .modelSwitch }.count == 3)
        let reason = try #require(rig.h.pill.unavailableReason)
        #expect(ModelChoice.allCases.allSatisfy { reason($0) == nil }, "the key works: everything can run")
        c.send(.pillCancel)
    }

    /// The menu disables what can't take the dictation, and picking it anyway says why.
    @Test func thePillsMenuSaysWhatCantRun() throws {
        let (rig, cues) = Self.make(key: .missing)
        let c = rig.h.controller
        c.start()
        let reason = try #require(rig.h.pill.unavailableReason)
        #expect(reason(.parakeet) == nil, "the main model always can")
        #expect(reason(.cleanup) == "Needs key" && reason(.gemini) == "Needs key")
        c.send(.handsFreeToggle)
        c.selectModelForCurrentDictation(.gemini)
        #expect(c.modelOverride == nil && !cues.played.contains(.modelSwitch))
        #expect(rig.notice(DictationController.switchModelNoticeKey)?.title == "Gemini needs an OpenRouter key")
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

    @Test func noHintWithoutAUsableKeyOrAnotherModel() {
        for (key, others) in [(KeyStatus.missing, true), (.valid(KeyInfo()), false)] {
            let (rig, _) = Self.make(key: key)
            let c = rig.h.controller
            c.runsTimers = false
            rig.h.settings.lineup.setSwitchable(.cleanup, others)
            rig.h.settings.lineup.setSwitchable(.gemini, others)
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
