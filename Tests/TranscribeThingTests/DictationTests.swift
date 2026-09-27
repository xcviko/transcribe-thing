import AppKit
import Foundation
import Testing
@testable import TranscribeThing

// MARK: - DictationMachine: every row of the SPEC §4.11 table

@Suite struct DictationMachineTests {
    typealias M = DictationMachine
    typealias E = DictationMachine.Effect

    /// Binary-exact times so effect payloads compare with ==.
    static let t0: TimeInterval = 10
    static let armedAt: TimeInterval = 10.125

    static let cancelLimits: [E] = [.cancelTimer(.limitWarning), .cancelTimer(.limit)]
    static let cancelAll: [E] = [.cancelTimer(.arming), .cancelTimer(.doublePressWindow),
                                 .cancelTimer(.limitWarning), .cancelTimer(.limit)]

    static func limitTimers(elapsed: TimeInterval) -> [E] {
        [.schedule(.limitWarning, after: 1140 - elapsed), .schedule(.limit, after: 1200 - elapsed)]
    }

    // Fixtures for each state.
    static func arming() -> M {
        var m = M()
        _ = m.handle(.pttDown, now: t0)
        return m
    }

    static func listening() -> M {
        var m = arming()
        _ = m.handle(.timer(.arming), now: armedAt)
        return m
    }

    static func locked() -> M {
        var m = M()
        _ = m.handle(.handsFreeToggle, now: t0)
        return m
    }

    static func stopPending() -> M {
        var m = locked()
        _ = m.handle(.pttDown, now: 30)
        return m
    }

    static func tapPending() -> M {
        var m = arming()
        _ = m.handle(.pttUp, now: 10.0625)
        return m
    }

    static func state(_ name: String) -> M {
        switch name {
        case "arming": arming()
        case "listening": listening()
        case "locked": locked()
        case "lockedStopPending": stopPending()
        case "tapPending": tapPending()
        default: M()
        }
    }

    @Test func idlePTTDownStartsCaptureAndArms() {
        var m = M()
        let effects = m.handle(.pttDown, now: Self.t0)
        #expect(m.capture == .arming(downAt: Self.t0))
        #expect(effects == [.startCapture, .schedule(.arming, after: 0.12)])
        #expect(m.isRecording && m.isBusy)
    }

    @Test func armingConfirmsIntoListeningWithLimitTimersFromKeyDown() {
        var m = Self.arming()
        let effects = m.handle(.timer(.arming), now: Self.armedAt)
        #expect(m.capture == .listening(downAt: Self.t0))
        #expect(effects == [.showPill(.listening), .playSound(.start)] + Self.limitTimers(elapsed: 0.125))
    }

