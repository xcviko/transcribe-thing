import Foundation
import SwiftUI
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

    @Test func expiresAfterHalfItsNominalLifetime() {
        #expect(ToastCountdown.speed == 2)
        let (center, clock) = makeCenter()
        center.post(notice("a", lifetime: .seconds(5)))
        center.post(notice("sticky", lifetime: .sticky))
        clock.advance(2.4)
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
        clock.advance(2)
        center.post(notice("a", "Again", lifetime: .seconds(5)))
        clock.advance(2)
        center.expire(now: clock.now)
        #expect(center.notices.map(\.title) == ["Again"])
    }

    @Test func hoverPausesAndResumesWithGrace() throws {
        let (center, clock) = makeCenter()
        center.post(notice("a", lifetime: .seconds(5)))
        clock.advance(1)
        center.setPaused(true)
        clock.advance(30)
        center.expire(now: clock.now)
        #expect(center.notices.count == 1)
        let id = try #require(center.notices.first?.id)
        #expect(abs((center.fractionRemaining(for: id, at: clock.now) ?? 0) - 0.6) < 0.001)

        center.setPaused(false)
        clock.advance(1.4)
        center.expire(now: clock.now)
        #expect(center.notices.count == 1)
        clock.advance(0.2)
        center.expire(now: clock.now)
        #expect(center.notices.isEmpty)
    }

    @Test func resumingNearTheEndKeepsTheToastBriefly() {
        let (center, clock) = makeCenter()
        center.post(notice("a", lifetime: .seconds(5)))
        clock.advance(2.4)
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
        clock.advance(9)
        center.perform(copy, on: card)
        #expect(received == [.copyText("hello")])
        clock.advance(1.9)
        center.expire(now: clock.now)
        #expect(center.notices.count == 1)
        clock.advance(0.2)
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

    @Test(arguments: [PillPhase.listening, .locked, .processing, .error])
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
        model.timing = PillTiming(errorHold: 0.08, hoverIn: 0.01, hoverOut: 0.01,
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

    /// A delivered dictation has no flourish: the pasted text is the confirmation.
    @Test func finishedProcessingGoesStraightBackToRest() {
        let model = makeModel()
        model.phase = .processing
        model.phase = .rest
        #expect(model.visiblePhase == .rest)
    }

    @Test func earlyRestWaitsForTheErrorFlash() async throws {
        let model = makeModel()
        model.timing.errorHold = 0.15
        model.phase = .error
        model.phase = .rest
        #expect(model.visiblePhase == .error)
        try await waitUntil { model.visiblePhase == .rest }
    }

    @Test func theNextQueuedJobWaitsForTheErrorFlash() async throws {
        let model = makeModel()
        model.timing.errorHold = 0.15
        model.phase = .processing
        model.phase = .error
        // Job 2 is still transcribing: the controller asks for processing in the same turn.
        model.phase = .processing
        #expect(model.visiblePhase == .error)
        try await waitUntil { model.visiblePhase == .processing }
    }

    @Test func visiblePhaseChangesAreReportedInTheSameTurn() async throws {
        let model = makeModel()
        model.timing.errorHold = 0.1
        var seen: [PillPhase] = []
        model.onVisiblePhaseChange = { seen.append(model.visiblePhase) }
        model.phase = .listening
        #expect(seen == [.listening], "before the caller's next statement")
        model.phase = .listening
        model.phase = .error
        model.phase = .rest
        #expect(seen == [.listening, .error], "held: the error flash is still showing")
        try await waitUntil { model.visiblePhase == .rest }
        #expect(seen == [.listening, .error, .rest])
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
        model.phase = .rest
        #expect(!model.isProcessingSlow)
    }

    @Test func previewsHoldTheirPhase() async throws {
        let model = PillModel.preview(phase: .error)
        #expect(model.visiblePhase == .error)
        try await Task.sleep(for: .seconds(1.8))
        #expect(model.visiblePhase == .error)
    }

    @Test func processingDotsStartWhereTheHandsFreeBarsWere() {
        let locked = PillVisual.locked(.elapsed), processing = PillVisual.processing(afterHandsFree: true)
        // Both pills share their center on screen while the hands-free one narrows, so the dots start at the
        // bars' offset from that center.
        #expect(locked.barsOffset == -20.5)
        let width = processing.size.width
        let barsCenter = width / 2 + locked.barsOffset
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
        #expect(PillVisual.processing(afterHandsFree: false).barsAnchor == .center)
        // Push-to-talk never offsets them.
        #expect(PillVisual.listening.barsOffset == 0 && PillVisual.processing(afterHandsFree: false).barsOffset == 0)
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
        #expect(PillVisual.locked(.elapsed).size == CGSize(width: 198, height: 36))
        #expect(PillVisual.locked(.remaining).size == CGSize(width: 198, height: 36))
        #expect(PillVisual.processing(afterHandsFree: true).size == CGSize(width: 104, height: 32))
        #expect(PillVisual.processing(afterHandsFree: false).size == CGSize(width: 104, height: 32))
        #expect(PillVisual.error.size == CGSize(width: 104, height: 32))
        #expect(PillMetrics.barFieldWidth == 69)
    }

    /// X | bars | timer | Stop, left to right, with the same gap between each for a "9:59" timer, and a
    /// "29:59" one still clear of the bars and Stop.
    @Test func handsFreeSpacesItsControlsEvenly() {
        let width = PillMetrics.lockedSize.width
        let cancelRight = PillMetrics.buttonInset + PillMetrics.buttonSize
        let stopLeft = width - cancelRight
        let barsLeft = width / 2 + PillVisual.locked(.elapsed).barsOffset - PillMetrics.barFieldWidth / 2
        let barsRight = barsLeft + PillMetrics.barFieldWidth
        let timerCenter = stopLeft - PillMetrics.timerTrailing - PillMetrics.timerWidth / 2
        func gaps(timer: CGFloat) -> [CGFloat] {
            [barsLeft - cancelRight, timerCenter - timer / 2 - barsRight, stopLeft - (timerCenter + timer / 2)]
        }
        #expect(gaps(timer: PillMetrics.shortTimerWidth) == [15, 15, 15])
        #expect(gaps(timer: PillMetrics.timerWidth) == [15, 11.5, 11.5])
        #expect(PillMetrics.lockedGap == 15)
    }

    @MainActor @Test func timerWidthsFitTheirText() {
        func width(_ text: String) -> CGFloat {
            NSHostingView(rootView: Text(text).font(PillMetrics.timerFont).fixedSize()).fittingSize.width
        }
        for text in ["0:05", "0:14", "8:88", "9:59"] {
            #expect(abs(width(text) - PillMetrics.shortTimerWidth) <= 1, "\(text)")
        }
        for text in ["10:00", "28:48", "29:59"] {
            #expect(width(text) <= PillMetrics.timerWidth, "\(text)")
        }
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

    @Test func processingAfterHandsFreeShrinksToThePushToTalkSize() {
        let model = PillModel.preview(phase: .locked)
        model.phase = .processing
        let processing = PillView(model: model).visual
        #expect(processing == .processing(afterHandsFree: true))
        #expect(processing.size == PillMetrics.listeningSize)
        let pushToTalk = PillModel.preview(phase: .listening)
        pushToTalk.phase = .processing
        #expect(PillView(model: pushToTalk).visual.size.width == PillMetrics.listeningSize.width)
    }

    /// "Still transcribing…" replaces the dots inside the capsule, which widens just enough to fit it.
    @Test func slowProcessingWidensThePillToFitItsText() {
        let model = PillModel.preview(phase: .processing)
        #expect(PillView(model: model).visual == .processing(afterHandsFree: false))
        let slow = PillView(model: model.previewSlowProcessing()).visual
        #expect(slow == .processing(afterHandsFree: false, slow: true) && slow.isSlow)
        #expect(!PillVisual.processing(afterHandsFree: false).isSlow && !PillVisual.listening.isSlow)
        // Push-to-talk height, wider than the dots' pill and still narrower than hands-free.
        let size = slow.size
        #expect(size == PillMetrics.slowProcessingSize && size.height == PillMetrics.listeningSize.height)
        #expect(size.width > PillMetrics.listeningSize.width && size.width < PillMetrics.lockedSize.width)
        // The text and the usual padding on both sides, rounded up to whole points.
        let text = PillMetrics.textWidth(PillMetrics.slowText, size: PillMetrics.slowFontSize, weight: .medium,
                                         rounded: true)
        #expect(text > 80)
        #expect(size.width >= text + 2 * PillMetrics.slowPadding && size.width < text + 2 * PillMetrics.slowPadding + 1)
        // After hands-free it's the same pill; the dots' start offset doesn't change its size.
        let afterHandsFree = PillModel.preview(phase: .locked)
        afterHandsFree.phase = .processing
        #expect(PillView(model: afterHandsFree.previewSlowProcessing()).visual
                == .processing(afterHandsFree: true, slow: true))
        #expect(PillVisual.processing(afterHandsFree: true, slow: true).size == size)
        #expect(PillVisual.processing(afterHandsFree: true, slow: true).barsOffset == PillMetrics.lockedBarsOffset)
        // The panel's pill says it too (no floating caption above it any more).
        #expect(PillView(model: model, context: .panel(nil)).visual.isSlow)
    }

    @Test func slowProcessingOnlyAppliesWhileProcessing() {
        #expect(!PillView(model: PillModel.preview(phase: .listening).previewSlowProcessing()).visual.isSlow)
        #expect(!PillView(model: PillModel.preview(phase: .error).previewSlowProcessing()).visual.isSlow)
    }

    /// Going slow keeps the pill's content (same wave, same shimmer) and its chip: only the capsule and what it says
    /// change.
    @Test func goingSlowKeepsTheContentAndTheModel() {
        var stage = PillStage()
        stage.record(.processing(afterHandsFree: false), choice: .engine(.geminiFlash))
        let slow = PillVisual.processing(afterHandsFree: false, slow: true)
        let frame = stage.frame(for: slow, choice: .engine(.geminiFlash))
        #expect(frame == PillStage.Frame(capsule: slow, content: slow, exit: 0, morph: 0, collapsed: false,
                                         choice: .engine(.geminiFlash)))
        #expect(frame.content.content == PillVisual.processing(afterHandsFree: false).content)
        stage.record(slow, choice: .engine(.geminiFlash))
        // Leaving, the wide pill exits whole, chip and text included.
        let exiting = stage.frame(for: .hidden)
        #expect(exiting.capsule == slow && exiting.content == slow && exiting.choice == .engine(.geminiFlash))
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

// MARK: - Leaving

@Suite @MainActor struct PillExitTests {
    /// A stage that has shown `visuals`, in order, the way the view records them.
    private func stage(after visuals: [PillVisual]) -> PillStage {
        var stage = PillStage()
        for visual in visuals { stage.record(visual) }
        return stage
    }

    @Test(arguments: [
        [PillVisual.listening, .processing(afterHandsFree: false)],
        [PillVisual.locked(.elapsed), .processing(afterHandsFree: true)],
        [PillVisual.listening, .processing(afterHandsFree: false), .processing(afterHandsFree: false, slow: true)],
        [PillVisual.listening, .error],
        [PillVisual.rest, .listening],
    ])
    func theExitKeepsTheWholePillUntilItHasFaded(shown: [PillVisual]) {
        var stage = stage(after: shown)
        let last = shown.last!
        // The first frame of the exit, before the view records `.hidden`, and every frame after it.
        let exiting = stage.frame(for: .hidden)
        #expect(exiting == PillStage.Frame(capsule: last, content: last, exit: 1, morph: 0, collapsed: false))
        stage.record(.hidden)
        #expect(stage.frame(for: .hidden) == exiting)
        // A settle from before the exit started can't cut it short.
        stage.settle(stage.generation - 1, visual: .hidden)
        #expect(stage.frame(for: .hidden) == exiting)
        // Once it has played out, the pill parks collapsed at rest size, ready to bloom as before.
        stage.settle(stage.generation, visual: .hidden)
        #expect(stage.frame(for: .hidden)
                == PillStage.Frame(capsule: .hidden, content: .hidden, exit: 1, morph: 0, collapsed: true))
    }

    @Test func theExitShrinksAndFadesInOnePieceToNothing() {
        #expect(PillMotion.exitPose(at: 0, reduceMotion: false)
                == PillMotion.ExitPose(scale: 1, drop: 0, blur: 0, opacity: 1))
        var previous = PillMotion.exitPose(at: 0, reduceMotion: false)
        for step in 1...100 {
            let pose = PillMotion.exitPose(at: CGFloat(step) / 100, reduceMotion: false)
            #expect(pose.scale < previous.scale && pose.scale >= 0.8)
            #expect(pose.drop >= previous.drop && pose.drop <= 4)
            #expect(pose.blur <= 2)
            #expect(pose.opacity < previous.opacity)
            if step < 100 { #expect(pose.opacity > 0) }
            previous = pose
        }
        #expect(previous.opacity == 0)
        // A soft start: the pill is still nearly solid a fifth of the way in.
        #expect(PillMotion.exitPose(at: 0.2, reduceMotion: false).opacity > 0.85)
    }

    @Test func reduceMotionOnlyCrossfades() {
        for step in 0...10 {
            let pose = PillMotion.exitPose(at: CGFloat(step) / 10, reduceMotion: true)
            #expect(pose.scale == 1 && pose.drop == 0 && pose.blur == 0)
        }
        #expect(PillMotion.exitPose(at: 1, reduceMotion: true).opacity == 0)
        #expect(PillMotion.reducedExitDuration < PillMotion.exitDuration)
        let stage = stage(after: [.listening])
        #expect(stage.exitAnimation(to: .hidden, reduceMotion: true) == .linear(duration: PillMotion.reducedExitDuration))
        #expect(stage.exitAnimation(to: .hidden, reduceMotion: false) == .linear(duration: PillMotion.exitDuration))
    }

    @Test(arguments: [PillVisual.processing(afterHandsFree: false), .processing(afterHandsFree: true),
                      .processing(afterHandsFree: false, slow: true), .processing(afterHandsFree: true, slow: true),
                      .error, .listening, .locked(.elapsed), .peek, .hello])
    func morphingToRestShrinksTheContentWithTheCapsule(from visual: PillVisual) {
        var stage = stage(after: [visual])
        let morphing = stage.frame(for: .rest)
        #expect(morphing == PillStage.Frame(capsule: .rest, content: visual, exit: 0, morph: 1, collapsed: false))
        stage.record(.rest)
        #expect(stage.frame(for: .rest) == morphing)

        let rest = PillMetrics.restSize
        var previous = PillMotion.morphPose(at: 0, from: visual.size, to: rest)
        #expect(previous.size == visual.size && previous.scale == 1 && previous.opacity == 1)
        for step in 1...100 {
            let p = CGFloat(step) / 100
            let pose = PillMotion.morphPose(at: p, from: visual.size, to: rest)
            // Same point of the same spring as the capsule, whose size it reports.
            #expect(abs(pose.size.width - (visual.size.width + (rest.width - visual.size.width) * p)) < 1e-9)
            #expect(abs(pose.size.height - (visual.size.height + (rest.height - visual.size.height) * p)) < 1e-9)
            // The content's own pill, scaled, always fits the capsule: it never overflows nor floats in a big one.
            #expect(visual.size.width * pose.scale <= pose.size.width + 1e-9)
            #expect(visual.size.height * pose.scale <= pose.size.height + 1e-9)
            #expect(abs(visual.size.width * pose.scale - pose.size.width) < 1e-9
                    || abs(visual.size.height * pose.scale - pose.size.height) < 1e-9)
            #expect(pose.scale < previous.scale && pose.opacity < previous.opacity)
            previous = pose
        }
        #expect(previous.size == rest && previous.opacity == 0)

        // The shrunk content is dropped once the spring has settled.
        stage.settle(stage.generation, visual: .rest)
        #expect(stage.frame(for: .rest) == PillStage.Frame(capsule: .rest, content: .rest, exit: 0, morph: 0,
                                                           collapsed: false))
    }

    @Test func newContentReplacesTheShrinkingOne() {
        var stage = stage(after: [.processing(afterHandsFree: false), .rest])
        #expect(stage.frame(for: .peek).content == .peek)
        stage.record(.peek)
        // Hovering out again shrinks the peek dots, not the old processing wave.
        #expect(stage.frame(for: .rest).content == .peek)
    }

    @Test func showingAgainDuringTheExitCancelsIt() {
        var stage = stage(after: [.listening, .processing(afterHandsFree: false)])
        stage.record(.hidden)
        let exitGeneration = stage.generation
        // A new dictation mid-exit: the pill is the new one at once, and fades back in at the entry's pace.
        let back = stage.frame(for: .listening)
        #expect(back == PillStage.Frame(capsule: .listening, content: .listening, exit: 0, morph: 0, collapsed: false))
        #expect(stage.exitAnimation(to: .listening, reduceMotion: false) == .easeOut(duration: 0.12))
        stage.record(.listening)
        // The exit's settle arrives late: it must neither park nor drop anything.
        stage.settle(exitGeneration, visual: .hidden)
        stage.settle(stage.generation, visual: .listening)
        #expect(stage.frame(for: .listening) == back)
        // Hiding again starts a fresh exit of the current pill; the stale settle still can't park it.
        #expect(stage.frame(for: .hidden).capsule == .listening)
        stage.record(.hidden)
        stage.settle(exitGeneration, visual: .hidden)
        #expect(!stage.frame(for: .hidden).collapsed)
    }

    @Test func aParkedPillBloomsAsBefore() {
        let stage = PillStage()
        // Hidden from the start (While dictating, Never): parked, nothing to exit.
        #expect(stage.frame(for: .hidden).collapsed)
        // Appearing, the exit has nothing to undo: no animation, so only the tuned bloom runs.
        #expect(stage.exitAnimation(to: .listening, reduceMotion: false) == nil)
        #expect(stage.frame(for: .listening)
                == PillStage.Frame(capsule: .listening, content: .listening, exit: 0, morph: 0, collapsed: false))
    }

    @Test func thePanelStaysUpUntilThePillHasLeft() {
        #expect(PillController.orderOutDelay >= PillMotion.exitDuration + 0.1)
        #expect(PillMotion.settleDelay >= PillMotion.exitDuration)
        // The pill parks before the panel goes, so the next appearance blooms from rest.
        #expect(PillMotion.settleDelay < PillController.orderOutDelay)
        // The rest morph's spring is all but done when the shrunk content is dropped.
        let spring = Spring(duration: PillMotion.morphDuration, bounce: 0)
        #expect(spring.value(target: 1.0, time: PillMotion.settleDelay) > 0.99)
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
        /// The newest column's landing, nil before audio.
        var newest: TimeInterval? = nil
        /// Columns standing taller than a dot.
        var voiced: [WaveformEngine.Bar] { bars.filter { $0.rect.height > PillMetrics.barMinHeight + 0.01 } }
    }

    private static let size = CGSize(width: PillMetrics.barFieldWidth, height: PillMetrics.barMaxHeight)
    private static let step = PillMetrics.barWidth + PillMetrics.barGap
    /// Where a landing column stands: the rightmost slot.
    private static let slot0 = size.width - PillMetrics.barWidth
    /// The slots' x, right to left.
    private static let slots = (0..<PillMetrics.barCount).map { slot0 - CGFloat($0) * step }
    /// Points every column glides per second: one slot per column.
    private static let pace = step / WaveformEngine.columnInterval

    private func frame(_ engine: WaveformEngine, _ meter: LevelMeter, at now: TimeInterval,
                       reduceMotion: Bool = false) -> Frame {
        let bars = engine.frame(size: Self.size, meter: meter, now: now, reduceMotion: reduceMotion, isStatic: false)
        return Frame(now: now, bars: bars, newest: engine.newestEnd)
    }

    /// Feeds `seconds` of 10 ms windows, drawing a 60 fps frame after every 1.67 windows' worth of time.
    private func run(_ meter: LevelMeter, _ engine: WaveformEngine, clock: Clock, seconds: Double,
                     reduceMotion: Bool = false, db: (Double) -> Float) -> [Frame] {
        var frames: [Frame] = []
        var nextFrame = clock.now
        for step in 0..<Int((seconds * 100).rounded()) {
            clock.now += 0.01
            meter.ingest(rmsDBFS: db(Double(step) * 0.01), at: clock.now)
            while nextFrame <= clock.now {
                frames.append(frame(engine, meter, at: nextFrame - meter.tuning.readBehind, reduceMotion: reduceMotion))
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

    /// From the first audio buffer: two seconds of room noise, a phrase, a pause, a second phrase and silence.
    private func conversation(reduceMotion: Bool = false) -> [Frame] {
        let clock = Clock()
        let meter = LevelMeter(clock: { clock.now })
        let engine = WaveformEngine()
        let noise = Self.noise()
        return run(meter, engine, clock: clock, seconds: 7, reduceMotion: reduceMotion) { t in
            t >= 2 && t < 3.2 ? Self.speech(t - 2) : (t >= 3.8 && t < 4.4 ? Self.speech(t - 3.8) : noise(t))
        }
    }

    /// 10 ms windows ending at `start + 0.01`, `start + 0.02`, ...
    private func ingest(_ meter: LevelMeter, from start: TimeInterval, seconds: Double, db: (Double) -> Float) {
        for step in 0..<Int((seconds * 100).rounded()) {
            meter.ingest(rmsDBFS: db(Double(step) * 0.01), at: start + Double(step + 1) * 0.01)
        }
    }

    @Test func startsEmptyAndDrawsNothingBeforeAudio() throws {
        let clock = Clock()
        let meter = LevelMeter(clock: { clock.now })
        let engine = WaveformEngine()
        // The pill is up before the microphone delivers: no dots, no track, no placeholder.
        for n in 0..<30 {
            #expect(frame(engine, meter, at: clock.now + Double(n) / 60).bars.isEmpty)
        }
        #expect(engine.newestEnd == nil)
        // The first buffer starts an empty field; the first column lands one column later, at the right edge.
        ingest(meter, from: clock.now, seconds: 0.1) { _ in -50 }
        let start = clock.now + 0.1
        #expect(frame(engine, meter, at: start).bars.isEmpty)
        #expect(frame(engine, meter, at: start + WaveformEngine.columnInterval - 0.001).bars.isEmpty)
        let landing = start + WaveformEngine.columnInterval
        let first = frame(engine, meter, at: landing + 0.02)
        let dot = try #require(first.bars.first)
        #expect(first.bars.count == 1 && engine.filled == 1)
        #expect(abs(dot.rect.minX - (Self.slot0 - Self.pace * 0.02)) < 1e-9)
        #expect(dot.rect.height == PillMetrics.barMinHeight)
        // It fades in rather than popping, to a dim dot.
        let later = try #require(frame(engine, meter, at: landing + 0.04).bars.first)
        #expect(dot.opacity > 0 && dot.opacity < later.opacity && later.opacity < 0.45)
        // (By then the next column has landed to its right.)
        let shown = try #require(frame(engine, meter, at: landing + WaveformEngine.appearDuration + 0.01).bars.last)
        #expect(abs(shown.opacity - 0.45) < 1e-9)
    }

    @Test func fillsFromTheRightThenTheOldestGlidesOutLeft() throws {
        let frames = conversation()
        let counts = frames.map(\.bars.count)
        // One more column per landing until the field is full, never a jump ...
        for (previous, count) in zip(counts, counts.dropFirst()) {
            #expect(count >= previous || previous >= PillMetrics.barCount - 1)
            #expect(count <= previous + 1)
        }
        let full = try #require(counts.firstIndex { $0 >= PillMetrics.barCount - 1 })
        let columns = (frames[full].now - frames[0].now) / WaveformEngine.columnInterval
        #expect(columns > Double(PillMetrics.barCount - 2) && columns < Double(PillMetrics.barCount + 1))
        // ... and while it fills, nothing stands left of the newest columns.
        for frame in frames[..<full] {
            #expect(frame.bars.allSatisfy { $0.rect.minX > Self.slot0 - CGFloat(frame.bars.count) * Self.step })
        }
        // Once full, the oldest column fades out as it glides past the left edge instead of being clipped.
        var exits = 0
        for frame in frames[(full + 30)...] {
            #expect(frame.bars.count >= PillMetrics.barCount - 1 && frame.bars.count <= PillMetrics.barCount)
            let oldest = try #require(frame.bars.last)
            #expect(oldest.rect.minX > -PillMetrics.barWidth)
            if oldest.rect.minX < 0 {
                exits += 1
                // Its fade runs out as the clip takes it: the less of it shows, the dimmer it is, down to 0.
                #expect(oldest.opacity < 0.4 * oldest.rect.maxX / PillMetrics.barWidth)
            }
        }
        #expect(exits > 100)
    }

    @Test func everythingGlidesAtOnePaceInSilenceAndSpeech() {
        for (previous, frame) in zip(conversation(), conversation().dropFirst()) {
            let dx = Self.pace * CGFloat(frame.now - previous.now)
            // Every column is one that stood exactly one frame's glide to the right, or one just landing at the
            // right edge: nothing waits, catches up or jumps, dots and bars alike.
            for bar in frame.bars {
                let from = bar.rect.minX + dx
                #expect(from > Self.slot0 - 1e-9 || previous.bars.contains { abs($0.rect.minX - from) < 1e-6 },
                        "a column at \(bar.rect.minX) came from nowhere")
            }
            // And every column keeps going until it has left past the left edge.
            for bar in previous.bars where bar.rect.minX - dx > -PillMetrics.barWidth {
                #expect(frame.bars.contains { abs($0.rect.minX - (bar.rect.minX - dx)) < 1e-6 },
                        "the column at \(bar.rect.minX) stopped or vanished")
            }
        }
    }

    @Test func silenceIsAMovingRowOfDots() {
        let frames = conversation()
        // The first two seconds: room noise only. Once the field is full, every frame is 12-13 dim dots that
        // moved since the last one.
        let silent = frames.filter { $0.now - frames[0].now > 1.3 && $0.now - frames[0].now < 1.9 }
        #expect(silent.count > 30)
        for (previous, frame) in zip(silent, silent.dropFirst()) {
            #expect(frame.bars.count >= PillMetrics.barCount - 1)
            #expect(frame.voiced.isEmpty && frame.bars.allSatisfy { $0.opacity <= 0.45 + 1e-9 })
            #expect(frame.bars.map(\.rect.minX) != previous.bars.map(\.rect.minX))
        }
        // After the last phrase its bars glide out and the dots carry on.
        let lastBar = frames.lastIndex { !$0.voiced.isEmpty } ?? 0
        #expect(frames[lastBar].now - frames[0].now > 4.4 + Double(PillMetrics.barCount - 2) * WaveformEngine.columnInterval)
        let rest = frames[(lastBar + 1)...]
        #expect(rest.count > 30 && rest.allSatisfy { $0.bars.count >= PillMetrics.barCount - 1 })
    }

    @Test func aVoicedColumnRisesOutOfItsDot() throws {
        let clock = Clock()
        let meter = LevelMeter(clock: { clock.now })
        let engine = WaveformEngine()
        _ = run(meter, engine, clock: clock, seconds: 2) { t in t < 0.5 ? -50 : Self.speech(t) }
        let end = try #require(engine.newestEnd)
        #expect(engine.columns.allSatisfy { $0 > 0.5 })
        // Fully grown and standing on the rightmost slot, as Reduce Motion draws it.
        let settled = try #require(engine.bars(size: Self.size, now: end, reduceMotion: true, isStatic: false).first)
        #expect(settled.rect.minX == Self.slot0 && settled.rect.height > 10)
        /// The column that landed at `end`, where it has glided to by then.
        func column(_ frame: Frame) -> WaveformEngine.Bar? {
            frame.bars.first { abs($0.rect.minX - (Self.slot0 - Self.pace * CGFloat(frame.now - end))) < 1e-6 }
        }
        // At its landing the column isn't drawn yet ...
        #expect(column(frame(engine, meter, at: end)) == nil)
        // ... then it grows out of a dot and brightens as it sets off at the row's pace.
        let (a, b) = (frame(engine, meter, at: end + 0.03), frame(engine, meter, at: end + 0.06))
        let (barA, barB) = (try #require(column(a)), try #require(column(b)))
        #expect(barA.rect.height > PillMetrics.barMinHeight && barA.rect.height < barB.rect.height)
        #expect(barA.opacity > 0 && barA.opacity < barB.opacity)
        let grown = try #require(column(frame(engine, meter, at: end + WaveformEngine.growDuration + 1e-6)))
        #expect(abs(grown.rect.height - settled.rect.height) < 1e-9 && abs(grown.opacity - settled.opacity) < 1e-9)
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
        let bars = frame(engine, meter, at: end + 0.034).voiced
        #expect(bars.count == 1 && abs(bars[0].rect.minX - (Self.slot0 - Self.pace * 0.034)) < 1e-9)
        #expect(bars[0].opacity > 0)
    }

    /// Every column in `frame` against where it stood in `previous`: no step in height or brightness.
    private func expectNoPops(_ previous: Frame, _ frame: Frame, height: CGFloat = 8, opacity: Double = 0.35) {
        let dx = Self.pace * CGFloat(frame.now - previous.now)
        for bar in frame.bars {
            let was = previous.bars.first { abs($0.rect.minX - (bar.rect.minX + dx)) < 1e-6 }
            #expect(bar.rect.height - (was?.rect.height ?? PillMetrics.barMinHeight) < height)
            #expect(abs(bar.opacity - (was?.opacity ?? 0)) < opacity, "\(was?.opacity ?? 0) → \(bar.opacity)")
        }
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
        var previous = frame(engine, meter, at: now)
        #expect(engine.columns[0] > 0.5)
        // At that instant nothing changes; from then on the dot grows into a bar and brightens a step at a time.
        #expect(previous.bars == before)
        var shown = false
        for _ in 0..<12 {
            now += 1.0 / 60
            let next = frame(engine, meter, at: now)
            expectNoPops(previous, next)
            shown = shown || next.voiced.contains { $0.opacity > 0.9 }
            previous = next
        }
        #expect(shown)
    }

    /// The newest column lands with part of its audio, and the rest arrives 20 ms later, while it is still
    /// fading in: it keeps fading in rather than jumping to full brightness.
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
        now = end + 0.02
        var previous = frame(engine, meter, at: now)
        let fading = try #require(previous.bars.first { abs($0.rect.minX - (Self.slot0 - Self.pace * 0.02)) < 1e-6 })
        #expect(fading.opacity > 0 && fading.opacity < 0.6, "still fading in")
        // The rest of its audio arrives, louder.
        ingest(meter, from: audioEnd, seconds: 0.3) { _ in -16 }
        let partial = engine.columns[0]
        for _ in 0..<8 {
            now += 1.0 / 60
            let next = frame(engine, meter, at: now)
            expectNoPops(previous, next)
            previous = next
        }
        #expect(engine.columns[0] > partial, "the rest of the audio filled it in")
    }

    @Test func aLateChunkFillsInInsteadOfLeavingDots() {
        let clock = Clock()
        let meter = LevelMeter(clock: { clock.now })
        let engine = WaveformEngine()
        let speech = clock.now + 1
        ingest(meter, from: clock.now, seconds: 1) { _ in -50 }
        engine.advance(meter: meter, to: speech - 0.3)
        ingest(meter, from: speech, seconds: 0.3) { _ in -22 }
        engine.advance(meter: meter, to: speech + 0.3 - meter.tuning.readBehind)
        // The tap thread stalls for 350 ms: the columns of that time land (as dots) before their audio does.
        let stalled = speech + 0.3 + 0.35 - meter.tuning.readBehind
        engine.advance(meter: meter, to: stalled)
        #expect(engine.columns[0] == 0)
        ingest(meter, from: speech + 0.3, seconds: 0.35) { _ in -22 }
        engine.advance(meter: meter, to: stalled + 0.017)
        #expect(engine.columns.prefix(4).allSatisfy { $0 > 0.5 }, "\(engine.columns)")
    }

    @Test func aNewRecordingOnTheSameMeterStartsEmpty() {
        let clock = Clock()
        let meter = LevelMeter(clock: { clock.now })
        let engine = WaveformEngine()
        let frames = run(meter, engine, clock: clock, seconds: 2) { _ in -50 }
        #expect(frames.last?.bars.count ?? 0 >= PillMetrics.barCount - 1)
        meter.reset()
        #expect(frame(engine, meter, at: clock.now).bars.isEmpty)
        clock.now += 5
        let next = run(meter, engine, clock: clock, seconds: 0.3) { _ in -50 }
        #expect(next[0].bars.isEmpty && (next.last?.bars.count ?? 0) <= 3)
    }

    @Test func reduceMotionStepsAWholeSlotPerColumn() {
        let frames = conversation(reduceMotion: true)
        #expect(frames[0].bars.isEmpty)
        #expect(frames.contains { $0.voiced.count >= 8 })
        // No gliding and no growing: every column stands on a slot, fully grown ...
        for frame in frames {
            #expect(frame.bars.allSatisfy { bar in Self.slots.contains(bar.rect.minX) })
        }
        var steps = 0
        for (previous, frame) in zip(frames, frames.dropFirst()) {
            guard let was = previous.newest, let newest = frame.newest else { continue }
            if newest == was {
                // ... nothing moves between landings ...
                #expect(frame.bars.map(\.rect.minX) == previous.bars.map(\.rect.minX))
            } else if previous.bars.count == PillMetrics.barCount {
                // ... and each landing moves the whole history one slot left (heights and all), bar a column
                // or two still filling in.
                #expect(abs(newest - was - WaveformEngine.columnInterval) < 1e-9)
                let kept = zip(previous.bars.dropLast(), frame.bars.dropFirst()).filter {
                    $0.rect.height == $1.rect.height && $0.rect.minX - Self.step == $1.rect.minX
                }
                #expect(kept.count >= PillMetrics.barCount - 3)
                steps += 1
            }
        }
        #expect(steps > 50)
    }

    @Test func staticRenderingIsDeterministic() {
        let a = WaveformEngine(), b = WaveformEngine()
        let meter = LevelMeter.preview(level: 0.7)
        let now = WaveformEngine.staticTime
        let barsA = a.frame(size: Self.size, meter: meter, now: now, reduceMotion: false, isStatic: true)
        #expect(barsA == b.frame(size: Self.size, meter: meter, now: now, reduceMotion: false, isStatic: true))
        #expect(barsA == a.frame(size: Self.size, meter: meter, now: now, reduceMotion: false, isStatic: true))
        // A full field on the slots: a pause (dots), then a phrase.
        #expect(barsA.map(\.rect.minX) == Self.slots)
        #expect(barsA.filter { $0.rect.height > 10 }.count >= 5)
        #expect(barsA.contains { $0.rect.height == PillMetrics.barMinHeight && $0.opacity > 0.4 })
        // Before audio (the "just started" snapshot) the field is empty.
        #expect(a.frame(size: Self.size, meter: LevelMeter(), now: now, reduceMotion: false, isStatic: true).isEmpty)
    }
}

