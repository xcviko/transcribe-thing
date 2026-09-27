import Foundation
import Testing
@testable import TranscribeThing

// MARK: - Toast center

@MainActor
private final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
private func makeCenter() -> (ToastCenter, TestClock) {
    let clock = TestClock()
    return (ToastCenter(clock: { clock.now }, schedulesExpiry: false), clock)
}

private func notice(_ key: String, _ title: String = "Title", lifetime: NoticeLifetime = .seconds(5),
                    sound: SoundEffect? = nil, style: NoticeStyle = .info, actions: [NoticeAction] = [],
                    transcript: String? = nil) -> Notice {
    Notice(dedupeKey: key, style: style, symbol: "info.circle", title: title, transcript: transcript,
           actions: actions, lifetime: lifetime, sound: sound)
}

@Suite @MainActor struct ToastCenterTests {
    @Test func sameDedupeKeyReplacesInPlace() {
        let (center, _) = makeCenter()
        center.post(notice("a", "First"))
        center.post(notice("b", "Second"))
        let replacement = notice("a", "First, updated")
        center.post(replacement)
        #expect(center.notices.map(\.dedupeKey) == ["a", "b"])
        #expect(center.notices[0].title == "First, updated")
        #expect(center.notices[0].id == replacement.id)
        #expect(center.countdowns.count == 2)
    }

    @Test func keepsAtMostTwoDroppingTheOldest() {
        let (center, _) = makeCenter()
        center.post(notice("a"))
        center.post(notice("b"))
        center.post(notice("c"))
        #expect(center.notices.map(\.dedupeKey) == ["b", "c"])
        #expect(center.countdowns.count == 2)
    }

    @Test func stickyNoticesSurviveOverflow() {
        let (center, _) = makeCenter()
        center.post(notice("mic", lifetime: .sticky))
        center.post(notice("b"))
        center.post(notice("c"))
        #expect(center.notices.map(\.dedupeKey) == ["mic", "c"])
    }

    @Test func allStickyDropsTheOldest() {
        let (center, _) = makeCenter()
        center.post(notice("a", lifetime: .sticky))
        center.post(notice("b", lifetime: .sticky))
        center.post(notice("c", lifetime: .sticky))
        #expect(center.notices.map(\.dedupeKey) == ["b", "c"])
    }

    @Test func expiresAfterItsLifetime() {
        let (center, clock) = makeCenter()
        center.post(notice("a", lifetime: .seconds(5)))
        center.post(notice("sticky", lifetime: .sticky))
        clock.advance(4.9)
        center.expire(now: clock.now)
        #expect(center.notices.count == 2)
        clock.advance(0.2)
        center.expire(now: clock.now)
        #expect(center.notices.map(\.dedupeKey) == ["sticky"])
        clock.advance(3600)
        center.expire(now: clock.now)
        #expect(center.notices.map(\.dedupeKey) == ["sticky"])
    }

    @Test func dedupeRestartsTheCountdown() {
        let (center, clock) = makeCenter()
        center.post(notice("a", lifetime: .seconds(5)))
        clock.advance(4)
        center.post(notice("a", "Again", lifetime: .seconds(5)))
        clock.advance(4)
        center.expire(now: clock.now)
        #expect(center.notices.map(\.title) == ["Again"])
    }

    @Test func hoverPausesAndResumesWithGrace() throws {
        let (center, clock) = makeCenter()
        center.post(notice("a", lifetime: .seconds(5)))
        clock.advance(2)
        center.setPaused(true)
        clock.advance(30)
        center.expire(now: clock.now)
        #expect(center.notices.count == 1)
        let id = try #require(center.notices.first?.id)
        #expect(abs((center.fractionRemaining(for: id, at: clock.now) ?? 0) - 0.6) < 0.001)

        center.setPaused(false)
        clock.advance(2.9)
        center.expire(now: clock.now)
        #expect(center.notices.count == 1)
        clock.advance(0.2)
        center.expire(now: clock.now)
        #expect(center.notices.isEmpty)
    }

    @Test func resumingNearTheEndKeepsTheToastBriefly() {
        let (center, clock) = makeCenter()
        center.post(notice("a", lifetime: .seconds(5)))
        clock.advance(4.9)
        center.setPaused(true)
        center.setPaused(false)
        clock.advance(1)
        center.expire(now: clock.now)
        #expect(center.notices.count == 1)
        clock.advance(0.6)
        center.expire(now: clock.now)
        #expect(center.notices.isEmpty)
    }

