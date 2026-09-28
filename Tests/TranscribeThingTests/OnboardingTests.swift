import Foundation
import Testing
@testable import TranscribeThing

// MARK: - Pure gating

@Suite struct OnboardingGateTests {
    private func inputs(mic: PermissionState = .granted, ax: PermissionState = .granted,
                        engine: EngineID = .parakeet, local: LocalModelState = .ready,
                        key: KeyStatus = .missing, stored: Bool = false) -> OnboardingGate.Inputs {
        OnboardingGate.Inputs(microphone: mic, accessibility: ax, engine: engine, localState: local,
                              keyStatus: key, hasStoredKey: stored)
    }

    @Test(arguments: [(-3, OnboardingStep.welcome), (0, .welcome), (2, .model), (3, .tryIt), (4, .done), (99, .done)])
    func resumeClampsTheStoredStep(_ stored: Int, _ expected: OnboardingStep) {
        #expect(OnboardingStep.resuming(from: stored) == expected)
    }

    @Test func fiveSteps() {
        #expect(OnboardingStep.allCases == [.welcome, .permissions, .model, .tryIt, .done])
        #expect(OnboardingStepIndex.tryIt == OnboardingStep.tryIt.rawValue, "the Hub's Practice button lands on the chat")
        #expect(OnboardingStepIndex.welcome == OnboardingStep.welcome.rawValue)
    }

    /// Old layout: welcome, permissions, model, shortcuts, try it, done.
    @Test(arguments: [(-1, OnboardingStep.welcome), (0, .welcome), (1, .permissions), (2, .model),
                      (3, .tryIt), (4, .tryIt), (5, .done), (9, .done)])
    func sixStepProgressMapsOntoFiveSteps(_ old: Int, _ expected: OnboardingStep) {
        #expect(OnboardingStep.resuming(from: AppSettings.onboardingStep(fromSixStepIndex: old)) == expected)
    }

    @Test func freeStepsNeverBlock() {
        let blocked = inputs(mic: .denied, ax: .denied, local: .notInstalled)
        for step in [OnboardingStep.welcome, .tryIt, .done] {
            #expect(OnboardingGate.canContinue(step, blocked))
        }
    }

    @Test func permissionsNeedBothForContinue() {
        #expect(!OnboardingGate.canContinue(.permissions, inputs(mic: .notDetermined, ax: .notDetermined)))
        #expect(!OnboardingGate.canContinue(.permissions, inputs(mic: .granted, ax: .notDetermined)))
        #expect(!OnboardingGate.canContinue(.permissions, inputs(mic: .denied, ax: .granted)))
        #expect(OnboardingGate.canContinue(.permissions, inputs(mic: .granted, ax: .granted)))
    }

    @Test func accessibilityIsSkippableOnlyOnceTheMicIsAllowed() {
        #expect(OnboardingGate.canSkipAccessibility(inputs(mic: .granted, ax: .notDetermined)))
        #expect(OnboardingGate.canSkipAccessibility(inputs(mic: .granted, ax: .denied)))
        #expect(!OnboardingGate.canSkipAccessibility(inputs(mic: .notDetermined, ax: .notDetermined)))
        #expect(!OnboardingGate.canSkipAccessibility(inputs(mic: .denied, ax: .notDetermined)))
        #expect(!OnboardingGate.canSkipAccessibility(inputs(mic: .granted, ax: .granted)))
    }

    @Test(arguments: [
        (LocalModelState.ready, true), (.installed, true), (.preparing(since: .distantPast), true),
        (.downloading(DownloadProgress(fraction: 0.2)), true), (.notInstalled, false), (.failed("disk"), false),
    ])
    func localEngineReadiness(_ state: LocalModelState, _ usable: Bool) {
        for engine in EngineID.localEngines {
            #expect(OnboardingGate.canContinue(.model, inputs(engine: engine, local: state)) == usable)
        }
    }

