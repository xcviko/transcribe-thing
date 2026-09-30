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

    /// The pill and its toasts show in screenshots, recordings and screen shares.
    @Test @MainActor func thePanelShowsInScreenCaptures() {
        #expect(PillPanel(size: CGSize(width: 10, height: 10)).sharingType == .readOnly)
    }
}

// MARK: - Pill model

@Suite @MainActor struct PillModelTests {
    private func makeModel() -> PillModel {
        let model = PillModel(settings: .inMemory(), levelMeter: .preview(level: 0.5))
        model.timing = PillTiming(errorHold: 0.08, hoverIn: 0.01, hoverOut: 0.01,
                                  tooltipDelay: 0.02, controlTooltipDelay: 0.02, counterDelay: 5)
        return model
    }

    @Test func startsIdleWithSettingsDerivedHints() {
        let settings = AppSettings.inMemory()
        let model = PillModel(settings: settings, levelMeter: .preview(level: 0))
        #expect(model.phase == .rest)
        #expect(model.visiblePhase == .rest)
        #expect(!model.showsHours)
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

    /// A recording has no limit: past its first hour the timer only needs room for the hours.
    @Test func showsHoursFromTheHourMark() {
        let model = makeModel()
        model.phase = .locked
        #expect(!model.showsHours)
        model.recordingStartedAt = Date().addingTimeInterval(-3601)
        #expect(model.showsHours, "an Undo-resumed long dictation is past it at once")
        model.phase = .processing
        #expect(!model.showsHours)
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

    /// A count shows once it has been there a moment, so a quick answer never flashes a number.
    @Test func theCounterWaitsItsDelayWhileProcessing() async throws {
        let model = makeModel()
        model.timing.counterDelay = 0.05
        model.phase = .processing
        model.tokenCount = PillTokenCount(phase: .thinking, tokens: 120)
        #expect(!model.showsCounter, "not at once")
        try await waitUntil { model.showsCounter }
        // The count moving on, or switching to writing, keeps it up.
        model.tokenCount = PillTokenCount(phase: .writing, tokens: 3)
        #expect(model.showsCounter)
    }

    @Test func aCountThatGoesAwayHidesIt() async throws {
        let model = makeModel()
        model.timing.counterDelay = 0.05
        model.phase = .processing
        model.tokenCount = PillTokenCount(phase: .writing, tokens: 40)
        try await waitUntil { model.showsCounter }
        model.tokenCount = nil
        #expect(!model.showsCounter)
        // A count gone before its delay never shows.
        model.tokenCount = PillTokenCount(phase: .writing, tokens: 40)
        model.tokenCount = nil
        try await Task.sleep(for: .milliseconds(150))
        #expect(!model.showsCounter)
    }

    @Test func leavingProcessingClearsTheCounter() async throws {
        let model = makeModel()
        model.timing.counterDelay = 0.05
        model.phase = .processing
        model.tokenCount = PillTokenCount(phase: .thinking, tokens: 2_400)
        try await waitUntil { model.showsCounter }
        model.phase = .rest
        #expect(!model.showsCounter)
        // Nor does a wait armed before the pill left bring it back.
        model.phase = .processing
        model.phase = .listening
        try await Task.sleep(for: .milliseconds(150))
        #expect(!model.showsCounter)
    }

    @Test func aCountWhileRecordingDoesntArmIt() async throws {
        let model = makeModel()
        model.timing.counterDelay = 0.05
        model.phase = .listening
        model.tokenCount = PillTokenCount(phase: .writing, tokens: 900)
        try await Task.sleep(for: .milliseconds(150))
        #expect(!model.showsCounter)
        #expect(PillView(model: model).visual == .listening)
    }

    @Test func previewsHoldTheirPhase() async throws {
        let model = PillModel.preview(phase: .error)
        #expect(model.visiblePhase == .error)
        try await Task.sleep(for: .seconds(1.8))
        #expect(model.visiblePhase == .error)
    }

    @Test func processingDotsStartWhereTheHandsFreeBarsWere() {
        let locked = PillVisual.locked(), processing = PillVisual.processing(afterHandsFree: true)
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

    @Test func visualGeometryMatchesTheSpec() {
        #expect(PillVisual.rest.size == CGSize(width: 40, height: 10))
        #expect(PillVisual.peek.size == CGSize(width: 76, height: 24))
        #expect(PillVisual.listening.size == CGSize(width: 104, height: 32))
        #expect(PillVisual.locked().size == CGSize(width: 198, height: 36))
        #expect(PillVisual.locked(hours: true).size == CGSize(width: 216, height: 36))
        #expect(PillVisual.processing(afterHandsFree: true).size == CGSize(width: 104, height: 32))
        #expect(PillVisual.processing(afterHandsFree: false).size == CGSize(width: 104, height: 32))
        #expect(PillVisual.error.size == CGSize(width: 104, height: 32))
        #expect(PillMetrics.barFieldWidth == 69)
    }

    /// X | bars | timer | Stop, left to right, with the same gap between each for a "9:59" timer, and a
    /// "59:59" one still clear of the bars and Stop.
    @Test func handsFreeSpacesItsControlsEvenly() {
        let width = PillMetrics.lockedSize.width
        let cancelRight = PillMetrics.buttonInset + PillMetrics.buttonSize
        let stopLeft = width - cancelRight
        let barsLeft = width / 2 + PillVisual.locked().barsOffset - PillMetrics.barFieldWidth / 2
        let barsRight = barsLeft + PillMetrics.barFieldWidth
        let timerCenter = stopLeft - PillMetrics.timerTrailing - PillMetrics.timerWidth / 2
        func gaps(timer: CGFloat) -> [CGFloat] {
            [barsLeft - cancelRight, timerCenter - timer / 2 - barsRight, stopLeft - (timerCenter + timer / 2)]
        }
        #expect(gaps(timer: PillMetrics.shortTimerWidth) == [15, 15, 15])
        #expect(gaps(timer: PillMetrics.timerWidth) == [15, 11.5, 11.5])
        #expect(PillMetrics.lockedGap == 15)
    }

    /// Past an hour the timer reads "1:02:03": the capsule widens once, to a column that fits it, and keeps its
    /// even gaps. The dots after Stop still start where the usual hands-free bars stand.
    @Test func handsFreePastAnHourWidensOnce() {
        let model = PillModel.preview(phase: .locked, recordingFor: 3733)
        #expect(model.showsHours)
        let visual = PillView(model: model).visual
        #expect(visual == .locked(hours: true))
        #expect(visual.size == PillMetrics.lockedHoursSize)
        #expect(!PillModel.preview(phase: .locked, recordingFor: 3599).showsHours)

        let width = PillMetrics.lockedHoursSize.width
        let cancelRight = PillMetrics.buttonInset + PillMetrics.buttonSize
        let stopLeft = width - cancelRight
        let barsLeft = width / 2 + visual.barsOffset - PillMetrics.barFieldWidth / 2
        let barsRight = barsLeft + PillMetrics.barFieldWidth
        let timerRight = stopLeft - PillMetrics.lockedGap
        let timerLeft = timerRight - PillMetrics.hoursTimerWidth
        #expect([barsLeft - cancelRight, timerLeft - barsRight, stopLeft - timerRight]
                == [PillMetrics.lockedGap, PillMetrics.lockedGap, PillMetrics.lockedGap])
        #expect(PillVisual.processing(afterHandsFree: true).barsOffset == PillMetrics.lockedBarsOffset(hours: false))
    }

    @MainActor @Test func timerWidthsFitTheirText() {
        func width(_ text: String) -> CGFloat {
            NSHostingView(rootView: Text(text).font(PillMetrics.timerFont).fixedSize()).fittingSize.width
        }
        for text in ["0:05", "0:14", "8:88", "9:59"] {
            #expect(abs(width(text) - PillMetrics.shortTimerWidth) <= 1, "\(text)")
        }
        for text in ["10:00", "28:48", "29:59", "59:59"] {
            #expect(width(text) <= PillMetrics.timerWidth, "\(text)")
        }
        for text in ["1:00:00", "1:02:03", "9:59:59"] {
            #expect(width(text) <= PillMetrics.hoursTimerWidth, "\(text)")
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
            #expect(PillView(model: model, context: context).visual == .locked())
            model.isHovering = true
            #expect(PillView(model: model, context: context).visual == .locked())
        }
        #expect(PillVisual.locked().isLocked && !PillVisual.listening.isLocked)
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

    /// The count takes the dots' place in a capsule wide enough for the longest it says, and no tick ever resizes it:
    /// the number isn't part of the visual.
    @Test func theCounterNeverResizesThePill() throws {
        let model = PillModel.preview(phase: .processing)
        #expect(PillView(model: model).visual == .processing(afterHandsFree: false))
        let visuals = [PillTokenCount(phase: .thinking, tokens: 1), PillTokenCount(phase: .thinking, tokens: 88_800),
                       PillTokenCount(phase: .writing, tokens: 340)].map {
            PillView(model: PillModel.preview(phase: .processing).previewCounter($0)).visual
        }
        #expect(Set(visuals.map { "\($0)" }).count == 1)
        let counting = try #require(visuals.first)
        #expect(counting == .processing(afterHandsFree: false, counting: true) && counting.isCounting)
        #expect(!PillVisual.processing(afterHandsFree: false).isCounting && !PillVisual.listening.isCounting)
        // Push-to-talk height, wider than the dots' pill and still narrower than hands-free.
        let size = counting.size
        #expect(size == PillMetrics.counterSize && size.height == PillMetrics.listeningSize.height)
        #expect(size.width > PillMetrics.listeningSize.width && size.width < PillMetrics.lockedSize.width)
        // Room for "~88.8k thinking", the widest it says, and its dot and padding.
        let number = PillMetrics.textWidth("~88.8k", size: PillMetrics.counterNumberFontSize, weight: .semibold,
                                           rounded: true, monospacedDigits: true)
        let word = PillMetrics.textWidth("thinking", size: PillMetrics.captionFontSize, weight: .medium, rounded: true)
        #expect(number > 25 && word > 35)
        #expect(size.width >= 2 * PillMetrics.counterPadding + PillMetrics.counterDotSize + PillMetrics.counterDotGap
                + number + PillMetrics.counterWordGap + word)
        #expect(PillTokenCount(phase: .thinking, tokens: 88_849).text == "~88.8k")
        // After hands-free it's the same pill; the dots' start offset doesn't change its size.
        let afterHandsFree = PillModel.preview(phase: .locked)
        afterHandsFree.phase = .processing
        _ = afterHandsFree.previewCounter(PillTokenCount(phase: .writing, tokens: 12))
        #expect(PillView(model: afterHandsFree).visual == .processing(afterHandsFree: true, counting: true))
        #expect(PillVisual.processing(afterHandsFree: true, counting: true).size == size)
        #expect(PillVisual.processing(afterHandsFree: true, counting: true).barsOffset
                == PillMetrics.lockedBarsOffset(hours: false))
        // The panel's pill counts too.
        #expect(PillView(model: PillModel.preview(phase: .processing)
            .previewCounter(PillTokenCount(phase: .thinking, tokens: 5)), context: .panel(nil)).visual.isCounting)
    }

    @Test func theCounterOnlyAppliesWhileProcessing() {
        let count = PillTokenCount(phase: .thinking, tokens: 500)
        #expect(!PillView(model: PillModel.preview(phase: .listening).previewCounter(count)).visual.isCounting)
        #expect(!PillView(model: PillModel.preview(phase: .error).previewCounter(count)).visual.isCounting)
    }

    /// Starting to count keeps the pill's content (same wave, same shimmer) and its model: only the capsule and what
    /// it says change.
    @Test func countingKeepsTheContentAndTheModel() {
        var stage = PillStage()
        stage.record(.processing(afterHandsFree: false), choice: .gemini)
        let counting = PillVisual.processing(afterHandsFree: false, counting: true)
        let frame = stage.frame(for: counting, choice: .gemini)
        #expect(frame == PillStage.Frame(capsule: counting, content: counting, exit: 0, morph: 0, collapsed: false,
                                         choice: .gemini))
        #expect(frame.content.content == PillVisual.processing(afterHandsFree: false).content)
        stage.record(counting, choice: .gemini)
        // Leaving, the wide pill exits whole, its count and tint included.
        let exiting = stage.frame(for: .hidden)
        #expect(exiting.capsule == counting && exiting.content == counting && exiting.choice == .gemini)
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