    @Test func noticesPostedWhileHoveringWaitForTheHoverToEnd() {
        let (center, clock) = makeCenter()
        center.setPaused(true)
        center.post(notice("a", lifetime: .seconds(2)))
        clock.advance(10)
        center.expire(now: clock.now)
        #expect(center.notices.count == 1)
    }

    @Test func playsTheNoticeSound() {
        let (center, _) = makeCenter()
        var played: [SoundEffect] = []
        center.onSound = { played.append($0) }
        center.post(notice("a", sound: .error))
        center.post(notice("b"))
        center.post(notice("a", sound: .error))
        #expect(played == [.error, .error])
    }

    @Test func actionsReachTheHandlerAndDismiss() {
        let (center, _) = makeCenter()
        var received: [NoticeActionKind] = []
        center.onAction = { _, action in received.append(action.kind) }
        let undo = NoticeAction(title: "Undo", kind: .undoCancel, isPrimary: true)
        let posted = notice("cancel", actions: [undo])
        center.post(posted)
        center.perform(undo, on: posted)
        #expect(received == [.undoCancel])
        #expect(center.notices.isEmpty)
    }

    @Test func copyKeepsTheTranscriptCardAround() {
        let (center, clock) = makeCenter()
        var received: [NoticeActionKind] = []
        center.onAction = { _, action in received.append(action.kind) }
        let copy = NoticeAction(title: "Copy", kind: .copyText("hello"), isPrimary: true)
        let card = notice("paste", lifetime: .seconds(20), actions: [copy], transcript: "hello")
        center.post(card)
        clock.advance(19)
        center.perform(copy, on: card)
        #expect(received == [.copyText("hello")])
        clock.advance(3)
        center.expire(now: clock.now)
        #expect(center.notices.count == 1)
        clock.advance(1.1)
        center.expire(now: clock.now)
        #expect(center.notices.isEmpty)
    }

    @Test func dismissByIdAndKey() {
        let (center, _) = makeCenter()
        let a = notice("a")
        center.post(a)
        center.post(notice("b"))
        center.dismiss(a.id)
        #expect(center.notices.map(\.dedupeKey) == ["b"])
        center.dismiss(dedupeKey: "b")
        #expect(center.notices.isEmpty)
        #expect(center.countdowns.isEmpty)
    }

    @Test func realTimerExpiresNotices() async throws {
        let center = ToastCenter()
        center.post(notice("a", lifetime: .seconds(0.1)))
        #expect(center.notices.count == 1)
        try await waitUntil { center.notices.isEmpty }
    }
}

// MARK: - Visibility

@Suite struct PillVisibilityTests {
    private let now = Date(timeIntervalSinceReferenceDate: 5_000)

    @Test(arguments: [PillPhase.hidden, .rest])
    func idleShowsOnlyInAlwaysMode(_ phase: PillPhase) {
        #expect(PillVisibility.showsPill(phase: phase, mode: .always))
        #expect(!PillVisibility.showsPill(phase: phase, mode: .whileDictating))
        #expect(!PillVisibility.showsPill(phase: phase, mode: .never))
    }

    @Test(arguments: [PillPhase.listening, .locked, .processing, .success, .error])
    func activePhasesShowUnlessNever(_ phase: PillPhase) {
        #expect(PillVisibility.showsPill(phase: phase, mode: .always))
        #expect(PillVisibility.showsPill(phase: phase, mode: .whileDictating))
        #expect(!PillVisibility.showsPill(phase: phase, mode: .never))
    }

    @Test func onlyNeverDisallowsThePill() {
        #expect(PillVisibility.isPillAllowed(mode: .always))
        #expect(PillVisibility.isPillAllowed(mode: .whileDictating))
        #expect(!PillVisibility.isPillAllowed(mode: .never))
    }

    @Test func helloShowsTheIdlePillInWhileDictatingButNotInNever() {
        #expect(PillVisibility.showsPill(phase: .rest, mode: .whileDictating, isHelloActive: true))
        #expect(!PillVisibility.showsPill(phase: .rest, mode: .never, isHelloActive: true))
    }

    @Test func panelIsNeededForThePillOrAnyToast() {
        #expect(PillVisibility.needsPanel(showsPill: true, toastCount: 0))
        #expect(PillVisibility.needsPanel(showsPill: false, toastCount: 1))
        #expect(!PillVisibility.needsPanel(showsPill: false, toastCount: 0))
    }
}

// MARK: - Pill model

