import CoreAudio
import Foundation
import os
import Testing
@testable import TranscribeThing

// Recording calls: the two tracks on one clock and on disk while recorded (`TrackAligner`, `CallJournal`), the Calls
// store and what it brings back after a crash (`CallStore`), the transcription's prompts, answers and chunks
// (`CallTranscriber`), and noticing calls in any app or browser tab (save `CallDenylist` and `CallExclusion`s),
// asking, keeping, discarding and excluding (`CallMonitor`). No real mic, tap or request: the sources, the HAL, the
// windows and Gemini are fakes.

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

/// A track source that hands over what a test pushes.
final class FakeSource: CallTrackSource, Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (pending: [TimedAudio](), started: false, stopped: false,
                                                             retargets: [[AudioObjectID]]()))
    let fixedProblem: String?

    init(problem: String? = nil) {
        fixedProblem = problem
    }

    func push(_ samples: [Float], at start: TimeInterval?) {
        state.withLock { $0.pending.append(TimedAudio(samples: samples, start: start)) }
    }

    func start() { state.withLock { $0.started = true } }
    func stop() { state.withLock { $0.stopped = true } }
    func drain() -> [TimedAudio] {
        state.withLock { state in
            defer { state.pending = [] }
            return state.pending
        }
    }
    var problem: String? { fixedProblem }
    func retarget(_ processes: [AudioObjectID]) { state.withLock { $0.retargets.append(processes) } }

    var started: Bool { state.withLock { $0.started } }
    var stopped: Bool { state.withLock { $0.stopped } }
    var retargets: [[AudioObjectID]] { state.withLock { $0.retargets } }
}

private func files(in folder: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
}

private func journalInfo(_ id: UUID = UUID(), consent: CallJournal.Consent = .kept) -> CallJournal.Info {
    CallJournal.Info(id: id, startedAt: Date(timeIntervalSince1970: 1_790_000_000), appName: "Telegram",
                     bundleID: "ru.keepcoder.Telegram", service: .telegram, consent: consent)
}

// MARK: - Tracks on disk

@Suite struct CallJournalTests {
    @Test func alignerPadsLateStretchesAndTrimsEarlyOnes() {
        var aligner = TrackAligner(origin: 100)
        // Starts 0.5 s into the call: half a second of silence first.
        #expect(aligner.place(TimedAudio(samples: [Float](repeating: 1, count: 1600), start: 100.5)).count == 8000 + 1600)
        #expect(aligner.written == 9600)
        // Straight on, unstamped.
        #expect(aligner.place(TimedAudio(samples: [1, 1], start: nil)) == [1, 1])
        // Within the tolerance of where the track is: just follows on.
        #expect(aligner.place(TimedAudio(samples: [2, 2], start: 100.6 + 0.02)).count == 2)
        // 0.1 s (1,600 samples) earlier than the track has reached (9,604): that much is already there, and goes.
        let early = aligner.place(TimedAudio(samples: [Float](repeating: 3, count: 3200), start: 100 + 8004 / rate))
        #expect(early.count == 3200 - 1600)
        // Before the call began: dropped whole.
        var fresh = TrackAligner(origin: 10)
        #expect(fresh.place(TimedAudio(samples: [Float](repeating: 1, count: 800), start: 9)) == [])
        #expect(fresh.written == 0)
    }

    @Test func twoTracksShareTheCallsClock() async throws {
        let directory = AppPaths.temporary().callJournals
        let journal = CallJournal(directory: directory)
        let mic = FakeSource(), remote = FakeSource(problem: "no permission")
        let info = journalInfo()
        journal.begin(info, origin: 100, sources: [.mic: mic, .remote: remote])
        #expect(mic.started && remote.started)
        let voice = speechLike(seconds: 1)
        mic.push(voice, at: 100)
        mic.push(voice, at: nil)
        // The other side's first sound one second in.
        remote.push([Float](repeating: 0.25, count: 8000), at: 101)
        journal.update(info.id) { $0.mutes = [CallInterval(start: 0.5, end: 1.0)] }
        let ended = try #require(await journal.end(info.id))
        #expect(mic.stopped && remote.stopped)
        #expect(ended.mutes == [CallInterval(start: 0.5, end: 1.0)])
        #expect(ended.remoteProblem == "no permission")
        let micSamples = try #require(RecordingJournal.read(journal.audioURL(for: info.id, track: .mic)))
        let remoteSamples = try #require(RecordingJournal.read(journal.audioURL(for: info.id, track: .remote)))
        #expect(micSamples.count == 32_000)
        #expect(remoteSamples.count == 16_000 + 8000)
        #expect(remoteSamples[..<16_000].allSatisfy { $0 == 0 })
        #expect(abs(remoteSamples[16_000] - 0.25) < 0.001)
        // The sidecar says what `end` said: a crash after this brings it back as such.
        let sidecar = try JSONDecoder().decode(CallJournal.Info.self, from: Data(contentsOf: journal.infoURL(for: info.id)))
        #expect(sidecar == ended)
        // Closed, not removed: the store removes it once it has the call.
        #expect(files(in: directory).count == 3)
        journal.remove(info.id)
        await journal.settle()
        #expect(files(in: directory).isEmpty)
    }

    @Test func discardDeletesEverything() async {
        let directory = AppPaths.temporary().callJournals
        let journal = CallJournal(directory: directory)
        let mic = FakeSource()
        let info = journalInfo(consent: .suspected)
        journal.begin(info, origin: 0, sources: [.mic: mic, .remote: FakeSource()])
        mic.push(speechLike(seconds: 0.5), at: 0)
        await journal.settle()
        #expect(!files(in: directory).isEmpty)
        journal.discard(info.id)
        await journal.settle()
        #expect(files(in: directory).isEmpty)
        #expect(mic.stopped)
    }

    @Test func journalFileNames() {
        let id = UUID()
        #expect(CallJournal.parse(fileName: "\(id.uuidString)-mic.wav")! == (id, .mic))
        #expect(CallJournal.parse(fileName: "\(id.uuidString)-remote.wav")! == (id, .remote))
        #expect(CallJournal.parse(fileName: "\(id.uuidString).json") == nil)
        #expect(CallJournal.parse(fileName: "\(id.uuidString)-other.wav") == nil)
    }

    @Test func tracksBecomeM4AsReadableInPieces() throws {
        let folder = AppPaths.temporary().root
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wav = folder.appendingPathComponent("track.wav")
        let samples = speechLike(seconds: 3)
        var data = RecordingJournal.openHeader()
        WAVEncoder.int16(samples).withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: wav)
        let m4a = folder.appendingPathComponent("call/mic.m4a")
        let encoded = try CallAudio.encode(journal: wav, to: m4a)
        #expect(encoded.samples == samples.count)
        #expect(encoded.peak > 0.05)
        let count = try CallAudio.sampleCount(of: m4a)
        #expect(abs(count - samples.count) < 2048)
        let piece = try CallAudio.read(m4a, range: 16_000..<24_000)
        #expect(piece.count == 8000)
        #expect(SpeechAnalyzer.stats(for: try CallAudio.read(m4a, range: 0..<count)).voicedSeconds > 1)
    }
}

// MARK: - Store

@MainActor
@Suite(.serialized) struct CallStoreTests {
    @Test func callsPersistAndReadLeniently() async throws {
        let paths = AppPaths.temporary()
        let store = CallStore(paths: paths, settings: .inMemory())
        store.load()
        var call = CallRecord(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_790_000_000), appName: "Google Chrome",
                              bundleID: "com.google.Chrome", service: .meet, pageTitle: "Meet – abc", status: .done)
        call.muteIntervals = [CallInterval(start: 3, end: 7)]
        call.muteKnown = true
        call.transcript = CallTranscript(segments: [
            .init(start: 1, end: 2, side: .remote, speaker: "Аня", text: "Привет"),
            .init(start: 3, end: 4, side: .local, speaker: "Sam", text: "Hi", duringMute: true),
        ])
        call.costUSD = 0.02
        store.upsert(call)
        store.rename(speaker: "Аня", to: "Anna", in: call.id)
        await store.flush()