// MARK: - Live count

@Suite struct TokenEstimateTests {
    /// A version by `modelID` that thought `reasoningTokens` for `reasoningCharacters` of summary, and wrote
    /// `outputTokens` for `text`.
    private func version(_ modelID: String, reasoningTokens: Int? = nil, reasoningCharacters: Int? = nil,
                         outputTokens: Int? = nil, text: String = "") -> TranscriptVersion {
        let usage = TokenUsage(completionTokens: (reasoningTokens ?? 0) + (outputTokens ?? 0),
                               reasoningTokens: reasoningTokens)
        return TranscriptVersion(kind: .transcription(.geminiFlash), text: text,
                                 metadata: TranscriptMetadata(modelID: modelID, usage: usage,
                                                              reasoningCharacters: reasoningCharacters))
    }

    private func entry(_ versions: TranscriptVersion...) -> TranscriptEntry {
        TranscriptEntry(engine: .geminiFlash, audioDuration: 5, voicedSeconds: 4, versions: versions)
    }

    private static let gemini = "google/gemini-3.8-flash"

    @Test func withoutHistoryReasoningCountsAsVisibleText() {
        let estimate = TokenEstimate.learned(from: [], modelID: Self.gemini)
        #expect(estimate == TokenEstimate())
        #expect(estimate.count(for: ChatStreamProgress(reasoningCharacters: 800))
                == PillTokenCount(phase: .thinking, tokens: 200))
        #expect(estimate.count(for: ChatStreamProgress(outputCharacters: 1_000))
                == PillTokenCount(phase: .writing, tokens: 400))
        #expect(TokenEstimate.learned(from: [entry(version(Self.gemini, reasoningTokens: 900, reasoningCharacters: 90))],
                                      modelID: nil) == TokenEstimate(), "the local model streams nothing")
    }

    /// Gemini streams summaries far shorter than its thinking: past versions say by how much, the median of them.
    @Test func pastVersionsCalibrateTheEstimate() {
        let entries = [
            entry(version(Self.gemini, reasoningTokens: 17_700, reasoningCharacters: 1_770, outputTokens: 200,
                          text: String(repeating: "a", count: 400))),
            entry(version(Self.gemini, reasoningTokens: 3_000, reasoningCharacters: 1_000, outputTokens: 300,
                          text: String(repeating: "b", count: 1_000))),
            entry(version(Self.gemini, reasoningTokens: 8_000, reasoningCharacters: 1_000, outputTokens: 100,
                          text: String(repeating: "c", count: 100))),
        ]
        let estimate = TokenEstimate.learned(from: entries, modelID: Self.gemini)
        #expect(estimate.reasoningPerCharacter == 8, "median of 10, 3 and 8")
        #expect(estimate.outputPerCharacter == 0.5, "median of 0.5, 0.3 and 1")
        #expect(estimate.count(for: ChatStreamProgress(reasoningCharacters: 150))
                == PillTokenCount(phase: .thinking, tokens: 1_200))
        // An even number of samples takes the middle two.
        let two = TokenEstimate.learned(from: Array(entries.prefix(2)), modelID: Self.gemini)
        #expect(two.reasoningPerCharacter == 6.5)
    }

    /// Only the same model calibrates, whether OpenRouter named it with a date or not; at most the newest 20
    /// versions.
    @Test func onlyTheSameModelCalibrates() {
        let luna = version("openai/gpt-6-luna-20260922", outputTokens: 50, text: String(repeating: "a", count: 100))
        let gemini = version(Self.gemini + "-20260901", reasoningTokens: 5_000, reasoningCharacters: 1_000)
        let estimate = TokenEstimate.learned(from: [entry(luna), entry(gemini)], modelID: "openai/gpt-6-luna")
        #expect(estimate.outputPerCharacter == 0.5)
        #expect(estimate.reasoningPerCharacter == TokenEstimate().reasoningPerCharacter)
        #expect(TokenEstimate.learned(from: [entry(luna), entry(gemini)], modelID: Self.gemini).reasoningPerCharacter == 5)
        // The newest 20 decide: 20 at ratio 2, then older ones at 10.
        let recent = (0..<20).map { _ in entry(version(Self.gemini, reasoningTokens: 200, reasoningCharacters: 100)) }
        let older = (0..<30).map { _ in entry(version(Self.gemini, reasoningTokens: 1_000, reasoningCharacters: 100)) }
        #expect(TokenEstimate.learned(from: recent + older, modelID: Self.gemini).reasoningPerCharacter == 2)
    }

    @Test func versionsWithoutCountsAreIgnored() {
        let entries = [
            entry(version(Self.gemini)),
            entry(version(Self.gemini, reasoningTokens: 9_000)),
            entry(version(Self.gemini, reasoningTokens: 0, reasoningCharacters: 400)),
            entry(version(Self.gemini, outputTokens: 50)),
            entry(version(Self.gemini, reasoningTokens: 4_000, reasoningCharacters: 1_000)),
        ]
        let estimate = TokenEstimate.learned(from: entries, modelID: Self.gemini)
        #expect(estimate.reasoningPerCharacter == 4, "only the version with both counts")
        #expect(estimate.outputPerCharacter == TokenEstimate().outputPerCharacter, "no text to divide by")
    }

    @Test func outliersAreClamped() {
        let huge = TokenEstimate.learned(from: [entry(version(Self.gemini, reasoningTokens: 90_000, reasoningCharacters: 3))],
                                         modelID: Self.gemini)
        #expect(huge.reasoningPerCharacter == 20)
        let tiny = TokenEstimate.learned(from: [entry(version(Self.gemini, outputTokens: 1,
                                                              text: String(repeating: "a", count: 1_000)))],
                                         modelID: Self.gemini)
        #expect(tiny.outputPerCharacter == 0.05)
    }

    @Test func countIsNilWithoutCharacters() {
        #expect(TokenEstimate().count(for: ChatStreamProgress()) == nil)
    }

    /// Once the answer starts, the count is its writing, from its own first tokens, however long it thought.
    @Test func writingWinsOnceOutputStarts() {
        let count = TokenEstimate().count(for: ChatStreamProgress(reasoningCharacters: 70_000, outputCharacters: 30))
        #expect(count == PillTokenCount(phase: .writing, tokens: 12))
    }

    @Test func everyCharacterCountsAtLeastOneToken() {
        let sparse = TokenEstimate(reasoningPerCharacter: 0.05, outputPerCharacter: 0.05)
        #expect(sparse.count(for: ChatStreamProgress(reasoningCharacters: 1)) == PillTokenCount(phase: .thinking, tokens: 1))
        #expect(sparse.count(for: ChatStreamProgress(outputCharacters: 2)) == PillTokenCount(phase: .writing, tokens: 1))
    }
}

