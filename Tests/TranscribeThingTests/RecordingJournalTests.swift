import AVFoundation
import Foundation
import os
import Testing
@testable import TranscribeThing

// A dictation is on disk from its first second (`RecordingJournal`) until History has it, so a crash, a kill or a
// power cut doesn't lose it: the next launch brings it back as a failed entry to transcribe again.

private let rate = Recording.sampleRate

/// `seconds` of something SpeechAnalyzer hears as speech: a voice with harmonics in syllables, over faint noise.
private func speechLike(seconds: Double) -> [Float] {
    var seed: UInt32 = 12_345
    return (0..<Int(seconds * rate)).map { i in
        let t = Double(i) / rate
        let inPause = t.truncatingRemainder(dividingBy: 1) >= 0.75
        let syllable = inPause ? 0 : pow(sin(.pi * (t * 4).truncatingRemainder(dividingBy: 1)), 2)
        var voice = 0.0
        for harmonic in 1...12 { voice += sin(2 * .pi * 140 * Double(harmonic) * t) / Double(harmonic) }
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let noise = Double(seed >> 8) / Double(1 << 24) - 0.5
        return Float(0.08 * syllable * voice + 0.002 * noise)
    }
}

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
}

private func files(in folder: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
}

/// The largest gap between two runs of samples (16-bit quantization allows 1/32,767).
private func maxError(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
}

/// What a capture has recorded so far, handed over as `CaptureSession.samples(from:keepingBack:)` does.
private final class FakeCapture: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [Float]())
    func record(_ samples: [Float]) { state.withLock { $0 += samples } }
    func samples(from index: Int) -> [Float] {
        state.withLock { all in index < all.count ? Array(all[index...]) : [] }
    }
}

private func info(_ id: UUID = UUID(), startedAt: Date = Date(timeIntervalSince1970: 1_790_000_000.5),
                  engine: EngineID? = .geminiFlash, mode: DictationMachine.Mode? = .handsFree) -> RecordingJournal.Info {
    RecordingJournal.Info(id: id, startedAt: startedAt, engine: engine?.rawValue, mode: mode?.rawValue,
                          deviceName: "MacBook Pro Microphone", continues: false)
}

/// A journal as an earlier run would have left it: `samples` written and closed, nothing removing it.
private func leaveJournal(in directory: URL, _ info: RecordingJournal.Info, samples: [Float]) async {
    let journal = RecordingJournal(directory: directory)
    journal.begin(info) { _ in [] }
    journal.end(info.id, samples: samples)
    await journal.settle()
}