    @Test func releaseDuringArmingIsATap() {
        var m = Self.arming()
        let effects = m.handle(.pttUp, now: 10.0625)
        #expect(m.capture == .tapPending(firstDownAt: Self.t0))
        #expect(effects == [.cancelTimer(.arming), .cancelCapture(keepForUndo: false, notify: false),
                            .schedule(.doublePressWindow, after: 0.4375)])
        #expect(!m.isRecording)
    }

    @Test func interruptionDuringArmingIsSilent() {
        var m = Self.arming()
        let effects = m.handle(.pttInterrupted, now: 10.0625)
        #expect(m.capture == .idle)
        #expect(effects == [.cancelTimer(.arming), .cancelCapture(keepForUndo: false, notify: false)])
    }

    @Test func handsFreeFromArmingLocksAndSchedulesLimits() {
        var m = Self.arming()
        let effects = m.handle(.handsFreeToggle, now: 10.0625)
        #expect(m.capture == .locked(startedAt: Self.t0))
        #expect(effects == [.cancelTimer(.arming), .showPill(.locked), .playSound(.lock)]
            + Self.limitTimers(elapsed: 0.0625))
    }

    @Test func handsFreeFromListeningKeepsExistingLimitTimers() {
        var m = Self.listening()
        let effects = m.handle(.handsFreeToggle, now: 11)
        #expect(m.capture == .locked(startedAt: Self.t0))
        #expect(effects == [.cancelTimer(.arming), .showPill(.locked), .playSound(.lock)])
    }

    @Test func shortListeningReleaseIsATap() {
        var m = Self.listening()
        let effects = m.handle(.pttUp, now: 10.25)
        #expect(m.capture == .tapPending(firstDownAt: Self.t0))
        #expect(effects == Self.cancelLimits + [.cancelCapture(keepForUndo: false, notify: false), .showPill(.rest),
                                                .schedule(.doublePressWindow, after: 0.25)])
    }

    @Test func longListeningReleaseTranscribes() {
        var m = Self.listening()
        let effects = m.handle(.pttUp, now: 10.3125)
        #expect(m.capture == .idle)
        #expect(effects == Self.cancelLimits + [.stopCaptureAndTranscribe(mode: .pushToTalk), .playSound(.stop)])
    }

    @Test func earlyInterruptionFoldsAwayQuietly() {
        var m = Self.listening()
        let effects = m.handle(.pttInterrupted, now: 11)
        #expect(m.capture == .idle)
        #expect(effects == Self.cancelLimits + [.cancelCapture(keepForUndo: false, notify: false), .showPill(.rest)])
    }

    @Test func lateInterruptionKeepsAudioAndTellsTheUser() {
        var m = Self.listening()
        let effects = m.handle(.pttInterrupted, now: 11.5)
        #expect(m.capture == .idle)
        #expect(effects == Self.cancelLimits + [.cancelCapture(keepForUndo: true, notify: false), .showPill(.rest),
                                                .notice(.stoppedByOtherKey)])
    }

    @Test func doublePressLocks() {
        var m = Self.tapPending()
        let effects = m.handle(.pttDown, now: 10.375)
        #expect(m.capture == .locked(startedAt: 10.375))
        #expect(effects == [.cancelTimer(.doublePressWindow), .startCapture, .showPill(.locked), .playSound(.lock)]
            + Self.limitTimers(elapsed: 0))
    }

    @Test func slowSecondPressArmsAgain() {
        var m = Self.tapPending()
        let effects = m.handle(.pttDown, now: 10.625)
        #expect(m.capture == .arming(downAt: 10.625))
        #expect(effects == [.cancelTimer(.doublePressWindow), .startCapture, .schedule(.arming, after: 0.12)])
    }

    @Test func doublePressDisabledArmsAgain() {
        var m = DictationMachine(config: .init(doublePressEnabled: false))
        _ = m.handle(.pttDown, now: Self.t0)
        _ = m.handle(.pttUp, now: 10.0625)
        let effects = m.handle(.pttDown, now: 10.25)
        #expect(m.capture == .arming(downAt: 10.25))
        #expect(effects == [.cancelTimer(.doublePressWindow), .startCapture, .schedule(.arming, after: 0.12)])
    }

    @Test func doublePressWindowExpires() {
        var m = Self.tapPending()
        let effects = m.handle(.timer(.doublePressWindow), now: 10.5)
        #expect(m.capture == .idle)
        #expect(effects.isEmpty)
    }

    @Test(arguments: ["idle", "tapPending"], [DictationMachine.Input.handsFreeToggle, .pillClick])
    func handsFreeOrClickFromRestLocks(_ from: String, _ input: DictationMachine.Input) {
        var m = Self.state(from)
        let effects = m.handle(input, now: 20)
        #expect(m.capture == .locked(startedAt: 20))
        #expect(effects == [.cancelTimer(.doublePressWindow), .startCapture, .showPill(.locked), .playSound(.lock)]
            + Self.limitTimers(elapsed: 0))
    }

    @Test func pttDownWhileLockedWaitsForRelease() {
        var m = Self.locked()
        let effects = m.handle(.pttDown, now: 30)
        #expect(m.capture == .lockedStopPending(startedAt: Self.t0))
        #expect(effects.isEmpty)
        #expect(m.isRecording)
    }

    @Test func releaseOfTheLockingKeyIsIgnored() {
        var m = Self.locked()
        let effects = m.handle(.pttUp, now: 10.25)
        #expect(m.capture == .locked(startedAt: Self.t0))
        #expect(effects.isEmpty)
    }

    @Test func cleanPTTTapStopsHandsFree() {
        var m = Self.stopPending()
        let effects = m.handle(.pttUp, now: 30.125)
        #expect(m.capture == .idle)
        #expect(effects == Self.cancelLimits + [.stopCaptureAndTranscribe(mode: .handsFree), .playSound(.stop)])
    }

    @Test func comboWhileLockedKeepsRecording() {
        var m = Self.stopPending()
        let effects = m.handle(.pttInterrupted, now: 30.125)
        #expect(m.capture == .locked(startedAt: Self.t0))
        #expect(effects.isEmpty)
    }

    @Test(arguments: ["locked", "lockedStopPending"], [DictationMachine.Input.handsFreeToggle, .pillStop])
    func handsFreeOrStopFinishes(_ from: String, _ input: DictationMachine.Input) {
        var m = Self.state(from)
        let effects = m.handle(input, now: 40)
        #expect(m.capture == .idle)
        #expect(effects == Self.cancelLimits + [.stopCaptureAndTranscribe(mode: .handsFree), .playSound(.stop)])
    }

    @Test(arguments: ["arming", "listening", "locked", "lockedStopPending"],
          [DictationMachine.Input.cancel, .pillCancel])
    func cancelDiscardsWithUndo(_ from: String, _ input: DictationMachine.Input) {
        var m = Self.state(from)
        let effects = m.handle(input, now: 40)
        #expect(m.capture == .idle)
        #expect(effects == Self.cancelAll + [.cancelCapture(keepForUndo: true, notify: true), .playSound(.cancel)])
    }

    // MARK: Undo resumes

    @Test(arguments: ["idle", "tapPending"])
    func resumeLocksWithTheKeptAudioCounted(_ from: String) {
        var m = Self.state(from)
        let effects = m.handle(.resume(prefix: 2.5), now: 20)
        #expect(m.capture == .locked(startedAt: 17.5), "the timer counts from the canceled dictation's start")
        #expect(m.mode == .handsFree)
        #expect(effects == [.cancelTimer(.doublePressWindow), .resumeCapture, .showPill(.locked), .playSound(.lock)]
            + Self.limitTimers(elapsed: 2.5))
    }

    @Test func resumeWhileAJobRunsStillRecords() {
        var m = M()
        _ = m.handle(.jobStarted, now: 1)
        let effects = m.handle(.resume(prefix: 1), now: 2)
        #expect(effects.contains(.resumeCapture))
        #expect(m.isRecording && m.activeJobs == 1)
    }

    @Test(arguments: ["arming", "listening", "locked", "lockedStopPending"])
    func resumeWhileRecordingIsIgnored(_ from: String) {
        var m = Self.state(from)
        let before = m
        #expect(m.handle(.resume(prefix: 3), now: 40).isEmpty)
        #expect(m == before)
    }

    @Test(arguments: [DictationMachine.Input.handsFreeToggle, .pillStop])
    func resumedDictationFinishesLikeHandsFree(_ input: DictationMachine.Input) {
        var m = M()
        _ = m.handle(.resume(prefix: 4), now: 20)
        #expect(m.handle(input, now: 30) == Self.cancelLimits + [.stopCaptureAndTranscribe(mode: .handsFree), .playSound(.stop)])
        #expect(m.capture == .idle)
    }

    @Test func resumedDictationStopsWithAnFnTapAndCancelsAgainWithEsc() {
        var m = M()
        _ = m.handle(.resume(prefix: 4), now: 20)
        #expect(m.handle(.pttDown, now: 25).isEmpty, "not the key that locked it: waits for the release")
        #expect(m.handle(.pttUp, now: 25.125) == Self.cancelLimits + [.stopCaptureAndTranscribe(mode: .handsFree), .playSound(.stop)])

        var again = M()
        _ = again.handle(.resume(prefix: 4), now: 20)
        #expect(again.handle(.cancel, now: 22) == Self.cancelAll + [.cancelCapture(keepForUndo: true, notify: true), .playSound(.cancel)])
        #expect(again.handle(.resume(prefix: 6), now: 23).contains(.resumeCapture), "and Undo resumes it again")
    }

    @Test func resumedLimitIncludesTheKeptAudio() {
        var m = DictationMachine(config: .init(maxDuration: 300))
        #expect(m.handle(.resume(prefix: 280), now: 1000).suffix(2) == [.schedule(.limitWarning, after: 0), .schedule(.limit, after: 20)])
        var over = DictationMachine(config: .init(maxDuration: 300))
        #expect(over.handle(.resume(prefix: 400), now: 1000).suffix(2) == [.schedule(.limitWarning, after: 0), .schedule(.limit, after: 0)],
                "kept audio past a limit lowered since: stops and transcribes at once")
    }

    @Test func escWhileProcessingCancelsNewestJob() {
        var m = M()
        _ = m.handle(.jobStarted, now: 1)
        let effects = m.handle(.cancel, now: 2)
        #expect(effects == [.cancelNewestJob, .playSound(.cancel)])
        #expect(m.capture == .idle)
    }

    @Test func escWhenIdleWithoutJobsDoesNothing() {
        var m = M()
        #expect(m.handle(.cancel, now: 2).isEmpty)
        #expect(!m.isBusy)
    }

    @Test(arguments: ["listening", "locked", "lockedStopPending"])
    func limitWarningKeepsRecording(_ from: String) {
        var m = Self.state(from)
        let before = m.capture
        let effects = m.handle(.timer(.limitWarning), now: 1150)
        #expect(m.capture == before)
        #expect(effects == [.notice(.oneMinuteLeft)])
    }

    @Test(arguments: [("listening", DictationMachine.Mode.pushToTalk), ("locked", .handsFree), ("lockedStopPending", .handsFree)])
    func limitFinishesInTheCurrentMode(_ from: String, _ mode: DictationMachine.Mode) {
        var m = Self.state(from)
        let effects = m.handle(.timer(.limit), now: 1210)
        #expect(m.capture == .idle)
        #expect(effects == [.stopCaptureAndTranscribe(mode: mode), .notice(.limitReached)])
    }

    @Test(arguments: [("listening", DictationMachine.Mode.pushToTalk), ("locked", .handsFree), ("lockedStopPending", .handsFree)])
    func deviceLostTranscribesWhatWasSaid(_ from: String, _ mode: DictationMachine.Mode) {
        var m = Self.state(from)
        let effects = m.handle(.deviceLost, now: 50)
        #expect(m.capture == .idle)
        #expect(effects == Self.cancelLimits + [.stopCaptureAndTranscribe(mode: mode), .notice(.deviceLostTranscribing)])
    }

    @Test func deviceLostWhileArmingIsSilent() {
        var m = Self.arming()
        let effects = m.handle(.deviceLost, now: 10.0625)
        #expect(m.capture == .idle)
        #expect(effects == [.cancelTimer(.arming), .cancelCapture(keepForUndo: false, notify: false)])
    }

    @Test(arguments: ["arming", "listening", "locked", "lockedStopPending"])
    func captureFailureResetsAndReports(_ from: String) {
        var m = Self.state(from)
        let error = AppError.microphoneNotResponding("HAL error")
        let effects = m.handle(.captureFailed(error), now: 40)
        #expect(m.capture == .idle)
        #expect(effects == Self.cancelAll + [.cancelCapture(keepForUndo: false, notify: false), .showPill(.rest),
                                             .notice(.captureFailed(error))])
    }

    @Test(arguments: ["idle", "arming", "listening", "locked", "lockedStopPending", "tapPending"])
    func jobBookkeepingInAnyState(_ from: String) {
        var m = Self.state(from)
        let before = m.capture
        #expect(m.handle(.jobStarted, now: 1).isEmpty)
        #expect(m.handle(.jobStarted, now: 1).isEmpty)
        #expect(m.activeJobs == 2)
        #expect(m.isBusy)
        _ = m.handle(.jobEnded, now: 1)
        _ = m.handle(.jobEnded, now: 1)
        _ = m.handle(.jobEnded, now: 1)
        #expect(m.activeJobs == 0)
        #expect(m.capture == before)
        #expect(m.isBusy == m.isRecording)
    }

    @Test(arguments: [
        ("idle", DictationMachine.Input.pttUp), ("idle", .pttInterrupted), ("idle", .timer(.arming)),
        ("idle", .timer(.limit)), ("idle", .deviceLost), ("idle", .pillStop), ("idle", .pillCancel),
        ("arming", .pttDown), ("arming", .pillClick), ("arming", .timer(.limit)),
        ("listening", .pttDown), ("listening", .pillClick), ("listening", .pillStop), ("listening", .timer(.arming)),
        ("locked", .pillClick), ("locked", .pttInterrupted), ("locked", .timer(.doublePressWindow)),
        ("lockedStopPending", .pttDown), ("lockedStopPending", .pillClick),
        ("tapPending", .pttUp), ("tapPending", .cancel), ("tapPending", .deviceLost), ("tapPending", .timer(.arming)),
    ])
    func unlistedInputsAreNoOps(_ from: String, _ input: DictationMachine.Input) {
        var m = Self.state(from)
        let before = m
        #expect(m.handle(input, now: 60).isEmpty)
        #expect(m == before)
    }

    // MARK: Sequences

    @Test func fnSpaceFromIdleLocksThenFnTapStops() {
        var m = M()
        #expect(m.handle(.pttDown, now: 10) == [.startCapture, .schedule(.arming, after: 0.12)])
        let lock = m.handle(.handsFreeToggle, now: 10.0625)
        #expect(lock.contains(.playSound(.lock)))
        #expect(!lock.contains(.startCapture), "the mic is already live since key-down")
        #expect(m.handle(.pttUp, now: 10.25).isEmpty)
        #expect(m.capture == .locked(startedAt: 10))
        #expect(m.handle(.pttDown, now: 15).isEmpty)
        let stop = m.handle(.pttUp, now: 15.125)
        #expect(stop.contains(.stopCaptureAndTranscribe(mode: .handsFree)))
        #expect(m.capture == .idle)
    }

    @Test func spaceWhileHoldingMorphsWithoutAGap() {
        var m = Self.listening()
        let effects = m.handle(.handsFreeToggle, now: 12)
        #expect(!effects.contains(.startCapture) && !effects.contains(where: {
            if case .cancelCapture = $0 { true } else { false }
        }))
        #expect(m.handle(.pttUp, now: 12.5).isEmpty)
        #expect(m.capture == .locked(startedAt: Self.t0))
    }

    @Test func doublePressThenReleaseStaysLocked() {
        var m = M()
        _ = m.handle(.pttDown, now: 10)
        _ = m.handle(.pttUp, now: 10.0625)
        let second = m.handle(.pttDown, now: 10.3125)
        #expect(second.contains(.startCapture))
        #expect(m.handle(.pttUp, now: 10.375).isEmpty)
        #expect(m.capture == .locked(startedAt: 10.3125))
    }

    @Test func fnTapThenFnSpaceLocksOnce() {
        // A quick fn tap, then fn+Space within the double-press window: the router reports the press
        // before it knows Space follows, so the lock comes first and Space only confirms it.
        var m = Self.tapPending()
        let lock = m.handle(.pttDown, now: 10.25)
        #expect(m.capture == .locked(startedAt: 10.25))
        #expect(lock.contains(.startCapture))
        #expect(m.handle(.handsFreeToggle, now: 10.375).isEmpty)
        #expect(m.capture == .locked(startedAt: 10.25))
        // The chord consumed fn's release; the next fn+Space stops as usual.
        #expect(m.handle(.handsFreeToggle, now: 20).contains(.stopCaptureAndTranscribe(mode: .handsFree)))
    }

    @Test func doublePressHeldThenReleasedStopsOnTheNextToggle() {
        var m = Self.tapPending()
        _ = m.handle(.pttDown, now: 10.25)
        #expect(m.handle(.pttUp, now: 10.5).isEmpty)
        #expect(!m.lockingPressHeld)
        #expect(m.handle(.handsFreeToggle, now: 20).contains(.stopCaptureAndTranscribe(mode: .handsFree)))
    }

    @Test func fnArrowWhileLockedKeepsRecordingThenStops() {
        var m = Self.locked()
        _ = m.handle(.pttDown, now: 20)
        _ = m.handle(.pttInterrupted, now: 20.1)
        #expect(m.capture == .locked(startedAt: Self.t0))
        #expect(m.handle(.pttUp, now: 20.3).isEmpty)
        #expect(m.isRecording)
        let stop = m.handle(.handsFreeToggle, now: 25)
        #expect(stop.contains(.stopCaptureAndTranscribe(mode: .handsFree)))
    }

    @Test func escDuringProcessingThenJobSettles() {
        var m = Self.listening()
        _ = m.handle(.pttUp, now: 12)
        _ = m.handle(.jobStarted, now: 12)
        #expect(m.isBusy && !m.isRecording)
        #expect(m.handle(.cancel, now: 12.5) == [.cancelNewestJob, .playSound(.cancel)])
        _ = m.handle(.jobEnded, now: 12.5)
        #expect(!m.isBusy)
    }

    @Test func newRecordingWhileAJobRuns() {
        var m = Self.listening()
        _ = m.handle(.pttUp, now: 12)
        _ = m.handle(.jobStarted, now: 12)
        #expect(m.handle(.pttDown, now: 13) == [.startCapture, .schedule(.arming, after: 0.12)])
        #expect(m.activeJobs == 1 && m.isRecording)
    }

    @Test func limitWarningThenLimitInHandsFree() {
        var m = Self.locked()
        #expect(m.handle(.timer(.limitWarning), now: 1150) == [.notice(.oneMinuteLeft)])
        #expect(m.isRecording)
        #expect(m.handle(.timer(.limit), now: 1210) == [.stopCaptureAndTranscribe(mode: .handsFree), .notice(.limitReached)])
        #expect(m.handle(.timer(.limit), now: 1211).isEmpty, "a stale limit timer is ignored")
    }

    @Test func limitsFollowTheConfiguredMaximum() {
        var m = DictationMachine(config: .init(maxDuration: 300))
        let effects = m.handle(.handsFreeToggle, now: 0)
        #expect(effects.suffix(2) == [.schedule(.limitWarning, after: 240), .schedule(.limit, after: 300)])
    }

    @Test func deviceLostMidHandsFreeKeepsAudio() {
        var m = Self.locked()
        let effects = m.handle(.deviceLost, now: 100)
        #expect(effects.contains(.stopCaptureAndTranscribe(mode: .handsFree)))
        #expect(!effects.contains(where: { if case .cancelCapture = $0 { true } else { false } }))
    }
}

