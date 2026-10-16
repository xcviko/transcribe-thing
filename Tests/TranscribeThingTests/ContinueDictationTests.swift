import Foundation
import Testing
@testable import TranscribeThing

// A dictation the app quit during comes back on Home with Continue. Cut off while it was recorded, Continue records
// on (the Undo machinery: its saved audio first), then the whole of it is transcribed and pasted like a dictation,
// the row becoming its transcript; Transcribe takes what was recorded without recording more. Quit while it was
// transcribed, Continue just transcribes it.

private struct EncodeRefused: Error {}

/// The largest gap between two runs of samples (16-bit quantization allows 1/32,767).
private func maxError(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
}

private func speech(seconds: Double) -> Recording {
    Recording(samples: journalSpeech(seconds: seconds).map { -$0 },
              speech: SpeechStats(voicedSeconds: seconds * 0.75, peakDBFS: -12, isSilent: false))
}

@MainActor
@Suite(.serialized) struct ContinueDictationTests {
    @MainActor final class Rig {
        let h: DictationControllerTests.Harness
        let paths: AppPaths
        var now: TimeInterval = 100
        var transcribed: [(recording: Recording, engine: EngineID)] = []
        var pasted: [String] = []
        var result: @MainActor (Recording) async throws -> String = { _ in "all of it" }

        init() {
            h = DictationControllerTests.make(persistsHistory: true)
            paths = h.paths!
            h.recorder.journal = h.history.journal
            // Kept as WAV: what's read back is what was saved, to the sample.
            h.history.encodeOverride = { _, _ in throw EncodeRefused() }
            // Weak: a test that timed out leaves its controller at work after the rig is gone.
            h.controller.clock = { [weak self] in self?.now ?? 0 }
            h.controller.transcribeOverride = { [weak self] recording, engine in
                guard let self else { throw CancellationError() }
                transcribed.append((recording, engine))
                return TranscriptResult(text: try await result(recording), engine: engine, processingTime: 0.1)
            }
            h.controller.insertOverride = { [weak self] text in
                self?.pasted.append(text)
                return .pasted
            }
            h.toasts.onAction = { [weak self] notice, action in self?.h.controller.perform(action, from: notice) }
        }

        deinit {
            try? FileManager.default.removeItem(at: paths.root)
        }

        /// The app launches and finds a journal an earlier run left: cut off while it recorded `samples`, or with
        /// its recording ended. Returns the row it comes back as.
        func launch(with samples: [Float], cutOff: Bool = true, engine: EngineID = .parakeet,
                    mode: DictationMachine.Mode = .pushToTalk) async throws -> TranscriptEntry {
            let info = RecordingJournal.Info(id: UUID(), startedAt: Date().addingTimeInterval(-600),
                                             engine: engine.rawValue, mode: mode.rawValue,
                                             deviceName: "MacBook Pro Microphone", continues: false)
            if cutOff {
                try leaveCutOffJournal(in: paths.journals, info, samples: samples)
            } else {
                let earlier = RecordingJournal(directory: paths.journals)
                earlier.begin(info) { _ in [] }
                earlier.end(info.id, samples: samples)
                await earlier.settle()
            }
            h.history.load()
            try await waitUntil { self.h.history.isLoaded }
            await h.history.waitForRecovery()
            return try #require(h.history.entry(id: info.id))
        }

        func notice(_ key: String) -> Notice? { h.toasts.notices.first { $0.dedupeKey == key } }

