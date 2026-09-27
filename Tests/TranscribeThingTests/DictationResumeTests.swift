import Foundation
import Testing
@testable import TranscribeThing

// MARK: - Undo after a cancel resumes the dictation; failures don't invite a hopeless retry loop

@MainActor
@Suite(.serialized) struct DictationResumeTests {
    typealias Harness = DictationControllerTests.Harness

    /// A controller whose toasts route their buttons the way the app does (ToastCenter → controller) and whose
    /// clock is driven by the test. Every transcription is counted.
    @MainActor final class Rig {
        let h: Harness
        var now: TimeInterval = 100
        var transcribed: [Recording] = []
        var pasted: [String] = []
        var result: @MainActor (Recording, EngineID) async throws -> String = { _, _ in "" }

        init(keyStatus: KeyStatus = .missing) {
            h = DictationControllerTests.make(keyStatus: keyStatus)
            h.controller.clock = { [unowned self] in now }
            h.controller.transcribeOverride = { [unowned self] recording, engine in
                transcribed.append(recording)
                return TranscriptResult(text: try await result(recording, engine), engine: engine, processingTime: 0.1)
            }
            h.controller.insertOverride = { [unowned self] text, _ in
                pasted.append(text)
                return .pasted
            }
            h.toasts.onAction = { [unowned self] notice, action in h.controller.perform(action, from: notice) }
        }

        func notice(_ key: String) -> Notice? { h.toasts.notices.first { $0.dedupeKey == key } }

        /// Clicks the notice's button the way the toast does.
        func click(_ kind: NoticeActionKind, in key: String) throws {
            let notice = try #require(notice(key), "no \(key) notice")
            let action = try #require(notice.actions.first { $0.kind == kind }, "\(key) has no \(kind)")
            h.toasts.perform(action, on: notice)
        }

        /// Push-to-talk held for `seconds`, then Esc.
        func holdThenEsc(_ seconds: TimeInterval) {
            h.controller.handle(.pttDown)
            h.controller.send(.timer(.arming))
            now += seconds
            h.controller.handle(.cancel)
        }
    }

    /// One second of room noise: SpeechAnalyzer counted 0.6 s "voiced" in the user's real recording, but nothing
    /// was said, so Parakeet returns no text.
    static func roomNoise(seconds: Double = 1) -> Recording {
        Recording(samples: Array(repeating: 0.003, count: Int(16_000 * seconds)),
                  speech: SpeechStats(voicedSeconds: 0.6, peakDBFS: -32, isSilent: false))
    }

    static func speech(seconds: Double) -> Recording {
        Recording(samples: Array(repeating: 0.1, count: Int(16_000 * seconds)),
                  speech: SpeechStats(voicedSeconds: seconds * 0.8, peakDBFS: -10, isSilent: false))
    }

    // MARK: The reported loop