// MARK: - History

@Suite struct HistoryStatsTests {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Wednesday, 2026-09-23 15:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_790_175_600)

    static func entry(daysAgo: Double, words: Int, audio: TimeInterval, voiced: TimeInterval,
                      status: TranscriptStatus = .success) -> TranscriptEntry {
        TranscriptEntry(createdAt: now.addingTimeInterval(-daysAgo * 86_400),
                        text: status == .success ? Array(repeating: "word", count: words).joined(separator: " ") : "",
                        engine: .parakeet, status: status, audioDuration: audio, voicedSeconds: voiced)
    }

    @Test func emptyHistory() {
        let stats = HistoryStats.compute([], now: Self.now, calendar: Self.calendar)
        #expect(stats == .empty)
    }

    @Test func dailyWordsAreOldestFirstAndOnlyTheLastSevenDays() {
        let entries = [
            Self.entry(daysAgo: 0, words: 10, audio: 5, voiced: 4),
            Self.entry(daysAgo: 0.2, words: 5, audio: 3, voiced: 2),
            Self.entry(daysAgo: 1, words: 20, audio: 8, voiced: 6),
            Self.entry(daysAgo: 6, words: 7, audio: 4, voiced: 3),
            Self.entry(daysAgo: 7, words: 100, audio: 40, voiced: 30),
        ]
        let stats = HistoryStats.compute(entries, now: Self.now, calendar: Self.calendar)
        #expect(stats.dailyWords == [7, 0, 0, 0, 0, 20, 15])
        #expect(stats.wordsThisWeek == 42)
        #expect(stats.totalDictations == 5)
    }

    @Test func failedAndCanceledEntriesDontCount() {
        let entries = [
            Self.entry(daysAgo: 0, words: 30, audio: 10, voiced: 9),
            Self.entry(daysAgo: 0, words: 0, audio: 20, voiced: 18, status: .failed),
            Self.entry(daysAgo: 0, words: 0, audio: 20, voiced: 18, status: .cancelled),
        ]
        let stats = HistoryStats.compute(entries, now: Self.now, calendar: Self.calendar)
        #expect(stats.totalDictations == 1)
        #expect(stats.wordsThisWeek == 30)
        #expect(stats.averageWPM == 200)
    }

    @Test func speedIsWordsPerMinuteOfSpeech() {
        // 300 words over 120 s of voiced speech = 150 wpm.
        let entries = [Self.entry(daysAgo: 0, words: 180, audio: 80, voiced: 72),
                       Self.entry(daysAgo: 2, words: 120, audio: 55, voiced: 48)]
        let stats = HistoryStats.compute(entries, now: Self.now, calendar: Self.calendar)
        #expect(stats.averageWPM == 150)
    }

    @Test func speedNeedsAFewSecondsOfSpeech() {
        let stats = HistoryStats.compute([Self.entry(daysAgo: 0, words: 3, audio: 2, voiced: 1.5)],
                                         now: Self.now, calendar: Self.calendar)
        #expect(stats.averageWPM == nil)
    }

    @Test func timeSavedComparesWithTypingAt40WPM() {
        // 400 words take 10 min to type; speaking took 150 s -> 450 s saved.
        let entries = [Self.entry(daysAgo: 1, words: 400, audio: 150, voiced: 130)]
        let stats = HistoryStats.compute(entries, now: Self.now, calendar: Self.calendar)
        #expect(stats.timeSavedSeconds == 450)
    }

    @Test func timeSavedNeverGoesNegative() {
        let entries = [Self.entry(daysAgo: 1, words: 4, audio: 60, voiced: 5)]
        #expect(HistoryStats.compute(entries, now: Self.now, calendar: Self.calendar).timeSavedSeconds == 0)
    }

    @Test func wordCountIgnoresPunctuationOnlyTokens() {
        #expect(TranscriptEntry.countWords("Hello — world …  and\nmore") == 4)
        #expect(TranscriptEntry.countWords("Привет, как дела?") == 3)
        #expect(TranscriptEntry.countWords("   ") == 0)
    }
}

@MainActor
@Suite struct HistoryStoreTests {
    @Test func upsertKeepsNewestFirstAndReplacesInPlace() {
        let store = HistoryStore.preview(entries: [])
        let now = Date()
        let older = TranscriptEntry(createdAt: now.addingTimeInterval(-60), text: "older", engine: .parakeet,
                                    audioDuration: 1, voicedSeconds: 1)
        let newer = TranscriptEntry(createdAt: now, text: "newer", engine: .geminiPro, audioDuration: 1, voicedSeconds: 1)
        store.upsert(newer)
        store.upsert(older)
        #expect(store.entries.map(\.text) == ["newer", "older"])
        var updated = older
        updated.text = "older, retried"
        store.upsert(updated)
        #expect(store.entries.map(\.text) == ["newer", "older, retried"])
        #expect(store.lastSuccessfulText == "newer")
    }