        var journalFiles: Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: paths.journals.path)) ?? [])
        }

        func savedSamples(of id: UUID) -> Int? {
            h.history.entry(id: id).flatMap { h.history.loadRecording(for: $0) }?.samples.count
        }
    }

    @Test func continueRecordsOnThenTranscribesAndPastesAllOfIt() async throws {
        let rig = Rig()
        let saved = journalSpeech(seconds: 3)
        let entry = try await rig.launch(with: saved)
        #expect(entry.interruption == .whileRecording)
        #expect(entry.errorMessage == "The app quit while you were recording")

        let more = speech(seconds: 2)
        rig.h.recorder.next = more
        rig.h.controller.continueDictation(entry)
        try await waitUntil { rig.h.recorder.starts == 1 }
        #expect(rig.h.recorder.lastPrefix?.id == entry.id, "the saved recording comes first")
        #expect(rig.h.controller.machine.mode == .handsFree, "it records on hands-free, as Undo does")
        #expect(rig.h.pill.phase == .locked)
        #expect(rig.h.controller.recordingOnID == entry.id, "its row says it's being recorded")
        #expect(rig.h.controller.isInFlight(entry.id))
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.transcribed.isEmpty, "nothing is transcribed until it's stopped")
        await rig.h.history.journal?.settle()
        #expect(rig.journalFiles == ["\(entry.id.uuidString).wav", "\(entry.id.uuidString).json"],
                "on disk again while it records: quitting now loses nothing")

        rig.now += 2
        rig.h.controller.send(.pillStop)
        try await waitUntil { rig.pasted == ["all of it"] && rig.h.controller.machine.activeJobs == 0 }
        #expect(rig.transcribed.count == 1)
        let (whole, engine) = try #require(rig.transcribed.first)
        #expect(engine == .parakeet, "the row's model")
        #expect(whole.id == entry.id)
        #expect(whole.samples.count == saved.count + more.samples.count)
        #expect(maxError(Array(whole.samples.prefix(saved.count)), saved) <= 1.0 / 32_767, "the saved part, as saved")
        #expect(Array(whole.samples.suffix(more.samples.count)) == more.samples, "then the new part")
        #expect(rig.h.controller.recordingOnID == nil)

        #expect(rig.h.history.entries.map(\.id) == [entry.id], "the same row")
        let row = try #require(rig.h.history.entry(id: entry.id))
        #expect(row.status == .success && row.text == "all of it")
        #expect(row.interruption == nil && row.errorMessage == nil)
        #expect(row.mode == .pushToTalk, "pasted by the rules of how it was first dictated")
        #expect(abs(row.audioDuration - 5) < 0.001)
        try await waitUntil { rig.savedSamples(of: entry.id) == saved.count + more.samples.count }
        try await waitUntil { rig.journalFiles.isEmpty }
    }

    /// A few words more, or none: the whole of it is still transcribed (its saved part has the speech).
    @Test func aVeryShortNewPartStillTranscribesTheWhole() async throws {
        let rig = Rig()
        let saved = journalSpeech(seconds: 2)
        let entry = try await rig.launch(with: saved)
        rig.h.recorder.next = Recording(samples: Array(repeating: 0, count: 1_600),
                                        speech: SpeechStats(voicedSeconds: 0, peakDBFS: -90, isSilent: true))
        rig.h.controller.continueDictation(entry)
        try await waitUntil { rig.h.recorder.starts == 1 }
        rig.now += 0.1
        rig.h.controller.send(.pillStop)
        try await waitUntil { rig.pasted == ["all of it"] && rig.h.controller.machine.activeJobs == 0 }
        #expect(rig.transcribed.first?.recording.samples.count == saved.count + 1_600)
        #expect(rig.h.history.entry(id: entry.id)?.status == .success)
    }

    /// Esc on the continued recording loses nothing: the row keeps all of it, still to continue, and the cancel
    /// notice's Undo records on as Continue would.
    @Test func escOnTheContinuedRecordingKeepsTheRowToContinue() async throws {
        let rig = Rig()
        let saved = journalSpeech(seconds: 3)
        let entry = try await rig.launch(with: saved)
        let more = speech(seconds: 1)
        rig.h.recorder.next = more
        rig.h.controller.continueDictation(entry)
        try await waitUntil { rig.h.recorder.starts == 1 }
        rig.now += 1
        rig.h.controller.handle(.cancel)
        #expect(!rig.h.controller.machine.isRecording)
        #expect(rig.h.controller.recordingOnID == nil)
        #expect(rig.notice("dictation.canceled")?.recordingID == entry.id)

        let row = try #require(rig.h.history.entry(id: entry.id))
        #expect(row.status == .failed && row.interruption == .whileRecording)
        #expect(row.errorMessage == entry.errorMessage && row.mode == .pushToTalk && row.engine == .parakeet)
        #expect(abs(row.audioDuration - 4) < 0.001, "what was said after Continue is kept too")
        try await waitUntil { rig.savedSamples(of: entry.id) == saved.count + more.samples.count }
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.transcribed.isEmpty && rig.pasted.isEmpty)

        // Continue again picks up after all of it.
        rig.h.recorder.next = speech(seconds: 1)
        rig.h.controller.continueDictation(try #require(rig.h.history.entry(id: entry.id)))
        try await waitUntil { rig.h.recorder.starts == 2 }
        #expect(rig.h.recorder.lastPrefix?.samples.count == saved.count + more.samples.count)
        rig.now += 1
        rig.h.controller.send(.pillStop)
        try await waitUntil { rig.pasted == ["all of it"] && rig.h.controller.machine.activeJobs == 0 }
        #expect(rig.transcribed.first?.recording.samples.count == saved.count + more.samples.count + 16_000)
        #expect(rig.h.history.entry(id: entry.id)?.status == .success)
    }

    /// Transcribe beside Continue: what was recorded, into the row, without recording more or pasting.
    @Test func transcribeTakesWhatWasRecordedWithoutRecordingMore() async throws {
        let rig = Rig()
        let saved = journalSpeech(seconds: 3)
        let entry = try await rig.launch(with: saved)
        rig.h.controller.retry(entry, with: entry.engine)
        try await waitUntil {
            rig.h.history.entry(id: entry.id)?.status == .success && rig.h.controller.runningVersions.isEmpty
        }
        #expect(rig.h.recorder.starts == 0)
        #expect(rig.pasted.isEmpty, "Home's work lands in its row")
        #expect(rig.transcribed.count == 1 && rig.transcribed.first?.recording.samples.count == saved.count)
        let row = try #require(rig.h.history.entry(id: entry.id))
        #expect(row.text == "all of it" && row.interruption == nil)
    }

    /// Quit while it was transcribed: nothing was cut off, so Continue transcribes it, as Retry does.
    @Test func continueAfterTheRecordingEndedTranscribesIt() async throws {
        let rig = Rig()
        let saved = journalSpeech(seconds: 2)
        let entry = try await rig.launch(with: saved, cutOff: false, engine: .parakeet)
        #expect(entry.interruption == .whileTranscribing)
        #expect(entry.errorMessage == HistoryStore.interruptedMessage)

        rig.h.controller.continueDictation(entry)
        try await waitUntil {
            rig.h.history.entry(id: entry.id)?.status == .success && rig.h.controller.runningVersions.isEmpty
        }
        #expect(rig.h.recorder.starts == 0, "no recording")
        #expect(rig.pasted.isEmpty)
        #expect(rig.transcribed.count == 1 && rig.transcribed.first?.engine == .parakeet)
        #expect(rig.transcribed.first?.recording.samples.count == saved.count)
        #expect(rig.h.history.entry(id: entry.id)?.text == "all of it")
    }

    /// Another dictation being recorded: Continue leaves it alone and records nothing (Home's button says why).
    /// Two quick clicks record on once.
    @Test func continueWaitsForADictationBeingRecordedAndRunsOnce() async throws {
        let rig = Rig()
        let entry = try await rig.launch(with: journalSpeech(seconds: 2))
        rig.h.recorder.next = speech(seconds: 1)
        rig.h.controller.send(.handsFreeToggle)
        #expect(rig.h.recorder.starts == 1)
        rig.h.controller.continueDictation(entry)
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.h.recorder.starts == 1 && rig.h.recorder.lastPrefix == nil, "the running dictation is left alone")
        #expect(!rig.h.controller.isInFlight(entry.id))
        rig.h.controller.send(.pillCancel)
        rig.h.toasts.dismissAll()

        rig.h.controller.continueDictation(entry)
        rig.h.controller.continueDictation(entry)
        try await waitUntil { rig.h.recorder.starts == 2 }
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.h.recorder.starts == 2, "one recording, however many clicks")
        #expect(rig.h.recorder.lastPrefix?.id == entry.id)
        rig.h.controller.send(.pillCancel)
    }

    /// The saved recording gone: nothing to record on after, and the row says it's no longer kept.
    @Test func aRecordingNoLongerKeptIsSaidInTheRow() async throws {
        let rig = Rig()
        let entry = try await rig.launch(with: journalSpeech(seconds: 2))
        try await waitUntil { rig.savedSamples(of: entry.id) != nil }
        for file in (try? FileManager.default.contentsOfDirectory(at: rig.paths.recordings,
                                                                    includingPropertiesForKeys: nil)) ?? [] {
            try FileManager.default.removeItem(at: file)
        }
        rig.h.controller.continueDictation(try #require(rig.h.history.entry(id: entry.id)))
        try await waitUntil { rig.h.controller.homeFailures[entry.id]?.isRecordingGone == true }
        #expect(rig.h.recorder.starts == 0)
        #expect(!rig.h.controller.isInFlight(entry.id))
    }

    /// The mic won't start: its error shows, and the row stays as it was, to continue later.
    @Test func whenTheMicCantStartTheRowStaysAsItWas() async throws {
        let rig = Rig()
        let entry = try await rig.launch(with: journalSpeech(seconds: 2))
        rig.h.recorder.startError = .noMicrophone
        rig.h.controller.continueDictation(entry)
        try await waitUntil { rig.notice("error.noMicrophone") != nil }
        #expect(!rig.h.controller.machine.isRecording && !rig.h.controller.isInFlight(entry.id))
        #expect(rig.h.history.entry(id: entry.id)?.interruption == .whileRecording)
    }
}