        let again = CallStore(paths: paths, settings: .inMemory())
        again.load()
        let read = try #require(again.call(id: call.id))
        #expect(read.transcript == call.transcript)
        #expect(read.name(of: "Аня") == "Anna")
        #expect(read.service == .meet && read.muteIntervals == call.muteIntervals)
        // A call another build wrote with a status and service this one doesn't know, and one that's broken.
        let json = """
            {"version":1,"calls":[{"id":"\(UUID().uuidString)","startedAt":"2026-10-01T10:00:00Z","appName":"X",
            "status":"archived","service":"teams"},{"id":"nope"}]}
            """
        let lenient = try CallStore.readRecords(from: Data(json.utf8))
        #expect(lenient.count == 1)
        #expect(lenient[0].status == .failed && lenient[0].service == nil)
    }

    @Test func autoDeleteFollowsHistoryAndTakesTheAudio() async throws {
        let paths = AppPaths.temporary()
        let settings = AppSettings.inMemory()
        let store = CallStore(paths: paths, settings: settings)
        store.load()
        let old = CallRecord(id: UUID(), startedAt: Date().addingTimeInterval(-10 * 86_400), appName: "Zoom",
                             status: .done)
        let recent = CallRecord(id: UUID(), startedAt: Date().addingTimeInterval(-86_400), appName: "Zoom", status: .done)
        for call in [old, recent] {
            store.upsert(call)
            try FileManager.default.createDirectory(at: store.folder(for: call.id), withIntermediateDirectories: true)
            try Data([1]).write(to: store.folder(for: call.id).appendingPathComponent("mic.m4a"))
        }
        var removed: [UUID] = []
        store.onRemove = { removed += $0 }
        store.deleteExpired()
        #expect(store.calls.count == 2)
        settings.autoDeleteHistoryDays = 7
        store.deleteExpired()
        #expect(store.calls.map(\.id) == [recent.id])
        #expect(removed == [old.id])
        await store.flush()
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: old.id).path))
        #expect(FileManager.default.fileExists(atPath: store.folder(for: recent.id).path))
        store.delete(recent.id)
        await store.flush()
        #expect(store.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: recent.id).path))
    }

    /// What an earlier run left in the journal: a kept call, one asked about, one only suspected.
    @Test func callsLeftInTheJournalComeBack() async throws {
        let paths = AppPaths.temporary()
        // A call the earlier run had as recording whose journal is gone.
        let lost = CallRecord(id: UUID(), startedAt: Date(), appName: "Zoom", status: .recording)
        let earlier = CallStore(paths: paths, settings: .inMemory())
        earlier.load()
        await earlier.waitForRecovery()
        earlier.upsert(lost)
        await earlier.flush()
        let journal = CallJournal(directory: paths.callJournals)
        var ids: [CallJournal.Consent: UUID] = [:]
        for consent in [CallJournal.Consent.kept, .asking, .suspected] {
            let info = journalInfo(consent: consent)
            ids[consent] = info.id
            let mic = FakeSource()
            journal.begin(info, origin: 0, sources: [.mic: mic, .remote: FakeSource()])
            mic.push(speechLike(seconds: 2), at: 0)
            _ = await journal.end(info.id)
        }

        let store = CallStore(paths: paths, settings: .inMemory())
        store.load()
        await store.waitForRecovery()
        let kept = try #require(store.call(id: ids[.kept]!))
        #expect(kept.status == .interrupted)
        #expect(kept.error == CallStore.interruptedMessage)
        #expect(kept.micFile == "mic.m4a" && abs(kept.micSeconds - 2) < 0.01)
        #expect(kept.remoteFile == nil)
        #expect(FileManager.default.fileExists(atPath: try #require(store.audioURL(of: kept, track: .mic)).path))
        #expect(store.call(id: ids[.asking]!)?.status == .unconfirmed)
        #expect(store.call(id: ids[.suspected]!) == nil)
        #expect(store.call(id: lost.id)?.status == .interrupted)
        await store.journal?.settle()
        #expect(files(in: paths.callJournals).isEmpty)
    }
}

// MARK: - Transcription