// MARK: - Extra models

@Suite @MainActor struct PillModelChipTests {
    private func makeModel(hold: TimeInterval = 0.05) -> PillModel {
        let model = PillModel(settings: .inMemory(), levelMeter: .preview(level: 0.5))
        model.timing.chipHold = hold
        return model
    }

    /// A switch names the new model for a moment; then the tint alone says it.
    @Test func eachSwitchFlashesTheChipThenItGoes() async throws {
        let model = makeModel()
        #expect(model.chipModel == nil, "a clean pill on the main model")
        model.engineChipPulse += 1
        model.sessionModel = .engine(.geminiFlash)
        #expect(model.chipModel == .engine(.geminiFlash))
        model.engineChipPulse += 1
        model.sessionModel = .cleanup
        #expect(model.chipModel == .cleanup)
        try await waitUntil { !model.showsChip }
        #expect(model.chipModel == nil && model.sessionModel == .cleanup, "the dictation stays on clean-up")
    }

    @Test func switchingBackNamesTheMainModelThenFades() async throws {
        let model = makeModel()
        model.settings.selectedEngine = .parakeetCloud
        model.sessionModel = .engine(.geminiFlash)
        model.engineChipPulse += 1
        model.sessionModel = nil
        #expect(model.chipModel == .engine(.parakeetCloud))
        try await waitUntil { !model.showsChip }
        #expect(model.chipModel == nil)
    }