@Suite struct PillTokenCountTests {
    @Test func theCountFormatsCalmly() {
        let texts = [7, 643, 1_249, 17_700, 123_456].map { PillTokenCount(phase: .thinking, tokens: $0).text }
        #expect(texts == ["~7", "~640", "~1.2k", "~17.7k", "~123k"])
        #expect(PillTokenCount(phase: .writing, tokens: 10).text == "~10")
        #expect(PillTokenCount(phase: .writing, tokens: 999).text == "~990")
        #expect(PillTokenCount(phase: .writing, tokens: 1_000).text == "~1k")
        // VoiceOver says the number the pill shows.
        #expect(PillTokenCount(phase: .thinking, tokens: 1_249).spokenDescription == "Thinking, about 1,200 tokens")
        #expect(PillTokenCount(phase: .writing, tokens: 343).spokenDescription == "Writing, about 340 tokens")
        #expect(PillTokenCount(phase: .thinking, tokens: 123_456).spokenDescription == "Thinking, about 123,000 tokens")
    }

    @Test func theWordSaysThinkingThenWriting() {
        #expect(PillTokenCount(phase: .thinking, tokens: 5).word == "thinking")
        #expect(PillTokenCount(phase: .writing, tokens: 5).word == "writing")
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
        [PillVisual.locked(), .processing(afterHandsFree: true)],
        [PillVisual.listening, .processing(afterHandsFree: false), .processing(afterHandsFree: false, counting: true)],
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
                      .processing(afterHandsFree: false, counting: true), .processing(afterHandsFree: true, counting: true),
                      .error, .listening, .locked(), .locked(hours: true), .peek, .hello])
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

    /// The token count spans its capsule edge to edge, and the capsule's ends round in faster than it shrinks: it
    /// fades over the first stretch of the morph (about 60 ms of the spring) instead of the whole of it.
    @Test func theCountFadesEarlyWhenThePillGoesToRest() {
        let counting = PillVisual.processing(afterHandsFree: false, counting: true)
        let rest = PillMetrics.restSize
        let span = PillMotion.counterFadeSpan
        let spring = Spring(duration: PillMotion.morphDuration, bounce: 0)
        #expect(CGFloat(spring.value(target: 1.0, time: 0.06)) >= span, "gone by 60 ms")
        let early = PillMotion.morphPose(at: span / 2, from: counting.size, to: rest, fadeSpan: span)
        #expect(abs(early.opacity - 0.5) < 1e-9, "halfway through its span, half gone")
        #expect(early.size == PillMotion.morphPose(at: span / 2, from: counting.size, to: rest).size, "same capsule")
        #expect(PillMotion.morphPose(at: span, from: counting.size, to: rest, fadeSpan: span).opacity == 0)
        #expect(PillMotion.morphPose(at: span, from: counting.size, to: rest).opacity > 0, "other content: the whole morph")
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

// MARK: - Models

@Suite @MainActor struct PillModelChipTests {
    private func makeModel(hold: TimeInterval = 0.05) -> PillModel {
        let model = PillModel(settings: .inMemory(), levelMeter: .preview(level: 0.5))
        model.timing.chipHold = hold
        return model
    }

    /// A switch names the new model for a moment; then the tint alone says it.
    @Test func eachSwitchFlashesTheChipThenItGoes() async throws {
        let model = makeModel()
        model.sessionModel = .parakeet
        #expect(model.chipModel == nil, "a clean pill until a switch")
        model.engineChipPulse += 1
        model.sessionModel = .gemini
        #expect(model.chipModel == .gemini)
        model.engineChipPulse += 1
        model.sessionModel = .cleanup
        #expect(model.chipModel == .cleanup)
        try await waitUntil { !model.showsChip }
        #expect(model.chipModel == nil && model.sessionModel == .cleanup, "the dictation stays on clean-up")
    }

    @Test func switchingBackNamesTheMainModelThenFades() async throws {
        let model = makeModel()
        model.sessionModel = .gemini
        model.engineChipPulse += 1
        model.sessionModel = .parakeet
        #expect(model.chipModel == .parakeet)
        try await waitUntil { !model.showsChip }
        #expect(model.chipModel == nil)
    }

    @Test func aSwitchMeanwhileRestartsTheHold() async throws {
        let model = makeModel(hold: 0.3)
        model.engineChipPulse += 1
        try await Task.sleep(for: .milliseconds(200))
        model.engineChipPulse += 1
        model.sessionModel = .gemini
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.chipModel == .gemini, "the second switch runs its own hold")
        try await waitUntil { !model.showsChip }
    }

    /// Hovering the pill never brings the chip up: only a switch does. A chip up in hands-free stays while the
    /// pointer is on it, so its menu can be opened.
    @Test func onlyASwitchBringsTheChipUp() async throws {
        let model = PillModel.preview(phase: .locked, isHovering: true)
        model.sessionModel = .gemini
        #expect(model.chipModel == nil, "hovering the pill")
        model.setPointerOverChip(true)
        #expect(model.chipModel == .gemini, "resting on the chip after a switch keeps it")
        model.setPointerOverChip(false)
        #expect(model.chipModel == nil)

        let pushToTalk = PillModel.preview(phase: .listening)
        pushToTalk.sessionModel = .gemini
        pushToTalk.setPointerOverChip(true)
        #expect(pushToTalk.chipModel == nil, "a held key has no menu to offer")
    }

    @Test func previewsKeepTheChip() async throws {
        let model = PillModel.preview(phase: .listening)
        model.flashChip()
        try await Task.sleep(for: .seconds(model.timing.chipHold + 0.1))
        #expect(model.showsChip)
    }

    @Test func theMenuOffersTheLineupFromTheMainModel() {
        let model = makeModel()
        #expect(model.menuChoices == [.parakeet, .cleanup, .gemini])
        model.settings.lineup.setSwitchable(.gemini, false)
        #expect(model.menuChoices == [.parakeet, .cleanup])
        model.settings.lineup.setSwitchable(.gemini, true)
        model.settings.lineup.setSwitchable(.cleanup, false)
        model.settings.lineup.main = .gemini
        #expect(model.menuChoices == [.gemini, .parakeet], "from the main model on, wrapping around")
    }

    /// Color means the model, whichever is main: the one Models gives it; today's by default.
    @Test func eachModelKeepsItsColorWhateverTheMainModel() {
        let colors = ModelColors.default
        #expect(PillPalette.accent(for: .gemini, in: colors) == PillAccent(ringHex: 0x7F77DD, markHex: 0xAFA9EC))
        #expect(PillPalette.accent(for: .cleanup, in: colors) == PillAccent(ringHex: 0xE58A5F, markHex: 0xFFB896))
        #expect(PillPalette.accent(for: .parakeet, in: colors) == nil && PillPalette.accent(for: nil, in: colors) == nil)

        var picked = ModelColors.default
        picked[.parakeet] = .teal
        picked[.gemini] = .graphite
        picked[.cleanup] = .teal
        #expect(PillPalette.accent(for: .parakeet, in: picked) == PillPalette.accent(for: ModelColor.teal))
        #expect(PillPalette.accent(for: .gemini, in: picked) == nil, "graphite is the plain pill")
        #expect(PillPalette.accent(for: .cleanup, in: picked) == PillPalette.accent(for: .parakeet, in: picked),
                "two may share one")
        // The main model changes nothing the pill draws.
        let model = makeModel()
        model.settings.lineup.main = .gemini
        model.sessionModel = .gemini
        model.flashChip()
        #expect(model.chipModel == .gemini)
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

    @Test func theModelMenuChecksTheCurrentChoiceAndDisablesWhatCantRun() throws {
        var picked: [ModelChoice] = []
        let menu = PillController.modelMenu(choices: [.gemini, .parakeet, .cleanup], current: .cleanup,
                                            parakeet: .parakeetCloud,
                                            unavailableReason: { $0 == .parakeet ? "Needs key" : nil }) {
            picked.append($0)
        }
        // The cycle as it is, the main model first: no separators.
        #expect(menu.items.allSatisfy { !$0.isSeparatorItem })
        #expect(menu.items.map(\.title) == ["Gemini 3.8 Flash", "Parakeet v3 · Cloud  Needs key", "Parakeet v3 + GPT-6 Luna"])
        #expect(menu.items.map(\.state) == [.off, .off, .on])
        #expect(menu.items.map(\.isEnabled) == [true, false, true])
        #expect(menu.items[0].attributedTitle == nil, "a suffix only for what can't run")
        let gemini = try #require(menu.items.first)
        _ = (gemini.target as AnyObject?)?.perform(gemini.action, with: gemini)
        #expect(picked == [.gemini])
    }

    @Test func theHintNamesTheOneStepOrWhatTheyShare() {
        #expect(PillSwitchHint.label(for: [.gemini]) == "Gemini 3.8 Flash")
        #expect(PillSwitchHint.label(for: [.cleanup]) == "GPT-6 Luna clean-up")
        #expect(PillSwitchHint.label(for: [.parakeet]) == "Parakeet v3")
        #expect(PillSwitchHint.label(for: [.cleanup, .gemini]) == "Clean-up, Gemini")
        #expect(PillSwitchHint.label(for: [.parakeet, .cleanup]) == "Parakeet, Clean-up")
    }

    @Test func toastsClearTheChip() {
        #expect(PillCanvasMetrics.chipLift == PillMetrics.chipGap + PillMetrics.chipHeight)
        // The lifted toast stack sits above the chip over the tallest pill.
        #expect(PillCanvasMetrics.toastLift + PillCanvasMetrics.chipLift
                >= PillCanvasMetrics.pillBottomInset + PillMetrics.maxHeight + PillMetrics.chipLift + 8)
    }
}