@Suite struct RecordingJournalTests {
    @Test func whatIsWrittenInChunksReadsBack() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = RecordingJournal(directory: folder)
        let capture = FakeCapture()
        let prefix = speechLike(seconds: 0.5)
        let audio = speechLike(seconds: 3).map { -$0 }
        let id = UUID()
        journal.begin(info(id), prefix: prefix) { capture.samples(from: $0) }
        for second in 0..<3 {
            capture.record(Array(audio[(second * 16_000)..<((second + 1) * 16_000 - 1_000)]))
            journal.pump(id)
            await journal.settle()
            capture.record(Array(audio[((second + 1) * 16_000 - 1_000)..<((second + 1) * 16_000)]))
        }
        #expect(RecordingJournal.sampleCount(of: journal.audioURL(for: id)) == prefix.count + 3 * 16_000 - 1_000,
                "the prefix and what the capture had at each pump, on disk while recording")
        journal.end(id, samples: audio)
        await journal.settle()

        let read = try #require(RecordingJournal.read(journal.audioURL(for: id)))
        #expect(read.count == prefix.count + audio.count)
        #expect(maxError(read, prefix + audio) <= 1.0 / 32_767)
        let leftovers = await RecordingJournal(directory: folder).leftovers()
        #expect(leftovers.map(\.id) == [id])
        #expect(leftovers.first?.info == info(id), "whose dictation it is, read back")
    }

    /// A kill or a power cut leaves the file wherever the last write ended, even mid-sample: what's there reads back.
    @Test func aCutOffJournalReadsBackWhatWasWritten() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = speechLike(seconds: 2)
        let id = UUID()
        await leaveJournal(in: folder, info(id), samples: audio)
        let url = RecordingJournal(directory: folder).audioURL(for: id)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(RecordingJournal.headerSize + 2 * 12_345 + 1))
        try handle.close()

        let read = try #require(RecordingJournal.read(url))
        #expect(read.count == 12_345)
        #expect(maxError(read, Array(audio.prefix(12_345))) <= 1.0 / 32_767)
        #expect(RecordingJournal.sampleCount(of: url) == 12_345)

        try Data(repeating: 0, count: 20).write(to: url)
        #expect(RecordingJournal.read(url) == nil, "not even a header: nothing to bring back")
    }

    /// History removes a journal once it has the recording, but not one still being written (the same dictation
    /// recorded on after an Undo) or one longer than what it saved.
    @Test func aJournalGoesOnlyOnceItsAudioIsSaved() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = RecordingJournal(directory: folder)
        let capture = FakeCapture()
        let id = UUID()
        journal.begin(info(id)) { capture.samples(from: $0) }
        capture.record(speechLike(seconds: 1))
        journal.pump(id)
        journal.remove(id)
        await journal.settle()
        #expect(files(in: folder).count == 2, "still recording")

        journal.end(id, samples: speechLike(seconds: 2))
        journal.remove(id, ifAtMost: 16_000)
        await journal.settle()
        #expect(files(in: folder).count == 2, "History saved only the first second")

        journal.remove(id, ifAtMost: 32_000)
        await journal.settle()
        #expect(files(in: folder).isEmpty)

        journal.begin(info(id)) { _ in [] }
        journal.discard(id)
        await journal.settle()
        #expect(files(in: folder).isEmpty, "a capture thrown away takes its journal along at once")
    }

    /// The journals this run writes are never a leftover; another run's are, and a sidecar without audio is removed.
    @Test func onlyAnEarlierRunsJournalsAreLeftovers() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = RecordingJournal(directory: folder)
        let mine = UUID()
        journal.begin(info(mine)) { _ in [] }
        journal.end(mine, samples: [0.1, 0.2])
        let earlier = UUID()
        await leaveJournal(in: folder, info(earlier), samples: [0.3])
        let stray = UUID()
        try Data("{}".utf8).write(to: folder.appendingPathComponent("\(stray.uuidString).json"))

        #expect(await journal.leftovers().map(\.id) == [earlier])
        #expect(!files(in: folder).contains("\(stray.uuidString).json"))
    }

    /// The capture hands its audio over for the journal, but for the last half second, where a cue's duck may land.
    @Test func theCaptureKeepsItsLastHalfSecondBack() {
        let device = AudioInputDevice(id: "synthetic", name: "Synthetic Mic", transport: .usb, isAvailable: true)
        let session = CaptureSession(device: CoreAudioHAL.InputRecord(device: device, audioID: 0),
                                     options: CaptureSession.Options(preferredUID: nil), meter: nil, onEvent: { _ in })
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        for i in 0..<16_000 { buffer.floatChannelData![0][i] = 0.1 * sin(Float(i) * 0.05) }
        let t0 = AudioClock.now() - 1
        session.receive(buffer, chunkStart: t0, arrival: t0 + 1)
        let captured = Int(session.capturedDuration * rate)
        #expect(captured > 15_000)
        #expect(session.samples(from: 0, keepingBack: RecordingJournal.holdBackSamples).count == captured - 8_000)
        #expect(session.samples(from: captured - 8_000, keepingBack: RecordingJournal.holdBackSamples).isEmpty)
        let all = session.finishNow(discard: false)
        #expect(all.count >= captured)
        #expect(session.samples(from: 0, keepingBack: 0).isEmpty, "nothing once the capture is over")
    }
}

// MARK: - Brought back at launch

@MainActor
@Suite(.serialized) struct JournalRecoveryTests {
    private func loaded(_ paths: AppPaths, settings: AppSettings? = nil) async throws -> HistoryStore {
        let store = HistoryStore(paths: paths, settings: settings ?? .inMemory())
        store.load()
        try await waitUntil { store.isLoaded }
        await store.waitForRecovery()
        return store
    }

    @Test func aDictationTheAppNeverFinishedComesBackFailedWithItsRecording() async throws {
        let paths = AppPaths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let audio = speechLike(seconds: 3)
        let started = Date(timeIntervalSince1970: 1_790_000_000.5)
        let id = UUID()
        await leaveJournal(in: paths.journals, info(id, startedAt: started), samples: audio)

        let store = try await loaded(paths)
        let entry = try #require(store.entry(id: id))
        #expect(entry.status == .failed)
        #expect(entry.errorMessage == HistoryStore.interruptedMessage)
        #expect(abs(entry.createdAt.timeIntervalSince(started)) < 0.001)
        #expect(entry.engine == .geminiFlash && entry.mode == .handsFree, "Retry uses the model and mode it had")
        #expect(abs(entry.audioDuration - 3) < 0.001)
        #expect(entry.voicedSeconds > 1)
        #expect(entry.audioFileName == "\(id.uuidString).m4a")
        let recording = try #require(store.loadRecording(for: entry))
        #expect(abs(recording.samples.count - audio.count) <= Int(RecordingFile.lengthTolerance * rate))
        try await waitUntil { files(in: paths.journals).isEmpty }

        // Only once: the next launch finds nothing more to bring back.
        store.flush()
        let again = try await loaded(paths)
        #expect(again.entries.map(\.id) == [id])
    }