    @Test func aSwitchMeanwhileRestartsTheHold() async throws {
        let model = makeModel(hold: 0.3)
        model.engineChipPulse += 1
        try await Task.sleep(for: .milliseconds(200))
        model.engineChipPulse += 1
        model.sessionModel = .engine(.geminiPro)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.chipModel == .engine(.geminiPro), "the second switch runs its own hold")
        try await waitUntil { !model.showsChip }
    }

    /// Hands-free: hovering the pill (or the chip) brings the chip back, where it opens the model menu.
    @Test func hoveringHandsFreeBringsTheChipBack() {
        let model = PillModel.preview(phase: .locked)
        model.sessionModel = .engine(.geminiPro)
        #expect(model.chipModel == nil)
        model.isHovering = true
        #expect(model.chipModel == .engine(.geminiPro))
        model.sessionModel = nil
        #expect(model.chipModel == .engine(.parakeet), "the main model too, for its menu")
        model.isHovering = false
        #expect(model.chipModel == nil)

        let pushToTalk = PillModel.preview(phase: .listening, isHovering: true)
        pushToTalk.sessionModel = .engine(.geminiPro)
        #expect(pushToTalk.chipModel == nil, "a held key has no menu to offer")
    }

    @Test func previewsKeepTheChip() async throws {
        let model = PillModel.preview(phase: .listening)
        model.flashChip()
        try await Task.sleep(for: .seconds(model.timing.chipHold + 0.1))
        #expect(model.showsChip)
    }

    @Test func theMenuOffersTheMainModelThenCleanupThenTheEnabledExtraModels() {
        let model = makeModel()
        #expect(model.menuChoices == [.engine(.parakeet), .cleanup, .engine(.geminiFlash), .engine(.geminiPro)])
        model.settings.switchEngines = [.geminiPro]
        #expect(model.menuChoices == [.engine(.parakeet), .cleanup, .engine(.geminiPro)])
        model.settings.switchCleanup = false
        #expect(model.menuChoices == [.engine(.parakeet), .engine(.geminiPro)])
        model.settings.switchCleanup = true
        model.settings.cleanupSystemPrompt = " "
        #expect(model.menuChoices == [.engine(.parakeet), .engine(.geminiPro)], "no prompt, no clean-up")
    }

    @Test func extraModelsAndCleanupTintThePillAndTheMainModelDoesNot() {
        #expect(PillPalette.accent(for: .engine(.geminiFlash)) == PillAccent(ringHex: 0x7F77DD, markHex: 0xAFA9EC))
        #expect(PillPalette.accent(for: .engine(.geminiPro)) == PillAccent(ringHex: 0xD4537E, markHex: 0xED93B1))
        #expect(PillPalette.accent(for: .cleanup) == PillAccent(ringHex: 0xE58A5F, markHex: 0xFFB896))
        for choice in [ModelChoice.engine(.parakeet), .engine(.parakeetCloud), nil] {
            #expect(PillPalette.accent(for: choice) == nil)
        }
        // Every choice has its own color.
        let choices = [ModelChoice.cleanup] + EngineID.switchCandidates.map(ModelChoice.engine)
        let accents = choices.compactMap { PillPalette.accent(for: $0) }
        #expect(Set(accents.map(\.ringHex)).count == choices.count)
    }

    @Test func theChipsHitRegionReportsItsChanges() {
        let regions = PillHitRegions()
        var changes = 0
        regions.onChange = { changes += 1 }
        let rect = CGRect(x: 180, y: 380, width: 110, height: PillMetrics.chipHeight)
        regions.setChip(rect)
        regions.setChip(rect)
        #expect(regions.chip == rect && changes == 1)
        regions.setChip(nil)
        #expect(regions.chip == nil && changes == 2)
    }

    @Test func theModelMenuChecksTheCurrentChoiceAndPicksOne() throws {
        var picked: [ModelChoice] = []
        let menu = PillController.modelMenu(choices: [.engine(.parakeet), .cleanup, .engine(.geminiFlash), .engine(.geminiPro)],
                                            current: .cleanup, main: .parakeet, cleanup: .gpt6Luna) {
            picked.append($0)
        }
        // The main model and its clean-up, then the models that hear the audio themselves.
        #expect(menu.items.map(\.isSeparatorItem) == [false, false, true, false, false])
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title)
            == ["Parakeet v3", "Parakeet v3 + GPT-6 Luna", "Gemini Flash", "Gemini Pro"])
        #expect(menu.items.map(\.state) == [.off, .on, .off, .off, .off])
        let pro = try #require(menu.items.last)
        menu.performActionForItem(at: menu.index(of: pro))
        #expect(picked == [.engine(.geminiPro)])

        let geminiOnly = PillController.modelMenu(choices: [.engine(.parakeet), .engine(.geminiPro)],
                                                  current: .engine(.parakeet), main: .parakeet, cleanup: .gpt6Luna) { _ in }
        #expect(geminiOnly.items.map(\.isSeparatorItem) == [false, true, false])
    }

    @Test func theHintNamesTheOneChoiceOrWhatTheyShare() {
        #expect(PillSwitchHint.label(for: [.engine(.geminiFlash), .engine(.geminiPro)], cleanup: .gpt6Luna) == "Gemini")
        #expect(PillSwitchHint.label(for: [.engine(.geminiPro)], cleanup: .gpt6Luna) == "Gemini Pro")
        #expect(PillSwitchHint.label(for: [.cleanup], cleanup: .gpt6Luna) == "Luna clean-up")
        #expect(PillSwitchHint.label(for: [.cleanup, .engine(.geminiFlash)], cleanup: .geminiFlashLite) == "Clean-up, Gemini")
    }

    @Test func toastsClearTheChip() {
        #expect(PillCanvasMetrics.chipLift == PillMetrics.chipGap + PillMetrics.chipHeight)
        // The lifted toast stack sits above the chip over the tallest pill.
        #expect(PillCanvasMetrics.toastLift + PillCanvasMetrics.chipLift
                >= PillCanvasMetrics.pillBottomInset + PillMetrics.maxHeight + PillMetrics.chipLift + 8)
    }
}