// MARK: - Colors

@Suite struct ModelColorTests {
    /// The pill's fill over a white page, where it's lightest; the capsule's text also sits under the top of its
    /// sheen (2%). The tooltip is a shade lighter.
    private static let pill = SRGB(0x101012).over(.white, alpha: 0.92)
    private static let capsule = SRGB.white.over(pill, alpha: 0.02)
    private static let tooltip = SRGB(0x151517).over(.white, alpha: 0.96)
    private static let stop = SRGB(0xFF453A)
    private static let error = SRGB(0xFF6B5E)

    private static let tinted = ModelColor.allCases.filter { $0 != .graphite }

    @Test func modelColorsGoRoundTheHuesFromGraphite() throws {
        #expect(ModelColor.allCases == [.graphite, .orange, .green, .teal, .blue, .violet, .purple, .pink])
        #expect(Set(ModelColor.allCases.map(\.title)).count == ModelColor.allCases.count)
        #expect(PillPalette.accent(for: ModelColor.graphite) == nil)
        let accents = try Self.tinted.map { try #require(PillPalette.accent(for: $0)) }
        #expect(Set(accents.map(\.ringHex)).count == Self.tinted.count)
        #expect(Set(accents.map(\.markHex)).count == Self.tinted.count)
    }

    @Test func theDefaultsAreTodaysAndPinkIsTheRetiredOne() {
        #expect(ModelColors.default[.parakeet] == .graphite)
        #expect(ModelColors.default[.cleanup] == .orange)
        #expect(ModelColors.default[.gemini] == .violet)
        #expect(ModelChoice.allCases.allSatisfy { ModelColors.default[$0] == $0.defaultColor })
        #expect(PillPalette.accent(for: ModelColor.violet) == PillAccent(ringHex: 0x7F77DD, markHex: 0xAFA9EC))
        #expect(PillPalette.accent(for: ModelColor.orange) == PillAccent(ringHex: 0xE58A5F, markHex: 0xFFB896))
        #expect(PillPalette.accent(for: ModelColor.pink) == PillAccent(ringHex: 0xD4537E, markHex: 0xED93B1),
                "Gemini 3.1 Pro's")
    }