@Suite @MainActor struct PillModelTests {
    private func makeModel() -> PillModel {
        let model = PillModel(settings: .inMemory(), levelMeter: .preview(level: 0.5))
        model.timing = PillTiming(successHold: 0.05, errorHold: 0.08, hoverIn: 0.01, hoverOut: 0.01,
                                  tooltipDelay: 0.02, controlTooltipDelay: 0.02, slowProcessing: 5)
        return model
    }

    @Test func startsIdleWithSettingsDerivedHints() {
        let settings = AppSettings.inMemory()
        settings.maxRecordingMinutes = 10
        let model = PillModel(settings: settings, levelMeter: .preview(level: 0))
        #expect(model.phase == .rest)
        #expect(model.visiblePhase == .rest)
        #expect(model.limitSeconds == 600)
        #expect(model.shortcutHint == "fn")
    }

    @Test func successSettlesBackToRest() async throws {
        let model = makeModel()
        model.phase = .processing
        model.phase = .success
        #expect(model.visiblePhase == .success)
        try await waitUntil { model.phase == .rest && model.visiblePhase == .rest }
    }

    @Test func earlyRestWaitsForTheCheckMark() async throws {
        let model = makeModel()
        model.timing.successHold = 0.15
        model.phase = .success
        model.phase = .rest
        #expect(model.visiblePhase == .success)
        try await waitUntil { model.visiblePhase == .rest }
    }

    @Test func theNextQueuedJobWaitsForTheCheckMark() async throws {
        let model = makeModel()
        model.timing.successHold = 0.15
        model.phase = .processing
        model.phase = .success
        // Job 2 is still transcribing: the controller asks for processing in the same turn.
        model.phase = .processing
        #expect(model.visiblePhase == .success)
        try await waitUntil { model.visiblePhase == .processing }
    }

    @Test func aNewRecordingInterruptsTheFlourish() {
        let model = makeModel()
        model.phase = .error
        model.phase = .listening
        #expect(model.visiblePhase == .listening)
    }

    @Test func errorShakesAndSettles() async throws {
        let model = makeModel()
        model.phase = .error
        #expect(model.shakeCount == 1)
        try await waitUntil { model.visiblePhase == .rest }
    }

    @Test func shakingAnIdlePillFlashesTheError() {
        let model = makeModel()
        model.shakeTrigger += 1
        #expect(model.visiblePhase == .error)
        #expect(model.shakeCount == 1)
    }

    @Test func shakingWhileRecordingOnlyShakes() {
        let model = makeModel()
        model.phase = .locked
        model.shakeTrigger += 1
        #expect(model.visiblePhase == .locked)
        #expect(model.shakeCount == 1)
    }

    @Test func processingRemembersHandsFreeWidth() {
        let model = makeModel()
        model.phase = .locked
        model.phase = .processing
        #expect(model.processingOrigin == .locked)
        model.phase = .rest
        model.phase = .listening
        model.phase = .processing
        #expect(model.processingOrigin == .listening)
    }

    @Test func recordingStampsItsStartAndClearsIt() {
        let model = makeModel()
        model.phase = .listening
        let start = model.recordingStartedAt
        #expect(start != nil)
        model.phase = .locked
        #expect(model.recordingStartedAt == start)
        model.phase = .processing
        #expect(model.recordingStartedAt == nil)
    }

    @Test func keepsTheControllersStartStamp() {
        let model = makeModel()
        let stamp = Date().addingTimeInterval(-0.12)
        model.recordingStartedAt = stamp
        model.phase = .listening
        #expect(model.recordingStartedAt == stamp)
    }

    @Test func finalMinuteFollowsTheLimit() {
        let model = makeModel()
        model.limitSeconds = 300
        model.phase = .locked
        #expect(!model.isInFinalMinute)
        model.recordingStartedAt = Date().addingTimeInterval(-250)
        #expect(model.isInFinalMinute)
        model.phase = .processing
        #expect(!model.isInFinalMinute)
    }

    @Test func hoverAndTooltipAfterTheirDelays() async throws {
        let model = makeModel()
        model.setPointerInside(true)
        #expect(!model.isHovering)
        // Polled rather than slept: the whole suite runs in parallel and can hold the main actor for a while.
        try await waitUntil { model.isHovering && model.showsTooltip }
        model.setPointerInside(false)
        #expect(!model.showsTooltip)
        try await waitUntil { !model.isHovering }
    }

    @Test func slowProcessingIsFlaggedAndClearedWhenDone() async throws {
        let model = makeModel()
        model.timing.slowProcessing = 0.05
        model.phase = .processing
        #expect(!model.isProcessingSlow)
        try await waitUntil { model.isProcessingSlow }
        model.phase = .success
        #expect(!model.isProcessingSlow)
    }