    @Test func cloudEngineNeedsAWorkingKey() {
        let valid = KeyStatus.valid(KeyInfo(limitRemaining: 3))
        for engine in EngineID.cloudEngines {
            #expect(OnboardingGate.canContinue(.model, inputs(engine: engine, local: .notInstalled, key: valid, stored: true)))
            #expect(!OnboardingGate.canContinue(.model, inputs(engine: engine, key: .missing)))
            #expect(!OnboardingGate.canContinue(.model, inputs(engine: engine, key: .checking, stored: true)))
            #expect(!OnboardingGate.canContinue(.model, inputs(engine: engine, key: .invalid("401"), stored: true)))
            #expect(!OnboardingGate.canContinue(.model, inputs(engine: engine, key: .noCredit(nil), stored: true)))
            #expect(OnboardingGate.canContinue(.model, inputs(engine: engine, key: .offline, stored: true)))
            #expect(!OnboardingGate.canContinue(.model, inputs(engine: engine, key: .offline, stored: false)))
        }
    }

    @Test func cloudSelectionIgnoresLocalModelState() {
        #expect(!OnboardingGate.canContinue(.model, inputs(engine: .geminiFlash, local: .ready, key: .missing)))
    }

    @Test func primaryTitles() {
        let downloading = inputs(local: .downloading(DownloadProgress(fraction: 0.4)))
        #expect(OnboardingGate.primaryTitle(.welcome, inputs(), practiceStarted: false) == "Get Started")
        #expect(OnboardingGate.primaryTitle(.model, downloading, practiceStarted: false) == "Continue")
        #expect(OnboardingGate.primaryTitle(.model, inputs(), practiceStarted: false) == "Continue")
        #expect(OnboardingGate.primaryTitle(.tryIt, inputs(), practiceStarted: false) == "Skip Practice")
        #expect(OnboardingGate.primaryTitle(.tryIt, inputs(), practiceStarted: true) == "Continue")
        #expect(OnboardingGate.primaryTitle(.done, inputs(), practiceStarted: true) == "Start Dictating")
    }

    @Test func keyFormatChecks() {
        #expect(OnboardingGate.keyFormatProblem("sk-o") == nil)
        #expect(OnboardingGate.keyFormatProblem("sk-or-v1-abc") == nil)
        #expect(OnboardingGate.keyFormatProblem("  sk-or-v1-abc  ") == nil)
        #expect(OnboardingGate.keyFormatProblem("sk-proj-12345") != nil)
        #expect(OnboardingGate.keyFormatProblem("sk-or-v1 abc") != nil)
        #expect(!OnboardingGate.keyIsCheckable("sk-or-v1-abc"))
        #expect(OnboardingGate.keyIsCheckable("sk-or-v1-" + String(repeating: "a", count: 64)))
        #expect(!OnboardingGate.keyIsCheckable("sk-proj-" + String(repeating: "a", count: 64)))
    }

    @Test func diskHeadroomIsTwentyFivePercent() throws {
        let needed = try #require(OnboardingGate.requiredDiskBytes(for: .parakeet))
        #expect(needed == Int64((Double(632_321_326) * 1.25).rounded(.up)))
        #expect(OnboardingGate.requiredDiskBytes(for: .geminiFlash) == nil)
    }

    @Test func practiceReadinessOrder() {
        func eval(mic: PermissionState = .granted, ax: PermissionState = .granted, engine: EngineID = .parakeet,
                  local: LocalModelState = .ready, key: KeyStatus = .missing, stored: Bool = false) -> PracticeReadiness {
            PracticeReadiness.evaluate(microphone: mic, accessibility: ax, engine: engine, localState: local,
                                       keyStatus: key, hasStoredKey: stored)
        }
        #expect(eval(mic: .denied, ax: .denied, local: .notInstalled) == .needsMicrophone)
        #expect(eval(ax: .notDetermined) == .needsAccessibility)
        #expect(eval() == .ready)
        #expect(eval(local: .preparing(since: .distantPast)) == .warmingUp(.parakeet))
        #expect(eval(local: .installed) == .warmingUp(.parakeet))
        #expect(eval(local: .downloading(DownloadProgress(fraction: 0.62))) == .downloading(.parakeet, 0.62))
        #expect(eval(local: .failed("x")) == .notDownloaded(.parakeet))
        #expect(eval(engine: .geminiFlash, key: .missing) == .needsKey(.geminiFlash))
        #expect(eval(engine: .parakeetCloud, key: .valid(KeyInfo()), stored: true) == .ready)
        #expect(eval(local: .downloading(DownloadProgress(fraction: 0.1))).allowsPractice == false)
        #expect(eval(local: .installed).allowsPractice)
    }