@Suite struct CallTranscriberTests {
    @Test func answersAreReadForgivingly() throws {
        let fenced = """
            Here you go:
            ```json
            [{"start": "00:01", "end": "00:04", "speaker": "Аня", "text": "Привет, как дела?"},
             {"start": "0:05.5", "speaker": "Participant 2", "text": " Нормально "},
             {"start": 7, "end": "01:30", "speaker": "", "text": "Ок"},
             {"start": "00:08", "text": ""}]
            ```
            """
        let segments = try CallTranscriptParser.segments(from: fenced, side: .remote, duration: 60)
        #expect(segments.count == 3)
        #expect(segments[0] == .init(start: 1, end: 4, side: .remote, speaker: "Аня", text: "Привет, как дела?"))
        // No end: up to the next phrase.
        #expect(segments[1].start == 5.5 && segments[1].end == 7 && segments[1].text == "Нормально")
        // No speaker: the side's default; an end past the audio: clamped.
        #expect(segments[2].speaker == "Participant 1" && segments[2].end == 60)
        #expect(try CallTranscriptParser.segments(from: "[]", side: .local, duration: 10).isEmpty)
        #expect(try CallTranscriptParser.segments(from: "```json\n```", side: .local, duration: 10).isEmpty)
        #expect(throws: CallTranscriber.Failure.unreadableAnswer(track: .mic, chunk: 1, chunks: 1, lines: 1)) {
            try CallTranscriptParser.segments(from: "I can't hear anything.", side: .local, duration: 10)
        }
        #expect(CallTranscriptParser.seconds("1:02:03") == 3723)
        #expect(CallTranscriptParser.seconds("12:3x") == nil)
    }

    @Test func longCallsAreCutIntoEqualChunks() {
        let total = Int(100 * 60 * rate)
        let chunks = CallTranscriber.chunks(totalSamples: total, maxSeconds: 45 * 60)
        #expect(chunks.count == 3)
        #expect(chunks.first?.lowerBound == 0 && chunks.last?.upperBound == total)
        for (a, b) in zip(chunks, chunks.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
        #expect(chunks.allSatisfy { Double($0.count) / rate <= 45 * 60 })
        #expect(CallTranscriber.chunks(totalSamples: 10, maxSeconds: 45 * 60) == [0..<10])
        #expect(CallTranscriber.chunks(totalSamples: 0, maxSeconds: 45 * 60).isEmpty)
    }

    @Test func mergeOrdersBySideAndMarksMutes() {
        let segments: [CallTranscript.Segment] = [
            .init(start: 10, end: 14, side: .local, speaker: "Sam", text: "muted mostly"),
            .init(start: 2, end: 3, side: .local, speaker: "Sam", text: "answer"),
            .init(start: 2, end: 2.5, side: .remote, speaker: "Аня", text: "question"),
            .init(start: 20, end: 21, side: .local, speaker: "Sam", text: "barely muted"),
            .init(start: 30, end: 30, side: .local, speaker: "Sam", text: "point in a mute"),
        ]
        let mutes = [CallInterval(start: 9, end: 13), CallInterval(start: 20.8, end: 25), CallInterval(start: 29, end: 31)]
        let merged = CallTranscriptMerge.merge(segments, mutes: mutes)
        #expect(merged.segments.map(\.text) == ["question", "answer", "muted mostly", "barely muted", "point in a mute"])
        #expect(merged.segments.map(\.duringMute) == [false, false, true, false, true])
        #expect(merged.speakers == ["Аня", "Sam"])
    }

    /// The prompts each request got, and Gemini's made-up answers.
    private final class FakeGemini: Sendable {
        let prompts = OSAllocatedUnfairLock(initialState: [String]())

        func send(_ audio: Data, _ prompt: String, _ seconds: TimeInterval) async throws -> CloudResult {
            let index = prompts.withLock { $0.append(prompt); return $0.count }
            #expect(!audio.isEmpty)
            let isRemote = prompt.contains("the other participants")
            let text = isRemote
                ? #"[{"start":"00:01","end":"00:03","speaker":"Аня","text":"Привет, ты меня слышишь? (\#(index))"}]"#
                : #"[{"start":"00:04","end":"00:06","speaker":"Sam","text":"Да, слышу (\#(index))"},{"start":"00:20","end":"00:24","speaker":"Sam","text":"Это про себя"}]"#
            var result = CloudResult(text: text)
            result.costUSD = 0.01
            return result
        }
    }

    @Test func bothSidesAreAskedWithEchoAndMutesThenMerged() async throws {
        let gemini = FakeGemini()
        let samples = speechLike(seconds: 30)
        let plan = CallTranscriber.Plan(remote: URL(fileURLWithPath: "/remote.m4a"), mic: URL(fileURLWithPath: "/mic.m4a"),
                                        remoteSamples: samples.count, micSamples: samples.count,
                                        mutes: [CallInterval(start: 19, end: 26)], userName: "Sam", service: "Telegram")
        let outcome = try await CallTranscriber.run(plan, send: { try await gemini.send($0, $1, $2) }) { _, range in Array(samples[range]) }
        let prompts = gemini.prompts.withLock { $0 }
        #expect(prompts.count == 2)
        #expect(prompts[0].contains("on Telegram") && prompts[0].contains("Participant 1"))
        // The mic's prompt has the other side's words as echo, the person's name, and the mute.
        #expect(prompts[1].contains("[00:01] Аня: Привет, ты меня слышишь? (1)"))
        #expect(prompts[1].contains("\"Sam\"") && prompts[1].contains("00:19 to 00:26"))
        #expect(outcome.transcript.segments.map(\.side) == [.remote, .local, .local])
        #expect(outcome.transcript.segments.map(\.duringMute) == [false, false, true])
        #expect(abs((outcome.costUSD ?? 0) - 0.02) < 1e-9)
    }

    @Test func silentTracksAreNotSent() async throws {
        let gemini = FakeGemini()
        let speech = speechLike(seconds: 10)
        let plan = CallTranscriber.Plan(remote: URL(fileURLWithPath: "/remote.m4a"), mic: URL(fileURLWithPath: "/mic.m4a"),
                                        remoteSamples: speech.count, micSamples: speech.count, mutes: [], userName: nil,
                                        service: nil)
        let outcome = try await CallTranscriber.run(plan, send: { try await gemini.send($0, $1, $2) }) { url, range in
            url.lastPathComponent == "remote.m4a" ? [Float](repeating: 0, count: range.count) : Array(speech[range])
        }
        let prompts = gemini.prompts.withLock { $0 }
        #expect(prompts.count == 1)
        // Without the person's name, they're "Me"; nothing heard from the other side, so no echo.
        #expect(prompts[0].contains("\"Me\"") && !prompts[0].contains("echo"))
        #expect(outcome.transcript.segments.allSatisfy { $0.side == .local })
    }

    @Test func chunksCarryTheSpeakersAndTheirTimes() async throws {
        let gemini = FakeGemini()
        let samples = speechLike(seconds: 25)
        let plan = CallTranscriber.Plan(remote: URL(fileURLWithPath: "/remote.m4a"), mic: nil,
                                        remoteSamples: samples.count, micSamples: 0, mutes: [], userName: "Sam",
                                        service: "Zoom")
        let outcome = try await CallTranscriber.run(plan, maxChunkSeconds: 10, send: { try await gemini.send($0, $1, $2) }) { _, range in
            Array(samples[range])
        }
        let prompts = gemini.prompts.withLock { $0 }
        #expect(prompts.count == 3)
        #expect(!prompts[0].contains("Earlier in this call"))
        #expect(prompts[1].contains("Earlier in this call these speakers were heard: Аня."))
        // Each chunk's times on the call's clock: 25 s in three chunks of 25/3 s.
        let starts = outcome.transcript.segments.map(\.start)
        let chunk = Double(Int(25 * rate + 2) / 3) / rate
        #expect(starts.count == 3)
        for (index, start) in starts.enumerated() { #expect(abs(start - (1 + Double(index) * chunk)) < 0.01) }
    }

    @MainActor
    @Test func transcribingACallUpdatesItsRecord() async throws {
        let paths = AppPaths.temporary()
        let store = CallStore(paths: paths, settings: .inMemory())
        store.load()
        var call = CallRecord(id: UUID(), startedAt: Date(), appName: "Telegram", service: .telegram, status: .done)
        call.micFile = "mic.m4a"
        call.micSeconds = 10
        store.upsert(call)
        let speech = speechLike(seconds: 10)
        let failing = OSAllocatedUnfairLock(initialState: true)
        let transcriber = CallTranscriber(store: store) { _, _, _ in
            if failing.withLock({ $0 }) { throw AppError.openRouterMissingKey }
            return CloudResult(text: #"[{"start":"00:01","end":"00:02","speaker":"Sam","text":"Hello"}]"#)
        }
        transcriber.read = { _, range in Array(speech[range]) }
        transcriber.transcribe(call.id)
        #expect(store.call(id: call.id)?.status == .transcribing)
        await transcriber.waitUntilIdle()
        #expect(store.call(id: call.id)?.status == .failed)
        #expect(store.call(id: call.id)?.error != nil)
        failing.withLock { $0 = false }
        transcriber.retranscribe(call.id)
        await transcriber.waitUntilIdle()
        let done = try #require(store.call(id: call.id))
        #expect(done.status == .done && done.error == nil)
        #expect(done.transcript?.segments.map(\.text) == ["Hello"])
    }
}

// MARK: - Monitor

@MainActor
@Suite(.serialized) struct CallMonitorTests {
    /// A made-up Mac: which apps use the mic and play sound, what the browser's tabs say, and the track sources each
    /// recording got.
    @MainActor final class Rig {
        var records: [CoreAudioHAL.ProcessRecord] = []
        var tabs: [String] = []
        /// Accessibility allowed.
        var canReadWindows = true
        /// The browser shows its windows to Accessibility.
        var windowsReadable = true
        /// The apps whose windows were read, a read at a time.
        var reads: [String] = []
        var sources: [[CallJournal.Track: FakeSource]] = []
        var asked: [CallMonitor.CallInfo] = []
        var answered: [UUID] = []
        let paths: AppPaths
        let settings = AppSettings.inMemory()
        let store: CallStore
        let transcriber: CallTranscriber
        var monitor: CallMonitor!

        init(mode: CallRecordingMode = .ask, paths: AppPaths = .temporary()) {
            self.paths = paths
            settings.callRecording = mode
            store = CallStore(paths: paths, settings: settings)
            store.load()
            transcriber = CallTranscriber(store: store) { _, prompt, _ in
                CloudResult(text: prompt.contains("the other participants") ? "[]"
                            : #"[{"start":"00:01","end":"00:03","speaker":"Sam","text":"Hello there"}]"#)
            }
            let sensors = CallWatch.Sensors(
                processRecords: { [unowned self] in records },
                app: { CallApp(bundleID: $0.bundleID) },
                pids: { _ in [] },
                canReadWindows: { [unowned self] in canReadWindows },
                readWindow: { [unowned self] app, _, following, done in
                    reads.append(app.id)
                    let windows = windowsReadable
                        ? [BrowserTabs.Window(title: tabs.first, tabs: tabs.map { BrowserTabs.Tab(title: $0, selected: nil) })]
                        : []
                    let isBrowser = CallAppKind.of(app.id) == .browser
                    done(CallMuteReader.Report(
                        read: MuteRead(state: .unknown("test"), inCall: nil, detail: ""), isBrowser: isBrowser,
                        tab: isBrowser ? BrowserTabs.callTab(in: windows, following: following) : nil,
                        windowCount: windows.count, otherTabPlaysAudio: BrowserTabs.otherTabPlaysAudio(
                            in: windows, besides: BrowserTabs.callTab(in: windows, following: following))))
                },
                releaseWindows: {})
            let deps = CallMonitor.Dependencies(
                sensors: sensors, clock: { 0 }, now: { Date(timeIntervalSince1970: 1_790_000_000) },
                makeSources: { [unowned self] _ in
                    let made = [CallJournal.Track.mic: FakeSource(), .remote: FakeSource()]
                    sources.append(made)
                    return made
                },
                appName: { Self.names[$0.id] ?? $0.id })
            monitor = CallMonitor(settings: settings, store: store, transcriber: transcriber, dependencies: deps)
            monitor.onAsk = { [unowned self] in asked.append($0) }
            monitor.onAnswered = { [unowned self] in answered.append($0) }
        }

        static let names = ["com.google.Chrome": "Google Chrome", "com.apple.FaceTime": "FaceTime",
                            "com.microsoft.teams2": "Microsoft Teams", "net.whatsapp.WhatsApp": "WhatsApp"]

        func app(_ bundleID: String, pid: pid_t = 100, object: AudioObjectID = 10, mic: Bool, sound: Bool) {
            records.removeAll { $0.pid == pid }
            records.append(CoreAudioHAL.ProcessRecord(objectID: object, pid: pid, bundleID: bundleID,
                                                      isRunningInput: mic, isRunningOutput: sound,
                                                      inputDevices: [], outputDevices: []))
        }

        func poll(_ times: some Sequence<Double>) {
            for time in times { monitor.poll(at: time) }
        }

        var journalFiles: Set<String> { files(in: paths.callJournals) }
    }

    private static let meet = "Meet – abc-defg-hij - Camera and microphone recording"

    @Test func aMeetTabIsAskedAboutOnceItsACall() async throws {
        let rig = Rig()
        rig.tabs = ["YouTube - Audio playing", Self.meet]
        rig.app("com.google.Chrome", mic: true, sound: true)
        rig.poll([0, 0.5])
        guard case .suspected(let info) = rig.monitor.state else { Issue.record("not suspected"); return }
        #expect(info.service == .meet && info.pageTitle == "Meet – abc-defg-hij")
        #expect(rig.asked.isEmpty)
        rig.poll([21])
        guard case .asking(let asking) = rig.monitor.state else { Issue.record("not asking"); return }
        #expect(rig.asked.map(\.id) == [asking.id])
        #expect(asking.title == "Google Meet")
        // Recording since the suspicion: the journal is there.
        await rig.store.journal?.settle()
        #expect(rig.journalFiles.contains("\(asking.id.uuidString)-mic.wav"))
        // A tap of Chrome's processes; a new helper joins it.
        rig.app("com.google.Chrome", pid: 101, object: 11, mic: false, sound: true)
        rig.poll([21.5])
        #expect(rig.sources.first?[.remote]?.retargets == [[10, 11]])

        // No: the recording goes, and that call isn't recorded again.
        rig.monitor.discard()
        #expect(rig.monitor.state == .idle)
        #expect(rig.answered == [asking.id])
        await rig.store.journal?.settle()
        #expect(rig.journalFiles.isEmpty)
        rig.poll([22, 23, 50])
        #expect(rig.monitor.state == .idle)
        #expect(rig.sources.count == 1)
        #expect(rig.store.calls.isEmpty)
    }

    /// The tap takes all of Chrome's sound: another tab playing meanwhile is noted, so the transcript can be read
    /// with that in mind.
    @Test func anotherTabsSoundIsNoted() async throws {
        let rig = Rig(mode: .automatic)
        rig.tabs = [Self.meet]
        rig.app("com.google.Chrome", mic: true, sound: true)
        rig.poll([0, 0.5, 21])
        guard case .recording(let info) = rig.monitor.state else { Issue.record("not kept"); return }
        // Its window is read every 3 s (no Mute button known here): at 24 and at 30.
        rig.tabs = [Self.meet, "Lo-fi beats - YouTube - Audio playing"]
        rig.poll([24, 25])
        rig.tabs = [Self.meet]
        rig.poll([30, 31])
        rig.monitor.stop(keep: true)
        await rig.monitor.waitForEndings()
        await rig.transcriber.waitUntilIdle()
        let call = try #require(rig.store.call(id: info.id))
        #expect(call.otherBrowserAudio == [CallInterval(start: 24, end: 30)])
        #expect(call.service == .meet && call.pageTitle == "Meet – abc-defg-hij")
        #expect(BrowserTabs.isPlayingAudio("YouTube – воспроизводится аудио"))
        #expect(!BrowserTabs.isPlayingAudio("Meet – abc"))
    }

    /// No list of call apps: Teams, WhatsApp, FaceTime are calls like any other, named by the app, mute unknown, and
    /// their windows aren't read (nobody knows their controls).
    @Test func anyAppWithMicAndSoundIsACall() {
        for bundleID in ["com.microsoft.teams2", "net.whatsapp.WhatsApp", "com.apple.FaceTime"] {
            let rig = Rig()
            rig.app(bundleID, mic: true, sound: true)
            rig.poll([0, 0.5, 21])
            guard case .asking(let info) = rig.monitor.state else { Issue.record("\(bundleID) not asked about"); continue }
            #expect(info.title == Rig.names[bundleID])
            #expect(info.service == nil && !info.muteKnown)
            #expect(rig.asked.map(\.id) == [info.id])
            #expect(rig.reads.isEmpty)
        }
        // A known service's app still reads its window for mute.
        let slack = Rig()
        slack.app("com.tinyspeck.slackmacgap", mic: true, sound: true)
        slack.poll([0])
        #expect(slack.reads == ["com.tinyspeck.slackmacgap"])
        // Telemost's desktop app is a call like any, and still Telemost.
        let telemost = Rig()
        telemost.app("ru.yandex.desktop.telemost", mic: true, sound: true)
        telemost.poll([0, 21])
        #expect(telemost.monitor.current?.title == "Telemost")
    }

    @Test func musicAndRecordingAppsAreNeverCalls() {
        for bundleID in ["com.apple.garageband10", "com.obsproject.obs-studio", "com.ableton.live.11"] {
            let rig = Rig(mode: .automatic)
            rig.app(bundleID, mic: true, sound: true)
            rig.poll([0, 0.5, 21, 22])
            #expect(rig.monitor.state == .idle, "\(bundleID)")
            #expect(rig.sources.isEmpty)
            // It doesn't stand in the way of a call that starts meanwhile.
            rig.app("ru.keepcoder.Telegram", pid: 200, object: 20, mic: true, sound: true)
            rig.poll([23])
            guard case .suspected(let telegram) = rig.monitor.state else { Issue.record("Telegram not noticed"); return }
            #expect(telegram.service == .telegram)
        }
        #expect(CallDenylist.denies(CallApp(bundleID: "com.apple.QuickTimePlayerX")!))
        #expect(CallDenylist.denies(CallApp(bundleID: "com.ableton.live")!))
        #expect(!CallDenylist.denies(CallApp(bundleID: "com.ableton.livestream")!))
        #expect(!CallDenylist.denies(CallApp(bundleID: "com.apple.FaceTime")!))
        // Off: nothing is noticed.
        let off = Rig(mode: .off)
        off.app("ru.keepcoder.Telegram", mic: true, sound: true)
        off.poll([0, 21])
        #expect(off.monitor.state == .idle && off.sources.isEmpty)
    }

    /// Any site whose tab says it records the mic is a call, titled by its page.
    @Test func aBrowserTabUsingTheMicIsACallTitledByItsPage() async throws {
        let rig = Rig()
        rig.tabs = ["(2) Inbox - Gmail", "ChatGPT - Microphone recording"]
        rig.app("com.google.Chrome", mic: true, sound: true)
        rig.poll([0, 0.5, 21])
        guard case .asking(let info) = rig.monitor.state else { Issue.record("not asking"); return }
        #expect(info.title == "ChatGPT" && info.service == nil && info.pageTitle == "ChatGPT")
        #expect(!info.muteKnown)
        #expect(CallExclusion.of(info) == CallExclusion(kind: .site, key: "page: chatgpt", name: "ChatGPT"))
        #expect(CallExclusion.of(info)?.actionTitle == "Never for This Site")
        rig.monitor.keep()
        rig.monitor.stop(keep: true)
        await rig.monitor.waitForEndings()
        await rig.transcriber.waitUntilIdle()
        let call = try #require(rig.store.call(id: info.id))
        #expect(call.title == "ChatGPT" && CallFormat.title(call) == "ChatGPT")
        #expect(CallFormat.place(call) == "In Google Chrome")

        // A browser with mic and sound but no tab that says so (a camera only, nothing at all): dropped once it's
        // had its time to say.
        let none = Rig(mode: .automatic)
        none.tabs = ["Photo Booth Online - Camera recording", "Lo-fi beats - YouTube - Audio playing"]
        none.app("com.google.Chrome", mic: true, sound: true)
        none.poll([0, 0.5, 5])
        #expect(none.monitor.isRecording)
        none.poll([CallMonitor.classifyWithin + 0.5])
        #expect(none.monitor.state == .idle)
        await none.store.journal?.settle()
        #expect(none.journalFiles.isEmpty)
        none.poll([21, 22])
        #expect(none.monitor.state == .idle && none.sources.count == 1)
    }

    /// With no window of the browser to read (no Accessibility, or a browser that shows none), it's any app.
    @Test func aBrowserWhoseTabsCantBeReadIsTakenWhole() {
        let rig = Rig()
        rig.canReadWindows = false
        rig.app("com.google.Chrome", mic: true, sound: true)
        rig.poll([0, 0.5, 21])
        guard case .asking(let info) = rig.monitor.state else { Issue.record("not asking"); return }
        #expect(info.title == "Google Chrome" && info.service == nil)
        #expect(CallExclusion.of(info) == .app(bundleID: "com.google.Chrome", name: "Google Chrome"))

        let hidden = Rig()
        hidden.windowsReadable = false
        hidden.app("com.google.Chrome", mic: true, sound: true)
        hidden.poll([0, 0.5, 5, CallMonitor.classifyWithin + 0.5])
        guard case .suspected = hidden.monitor.state else { Issue.record("dropped"); return }
        hidden.poll([21])
        guard case .asking(let whole) = hidden.monitor.state else { Issue.record("not asking"); return }
        #expect(whole.title == "Google Chrome")
    }

    @Test func excludedAppsAndSitesAreNeverFollowed() async {
        let app = Rig(mode: .automatic)
        app.settings.excludeFromCalls(.app(bundleID: "com.apple.FaceTime", name: "FaceTime"))
        app.app("com.apple.FaceTime", mic: true, sound: true)
        app.poll([0, 0.5, 21, 22])
        #expect(app.monitor.state == .idle && app.sources.isEmpty)
        // Not followed, so a call elsewhere is noticed at once.
        app.app("com.hnc.Discord", pid: 200, object: 20, mic: true, sound: true)
        app.poll([23])
        #expect(app.monitor.current?.service == .discord)

        // Google Meet's site: every meeting, in any browser.
        let meet = Rig(mode: .automatic)
        meet.settings.excludeFromCalls(CallExclusion.site(service: .meet, page: "Meet – other-meet-ing")!)
        meet.tabs = [Self.meet]
        meet.app("com.apple.Safari", mic: true, sound: true)
        meet.poll([0, 0.5])
        #expect(meet.monitor.state == .idle)
        meet.poll([21, 22, 40])
        #expect(meet.monitor.state == .idle && meet.sources.count == 1)
        await meet.store.journal?.settle()
        #expect(meet.journalFiles.isEmpty)

        // An unknown site, by the start of its title.
        let site = Rig(mode: .automatic)
        site.settings.excludeFromCalls(CallExclusion.site(service: nil, page: "ChatGPT | voice")!)
        site.tabs = ["ChatGPT - Microphone recording"]
        site.app("com.google.Chrome", mic: true, sound: true)
        site.poll([0, 0.5, 21])
        #expect(site.monitor.state == .idle && site.store.calls.isEmpty)
        // Another site in the same browser still is a call.
        let other = Rig(mode: .automatic)
        other.settings.excludeFromCalls(CallExclusion.site(service: nil, page: "ChatGPT")!)
        other.tabs = ["Voice Recorder Online - Microphone recording"]
        other.app("com.google.Chrome", mic: true, sound: true)
        other.poll([0, 0.5, 21])
        guard case .recording(let info) = other.monitor.state else { Issue.record("not recorded"); return }
        #expect(info.title == "Voice Recorder Online")
    }

    /// Never for …: the call goes as with Don't Keep, and the app (or site) is on the list from then on.
    @Test func neverForFromTheQuestionDiscardsAndExcludes() async {
        let rig = Rig()
        rig.app("com.apple.FaceTime", mic: true, sound: true)
        rig.poll([0, 21])
        guard case .asking(let info) = rig.monitor.state else { Issue.record("not asking"); return }
        let notice = Notice.transcribeCall(info.id, service: info.title, never: CallExclusion.of(info)?.actionTitle)
        #expect(notice.link?.title == "Never for FaceTime")
        #expect(notice.link?.kind == .neverForCall(info.id))
        rig.monitor.answer(.never, callID: info.id)
        #expect(rig.monitor.state == .idle)
        #expect(rig.answered == [info.id])
        #expect(rig.settings.callExclusions == [.app(bundleID: "com.apple.FaceTime", name: "FaceTime")])
        await rig.store.journal?.settle()
        #expect(rig.journalFiles.isEmpty)
        #expect(rig.store.calls.isEmpty)
        // The call goes on and ends, another starts: neither is recorded.
        rig.app("com.apple.FaceTime", mic: false, sound: false)
        rig.poll(stride(from: 22.0, through: 90, by: 1))
        rig.app("com.apple.FaceTime", mic: true, sound: true)
        rig.poll([91, 92, 120])
        #expect(rig.monitor.state == .idle && rig.sources.count == 1)

        // On a call that ended unanswered: deleted, and its site excluded.
        let ended = Rig()
        ended.tabs = [Self.meet]
        ended.app("com.google.Chrome", mic: true, sound: true)
        ended.poll([0, 0.5, 21])
        guard case .asking(let meet) = ended.monitor.state else { Issue.record("not asking"); return }
        ended.app("com.google.Chrome", mic: false, sound: false)
        ended.poll(stride(from: 22.0, through: 90, by: 1))
        await ended.monitor.waitForEndings()
        #expect(ended.store.call(id: meet.id)?.status == .unconfirmed)
        ended.monitor.answer(.never, callID: meet.id)
        #expect(ended.store.call(id: meet.id) == nil)
        #expect(ended.settings.callExclusions.map(\.name) == ["Google Meet"])
        #expect(ended.settings.callExclusions.first?.actionTitle == "Never for Google Meet")
        // Twice is still once.
        ended.settings.excludeFromCalls(CallExclusion.site(service: .meet, page: "Meet – x")!)
        #expect(ended.settings.callExclusions.count == 1)
    }

    @Test func aSuspicionThatDropsIsDeleted() async {
        let rig = Rig()
        rig.app("ru.keepcoder.Telegram", mic: true, sound: true)
        rig.poll([0])
        #expect(rig.monitor.isRecording)
        // A voice note played back while recording another: not 20 s of both.
        rig.app("ru.keepcoder.Telegram", mic: false, sound: false)
        rig.poll([5, 7])
        #expect(rig.monitor.state == .idle)
        await rig.store.journal?.settle()
        #expect(rig.journalFiles.isEmpty)
        #expect(rig.asked.isEmpty)
    }

    @Test func aKeptCallEndsInTheStoreTranscribed() async throws {
        let rig = Rig()
        rig.app("ru.keepcoder.Telegram", mic: true, sound: true)
        rig.poll([0, 21])
        guard case .asking(let info) = rig.monitor.state else { Issue.record("not asking"); return }
        #expect(info.muteKnown)
        let mic = try #require(rig.sources.first?[.mic])
        let remote = try #require(rig.sources.first?[.remote])
        mic.push(speechLike(seconds: 12), at: 0)
        remote.push([Float](repeating: 0, count: Int(12 * rate)), at: 0)
        rig.monitor.keep()
        guard case .recording = rig.monitor.state else { Issue.record("not recording"); return }
        #expect(rig.store.call(id: info.id)?.status == .recording)
        // Telegram mutes by giving the mic back.
        rig.app("ru.keepcoder.Telegram", mic: false, sound: true)
        rig.poll([25, 27])
        rig.app("ru.keepcoder.Telegram", mic: true, sound: true)
        rig.poll([30])
        rig.app("ru.keepcoder.Telegram", mic: false, sound: false)
        rig.poll(stride(from: 40.0, through: 101, by: 1))
        #expect(rig.monitor.state == .ending || rig.monitor.state == .idle)
        await rig.monitor.waitForEndings()
        await rig.transcriber.waitUntilIdle()
        #expect(rig.monitor.state == .idle)
        let call = try #require(rig.store.call(id: info.id))
        #expect(call.status == .done)
        #expect(call.service == .telegram && call.muteKnown)
        #expect(call.muteIntervals.count == 1)
        #expect(abs((call.muteIntervals.first?.start ?? 0) - 25) < 0.01)
        #expect(abs(call.micSeconds - 12) < 0.01)
        #expect(call.remoteProblem == CallStore.silentTapMessage)
        #expect(call.transcript?.segments.map(\.text) == ["Hello there"])
        await rig.store.journal?.settle()
        #expect(rig.journalFiles.isEmpty)
    }

    @Test func aCallEndingUnansweredWaitsForTheAnswer() async throws {
        let rig = Rig()
        rig.app("us.zoom.xos", mic: true, sound: true)
        rig.poll([0, 21])
        guard case .asking(let info) = rig.monitor.state else { Issue.record("not asking"); return }
        rig.sources.first?[.mic]?.push(speechLike(seconds: 3), at: 0)
        rig.app("us.zoom.xos", mic: false, sound: false)
        rig.poll(stride(from: 22.0, through: 90, by: 1))
        await rig.monitor.waitForEndings()
        #expect(rig.store.call(id: info.id)?.status == .unconfirmed)
        #expect(rig.answered.isEmpty)
        rig.monitor.keep(callID: info.id)
        await rig.transcriber.waitUntilIdle()
        #expect(rig.store.call(id: info.id)?.status == .done)
        #expect(rig.answered == [info.id])
    }

    @Test func manualRecordingTakesEverythingAndConfirmsANoticedCall() async throws {
        let rig = Rig()
        rig.monitor.startManual()
        guard case .recording(let manual) = rig.monitor.state else { Issue.record("not recording"); return }
        #expect(manual.manual && manual.appName == CallMonitor.manualName)
        // A call noticed meanwhile is the manual recording's.
        rig.app("com.hnc.Discord", mic: true, sound: true)
        rig.poll([0, 21])
        guard case .recording(let still) = rig.monitor.state, still.id == manual.id else {
            Issue.record("manual recording replaced")
            return
        }
        rig.sources.first?[.mic]?.push(speechLike(seconds: 2), at: 0)
        rig.monitor.stop(keep: true)
        await rig.monitor.waitForEndings()
        await rig.transcriber.waitUntilIdle()
        #expect(rig.store.call(id: manual.id)?.manual == true)
        #expect(rig.store.call(id: manual.id)?.status == .done)
        // The Discord call goes on, and isn't picked up again.
        rig.poll([22, 23])
        #expect(rig.monitor.state == .idle)

        // During a noticed call, Start Call Recording keeps it.
        let other = Rig()
        other.app("com.tinyspeck.slackmacgap", mic: true, sound: true)
        other.poll([0])
        other.monitor.startManual()
        guard case .recording(let kept) = other.monitor.state else { Issue.record("not kept"); return }
        #expect(!kept.manual && kept.service == .slack)
        other.poll([21])
        guard case .recording = other.monitor.state else { Issue.record("asked anyway"); return }
        #expect(other.asked.isEmpty)
        other.monitor.stop(keep: false)
        await other.store.journal?.settle()
        #expect(other.journalFiles.isEmpty)
        #expect(other.store.calls.isEmpty)
    }
}

// MARK: - Answers, a line per phrase

@Suite struct CallAnswerFormatTests {
    @Test func linesAreReadWhateverTheModelAddsAround() throws {
        let answer = """
            Here is the transcript:

            [00:01-00:04] Аня: Привет, как дела? [смеётся]
            [0:05.5-0:07] Participant 2: «Нормально», сказал он: "да".

            - **[01:02:03 - 01:02:05] HR: Аня:** Ок
            [12] Participant 2: Plain seconds
            00:20-00:22 Participant 1: A bare time
            [00:30–00:33] [смеётся]
            [00:40] Participant [3]: (тихо) "Brackets" in the name
            ```
            That's everything I heard.
            """
        let parsed = CallTranscriptParser.parse(answer, side: .remote, duration: 4000, speakers: ["HR: Аня"])
        #expect(parsed.format == .lines)
        // The remark before and after; blank lines and the fence aren't counted.
        #expect(parsed.skipped == 2)
        let s = parsed.segments
        #expect(s.map(\.speaker) == ["Аня", "Participant 2", "HR: Аня", "Participant 2", "Participant 1",
                                     "Participant 1", "Participant [3]"])
        #expect(s.map(\.text) == ["Привет, как дела? [смеётся]", "«Нормально», сказал он: \"да\".", "Ок",
                                  "Plain seconds", "A bare time", "[смеётся]", "(тихо) \"Brackets\" in the name"])
        #expect(s[0].start == 1 && s[0].end == 4)
        #expect(s[1].start == 5.5 && s[1].end == 7)
        #expect(s[2].start == 3723 && s[2].end == 3725)
        // No end: up to the next phrase.
        #expect(s[3].start == 12 && s[3].end == 20)
        #expect(s[5].start == 30 && s[5].end == 33)
        #expect(s.allSatisfy { $0.side == .remote })
    }

    @Test func aLineWithoutANameIsTheSpeakerBeforeAndListNumbersArentTimes() {
        let answer = """
            1. [00:02-00:03] Sam: Первое
            [00:04-00:05] и продолжение
            2. Not a phrase
            2024 was a year: not a phrase either
            """
        let parsed = CallTranscriptParser.parse(answer, side: .local, duration: 60, defaultSpeaker: "Sam")
        #expect(parsed.segments.map(\.speaker) == ["Sam", "Sam"])
        #expect(parsed.segments.map(\.text) == ["Первое", "и продолжение"])
        #expect(parsed.skipped == 2)
        // The first line names nobody: the side's own voice.
        let alone = CallTranscriptParser.parse("[00:01] [кашляет]", side: .local, duration: 60, defaultSpeaker: "Sam")
        #expect(alone.segments.map(\.speaker) == ["Sam"])
    }

    @Test func noSpeechIsNotAFailureButWordsWithNoPhraseAre() throws {
        for answer in ["", "NO SPEECH", "\n  \n", "[]", "```\n```", "(No speech.)"] {
            let parsed = CallTranscriptParser.parse(answer, side: .remote, duration: 10)
            #expect(parsed.format == .empty, "\(answer)")
            #expect(try CallTranscriptParser.segments(from: answer, side: .remote, duration: 10).isEmpty)
        }
        let words = CallTranscriptParser.parse("I can't make out any speech.\nSorry.", side: .remote, duration: 10)
        #expect(words.format == .unreadable && words.skipped == 2)
        #expect(throws: CallTranscriber.Failure.unreadableAnswer(track: .remote, chunk: 1, chunks: 1, lines: 2)) {
            try CallTranscriptParser.segments(from: "I can't make out any speech.\nSorry.", side: .remote,
                                              duration: 10)
        }
    }

    @Test func aBrokenJSONArrayGivesUpOnlyItsBrokenObjects() {
        // A quote left unescaped, then an answer that stops mid-object.
        let answer = """
            [{"start": "00:01", "end": "00:02", "speaker": "Аня", "text": "Он сказал "да" и ушёл"},
             {"start": "00:03", "end": "00:04", "speaker": "Sam", "text": "Ок, {понял}"},
             {"start": 5, "end": 6.5, "speaker": "Аня", "text": "Пока"},
             {"start": "00:07", "speak
            """
        let parsed = CallTranscriptParser.parse(answer, side: .remote, duration: 60)
        #expect(parsed.format == .salvaged)
        #expect(parsed.segments.map(\.text) == ["Он сказал \"да\" и ушёл", "Пока"])
        #expect(parsed.segments.map(\.start) == [1, 5])
        #expect(parsed.skipped == 1, "the object with braces in its text")
        // A whole array is still read as JSON.
        let whole = CallTranscriptParser.parse(#"[{"start":"00:01","end":"00:02","speaker":"Аня","text":"Да"}]"#,
                                               side: .remote, duration: 60)
        #expect(whole.format == .json && whole.segments.map(\.text) == ["Да"])
    }

    @Test func thePromptAsksForLines() {
        let prompt = CallPrompts.remote(roster: [], service: "Telegram")
        #expect(prompt.contains("[start-end] Speaker: what they said"))
        #expect(prompt.contains(CallPrompts.noSpeech))
        #expect(!prompt.contains("JSON"))
    }
}