// MARK: - Home's buttons

#if DEBUG
@MainActor @Suite(.serialized) struct ContinueButtonTests {
    private func row(_ interruption: TranscriptEntry.Interruption, engine: EngineID) -> TranscriptEntry {
        var entry = TranscriptEntry(text: "", engine: engine, status: .failed, audioDuration: 12, voicedSeconds: 9,
                                    errorMessage: interruption.message, audioFileName: "a.m4a")
        entry.interruption = interruption
        return entry
    }

    /// Continue says why it can't run: another dictation being recorded (only where it would record on), or the
    /// row's model not ready.
    @Test func continueSaysWhyItCantRun() {
        let context = HubContext(env: .preview())
        context.models = .preview(states: [.parakeet: .ready])
        context.account = .preview(status: .missing)
        let cutOff = row(.whileRecording, engine: .parakeet)
        let ended = row(.whileTranscribing, engine: .parakeet)
        #expect(context.continueBlocker(for: cutOff) == nil)
        context.previewDictating = true
        #expect(context.continueBlocker(for: cutOff) == "Finish the dictation you’re recording first")
        #expect(context.continueBlocker(for: ended) == nil, "transcribing it records nothing")
        context.previewDictating = false
        #expect(context.continueBlocker(for: row(.whileRecording, engine: .geminiFlash)) == "Needs key")
    }