    @Test func illustratedKeysFollowBindings() {
        #expect(IllustratedKey.keys(for: .fn) == [.fn])
        #expect(IllustratedKey.keys(for: .fnSpace) == [.fn, .space])
        #expect(IllustratedKey.keys(for: .escape) == [.escape])
        #expect(IllustratedKey.keys(for: .rightOption) == [.option])
        // V isn't on the drawing, so the chord can't be shown as held.
        #expect(IllustratedKey.keys(for: .commandFnV).isEmpty)
        #expect(IllustratedKey.keys(for: nil).isEmpty)
    }

    @Test func practiceStatMath() {
        let stat = PracticeStat(words: 38, seconds: 11)
        #expect(stat.wordsPerMinute == 207)
        #expect(stat.isMeaningful)
        #expect(!PracticeStat(words: 2, seconds: 3).isMeaningful)
        #expect(!PracticeStat(words: 10, seconds: 0.5).isMeaningful)
    }
}

// MARK: - Model behavior

@MainActor
@Suite struct OnboardingModelTests {
    private func makeModel(step: Int = 0, _ configure: (inout OnboardingContext) -> Void = { _ in }) -> OnboardingModel {
        let env = AppEnvironment.preview()
        env.settings.onboardingCompleted = false
        env.settings.onboardingStep = step
        var ctx = OnboardingContext(env: env)
        configure(&ctx)
        return OnboardingModel(context: ctx)
    }

    @Test func resumesAtTheSavedStepAndPersistsNavigation() {
        let model = makeModel(step: 2)
        #expect(model.step == .model)
        model.goNext()
        #expect(model.step == .tryIt)
        #expect(model.ctx.settings.onboardingStep == 3)
        #expect(model.movingForward)
        model.goNext()
        #expect(model.step == .done)
        #expect(model.ctx.settings.onboardingStep == 4)
        model.goBack()
        model.goBack()
        #expect(model.step == .model)
        #expect(!model.movingForward)
        #expect(model.ctx.settings.onboardingStep == 2)
    }

    /// Someone who quit a six-step build on Shortcuts or Try it comes back to the merged step, once.
    @Test(arguments: [(3, OnboardingStep.tryIt), (4, .tryIt), (5, .done), (2, .model)])
    func resumesSixStepProgressSavedByAnOlderBuild(_ old: Int, _ expected: OnboardingStep) throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        defaults.set(old, forKey: SettingsKey.onboardingStep.defaultsKey)

        let settings = AppSettings(defaults: defaults)
        #expect(settings.onboardingStep == expected.rawValue)
        #expect(defaults.object(forKey: SettingsKey.onboardingStep.defaultsKey) == nil, "the six-step value is moved, not kept")
        #expect(defaults.integer(forKey: SettingsKey.onboardingResumeStep.defaultsKey) == expected.rawValue)
        let model = makeModel { ctx in ctx.settings = settings }
        #expect(model.step == expected)