// MARK: - Answers kept, cut off, logged

@MainActor
@Suite(.serialized) struct CallAnswerKeepingTests {
    private static func store() -> (CallStore, CallRecord) {
        let store = CallStore(paths: .temporary(), settings: .inMemory())
        store.load()
        var call = CallRecord(id: UUID(), startedAt: Date(), appName: "Telegram", service: .telegram, status: .done)
        call.micFile = "mic.m4a"
        call.micSeconds = 10
        call.remoteFile = "remote.m4a"
        call.remoteSeconds = 10
        store.upsert(call)
        return (store, call)
    }

    private static func log() -> (DiagnosticLog, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("calls-log-\(UUID().uuidString)", isDirectory: true)
        let log = DiagnosticLog()
        log.start(directory: folder)
        return (log, folder)
    }

    @Test func answersAreKeptWithTheCallAndGoWithIt() async throws {
        let (store, call) = Self.store()
        let speech = speechLike(seconds: 10)
        let transcriber = CallTranscriber(store: store) { _, prompt, _ in
            CloudResult(text: prompt.contains("the other participants") ? "[00:01-00:02] Аня: Привет"
                        : "Sure!\n[00:03-00:04] Sam: Hi")
        }
        transcriber.read = { _, range in Array(speech[range]) }
        transcriber.transcribe(call.id)
        await transcriber.waitUntilIdle()
        let answers = store.answersFolder(for: call.id)
        #expect(files(in: answers) == ["1-remote.txt", "1-mic.txt"])
        #expect(try String(contentsOf: answers.appendingPathComponent("1-mic.txt"), encoding: .utf8)
                == "Sure!\n[00:03-00:04] Sam: Hi")
        #expect(store.call(id: call.id)?.transcript?.segments.map(\.text) == ["Привет", "Hi"])
        store.delete(call.id)
        await store.flush()
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: call.id).path))
    }

    @Test func anUnreadableAnswerSaysHowMuchAndWhereItIs() async throws {
        let (store, call) = Self.store()
        let speech = speechLike(seconds: 10)
        let transcriber = CallTranscriber(store: store) { _, _, _ in
            CloudResult(text: "I'm sorry,\nI can't transcribe this.\nIt is too quiet.")
        }
        transcriber.read = { _, range in Array(speech[range]) }
        transcriber.transcribe(call.id)
        await transcriber.waitUntilIdle()
        let failed = try #require(store.call(id: call.id))
        #expect(failed.status == .failed)
        let error = try #require(failed.error)
        #expect(error.contains("their side") && error.contains("any of its 3 lines") && error.contains("Show in Finder"))
        #expect(files(in: store.answersFolder(for: call.id)) == ["1-remote.txt"])
    }

    @Test func aCutOffAnswerIsReadAsFarAsItGoes() async throws {
        let (store, call) = Self.store()
        let speech = speechLike(seconds: 30)
        let mic = OSAllocatedUnfairLock(initialState: 0)
        let transcriber = CallTranscriber(store: store) { _, prompt, _ in
            if prompt.contains("the other participants") {
                throw AppError.openRouterTruncated("[00:01-00:03] Аня: Первая фраза\n[00:12-00:14] Аня: Вторая\n[00:15-00")
            }
            mic.withLock { $0 += 1 }
            return CloudResult(text: "[00:20-00:21] Sam: Да")
        }
        transcriber.read = { _, range in Array(speech[range]) }
        store.update(call.id) {
            $0.micSeconds = 30
            $0.remoteSeconds = 30
        }
        transcriber.transcribe(call.id)
        await transcriber.waitUntilIdle()
        let done = try #require(store.call(id: call.id))
        #expect(done.status == .done)
        #expect(mic.withLock { $0 } == 1, "the mic is still asked")
        #expect(done.transcript?.segments.map(\.text) == ["Первая фраза", "Вторая", "Да"])
        #expect(done.cutOffAt == 14)
        #expect(CallFormat.notes(done).contains { $0.contains("may be cut off at 00:14") })
        // The partial answer is kept as it came.
        #expect(try String(contentsOf: store.answersFolder(for: call.id).appendingPathComponent("1-remote.txt"),
                           encoding: .utf8).hasSuffix("[00:15-00"))
    }

    @Test func eachRequestIsLoggedWithoutWhatWasSaid() async throws {
        let (log, folder) = Self.log()
        defer {
            log.stop()
            log.flush()
            try? FileManager.default.removeItem(at: folder)
        }
        let (store, call) = Self.store()
        let quiet = [Float](repeating: 0, count: Int(10 * rate))
        let speech = speechLike(seconds: 10)
        let transcriber = CallTranscriber(store: store) { _, _, _ in
            var result = CloudResult(text: "Note: one phrase\n[00:01-00:02] Sam: секретные слова")
            result.costUSD = 0.004
            result.finishReason = "stop"
            return result
        }
        transcriber.log = log
        transcriber.read = { url, range in url.lastPathComponent == "remote.m4a" ? Array(quiet[range]) : Array(speech[range]) }
        transcriber.transcribe(call.id)
        await transcriber.waitUntilIdle()
        log.flush()
        let text = log.retainedText()
        let id = CallTranscriber.shortID(call.id)
        #expect(text.contains("[calls] transcription.started call=\(id) chunks=1 remote=10 mic=10 mutes=0"))
        #expect(text.contains("[calls] transcription.skipped call=\(id) track=remote chunk=1"))
        #expect(text.contains("[calls] transcription.request call=\(id) track=mic chunk=1 chunks=1 audio=10 chars=51 "
                              + "format=lines phrases=1 skipped=1 finish=stop cost=0"))
        #expect(text.contains("[calls] transcription.finished call=\(id) phrases=1 requests=1 skippedSilent=1"))
        #expect(!text.contains("секрет"), "never what was said")
    }
}