    /// A journal History already has (the app quit between saving and removing it) just goes. So do journals too
    /// short or too quiet to transcribe, unreadable ones, and ones older than Auto-delete keeps.
    @Test func whatHistoryHasOrWouldNotKeepJustGoes() async throws {
        let paths = AppPaths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let settings = AppSettings.inMemory()
        settings.autoDeleteHistoryDays = 7
        let first = try await loaded(paths, settings: settings)
        let saved = Recording(samples: speechLike(seconds: 2), speech: SpeechStats(voicedSeconds: 1.5, peakDBFS: -12,
                                                                                    isSilent: false))
        let file = first.saveAudio(saved)
        first.upsert(TranscriptEntry(id: saved.id, createdAt: Date(), text: "kept", engine: .parakeet,
                                     audioDuration: saved.duration, voicedSeconds: 1.5, audioFileName: file))
        first.flush()
        _ = first.loadRecording(for: try #require(first.entry(id: saved.id)))
        await first.journal?.settle()

        await leaveJournal(in: paths.journals, info(saved.id, startedAt: Date()), samples: saved.samples)
        await leaveJournal(in: paths.journals, info(startedAt: Date()), samples: speechLike(seconds: 0.2))
        await leaveJournal(in: paths.journals, info(startedAt: Date()), samples: Array(repeating: 0, count: 32_000))
        await leaveJournal(in: paths.journals, info(startedAt: Date().addingTimeInterval(-8 * 86_400)),
                           samples: speechLike(seconds: 2))
        try Data("RIFF".utf8).write(to: paths.journals.appendingPathComponent("\(UUID().uuidString).wav"))
        #expect(files(in: paths.journals).count == 9)

        let store = try await loaded(paths, settings: settings)
        #expect(store.entries.map(\.id) == [saved.id])
        #expect(store.entry(id: saved.id)?.status == .success && store.entry(id: saved.id)?.text == "kept")
        try await waitUntil { files(in: paths.journals).isEmpty }
    }

    /// A transcript whose recording never made it to disk gets it back from its journal, and keeps its text.
    @Test func aTranscriptMissingItsRecordingGetsItBack() async throws {
        let paths = AppPaths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let first = try await loaded(paths)
        let id = UUID()
        first.upsert(TranscriptEntry(id: id, createdAt: Date(), text: "hello", engine: .parakeet, audioDuration: 2,
                                     voicedSeconds: 1.5, audioFileName: "\(id.uuidString).m4a"))
        first.flush()
        await leaveJournal(in: paths.journals, info(id, startedAt: Date()), samples: speechLike(seconds: 2))

        let store = try await loaded(paths)
        let entry = try #require(store.entry(id: id))
        #expect(entry.status == .success && entry.text == "hello")
        #expect(store.loadRecording(for: entry) != nil)
        try await waitUntil { files(in: paths.journals).isEmpty }
    }
}

// MARK: - Every way a dictation ends leaves no journal behind

@MainActor
@Suite(.serialized) struct DictationJournalTests {
    typealias Harness = DictationControllerTests.Harness

    @MainActor final class Rig {
        let h: Harness
        let journals: URL
        let root: URL
        var now: TimeInterval = 100
        var pasted: [String] = []
        var result: @MainActor (Recording) async throws -> String = { _ in "dictated" }

        init() {
            h = DictationControllerTests.make(persistsHistory: true)
            journals = h.paths!.journals
            root = h.paths!.root
            h.recorder.journal = h.history.journal
            h.controller.clock = { [weak self] in self?.now ?? 0 }
            h.controller.transcribeOverride = { [weak self] recording, engine in
                guard let self else { throw CancellationError() }
                return TranscriptResult(text: try await result(recording), engine: engine, processingTime: 0.1)
            }
            h.controller.insertOverride = { [weak self] text in
                self?.pasted.append(text)
                return .pasted
            }
            h.toasts.onAction = { [weak self] notice, action in self?.h.controller.perform(action, from: notice) }
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        var journalFiles: Set<String> { files(in: journals) }

        /// Push-to-talk held for `seconds` of `samples`, then let go (or Esc).
        func hold(_ samples: [Float], voiced: Double = 1, esc: Bool = false) {
            h.recorder.next = Recording(samples: samples,
                                        speech: SpeechStats(voicedSeconds: voiced, peakDBFS: -12, isSilent: voiced == 0))
            h.controller.handle(.pttDown)
            h.controller.send(.timer(.arming))
            now += Double(samples.count) / rate
            h.controller.handle(esc ? .cancel : .pttUp)
        }

        func settled() async throws {
            try await waitUntil { self.h.controller.machine.activeJobs == 0 }
            await h.history.journal?.settle()
        }
    }