@Suite @MainActor struct PillStageEngineTests {
    @Test func theExitKeepsTheExtraModelUntilThePillHasLeft() {
        var stage = PillStage()
        stage.record(.listening, choice: .engine(.geminiFlash))
        stage.record(.processing(afterHandsFree: false), choice: .engine(.geminiFlash))
        // The text lands: the controller drops the engine in the same update that hides the pill.
        let exiting = stage.frame(for: .hidden, choice: nil)
        #expect(exiting.choice == .engine(.geminiFlash) && exiting.content == .processing(afterHandsFree: false))
        stage.record(.hidden, choice: nil)
        #expect(stage.frame(for: .hidden, choice: nil).choice == .engine(.geminiFlash))
        stage.settle(stage.generation, visual: .hidden)
        #expect(stage.frame(for: .hidden, choice: nil).choice == nil)
        #expect(stage.lastShownChoice == nil)
    }

    @Test func theRestMorphShrinksTheChipWithTheContent() {
        var stage = PillStage()
        stage.record(.processing(afterHandsFree: false), choice: .engine(.geminiPro))
        let morphing = stage.frame(for: .rest, choice: nil)
        #expect(morphing.choice == .engine(.geminiPro) && morphing.morph == 1)
        stage.record(.rest, choice: nil)
        #expect(stage.frame(for: .rest, choice: nil).choice == .engine(.geminiPro))
        stage.settle(stage.generation, visual: .rest)
        #expect(stage.frame(for: .rest, choice: nil).choice == nil)
    }