    /// Whatever the model's color, the fill stays graphite: its whites read as they always have.
    @Test func thePillKeepsItsWhitesLegible() {
        func white(_ opacity: Double, on background: SRGB) -> Double {
            SRGB.white.over(background, alpha: opacity).contrast(with: background)
        }
        let (pill, capsule, tooltip) = (Self.pill, Self.capsule, Self.tooltip)

        #expect(white(0.96, on: capsule) >= 12, "the bars")
        #expect(white(0.70, on: capsule) >= 7 && white(0.70, on: pill) >= 7 && white(0.70, on: tooltip) >= 7,
                "the timer, the hint's label, Click for hands-free")
        #expect(white(0.55, on: capsule) >= 5, "the counter's word")
        #expect(white(0.50, on: pill) >= 4.5, "the chip's dimmed Parakeet")
        #expect(white(0.45, on: pill) >= 4, "silence and processing dots")
        #expect(white(0.35, on: pill) >= 3, "the peek's dots")
        // A key's "left" or "right", in the tooltip and in the hint.
        let keyCaps = [SRGB.white.over(tooltip, alpha: 0.18), SRGB.white.over(pill, alpha: 0.18)]
        #expect(keyCaps.allSatisfy { white(0.7, on: $0) >= 4.5 }, "a key's side caption")
        #expect(Self.stop.contrast(with: pill) >= 4, "Stop (PillPalette.stop)")
    }

    /// On the pill over a white page, the hardest case. Any color added later has to pass too.
    @Test(arguments: ModelColor.allCases.filter { $0 != .graphite })
    func everyModelColorReadsOnThePill(color: ModelColor) throws {
        let accent = try #require(PillPalette.accent(for: color))
        let mark = SRGB(accent.markHex)
        #expect(mark.over(Self.capsule, alpha: 0.96).contrast(with: Self.capsule) >= 6, "the bars")
        #expect(mark.contrast(with: Self.pill) >= 6.5, "the count's word and dot, the chip's symbol")
        #expect(SRGB(accent.ringHex).contrast(with: Self.pill) >= 3.5, "the ring")
    }

    /// Two colors, or a color and Stop or the error, never read as one.
    @Test func modelColorsStayApart() throws {
        let accents = try Self.tinted.map { color in (color, try #require(PillPalette.accent(for: color))) }
        for (a, b) in pairs(accents) {
            #expect(SRGB(a.1.ringHex).distance(to: SRGB(b.1.ringHex)) >= 0.10, "\(a.0) and \(b.0)'s rings")
            #expect(SRGB(a.1.markHex).distance(to: SRGB(b.1.markHex)) >= 0.08, "\(a.0) and \(b.0)'s marks")
        }
        for (color, accent) in accents {
            let ring = SRGB(accent.ringHex), mark = SRGB(accent.markHex)
            #expect(ring.distance(to: Self.stop) >= 0.11, "\(color)'s ring and Stop")
            #expect(mark.distance(to: Self.stop) >= 0.11 && mark.distance(to: Self.error) >= 0.11,
                    "\(color)'s marks and Stop, the error")
            // Clean-up's ring has always been this close to the error's red.
            #expect(ring.distance(to: Self.error) >= (color == .orange ? 0.07 : 0.11), "\(color)'s ring and the error")
        }
    }

    /// The tile's symbol over 13% of its color on the card (Models, the sidebar), History's mark over 12%, in both
    /// appearances. Orange (the Hub's warm) and graphite (ink) are as they always were.
    @Test(arguments: [ModelColor.green, .teal, .blue, .violet, .purple, .pink])
    func everyModelColorReadsInTheHub(color: ModelColor) throws {
        for (appearance, card) in [(NSAppearance.Name.aqua, SRGB.white), (.darkAqua, SRGB(0x1F1E1C))] {
            let tint = try #require(Self.resolved(color, in: appearance))
            #expect(tint.contrast(with: tint.over(card, alpha: 0.13)) >= 4.5, "\(color)'s tile, \(appearance.rawValue)")
            #expect(tint.contrast(with: tint.over(card, alpha: 0.12)) >= 4.5, "\(color)'s mark, \(appearance.rawValue)")
        }
    }

    @Test func hubColorsStayApart() throws {
        let colors: [ModelColor] = [.green, .teal, .blue, .violet, .purple, .pink]
        for (appearance, floor) in [(NSAppearance.Name.aqua, 0.10), (.darkAqua, 0.09)] {
            let tints = try colors.map { color in (color, try #require(Self.resolved(color, in: appearance))) }
            for (a, b) in pairs(tints) {
                #expect(a.1.distance(to: b.1) >= floor, "\(a.0) and \(b.0), \(appearance.rawValue)")
            }
        }
    }

    /// `color.hubColor` as `appearance` draws it.
    private static func resolved(_ color: ModelColor, in appearance: NSAppearance.Name) -> SRGB? {
        var resolved: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = color.hubColor.usingColorSpace(.sRGB)
        }
        return resolved.map { SRGB(r: Double($0.redComponent), g: Double($0.greenComponent), b: Double($0.blueComponent)) }
    }

    private func pairs<T>(_ items: [T]) -> [(T, T)] {
        items.indices.flatMap { i in items[(i + 1)...].map { (items[i], $0) } }
    }
}

/// A color as sRGB stores it (gamma-encoded, 0…1 a channel), where Core Animation blends.
private struct SRGB {
    var r, g, b: Double

    static let white = SRGB(r: 1, g: 1, b: 1)

    init(r: Double, g: Double, b: Double) {
        (self.r, self.g, self.b) = (r, g, b)
    }

    init(_ hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }

    /// This color at `alpha` over `background`.
    func over(_ background: SRGB, alpha: Double) -> SRGB {
        SRGB(r: alpha * r + (1 - alpha) * background.r, g: alpha * g + (1 - alpha) * background.g,
             b: alpha * b + (1 - alpha) * background.b)
    }

    private static func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

    /// WCAG 2 relative luminance.
    var luminance: Double {
        0.2126 * Self.linear(r) + 0.7152 * Self.linear(g) + 0.0722 * Self.linear(b)
    }

    /// WCAG 2 contrast ratio, 1…21.
    func contrast(with other: SRGB) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }

    /// OKLab (Björn Ottosson's), where a distance reads as a difference the eye sees.
    var oklab: (l: Double, a: Double, b: Double) {
        let (lr, lg, lb) = (Self.linear(r), Self.linear(g), Self.linear(b))
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// Euclidean distance in OKLab.
    func distance(to other: SRGB) -> Double {
        let (p, q) = (oklab, other.oklab)
        return ((p.l - q.l) * (p.l - q.l) + (p.a - q.a) * (p.a - q.a) + (p.b - q.b) * (p.b - q.b)).squareRoot()
    }
}

@Suite @MainActor struct PillStageEngineTests {
    @Test func theExitKeepsTheModelUntilThePillHasLeft() {
        var stage = PillStage()
        stage.record(.listening, choice: .gemini)
        stage.record(.processing(afterHandsFree: false), choice: .gemini)
        // The text lands: the controller drops the engine in the same update that hides the pill.
        let exiting = stage.frame(for: .hidden, choice: nil)
        #expect(exiting.choice == .gemini && exiting.content == .processing(afterHandsFree: false))
        stage.record(.hidden, choice: nil)
        #expect(stage.frame(for: .hidden, choice: nil).choice == .gemini)
        stage.settle(stage.generation, visual: .hidden)
        #expect(stage.frame(for: .hidden, choice: nil).choice == nil)
        #expect(stage.lastShownChoice == nil)
    }

    @Test func theRestMorphShrinksTheChipWithTheContent() {
        var stage = PillStage()
        stage.record(.processing(afterHandsFree: false), choice: .cleanup)
        let morphing = stage.frame(for: .rest, choice: nil)
        #expect(morphing.choice == .cleanup && morphing.morph == 1)
        stage.record(.rest, choice: nil)
        #expect(stage.frame(for: .rest, choice: nil).choice == .cleanup)
        stage.settle(stage.generation, visual: .rest)
        #expect(stage.frame(for: .rest, choice: nil).choice == nil)
    }

    @Test func aShownPillFollowsTheCurrentEngine() {
        var stage = PillStage()
        stage.record(.listening, choice: nil)
        #expect(stage.frame(for: .listening, choice: .gemini).choice == .gemini)
        stage.record(.listening, choice: .gemini)
        // The next queued job has no model to show (at rest): its processing pill drops the chip.
        #expect(stage.frame(for: .processing(afterHandsFree: false), choice: nil).choice == nil)
        // Contents without a dictation never carry one.
        #expect(stage.frame(for: .error, choice: .gemini).choice == nil)
        #expect(stage.frame(for: .peek, choice: .gemini).choice == nil)
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
