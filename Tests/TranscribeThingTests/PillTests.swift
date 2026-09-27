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

    @Test func visiblePhaseChangesAreReportedInTheSameTurn() async throws {
        let model = makeModel()
        model.timing.successHold = 0.1
        var seen: [PillPhase] = []
        model.onVisiblePhaseChange = { seen.append(model.visiblePhase) }
        model.phase = .listening
        #expect(seen == [.listening], "before the caller's next statement")
        model.phase = .listening
        model.phase = .success
        model.phase = .rest
        #expect(seen == [.listening, .success], "held: the check mark is still showing")
        try await waitUntil { model.visiblePhase == .rest }
        #expect(seen == [.listening, .success, .rest])
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

    @Test func processingDotsStartWhereTheHandsFreeBarsWere() {
        let locked = PillVisual.locked(.elapsed), processing = PillVisual.processing(wide: true)
        let barsCenter = locked.size.width / 2 + locked.barsOffset
        #expect(barsCenter == 102 - 19.5)
        let width = processing.size.width
        func center(at time: Double, reduceMotion: Bool = false) -> CGFloat {
            ProcessingWaveView.dotsCenterX(width: width, time: time, startOffset: processing.barsOffset,
                                           reduceMotion: reduceMotion)
        }
        #expect(center(at: 0) == barsCenter)
        // Then they glide to the center, never more than 1.5 pt per 60 fps frame.
        var previous = center(at: 0)
        for frame in 1...60 {
            let x = center(at: Double(frame) / 60)
            #expect(x >= previous && x - previous < 1.5)
            previous = x
        }
        #expect(previous == width / 2)
        // Reduce Motion has no glide: the crossfade swaps the bars for centered dots.
        #expect(center(at: 0, reduceMotion: true) == width / 2 && center(at: 1, reduceMotion: true) == width / 2)
        // The dots also scale in around where the bars were, not around the pill's center.
        #expect(abs(processing.barsAnchor.x * width - barsCenter) < 1e-9)
        #expect(PillVisual.processing(wide: false).barsAnchor == .center)
        // Push-to-talk never offsets them.
        #expect(PillVisual.listening.barsOffset == 0 && PillVisual.processing(wide: false).barsOffset == 0)
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

    private struct Frame {
        var now: TimeInterval
        var bars: [WaveformEngine.Bar]
        var track: [WaveformEngine.Bar] { bars.filter(\.isTrack) }
        var flowing: [WaveformEngine.Bar] { bars.filter { !$0.isTrack } }
    }

    private static let size = CGSize(width: PillMetrics.barFieldWidth, height: PillMetrics.barMaxHeight)
    private static let step = PillMetrics.barWidth + PillMetrics.barGap
    /// Where the rightmost slot's dot (and a landing column) stands.
    private static let slot0 = size.width - PillMetrics.barWidth
    /// The track: a fixed dot per slot.
    private static let slots = (0..<PillMetrics.barCount).map {
        CGRect(x: slot0 - CGFloat($0) * step, y: (size.height - PillMetrics.barMinHeight) / 2,
               width: PillMetrics.barWidth, height: PillMetrics.barMinHeight)
    }
    /// Points a bar glides per second: one slot per column.
    private static let pace = step / WaveformEngine.columnInterval

    /// Feeds `seconds` of 10 ms windows, drawing a 60 fps frame after every 1.67 windows' worth of time.
    private func run(_ meter: LevelMeter, _ engine: WaveformEngine, clock: Clock, seconds: Double,
                     reduceMotion: Bool = false, db: (Double) -> Float) -> [Frame] {
        var frames: [Frame] = []
        var nextFrame = clock.now
        for step in 0..<Int((seconds * 100).rounded()) {
            clock.now += 0.01
            meter.ingest(rmsDBFS: db(Double(step) * 0.01), at: clock.now)
            while nextFrame <= clock.now {
                let now = nextFrame - meter.tuning.readBehind
                engine.advance(meter: meter, to: now)
                frames.append(Frame(now: now, bars: engine.bars(size: Self.size, now: now, reduceMotion: reduceMotion,
                                                                isStatic: false)))
                nextFrame += 1.0 / 60
            }
        }
        return frames
    }

    /// Speech with a short dip every 300 ms: a level that never dips for a second is noise to the gate.
    private static func speech(_ t: Double) -> Float { t.truncatingRemainder(dividingBy: 0.3) < 0.24 ? -20 : -40 }

    /// Room noise around -50 dBFS.
    private static func noise() -> (Double) -> Float {
        var seed: UInt64 = 9
        return { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return -50 + 8 * Float(Double(seed >> 11) / Double(1 << 53)) - 4
        }
    }

    /// A phrase, a pause, a second phrase and silence, after a second of room noise.
    private func conversation(reduceMotion: Bool = false) -> [Frame] {
        let clock = Clock()
        let meter = LevelMeter(clock: { clock.now })
        let engine = WaveformEngine()
        let noise = Self.noise()
        _ = run(meter, engine, clock: clock, seconds: 1, reduceMotion: reduceMotion, db: noise)
        return run(meter, engine, clock: clock, seconds: 5, reduceMotion: reduceMotion) { t in
            t < 1.2 ? Self.speech(t) : (t >= 1.8 && t < 2.4 ? Self.speech(t - 1.8) : noise(t))
        }
    }

    @Test func silenceIsPerfectlyStill() {
        let clock = Clock()
        let meter = LevelMeter(clock: { clock.now })
        let engine = WaveformEngine()
        let noise = Self.noise()
        _ = run(meter, engine, clock: clock, seconds: 1, db: noise)
        let frames = run(meter, engine, clock: clock, seconds: 3, db: noise)
        #expect(frames.count > 150)
        #expect(frames.allSatisfy { $0.bars == frames[0].bars })
        #expect(frames[0].bars.map(\.rect) == Self.slots)
        #expect(frames[0].bars.allSatisfy { $0.isTrack && $0.opacity > 0 })
    }

    @Test func theTrackNeverMoves() {
        for reduceMotion in [false, true] {
            let frames = conversation(reduceMotion: reduceMotion)
            #expect(frames.contains { $0.flowing.count >= 8 })
            #expect(frames.allSatisfy { $0.track.map(\.rect) == Self.slots })
        }
    }

    @Test func barsGlideAtOnePaceUntilTheyLeave() throws {
        let frames = conversation()
        for (previous, frame) in zip(frames, frames.dropFirst()) {
            let dx = Self.pace * CGFloat(frame.now - previous.now)
            // Every bar is one that stood exactly one frame's glide to the right, one just rising out of the
            // rightmost dot, or a faint one fading in as its column grows out of the track: nothing waits, catches
            // up or jumps.
            for bar in frame.flowing {
                let from = bar.rect.minX + dx
                #expect(from > Self.slot0 - dx || bar.opacity < 0.35
                            || previous.flowing.contains { abs($0.rect.minX - from) < 1e-6 },
                        "a bar at \(bar.rect.minX) (\(bar.rect.height) pt, \(bar.opacity)) came from nowhere")
            }
            // And every bar keeps going until it has left past the left edge.
            for bar in previous.flowing where bar.rect.minX - dx > -PillMetrics.barWidth {
                #expect(frame.flowing.contains { abs($0.rect.minX - (bar.rect.minX - dx)) < 1e-6 },
                        "the bar at \(bar.rect.minX) stopped or vanished")
            }
        }
        // The second phrase's last bars glide out after it ends, then the track is left as still as before.
        let lastBar = try #require(frames.lastIndex { !$0.flowing.isEmpty })
        let voiceEnd = frames[0].now + 2.4
        #expect(frames[lastBar].now > voiceEnd + Double(PillMetrics.barCount - 1) * WaveformEngine.columnInterval)
        let rest = frames[(lastBar + 1)...]
        #expect(rest.count > 30 && rest.allSatisfy { $0.bars == rest.first?.bars && $0.bars.map(\.rect) == Self.slots })
    }

    @Test func dotsUnderBarsGiveWayWithoutFlicker() {
        let frames = conversation()
        let full = (0.45 + 0.51) * 0.999
        for (previous, frame) in zip(frames, frames.dropFirst()) {
            for (dot, was) in zip(frame.track, previous.track) {
                // A dot fades as a bar passes over it, never in one frame ...
                #expect(abs(dot.opacity - was.opacity) < 0.35)
                // ... and one between two full bars stays hidden at every phase instead of showing in the gap.
                let left = frame.flowing.contains {
                    $0.opacity >= full && $0.rect.minX <= dot.rect.minX && dot.rect.minX - $0.rect.minX < Self.step
                }
                let right = frame.flowing.contains {
                    $0.opacity >= full && $0.rect.minX >= dot.rect.minX && $0.rect.minX - dot.rect.minX < Self.step
                }
                if left && right { #expect(dot.opacity < 1e-3) }
                // A dot a grown bar covers doesn't show through it, even as the bar fades out past the left edge
                // (the rightmost dot fades out as a bar rises out of it).
                let grown = PillMetrics.barMinHeight + 5
                if dot.rect.minX < Self.slot0,
                   frame.flowing.contains(where: { $0.rect.height >= grown && abs($0.rect.minX - dot.rect.minX) <= 1.5 }) {
                    #expect(dot.opacity < 1e-3, "a dot at \(dot.rect.minX) inside a bar")
                }
            }
            // A column barely taller than a dot merges into the track rather than drifting between its dots.
            #expect(frame.flowing.allSatisfy { $0.rect.height > PillMetrics.barMinHeight + 0.5 || $0.opacity < 0.01 })
        }
    }

    @Test func aVoicedColumnRisesOutOfTheRightmostDot() throws {
        let clock = Clock()
        let meter = LevelMeter(clock: { clock.now })
        let engine = WaveformEngine()
        _ = run(meter, engine, clock: clock, seconds: 2) { t in t < 0.5 ? -50 : Self.speech(t) }
        let end = try #require(engine.newestEnd)
        #expect(engine.columns.allSatisfy { $0 > 0.5 })
        // Fully grown and standing on the rightmost slot, as Reduce Motion draws it.
        let settled = try #require(engine.bars(size: Self.size, now: end, reduceMotion: true, isStatic: false)
            .first { !$0.isTrack })
        #expect(settled.rect.minX == Self.slot0)
        func frame(at time: TimeInterval) -> Frame {
            engine.advance(meter: meter, to: time)
            return Frame(now: time, bars: engine.bars(size: Self.size, now: time, reduceMotion: false, isStatic: false))
        }
        /// The column that landed at `end`, where it has glided to by then.
        func column(_ frame: Frame) -> WaveformEngine.Bar? {
            frame.flowing.first { abs($0.rect.minX - (Self.slot0 - Self.pace * CGFloat(frame.now - end))) < 1e-6 }
        }
        // At its landing the column is still the rightmost dot ...
        let landing = frame(at: end)
        #expect(column(landing) == nil && landing.track[0].opacity > 0.4)
        // ... which then grows into a bar that brightens as it sets off at the row's pace, the dot giving way.
        let (a, b) = (frame(at: end + 0.03), frame(at: end + 0.06))
        let (barA, barB) = (try #require(column(a)), try #require(column(b)))
        #expect(barA.rect.height > PillMetrics.barMinHeight && barA.rect.height < barB.rect.height)
        #expect(barA.opacity > 0 && barA.opacity < barB.opacity)
        #expect(a.track[0].opacity < landing.track[0].opacity)
        let grown = try #require(column(frame(at: end + WaveformEngine.growDuration)))
        #expect(grown.rect.height == settled.rect.height && grown.opacity == settled.opacity)
    }

    /// 10 ms windows ending at `start + 0.01`, `start + 0.02`, ...
    private func ingest(_ meter: LevelMeter, from start: TimeInterval, seconds: Double, db: (Double) -> Float) {
        for step in 0..<Int((seconds * 100).rounded()) {
            meter.ingest(rmsDBFS: db(Double(step) * 0.01), at: start + Double(step + 1) * 0.01)
        }
    }

    @Test func anOnsetConfirmedByTheNextChunkStillDraws() throws {
        let clock = Clock()
        let meter = LevelMeter(clock: { clock.now })
        let engine = WaveformEngine()
        let onset = clock.now + 1
        ingest(meter, from: clock.now, seconds: 1) { _ in -50 }
        engine.advance(meter: meter, to: onset - 0.2)
        // The first 50 ms of a word arrive; the gate needs one more window, which is in the next chunk.
        ingest(meter, from: onset, seconds: 0.05) { _ in -22 }
        engine.advance(meter: meter, to: onset - 0.2 + 3 * WaveformEngine.columnInterval)
        let end = try #require(engine.newestEnd)
        #expect(engine.columns[0] == 0)
        ingest(meter, from: onset + 0.05, seconds: 0.03) { _ in -22 }
        engine.advance(meter: meter, to: end + 0.017)
        #expect(engine.columns[0] > 0.5)
        // Its bar rises where the column has glided to by then.
        let bars = engine.bars(size: Self.size, now: end + 0.034, reduceMotion: false, isStatic: false).filter { !$0.isTrack }
        #expect(bars.count == 1 && abs(bars[0].rect.minX - (Self.slot0 - Self.pace * 0.034)) < 1e-9)
        #expect(bars[0].rect.height > PillMetrics.barMinHeight && bars[0].opacity > 0)
    }

    @Test func aFillInBetweenLandingsNeverPops() throws {
        let clock = Clock()
        let meter = LevelMeter(clock: { clock.now })
        let engine = WaveformEngine()
        let onset = clock.now + 1
        ingest(meter, from: clock.now, seconds: 1) { _ in -50 }
        engine.advance(meter: meter, to: onset - 0.2)
        ingest(meter, from: onset, seconds: 0.05) { _ in -22 }
        engine.advance(meter: meter, to: onset - 0.2 + 3 * WaveformEngine.columnInterval)
        let end = try #require(engine.newestEnd)
        #expect(engine.columns.allSatisfy { $0 == 0 })
        // The window that confirms the onset arrives 50 ms after the column landed, well into its glide.
        ingest(meter, from: onset + 0.05, seconds: 0.03) { _ in -22 }
        var now = end + 0.05
        let before = engine.bars(size: Self.size, now: now, reduceMotion: false, isStatic: false)
        engine.advance(meter: meter, to: now)
        #expect(engine.columns[0] > 0.5)
        // At that instant nothing changes; from then on the bar grows and fades in a step at a time, in stride.
        var previous = engine.bars(size: Self.size, now: now, reduceMotion: false, isStatic: false)
        #expect(previous == before)
        /// The filled-in column, where it has glided to by `time`.
        func column(_ bars: [WaveformEngine.Bar], at time: TimeInterval) -> WaveformEngine.Bar? {
            bars.first { !$0.isTrack && abs($0.rect.minX - (Self.slot0 - Self.pace * CGFloat(time - end))) < 1e-6 }
        }
        var shown = false
        for _ in 0..<12 {
            let was = column(previous, at: now)
            now += 1.0 / 60
            engine.advance(meter: meter, to: now)
            let bars = engine.bars(size: Self.size, now: now, reduceMotion: false, isStatic: false)
            let bar = try #require(column(bars, at: now))
            #expect(bar.opacity - (was?.opacity ?? 0) < 0.4)
            #expect(bar.rect.height - (was?.rect.height ?? PillMetrics.barMinHeight) < 8)
            for (dot, wasDot) in zip(bars.prefix(PillMetrics.barCount), previous) {
                #expect(abs(dot.opacity - wasDot.opacity) < 0.35)
            }
            shown = shown || bar.opacity > 0.9
            previous = bars
        }
        #expect(shown)
    }

    /// A quiet voice (about -45 dBFS) makes many columns barely taller than a dot. Their bars stay faint, and
    /// the dots they glide over give way, so the pair never reads as a doubled dot drifting along the track.
    @Test func aQuietVoiceNeverDoublesTheDots() {
        let clock = Clock()
        let meter = LevelMeter(clock: { clock.now })
        let engine = WaveformEngine()
        var seed: UInt64 = 5
        func random() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Double(seed >> 11) / Double(1 << 53))
        }
        _ = run(meter, engine, clock: clock, seconds: 1) { _ in -62 + 4 * random() }
        let frames = run(meter, engine, clock: clock, seconds: 4) { t in
            t.truncatingRemainder(dividingBy: 0.3) < 0.24 ? -47 + 8 * random() : -60
        }
        #expect(frames.filter { !$0.flowing.isEmpty }.count > 100)
        for frame in frames {
            // A bar rising out of the rightmost dot starts on it; past that, a short bar never sits half on a dot.
            for bar in frame.flowing where bar.rect.minX < Self.slot0 - 1.5 && bar.rect.height < 5.5 && bar.opacity > 0.15 {
                for dot in frame.track where dot.opacity > 0.25 {
                    let overlap = min(bar.rect.maxX, dot.rect.maxX) - max(bar.rect.minX, dot.rect.minX)
                    #expect(overlap <= 0.5 || overlap >= 2.5,
                            "a \(bar.rect.height) pt bar at \(bar.rect.minX) half over a lit dot at \(dot.rect.minX)")
                }
            }
        }
    }

    /// The newest column lands with part of its audio, and the rest arrives 20 ms later, while its bar is still
    /// fading in: the bar keeps fading in rather than jumping to full brightness.
    @Test func aColumnFilledInWhileFadingInNeverJumps() throws {
        let clock = Clock()
        let meter = LevelMeter(clock: { clock.now })
        let engine = WaveformEngine()
        let start = clock.now
        ingest(meter, from: start, seconds: 1) { _ in -50 }
        ingest(meter, from: start + 1, seconds: 0.6) { _ in -24 }
        let audioEnd = start + 1.6
        var now = start + 1.2
        engine.advance(meter: meter, to: now)
        while (engine.newestEnd ?? 0) <= audioEnd {
            now += 1.0 / 60
            engine.advance(meter: meter, to: now)
        }
        let end = try #require(engine.newestEnd)
        #expect(engine.columns[0] > 0, "the column holds part of its audio")
        /// The newest column, where it has glided to by `time`.
        func column(_ bars: [WaveformEngine.Bar], at time: TimeInterval) -> WaveformEngine.Bar? {
            bars.first { !$0.isTrack && abs($0.rect.minX - (Self.slot0 - Self.pace * CGFloat(time - end))) < 1e-6 }
        }
        now = end + 0.02
        engine.advance(meter: meter, to: now)
        var previous = engine.bars(size: Self.size, now: now, reduceMotion: false, isStatic: false)
        let fading = try #require(column(previous, at: now))
        #expect(fading.opacity > 0 && fading.opacity < 0.6, "still fading in")
        // The rest of its audio arrives, louder.
        ingest(meter, from: audioEnd, seconds: 0.3) { _ in -16 }
        let partial = engine.columns[0]
        for _ in 0..<8 {
            let was = try #require(column(previous, at: now))
            now += 1.0 / 60
            engine.advance(meter: meter, to: now)
            let bars = engine.bars(size: Self.size, now: now, reduceMotion: false, isStatic: false)
            let bar = try #require(column(bars, at: now))
            #expect(abs(bar.opacity - was.opacity) < 0.4, "\(was.opacity) → \(bar.opacity)")
            for (dot, wasDot) in zip(bars.prefix(PillMetrics.barCount), previous) {
                #expect(abs(dot.opacity - wasDot.opacity) < 0.35)
            }
            previous = bars
        }
        #expect(engine.columns[0] > partial, "the rest of the audio filled it in")
    }

    @Test func aLateChunkFillsInInsteadOfLeavingDots() {
        let clock = Clock()
        let meter = LevelMeter(clock: { clock.now })
        let engine = WaveformEngine()
        let speech = clock.now + 1
        ingest(meter, from: clock.now, seconds: 1) { _ in -50 }
        ingest(meter, from: speech, seconds: 0.3) { _ in -22 }
        engine.advance(meter: meter, to: speech + 0.3 - meter.tuning.readBehind)
        // The tap thread stalls for 350 ms: the columns of that time land before their audio does.
        let stalled = speech + 0.3 + 0.35 - meter.tuning.readBehind
        engine.advance(meter: meter, to: stalled)
        #expect(engine.columns[0] == 0)
        ingest(meter, from: speech + 0.3, seconds: 0.35) { _ in -22 }
        engine.advance(meter: meter, to: stalled + 0.017)
        #expect(engine.columns.prefix(5).allSatisfy { $0 > 0.5 }, "\(engine.columns)")
    }

    @Test func reduceMotionStepsAWholeSlotPerColumn() {
        let frames = conversation(reduceMotion: true)
        let steps = zip(frames, frames.dropFirst()).filter { $0.flowing != $1.flowing }.count
        #expect(frames.contains { $0.flowing.count >= 8 })
        // No gliding and no growing: every bar stands on a slot, fully grown, and the row changes once a column.
        for frame in frames {
            #expect(frame.flowing.allSatisfy { bar in Self.slots.contains { $0.minX == bar.rect.minX } })
        }
        let columns = (frames[frames.count - 1].now - frames[0].now) / WaveformEngine.columnInterval
        #expect(steps > 20 && Double(steps) <= columns + 1)
    }

    @Test func staticRenderingIsDeterministic() {
        let a = WaveformEngine(), b = WaveformEngine()
        let meter = LevelMeter.preview(level: 0.7)
        a.advance(meter: meter, to: WaveformEngine.staticTime)
        b.advance(meter: meter, to: WaveformEngine.staticTime)
        let barsA = a.bars(size: Self.size, now: WaveformEngine.staticTime, reduceMotion: false, isStatic: true)
        #expect(barsA == b.bars(size: Self.size, now: WaveformEngine.staticTime, reduceMotion: false, isStatic: true))
        #expect(barsA.filter(\.isTrack).map(\.rect) == Self.slots)
        let flowing = barsA.filter { !$0.isTrack }
        #expect(flowing.filter { $0.rect.height > 10 }.count >= 5)
        // A pause before the phrase: dots show where no bar stands.
        #expect(barsA.contains { $0.isTrack && $0.opacity > 0.4 })
        #expect(flowing.allSatisfy { bar in Self.slots.contains { $0.minX == bar.rect.minX } })
    }
}