    @Test func lastSuccessfulTextSkipsFailures() {
        let store = HistoryStore.preview(entries: [
            TranscriptEntry(createdAt: Date(), text: "", engine: .geminiPro, status: .failed, audioDuration: 3, voicedSeconds: 2),
            TranscriptEntry(createdAt: Date().addingTimeInterval(-10), text: "keep me", engine: .parakeet,
                            audioDuration: 3, voicedSeconds: 2),
        ])
        #expect(store.lastSuccessfulText == "keep me")
    }

    @Test func historyIsCappedAt2000() {
        let store = HistoryStore.preview(entries: [])
        let base = Date()
        for i in 0..<(HistoryStore.maxEntries + 5) {
            store.upsert(TranscriptEntry(createdAt: base.addingTimeInterval(Double(i)), text: "n\(i)", engine: .parakeet,
                                         audioDuration: 1, voicedSeconds: 1))
        }
        #expect(store.entries.count == HistoryStore.maxEntries)
        #expect(store.entries.first?.text == "n\(HistoryStore.maxEntries + 4)")
    }

    @Test func pruneDropsOldAudioReferences() {
        let now = Date()
        let store = HistoryStore.preview(entries: [
            TranscriptEntry(createdAt: now.addingTimeInterval(-20 * 86_400), text: "", engine: .parakeet, status: .failed,
                            audioDuration: 3, voicedSeconds: 2, audioFileName: "old.wav"),
            TranscriptEntry(createdAt: now.addingTimeInterval(-2 * 86_400), text: "", engine: .parakeet, status: .failed,
                            audioDuration: 3, voicedSeconds: 2, audioFileName: "recent.wav"),
        ])
        store.pruneOldRecordings(now: now)
        #expect(store.entries.map(\.audioFileName) == [.some("recent.wav"), nil])
    }

    @Test func persistsAndReloads() async throws {
        let paths = AppPaths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let settings = AppSettings.inMemory()
        let store = HistoryStore(paths: paths, settings: settings)
        store.load()
        try await waitUntil { store.isLoaded }
        let entry = TranscriptEntry(createdAt: Date(timeIntervalSince1970: 1_790_000_000.25), text: "Привет, world",
                                    engine: .geminiFlash, audioDuration: 4.5, voicedSeconds: 3.25,
                                    processingTime: 1.5, costUSD: 0.0012)
        store.upsert(entry)
        store.flush()

        let reloaded = HistoryStore(paths: paths, settings: settings)
        reloaded.load()
        try await waitUntil { reloaded.isLoaded }
        #expect(reloaded.entries == [entry])
    }

    @Test func unreadableFileIsKeptAside() async throws {
        let paths = AppPaths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: paths.historyFile)
        let store = HistoryStore(paths: paths, settings: .inMemory())
        store.load()
        try await waitUntil { store.isLoaded }
        #expect(store.entries.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
        #expect(files.contains { $0.hasPrefix("history-unreadable-") })
    }
}

// MARK: - DictationController: FIFO jobs, pre-flight, refusals

@MainActor
final class FakeRecorder: DictationRecorder {
    var isCapturing = false
    var starts = 0
    /// The recording the last successful start continued (Undo), if any.
    var lastPrefix: Recording?
    /// Thrown by the next starts (a mic that can't start).
    var startError: AppError?
    /// What the capture in progress records; a start that continues a recording puts that one first.
    var next = Recording(samples: Array(repeating: 0.1, count: 16_000 * 2),
                         speech: SpeechStats(voicedSeconds: 1.5, peakDBFS: -12, isSilent: false))
    private var prefix: Recording?

    func start(preferredDeviceUID: String?, continuing prefix: Recording?) throws {
        if let startError { throw startError }
        starts += 1
        isCapturing = true
        self.prefix = prefix
        lastPrefix = prefix
    }

    func finish(tail: TimeInterval) async -> Recording {
        isCapturing = false
        defer { next = Recording(samples: next.samples, speech: next.speech) }
        return take()
    }

    func cancel() -> Recording? {
        isCapturing = false
        return take()
    }

    private func take() -> Recording {
        let recording = AudioRecorder.joined(prefix, next)
        prefix = nil
        return recording
    }

    func duckRecording(from: TimeInterval, duration: TimeInterval) {}
}

@MainActor
@Suite(.serialized) struct DictationControllerTests {
    struct Harness {
        let controller: DictationController
        let recorder: FakeRecorder
        let history: HistoryStore
        let toasts: ToastCenter
        let settings: AppSettings
        let pill: PillModel
        let hotkeys: HotkeyMonitor
    }

    static func make(models: [EngineID: LocalModelState] = [.parakeet: .ready],
                     modelErrors: [EngineID: AppError] = [:], store: ModelStore? = nil,
                     mic: PermissionState = .granted, micLive: Bool = false, keyStatus: KeyStatus = .missing) -> Harness {
        let settings = AppSettings.inMemory()
        let meter = LevelMeter.preview(level: 0)
        let devices = AudioDeviceCatalog.preview()
        let store = store ?? ModelStore.preview(states: models, lastErrors: modelErrors)
        let account = OpenRouterAccount.preview(status: keyStatus)
        let client = OpenRouterClient()
        let history = HistoryStore.preview(entries: [])
        let toasts = ToastCenter()
        let pill = PillModel(settings: settings, levelMeter: meter)
        let hotkeys = HotkeyMonitor.preview()
        let controller = DictationController(
            settings: settings, recorder: AudioRecorder(levelMeter: meter, devices: devices),
            transcription: TranscriptionService(models: store, account: account, client: client, settings: settings),
            models: store, account: account, history: history, inserter: TextInserter(settings: settings),
            hotkeys: hotkeys, permissions: .preview(mic: mic, ax: .granted), sounds: SoundPlayer(settings: settings),
            pillModel: pill, toasts: toasts)
        let recorder = FakeRecorder()
        controller.captureDevice = recorder
        controller.copyOverride = { _ in }
        controller.microphoneAuthorizedNow = { micLive }
        return Harness(controller: controller, recorder: recorder, history: history, toasts: toasts,
                       settings: settings, pill: pill, hotkeys: hotkeys)
    }

    static func recording() -> Recording {
        Recording(samples: Array(repeating: 0.1, count: 16_000), speech: SpeechStats(voicedSeconds: 1, peakDBFS: -10, isSilent: false))
    }

    @Test func resultsArePastedInRecordingOrderEvenWhenTheyFinishOutOfOrder() async throws {
        let h = Self.make()
        let first = Self.recording(), second = Self.recording(), third = Self.recording()
        let delays: [UUID: Int] = [first.id: 300, second.id: 20, third.id: 120]
        let texts: [UUID: String] = [first.id: "first", second.id: "second", third.id: "third"]
        var pasted: [String] = []
        h.controller.transcribeOverride = { recording, engine in
            try await Task.sleep(for: .milliseconds(delays[recording.id] ?? 0))
            return TranscriptResult(text: " \(texts[recording.id] ?? "?") ", engine: engine, processingTime: 0.1)
        }
        h.controller.insertOverride = { text, _ in
            pasted.append(text)
            return .pasted
        }
        for r in [first, second, third] {
            h.controller.enqueue(r, engine: .parakeet, delivery: .paste(targetPID: nil))
        }
        #expect(h.controller.machine.activeJobs == 3)
        #expect(h.pill.phase == .processing)
        try await waitUntil { pasted.count == 3 }
        #expect(pasted == ["first", "second", "third"])
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(h.history.entries.count == 3)
        #expect(h.history.entries.allSatisfy { $0.status == .success })
    }

    @Test func aFailureInTheMiddleDoesntBlockTheQueue() async throws {
        let h = Self.make()
        let a = Self.recording(), b = Self.recording(), c = Self.recording()
        var pasted: [String] = []
        h.controller.transcribeOverride = { recording, engine in
            if recording.id == b.id { throw AppError.timeout(engine) }
            try await Task.sleep(for: .milliseconds(recording.id == a.id ? 150 : 10))
            return TranscriptResult(text: recording.id == a.id ? "a" : "c", engine: engine, processingTime: 0.1)
        }
        h.controller.insertOverride = { text, _ in
            pasted.append(text)
            return .pasted
        }
        for r in [a, b, c] { h.controller.enqueue(r, engine: .geminiFlash, delivery: .paste(targetPID: nil)) }
        try await waitUntil { pasted.count == 2 && h.controller.machine.activeJobs == 0 }
        #expect(pasted == ["a", "c"])
        let failed = try #require(h.history.entry(id: b.id))
        #expect(failed.status == .failed)
        #expect(failed.errorMessage == "Gemini Flash took too long")
        let notice = try #require(h.toasts.notices.first { $0.recordingID == b.id })
        #expect(notice.actions.first?.kind == .retry)
        #expect(notice.actions.contains { $0.kind == .retryWith(.parakeet) })
    }