    /// Esc before saying anything, then Undo: it used to transcribe the noise, fail with "No text came back ·
    /// Retry", and every Retry click failed the same way under the pointer. Undo now records on instead.
    @Test func undoAfterEscWithNothingSaidRecordsOnInsteadOfTranscribing() async throws {
        let rig = Rig()
        let kept = Self.roomNoise()
        rig.h.recorder.next = kept
        rig.holdThenEsc(1)
        let canceled = try #require(rig.notice("dictation.canceled"))
        #expect(canceled.title == "Dictation canceled")
        #expect(canceled.body == DictationController.undoResumesHint)
        #expect(!rig.h.controller.machine.isRecording)

        rig.now += 3
        try rig.click(.undoCancel, in: "dictation.canceled")
        #expect(rig.h.controller.machine.capture == .locked(startedAt: rig.now - kept.duration))
        #expect(rig.h.recorder.starts == 2)
        #expect(rig.h.recorder.lastPrefix?.id == kept.id)
        #expect(rig.h.pill.phase == .locked)
        let shownStart = try #require(rig.h.pill.recordingStartedAt)
        #expect(abs(Date().timeIntervalSince(shownStart) - kept.duration) < 0.5,
                "the timer counts from the canceled dictation's start")
        #expect(rig.h.hotkeys.isBusy)
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.transcribed.isEmpty, "Undo itself never transcribes")
        #expect(rig.pasted.isEmpty)
        #expect(rig.notice("error.emptyResult.parakeet") == nil)

        // The user talks now and stops: the whole thing is transcribed once and pasted once.
        let rest = Self.speech(seconds: 2)
        rig.h.recorder.next = rest
        rig.result = { _, _ in "hello there" }
        rig.now += 2
        rig.h.controller.send(.pillStop)
        try await waitUntil { rig.pasted == ["hello there"] && rig.h.controller.machine.activeJobs == 0 }
        #expect(rig.transcribed.count == 1)
        let whole = try #require(rig.transcribed.first)
        #expect(whole.id == kept.id)
        #expect(whole.samples.count == kept.samples.count + rest.samples.count)
        #expect(whole.speech.voicedSeconds == kept.speech.voicedSeconds + rest.speech.voicedSeconds)
    }

    /// Parakeet on this Mac gives the same nothing for the same audio: no Retry, only the cloud model when the
    /// key works.
    @Test func noTextFromTheLocalModelOffersNoRetry() async throws {
        for (key, expected) in [(KeyStatus.valid(KeyInfo()), [NoticeActionKind.retryWith(.parakeetCloud)]),
                                (.missing, []), (.invalid("401"), [])] {
            let rig = Rig(keyStatus: key)
            let r = Self.roomNoise()
            rig.h.controller.enqueue(r, engine: .parakeet, delivery: .paste(targetPID: nil))
            try await waitUntil { rig.h.controller.machine.activeJobs == 0 }
            let notice = try #require(rig.notice("error.emptyResult.parakeet"))
            #expect(notice.actions.map(\.kind) == expected, "\(key)")
            #expect(notice.actions.first.map(\.title) == (expected.isEmpty ? nil : "Try in the cloud"))
            #expect(rig.transcribed.count == 1)
            #expect(rig.h.history.entry(id: r.id)?.status == .failed, "kept in history for the Hub's Retry With")
        }
    }

    @Test func noTextFromACloudModelStillOffersRetry() async throws {
        let rig = Rig(keyStatus: .valid(KeyInfo()))
        rig.h.controller.enqueue(Self.roomNoise(), engine: .parakeetCloud, delivery: .paste(targetPID: nil))
        try await waitUntil { rig.h.controller.machine.activeJobs == 0 }
        let notice = try #require(rig.notice("error.emptyResult.parakeetCloud"))
        #expect(notice.actions.first?.kind == .retry)
    }

    /// Clicking Retry again and again on a failure that comes straight back plays its sound once per 2 s.
    @Test func aRepeatedFailureReplaysItsSoundAtMostEveryTwoSeconds() async throws {
        let rig = Rig(keyStatus: .valid(KeyInfo()))
        rig.h.controller.enqueue(Self.roomNoise(), engine: .geminiFlash, delivery: .paste(targetPID: nil))
        try await waitUntil { rig.notice("error.emptyResult.geminiFlash") != nil }
        #expect(rig.notice("error.emptyResult.geminiFlash")?.sound == .alert)

        var sounds: [SoundEffect?] = []
        for step in [0.3, 0.3, 0.3, 1.5, 0.3] {
            rig.now += step
            let before = try #require(rig.notice("error.emptyResult.geminiFlash")).id
            try rig.click(.retry, in: "error.emptyResult.geminiFlash")
            try await waitUntil { rig.notice("error.emptyResult.geminiFlash").map { $0.id != before } ?? false }
            sounds.append(rig.notice("error.emptyResult.geminiFlash")?.sound)
        }
        #expect(sounds == [nil, nil, nil, .alert, nil], "quiet until 2 s after the last sound")
        #expect(rig.transcribed.count == 6, "one transcription per click, never more")
    }

    // MARK: Undo resumes, whatever stopped the dictation

    @Test func undoAfterPushToTalkWasStoppedByAnotherKeyRecordsOn() throws {
        let rig = Rig()
        let kept = Self.speech(seconds: 2)
        rig.h.recorder.next = kept
        rig.h.controller.handle(.pttDown)
        rig.h.controller.send(.timer(.arming))
        rig.now += 2
        rig.h.controller.handle(.pttInterrupted)
        let stopped = try #require(rig.notice("dictation.canceled"))
        #expect(stopped.title == "Dictation stopped")
        #expect(stopped.body?.hasSuffix(DictationController.undoResumesHint) == true)
        try rig.click(.undoCancel, in: "dictation.canceled")
        #expect(rig.h.controller.machine.mode == .handsFree)
        #expect(rig.h.recorder.lastPrefix?.id == kept.id)
    }

    @Test func undoAfterEscWhileProcessingRecordsOnWithTheWholeRecording() async throws {
        let rig = Rig()
        let kept = Self.speech(seconds: 3)
        rig.h.recorder.next = kept
        rig.result = { _, _ in
            try await Task.sleep(for: .milliseconds(150))
            return "first"
        }
        rig.h.controller.send(.handsFreeToggle)
        rig.now += 3
        rig.h.controller.send(.pillStop)
        try await waitUntil { rig.transcribed.count == 1 }
        rig.h.controller.handle(.cancel)
        #expect(rig.h.controller.machine.activeJobs == 0)
        #expect(rig.notice("dictation.canceled")?.recordingID == kept.id)

        try rig.click(.undoCancel, in: "dictation.canceled")
        #expect(rig.h.controller.machine.capture.isListeningOrLocked)
        #expect(rig.h.recorder.lastPrefix?.id == kept.id)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.pasted.isEmpty, "the canceled transcription never lands")

        rig.h.recorder.next = Self.speech(seconds: 1)
        rig.result = { _, _ in "all of it" }
        rig.now += 1
        rig.h.controller.send(.handsFreeToggle)
        try await waitUntil { rig.pasted == ["all of it"] && rig.h.controller.machine.activeJobs == 0 }
        #expect(rig.transcribed.last?.id == kept.id)
        #expect(rig.transcribed.last?.duration == 4)
    }

    @Test func escAfterUndoCancelsTheWholeRecordingAndUndoResumesItAgain() throws {
        let rig = Rig()
        let kept = Self.speech(seconds: 2)
        rig.h.recorder.next = kept
        rig.holdThenEsc(2)
        try rig.click(.undoCancel, in: "dictation.canceled")

        rig.h.recorder.next = Self.speech(seconds: 1.5)
        rig.now += 1.5
        rig.h.controller.handle(.cancel)
        #expect(!rig.h.controller.machine.isRecording)
        let again = try #require(rig.notice("dictation.canceled"))
        #expect(again.recordingID == kept.id)

        try rig.click(.undoCancel, in: "dictation.canceled")
        #expect(rig.h.recorder.lastPrefix?.duration == 3.5, "the kept part and what came after it")
        #expect(rig.h.controller.machine.recordingStartedAt == rig.now - 3.5)
        rig.h.controller.send(.pillCancel)
    }

    /// The canceled entry (long ones are saved to history) becomes the finished dictation: same id, one row.
    @Test func aResumedDictationReplacesItsCanceledHistoryEntry() async throws {
        let rig = Rig()
        let kept = Self.speech(seconds: 21)
        rig.h.recorder.next = kept
        rig.h.controller.send(.handsFreeToggle)
        rig.now += 21
        rig.h.controller.handle(.cancel)
        #expect(rig.h.history.entries.map(\.id) == [kept.id])
        #expect(rig.h.history.entries.first?.status == .cancelled)

        try rig.click(.undoCancel, in: "dictation.canceled")
        rig.h.recorder.next = Self.speech(seconds: 1)
        rig.result = { _, _ in "done" }
        rig.h.controller.send(.pillStop)
        try await waitUntil { rig.pasted == ["done"] && rig.h.controller.machine.activeJobs == 0 }
        #expect(rig.h.history.entries.count == 1)
        let entry = try #require(rig.h.history.entries.first)
        #expect(entry.id == kept.id)
        #expect(entry.status == .success)
        #expect(entry.text == "done")
        #expect(entry.audioDuration == 22)
    }

    @Test func undoWhenTheMicCantStartShowsWhyAndKeepsTheAudio() throws {
        let rig = Rig()
        let kept = Self.speech(seconds: 2)
        rig.h.recorder.next = kept
        rig.holdThenEsc(2)

        rig.h.recorder.startError = .noMicrophone
        try rig.click(.undoCancel, in: "dictation.canceled")
        #expect(!rig.h.controller.machine.isRecording)
        #expect(rig.notice("error.noMicrophone") != nil)
        #expect(rig.notice("dictation.canceled")?.recordingID == kept.id, "Undo is still there")
        #expect(rig.transcribed.isEmpty)

        rig.h.recorder.startError = nil
        try rig.click(.undoCancel, in: "dictation.canceled")
        #expect(rig.h.controller.machine.mode == .handsFree)
        #expect(rig.h.recorder.lastPrefix?.id == kept.id)
        rig.h.controller.send(.pillCancel)
    }

    /// Bluetooth mics can fail a moment after starting: the resumed audio isn't lost either.
    @Test func aResumedCaptureThatFailsLaterKeepsItsAudioForUndo() throws {
        let rig = Rig()
        let kept = Self.speech(seconds: 2)
        rig.h.recorder.next = kept
        rig.holdThenEsc(2)
        try rig.click(.undoCancel, in: "dictation.canceled")
        rig.h.toasts.dismissAll()

        rig.h.recorder.next = Self.speech(seconds: 0.5)
        rig.h.controller.send(.captureFailed(.microphoneNotResponding("no audio")))
        #expect(!rig.h.controller.machine.isRecording)
        #expect(rig.notice("error.microphoneNotResponding") != nil)
        let undo = try #require(rig.notice("dictation.canceled"))
        #expect(undo.recordingID == kept.id)
        try rig.click(.undoCancel, in: "dictation.canceled")
        #expect(rig.h.recorder.lastPrefix?.duration == 2.5)
        rig.h.controller.send(.pillCancel)
    }

    @Test func undoWhileAnotherDictationRecordsKeepsTheCanceledOne() throws {
        let rig = Rig()
        let kept = Self.speech(seconds: 2)
        rig.h.recorder.next = kept
        rig.holdThenEsc(2)
        let canceled = try #require(rig.notice("dictation.canceled"))

        rig.h.recorder.next = Self.speech(seconds: 1)
        rig.h.controller.send(.handsFreeToggle)
        rig.h.toasts.perform(canceled.actions[0], on: canceled)
        #expect(rig.h.recorder.lastPrefix == nil, "the running dictation is left alone")
        #expect(rig.h.controller.machine.mode == .handsFree)
        let offered = try #require(rig.notice("dictation.canceled"))
        #expect(offered.recordingID == kept.id)
        #expect(offered.body == "Finish this dictation first, then Undo.")
        rig.h.controller.send(.pillCancel)
    }

    /// A Hub "Retry With" canceled with Esc is a transcription, not a dictation: Undo finishes it into history.
    @Test func undoOfACanceledHubTranscriptionTranscribesItAfterAll() async throws {
        let rig = Rig()
        rig.result = { _, _ in
            try await Task.sleep(for: .milliseconds(100))
            return "from the hub"
        }
        let r = Self.speech(seconds: 2)
        rig.h.controller.enqueue(r, engine: .parakeet, delivery: .historyOnly)
        rig.h.controller.handle(.cancel)
        let canceled = try #require(rig.notice("dictation.canceled"))
        #expect(canceled.title == "Transcription canceled")
        #expect(canceled.body == nil)
        try rig.click(.undoCancel, in: "dictation.canceled")
        #expect(rig.h.recorder.starts == 0, "no microphone")
        try await waitUntil { rig.h.history.entry(id: r.id)?.status == .success }
        #expect(rig.pasted.isEmpty)
    }

    // MARK: Sequences that used to (or could) loop

    /// Esc before saying anything, Undo, Esc again, Undo again: nothing is transcribed until the user stops, and
    /// the empty result from the model on this Mac then offers nothing to click again.
    @Test func escUndoEscUndoWithNothingSaidNeverTranscribesUntilStopped() async throws {
        let rig = Rig()
        let first = Self.roomNoise()
        rig.h.recorder.next = first
        rig.holdThenEsc(1)
        try rig.click(.undoCancel, in: "dictation.canceled")

        rig.h.recorder.next = Self.roomNoise(seconds: 0.5)
        rig.now += 0.5
        rig.h.controller.handle(.cancel)
        let again = try #require(rig.notice("dictation.canceled"))
        #expect(again.recordingID == first.id)
        try rig.click(.undoCancel, in: "dictation.canceled")
        #expect(rig.h.recorder.lastPrefix?.duration == 1.5)
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.transcribed.isEmpty)
        #expect(rig.h.toasts.notices.allSatisfy { $0.actions.allSatisfy { $0.kind != .retry } })

        rig.h.recorder.next = Self.roomNoise(seconds: 1)
        rig.now += 1
        rig.h.controller.send(.pillStop)
        try await waitUntil { rig.notice("error.emptyResult.parakeet") != nil && rig.h.controller.machine.activeJobs == 0 }
        #expect(rig.transcribed.count == 1)
        #expect(rig.transcribed.first?.duration == 2.5)
        #expect(rig.notice("error.emptyResult.parakeet")?.actions.isEmpty == true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.transcribed.count == 1, "nothing re-queues it on its own")
        #expect(rig.pasted.isEmpty)
    }

    /// Two quick clicks on the same Retry (the toast hasn't gone yet): one retry.
    @Test func doubleClickingRetryOnACloudFailureRetriesOnce() async throws {
        let rig = Rig(keyStatus: .valid(KeyInfo()))
        rig.h.controller.enqueue(Self.roomNoise(), engine: .geminiFlash, delivery: .paste(targetPID: nil))
        try await waitUntil { rig.notice("error.emptyResult.geminiFlash") != nil && rig.h.controller.machine.activeJobs == 0 }
        let failed = try #require(rig.notice("error.emptyResult.geminiFlash"))
        let retry = try #require(failed.actions.first { $0.kind == .retry })
        rig.result = { _, _ in
            try await Task.sleep(for: .milliseconds(100))
            return "second time lucky"
        }
        rig.h.toasts.perform(retry, on: failed)
        rig.h.toasts.perform(retry, on: failed)
        try await waitUntil { rig.pasted == ["second time lucky"] && rig.h.controller.machine.activeJobs == 0 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.transcribed.count == 2, "the failure and one retry")
        #expect(rig.pasted == ["second time lucky"])
    }

    /// Two quick clicks on Undo: one resumed recording.
    @Test func doubleClickingUndoResumesOnce() throws {
        let rig = Rig()
        let kept = Self.speech(seconds: 2)
        rig.h.recorder.next = kept
        rig.holdThenEsc(2)
        let canceled = try #require(rig.notice("dictation.canceled"))
        let undo = try #require(canceled.actions.first { $0.kind == .undoCancel })
        rig.h.toasts.perform(undo, on: canceled)
        rig.h.toasts.perform(undo, on: canceled)
        #expect(rig.h.recorder.starts == 2, "the dictation, then one resume")
        #expect(rig.h.recorder.lastPrefix?.id == kept.id)
        #expect(rig.notice("dictation.canceled") == nil)
        rig.h.controller.send(.pillCancel)
    }

    // MARK: Defenses

    @Test func aRecordingIsNeverQueuedTwice() async throws {
        let rig = Rig()
        var pasting = false, releasePaste = false
        rig.h.controller.insertOverride = { text, _ in
            pasting = true
            while !releasePaste { try? await Task.sleep(for: .milliseconds(10)) }
            rig.pasted.append(text)
            return .pasted
        }
        rig.result = { _, _ in "once" }
        let r = Self.speech(seconds: 2)
        rig.h.controller.enqueue(r, engine: .parakeet, delivery: .paste(targetPID: nil))
        rig.h.controller.enqueue(r, engine: .parakeet, delivery: .paste(targetPID: nil))
        #expect(rig.h.controller.pendingJobCount == 1)
        // Being pasted now (it has left the queue): still not queued again.
        try await waitUntil { pasting }
        rig.h.controller.enqueue(r, engine: .parakeet, delivery: .paste(targetPID: nil))
        releasePaste = true
        try await waitUntil { rig.h.controller.machine.activeJobs == 0 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.transcribed.count == 1)
        #expect(rig.pasted == ["once"])
    }

    @Test func aDictationBeingRecordedOnIsntRetriedFromTheHub() throws {
        let rig = Rig()
        let kept = Self.speech(seconds: 21)
        rig.h.recorder.next = kept
        rig.holdThenEsc(21)
        let entry = try #require(rig.h.history.entry(id: kept.id))
        try rig.click(.undoCancel, in: "dictation.canceled")
        rig.h.controller.retry(entry, with: .parakeet)
        #expect(rig.h.controller.pendingJobCount == 0)
        rig.h.controller.send(.pillCancel)
    }
}