        // Five-step values saved from now on are read as they are, never migrated again.
        settings.onboardingStep = OnboardingStep.done.rawValue
        #expect(AppSettings(defaults: defaults).onboardingStep == OnboardingStep.done.rawValue)
    }

    @Test func hubPracticeLinkOpensTheMergedStep() {
        let model = makeModel(step: 0)
        model.externalStepChanged(OnboardingStepIndex.tryIt)
        #expect(model.step == .tryIt)
    }

    @Test func primaryActionRespectsTheGate() {
        let model = makeModel(step: 1) { ctx in ctx.permissions = .preview(mic: .granted, ax: .notDetermined) }
        #expect(!model.canContinue)
        model.primaryAction()
        #expect(model.step == .permissions)
        #expect(model.canSkipAccessibility)
        model.skipAccessibility()
        #expect(model.skipAccessibilityArmed)
        #expect(model.step == .permissions)
        model.skipAccessibility()
        #expect(model.step == .model)
    }

    @Test func modelStepBlocksUntilSomethingIsUsable() {
        let model = makeModel(step: 2) { ctx in
            ctx.models = .preview(states: [.parakeet: .notInstalled])
            ctx.account = .preview(status: .missing)
        }
        #expect(!model.canContinue)
        model.select(.parakeetCloud)
        #expect(model.ctx.settings.selectedEngine == .parakeetCloud)
        #expect(model.showsKeyField)
        #expect(!model.canContinue)
    }

    @Test func validKeyUnlocksCloudEngines() {
        let model = makeModel(step: 2) { ctx in
            ctx.models = .preview(states: [.parakeet: .notInstalled])
            ctx.account = .preview(status: .valid(KeyInfo(limitRemaining: 4.2)))
        }
        model.select(.parakeetCloud)
        #expect(model.canContinue)
        #expect(!model.showsKeyField)
        model.replaceKey()
        #expect(model.showsKeyField)
    }

    @Test func cloudSpeechSharesTheOneKey() {
        let missing = makeModel(step: 2) { ctx in
            ctx.models = .preview(states: [.parakeet: .notInstalled])
            ctx.account = .preview(status: .missing)
        }
        missing.select(.parakeetCloud)
        #expect(missing.ctx.settings.selectedEngine == .parakeetCloud)
        #expect(missing.showsKeyField)
        #expect(!missing.canContinue)

        let connected = makeModel(step: 2) { ctx in
            ctx.models = .preview(states: [.parakeet: .notInstalled])
        }
        connected.select(.parakeetCloud)
        #expect(connected.canContinue, "the key Gemini uses works for cloud Parakeet too")
        #expect(!connected.showsKeyField)
    }

    @Test func keyFormatErrorShowsOnSubmit() {
        let model = makeModel(step: 2)
        model.updateKeyDraft("sk-proj-abcdef")
        model.submitKeyDraft()
        #expect(model.keyFormatError != nil)
        model.updateKeyDraft("sk-or-v1-")
        #expect(model.keyFormatError == nil)
    }

    @Test func diskCheckBlocksTheDownload() {
        let model = makeModel(step: 2) { ctx in ctx.models = .preview(states: [.parakeet: .notInstalled]) }
        model.stageDisk(free: 100_000_000)
        #expect(!model.hasEnoughDisk(for: .parakeet))
        model.download(.parakeet)
        #expect(!model.celebrateReady.contains(.parakeet))
        model.stageDisk(free: 10_000_000_000)
        model.download(.parakeet)
        #expect(model.celebrateReady.contains(.parakeet))
    }

    @Test func holdingFnLightsTheKeysWithoutTickingALesson() {
        let model = makeModel(step: 3)
        let t0 = Date()
        model.handleRawKey(RawKeyEvent(key: .fn, isDown: true), now: t0)
        #expect(model.isHoldingPushToTalk)
        #expect(model.livePhase == .listening)
        model.handleRawKey(RawKeyEvent(key: .fn, isDown: false), now: t0.addingTimeInterval(0.8))
        #expect(model.heldPushToTalk)
        #expect(!model.triedHandsFree)
        #expect(model.livePhase == .rest)
        #expect(model.completedLessons.isEmpty, "with a model ready, only words in the chat count")
    }

    @Test func keysTickTheLessonsWhileTheModelDownloads() {
        let model = makeModel(step: 3) { ctx in
            ctx.models = .preview(states: [.parakeet: .downloading(DownloadProgress(fraction: 0.4))])
        }
        #expect(model.lessonsFollowKeys)
        let t0 = Date()
        model.handleRawKey(RawKeyEvent(key: .fn, isDown: true), now: t0)
        model.handleRawKey(RawKeyEvent(key: .fn, isDown: false), now: t0.addingTimeInterval(0.8))
        #expect(model.completedLessons == [.pushToTalk])
        #expect(model.currentLesson == .handsFree)
        model.handleRawKey(RawKeyEvent(key: .fn, isDown: true), now: t0.addingTimeInterval(2))
        model.handleRawKey(RawKeyEvent(key: .space, isDown: true), now: t0.addingTimeInterval(2.1))
        #expect(model.completedLessons == [.pushToTalk, .handsFree])
        model.handleRawKey(RawKeyEvent(key: .escape, isDown: true), now: t0.addingTimeInterval(2.5))
        #expect(model.currentLesson == nil)
        #expect(model.primaryTitle == "Continue")
    }

    @Test func keysOutsideThePracticeStepOnlyLightUp() {
        let model = makeModel(step: 1)
        model.handleRawKey(RawKeyEvent(key: .fn, isDown: true))
        model.handleRawKey(RawKeyEvent(key: .escape, isDown: true))
        #expect(model.pressedKeys == [.fn, .escape])
        #expect(model.completedLessons.isEmpty)
        #expect(!model.handsFreeLatched)
    }

    @Test func fnSpaceLatchesAndFnFinishes() {
        let model = makeModel(step: 3)
        let t0 = Date()
        model.handleRawKey(RawKeyEvent(key: .fn, isDown: true), now: t0)
        model.handleRawKey(RawKeyEvent(key: .space, isDown: true), now: t0.addingTimeInterval(0.1))
        #expect(model.triedHandsFree)
        #expect(model.handsFreeLatched)
        model.handleRawKey(RawKeyEvent(key: .space, isDown: false), now: t0.addingTimeInterval(0.2))
        model.handleRawKey(RawKeyEvent(key: .fn, isDown: false), now: t0.addingTimeInterval(0.25))
        #expect(model.handsFreeLatched)
        #expect(model.livePhase == .locked)
        model.handleRawKey(RawKeyEvent(key: .fn, isDown: true), now: t0.addingTimeInterval(3))
        model.handleRawKey(RawKeyEvent(key: .fn, isDown: false), now: t0.addingTimeInterval(3.1))
        #expect(!model.handsFreeLatched)
    }

    @Test func doublePressLatchesHandsFree() {
        let model = makeModel(step: 3)
        model.ctx.settings.doublePressForHandsFree = true
        let t0 = Date()
        model.handleRawKey(RawKeyEvent(key: .fn, isDown: true), now: t0)
        model.handleRawKey(RawKeyEvent(key: .fn, isDown: false), now: t0.addingTimeInterval(0.12))
        model.handleRawKey(RawKeyEvent(key: .fn, isDown: true), now: t0.addingTimeInterval(0.3))
        #expect(model.handsFreeLatched)
        #expect(model.triedHandsFree)
    }

    @Test func repeatedKeyDownsAreIgnored() {
        let model = makeModel(step: 3)
        let t0 = Date()
        model.handleRawKey(RawKeyEvent(key: .fn, isDown: true), now: t0)
        model.handleRawKey(RawKeyEvent(key: .fn, isDown: true), now: t0.addingTimeInterval(0.2))
        model.handleRawKey(RawKeyEvent(key: .other(12), isDown: true), now: t0.addingTimeInterval(0.3))
        #expect(model.pressedKeys == [.fn])
    }

    @Test func dictatedTextSendsAndCompletesTheFirstLesson() {
        let model = makeModel(step: 3)
        let t0 = Date()
        model.pillPhaseChanged(from: .hidden, to: .listening, now: t0)
        model.pillPhaseChanged(from: .listening, to: .processing, now: t0.addingTimeInterval(4))
        model.updateDraft("Heading to the gym at four, then dinner.", now: t0.addingTimeInterval(4.6))
        #expect(model.draft.isEmpty)
        #expect(model.completedLessons == [.pushToTalk])
        #expect(model.messages.map(\.sender) == [.alex, .me, .alex])
        #expect(model.practiceStat == PracticeStat(words: 8, seconds: 4))
        #expect(model.currentLesson == .handsFree)
        #expect(model.primaryTitle == "Continue")
    }

    /// Pretends the pipeline recorded (hands-free or held) and pasted `text` into the practice field.
    private func dictate(_ text: String, handsFree: Bool, into model: OnboardingModel, at t0: Date) {
        model.pillPhaseChanged(from: .hidden, to: handsFree ? .locked : .listening, now: t0)
        model.pillPhaseChanged(from: handsFree ? .locked : .listening, to: .processing, now: t0.addingTimeInterval(4))
        model.updateDraft(text, now: t0.addingTimeInterval(4.6))
        model.pillPhaseChanged(from: .processing, to: .hidden, now: t0.addingTimeInterval(5))
    }

    @Test func eachLessonTicksForTheWayItWasDictated() {
        let model = makeModel(step: 3)
        let t0 = Date()
        dictate("Heading to the gym at four, then dinner.", handsFree: false, into: model, at: t0)
        #expect(model.completedLessons == [.pushToTalk])

        // Holding the key again doesn't pass for hands-free: a hint says how.
        dictate("Probably the farmers market in the morning.", handsFree: false, into: model, at: t0.addingTimeInterval(10))
        #expect(model.completedLessons == [.pushToTalk])
        #expect(model.practiceHint == .tryHandsFree)
        #expect(model.currentLesson == .handsFree)

        dictate("And then a long lunch with Sam, if the weather holds.", handsFree: true, into: model, at: t0.addingTimeInterval(20))
        #expect(model.completedLessons == [.pushToTalk, .handsFree])
        #expect(model.practiceHint == nil)
        #expect(model.currentLesson == .cancel)
        #expect(model.messages.map(\.sender) == [.alex, .me, .alex, .me, .alex, .me, .alex])
    }

    @Test func doublePressingIntoHandsFreeCountsAsHandsFree() {
        let model = makeModel(step: 3)
        model.ctx.settings.doublePressForHandsFree = true
        let t0 = Date()
        // The pill starts held, then the second press latches it.
        model.pillPhaseChanged(from: .hidden, to: .listening, now: t0)
        model.pillPhaseChanged(from: .listening, to: .locked, now: t0.addingTimeInterval(0.4))
        model.pillPhaseChanged(from: .locked, to: .processing, now: t0.addingTimeInterval(5))
        model.updateDraft("Long answer, spoken with my hands off the keyboard.", now: t0.addingTimeInterval(5.5))
        #expect(model.completedLessons == [.handsFree])
        #expect(model.currentLesson == .pushToTalk)
    }

    @Test func typedTextDoesNotCountAsDictation() {
        let model = makeModel(step: 3)
        model.updateDraft("h")
        model.updateDraft("hi")
        model.submitDraft()
        #expect(model.completedLessons.isEmpty)
        #expect(model.practiceHint == .typedInstead)
        #expect(model.messages.last?.sender == .me)
    }

    @Test func escWhileRecordingCompletesTheCancelLesson() {
        let model = makeModel(step: 3)
        model.pillPhaseChanged(from: .hidden, to: .listening)
        model.handleRawKey(RawKeyEvent(key: .escape, isDown: true))
        #expect(model.completedLessons.contains(.cancel))
        #expect(model.messages.last?.sender == .note)
        #expect(model.messages.last?.text == OnboardingModel.cancelNote)
    }

    /// Undo after a cancel picks the recording back up hands-free; what it then pastes is a hands-free answer.
    @Test func undoResumingHandsFreeFinishesTheHandsFreeLesson() {
        let model = makeModel(step: 3)
        let t0 = Date()
        dictate("Heading to the gym at four, then dinner.", handsFree: false, into: model, at: t0)
        model.pillPhaseChanged(from: .hidden, to: .listening, now: t0.addingTimeInterval(10))
        model.handleRawKey(RawKeyEvent(key: .escape, isDown: true), now: t0.addingTimeInterval(12))
        model.handleRawKey(RawKeyEvent(key: .escape, isDown: false), now: t0.addingTimeInterval(12.1))
        model.pillPhaseChanged(from: .listening, to: .hidden, now: t0.addingTimeInterval(12.1))
        #expect(model.completedLessons == [.pushToTalk, .cancel])
        #expect(model.draft.isEmpty, "nothing pasted on cancel")

        model.pillPhaseChanged(from: .hidden, to: .locked, now: t0.addingTimeInterval(14))
        model.pillPhaseChanged(from: .locked, to: .processing, now: t0.addingTimeInterval(20))
        model.updateDraft("Actually, the plan is a long walk and then pizza.", now: t0.addingTimeInterval(20.5))
        #expect(model.completedLessons == [.pushToTalk, .handsFree, .cancel])
        #expect(model.currentLesson == nil)
    }

    /// Stands in for `DictationController.committedPillPhase` while the real pill shows a press that never commits.
    private final class DictationPhaseBox {
        var phase: PillPhase = .rest
    }

    /// A quick fn tap brings the pill up for the double-press window, but it isn't a recording: a paste or an
    /// autocorrect right after it isn't taken for dictation.
    @Test func aTapThatShowsThePillIsNotARecording() {
        let committed = DictationPhaseBox()
        let model = makeModel(step: 3) { ctx in ctx.dictationPhase = { committed.phase } }
        model.ctx.pillModel.phase = .listening
        model.updateDraft("Sounds good", now: Date())
        #expect(!model.isSendingDictation)
        #expect(model.draft == "Sounds good")
        #expect(model.messages.map(\.sender) == [.alex])
        #expect(model.livePhase == .rest, "the stage follows what was committed (and the keys)")
    }

    /// Keys that only reach the event tap: the real pill stands in for a hold only while it really records, not
    /// while it waits out the double-press window after a short press.
    @Test func theFallbackHoldCheckIgnoresTheTapWindow() async throws {
        let committed = DictationPhaseBox()
        let model = makeModel(step: 3) { ctx in
            ctx.dictationPhase = { committed.phase }
            ctx.isPreview = false
        }
        committed.phase = .listening
        model.pillPhaseChanged(from: .rest, to: .listening)
        // Released right after the confirm: the pill stays up for a second press, but nothing records.
        model.ctx.pillModel.phase = .listening
        committed.phase = .rest
        model.pillPhaseChanged(from: .listening, to: .rest)
        try await Task.sleep(for: .milliseconds(600))
        #expect(!model.heldPushToTalk)

        committed.phase = .listening
        model.pillPhaseChanged(from: .rest, to: .listening)
        try await Task.sleep(for: .milliseconds(600))
        #expect(model.heldPushToTalk, "a real hold still counts")
    }

    @Test func escInTheTapWindowDoesntCompleteTheCancelLesson() {
        let committed = DictationPhaseBox()
        let model = makeModel(step: 3) { ctx in ctx.dictationPhase = { committed.phase } }
        model.ctx.pillModel.phase = .listening
        model.handleRawKey(RawKeyEvent(key: .escape, isDown: true))
        #expect(!model.completedLessons.contains(.cancel), "nothing was recording")
        model.handleRawKey(RawKeyEvent(key: .escape, isDown: false))

        committed.phase = .listening
        model.handleRawKey(RawKeyEvent(key: .escape, isDown: true))
        #expect(model.completedLessons.contains(.cancel))
    }

    @Test func escWhileIdleDoesNothing() {
        let model = makeModel(step: 3)
        model.handleRawKey(RawKeyEvent(key: .escape, isDown: true))
        #expect(model.completedLessons.isEmpty)
    }

    @Test func noSpeechShowsTheMicHint() {
        let model = makeModel(step: 3)
        model.pillPhaseChanged(from: .processing, to: .error)
        #expect(model.practiceHint == .noSpeech)
        model.pillPhaseChanged(from: .error, to: .listening)
        #expect(model.practiceHint == nil)
    }

    @Test func finishCompletesOnboardingAndAppliesPreferences() {
        let model = makeModel(step: 4)
        #expect(model.step == .done)
        #expect(model.openAtLogin)
        model.finish()
        #expect(model.ctx.settings.onboardingCompleted)
        #expect(model.ctx.settings.onboardingStep == 0)
    }

    @Test func fnCardAppearsOnlyWhenFnIsUsedAndBusy() {
        let model = makeModel(step: 1)
        model.fnKeyUsageOverride = .doNothing
        #expect(!model.showsFnKeyCard)
        model.fnKeyUsageOverride = .other("Emoji & Symbols")
        #expect(model.showsFnKeyCard)
        model.ctx.settings.shortcuts[.pushToTalk] = .rightOption
        model.ctx.settings.shortcuts[.handsFree] = .f13
        #expect(!model.showsFnKeyCard)
    }
}