    /// An engine that answers with no text heard no speech: exactly what a speechless recording gets before any
    /// engine (the quiet notice and the pill's shake), and nothing is kept.
    @Test func emptyTextIsSilenceNotAnError() async throws {
        let preflight = Self.make()
        preflight.recorder.next = Recording(samples: Array(repeating: 0.01, count: 32_000),
                                            speech: SpeechStats(voicedSeconds: 0.1, peakDBFS: -40, isSilent: false))
        preflight.controller.send(.handsFreeToggle)
        preflight.controller.send(.pillStop)
        try await waitUntil { preflight.controller.machine.activeJobs == 0 && !preflight.toasts.notices.isEmpty }
        let expected = try #require(preflight.toasts.notices.first)
        #expect(preflight.pill.visiblePhase == .error)

        for engine in [EngineID.parakeet, .parakeetCloud, .geminiFlash, .geminiPro] {
            let h = Self.make(keyStatus: .valid(KeyInfo()))
            h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "  \n", engine: engine, processingTime: 0.1) }
            h.controller.insertOverride = { _, _ in Issue.record("nothing should be pasted"); return .pasted }
            let r = Self.recording()
            h.controller.enqueue(r, engine: engine, delivery: .paste(targetPID: nil))
            try await waitUntil { h.controller.machine.activeJobs == 0 }
            #expect(h.history.entries.isEmpty, "\(engine): silence leaves no history entry")
            #expect(h.toasts.notices.count == 1)
            let notice = try #require(h.toasts.notices.first)
            #expect(notice.dedupeKey == expected.dedupeKey && notice.title == expected.title && notice.body == expected.body)
            #expect(notice.style == .info && notice.sound == nil && notice.lifetime == expected.lifetime)
            #expect(notice.actions.isEmpty && notice.recordingID == nil, "no Retry")
            #expect(h.pill.visiblePhase == .error, "the same shake as a recording with no speech")