    @Test func previewsHoldTheirPhase() async throws {
        let model = PillModel.preview(phase: .success)
        #expect(model.visiblePhase == .success)
        try await Task.sleep(for: .seconds(0.9))
        #expect(model.visiblePhase == .success)
    }

    @Test func previewInTheLastMinuteShowsTheCountdown() {
        let model = PillModel.preview(phase: .locked, recordingFor: 1190, limitSeconds: 1200)
        #expect(model.isInFinalMinute)
        #expect(!PillModel.preview(phase: .locked, recordingFor: 30).isInFinalMinute)
    }

    @Test func visualGeometryMatchesTheSpec() {
        #expect(PillVisual.rest.size == CGSize(width: 40, height: 10))
        #expect(PillVisual.peek.size == CGSize(width: 76, height: 24))
        #expect(PillVisual.listening.size == CGSize(width: 104, height: 32))
        #expect(PillVisual.locked(.elapsed).size == CGSize(width: 204, height: 36))
        #expect(PillVisual.locked(.remaining).size == CGSize(width: 204, height: 36))
        #expect(PillVisual.processing(wide: true).size == CGSize(width: 204, height: 32))
        #expect(PillVisual.processing(wide: false).size == CGSize(width: 104, height: 32))
        #expect(PillVisual.success.size == CGSize(width: 32, height: 32))
        #expect(PillVisual.error.size == CGSize(width: 104, height: 32))
        #expect(PillMetrics.barFieldWidth == 69)
    }

    @Test func panelViewResolvesPresentation() {
        let model = PillModel.preview(phase: .rest)
        model.isPresented = false
        #expect(PillView(model: model, context: .panel(nil)).visual == .hidden)
        model.isPresented = true
        #expect(PillView(model: model, context: .panel(nil)).visual == .rest)
        #expect(PillView(model: PillModel.preview(phase: .hidden)).visual == .hidden)
        #expect(PillView(model: PillModel.preview(phase: .hidden), context: .panel(nil)).visual == .rest)
    }

    @Test func handsFreeAlwaysShowsTheTimer() {
        for context in [PillView.Context.standalone, .panel(nil)] {
            let model = PillModel.preview(phase: .locked, recordingFor: 42)
            #expect(PillView(model: model, context: context).visual == .locked(.elapsed))
            model.isHovering = true
            #expect(PillView(model: model, context: context).visual == .locked(.elapsed))
        }
        #expect(PillView(model: .preview(phase: .locked, recordingFor: 1190, limitSeconds: 1200)).visual
                == .locked(.remaining))
        #expect(PillVisual.listening.timer == nil)
    }

    @Test func hoverNeverResizesHandsFree() {
        let model = PillModel.preview(phase: .locked, recordingFor: 42)
        let resting = PillView(model: model).visual.size
        model.isHovering = true
        #expect(PillView(model: model).visual.size == resting)
        #expect(resting == PillMetrics.lockedSize)
    }

    @Test func processingAfterHandsFreeKeepsItsWidth() {
        let model = PillModel.preview(phase: .locked)
        let locked = PillView(model: model).visual.size
        model.phase = .processing
        let processing = PillView(model: model).visual
        #expect(processing == .processing(wide: true))
        #expect(processing.size.width == locked.width)
        let pushToTalk = PillModel.preview(phase: .listening)
        pushToTalk.phase = .processing
        #expect(PillView(model: pushToTalk).visual.size.width == PillMetrics.listeningSize.width)
    }

    @Test func helloBloomsToListeningSize() {
        let model = PillModel.preview(phase: .rest, isHovering: true)
        model.beginHello(duration: 60)
        #expect(PillView(model: model, context: .panel(nil)).visual == .hello)
        #expect(PillVisual.hello.size == PillMetrics.listeningSize)
        #expect(!PillVisual.hello.isQuiet)
        // A real dictation takes over from the hello.
        model.phase = .listening
        #expect(PillView(model: model, context: .panel(nil)).visual == .listening)
    }
}

// MARK: - Waveform

