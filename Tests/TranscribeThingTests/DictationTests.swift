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

    static let cancelAll: [E] = [.cancelTimer(.arming), .cancelTimer(.doublePressWindow)]

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

    @Test func idlePTTDownShowsThePillThenStartsCaptureAndArms() {
        var m = M()
        let effects = m.handle(.pttDown, now: Self.t0)
        #expect(m.capture == .arming(downAt: Self.t0))
        #expect(effects == [.showPill(.listening), .startCapture, .schedule(.arming, after: 0.12)],
                "the pill first, so the mic open never delays it; no sound yet")
        #expect(m.isRecording && m.isBusy)
    }

    @Test func armingConfirmsIntoListening() {
        var m = Self.arming()
        let effects = m.handle(.timer(.arming), now: Self.armedAt)
        #expect(m.capture == .listening(downAt: Self.t0))
        #expect(effects == [.playSound(.start)], "the pill is already up")
    }

    @Test func releaseDuringArmingIsATap() {
        var m = Self.arming()
        let effects = m.handle(.pttUp, now: 10.0625)
        #expect(m.capture == .tapPending(firstDownAt: Self.t0))
        #expect(effects == [.cancelTimer(.arming), .cancelCapture(keepForUndo: false, notify: false),
                            .schedule(.doublePressWindow, after: 0.4375)], "the pill stays up for a second press")
        #expect(!m.isRecording)
    }

    @Test func interruptionDuringArmingFoldsThePillSilently() {
        var m = Self.arming()
        let effects = m.handle(.pttInterrupted, now: 10.0625)
        #expect(m.capture == .idle)
        #expect(effects == [.cancelTimer(.arming), .cancelCapture(keepForUndo: false, notify: false), .showPill(.rest)])
    }

    @Test func handsFreeFromArmingLocks() {
        var m = Self.arming()
        let effects = m.handle(.handsFreeToggle, now: 10.0625)
        #expect(m.capture == .locked(startedAt: Self.t0))
        #expect(effects == [.cancelTimer(.arming), .showPill(.locked), .playSound(.lock)])
    }

    @Test func handsFreeFromListeningLocks() {
        var m = Self.listening()
        let effects = m.handle(.handsFreeToggle, now: 11)
        #expect(m.capture == .locked(startedAt: Self.t0))
        #expect(effects == [.cancelTimer(.arming), .showPill(.locked), .playSound(.lock)])
    }

    @Test func shortListeningReleaseIsATap() {
        var m = Self.listening()
        let effects = m.handle(.pttUp, now: 10.25)
        #expect(m.capture == .tapPending(firstDownAt: Self.t0))
        #expect(effects == [.cancelCapture(keepForUndo: false, notify: false),
                                                .schedule(.doublePressWindow, after: 0.25)])
    }

    @Test func longListeningReleaseTranscribes() {
        var m = Self.listening()
        let effects = m.handle(.pttUp, now: 10.3125)
        #expect(m.capture == .idle)
        #expect(effects == [.stopCaptureAndTranscribe(mode: .pushToTalk), .playSound(.stop)])
    }

    @Test func earlyInterruptionFoldsAwayQuietly() {
        var m = Self.listening()
        let effects = m.handle(.pttInterrupted, now: 11)
        #expect(m.capture == .idle)
        #expect(effects == [.cancelCapture(keepForUndo: false, notify: false), .showPill(.rest)])
    }

    @Test func lateInterruptionKeepsAudioAndTellsTheUser() {
        var m = Self.listening()
        let effects = m.handle(.pttInterrupted, now: 11.5)
        #expect(m.capture == .idle)
        #expect(effects == [.cancelCapture(keepForUndo: true, notify: false), .showPill(.rest),
                                                .notice(.stoppedByOtherKey)])
    }

    @Test func doublePressLocks() {
        var m = Self.tapPending()
        let effects = m.handle(.pttDown, now: 10.375)
        #expect(m.capture == .locked(startedAt: 10.375))
        #expect(effects == [.cancelTimer(.doublePressWindow), .startCapture, .showPill(.locked), .playSound(.lock)])
    }

    @Test func slowSecondPressArmsAgain() {
        var m = Self.tapPending()
        let effects = m.handle(.pttDown, now: 10.625)
        #expect(m.capture == .arming(downAt: 10.625))
        #expect(effects == [.cancelTimer(.doublePressWindow), .showPill(.listening), .startCapture,
                            .schedule(.arming, after: 0.12)])
    }

    @Test func doublePressDisabledFoldsTheTapAwayAndArmsAgain() {
        var m = DictationMachine(config: .init(doublePressEnabled: false))
        _ = m.handle(.pttDown, now: Self.t0)
        let tap = m.handle(.pttUp, now: 10.0625)
        #expect(m.capture == .idle, "nothing to wait for")
        #expect(tap == [.cancelTimer(.arming), .cancelCapture(keepForUndo: false, notify: false), .showPill(.rest)])
        let effects = m.handle(.pttDown, now: 10.25)
        #expect(m.capture == .arming(downAt: 10.25))
        #expect(effects == [.showPill(.listening), .startCapture, .schedule(.arming, after: 0.12)])
    }

    @Test func doublePressDisabledShortListeningReleaseFoldsAway() {
        var m = DictationMachine(config: .init(doublePressEnabled: false))
        _ = m.handle(.pttDown, now: Self.t0)
        _ = m.handle(.timer(.arming), now: Self.armedAt)
        let effects = m.handle(.pttUp, now: 10.25)
        #expect(m.capture == .idle)
        #expect(effects == [.cancelCapture(keepForUndo: false, notify: false), .showPill(.rest)])
    }

    @Test func doublePressWindowExpiresAndThePillFolds() {
        var m = Self.tapPending()
        let effects = m.handle(.timer(.doublePressWindow), now: 10.5)
        #expect(m.capture == .idle)
        #expect(effects == [.showPill(.rest)])
    }

    @Test(arguments: ["idle", "tapPending"], [DictationMachine.Input.handsFreeToggle, .pillClick])
    func handsFreeOrClickFromRestLocks(_ from: String, _ input: DictationMachine.Input) {
        var m = Self.state(from)
        let effects = m.handle(input, now: 20)
        #expect(m.capture == .locked(startedAt: 20))
        #expect(effects == [.cancelTimer(.doublePressWindow), .startCapture, .showPill(.locked), .playSound(.lock)])
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
        #expect(effects == [.stopCaptureAndTranscribe(mode: .handsFree), .playSound(.stop)])
    }

    @Test func comboWhileLockedKeepsRecording() {
        var m = Self.stopPending()
        let effects = m.handle(.pttInterrupted, now: 30.125)
        #expect(m.capture == .locked(startedAt: Self.t0))
        #expect(effects.isEmpty)
    }

    @Test(arguments: ["locked", "lockedStopPending"])
    func stopFinishes(_ from: String) {
        var m = Self.state(from)
        let effects = m.handle(.pillStop, now: 40)
        #expect(m.capture == .idle)
        #expect(effects == [.stopCaptureAndTranscribe(mode: .handsFree), .playSound(.stop)])
    }

    /// The hands-free shortcut only starts hands-free: pressed again it neither finishes nor stops anything.
    @Test(arguments: ["locked", "lockedStopPending"])
    func handsFreeWhileHandsFreeKeepsRecording(_ from: String) {
        var m = Self.state(from)
        #expect(m.handle(.handsFreeToggle, now: 40).isEmpty)
        #expect(m.capture == .locked(startedAt: Self.t0), "fn+Space is a combo: fn's release doesn't finish")
        #expect(m.isRecording && m.mode == .handsFree)
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
        #expect(effects == [.cancelTimer(.doublePressWindow), .resumeCapture, .showPill(.locked), .playSound(.lock)])
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

    @Test func resumedDictationFinishesLikeHandsFree() {
        var m = M()
        _ = m.handle(.resume(prefix: 4), now: 20)
        #expect(m.handle(.handsFreeToggle, now: 25).isEmpty, "the shortcut only starts hands-free")
        #expect(m.handle(.pillStop, now: 30) == [.stopCaptureAndTranscribe(mode: .handsFree), .playSound(.stop)])
        #expect(m.capture == .idle)
    }

    @Test func resumedDictationStopsWithAnFnTapAndCancelsAgainWithEsc() {
        var m = M()
        _ = m.handle(.resume(prefix: 4), now: 20)
        #expect(m.handle(.pttDown, now: 25).isEmpty, "not the key that locked it: waits for the release")
        #expect(m.handle(.pttUp, now: 25.125) == [.stopCaptureAndTranscribe(mode: .handsFree), .playSound(.stop)])

        var again = M()
        _ = again.handle(.resume(prefix: 4), now: 20)
        #expect(again.handle(.cancel, now: 22) == Self.cancelAll + [.cancelCapture(keepForUndo: true, notify: true), .playSound(.cancel)])
        #expect(again.handle(.resume(prefix: 6), now: 23).contains(.resumeCapture), "and Undo resumes it again")
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

    @Test(arguments: [("listening", DictationMachine.Mode.pushToTalk), ("locked", .handsFree), ("lockedStopPending", .handsFree)])
    func deviceLostTranscribesWhatWasSaid(_ from: String, _ mode: DictationMachine.Mode) {
        var m = Self.state(from)
        let effects = m.handle(.deviceLost, now: 50)
        #expect(m.capture == .idle)
        #expect(effects == [.stopCaptureAndTranscribe(mode: mode), .notice(.deviceLostTranscribing)])
    }

    @Test func deviceLostWhileArmingIsSilent() {
        var m = Self.arming()
        let effects = m.handle(.deviceLost, now: 10.0625)
        #expect(m.capture == .idle)
        #expect(effects == [.cancelTimer(.arming), .cancelCapture(keepForUndo: false, notify: false), .showPill(.rest)])
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
        ("idle", .timer(.doublePressWindow)), ("idle", .deviceLost), ("idle", .pillStop), ("idle", .pillCancel),
        ("arming", .pttDown), ("arming", .pillClick), ("arming", .timer(.doublePressWindow)),
        ("listening", .pttDown), ("listening", .pillClick), ("listening", .pillStop), ("listening", .timer(.arming)),
        ("locked", .pillClick), ("locked", .pttInterrupted), ("locked", .handsFreeToggle),
        ("locked", .timer(.doublePressWindow)),
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
        #expect(m.handle(.pttDown, now: 10) == [.showPill(.listening), .startCapture, .schedule(.arming, after: 0.12)])
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

    @Test func quickTapIsSilentAndFoldsWhenTheWindowCloses() {
        var m = M()
        var effects = m.handle(.pttDown, now: 10)
        effects += m.handle(.pttUp, now: 10.0625)
        #expect(m.capture == .tapPending(firstDownAt: 10))
        #expect(!effects.contains(.showPill(.rest)), "up until the double-press window closes")
        effects += m.handle(.timer(.doublePressWindow), now: 10.5)
        #expect(m.capture == .idle)
        #expect(effects.last == .showPill(.rest))
        #expect(!effects.contains { if case .playSound = $0 { true } else { false } })
        #expect(!effects.contains { if case .notice = $0 { true } else { false } })
    }

    @Test func doublePressLocksWithOneLockSoundAndNoStartSound() {
        var m = M()
        var effects = m.handle(.pttDown, now: 10)
        effects += m.handle(.pttUp, now: 10.0625)
        effects += m.handle(.pttDown, now: 10.25)
        effects += m.handle(.pttUp, now: 10.3125)
        #expect(m.capture == .locked(startedAt: 10.25))
        let sounds = effects.compactMap { if case .playSound(let s) = $0 { s } else { nil } }
        #expect(sounds == [.lock])
        let pills = effects.compactMap { if case .showPill(let p) = $0 { p } else { nil } }
        #expect(pills == [.listening, .locked], "the pill grows into hands-free without folding in between")
    }

    @Test func fnTapThenFnSpaceLocksOnce() {
        // A quick fn tap, then fn+Space within the double-press window: the router reports the press
        // before it knows Space follows, so the lock comes first and Space changes nothing.
        var m = Self.tapPending()
        let lock = m.handle(.pttDown, now: 10.25)
        #expect(m.capture == .locked(startedAt: 10.25))
        #expect(lock.contains(.startCapture))
        #expect(m.handle(.handsFreeToggle, now: 10.375).isEmpty)
        #expect(m.capture == .locked(startedAt: 10.25))
        // The chord consumed fn's release; the next fn+Space does nothing either, and a lone fn tap stops.
        #expect(m.handle(.pttDown, now: 20).isEmpty)
        #expect(m.handle(.handsFreeToggle, now: 20.0625).isEmpty)
        #expect(m.capture == .locked(startedAt: 10.25))
        #expect(m.handle(.pttDown, now: 25).isEmpty)
        #expect(m.handle(.pttUp, now: 25.125).contains(.stopCaptureAndTranscribe(mode: .handsFree)))
    }

    @Test func doublePressHeldThenReleasedStopsOnTheNextFnTap() {
        var m = Self.tapPending()
        _ = m.handle(.pttDown, now: 10.25)
        #expect(m.handle(.pttUp, now: 10.5).isEmpty)
        #expect(m.handle(.handsFreeToggle, now: 15).isEmpty)
        #expect(m.handle(.pttDown, now: 20).isEmpty)
        #expect(m.handle(.pttUp, now: 20.125).contains(.stopCaptureAndTranscribe(mode: .handsFree)))
    }

    /// fn+Space while hands-free is a combo like fn+Tab: the recording goes on through fn's release (should one
    /// come through), and only a lone fn press finishes it, or Esc cancels it.
    @Test func fnSpaceWhileHandsFreeKeepsRecordingUntilALoneFnPress() {
        var m = M()
        _ = m.handle(.pttDown, now: 10)
        _ = m.handle(.handsFreeToggle, now: 10.0625)
        #expect(m.capture == .locked(startedAt: 10))
        var effects = m.handle(.pttDown, now: 20)
        effects += m.handle(.handsFreeToggle, now: 20.0625)
        effects += m.handle(.pttUp, now: 20.25)
        #expect(effects.isEmpty, "no sound, no stop")
        #expect(m.capture == .locked(startedAt: 10))
        #expect(m.handle(.pttDown, now: 30).isEmpty)
        #expect(m.handle(.pttUp, now: 30.125) == [.stopCaptureAndTranscribe(mode: .handsFree), .playSound(.stop)])
        #expect(m.capture == .idle)

        var again = M()
        _ = again.handle(.handsFreeToggle, now: 10)
        _ = again.handle(.pttDown, now: 20)
        _ = again.handle(.handsFreeToggle, now: 20.0625)
        #expect(again.handle(.cancel, now: 21) == Self.cancelAll + [.cancelCapture(keepForUndo: true, notify: true), .playSound(.cancel)])
        #expect(again.capture == .idle)
    }

    @Test func fnArrowWhileLockedKeepsRecordingThenStops() {
        var m = Self.locked()
        _ = m.handle(.pttDown, now: 20)
        _ = m.handle(.pttInterrupted, now: 20.1)
        #expect(m.capture == .locked(startedAt: Self.t0))
        #expect(m.handle(.pttUp, now: 20.3).isEmpty)
        #expect(m.isRecording)
        _ = m.handle(.pttDown, now: 25)
        let stop = m.handle(.pttUp, now: 25.125)
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
        #expect(m.handle(.pttDown, now: 13) == [.showPill(.listening), .startCapture, .schedule(.arming, after: 0.12)])
        #expect(m.activeJobs == 1 && m.isRecording)
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

    @Test func autoDeleteRemovesOldEntriesAndTheirAudio() async throws {
        let paths = AppPaths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let settings = AppSettings.inMemory()
        let store = HistoryStore(paths: paths, settings: settings)
        store.load()
        try await waitUntil { store.isLoaded }
        try FileManager.default.createDirectory(at: paths.recordings, withIntermediateDirectories: true)
        for name in ["old.wav", "recent.wav"] { try Data([1, 2]).write(to: paths.recordingURL(fileName: name)) }
        let now = Date()
        let old = TranscriptEntry(createdAt: now.addingTimeInterval(-20 * 86_400), text: "old", engine: .parakeet,
                                  audioDuration: 3, voicedSeconds: 2, audioFileName: "old.wav")
        let recent = TranscriptEntry(createdAt: now.addingTimeInterval(-2 * 86_400), text: "", engine: .parakeet,
                                     status: .failed, audioDuration: 3, voicedSeconds: 2, audioFileName: "recent.wav")
        store.upsert(old)
        store.upsert(recent)
        var removed: [UUID] = []
        store.onRemove = { removed += $0 }
        settings.autoDeleteHistoryDays = 7
        store.deleteExpired(now: now)
        #expect(store.entries.map(\.id) == [recent.id])
        #expect(removed == [old.id])
        try await waitUntil { !FileManager.default.fileExists(atPath: paths.recordingURL(fileName: "old.wav").path) }
        #expect(FileManager.default.fileExists(atPath: paths.recordingURL(fileName: "recent.wav").path))
    }

    @Test func neverKeepsEverything() {
        let now = Date()
        let store = HistoryStore.preview(entries: [
            TranscriptEntry(createdAt: now.addingTimeInterval(-400 * 86_400), text: "", engine: .parakeet, status: .failed,
                            audioDuration: 3, voicedSeconds: 2, audioFileName: "old.wav"),
            TranscriptEntry(createdAt: now.addingTimeInterval(-2 * 86_400), text: "hi", engine: .parakeet,
                            audioDuration: 3, voicedSeconds: 2, audioFileName: "recent.wav"),
        ])
        store.deleteExpired(now: now)
        #expect(store.entries.map(\.audioFileName) == ["recent.wav", "old.wav"])
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
    /// Called as each start begins (to see what is already on screen when the mic opens).
    var onStart: (() -> Void)?
    /// What the capture in progress records; a start that continues a recording puts that one first.
    var next = Recording(samples: Array(repeating: 0.1, count: 16_000 * 2),
                         speech: SpeechStats(voicedSeconds: 1.5, peakDBFS: -12, isSilent: false))
    private var prefix: Recording?

    func start(preferredDeviceUID: String?, continuing prefix: Recording?) throws {
        onStart?()
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
        let meter: LevelMeter
        /// Where a history that writes its recordings to disk keeps them (`persistsHistory`).
        var paths: AppPaths?
    }

    static func make(models: [EngineID: LocalModelState] = [.parakeet: .ready],
                     modelErrors: [EngineID: AppError] = [:], store: ModelStore? = nil,
                     mic: PermissionState = .granted, micLive: Bool = false, keyStatus: KeyStatus = .missing,
                     meter: LevelMeter = .preview(level: 0), persistsHistory: Bool = false,
                     client: OpenRouterClient? = nil, inserter: TextInserter? = nil) -> Harness {
        let settings = AppSettings.inMemory()
        let paths: AppPaths? = persistsHistory ? .temporary() : nil
        let devices = AudioDeviceCatalog.preview()
        let store = store ?? ModelStore.preview(states: models, lastErrors: modelErrors)
        // A stubbed `client` (`StubURLProtocol`) gets a key to send; the default one never has any.
        let account = OpenRouterAccount.preview(
            status: keyStatus,
            keyStore: .inMemory(client == nil ? nil : "sk-or-v1-test"))
        let client = client ?? OpenRouterClient()
        let history = paths.map { HistoryStore(paths: $0, settings: settings) } ?? .preview(entries: [], settings: settings)
        let toasts = ToastCenter()
        let pill = PillModel(settings: settings, levelMeter: meter)
        let hotkeys = HotkeyMonitor.preview()
        let controller = DictationController(
            settings: settings, recorder: AudioRecorder(levelMeter: meter, devices: devices),
            transcription: TranscriptionService(models: store, account: account, client: client),
            models: store, account: account, history: history, inserter: inserter ?? .inert(),
            hotkeys: hotkeys, permissions: .preview(mic: mic, ax: .granted), sounds: SoundPlayer(settings: settings),
            pillModel: pill, toasts: toasts)
        let recorder = FakeRecorder()
        controller.captureDevice = recorder
        controller.copyOverride = { _ in }
        controller.microphoneAuthorizedNow = { micLive }
        return Harness(controller: controller, recorder: recorder, history: history, toasts: toasts,
                       settings: settings, pill: pill, hotkeys: hotkeys, meter: meter, paths: paths)
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
            h.controller.enqueue(r, engine: .parakeet, targetPID: nil)
        }
        #expect(h.controller.machine.activeJobs == 3)
        #expect(h.pill.phase == .processing)
        try await waitUntil { pasted.count == 3 }
        #expect(pasted == ["first", "second", "third"])
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(h.history.entries.count == 3)
        #expect(h.history.entries.allSatisfy { $0.status == .success })
    }

    /// A transcript keeps its recording as long as it's in History, so it can always be transcribed again.
    @Test func everyTranscriptKeepsItsAudio() async throws {
        let h = Self.make(persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "kept", engine: engine, processingTime: 0.1) }
        h.controller.insertOverride = { _, _ in .pasted }
        let r = Self.recording()
        h.controller.enqueue(r, engine: .parakeet, targetPID: nil)
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id) != nil }
        let entry = try #require(h.history.entry(id: r.id))
        #expect(entry.audioFileName == "\(r.id.uuidString).m4a")
        #expect(h.history.loadRecording(for: entry)?.samples.count == r.samples.count)
    }

    /// Recordings kept in memory for Undo and Retry stay within their budget however long they are: past it, older
    /// ones History has on disk let go of their samples, and a Retry reads them back from there.
    @Test func keptAudioStaysWithinItsBudget() async throws {
        let h = Self.make(persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        h.controller.retainedSecondsLimit = 1.5
        h.controller.transcribeOverride = { _, engine in throw AppError.engineFailed(engine, "Couldn’t transcribe") }
        let voiced = (0..<16_000).map { 0.2 * sin(Float($0) * 0.05) }
        let first = Recording(samples: voiced, speech: SpeechStats(voicedSeconds: 1, peakDBFS: -14, isSilent: false))
        let second = Recording(samples: voiced, speech: SpeechStats(voicedSeconds: 1, peakDBFS: -14, isSilent: false))
        h.controller.enqueue(first, engine: .parakeet, targetPID: nil)
        try await waitUntil { h.history.entry(id: first.id)?.status == .failed }
        #expect(h.controller.retainedRecordingIDs == [first.id])
        h.controller.enqueue(second, engine: .parakeet, targetPID: nil)
        try await waitUntil { h.history.entry(id: second.id)?.status == .failed }
        #expect(h.controller.retainedRecordingIDs == [second.id], "2 s kept is past the budget: the older one goes")

        var heard: [Int] = []
        h.controller.transcribeOverride = { recording, engine in
            heard.append(recording.samples.count)
            return TranscriptResult(text: "back from disk", engine: engine, processingTime: 0.1)
        }
        h.controller.retry(try #require(h.history.entry(id: first.id)), with: .parakeet)
        try await waitUntil { h.history.entry(id: first.id)?.status == .success }
        #expect(heard == [first.samples.count])
    }

    /// General → Pasting shapes only what the app pastes (a dictation, Paste Here, paste last): History, the cards and
    /// Copy keep the text as the model wrote it.
    @Test func thePastingSettingsShapeOnlyWhatIsPasted() async throws {
        let h = Self.make()
        h.settings.addsSpaceAfterText = true
        h.settings.removesFinalPeriod = true
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "Hello.", engine: engine, processingTime: 0.1) }
        var pasted: [String] = []
        h.controller.insertOverride = { text, _ in pasted.append(text); return .targetChanged }
        var copied: [String] = []
        h.controller.copyOverride = { copied.append($0) }
        var pastedHere: [String] = []
        h.controller.pasteNowOverride = { pastedHere.append($0); return .pasted }
        var pastedLast: [String] = []
        h.controller.pasteLastOverride = { pastedLast.append($0); return .pasted }

        let r = Self.recording()
        h.controller.enqueue(r, engine: .parakeet, targetPID: nil)
        try await waitUntil { h.controller.machine.activeJobs == 0 && !pasted.isEmpty }
        #expect(pasted == ["Hello "])
        #expect(h.history.entry(id: r.id)?.text == "Hello.")

        let card = try #require(h.toasts.notices.first { $0.transcript == "Hello." }, "the card shows the text as written")
        h.controller.perform(try #require(card.actions.first { $0.title == "Copy" }), from: card)
        #expect(copied == ["Hello."])
        h.controller.perform(try #require(card.actions.first { $0.title == "Paste Here" }), from: card)
        try await waitUntil { !pastedHere.isEmpty }
        #expect(pastedHere == ["Hello "])

        h.controller.pasteLast()
        try await waitUntil { !pastedLast.isEmpty }
        #expect(pastedLast == ["Hello "])
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
        for r in [a, b, c] { h.controller.enqueue(r, engine: .geminiFlash, targetPID: nil) }
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
    /// engine, and nothing is kept. Compared through the Never-mode notice (the pill's words are covered above).
    @Test func emptyTextIsSilenceNotAnError() async throws {
        let preflight = Self.make()
        preflight.settings.pillMode = .never
        preflight.recorder.next = Recording(samples: Array(repeating: 0.01, count: 32_000),
                                            speech: SpeechStats(voicedSeconds: 0.1, peakDBFS: -40, isSilent: false))
        preflight.controller.send(.handsFreeToggle)
        preflight.controller.send(.pillStop)
        try await waitUntil { preflight.controller.machine.activeJobs == 0 && !preflight.toasts.notices.isEmpty }
        let expected = try #require(preflight.toasts.notices.first)
        #expect(preflight.pill.visiblePhase == .error)

        for engine in EngineID.offered {
            let h = Self.make(keyStatus: .valid(KeyInfo()))
            h.settings.pillMode = .never
            h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "  \n", engine: engine, processingTime: 0.1) }
            h.controller.insertOverride = { _, _ in Issue.record("nothing should be pasted"); return .pasted }
            let r = Self.recording()
            h.controller.enqueue(r, engine: engine, targetPID: nil)
            try await waitUntil { h.controller.machine.activeJobs == 0 }
            #expect(h.history.entries.isEmpty, "\(engine): silence leaves no history entry")
            #expect(h.toasts.notices.count == 1)
            let notice = try #require(h.toasts.notices.first)
            #expect(notice.dedupeKey == expected.dedupeKey && notice.title == expected.title && notice.body == expected.body)
            #expect(notice.style == .info && notice.sound == nil && notice.lifetime == expected.lifetime)
            #expect(notice.actions.isEmpty && notice.recordingID == nil, "no Retry")
            #expect(h.pill.visiblePhase == .error, "the same flash as a recording with no speech")

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
        h.controller.enqueue(r, engine: .parakeet, targetPID: nil)
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(h.history.entry(id: r.id)?.status == .failed)
        let notice = try #require(h.toasts.notices.first { $0.dedupeKey == "error.engineFailed.parakeet" })
        #expect(notice.actions.first?.kind == .retry)
        #expect(!h.toasts.notices.contains { $0.dedupeKey == "error.noSpeech" })
    }

    /// Every silent result says "No speech detected" inside the pill, with no toast and no shake; with no pill
    /// (Never mode) it is the quiet notice instead, every time.
    @Test func engineSilenceSaysNoSpeechEveryTime() async throws {
        let h = Self.make()
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "", engine: engine, processingTime: 0.1) }
        for _ in 0..<4 {
            h.pill.errorMessage = nil
            let shakes = h.pill.shakeCount
            h.controller.enqueue(Self.recording(), engine: .parakeet, targetPID: nil)
            try await waitUntil { h.controller.machine.activeJobs == 0 }
            #expect(h.pill.errorMessage == PillMetrics.noSpeechText)
            #expect(PillView(model: h.pill).visual == .message(PillMetrics.noSpeechText))
            #expect(h.pill.shakeCount == shakes, "a worded flash doesn't shake")
            #expect(!h.toasts.notices.contains { $0.dedupeKey == "error.noSpeech" })
        }
        h.settings.pillMode = .never
        for _ in 0..<4 {
            h.toasts.dismissAll()
            h.controller.enqueue(Self.recording(), engine: .parakeet, targetPID: nil)
            try await waitUntil { h.controller.machine.activeJobs == 0 }
            #expect(h.toasts.notices.contains { $0.dedupeKey == "error.noSpeech" })
        }
        #expect(h.history.entries.isEmpty)
    }

    @Test func noEditableTargetShowsTheTranscriptCard() async throws {
        let h = Self.make()
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "Hello there", engine: engine, processingTime: 0.1) }
        h.controller.insertOverride = { _, _ in .targetChanged }
        h.controller.enqueue(Self.recording(), engine: .parakeet, targetPID: 42)
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
        var cues: [SoundEffect] = []
        h.controller.playCueOverride = { cues.append($0) }
        var now: TimeInterval = 100
        h.controller.clock = { now }
        h.controller.handle(.pttDown)
        #expect(h.recorder.starts == 1)
        #expect(h.pill.phase == .listening, "the pill answers the key at once")
        #expect(cues.isEmpty, "the start sound waits for the arming delay")
        h.controller.send(.timer(.arming))
        #expect(h.pill.phase == .listening)
        #expect(cues == [.start])
        now = 102
        h.controller.handle(.pttUp)
        #expect(!h.recorder.isCapturing)
        #expect(h.pill.phase == .processing)
        try await waitUntil { pasted == ["dictated"] }
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(h.history.entries.first?.status == .success)
    }

    /// fn+Space only starts hands-free: pressed again (the router reports fn's press and the chord, and nothing for
    /// fn's release) the recording goes on without a sound, and a lone fn press finishes it.
    @Test func handsFreeEndToEndFinishesOnlyWithALoneFnPress() async throws {
        let h = Self.make()
        var pasted: [String] = []
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "dictated", engine: engine, processingTime: 0.2) }
        h.controller.insertOverride = { text, _ in pasted.append(text); return .pasted }
        var cues: [SoundEffect] = []
        h.controller.playCueOverride = { cues.append($0) }
        h.controller.handle(.pttDown)
        h.controller.handle(.handsFreeToggle)
        #expect(h.pill.phase == .locked)
        #expect(cues == [.lock])
        for _ in 0..<2 {
            h.controller.handle(.pttDown)
            h.controller.handle(.handsFreeToggle)
            #expect(h.recorder.isCapturing && h.recorder.starts == 1)
            #expect(h.pill.phase == .locked)
            #expect(cues == [.lock])
        }
        h.controller.handle(.pttDown)
        h.controller.handle(.pttUp)
        #expect(!h.recorder.isCapturing)
        #expect(h.pill.phase == .processing)
        try await waitUntil { pasted == ["dictated"] }
        try await waitUntil { h.controller.machine.activeJobs == 0 }
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
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.pill.errorMessage != nil }
        #expect(h.pill.errorMessage == PillMetrics.noSpeechText)
        #expect(!h.toasts.notices.contains { $0.dedupeKey == "error.noSpeech" })
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
        for parakeet in EngineID.parakeetRuntimes {
            #expect(DictationController.fallbackCandidates(for: .parakeet, parakeet: parakeet) == [.parakeetCloud])
            #expect(DictationController.fallbackCandidates(for: .parakeetCloud, parakeet: parakeet) == [.parakeet])
        }
        #expect(DictationController.fallbackCandidates(for: .geminiFlash, parakeet: .parakeet) == [.parakeet, .parakeetCloud],
                "Gemini falls back to Parakeet where it runs first")
        #expect(DictationController.fallbackCandidates(for: .geminiFlash, parakeet: .parakeetCloud)
                == [.parakeetCloud, .parakeet])
    }

    @Test func aFailedLocalDictationOffersParakeetInTheCloudOnlyWithAWorkingKey() async throws {
        for (key, expected) in [(KeyStatus.valid(KeyInfo()), true), (.missing, false), (.invalid("401"), false)] {
            let h = Self.make(models: [.parakeet: .ready], keyStatus: key)
            h.controller.transcribeOverride = { _, engine in throw AppError.engineFailed(engine, "CoreML error") }
            let r = Self.recording()
            h.controller.enqueue(r, engine: .parakeet, targetPID: nil)
            try await waitUntil { h.controller.machine.activeJobs == 0 }
            let notice = try #require(h.toasts.notices.first { $0.recordingID == r.id })
            #expect(notice.actions.contains { $0.kind == .retryWith(.parakeetCloud) } == expected, "\(key)")
        }
    }

    @Test func aFailedGeminiDictationFallsBackToParakeet() async throws {
        func fallback(main: EngineID = .parakeet, local: LocalModelState, error: AppError) async throws -> EngineID? {
            let h = Self.make(models: [.parakeet: local], keyStatus: .valid(KeyInfo()))
            h.settings.parakeetEngine = main
            h.controller.transcribeOverride = { _, _ in throw error }
            let r = Self.recording()
            h.controller.enqueue(r, engine: .geminiFlash, targetPID: nil)
            try await waitUntil { h.controller.machine.activeJobs == 0 }
            let notice = try #require(h.toasts.notices.first { $0.recordingID == r.id })
            return notice.actions.lazy.compactMap { if case .retryWith(let e) = $0.kind { e } else { nil } }.first
        }
        let limited = AppError.openRouterRateLimited(retryAfter: nil)
        #expect(try await fallback(local: .ready, error: limited) == .parakeet, "Parakeet, loaded")
        #expect(try await fallback(local: .installed, error: limited) == .parakeet,
                "Parakeet on this Mac loads for the retry: it comes before a key that works now")
        #expect(try await fallback(local: .preparing(since: .distantPast), error: limited) == .parakeet)
        #expect(try await fallback(local: .notInstalled, error: limited) == .parakeetCloud, "Parakeet on this Mac can't run")
        #expect(try await fallback(local: .failed("x"), error: limited) == .parakeetCloud)
        #expect(try await fallback(local: .notInstalled, error: .openRouterNoCredits("")) == nil,
                "no credit stops every cloud model")
        #expect(try await fallback(local: .installed, error: .offline) == .parakeet)
        // Parakeet · Cloud where Parakeet runs comes first; Parakeet on this Mac only when the cloud can't run.
        #expect(try await fallback(main: .parakeetCloud, local: .ready, error: limited) == .parakeetCloud)
        #expect(try await fallback(main: .parakeetCloud, local: .installed, error: .offline) == .parakeet)
    }

    /// A cloud model that takes long is simply at work: no notice says so (Esc cancels it), whatever the model.
    @Test func aSlowCloudModelPostsNoNotice() async throws {
        let h = Self.make(keyStatus: .valid(KeyInfo()))
        h.controller.waitNoticeDelayOverride = 0.02
        h.controller.transcribeOverride = { _, engine in
            try await Task.sleep(for: .seconds(5))
            return TranscriptResult(text: "late", engine: engine, processingTime: 5)
        }
        h.controller.insertOverride = { _, _ in Issue.record("canceled, never pasted"); return .pasted }
        h.controller.enqueue(Self.recording(), engine: .geminiFlash, targetPID: nil)
        h.controller.enqueue(Self.recording(), engine: .parakeetCloud, targetPID: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.toasts.notices.isEmpty)
        h.controller.handle(.cancel)
        h.controller.handle(.cancel)
        #expect(h.controller.machine.activeJobs == 0)
    }

    /// A dictation waiting for Parakeet on this Mac to download says so, and "Use … Instead" runs it on the model
    /// that can take it now.
    @Test func aDictationWaitingForItsDownloadSaysSoAndOffersAnother() async throws {
        let h = Self.make(models: [.parakeet: .downloading(DownloadProgress(fraction: 0.42))],
                          keyStatus: .valid(KeyInfo()))
        h.controller.waitNoticeDelayOverride = 0.05
        var runs: [EngineID] = []
        h.controller.transcribeOverride = { _, engine in
            runs.append(engine)
            if engine == .parakeet { try await Task.sleep(for: .seconds(5)) }
            return TranscriptResult(text: "by \(engine.rawValue)", engine: engine, processingTime: 0.2)
        }
        var pasted: [String] = []
        h.controller.insertOverride = { text, _ in pasted.append(text); return .pasted }
        let r = Self.recording()
        h.controller.enqueue(r, engine: .parakeet, targetPID: nil)
        try await waitUntil { h.toasts.notices.contains { $0.dedupeKey == "slow.\(r.id)" } }
        let wait = try #require(h.toasts.notices.first { $0.dedupeKey == "slow.\(r.id)" })
        #expect(wait.title == "Still downloading Parakeet v3 · 42%")
        let use = try #require(wait.actions.first)
        #expect(use.title == "Use Parakeet v3 · Cloud Instead")
        h.controller.perform(use, from: wait)
        try await waitUntil { h.controller.machine.activeJobs == 0 && !pasted.isEmpty }
        #expect(runs == [.parakeet, .parakeetCloud])
        #expect(pasted == ["by parakeetCloud"])
        #expect(h.history.entry(id: r.id)?.engine == .parakeetCloud)
        #expect(!h.toasts.notices.contains { $0.dedupeKey == "slow.\(r.id)" })
    }

    @Test func refusalWhileArmingStaysSilentForFnCombos() {
        let h = Self.make(mic: .denied)
        var cues: [SoundEffect] = []
        h.controller.playCueOverride = { cues.append($0) }
        h.controller.handle(.pttDown)
        #expect(h.pill.visiblePhase == .listening, "the refusal waits: this may be fn+←")
        h.controller.handle(.pttInterrupted)
        #expect(h.toasts.notices.isEmpty)
        #expect(h.pill.visiblePhase == .rest, "folded away without a shake")
        #expect(h.recorder.starts == 0)
        #expect(cues.isEmpty)
        h.controller.handle(.pttDown)
        h.controller.send(.timer(.arming))
        #expect(h.controller.machine.capture == .idle)
        #expect(h.toasts.notices.first?.dedupeKey == "error.microphonePermissionDenied")
        #expect(h.pill.visiblePhase == .error, "the pill that came up at key-down shakes, with the notice above it")
        #expect(!cues.contains(.start))
    }

    @Test func refusedQuickTapFoldsAwaySilently() {
        let h = Self.make(mic: .denied)
        h.settings.doublePressForHandsFree = true
        var cues: [SoundEffect] = []
        h.controller.playCueOverride = { cues.append($0) }
        h.controller.handle(.pttDown)
        h.controller.handle(.pttUp)
        h.controller.send(.timer(.doublePressWindow))
        #expect(h.controller.machine.capture == .idle)
        #expect(h.pill.visiblePhase == .rest)
        #expect(h.pill.shakeCount == 0)
        #expect(h.toasts.notices.isEmpty)
        #expect(cues.isEmpty)
    }

    @Test func captureFailureWhileArmingExplainsThePill() {
        let h = Self.make()
        h.controller.handle(.pttDown)
        #expect(h.pill.visiblePhase == .listening)
        h.controller.send(.captureFailed(.microphoneNotResponding("HAL error")))
        #expect(h.controller.machine.capture == .idle)
        #expect(!h.recorder.isCapturing)
        #expect(h.pill.visiblePhase == .error)
        #expect(h.toasts.notices.contains { $0.dedupeKey == "error.microphoneNotResponding" })
    }

    // MARK: Instant pill

    @Test func thePillIsOnScreenBeforeTheMicOpens() {
        let h = Self.make()
        var order: [String] = []
        h.pill.onVisiblePhaseChange = { order.append("pill \(h.pill.visiblePhase)") }
        h.recorder.onStart = { order.append("mic") }
        h.controller.handle(.pttDown)
        #expect(order == ["pill listening", "mic"])
        #expect(h.controller.machine.capture.isArming)
    }

    @Test func aQuickTapStaysUpForTheDoublePressWindowThenFoldsSilently() {
        let h = Self.make()
        h.settings.doublePressForHandsFree = true
        var cues: [SoundEffect] = []
        h.controller.playCueOverride = { cues.append($0) }
        var phases: [PillPhase] = []
        h.pill.onVisiblePhaseChange = { phases.append(h.pill.visiblePhase) }
        h.controller.handle(.pttDown)
        h.controller.handle(.pttUp)
        #expect(!h.recorder.isCapturing)
        #expect(h.pill.visiblePhase == .listening, "a second press may still come")
        h.controller.send(.timer(.doublePressWindow))
        #expect(phases == [.listening, .rest])
        #expect(cues.isEmpty)
        #expect(h.pill.shakeCount == 0)
        #expect(h.toasts.notices.isEmpty)
        #expect(h.controller.activity == .idle)
    }

    @Test func withoutDoublePressATapFoldsAtOnce() {
        let h = Self.make()
        h.settings.doublePressForHandsFree = false
        h.controller.handle(.pttDown)
        #expect(h.pill.visiblePhase == .listening)
        h.controller.handle(.pttUp)
        #expect(h.controller.machine.capture == .idle)
        #expect(h.pill.visiblePhase == .rest)
    }

    @Test func doublePressGrowsIntoHandsFreeWithOneLockCue() {
        let h = Self.make()
        h.settings.doublePressForHandsFree = true
        var cues: [SoundEffect] = []
        h.controller.playCueOverride = { cues.append($0) }
        var phases: [PillPhase] = []
        h.pill.onVisiblePhaseChange = { phases.append(h.pill.visiblePhase) }
        h.controller.handle(.pttDown)
        h.controller.handle(.pttUp)
        h.controller.handle(.pttDown)
        h.controller.handle(.pttUp)
        #expect(h.controller.machine.capture.isListeningOrLocked)
        #expect(h.controller.machine.mode == .handsFree)
        #expect(h.recorder.starts == 2 && h.recorder.isCapturing)
        #expect(cues == [.lock])
        #expect(phases == [.listening, .locked], "never folds in between")
    }

    @Test(arguments: PillMode.allCases)
    func everyPillModeFollowsTheKey(_ mode: PillMode) {
        let h = Self.make()
        h.settings.doublePressForHandsFree = true
        h.settings.pillMode = mode
        var shown: [Bool] = []
        h.pill.onVisiblePhaseChange = {
            shown.append(PillVisibility.showsPill(phase: h.pill.visiblePhase, mode: mode))
        }
        h.controller.handle(.pttDown)
        h.controller.handle(.pttUp)
        h.controller.send(.timer(.doublePressWindow))
        #expect(h.pill.visiblePhase == .rest, "never stuck after a tap")
        switch mode {
        case .always: #expect(shown == [true, true])
        case .whileDictating: #expect(shown == [true, false])
        case .never: #expect(shown == [false, false], "no pill at all")
        }
    }

    /// Onboarding counts recordings by this: the pill is up from key-down, but only a committed press records.
    @Test func aPressCountsAsARecordingOnlyOnceItCommits() {
        let h = Self.make()
        h.settings.doublePressForHandsFree = true
        h.controller.handle(.pttDown)
        #expect(h.pill.phase == .listening)
        #expect(h.controller.committedPillPhase == .rest, "arming isn't a recording yet")
        h.controller.handle(.pttUp)
        #expect(h.pill.phase == .listening)
        #expect(h.controller.committedPillPhase == .rest, "nor is the tap window")
        h.controller.send(.timer(.doublePressWindow))
        #expect(h.controller.committedPillPhase == .rest)

        h.controller.handle(.pttDown)
        h.controller.send(.timer(.arming))
        #expect(h.controller.committedPillPhase == .listening)
        h.controller.handle(.handsFreeToggle)
        #expect(h.controller.committedPillPhase == .locked)
    }

    /// A job lands while a quick tap holds the pill up: its flash plays once the pill folds. A paste has no
    /// flourish (the pasted text is the confirmation), so the pill just folds to rest; no speech says so in words.
    @Test(arguments: [true, false])
    func aFlourishDuringATapPlaysWhenThePillFolds(_ succeeds: Bool) async throws {
        let h = Self.make()
        h.settings.doublePressForHandsFree = true
        h.controller.runsTimers = false
        h.controller.transcribeOverride = { _, engine in
            TranscriptResult(text: succeeds ? "dictated" : "", engine: engine, processingTime: 0.1)
        }
        h.controller.insertOverride = { _, _ in .pasted }
        h.controller.handle(.pttDown)
        h.controller.handle(.pttUp)
        // A notice's Retry, say, finishes inside the double-press window.
        h.controller.enqueue(Self.recording(), engine: .parakeet, targetPID: nil)
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(h.pill.visiblePhase == .listening, "the tap's pill holds until the window closes")
        #expect(h.pill.shakeCount == 0)
        h.controller.send(.timer(.doublePressWindow))
        #expect(h.pill.visiblePhase == (succeeds ? .rest : .error))
        #expect(h.pill.shakeCount == 0, "a worded flash doesn't shake")
        #expect(h.pill.errorMessage == (succeeds ? nil : PillMetrics.noSpeechText))
    }

    /// A press that commits drops the held-back flourish, as a recording cuts one already on screen.
    @Test func aFlourishHeldDuringArmingIsDroppedWhenThePressCommits() async throws {
        let h = Self.make()
        h.controller.runsTimers = false
        var now: TimeInterval = 100
        h.controller.clock = { now }
        // No text: the job ends with a shake, held back while the press is arming.
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "", engine: engine, processingTime: 0.1) }
        h.controller.handle(.pttDown)
        h.controller.enqueue(Self.recording(), engine: .parakeet, targetPID: nil)
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(h.pill.visiblePhase == .listening)
        h.controller.send(.timer(.arming))
        now = 102
        h.controller.handle(.pttUp)
        #expect(h.pill.visiblePhase == .processing, "the old shake doesn't come back after the recording")
        #expect(h.pill.shakeCount == 0)
    }

    /// An fn tap or an fn combo while a job is in flight doesn't touch the processing pill: not its width, not its
    /// count. A real hold takes over once it commits.
    @Test func pressesThatDontCommitLeaveTheProcessingPillAlone() async throws {
        let h = Self.make(keyStatus: .valid(KeyInfo()))
        h.settings.doublePressForHandsFree = true
        h.settings.lineup.main = .gemini
        h.controller.runsTimers = false
        h.pill.timing.counterDelay = 0.05
        var release = false
        var jobID: UUID?
        h.controller.transcribeOverride = { recording, engine in
            jobID = recording.id
            while !release { try await Task.sleep(for: .milliseconds(5)) }
            return TranscriptResult(text: "dictated", engine: engine, processingTime: 0.1)
        }
        h.controller.insertOverride = { _, _ in .pasted }
        var now: TimeInterval = 100
        h.controller.clock = { now }
        h.controller.send(.handsFreeToggle)
        now = 104
        h.controller.send(.pillStop)
        #expect(h.pill.visiblePhase == .processing)
        #expect(h.pill.processingOrigin == .locked, "its dots start where the hands-free bars stood")
        try await waitUntil { jobID != nil }
        h.controller.streamed(ChatStreamProgress(reasoningCharacters: 4_000), for: try #require(jobID))
        try await waitUntil { h.pill.showsCounter }
        let count = h.pill.tokenCount

        var phases: [PillPhase] = []
        h.pill.onVisiblePhaseChange = { phases.append(h.pill.visiblePhase) }
        now = 105
        h.controller.handle(.pttDown)
        h.controller.handle(.pttUp)
        #expect(h.controller.machine.capture == .tapPending(firstDownAt: 105))
        h.controller.send(.timer(.doublePressWindow))
        now = 106
        h.controller.handle(.pttDown)
        h.controller.handle(.pttInterrupted)
        #expect(phases.isEmpty, "the processing pill never moved")
        #expect(h.pill.processingOrigin == .locked)
        #expect(h.pill.showsCounter && h.pill.tokenCount == count)

        now = 107
        h.controller.handle(.pttDown)
        #expect(h.pill.visiblePhase == .processing, "until the press commits")
        #expect(h.pill.showsCounter)
        h.controller.send(.timer(.arming))
        #expect(h.pill.visiblePhase == .listening)
        #expect(h.pill.tokenCount == nil && !h.pill.showsCounter, "a recording shows no count")
        h.controller.handle(.cancel)
        release = true
        try await waitUntil { h.controller.machine.activeJobs == 0 }
    }

    /// The job under a held press ends without a flourish (pasted, or nowhere to paste) before the press commits:
    /// the pill goes straight to the press's dots, never to rest (hidden while dictating) in between.
    @Test(arguments: [false, true])
    func aJobEndingUnderAHeldPressHandsThePillToThePress(pastes: Bool) async throws {
        let h = Self.make()
        h.controller.runsTimers = false
        var release = false
        h.controller.transcribeOverride = { _, engine in
            while !release { try await Task.sleep(for: .milliseconds(5)) }
            return TranscriptResult(text: "dictated", engine: engine, processingTime: 0.1)
        }
        h.controller.insertOverride = { _, _ in pastes ? .pasted : .noEditableTarget }
        h.controller.enqueue(Self.recording(), engine: .parakeet, targetPID: nil)
        #expect(h.pill.visiblePhase == .processing)
        var phases: [PillPhase] = []
        h.pill.onVisiblePhaseChange = { phases.append(h.pill.visiblePhase) }
        h.controller.handle(.pttDown)
        #expect(h.pill.visiblePhase == .processing, "until the press commits")
        release = true
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.pill.visiblePhase != .processing }
        #expect(h.controller.machine.capture.isArming)
        #expect(h.pill.visiblePhase == .listening)
        #expect(!phases.contains(.rest))
        h.controller.send(.timer(.arming))
        #expect(h.pill.visiblePhase == .listening)
        h.controller.handle(.cancel)
    }

    /// The job finishes while a tap over its processing pill is still in the double-press window: a paste folds
    /// the pill to rest, a failure shows its shake at once.
    @Test(arguments: [true, false])
    func aJobFinishingDuringATapOverProcessingSettlesAtOnce(pastes: Bool) async throws {
        let h = Self.make()
        h.settings.doublePressForHandsFree = true
        h.controller.runsTimers = false
        var release = false
        h.controller.transcribeOverride = { _, engine in
            while !release { try await Task.sleep(for: .milliseconds(5)) }
            return TranscriptResult(text: pastes ? "dictated" : "", engine: engine, processingTime: 0.1)
        }
        var pasted: [String] = []
        h.controller.insertOverride = { text, _ in pasted.append(text); return .pasted }
        h.controller.enqueue(Self.recording(), engine: .parakeet, targetPID: nil)
        #expect(h.pill.visiblePhase == .processing)
        h.controller.handle(.pttDown)
        h.controller.handle(.pttUp)
        release = true
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(pasted == (pastes ? ["dictated"] : []))
        #expect(h.controller.machine.capture.isUncommittedPress)
        #expect(h.pill.visiblePhase == (pastes ? .rest : .error))
        h.controller.send(.timer(.doublePressWindow))
        #expect(h.pill.visiblePhase == (pastes ? .rest : .error), "an error is held for its minimum time")
    }

    /// Right after a paste the pill is back at rest, so clicking it starts hands-free at once. Only the error
    /// shake swallows clicks (they open the Hub instead).
    @Test(arguments: [true, false])
    func clickingThePillRightAfterAJobRecordsOnlyAfterAPaste(pastes: Bool) async throws {
        let h = Self.make()
        h.controller.start()
        var now: TimeInterval = 100
        h.controller.clock = { now }
        h.controller.transcribeOverride = { _, engine in
            TranscriptResult(text: pastes ? "dictated" : "", engine: engine, processingTime: 0.1)
        }
        h.controller.insertOverride = { _, _ in .pasted }
        h.controller.enqueue(Self.recording(), engine: .parakeet, targetPID: nil)
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(h.pill.visiblePhase == (pastes ? .rest : .error))
        now = 100.5
        h.pill.onClick?()
        #expect(h.controller.machine.isRecording == pastes)
        #expect(h.pill.phase.isRecording == pastes)
        h.controller.handle(.cancel)
    }

    /// Every press starts from an empty equalizer, even one refused before the mic opens (whose start would
    /// clear the meter): never the still bars of the last recording.
    @Test func everyPressStartsFromAnEmptyEqualizer() {
        let meter = LevelMeter()
        let h = Self.make(mic: .denied, meter: meter)
        for index in 0..<30 { meter.ingest(rmsDBFS: -30, at: Double(index) * 0.01) }
        #expect(meter.hasReceivedAudio, "levels left over from the last dictation")
        h.controller.handle(.pttDown)
        #expect(h.pill.visiblePhase == .listening)
        #expect(!meter.hasReceivedAudio)
        h.controller.handle(.pttInterrupted)

        // A press while hands-free (stop pending) leaves the live meter alone.
        let live = LevelMeter()
        let locked = Self.make(meter: live)
        locked.controller.send(.handsFreeToggle)
        for index in 0..<30 { live.ingest(rmsDBFS: -30, at: Double(index) * 0.01) }
        locked.controller.handle(.pttDown)
        #expect(locked.controller.machine.mode == .handsFree)
        #expect(live.hasReceivedAudio)
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

    @Test func truncatedGeminiTextIsShownNotPasted() async throws {
        let h = Self.make(keyStatus: .valid(KeyInfo()))
        var pasted: [String] = []
        h.controller.transcribeOverride = { _, _ in throw AppError.openRouterTruncated("so the plan is so the plan is") }
        h.controller.insertOverride = { text, _ in pasted.append(text); return .pasted }
        let recording = Self.recording()
        h.controller.enqueue(recording, engine: .geminiFlash, targetPID: nil)
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
        h.controller.enqueue(long, engine: .parakeet, targetPID: nil)
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

    /// Paste last only pastes (the inserter puts the clipboard back): no copy, no card.
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

    /// The clipboard a dictation's paste puts back is read while it's transcribed, not between the target checks and
    /// ⌘V.
    @Test func aDictationReadsTheClipboardWhileItIsTranscribed() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.transcribe-thing.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let canvas = LazyType()
        let canvasType = NSPasteboard.PasteboardType("com.example.canvas")
        let item = NSPasteboardItem()
        item.setString("user clipboard", forType: .string)
        item.setDataProvider(canvas, forTypes: [canvasType])
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let inserter = TextInserter(pasteboard: pasteboard, system: .init(
            frontmostPID: { 42 }, canPostEvents: { true }, modifiersHeld: { false },
            inspectFocus: { FocusInfo(pid: 42, editability: .editable) }, pasteKeyCode: { 9 },
            postPaste: { _ in true }))
        inserter.restoreDelay = .milliseconds(50)
        let h = Self.make(inserter: inserter)
        var readWhileTranscribing: Int?
        h.controller.transcribeOverride = { _, engine in
            readWhileTranscribing = canvas.requests
            return TranscriptResult(text: "Hello there", engine: engine, processingTime: 0.1)
        }
        h.controller.enqueue(Self.recording(), engine: .parakeet, targetPID: 42)
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(readWhileTranscribing == 1)
        #expect(pasteboard.string(forType: .string) == "Hello there", "what ⌘V pastes")
        try await waitUntil { pasteboard.string(forType: .string) == "user clipboard" }
        #expect(pasteboard.data(forType: canvasType) == Data(canvasType.rawValue.utf8))
    }

    /// Nowhere to paste leaves the clipboard alone: a card holds the text, as after a dictation, and only its Copy
    /// puts it on the clipboard.
    @Test(arguments: [(InsertionOutcome.noEditableTarget, "Nowhere to paste", false), (.failed("no ⌘V"), "Couldn’t paste", true)])
    func pasteLastWithNowhereToPasteOffersTheTextToCopy(_ outcome: InsertionOutcome, _ title: String,
                                                       _ offersPasteHere: Bool) async throws {
        let h = Self.make()
        h.history.upsert(TranscriptEntry(text: "last words", engine: .parakeet, audioDuration: 1, voicedSeconds: 1))
        var copied: [String] = []
        h.controller.pasteLastOverride = { _ in outcome }
        h.controller.copyOverride = { copied.append($0) }
        h.controller.pasteLast()
        try await waitUntil { !h.toasts.notices.isEmpty }
        #expect(copied.isEmpty)
        let card = try #require(h.toasts.notices.first)
        #expect(card.title == title)
        #expect(card.transcript == "last words")
        #expect(card.actions.contains { $0.kind == .pasteText("last words") } == offersPasteHere)
        h.controller.perform(try #require(card.actions.first { $0.kind == .copyText("last words") }), from: card)
        #expect(copied == ["last words"])
    }

    /// Without Accessibility nothing is pasted or copied: the notice holds the text until the user copies it.
    @Test func withoutAccessibilityTheTextWaitsInTheNoticeUncopied() async throws {
        let h = Self.make()
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "Hello there", engine: engine, processingTime: 0.1) }
        h.controller.insertOverride = { _, _ in .accessibilityMissing }
        var copied: [String] = []
        h.controller.copyOverride = { copied.append($0) }
        h.controller.enqueue(Self.recording(), engine: .parakeet, targetPID: nil)
        try await waitUntil { h.toasts.notices.contains { $0.dedupeKey == "error.accessibilityMissing" } }
        let notice = try #require(h.toasts.notices.first { $0.dedupeKey == "error.accessibilityMissing" })
        #expect(notice.transcript == "Hello there")
        #expect(notice.actions.map(\.title) == ["Allow Access", "Copy"])
        #expect(copied.isEmpty)
        h.controller.perform(try #require(notice.actions.first { $0.kind == .copyText("Hello there") }), from: notice)
        #expect(copied == ["Hello there"])
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
        h.controller.enqueue(r, engine: .geminiFlash, targetPID: nil)
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        let notice = try #require(h.toasts.notices.first { $0.recordingID == r.id })
        #expect(notice.actions.contains { $0.kind == .retryWith(.parakeet) })
    }

    @Test func pasteHereThatFailsBringsTheTextBack() async throws {
        let h = Self.make()
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "Hello there", engine: engine, processingTime: 0.1) }
        h.controller.insertOverride = { _, _ in .failed("no event source") }
        h.controller.enqueue(Self.recording(), engine: .parakeet, targetPID: nil)
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