    @Test func aTranscribedDictationsJournalGoesOnceHistoryHasIt() async throws {
        let rig = Rig()
        var release: CheckedContinuation<Void, Never>?
        rig.result = { _ in
            await withCheckedContinuation { release = $0 }
            return "dictated"
        }
        rig.hold(speechLike(seconds: 2))
        try await waitUntil { release != nil }
        await rig.h.history.journal?.settle()
        #expect(rig.journalFiles.count == 2, "on disk while the model works: a crash now doesn't lose it")
        release?.resume()
        try await waitUntil { rig.pasted == ["dictated"] }
        try await rig.settled()
        try await waitUntil { rig.journalFiles.isEmpty }
        #expect(rig.h.history.entries.first?.status == .success)
    }

    @Test func aFailedDictationsJournalGoesOnceHistoryHasIt() async throws {
        let rig = Rig()
        rig.result = { _ in throw AppError.engineFailed(.parakeet, "Couldn’t transcribe") }
        rig.hold(speechLike(seconds: 2))
        try await waitUntil { rig.h.history.entries.first?.status == .failed }
        try await rig.settled()
        try await waitUntil { rig.journalFiles.isEmpty }
    }

    /// Canceled: kept for Undo in memory (short) or in History too (20 s and longer), and on through an Undo.
    @Test func aCanceledDictationLeavesNoJournal() async throws {
        let rig = Rig()
        rig.hold(speechLike(seconds: 2), esc: true)
        try await rig.settled()
        #expect(rig.h.controller.retainedRecordingIDs.count == 1, "kept for Undo")
        #expect(rig.journalFiles.isEmpty, "not History's: nothing to bring back after a crash")

        rig.hold(speechLike(seconds: 25), esc: true)
        try await waitUntil { rig.h.history.entries.first?.status == .cancelled }
        try await rig.settled()
        try await waitUntil { rig.journalFiles.isEmpty }

        // Undo records on: the same dictation, on disk again from its kept audio, until it's transcribed.
        let canceled = try #require(rig.h.history.entries.first)
        rig.h.recorder.next = Recording(samples: speechLike(seconds: 2),
                                        speech: SpeechStats(voicedSeconds: 1.5, peakDBFS: -12, isSilent: false))
        let notice = try #require(rig.h.toasts.notices.first { $0.dedupeKey == "dictation.canceled" })
        rig.h.toasts.perform(try #require(notice.actions.first { $0.kind == .undoCancel }), on: notice)
        #expect(rig.h.recorder.lastPrefix?.id == canceled.id)
        await rig.h.history.journal?.settle()
        #expect(rig.journalFiles == ["\(canceled.id.uuidString).wav", "\(canceled.id.uuidString).json"])
        rig.now += 2
        rig.h.controller.send(.pillStop)
        try await waitUntil { rig.pasted == ["dictated"] }
        try await rig.settled()
        try await waitUntil { rig.journalFiles.isEmpty }
        #expect(rig.h.history.entry(id: canceled.id)?.status == .success)
    }

    /// A quick tap, a press too short to keep, and a recording without speech are thrown away with their journals.
    @Test func whatIsThrownAwayTakesItsJournalAlong() async throws {
        let rig = Rig()
        rig.h.recorder.next = Recording(samples: speechLike(seconds: 2),
                                        speech: SpeechStats(voicedSeconds: 1.5, peakDBFS: -12, isSilent: false))
        rig.h.controller.handle(.pttDown)
        rig.now += 0.06
        rig.h.controller.handle(.pttUp)
        try await rig.settled()
        #expect(rig.h.recorder.starts == 1)
        #expect(rig.journalFiles.isEmpty, "a quick tap")

        rig.hold(speechLike(seconds: 0.2), esc: true)
        try await rig.settled()
        #expect(rig.journalFiles.isEmpty, "a cancel shorter than Undo keeps")

        rig.hold(Array(repeating: 0.001, count: 32_000), voiced: 0.1)
        try await rig.settled()
        #expect(rig.journalFiles.isEmpty, "no speech: never sent to a model")
        #expect(rig.h.history.entries.isEmpty)
    }
}