@Suite struct WaveformEngineTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 500
        var now: TimeInterval {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private static let size = CGSize(width: PillMetrics.barFieldWidth, height: PillMetrics.barMaxHeight)

    /// Feeds `seconds` of 10 ms windows, drawing a 60 fps frame after every 1.67 windows' worth of time.
    private func run(_ meter: LevelMeter, _ engine: WaveformEngine, clock: Clock, seconds: Double,
                     db: (Double) -> Float) -> [[WaveformEngine.Bar]] {
        var frames: [[WaveformEngine.Bar]] = []
        var nextFrame = clock.now
        for step in 0..<Int((seconds * 100).rounded()) {
            clock.now += 0.01
            meter.ingest(rmsDBFS: db(Double(step) * 0.01), at: clock.now)
            while nextFrame <= clock.now {
                let now = nextFrame - meter.tuning.readBehind
                engine.advance(meter: meter, to: now)
                frames.append(engine.bars(size: Self.size, now: now, reduceMotion: false, isStatic: false))
                nextFrame += 1.0 / 60
            }
        }
        return frames
    }

    @Test func silenceIsPerfectlyStill() {
        let clock = Clock()
        let meter = LevelMeter(clock: { clock.now })
        let engine = WaveformEngine()
        var seed: UInt64 = 9
        let noise: (Double) -> Float = { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return -50 + 8 * Float(Double(seed >> 11) / Double(1 << 53)) - 4
        }
        _ = run(meter, engine, clock: clock, seconds: 1, db: noise)
        let frames = run(meter, engine, clock: clock, seconds: 3, db: noise)
        #expect(frames.count > 150)
        #expect(frames.allSatisfy { $0 == frames[0] })
        #expect(frames[0].count == PillMetrics.barCount)
        #expect(frames[0].allSatisfy { $0.rect.height == PillMetrics.barMinHeight })
    }

    @Test func speechScrollsLeftAndGrowsIn() {
        let clock = Clock()
        let meter = LevelMeter(clock: { clock.now })
        let engine = WaveformEngine()
        _ = run(meter, engine, clock: clock, seconds: 1) { _ in -50 }
        let frames = run(meter, engine, clock: clock, seconds: 1.5) { _ in -22 }
        let last = frames[frames.count - 1]
        #expect(last.filter { $0.rect.height > 12 }.count >= 8)
        // Between landings the newest bar drifts left a fraction of a step per frame instead of jumping.
        let step = PillMetrics.barWidth + PillMetrics.barGap
        let shifts = zip(frames.dropFirst(), frames).compactMap { next, previous -> CGFloat? in
            guard let a = next.first?.rect.minX, let b = previous.first?.rect.minX, a < b else { return nil }
            return b - a
        }
        #expect(shifts.count > 40 && shifts.allSatisfy { $0 < step * 0.25 })
        #expect(last.allSatisfy { $0.rect.minX > -PillMetrics.barWidth && $0.rect.maxX <= Self.size.width })
    }

    @Test func newestColumnGrowsFromADot() throws {
        let clock = Clock()
        let meter = LevelMeter(clock: { clock.now })
        let engine = WaveformEngine()
        // Speech with a short dip every 300 ms: a level that never dips for a second is noise to the gate.
        _ = run(meter, engine, clock: clock, seconds: 2) { t in
            t < 0.5 ? -50 : (t.truncatingRemainder(dividingBy: 0.3) < 0.24 ? -20 : -40)
        }
        let end = try #require(engine.newestEnd)
        #expect(engine.columns.allSatisfy { $0 > 0.5 })
        func newest(at time: TimeInterval, reduceMotion: Bool = false) -> CGFloat {
            engine.bars(size: Self.size, now: time, reduceMotion: reduceMotion, isStatic: false)[0].rect.height
        }
        #expect(newest(at: end) == PillMetrics.barMinHeight)
        #expect(newest(at: end + 0.03) > PillMetrics.barMinHeight)
        #expect(newest(at: end + 0.03) < newest(at: end + 0.06))
        #expect(newest(at: end + WaveformEngine.growDuration) == newest(at: end, reduceMotion: true))
    }

    @Test func staticRenderingIsDeterministic() {
        let a = WaveformEngine(), b = WaveformEngine()
        let meter = LevelMeter.preview(level: 0.7)
        a.advance(meter: meter, to: WaveformEngine.staticTime)
        b.advance(meter: meter, to: WaveformEngine.staticTime)
        let barsA = a.bars(size: Self.size, now: WaveformEngine.staticTime, reduceMotion: false, isStatic: true)
        #expect(barsA == b.bars(size: Self.size, now: WaveformEngine.staticTime, reduceMotion: false, isStatic: true))
        #expect(barsA.count == PillMetrics.barCount)
        #expect(barsA.contains { $0.rect.height == PillMetrics.barMinHeight })   // a pause before the phrase
        #expect(barsA.filter { $0.rect.height > 10 }.count >= 5)
    }
}