    @Test func aRowBeingRecordedOnSaysSo() {
        let context = HubContext(env: .preview())
        let id = UUID()
        #expect(!context.isRecordingOn(id))
        context.previewRecordingOn = id
        #expect(context.isRecordingOn(id))
    }
}
#endif

// MARK: - Kept in History

@Suite struct InterruptedEntryCodingTests {
    private func entries(_ json: String) throws -> [TranscriptEntry] {
        try HistoryStore.readEntries(from: Data("{\"version\":1,\"entries\":[\(json)]}".utf8))
    }

    private func entry(_ id: UUID, status: String = "failed", errorMessage: String?, interrupted: String?) -> String {
        let message = errorMessage.map { ",\"errorMessage\":\"\($0)\"" } ?? ""
        let mark = interrupted.map { ",\"interrupted\":\"\($0)\"" } ?? ""
        return """
            {"id":"\(id.uuidString)","createdAt":"2026-10-17T10:00:00.000Z","status":"\(status)","audioDuration":12,\
            "voicedSeconds":9,"text":"","engine":"parakeet","mode":"handsFree"\(message)\(mark)}
            """
    }

    @Test func howItWasInterruptedIsKept() throws {
        let paths = AppPaths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let cutOff = UUID(), ended = UUID()
        let json = [entry(cutOff, errorMessage: "The app quit while you were recording", interrupted: "recording"),
                    entry(ended, errorMessage: "The app quit before it was transcribed", interrupted: "transcribing")]
        let read = try entries(json.joined(separator: ","))
        #expect(read.map(\.interruption) == [.whileRecording, .whileTranscribing])

        var entry = TranscriptEntry(text: "", engine: .geminiFlash, status: .failed, audioDuration: 3, voicedSeconds: 2,
                                    errorMessage: TranscriptEntry.Interruption.whileRecording.message)
        entry.interruption = .whileRecording
        let encoded = try JSONEncoder().encode(entry)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"interrupted\":\"recording\""))
        #expect(try JSONDecoder().decode(TranscriptEntry.self, from: encoded) == entry)
    }

    /// Entries from before: none is interrupted but one an older build brought back from its journal, which reads as
    /// cut off (as its journal would). One a newer build marks some other way reads as a plain failure, not lost.
    @Test func olderAndNewerEntriesStillRead() throws {
        let failed = UUID(), recovered = UUID(), newer = UUID(), success = UUID()
        let read = try entries([
            entry(failed, errorMessage: "Gemini Flash took too long", interrupted: nil),
            entry(recovered, errorMessage: "The app quit before it was transcribed", interrupted: nil),
            entry(newer, errorMessage: "The app quit somehow", interrupted: "sleeping"),
            entry(success, status: "success", errorMessage: nil, interrupted: nil),
        ].joined(separator: ","))
        #expect(read.map(\.id) == [failed, recovered, newer, success])
        #expect(read.map(\.interruption) == [nil, .whileRecording, nil, nil])
        #expect(read[1].errorMessage == "The app quit before it was transcribed", "it keeps saying what it said")
    }
}