// MARK: - The pill's live count

/// A streamed answer's count reaches the processing pill through `streamed(_:for:)`, the progress every dictation
/// on a streamed model reports: the newest dictation's, only while it's under way, and never for Home's work.
@MainActor
@Suite(.serialized) struct StreamingPillTests {
    private typealias H = DictationControllerTests

    /// Holds a job's transcription (or clean-up) until opened.
    @MainActor private final class Gate {
        var isOpen = false
        func wait() async throws { while !isOpen { try await Task.sleep(for: .milliseconds(5)) } }
    }

    private func harness(persistsHistory: Bool = false) -> H.Harness {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: persistsHistory)
        h.pill.timing.counterDelay = 0.05
        h.controller.insertOverride = { _, _ in .pasted }
        return h
    }

    private func hold(_ h: H.Harness, _ gate: Gate) {
        h.controller.transcribeOverride = { _, engine in
            try await gate.wait()
            return TranscriptResult(text: "dictated", engine: engine, processingTime: 0.1)
        }
    }

    @Test func aGeminiJobsCountReachesThePill() async throws {
        let h = harness()
        let gate = Gate()
        hold(h, gate)
        let r = H.recording()
        h.controller.enqueue(r, engine: .geminiFlash, targetPID: nil)
        #expect(h.pill.phase == .processing && h.pill.tokenCount == nil, "nothing to count before the stream starts")
        // No history yet: the visible text, about 4 characters a token.
        h.controller.streamed(ChatStreamProgress(reasoningCharacters: 800), for: r.id)
        #expect(h.pill.tokenCount == PillTokenCount(phase: .thinking, tokens: 200))
        #expect(h.pill.tokenCount.map { "\($0.text) \($0.word)" } == "~200 thinking")
        try await waitUntil { h.pill.showsCounter }
        #expect(PillView(model: h.pill).visual == .processing(afterHandsFree: false, counting: true))
        // The answer starts: writing, counted from its own first tokens.
        h.controller.streamed(ChatStreamProgress(reasoningCharacters: 900, outputCharacters: 25), for: r.id)
        #expect(h.pill.tokenCount == PillTokenCount(phase: .writing, tokens: 10))
        #expect(h.pill.showsCounter)
        gate.isOpen = true
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(h.pill.tokenCount == nil && !h.pill.showsCounter)
    }

    @Test func aParakeetJobHasNoCount() async throws {
        let h = harness()
        let gate = Gate()
        hold(h, gate)
        for engine in [EngineID.parakeet, .parakeetCloud] {
            let r = H.recording()
            h.controller.enqueue(r, engine: engine, targetPID: nil)
            h.controller.streamed(ChatStreamProgress(reasoningCharacters: 800, outputCharacters: 80), for: r.id)
            #expect(h.pill.phase == .processing && h.pill.tokenCount == nil, "\(engine): no tokens, only the dots")
        }
        gate.isOpen = true
        try await waitUntil { h.controller.machine.activeJobs == 0 }
    }

    /// On clean-up, Parakeet's part has nothing to count; GPT-6 Luna's answer does, calibrated by its own history.
    @Test func aCleanupJobCountsOnlyItsWriting() async throws {
        let h = harness()
        // Luna wrote 100 characters for 50 tokens before; Gemini's ratio must not leak into it.
        let raw = TranscriptResult(text: "raw", engine: .parakeet, processingTime: 1)
        var luna = TranscriptResult(text: String(repeating: "a", count: 100), engine: .parakeet, processingTime: 1)
        luna.modelID = "openai/gpt-6-luna-20260922"
        luna.usage = TokenUsage(completionTokens: 50, reasoningTokens: 0)
        var gemini = TranscriptResult(text: String(repeating: "b", count: 100), engine: .geminiFlash, processingTime: 1)
        gemini.modelID = "google/gemini-3.8-flash"
        gemini.usage = TokenUsage(completionTokens: 900, reasoningTokens: 0)
        h.history.upsert(TranscriptEntry(engine: .parakeet, audioDuration: 5, voicedSeconds: 4,
                                         versions: [raw.version(), luna.version(.cleanup(of: .parakeet, by: .gpt6Luna))]))
        h.history.upsert(TranscriptEntry(engine: .geminiFlash, audioDuration: 5, voicedSeconds: 4,
                                         versions: [gemini.version()]))
        let transcription = Gate(), cleanup = Gate()
        hold(h, transcription)
        h.controller.cleanupOverride = { text, source in
            try await cleanup.wait()
            return TranscriptResult(text: "Dictated.", engine: source, processingTime: 0.2)
        }
        let r = H.recording()
        h.controller.enqueue(r, engine: .parakeet, targetPID: nil, cleansUp: true)
        h.controller.streamed(ChatStreamProgress(outputCharacters: 40), for: r.id)
        #expect(h.pill.tokenCount == nil, "Parakeet streams nothing")
        transcription.isOpen = true
        try await waitUntil { h.controller.runningVersions[r.id] == .cleanup(of: .parakeet, by: .gpt6Luna) }
        #expect(h.pill.tokenCount == nil, "the clean-up starts from nothing")
        h.controller.streamed(ChatStreamProgress(outputCharacters: 40), for: r.id)
        #expect(h.pill.tokenCount == PillTokenCount(phase: .writing, tokens: 20), "Luna's half a token a character")
        #expect(h.pill.sessionModel == .cleanup)
        cleanup.isOpen = true
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(h.pill.tokenCount == nil)
    }

    /// With several dictations in flight the pill speaks for the newest, its count as its tint.
    @Test func theCountFollowsTheNewestJob() async throws {
        let h = harness()
        let gate = Gate()
        hold(h, gate)
        let older = H.recording(), newer = H.recording()
        h.controller.enqueue(older, engine: .geminiFlash, targetPID: nil)
        h.controller.enqueue(newer, engine: .geminiFlash, targetPID: nil)
        h.controller.streamed(ChatStreamProgress(reasoningCharacters: 4_000), for: older.id)
        #expect(h.pill.tokenCount == nil, "the newest hasn't streamed yet")
        h.controller.streamed(ChatStreamProgress(reasoningCharacters: 40), for: newer.id)
        #expect(h.pill.tokenCount == PillTokenCount(phase: .thinking, tokens: 10))
        h.controller.streamed(ChatStreamProgress(reasoningCharacters: 8_000), for: older.id)
        #expect(h.pill.tokenCount == PillTokenCount(phase: .thinking, tokens: 10))
        gate.isOpen = true
        try await waitUntil { h.controller.machine.activeJobs == 0 }
    }

    @Test func progressAfterTheTextLandsIsIgnored() async throws {
        let h = harness()
        let r = H.recording()
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "dictated", engine: engine, processingTime: 0.1) }
        h.controller.enqueue(r, engine: .geminiFlash, targetPID: nil)
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        h.controller.streamed(ChatStreamProgress(reasoningCharacters: 800, outputCharacters: 80), for: r.id)
        #expect(h.pill.tokenCount == nil && h.pill.phase == .rest)
    }

    // MARK: The whole way, through the service and a canned stream

    /// A harness whose OpenRouter requests get `replies` (`StubURLProtocol`), each a stream that stays open until
    /// the job is canceled.
    private func streamingHarness(_ replies: [StubURLProtocol.Reply], persistsHistory: Bool = false) -> (H.Harness, String) {
        let (client, host) = StubURLProtocol.client(replies)
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: persistsHistory, client: client)
        h.pill.timing.counterDelay = 0.05
        h.controller.insertOverride = { _, _ in Issue.record("canceled before its text came"); return .pasted }
        return (h, host)
    }

    /// `events` streamed, then nothing more: the model still at work.
    private func openStream(_ events: [String]) -> StubURLProtocol.Reply {
        .stream(": OPENROUTER PROCESSING\n\n" + SSE.stream(events, done: false), staysOpen: true)
    }

    /// A Gemini dictation's own stream reaches the pill: its progress closure is wired to this attempt of this job.
    @Test func aGeminiStreamMovesThePillsCount() async throws {
        let (h, host) = streamingHarness([openStream([SSE.chunk(reasoning: String(repeating: "Listening. ", count: 40))])])
        h.controller.enqueue(H.recording(), engine: .geminiFlash, targetPID: nil)
        try await waitUntil { h.pill.tokenCount != nil }
        #expect(h.pill.tokenCount == PillTokenCount(phase: .thinking, tokens: 110), "440 characters, 4 a token")
        try await waitUntil { h.pill.showsCounter }
        #expect(StubURLProtocol.registry.requests(for: host).count == 1)
        h.controller.handle(.cancel)
        #expect(h.controller.machine.activeJobs == 0 && h.pill.tokenCount == nil)
    }

    /// A clean-up's stream counts its writing, once Parakeet's text is in.
    @Test func aCleanupStreamMovesThePillsCount() async throws {
        let (h, _) = streamingHarness([openStream([SSE.chunk(content: String(repeating: "Tidy. ", count: 10))])])
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "um tidy", engine: engine, processingTime: 0.1) }
        h.controller.enqueue(H.recording(), engine: .parakeet, targetPID: nil, cleansUp: true)
        try await waitUntil { h.pill.tokenCount != nil }
        #expect(h.pill.tokenCount == PillTokenCount(phase: .writing, tokens: 24), "60 characters, 2.5 a token")
        #expect(h.pill.sessionModel == .cleanup)
        h.controller.handle(.cancel)
        #expect(h.controller.machine.activeJobs == 0 && h.pill.tokenCount == nil)
    }

    /// Transcribe With from Home runs beside dictations and never reaches the pill: its request streams, but no
    /// count comes of it.
    @Test func homeWorkNeverCountsInThePill() async throws {
        let (h, host) = streamingHarness([openStream([SSE.chunk(reasoning: String(repeating: "Listening. ", count: 40))])],
                                         persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "parakeet text", engine: engine, processingTime: 0.1) }
        h.controller.insertOverride = { _, _ in .pasted }
        let r = H.recording()
        h.controller.enqueue(r, engine: .parakeet, targetPID: nil)
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id) != nil }
        h.controller.transcribeOverride = nil
        h.controller.retry(try #require(h.history.entry(id: r.id)), with: .geminiFlash)
        #expect(h.controller.homeWork[r.id] == .transcription(.geminiFlash))
        try await waitUntil { !StubURLProtocol.registry.requests(for: host).isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.pill.tokenCount == nil && h.pill.phase == .rest)
        h.controller.cancelHomeWork(for: r.id)
        try await waitUntil { h.controller.homeWork.isEmpty }
        #expect(h.pill.tokenCount == nil)
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

extension TextInserter {
    /// Test harnesses: a private pasteboard and a system that never posts ⌘V, so a test that reaches the inserter
    /// (without an insertion override) can't touch the user's clipboard or type into the frontmost app.
    static func inert() -> TextInserter {
        TextInserter(pasteboard: NSPasteboard(name: NSPasteboard.Name("dev.transcribe-thing.tests.inert")), system: .init(
            frontmostPID: { nil }, canPostEvents: { false }, modifiersHeld: { false },
            inspectFocus: { .unknown }, pasteKeyCode: { 9 }, postPaste: { _ in false }))
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
            "Copy Last Transcript", "—",
            "Microphone", "—",
            "Settings…", "—", "Quit",
        ])
        #expect(menu.items.first?.isEnabled == false)
    }

    /// The status line names the main model, whichever it is, and its status: clean-up's is Parakeet's until it's
    /// ready, then the key's.
    @Test func theStatusLineNamesTheMainModel() throws {
        let env = AppEnvironment.preview()
        func status() throws -> String {
            try #require(env.menuBar.builder.makeMenu(includeQuit: true).items.first).title
        }
        env.settings.lineup.main = .gemini
        #expect(try status() == "Gemini 3.8 Flash · Ready")
        env.settings.lineup.main = .cleanup
        #expect(try status() == "Parakeet v3 + GPT-6 Luna · Ready")
        env.settings.parakeetEngine = .parakeetCloud
        env.settings.lineup.main = .parakeet
        #expect(try status() == "Parakeet v3 · Cloud · Ready")
        let keyless = OpenRouterAccount.preview(status: .missing)
        #expect(MenuBuilder.status(of: .gemini, parakeet: .parakeet, models: env.models, account: keyless).text
            == "Needs key")
        #expect(MenuBuilder.status(of: .cleanup, parakeet: .parakeet, models: env.models, account: keyless).text
            == "Needs key")
        let bare = ModelStore.preview(states: [.parakeet: .notInstalled])
        #expect(MenuBuilder.status(of: .cleanup, parakeet: .parakeet, models: bare, account: keyless).text
            == "Not downloaded", "Parakeet first")
    }

    /// The model is chosen in Models (and per dictation, from the pill): neither menu offers it.
    @Test func theMenuHasNoModelItem() {
        let env = AppEnvironment.preview()
        for includeQuit in [true, false] {
            let menu = env.menuBar.builder.makeMenu(includeQuit: includeQuit)
            #expect(!menu.items.contains { $0.title == "Model" || $0.title == "Manage Models…" })
            #expect(!menu.items.contains { $0.submenu?.items.contains { $0.title == "Manage Models…" } == true })
        }
    }

    @Test func pillMenuHasNoQuit() {
        let env = AppEnvironment.preview()
        let menu = env.menuBar.builder.makeMenu(includeQuit: false)
        #expect(!menu.items.contains { $0.title == "Quit" })
        #expect(menu.items.last?.title == "Settings…")
    }

    /// ⌘, and ⌘Q are gone (no quitting by accident); Copy Last Transcript has no shortcut of its own.
    @Test func noMisleadingKeyEquivalents() throws {
        let env = AppEnvironment.preview()
        let menu = env.menuBar.builder.makeMenu(includeQuit: true)
        for title in ["Settings…", "Quit", "Copy Last Transcript"] {
            let item = try #require(menu.items.first { $0.title == title })
            #expect(item.keyEquivalent.isEmpty, "\(title)")
        }
    }

    /// The menu copies the last transcript (to stay on the clipboard); pasting it is the Paste last shortcut's job.
    @Test func theMenuCopiesTheLastTranscriptAndNeverPastesIt() throws {
        let env = AppEnvironment.preview()
        var copied: [String] = []
        env.dictation.copyOverride = { copied.append($0) }
        let menu = env.menuBar.builder.makeMenu(includeQuit: true)
        #expect(!menu.items.contains { $0.title == "Paste Last Transcript" })
        let item = try #require(menu.items.first { $0.title == "Copy Last Transcript" })
        #expect(item.isEnabled)
        let last = try #require(env.history.lastSuccessfulText)
        NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item)
        #expect(copied == [last])
    }

    @Test func copyLastIsDisabledWithoutHistory() throws {
        let env = AppEnvironment.preview()
        env.history.clearAll()
        let menu = env.menuBar.builder.makeMenu(includeQuit: true)
        let copy = try #require(menu.items.first { $0.title == "Copy Last Transcript" })
        #expect(!copy.isEnabled)
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
            "—", "Cancel Dictation", "Copy Last Transcript", "—",
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
                "Parakeet v3 · Listening…", "—", "Finish Dictation", "Cancel Dictation", "Copy Last Transcript", "—",
            ])
            Self.expectTidySeparators(menu, "hands-free")
        }
        // Even a hands-free shortcut the menu could draw isn't Finish's: it only starts hands-free.
        env.settings.shortcuts[.handsFree] = Shortcut(modifiers: [.init(.control), .init(.option)], keyCode: KeyCode.space)
        #expect(MenuActionItem.keyEquivalent(for: try #require(env.settings.shortcuts[.handsFree])) != nil)
        let finish = try #require(env.menuBar.builder.makeMenu(includeQuit: true).items.first { $0.title == "Finish Dictation" })
        #expect(finish.keyEquivalent.isEmpty)
    }

    @Test func finishDictationFinishesHandsFree() async throws {
        let env = Self.dictatingEnvironment()
        env.dictation.playCueOverride = { _ in }
        env.dictation.transcribeOverride = { _, engine in TranscriptResult(text: "", engine: engine, processingTime: 0.1) }
        env.dictation.insertOverride = { _, _ in Issue.record("nothing should be pasted"); return .pasted }
        env.dictation.send(.handsFreeToggle)
        let finish = try #require(env.menuBar.builder.makeMenu(includeQuit: true).items.first { $0.title == "Finish Dictation" })
        NSApplication.shared.sendAction(try #require(finish.action), to: finish.target, from: finish)
        #expect(env.dictation.machine.capture == .idle)
        try await waitUntil { env.dictation.machine.activeJobs == 0 }
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
