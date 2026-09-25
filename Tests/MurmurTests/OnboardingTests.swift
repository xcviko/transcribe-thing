import Foundation
import Testing
@testable import MurmurApp

// MARK: - Pure gating

@Suite struct OnboardingGateTests {
    private func inputs(mic: PermissionState = .granted, ax: PermissionState = .granted,
                        engine: EngineID = .parakeet, local: LocalModelState = .ready,
                        key: KeyStatus = .missing, stored: Bool = false) -> OnboardingGate.Inputs {
        OnboardingGate.Inputs(microphone: mic, accessibility: ax, engine: engine, localState: local,
                              keyStatus: key, hasStoredKey: stored)
    }

    @Test(arguments: [(-3, OnboardingStep.welcome), (0, .welcome), (2, .model), (5, .done), (99, .done)])
    func resumeClampsTheStoredStep(_ stored: Int, _ expected: OnboardingStep) {
        #expect(OnboardingStep.resuming(from: stored) == expected)
    }

    @Test func freeStepsNeverBlock() {
        let blocked = inputs(mic: .denied, ax: .denied, local: .notInstalled)
        for step in [OnboardingStep.welcome, .shortcuts, .tryIt, .done] {
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
        #expect(OnboardingGate.primaryTitle(.model, downloading, practiceStarted: false) == "Continue (download keeps going)")
        #expect(OnboardingGate.primaryTitle(.model, inputs(), practiceStarted: false) == "Continue")
        #expect(OnboardingGate.primaryTitle(.tryIt, inputs(), practiceStarted: false) == "Skip practice")
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
        #expect(OnboardingGate.requiredDiskBytes(for: .geminiPro) == nil)
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
        #expect(eval(engine: .whisper, local: .installed) == .warmingUp(.whisper))
        #expect(eval(local: .downloading(DownloadProgress(fraction: 0.62))) == .downloading(.parakeet, 0.62))
        #expect(eval(local: .failed("x")) == .notDownloaded(.parakeet))
        #expect(eval(engine: .geminiFlash, key: .missing) == .needsKey(.geminiFlash))
        #expect(eval(engine: .geminiPro, key: .valid(KeyInfo()), stored: true) == .ready)
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
        let model = makeModel(step: 3)
        #expect(model.step == .shortcuts)
        model.goNext()
        #expect(model.step == .tryIt)
        #expect(model.ctx.settings.onboardingStep == OnboardingStep.tryIt.rawValue)
        #expect(model.movingForward)
        model.goBack()
        model.goBack()
        #expect(model.step == .model)
        #expect(!model.movingForward)
        #expect(model.ctx.settings.onboardingStep == 2)
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
            ctx.models = .preview(states: [.parakeet: .notInstalled, .whisper: .notInstalled])
            ctx.account = .preview(status: .missing)
        }
        #expect(!model.canContinue)
        model.select(.geminiFlash)
        #expect(model.ctx.settings.selectedEngine == .geminiFlash)
        #expect(model.showsKeyField)
        #expect(!model.canContinue)
    }

    @Test func validKeyUnlocksCloudEngines() {
        let model = makeModel(step: 2) { ctx in
            ctx.models = .preview(states: [.parakeet: .notInstalled])
            ctx.account = .preview(status: .valid(KeyInfo(limitRemaining: 4.2)))
        }
        model.select(.geminiPro)
        #expect(model.canContinue)
        #expect(!model.showsKeyField)
        model.replaceKey()
        #expect(model.showsKeyField)
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

    @Test func holdingFnTicksTheFirstChip() {
        let model = makeModel(step: 3)
        let t0 = Date()
        model.handleRawKey(RawKeyEvent(key: .fn, isDown: true), now: t0)
        #expect(model.isHoldingPushToTalk)
        #expect(model.shortcutsPillPhase == .listening)
        model.handleRawKey(RawKeyEvent(key: .fn, isDown: false), now: t0.addingTimeInterval(0.8))
        #expect(model.heldPushToTalk)
        #expect(!model.triedHandsFree)
        #expect(model.shortcutsPillPhase == .rest)
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
        #expect(model.shortcutsPillPhase == .locked)
        model.handleRawKey(RawKeyEvent(key: .fn, isDown: true), now: t0.addingTimeInterval(3))
        model.handleRawKey(RawKeyEvent(key: .fn, isDown: false), now: t0.addingTimeInterval(3.1))
        #expect(!model.handsFreeLatched)
    }

    @Test func doublePressLatchesHandsFree() {
        let model = makeModel(step: 3)
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
        let model = makeModel(step: 4)
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

    @Test func typedTextDoesNotCountAsDictation() {
        let model = makeModel(step: 4)
        model.updateDraft("h")
        model.updateDraft("hi")
        model.submitDraft()
        #expect(model.completedLessons.isEmpty)
        #expect(model.practiceHint == .typedInstead)
        #expect(model.messages.last?.sender == .me)
    }

    @Test func escWhileRecordingCompletesTheCancelLesson() {
        let model = makeModel(step: 4)
        model.pillPhaseChanged(from: .hidden, to: .listening)
        model.handleRawKey(RawKeyEvent(key: .escape, isDown: true))
        #expect(model.completedLessons.contains(.cancel))
        #expect(model.messages.last?.sender == .note)
    }

    @Test func escWhileIdleDoesNothing() {
        let model = makeModel(step: 4)
        model.handleRawKey(RawKeyEvent(key: .escape, isDown: true))
        #expect(model.completedLessons.isEmpty)
    }

    @Test func noSpeechShowsTheMicHint() {
        let model = makeModel(step: 4)
        model.pillPhaseChanged(from: .processing, to: .error)
        #expect(model.practiceHint == .noSpeech)
        model.pillPhaseChanged(from: .error, to: .listening)
        #expect(model.practiceHint == nil)
    }

    @Test func finishCompletesOnboardingAndAppliesPreferences() {
        let model = makeModel(step: 5)
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
