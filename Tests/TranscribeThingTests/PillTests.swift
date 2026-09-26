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

    @Test func interceptorRunsBeforeTheHandler() {
        let (center, _) = makeCenter()
        var order: [String] = []
        center.actionInterceptor = { _, _ in order.append("pill") }
        center.onAction = { _, _ in order.append("shell") }
        let show = NoticeAction(title: "Show Now", kind: .showPillNow, isPrimary: true)
        let posted = notice("hidden", actions: [show])
        center.post(posted)
        center.perform(show, on: posted)
        #expect(order == ["pill", "shell"])
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
        try await Task.sleep(for: .seconds(0.35))
        #expect(center.notices.isEmpty)
    }
}

// MARK: - Visibility

@Suite struct PillVisibilityTests {
    private let now = Date(timeIntervalSinceReferenceDate: 5_000)

    @Test(arguments: [PillPhase.hidden, .rest])
    func idleShowsOnlyInAlwaysMode(_ phase: PillPhase) {
        #expect(PillVisibility.showsPill(phase: phase, mode: .always, hiddenUntil: nil, now: now))
        #expect(!PillVisibility.showsPill(phase: phase, mode: .whileDictating, hiddenUntil: nil, now: now))
        #expect(!PillVisibility.showsPill(phase: phase, mode: .never, hiddenUntil: nil, now: now))
    }

    @Test(arguments: [PillPhase.listening, .locked, .processing, .success, .error])
    func activePhasesShowUnlessNeverOrHidden(_ phase: PillPhase) {
        #expect(PillVisibility.showsPill(phase: phase, mode: .always, hiddenUntil: nil, now: now))
        #expect(PillVisibility.showsPill(phase: phase, mode: .whileDictating, hiddenUntil: nil, now: now))
        #expect(!PillVisibility.showsPill(phase: phase, mode: .never, hiddenUntil: nil, now: now))
        #expect(!PillVisibility.showsPill(phase: phase, mode: .always, hiddenUntil: now.addingTimeInterval(60), now: now))
        #expect(!PillVisibility.showsPill(phase: phase, mode: .whileDictating, hiddenUntil: now.addingTimeInterval(60), now: now))
    }

    @Test func hideForAnHourExpires() {
        let past = now.addingTimeInterval(-1)
        #expect(PillVisibility.showsPill(phase: .rest, mode: .always, hiddenUntil: past, now: now))
        #expect(PillVisibility.isPillAllowed(mode: .whileDictating, hiddenUntil: past, now: now))
        #expect(!PillVisibility.isPillAllowed(mode: .whileDictating, hiddenUntil: now.addingTimeInterval(3600), now: now))
        #expect(!PillVisibility.isPillAllowed(mode: .never, hiddenUntil: nil, now: now))
    }

    @Test func helloShowsTheIdlePillInWhileDictatingButNotInNever() {
        #expect(PillVisibility.showsPill(phase: .rest, mode: .whileDictating, hiddenUntil: nil, now: now, isHelloActive: true))
        #expect(!PillVisibility.showsPill(phase: .rest, mode: .never, hiddenUntil: nil, now: now, isHelloActive: true))
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
        try await Task.sleep(for: .seconds(0.2))
        #expect(model.phase == .rest)
        #expect(model.visiblePhase == .rest)
    }

    @Test func earlyRestWaitsForTheCheckMark() async throws {
        let model = makeModel()
        model.timing.successHold = 0.15
        model.phase = .success
        model.phase = .rest
        #expect(model.visiblePhase == .success)
        try await Task.sleep(for: .seconds(0.35))
        #expect(model.visiblePhase == .rest)
    }

    @Test func theNextQueuedJobWaitsForTheCheckMark() async throws {
        let model = makeModel()
        model.timing.successHold = 0.15
        model.phase = .processing
        model.phase = .success
        // Job 2 is still transcribing: the controller asks for processing in the same turn.
        model.phase = .processing
        #expect(model.visiblePhase == .success)
        try await Task.sleep(for: .seconds(0.35))
        #expect(model.visiblePhase == .processing)
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
        try await Task.sleep(for: .seconds(0.3))
        #expect(model.visiblePhase == .rest)
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
        try await Task.sleep(for: .seconds(0.15))
        #expect(model.isHovering)
        #expect(model.showsTooltip)
        model.setPointerInside(false)
        #expect(!model.showsTooltip)
        try await Task.sleep(for: .seconds(0.1))
        #expect(!model.isHovering)
    }

    @Test func slowProcessingIsFlaggedAndClearedWhenDone() async throws {
        let model = makeModel()
        model.timing.slowProcessing = 0.05
        model.phase = .processing
        #expect(!model.isProcessingSlow)
        try await Task.sleep(for: .seconds(0.2))
        #expect(model.isProcessingSlow)
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
        #expect(PillVisual.locked(.none).size == CGSize(width: 168, height: 36))
        #expect(PillVisual.locked(.remaining).size == CGSize(width: 204, height: 36))
        #expect(PillVisual.processing(wide: true).size == CGSize(width: 168, height: 32))
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
        let hover = PillModel.preview(phase: .locked, isHovering: true)
        #expect(PillView(model: hover).visual == .locked(.elapsed))
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