    @Test func aShownPillFollowsTheCurrentEngine() {
        var stage = PillStage()
        stage.record(.listening, choice: nil)
        #expect(stage.frame(for: .listening, choice: .engine(.geminiFlash)).choice == .engine(.geminiFlash))
        stage.record(.listening, choice: .engine(.geminiFlash))
        // The next queued job is on the main model: its processing pill drops the chip.
        #expect(stage.frame(for: .processing(afterHandsFree: false), choice: nil).choice == nil)
        // Contents without a dictation never carry one.
        #expect(stage.frame(for: .error, choice: .engine(.geminiFlash)).choice == nil)
        #expect(stage.frame(for: .peek, choice: .engine(.geminiFlash)).choice == nil)
    }
}

@Suite struct ToastSlotTests {
    /// A hidden pill (While dictating, between dictations) or Never mode: the toast's bottom meets the pill's.
    @Test func toastsDropIntoThePillSlotWhenNoPillIsShown() {
        #expect(PillCanvasView.toastBottomPadding(pillOnScreen: false, showsChip: false) == PillCanvasMetrics.pillBottomInset)
        #expect(PillCanvasView.toastBottomPadding(pillOnScreen: false, showsChip: true) == PillCanvasMetrics.pillBottomInset)
        #expect(PillCanvasView.toastBottomPadding(pillOnScreen: true, showsChip: false) == PillCanvasMetrics.toastLift)
        #expect(PillCanvasView.toastBottomPadding(pillOnScreen: true, showsChip: true)
                == PillCanvasMetrics.toastLift + PillCanvasMetrics.chipLift)
    }
}