            // No audio was kept: a Retry for it finds nothing.
            h.controller.perform(NoticeAction(title: "Retry", kind: .retry),
                                 from: Notice(dedupeKey: "test", style: .error, symbol: "x", title: "x", recordingID: r.id))
            #expect(h.toasts.notices.contains { $0.dedupeKey == "recording.gone" })
        }
    }

    /// An engine error is still an error: kept for Retry, in history, with its own notice.
    @Test func anEngineErrorIsNotTakenForSilence() async throws {
        let h = Self.make()
        h.controller.transcribeOverride = { _, engine in throw AppError.engineFailed(engine, "CoreML error") }
        let r = Self.recording()
        h.controller.enqueue(r, engine: .parakeet, delivery: .paste(targetPID: nil))
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(h.history.entry(id: r.id)?.status == .failed)
        let notice = try #require(h.toasts.notices.first { $0.dedupeKey == "error.engineFailed.parakeet" })
        #expect(notice.actions.first?.kind == .retry)
        #expect(!h.toasts.notices.contains { $0.dedupeKey == "error.noSpeech" })
    }

    /// Engine silence and speechless recordings share the day's three quiet notices; the shake always comes.
    @Test func engineSilenceSharesTheNoSpeechQuota() async throws {
        let h = Self.make()
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "", engine: engine, processingTime: 0.1) }
        var shown: [Bool] = []
        for _ in 0..<4 {
            h.toasts.dismissAll()
            h.controller.enqueue(Self.recording(), engine: .parakeet, delivery: .paste(targetPID: nil))
            try await waitUntil { h.controller.machine.activeJobs == 0 }
            shown.append(h.toasts.notices.contains { $0.dedupeKey == "error.noSpeech" })
        }
        #expect(shown == [true, true, true, false])
        #expect(h.history.entries.isEmpty)
    }

    @Test func noEditableTargetShowsTheTranscriptCard() async throws {
        let h = Self.make()
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "Hello there", engine: engine, processingTime: 0.1) }
        h.controller.insertOverride = { _, _ in .targetChanged }
        h.controller.enqueue(Self.recording(), engine: .parakeet, delivery: .paste(targetPID: 42))
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        let card = try #require(h.toasts.notices.first { $0.transcript != nil })
        #expect(card.transcript == "Hello there")
        #expect(card.actions.map(\.kind) == [.pasteText("Hello there"), .copyText("Hello there")])
        #expect(h.history.entries.first?.text == "Hello there")
    }

    @Test func pushToTalkEndToEnd() async throws {
        let h = Self.make()
        var pasted: [String] = []
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "dictated", engine: engine, processingTime: 0.2) }
        h.controller.insertOverride = { text, _ in pasted.append(text); return .pasted }
        var now: TimeInterval = 100
        h.controller.clock = { now }
        h.controller.handle(.pttDown)
        #expect(h.recorder.starts == 1)
        #expect(h.pill.phase != .listening, "the pill waits for the arming delay")
        h.controller.send(.timer(.arming))
        #expect(h.pill.phase == .listening)
        now = 102
        h.controller.handle(.pttUp)
        #expect(!h.recorder.isCapturing)
        #expect(h.pill.phase == .processing)
        try await waitUntil { pasted == ["dictated"] }
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(h.history.entries.first?.status == .success)
    }

    @Test func silentRecordingIsRejectedBeforeTranscription() async throws {
        let h = Self.make()
        h.recorder.next = Recording(samples: Array(repeating: 0, count: 32_000), speech: .empty)
        h.controller.transcribeOverride = { _, _ in Issue.record("must not transcribe"); throw AppError.noSpeech }
        h.controller.send(.handsFreeToggle)
        h.controller.send(.pillStop)
        try await waitUntil { h.controller.machine.activeJobs == 0 && !h.toasts.notices.isEmpty }
        #expect(h.toasts.notices.contains { $0.dedupeKey == "error.microphoneSilent" })
        #expect(h.history.entries.isEmpty)
        #expect(h.pill.visiblePhase == .error)
    }

    @Test func speechlessRecordingShowsNoSpeechAndNoHistory() async throws {
        let h = Self.make()
        h.recorder.next = Recording(samples: Array(repeating: 0.01, count: 32_000),
                                    speech: SpeechStats(voicedSeconds: 0.1, peakDBFS: -40, isSilent: false))
        h.controller.send(.handsFreeToggle)
        h.controller.send(.pillStop)
        try await waitUntil { h.controller.machine.activeJobs == 0 && !h.toasts.notices.isEmpty }
        #expect(h.toasts.notices.contains { $0.dedupeKey == "error.noSpeech" })
        #expect(h.history.entries.isEmpty)
    }

    @Test func missingModelRefusesHandsFreeImmediately() {
        let h = Self.make(models: [.parakeet: .notInstalled], keyStatus: .valid(KeyInfo()))
        h.controller.send(.handsFreeToggle)
        #expect(h.recorder.starts == 0)
        #expect(h.controller.machine.capture == .idle)
        let notice = h.toasts.notices.first
        #expect(notice?.dedupeKey == "error.modelNotDownloaded.parakeet")
        #expect(notice?.actions.map(\.kind) == [.download(.parakeet), .selectEngine(.parakeetCloud)],
                "the same model through OpenRouter, the key works")
        #expect(h.pill.visiblePhase == .error)

        let keyless = Self.make(models: [.parakeet: .notInstalled])
        keyless.controller.send(.handsFreeToggle)
        #expect(keyless.toasts.notices.first?.actions.map(\.kind) == [.download(.parakeet), .openHub(.models)])
    }

    @Test func fallbacksPairParakeetOnThisMacWithParakeetInTheCloud() {
        #expect(DictationController.fallbackCandidates(for: .parakeet) == [.parakeetCloud])
        #expect(DictationController.fallbackCandidates(for: .parakeetCloud) == [.parakeet])
        #expect(DictationController.fallbackCandidates(for: .geminiFlash) == [.parakeet, .parakeetCloud])
        #expect(DictationController.fallbackCandidates(for: .geminiPro) == [.parakeet, .parakeetCloud])
    }

    @Test func aFailedLocalDictationOffersParakeetInTheCloudOnlyWithAWorkingKey() async throws {
        for (key, expected) in [(KeyStatus.valid(KeyInfo()), true), (.missing, false), (.invalid("401"), false)] {
            let h = Self.make(models: [.parakeet: .ready], keyStatus: key)
            h.controller.transcribeOverride = { _, engine in throw AppError.engineFailed(engine, "CoreML error") }
            let r = Self.recording()
            h.controller.enqueue(r, engine: .parakeet, delivery: .paste(targetPID: nil))
            try await waitUntil { h.controller.machine.activeJobs == 0 }
            let notice = try #require(h.toasts.notices.first { $0.recordingID == r.id })
            #expect(notice.actions.contains { $0.kind == .retryWith(.parakeetCloud) } == expected, "\(key)")
        }
    }

    @Test func aFailedGeminiDictationFallsBackToParakeetHereThenInTheCloud() async throws {
        func fallback(local: LocalModelState, error: AppError) async throws -> EngineID? {
            let h = Self.make(models: [.parakeet: local], keyStatus: .valid(KeyInfo()))
            h.controller.transcribeOverride = { _, _ in throw error }
            let r = Self.recording()
            h.controller.enqueue(r, engine: .geminiFlash, delivery: .paste(targetPID: nil))
            try await waitUntil { h.controller.machine.activeJobs == 0 }
            let notice = try #require(h.toasts.notices.first { $0.recordingID == r.id })
            return notice.actions.lazy.compactMap { if case .retryWith(let e) = $0.kind { e } else { nil } }.first
        }
        let limited = AppError.openRouterRateLimited(retryAfter: nil)
        #expect(try await fallback(local: .ready, error: limited) == .parakeet, "loaded on this Mac comes first")
        #expect(try await fallback(local: .notInstalled, error: limited) == .parakeetCloud)
        #expect(try await fallback(local: .installed, error: limited) == .parakeetCloud,
                "a model that still has to load waits behind a key that works now")
        #expect(try await fallback(local: .notInstalled, error: .openRouterNoCredits("")) == nil,
                "no credit stops every cloud model")
        #expect(try await fallback(local: .installed, error: .offline) == .parakeet)
    }

    @Test func refusalWhileArmingStaysSilentForFnCombos() {
        let h = Self.make(mic: .denied)
        h.controller.handle(.pttDown)
        h.controller.handle(.pttInterrupted)
        #expect(h.toasts.notices.isEmpty)
        #expect(h.recorder.starts == 0)
        h.controller.handle(.pttDown)
        h.controller.send(.timer(.arming))
        #expect(h.controller.machine.capture == .idle)
        #expect(h.toasts.notices.first?.dedupeKey == "error.microphonePermissionDenied")
    }

    @Test func micTurnedOnInSettingsIsNoticedAtTheNextPress() {
        // The cached state still says denied (nothing refreshed it while transcribe-thing stayed in the background).
        let h = Self.make(mic: .denied, micLive: true)
        h.controller.send(.handsFreeToggle)
        #expect(h.recorder.starts == 1)
        #expect(h.controller.machine.capture.isListeningOrLocked)
        #expect(h.toasts.notices.isEmpty)
    }

    @Test func failedDownloadKeepsItsOwnNotice() {
        let h = Self.make(models: [.parakeet: .failed("Download didn’t finish.")],
                          modelErrors: [.parakeet: .downloadFailed(.parakeet, "offline")])
        #expect(h.controller.captureRefusal() == .downloadFailed(.parakeet, "offline"))
        let noDisk = Self.make(models: [.parakeet: .failed("Not enough space.")],
                               modelErrors: [.parakeet: .notEnoughDisk(needed: 2, available: 1)])
        #expect(noDisk.controller.captureRefusal() == .notEnoughDisk(needed: 2, available: 1))
        let unknown = Self.make(models: [.parakeet: .failed("Couldn’t remove all model files.")])
        #expect(unknown.controller.captureRefusal() == .modelLoadFailed(.parakeet, "Couldn’t remove all model files."))
    }

    @Test func failedLoadStillRecordsSoTheJobCanLoadAgain() {
        // The files are complete: the job retries the load once and keeps the audio if that fails too.
        let h = Self.make(models: [.parakeet: .failed("Couldn’t load the model.")],
                          modelErrors: [.parakeet: .modelLoadFailed(.parakeet, "corrupt weights")])
        #expect(h.controller.captureRefusal() == nil)
    }

    @Test func modelsArentMissingBeforeTheFirstDiskScan() async throws {
        let settings = AppSettings.inMemory()
        let store = ModelStore(paths: .temporary(), settings: settings,
                               engines: [.parakeet: FakeEngine(.parakeet, installed: false)],
                               gate: InferenceGate(), freeDiskBytes: { 50_000_000_000 })
        let h = Self.make(store: store)
        #expect(h.controller.captureRefusal() == nil, "not known yet is not missing")
        await store.refreshFromDisk()
        #expect(h.controller.captureRefusal() == .modelNotDownloaded(.parakeet))
    }

    @Test func stoppedByOtherKeyNeverOffersAnOlderRecording() {
        let h = Self.make()
        var now: TimeInterval = 100
        h.controller.clock = { now }
        // An earlier cancel that was never undone stays retained.
        h.recorder.next = Recording(samples: Array(repeating: 0.1, count: 16_000 * 2),
                                    speech: SpeechStats(voicedSeconds: 1.5, peakDBFS: -12, isSilent: false))
        h.controller.send(.handsFreeToggle)
        h.controller.handle(.cancel)
        #expect(h.toasts.notices.contains { $0.title == "Dictation canceled" })
        h.toasts.dismissAll()

        // A slow mic captured only half a second of a 2 s hold before another key interrupted it.
        h.recorder.next = Recording(samples: Array(repeating: 0.1, count: 8_000),
                                    speech: SpeechStats(voicedSeconds: 0.4, peakDBFS: -12, isSilent: false))
        now = 200
        h.controller.handle(.pttDown)
        h.controller.send(.timer(.arming))
        now = 202
        h.controller.handle(.pttInterrupted)
        #expect(!h.toasts.notices.contains { $0.title == "Dictation stopped" })

        // Long enough to keep: the notice offers exactly this recording.
        let kept = Recording(samples: Array(repeating: 0.1, count: 16_000 * 2),
                             speech: SpeechStats(voicedSeconds: 1.5, peakDBFS: -12, isSilent: false))
        h.recorder.next = kept
        now = 300
        h.controller.handle(.pttDown)
        h.controller.send(.timer(.arming))
        now = 302
        h.controller.handle(.pttInterrupted)
        #expect(h.toasts.notices.first { $0.title == "Dictation stopped" }?.recordingID == kept.id)
    }

    @Test func retryOfAHubJobStaysInHistory() async throws {
        let h = Self.make()
        var fail = true
        var pasted: [String] = []
        h.controller.transcribeOverride = { _, engine in
            if fail { throw AppError.timeout(engine) }
            return TranscriptResult(text: "retried", engine: engine, processingTime: 0.1)
        }
        h.controller.insertOverride = { text, _ in pasted.append(text); return .pasted }
        let r = Self.recording()
        h.controller.enqueue(r, engine: .parakeet, delivery: .historyOnly)
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        let notice = try #require(h.toasts.notices.first { $0.recordingID == r.id })
        let retry = try #require(notice.actions.first { $0.kind == .retry })
        fail = false
        h.controller.perform(retry, from: notice)
        try await waitUntil { h.history.entry(id: r.id)?.status == .success }
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(pasted.isEmpty, "a Hub retry never pastes into whatever is frontmost")
        #expect(h.toasts.notices.contains { $0.dedupeKey == "retry.\(r.id)" })
    }

    @Test func theLimitIsFixedForTheRecordingInProgress() {
        let h = Self.make()
        h.controller.send(.handsFreeToggle)
        #expect(h.pill.limitSeconds == 1200)
        h.settings.maxRecordingMinutes = 5
        h.controller.send(.timer(.limitWarning))
        #expect(h.pill.limitSeconds == 1200)
        #expect(h.toasts.notices.first { $0.dedupeKey == "limit" }?.body == "Recording stops at 20 min and gets transcribed.")
        h.controller.send(.pillCancel)
        h.controller.send(.handsFreeToggle)
        #expect(h.pill.limitSeconds == 300, "the next recording uses the new limit")
        h.controller.send(.pillCancel)
    }

    @Test func geminiRecordingsStopWhileTheyStillFitInOneRequest() {
        let h = Self.make(keyStatus: .valid(KeyInfo()))
        h.settings.selectedEngine = .geminiFlash
        h.controller.send(.handsFreeToggle)
        #expect(h.controller.machine.capture.isListeningOrLocked)
        #expect(h.pill.limitSeconds == 420, "Gemini takes about 7.4 minutes per request, not the 20-minute setting")
        h.controller.send(.timer(.limitWarning))
        #expect(h.toasts.notices.first { $0.dedupeKey == "limit" }?.body == "Recording stops at 7 min and gets transcribed.")
        h.controller.send(.pillCancel)
        h.settings.maxRecordingMinutes = 5
        h.controller.send(.handsFreeToggle)
        #expect(h.pill.limitSeconds == 300, "a shorter setting still wins")
        h.controller.send(.pillCancel)
        #expect(OpenRouterClient.base64Length(ofByteCount: 44 + Int(OpenRouterClient.maxRecordingDuration) * 16_000 * 2)
            <= OpenRouterClient.maxBase64Bytes)
    }

    @Test func truncatedGeminiTextIsShownNotPasted() async throws {
        let h = Self.make(keyStatus: .valid(KeyInfo()))
        var pasted: [String] = []
        h.controller.transcribeOverride = { _, _ in throw AppError.openRouterTruncated("so the plan is so the plan is") }
        h.controller.insertOverride = { text, _ in pasted.append(text); return .pasted }
        let recording = Self.recording()
        h.controller.enqueue(recording, engine: .geminiFlash, delivery: .paste(targetPID: nil))
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(pasted.isEmpty)
        let notice = try #require(h.toasts.notices.first { $0.dedupeKey == "error.openRouterTruncated" })
        #expect(notice.transcript == "so the plan is so the plan is")
        #expect(notice.recordingID == recording.id)
        #expect(h.history.entry(id: recording.id)?.status == .failed)
    }

    @Test func escCancelsTheNewestJobAndOffersUndo() async throws {
        let h = Self.make()
        var pasted: [String] = []
        h.controller.transcribeOverride = { recording, engine in
            try await Task.sleep(for: .milliseconds(200))
            return TranscriptResult(text: "text", engine: engine, processingTime: 0.2)
        }
        h.controller.insertOverride = { text, _ in pasted.append(text); return .pasted }
        let long = Recording(samples: Array(repeating: 0.1, count: 16_000 * 3),
                             speech: SpeechStats(voicedSeconds: 2, peakDBFS: -10, isSilent: false))
        h.controller.enqueue(long, engine: .parakeet, delivery: .paste(targetPID: nil))
        h.controller.handle(.cancel)
        #expect(h.controller.machine.activeJobs == 0)
        let undo = try #require(h.toasts.notices.first { $0.dedupeKey == "dictation.canceled" })
        #expect(undo.recordingID == long.id)
        #expect(undo.actions.first?.kind == .undoCancel)
        try await Task.sleep(for: .milliseconds(300))
        #expect(pasted.isEmpty)

        // Undo records on, hands-free, after the kept audio; only stopping transcribes (and pastes) it all.
        h.controller.perform(undo.actions[0], from: undo)
        #expect(h.controller.machine.capture.isListeningOrLocked)
        #expect(h.recorder.lastPrefix?.id == long.id)
        try await Task.sleep(for: .milliseconds(300))
        #expect(pasted.isEmpty)
        h.controller.send(.pillStop)
        try await waitUntil { pasted == ["text"] }
    }

    @Test func cancelDuringRecordingKeepsAudioForUndo() {
        let h = Self.make()
        h.controller.send(.handsFreeToggle)
        #expect(h.recorder.isCapturing)
        h.controller.handle(.cancel)
        #expect(!h.recorder.isCapturing)
        #expect(h.toasts.notices.contains { $0.title == "Dictation canceled" })
        #expect(h.history.entries.isEmpty, "short cancellations stay out of history")
    }

    @Test func busyStateIsMirroredToTheHotkeyMonitor() {
        let h = Self.make()
        #expect(!h.hotkeys.isBusy)
        h.controller.send(.handsFreeToggle)
        #expect(h.hotkeys.isBusy)
        #expect(h.controller.activity == .recording)
        h.controller.send(.pillCancel)
        #expect(!h.hotkeys.isBusy)
        #expect(h.controller.activity == .idle)
    }

    @Test func pasteLastWithoutHistorySaysSo() {
        let h = Self.make()
        h.controller.pasteLast()
        #expect(h.toasts.notices.first?.title == "Nothing to paste yet")
    }

    /// Paste last is copy and paste in one: the inserter keeps it on the clipboard, so no copy or card here.
    @Test func pasteLastPastesTheLatestTranscript() async throws {
        let h = Self.make()
        h.history.upsert(TranscriptEntry(text: "last words", engine: .parakeet, audioDuration: 1, voicedSeconds: 1))
        var pasted: [String] = [], copied: [String] = []
        h.controller.pasteLastOverride = { text in
            pasted.append(text)
            return .pasted
        }
        h.controller.copyOverride = { copied.append($0) }
        h.controller.pasteLast()
        try await waitUntil { !pasted.isEmpty }
        #expect(pasted == ["last words"])
        #expect(copied.isEmpty)
        #expect(h.toasts.notices.isEmpty)
    }

    @Test(arguments: [(InsertionOutcome.noEditableTarget, "Nowhere to paste"), (.failed("no ⌘V"), "Couldn’t paste")])
    func pasteLastWithNowhereToPasteLeavesItOnTheClipboard(_ outcome: InsertionOutcome, _ title: String) async throws {
        let h = Self.make()
        h.history.upsert(TranscriptEntry(text: "last words", engine: .parakeet, audioDuration: 1, voicedSeconds: 1))
        var copied: [String] = []
        h.controller.pasteLastOverride = { _ in outcome }
        h.controller.copyOverride = { copied.append($0) }
        h.controller.pasteLast()
        try await waitUntil { !h.toasts.notices.isEmpty }
        #expect(copied == ["last words"])
        let notice = try #require(h.toasts.notices.first)
        #expect(notice.title == title)
        #expect(notice.body == "Your text is on the clipboard.")
        #expect(notice.transcript == nil, "a short notice, not a transcript card")
    }

    @Test func grantingTheMicDismissesTheStickyToast() throws {
        let h = Self.make(mic: .denied)
        h.controller.send(.handsFreeToggle)
        let sticky = try #require(h.toasts.notices.first { $0.dedupeKey == "error.microphonePermissionDenied" })
        #expect(sticky.lifetime == .sticky)
        // Turned on in System Settings; the cached state hasn't caught up yet.
        h.controller.microphoneAuthorizedNow = { true }
        h.controller.send(.handsFreeToggle)
        #expect(h.recorder.starts == 1)
        #expect(!h.toasts.notices.contains { $0.dedupeKey == "error.microphonePermissionDenied" })
        h.controller.send(.pillCancel)
    }

    @Test func failedCloudJobOffersADownloadedLocalModelThatIsntLoaded() async throws {
        // Gemini selected at launch: Parakeet is on disk but not loaded. Retrying with it loads it.
        let h = Self.make(models: [.parakeet: .installed], keyStatus: .valid(KeyInfo()))
        h.controller.transcribeOverride = { _, _ in throw AppError.offline }
        let r = Self.recording()
        h.controller.enqueue(r, engine: .geminiFlash, delivery: .paste(targetPID: nil))
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        let notice = try #require(h.toasts.notices.first { $0.recordingID == r.id })
        #expect(notice.actions.contains { $0.kind == .retryWith(.parakeet) })
    }

    @Test func pasteHereThatFailsBringsTheTextBack() async throws {
        let h = Self.make()
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "Hello there", engine: engine, processingTime: 0.1) }
        h.controller.insertOverride = { _, _ in .failed("no event source") }
        h.controller.enqueue(Self.recording(), engine: .parakeet, delivery: .paste(targetPID: nil))
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        let card = try #require(h.toasts.notices.first { $0.transcript == "Hello there" })
        let pasteHere = try #require(card.actions.first { $0.kind == .pasteText("Hello there") })

        h.controller.pasteNowOverride = { _ in .failed("no event source") }
        h.controller.perform(pasteHere, from: card)
        try await waitUntil { h.toasts.notices.contains { $0.transcript == "Hello there" && $0.id != card.id } }

        let again = try #require(h.toasts.notices.first { $0.transcript == "Hello there" })
        let retry = try #require(again.actions.first { $0.kind == .pasteText("Hello there") })
        h.controller.pasteNowOverride = { _ in .accessibilityMissing }
        h.controller.perform(retry, from: again)
        try await waitUntil { h.toasts.notices.contains { $0.dedupeKey == "error.accessibilityMissing" } }
        #expect(h.toasts.notices.first { $0.dedupeKey == "error.accessibilityMissing" }?.transcript == "Hello there")
    }

    @Test func shortcutDownForLongerThanTheGraceIsShown() async throws {
        let h = Self.make()
        h.settings.onboardingCompleted = true
        h.controller.shortcutNoticeGrace = .milliseconds(30)

        // A brief drop (the tap's own restart) stays quiet.
        h.controller.shortcutAvailabilityChanged(false)
        h.controller.shortcutAvailabilityChanged(true)
        try await Task.sleep(for: .milliseconds(80))
        #expect(!h.controller.isShortcutUnavailable)
        #expect(h.toasts.notices.isEmpty)

        h.controller.shortcutAvailabilityChanged(false)
        #expect(h.toasts.notices.isEmpty, "not before the grace period")
        try await waitUntil { h.controller.isShortcutUnavailable }
        let notice = try #require(h.toasts.notices.first { $0.dedupeKey == Notice.shortcutUnavailableKey })
        #expect(notice.lifetime == .sticky)
        #expect(notice.actions.first?.kind == .openSettingsPane(.accessibility))

        h.controller.shortcutAvailabilityChanged(true)
        #expect(!h.controller.isShortcutUnavailable)
        #expect(!h.toasts.notices.contains { $0.dedupeKey == Notice.shortcutUnavailableKey })
    }

    @Test func shortcutNoticeWaitsForOnboardingToFinish() async throws {
        let h = Self.make()
        h.controller.shortcutNoticeGrace = .milliseconds(10)
        h.controller.shortcutAvailabilityChanged(false)
        try await waitUntil { h.controller.isShortcutUnavailable }
        #expect(h.toasts.notices.isEmpty, "onboarding explains Accessibility itself")
    }

    @Test func shortcutNoticeCopyFollowsTheCause() {
        let off = Notice.shortcutUnavailable(accessibility: .denied, likelyStale: false, shortcut: "fn")
        #expect(off.title == "\(Brand.name) can’t hear your shortcut")
        #expect(off.actions.first?.title == "Allow Access")
        let stale = Notice.shortcutUnavailable(accessibility: .denied, likelyStale: true, shortcut: "fn")
        #expect(stale.title == "macOS needs to trust \(Brand.name) again")
        let dropped = Notice.shortcutUnavailable(accessibility: .granted, likelyStale: false, shortcut: "fn")
        #expect(dropped.body?.contains("stopped sending key presses") == true)
        #expect(dropped.actions.first?.title == "Open Settings")
    }
}