// MARK: - Copy style

/// Visible copy uses the typographic apostrophe (’). A straight tick looks cheap next to the rest of the app,
/// most of all in the serif display titles.
@Suite struct CopyStyleTests {
    /// Sample dictation keeps the ASCII apostrophe the engines produce.
    private static let dictatedSamples: Set<String> = [
        "Let's push the review to Thursday and ship on Monday.",
        "Let's move the design review to Thursday afternoon so Maya can join, and I'll send the updated deck tonight. Also, can someone check whether the staging build picked up the new onboarding copy?",
        "Let's move the design review to Thursday afternoon so Maya can join.",
    ]

    /// Single-line string literals on one line of Swift, comments skipped.
    static func stringLiterals(in line: String) -> [String] {
        var literals: [String] = []
        var current = ""
        var inString = false
        var chars = Array(line)[...]
        while let c = chars.popFirst() {
            if inString {
                if c == "\\" {
                    current.append(c)
                    if let next = chars.popFirst() { current.append(next) }
                } else if c == "\"" {
                    inString = false
                    literals.append(current)
                } else {
                    current.append(c)
                }
            } else if c == "/", chars.first == "/" {
                break
            } else if c == "\"" {
                if chars.starts(with: "\"\"") { break }
                inString = true
                current = ""
            }
        }
        return literals
    }