// MARK: - A call split by a relaunch

@MainActor
@Suite(.serialized) struct CallContinuationTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// A kept Telegram call an earlier run left in the journal: `seconds` of speech on both tracks, started so it
    /// stopped `gap` seconds before `now`, muted from 1 to 1.5 s.
    private static func leaveInterruptedCall(in paths: AppPaths, seconds: Double, gap: Double) async -> UUID {
        var info = CallJournal.Info(startedAt: now.addingTimeInterval(-seconds - gap), appName: "Telegram",
                                    bundleID: "ru.keepcoder.Telegram", service: .telegram, consent: .kept)
        info.mutes = [CallInterval(start: 1, end: 1.5)]
        info.muteKnown = true
        let journal = CallJournal(directory: paths.callJournals)
        let mic = FakeSource(), remote = FakeSource()
        journal.begin(info, origin: 0, sources: [.mic: mic, .remote: remote])
        mic.push(speechLike(seconds: seconds), at: 0)
        remote.push(speechLike(seconds: seconds), at: 0)
        _ = await journal.end(info.id)
        return info.id
    }

    private static func rms(_ samples: [Float]) -> Float {
        samples.isEmpty ? 0 : (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    @Test func aCallSplitByARelaunchIsOneCallWithItsTracksInLine() async throws {
        let paths = AppPaths.temporary()
        let earlier = await Self.leaveInterruptedCall(in: paths, seconds: 2, gap: 5)
        let (log, logs) = (DiagnosticLog(), FileManager.default.temporaryDirectory.appendingPathComponent("calls-log-\(UUID().uuidString)", isDirectory: true))
        log.start(directory: logs)
        defer {
            log.stop()
            log.flush()
            try? FileManager.default.removeItem(at: logs)
        }
        let rig = CallMonitorTests.Rig(mode: .ask, paths: paths)
        rig.monitor.log = log
        rig.store.log = log
        await rig.store.waitForRecovery()
        #expect(rig.store.call(id: earlier)?.status == .interrupted)

        // The same call, noticed again right after the relaunch: kept without asking, it was kept before.
        rig.app("ru.keepcoder.Telegram", mic: true, sound: true)
        rig.poll([0, 21])
        guard case .recording(let info) = rig.monitor.state else { Issue.record("not kept"); return }
        #expect(rig.asked.isEmpty)
        rig.sources.first?[.mic]?.push(speechLike(seconds: 3), at: 0)
        rig.sources.first?[.remote]?.push(speechLike(seconds: 3), at: 0)
        rig.app("ru.keepcoder.Telegram", mic: false, sound: false)
        rig.poll(stride(from: 22.0, through: 101, by: 1))
        await rig.monitor.waitForEndings()
        await rig.transcriber.waitUntilIdle()

        #expect(rig.store.calls.map(\.id) == [earlier], "one call, the earlier one")
        let call = try #require(rig.store.call(id: earlier))
        #expect(call.status == .done && call.error == nil)
        #expect(call.transcript?.segments.map(\.text) == ["Hello there"])
        // 2 s, the 5 s gap as silence, then 3 s: both tracks the same length, the continuation at 7 s on both.
        #expect(abs(call.micSeconds - 10) < 0.05 && abs(call.remoteSeconds - 10) < 0.05)
        for track in CallJournal.Track.allCases {
            let url = try #require(rig.store.audioURL(of: call, track: track))
            let before = try CallAudio.read(url, range: Int(0.2 * rate)..<Int(1.8 * rate))
            let gap = try CallAudio.read(url, range: Int(2.5 * rate)..<Int(6.5 * rate))
            let after = try CallAudio.read(url, range: Int(7.5 * rate)..<Int(9.5 * rate))
            #expect(Self.rms(before) > 0.01 && Self.rms(after) > 0.01, "\(track)")
            #expect(Self.rms(gap) < 0.001, "\(track)")
        }
        #expect(call.muteIntervals.first == CallInterval(start: 1, end: 1.5))
        #expect(!FileManager.default.fileExists(atPath: rig.store.folder(for: info.id).path))
        await rig.store.journal?.settle()
        #expect(files(in: paths.callJournals).isEmpty)
        log.flush()
        let text = log.retainedText()
        #expect(text.contains("call.continues call=\(CallTranscriber.shortID(info.id)) app=ru.keepcoder.Telegram"))
        #expect(text.contains("call.joined call=\(CallTranscriber.shortID(earlier))"))
    }

    @Test func onlyACallSoonAfterInTheSameAppContinuesIt() async throws {
        let paths = AppPaths.temporary()
        let earlier = await Self.leaveInterruptedCall(in: paths, seconds: 2, gap: 5)
        let store = CallStore(paths: paths, settings: .inMemory())
        store.load()
        await store.waitForRecovery()
        let telegram = "ru.keepcoder.Telegram"
        #expect(store.interruptedCall(continuedBy: telegram, service: .telegram, pageTitle: nil, manual: false,
                                      startedAt: Self.now)?.id == earlier)
        #expect(store.interruptedCall(continuedBy: telegram, service: .telegram, pageTitle: nil, manual: false,
                                      startedAt: Self.now.addingTimeInterval(CallStore.continuationWindow)) == nil)
        #expect(store.interruptedCall(continuedBy: "us.zoom.xos", service: .zoom, pageTitle: nil, manual: false,
                                      startedAt: Self.now) == nil)
        #expect(store.interruptedCall(continuedBy: telegram, service: .telegram, pageTitle: nil, manual: true,
                                      startedAt: Self.now) == nil)
        // Once transcribed (Transcribe on the interrupted call), it's a call of its own.
        store.update(earlier) { $0.status = .done }
        #expect(store.interruptedCall(continuedBy: telegram, service: .telegram, pageTitle: nil, manual: false,
                                      startedAt: Self.now) == nil)
    }

    @Test func aCallInterruptedTwiceComesBackAsOne() async throws {
        let paths = AppPaths.temporary()
        let first = await Self.leaveInterruptedCall(in: paths, seconds: 2, gap: 8)
        // The continuation was cut off too, before it was joined: both come back at the next launch.
        var info = CallJournal.Info(startedAt: Self.now.addingTimeInterval(-4), appName: "Telegram",
                                    bundleID: "ru.keepcoder.Telegram", service: .telegram, consent: .kept)
        info.mutes = [CallInterval(start: 0.5, end: 1)]
        info.muteKnown = true
        let journal = CallJournal(directory: paths.callJournals)
        let mic = FakeSource()
        journal.begin(info, origin: 0, sources: [.mic: mic])
        mic.push(speechLike(seconds: 3), at: 0)
        _ = await journal.end(info.id)

        let store = CallStore(paths: paths, settings: .inMemory())
        store.load()
        await store.waitForRecovery()
        #expect(store.calls.map(\.id) == [first])
        let call = try #require(store.call(id: first))
        #expect(call.status == .interrupted && call.error == CallStore.interruptedMessage)
        // Started 10 s before now; the second part 6 s in, 3 s long. It had no remote track: the earlier one stays.
        #expect(abs(call.micSeconds - 9) < 0.05)
        #expect(abs(call.remoteSeconds - 2) < 0.05)
        #expect(call.muteIntervals == [CallInterval(start: 1, end: 1.5), CallInterval(start: 6.5, end: 7)])
    }
}