@Suite struct DailyQuotaTests {
    @Test func resetsEachDay() {
        var quota = DailyQuota(limit: 2)
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        let results = [quota.take(now: day), quota.take(now: day), quota.take(now: day),
                       quota.take(now: day.addingTimeInterval(86_400))]
        #expect(results == [true, true, false, true])
    }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now > deadline {
            Issue.record("Timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Menu

@MainActor
@Suite struct MenuBuilderTests {
    private static func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    /// No section is empty: separators only ever sit between items.
    private static func expectTidySeparators(_ menu: NSMenu, _ state: String) {
        let titles = titles(menu)
        #expect(titles.first != "—" && titles.last != "—", "\(state): \(titles)")
        #expect(!zip(titles, titles.dropFirst()).contains { $0 == "—" && $1 == "—" }, "\(state): \(titles)")
    }

    /// The preview environment with a capture that never touches the microphone.
    private static func dictatingEnvironment() -> AppEnvironment {
        let env = AppEnvironment.preview()
        env.dictation.captureDevice = FakeRecorder()
        env.dictation.microphoneAuthorizedNow = { true }
        return env
    }

    @Test func statusMenuFollowsTheSpecOrder() {
        let env = AppEnvironment.preview()
        let menu = env.menuBar.builder.makeMenu(includeQuit: true)
        #expect(Self.titles(menu) == [
            "Parakeet v3 · Ready", "—",
            "Paste Last Transcript", "—",
            "Model", "Microphone", "—",
            "Settings…", "—", "Quit",
        ])
        #expect(menu.items.first?.isEnabled == false)
    }

    @Test func pillMenuHasNoQuit() {
        let env = AppEnvironment.preview()
        let menu = env.menuBar.builder.makeMenu(includeQuit: false)
        #expect(!menu.items.contains { $0.title == "Quit" })
        #expect(menu.items.last?.title == "Settings…")
    }

    /// ⌘, and ⌘Q are gone (no quitting by accident), and paste last's ⌘ fn V can't be drawn faithfully.
    @Test func noMisleadingKeyEquivalents() throws {
        let env = AppEnvironment.preview()
        let menu = env.menuBar.builder.makeMenu(includeQuit: true)
        for title in ["Settings…", "Quit", "Paste Last Transcript"] {
            let item = try #require(menu.items.first { $0.title == title })
            #expect(item.keyEquivalent.isEmpty, "\(title)")
        }
        // A shortcut the menu can draw is shown.
        env.settings.shortcuts[.pasteLast] = Shortcut(modifiers: [.init(.control), .init(.command)], keyCode: KeyCode.ansiV)
        let paste = try #require(env.menuBar.builder.makeMenu(includeQuit: true).items.first { $0.title == "Paste Last Transcript" })
        #expect(paste.keyEquivalent == "v" && paste.keyEquivalentModifierMask == [.control, .command])
    }

    @Test func pasteLastIsDisabledWithoutHistory() throws {
        let env = AppEnvironment.preview()
        env.history.clearAll()
        let menu = env.menuBar.builder.makeMenu(includeQuit: true)
        let paste = try #require(menu.items.first { $0.title == "Paste Last Transcript" })
        #expect(!paste.isEnabled)
        Self.expectTidySeparators(menu, "no history")
    }

    @Test func holdingToTalkOffersCancel() throws {
        let env = Self.dictatingEnvironment()
        env.dictation.send(.pttDown)
        defer { env.dictation.send(.pillCancel) }
        // Still arming: the mic runs while the UI (and the status line) waits.
        #expect(env.dictation.machine.isRecording)
        let menu = env.menuBar.builder.makeMenu(includeQuit: true)
        #expect(Array(Self.titles(menu).dropFirst().prefix(4)) == [
            "—", "Cancel Dictation", "Paste Last Transcript", "—",
        ])
        let cancel = try #require(menu.items.first { $0.title == "Cancel Dictation" })
        #expect(cancel.keyEquivalent == "\u{1b}" && cancel.keyEquivalentModifierMask.isEmpty, "esc draws as ⎋")
        Self.expectTidySeparators(menu, "recording")
    }

    @Test func handsFreeOffersFinishAndCancel() throws {
        let env = Self.dictatingEnvironment()
        env.dictation.send(.handsFreeToggle)
        defer { env.dictation.send(.pillCancel) }
        for includeQuit in [true, false] {
            let menu = env.menuBar.builder.makeMenu(includeQuit: includeQuit)
            #expect(Array(Self.titles(menu).prefix(6)) == [
                "Parakeet v3 · Listening…", "—", "Finish Dictation", "Cancel Dictation", "Paste Last Transcript", "—",
            ])
            Self.expectTidySeparators(menu, "hands-free")
        }
        let finish = try #require(env.menuBar.builder.makeMenu(includeQuit: true).items.first { $0.title == "Finish Dictation" })
        #expect(finish.keyEquivalent.isEmpty, "fn Space has no faithful menu form")
    }

    @Test func updateItemAppearsOnlyWhileAnUpdateWaits() throws {
        let current = AppEnvironment.preview()
        #expect(!current.menuBar.builder.makeMenu(includeQuit: true).items.contains { $0.title.hasPrefix("Update") })
        #expect(!current.menuBar.builder.makeMenu(includeQuit: true).items.contains { $0.title.contains("Check for Updates") })

        // The preview runs 0.2.0; the full feed has 0.3.0.
        let env = AppEnvironment.preview(releases: PreviewFixtures.releases())
        for includeQuit in [true, false] {
            let menu = env.menuBar.builder.makeMenu(includeQuit: includeQuit)
            let titles = Self.titles(menu)
            let settings = try #require(titles.firstIndex(of: "Settings…"))
            #expect(titles[settings + 1] == "Update to 0.3.0…")
            Self.expectTidySeparators(menu, "update available")
        }
        let update = try #require(env.menuBar.builder.makeMenu(includeQuit: true).items.first { $0.title == "Update to 0.3.0…" })
        #expect(update.badge != nil)

        // Updates ignored: no item, no badge.
        env.settings.checkForUpdatesAutomatically = false
        #expect(!env.menuBar.builder.makeMenu(includeQuit: true).items.contains { $0.title.hasPrefix("Update") })
    }

    @Test func modelSubmenuMarksTheSelection() throws {
        let env = AppEnvironment.preview()
        let menu = env.menuBar.builder.makeMenu(includeQuit: true)
        let models = try #require(menu.items.first { $0.title == "Model" }?.submenu)
        let parakeet = try #require(models.items.first { $0.title == "Parakeet v3" })
        let flash = try #require(models.items.first { $0.title == "Gemini 3.8 Flash" })
        #expect(parakeet.state == .on && parakeet.isEnabled)
        #expect(flash.state == .off && flash.isEnabled, "the preview key is valid")
    }

    @Test func modelSubmenuGroupsThisMacThenOpenRouter() throws {
        let env = AppEnvironment.preview()
        let menu = env.menuBar.builder.makeMenu(includeQuit: true)
        let models = try #require(menu.items.first { $0.title == "Model" }?.submenu)
        // A status suffix follows the name after two spaces ("Parakeet v3  Not downloaded").
        #expect(models.items.map { $0.isSeparatorItem ? "—" : $0.title.components(separatedBy: "  ")[0] } == [
            "Parakeet v3", "—",
            "Parakeet v3 · Cloud", "Gemini 3.8 Flash", "Gemini 3.1 Pro", "—", "Manage Models…",
        ])
        let cloudEnabled = models.items.filter { $0.title.contains("· Cloud") }.map(\.isEnabled)
        #expect(cloudEnabled == [true], "the preview key is valid")
    }

    @Test func cloudModelsNeedTheKey() throws {
        let env = AppEnvironment.preview()
        env.account.removeKey()
        let menu = env.menuBar.builder.makeMenu(includeQuit: true)
        let models = try #require(menu.items.first { $0.title == "Model" }?.submenu)
        for engine in EngineID.cloudEngines {
            let item = try #require(models.items.first { $0.title.hasPrefix(engine.displayName + "  ") })
            #expect(!item.isEnabled)
            #expect(item.attributedTitle?.string == "\(engine.displayName)  Needs key")
        }
    }

    @Test func shortcutHintsBecomeKeyEquivalents() throws {
        let controlCommandV = Shortcut(modifiers: [.init(.control), .init(.command)], keyCode: KeyCode.ansiV)
        let paste = try #require(MenuActionItem.keyEquivalent(for: controlCommandV))
        #expect(paste.key == "v")
        #expect(paste.modifiers == [.control, .command])
        let escape = try #require(MenuActionItem.keyEquivalent(for: .escape))
        #expect(escape.key == "\u{1b}" && escape.modifiers.isEmpty)
        #expect(MenuActionItem.keyEquivalent(for: .fn) == nil, "modifier-only shortcuts have no menu form")
    }

    /// The menu drops fn and sides: ⌘ fn V would read as a plain ⌘V, so no hint beats a wrong one.
    @Test func unfaithfulShortcutsGetNoHint() {
        #expect(MenuActionItem.keyEquivalent(for: .commandFnV) == nil)
        #expect(MenuActionItem.keyEquivalent(for: .fnSpace) == nil)
        let leftControlC = Shortcut(modifiers: [.init(.command), .init(.control, .left)], keyCode: KeyCode.ansiC)
        #expect(MenuActionItem.keyEquivalent(for: leftControlC) == nil)
    }
}