    @Test func literalScannerSkipsCommentsAndEscapes() {
        #expect(Self.stringLiterals(in: #"Text("You’re set") // don't"#) == ["You’re set"])
        #expect(Self.stringLiterals(in: #"f("a \"b\" c", "it's")"#) == [#"a \"b\" c"#, "it's"])
    }

    @Test func uiCopyUsesTypographicApostrophes() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TranscribeThing")
        var offenders: [String] = []
        for folder in ["UI", "Pill"] {
            let dir = sources.appendingPathComponent(folder)
            let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            #expect(!files.isEmpty, "No sources under \(dir.path)")
            for file in files {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    for literal in Self.stringLiterals(in: line)
                    where literal.contains("'") && !Self.dictatedSamples.contains(literal) {
                        offenders.append("\(file.lastPathComponent):\(index + 1): \(literal)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "Use ’ instead of ' in: \(offenders.joined(separator: "\n"))")
    }
}

// MARK: - Extra models

@Suite struct OnboardingExtraModelsGateTests {
    @Test func extraModelsNeedAnEnabledModelAndAWorkingKey() {
        let valid = KeyStatus.valid(KeyInfo(limitRemaining: 3))
        #expect(OnboardingGate.extraModelsUsable(enabled: [.engine(.geminiFlash)], keyStatus: valid, hasStoredKey: true))
        #expect(!OnboardingGate.extraModelsUsable(enabled: [], keyStatus: valid, hasStoredKey: true))
        #expect(!OnboardingGate.extraModelsUsable(enabled: [.cleanup], keyStatus: .missing, hasStoredKey: false))
        #expect(!OnboardingGate.extraModelsUsable(enabled: [.engine(.geminiFlash)], keyStatus: .invalid("401"), hasStoredKey: true))
        #expect(OnboardingGate.extraModelsUsable(enabled: [.engine(.geminiFlash)], keyStatus: .offline, hasStoredKey: true))
    }

    @Test func noteNamesTheActualSwitchModelBinding() {
        let fnTab = OnboardingGate.extraModelsNote(binding: .fnTab, enabled: [.engine(.geminiFlash)])
        #expect(fnTab.contains(Shortcut.fnTab.compactDescription.replacingOccurrences(of: " ", with: "\u{00A0}")))
        let custom = OnboardingGate.extraModelsNote(binding: .rightCommand, enabled: [.engine(.geminiFlash)])
        #expect(custom.contains(Shortcut.rightCommand.compactDescription.replacingOccurrences(of: " ", with: "\u{00A0}")))
        #expect(!custom.contains("fn"))
        #expect(OnboardingGate.extraModelsNote(binding: nil, enabled: [.engine(.geminiFlash)]).contains("Settings"))
        #expect(OnboardingGate.extraModelsNote(binding: .fnTab, enabled: []).contains("Settings"))
        let both = OnboardingGate.extraModelsNote(binding: .fnTab, enabled: [.cleanup, .engine(.geminiFlash)])
        #expect(both.contains("cleaned up") && both.contains("Gemini"))
        let cleanup = OnboardingGate.extraModelsNote(binding: .fnTab, enabled: [.cleanup])
        #expect(cleanup.contains("cleaned up") && !cleanup.contains("Gemini"))
    }
}

@MainActor
@Suite struct OnboardingExtraModelsTests {
    private func makeModel(_ configure: (inout OnboardingContext) -> Void = { _ in }) -> OnboardingModel {
        let env = AppEnvironment.preview()
        env.settings.onboardingCompleted = false
        env.settings.onboardingStep = OnboardingStep.model.rawValue
        var ctx = OnboardingContext(env: env)
        configure(&ctx)
        return OnboardingModel(context: ctx)
    }

    @Test func theModelStepPicksOnlyAMainModel() {
        let model = makeModel()
        model.select(.parakeetCloud)
        for engine in EngineID.switchCandidates {
            model.select(engine)
            #expect(model.selectedEngine == .parakeetCloud, "\(engine) is picked per dictation, not here")
        }
    }

    @Test func switchModelLessonShowsOnlyWhenAStepWouldAnswer() {
        #expect(makeModel().showsSwitchModelLesson, "the preview key is valid")
        #expect(!makeModel { ctx in ctx.account = .preview(status: .missing) }.showsSwitchModelLesson)
        #expect(makeModel { ctx in ctx.settings.switchEngines = [] }.showsSwitchModelLesson, "clean-up alone")
        #expect(!makeModel { ctx in
            ctx.settings.switchEngines = []
            ctx.settings.switchCleanup = false
        }.showsSwitchModelLesson)
    }
}
