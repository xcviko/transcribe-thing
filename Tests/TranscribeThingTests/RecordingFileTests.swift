import AVFoundation
import Foundation
import os
import Testing
@testable import TranscribeThing

// How History keeps recordings: AAC in an .m4a (WAV from older builds, or when the encoder fails), read back either
// way, and the older builds' WAVs compressed in the background.

private let rate = Recording.sampleRate

/// `seconds` of something like speech: a 140 Hz voice with its harmonics, in syllables (four a second) that pause for
/// the last quarter of every second, over faint noise. The same every time.
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

private func dBFS(_ samples: ArraySlice<Float>) -> Double {
    let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count))
    return power > 0 ? 10 * log10(power) : -160
}

private func dBFS(_ samples: [Float]) -> Double { dBFS(samples[...]) }

/// A fresh folder under the temporary directory.
private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func files(in folder: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
}

private func size(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
}

private struct EncoderFailed: Error {}

/// Encodes only the first half: a copy that reads back short.
private let halfEncoder: RecordingFile.Encoder = { samples, url in
    try RecordingFile.aac(Array(samples.prefix(samples.count / 2)), url)
}

/// Counts the encoder's calls from any thread.
private final class Calls: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var value: Int { count.withLock { $0 } }
    @discardableResult func add() -> Int { count.withLock { $0 += 1; return $0 } }
}

@Suite struct RecordingFileTests {
    @Test func aRecordingRoundTripsAsAAC() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let samples = speechLike(seconds: 3)
        let url = folder.appendingPathComponent("\(UUID().uuidString).m4a")
        #expect(RecordingFile.save(samples, as: url) == url)
        #expect(files(in: folder) == [url.lastPathComponent], "no partial file, no WAV")

        let format = try AVAudioFile(forReading: url).fileFormat
        #expect(format.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(format.sampleRate == 16_000 && format.channelCount == 1)
        #expect(size(url) < WAVEncoder.pcm16(samples).count / 5)

        let decoded = try #require(RecordingFile.read(url))
        #expect(decoded.count == samples.count, "as long as it was, to the sample")
        #expect(abs(dBFS(decoded) - dBFS(samples)) < 1, "its energy kept")
        let syllable = Int(0.1 * rate)..<Int(0.2 * rate), pause = Int(0.8 * rate)..<Int(0.95 * rate)
        #expect(abs(dBFS(decoded[syllable]) - dBFS(samples[syllable])) < 1.5)
        #expect(dBFS(decoded[pause]) < dBFS(decoded[syllable]) - 30, "a pause stays quiet")
    }

    @Test func aFailedEncodeKeepsTheRecordingAsWAV() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let samples = speechLike(seconds: 1)
        let url = folder.appendingPathComponent("rec.m4a")
        try Data("older".utf8).write(to: url)
        let saved = RecordingFile.save(samples, as: url) { _, _ in throw EncoderFailed() }
        #expect(saved == folder.appendingPathComponent("rec.wav"))
        #expect(files(in: folder) == ["rec.wav"], "the older .m4a goes, and no partial file stays")
        let decoded = try #require(saved.flatMap(RecordingFile.read))
        #expect(decoded.count == samples.count)
        #expect(zip(decoded, samples).allSatisfy { abs($0 - $1) <= 1 / 32_768 + 1e-6 })
    }

    @Test func aSaveReplacesTheRecordingInTheOtherFormat() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let samples = speechLike(seconds: 1)
        try WAVEncoder.pcm16(samples).write(to: folder.appendingPathComponent("rec.wav"))
        let url = folder.appendingPathComponent("rec.m4a")
        #expect(RecordingFile.save(samples, as: url) == url)
        #expect(files(in: folder) == ["rec.m4a"])
    }

    @Test func legacyWAVAndAACBothReadBack() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let samples = speechLike(seconds: 1.5)
        let wav = folder.appendingPathComponent("old.wav")
        try WAVEncoder.pcm16(samples).write(to: wav)
        #expect(RecordingFile.read(wav) == WAVEncoder.decode(WAVEncoder.pcm16(samples)))
        let aac = folder.appendingPathComponent("new.m4a")
        try RecordingFile.aac(samples, aac)
        #expect(RecordingFile.read(aac)?.count == samples.count)

        let junk = folder.appendingPathComponent("junk.m4a")
        try Data("not audio".utf8).write(to: junk)
        #expect(RecordingFile.read(junk) == nil)
        #expect(RecordingFile.read(folder.appendingPathComponent("gone.m4a")) == nil)
        #expect(RecordingFile.read(folder.appendingPathComponent("gone.wav")) == nil)
    }

    @Test func compressingChecksTheLengthItReadsBack() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let samples = speechLike(seconds: 2)
        let wav = folder.appendingPathComponent("old.wav")
        try WAVEncoder.pcm16(samples).write(to: wav)
        let out = folder.appendingPathComponent("out.m4a")

        let check = try RecordingFile.compress(wav, into: out)
        #expect(check.sourceSamples == samples.count && check.outputSamples == samples.count)
        #expect(abs(20 * log10(Double(check.outputRMS / check.sourceRMS))) < 1)
        #expect(RecordingFile.read(out)?.count == samples.count)

        #expect(throws: RecordingFile.CompressError.self) {
            try RecordingFile.compress(wav, into: out, encode: halfEncoder)
        }
        #expect(!FileManager.default.fileExists(atPath: out.path), "what didn't pass is removed")
        #expect(throws: EncoderFailed.self) {
            try RecordingFile.compress(wav, into: out) { _, url in
                try Data("half a file".utf8).write(to: url)
                throw EncoderFailed()
            }
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(throws: RecordingFile.CompressError.self) {
            try RecordingFile.compress(folder.appendingPathComponent("gone.wav"), into: out)
        }
        #expect(files(in: folder) == ["old.wav"])
    }

    @Test func aCompressedWAVTakesItsPlaceOnlyWhileTheWAVIsUnchanged() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let wav = folder.appendingPathComponent("rec.wav"), aac = folder.appendingPathComponent("rec.m4a")
        try WAVEncoder.pcm16(speechLike(seconds: 1)).write(to: wav)

        let first = try #require(RecordingFile.compressLegacy(wav))
        #expect(RecordingFile.isPartial(first.partial.lastPathComponent))
        try WAVEncoder.pcm16(speechLike(seconds: 2)).write(to: wav)
        #expect(RecordingFile.place(first.partial, at: aac, madeFrom: wav, stamp: first.stamp) == nil, "the WAV changed")
        #expect(files(in: folder) == ["rec.wav"])

        let second = try #require(RecordingFile.compressLegacy(wav))
        let placed = try #require(RecordingFile.place(second.partial, at: aac, madeFrom: wav, stamp: second.stamp))
        #expect(placed == RecordingFile.Stamp(aac))
        #expect(files(in: folder) == ["rec.wav", "rec.m4a"], "the WAV goes only once history.json names the new file")
        #expect(RecordingFile.read(aac)?.count == Int(2 * rate))

        #expect(RecordingFile.compressLegacy(folder.appendingPathComponent("gone.wav")) == nil)
        #expect(RecordingFile.compressLegacy(wav) { _, _ in throw EncoderFailed() } == nil)
        #expect(files(in: folder) == ["rec.wav", "rec.m4a"], "no partial file left")

        // A placed file that has to go again goes only while nothing has been saved over it.
        #expect(RecordingFile.save(speechLike(seconds: 3), as: aac) == aac)
        RecordingFile.remove(aac, ifStill: placed)
        #expect(RecordingFile.read(aac)?.count == Int(3 * rate), "saved over since")
        RecordingFile.remove(aac, ifStill: try #require(RecordingFile.Stamp(aac)))
        #expect(files(in: folder).isEmpty)
    }

    @Test func namesTellTheFormatsApart() {
        #expect(RecordingFile.name(for: UUID(uuidString: "6F1C2D3E-0000-4000-8000-000000000001")!)
                == "6F1C2D3E-0000-4000-8000-000000000001.m4a")
        #expect(RecordingFile.otherFormat(of: "abc.wav") == "abc.m4a")
        #expect(RecordingFile.otherFormat(of: "abc.m4a") == "abc.wav")
        #expect(RecordingFile.isRecording("abc.m4a") && RecordingFile.isRecording("abc.wav"))
        #expect(!RecordingFile.isRecording("abc\(RecordingFile.partialSuffix)"), "a partial file is no recording")
        #expect(!RecordingFile.isRecording("history.json"))
    }

    @Test func theRecompressFlagNamesAnotherM4A() {
        let files = EngineCLI.Recompress.files(["--recompress", "/tmp/in.wav", "/tmp/out.m4a"])
        #expect(files?.input.path == "/tmp/in.wav" && files?.output.path == "/tmp/out.m4a")
        #expect(EngineCLI.Recompress.files(["--recompress", "/tmp/in.wav"]) == nil)
        #expect(EngineCLI.Recompress.files(["--recompress", "/tmp/in.wav", "/tmp/out.wav"]) == nil, "not an .m4a")
        #expect(EngineCLI.Recompress.files(["--recompress", "/tmp/a.m4a", "/tmp/./a.m4a"]) == nil, "its own input")
        #expect(EngineCLI.Recompress.files(["--recompress", "/tmp/in.wav", "--model-status"]) == nil)
    }
}

// MARK: - History's recordings

@MainActor
@Suite struct CompressedHistoryTests {
    @MainActor private struct Store {
        let history: HistoryStore
        let paths: AppPaths
        let settings: AppSettings

        func url(_ name: String) -> URL { paths.recordingURL(fileName: name) }
        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }
        var files: Set<String> { TranscribeThingTests.files(in: paths.recordings) }
        func load(_ id: UUID) -> Recording? { history.entry(id: id).flatMap { history.loadRecording(for: $0) } }
        /// Everything the store has queued for the disk has landed.
        func settle() async { _ = await history.recordingsByteCount() }
    }

    private func store(at paths: AppPaths = .temporary(), settings: AppSettings? = nil) async throws -> Store {
        let settings = settings ?? .inMemory()
        let history = HistoryStore(paths: paths, settings: settings)
        history.load()
        try await waitUntil { history.isLoaded }
        try FileManager.default.createDirectory(at: paths.recordings, withIntermediateDirectories: true)
        return Store(history: history, paths: paths, settings: settings)
    }

    private func entry(_ id: UUID = UUID(), file: String?, status: TranscriptStatus = .failed,
                       daysAgo: Double = 0) -> TranscriptEntry {
        TranscriptEntry(id: id, createdAt: Date().addingTimeInterval(-daysAgo * 86_400),
                        text: status == .success ? "hi" : "", engine: .parakeet, status: status, audioDuration: 1,
                        voicedSeconds: 1, audioFileName: file)
    }

    /// An entry as an older build left it: its recording a WAV.
    @discardableResult
    private func legacy(_ s: Store, seconds: Double = 1,
                        daysAgo: Double = 0) throws -> (entry: TranscriptEntry, samples: [Float]) {
        let id = UUID()
        let samples = speechLike(seconds: seconds)
        try WAVEncoder.pcm16(samples).write(to: s.url("\(id.uuidString).wav"))
        let entry = entry(id, file: "\(id.uuidString).wav", daysAgo: daysAgo)
        s.history.upsert(entry)
        return (entry, samples)
    }

    // MARK: Saving

    @Test func aNewRecordingIsKeptAsAAC() async throws {
        let s = try await store()
        defer { try? FileManager.default.removeItem(at: s.paths.root) }
        let recording = Recording(samples: speechLike(seconds: 2))
        let name = try #require(s.history.saveAudio(recording))
        #expect(name == "\(recording.id.uuidString).m4a")
        s.history.upsert(entry(recording.id, file: name))
        await s.settle()
        #expect(s.files == [name])

        let loaded = try #require(s.load(recording.id))
        #expect(loaded.samples.count == recording.samples.count)
        #expect(loaded.aacFile == s.url(name))
        #expect(loaded.speech.voicedSeconds > 0.5 && !loaded.speech.isSilent, "its speech stats come from the audio")
        let bytes = await s.history.recordingsByteCount()
        #expect(bytes == Int64(size(s.url(name))) && bytes < Int64(WAVEncoder.pcm16(recording.samples).count / 5))
    }

    @Test func aRecordingWhoseEncodeFailsIsKeptAsWAVAndItsEntryNamesThat() async throws {
        let s = try await store()
        defer { try? FileManager.default.removeItem(at: s.paths.root) }
        s.history.encodeOverride = { _, _ in throw EncoderFailed() }
        let recording = Recording(samples: speechLike(seconds: 1))
        let name = try #require(s.history.saveAudio(recording))
        s.history.upsert(entry(recording.id, file: name))
        // Read back (Retry, Undo, Home) before the entry hears of the WAV, a main-actor hop after the save.
        let early = try #require(s.load(recording.id))
        #expect(s.history.entry(id: recording.id)?.audioFileName == name)
        #expect(early.samples.count == recording.samples.count && early.aacFile == nil)
        let wav = "\(recording.id.uuidString).wav"
        try await waitUntil { s.history.entry(id: recording.id)?.audioFileName == wav }
        await s.settle()
        #expect(s.files == [wav])
        let loaded = try #require(s.load(recording.id))
        #expect(loaded.samples.count == recording.samples.count && loaded.aacFile == nil)
    }

    /// A save whose encoder failed doesn't rename the entry when a newer save of the recording (that worked) follows.
    @Test func aNewerSaveWinsOverAFailedOne() async throws {
        let s = try await store()
        defer { try? FileManager.default.removeItem(at: s.paths.root) }
        let calls = Calls()
        s.history.encodeOverride = { samples, url in
            if calls.add() == 1 { throw EncoderFailed() }
            try RecordingFile.aac(samples, url)
        }
        let recording = Recording(samples: speechLike(seconds: 1))
        let name = try #require(s.history.saveAudio(recording))
        #expect(s.history.saveAudio(recording) == name)
        s.history.upsert(entry(recording.id, file: name))
        await s.settle()
        // Both saves' follow-ups on the main actor have their turn.
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.value == 2)
        #expect(s.history.entry(id: recording.id)?.audioFileName == name)
        #expect(s.files == [name])
    }

    /// The app quit between a failed encode and its entry naming the WAV: the sweep that follows loading finds the WAV
    /// again, rather than taking it for a recording nobody names.
    @Test func aWAVKeptByAFailedEncodeIsFoundAgain() async throws {
        let s = try await store()
        defer { try? FileManager.default.removeItem(at: s.paths.root) }
        let id = UUID(), samples = speechLike(seconds: 1)
        let wav = "\(id.uuidString).wav", orphan = "\(UUID().uuidString).wav"
        for name in [wav, orphan] {
            try WAVEncoder.pcm16(samples).write(to: s.url(name))
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)],
                                                  ofItemAtPath: s.url(name).path)
        }
        s.history.upsert(entry(id, file: "\(id.uuidString).m4a"))
        s.history.deleteExpired()
        try await waitUntil { s.history.entry(id: id)?.audioFileName == wav }
        await s.settle()
        #expect(s.files == [wav], "a WAV nobody names still goes")
        #expect(s.load(id)?.samples.count == samples.count)
    }

    @Test func aRecordingReadFromItsAACIsNotEncodedAgain() async throws {
        let s = try await store()
        defer { try? FileManager.default.removeItem(at: s.paths.root) }
        let recording = Recording(samples: speechLike(seconds: 1))
        let name = try #require(s.history.saveAudio(recording))
        s.history.upsert(entry(recording.id, file: name))
        await s.settle()
        let bytes = try Data(contentsOf: s.url(name))

        let calls = Calls()
        s.history.encodeOverride = { samples, url in
            calls.add()
            try RecordingFile.aac(samples, url)
        }
        let loaded = try #require(s.load(recording.id))
        #expect(s.history.saveAudio(loaded) == name)
        await s.settle()
        #expect(calls.value == 0)
        #expect(try Data(contentsOf: s.url(name)) == bytes)

        // Read from an older build's WAV, it is encoded, and the WAV goes.
        let (old, _) = try legacy(s)
        let fromWAV = try #require(s.history.loadRecording(for: old))
        #expect(fromWAV.aacFile == nil)
        let saved = try #require(s.history.saveAudio(fromWAV))
        var updated = old
        updated.audioFileName = saved
        s.history.upsert(updated)
        await s.settle()
        #expect(calls.value == 1)
        #expect(s.files == [name, saved])
    }

    // MARK: Compressing older builds' WAVs

    @Test func olderBuildsWAVsAreCompressed() async throws {
        let s = try await store()
        defer { try? FileManager.default.removeItem(at: s.paths.root) }
        let olds = try (0..<3).map { _ in try legacy(s, seconds: 2) }
        s.history.flush()
        let before = await s.history.recordingsByteCount()

        await s.history.compressLegacyRecordings()
        await s.settle()
        #expect(s.history.compressedRecordings == 3)
        let names = olds.map { "\($0.entry.id.uuidString).m4a" }
        #expect(s.history.entries.compactMap(\.audioFileName).sorted() == names.sorted())
        #expect(s.files == Set(names), "the WAVs are gone")
        let saved = try HistoryStore.readEntries(from: Data(contentsOf: s.paths.historyFile))
        #expect(saved.compactMap(\.audioFileName).sorted() == names.sorted(), "history.json names the new files")
        for old in olds {
            let entry = try #require(s.history.entry(id: old.entry.id))
            #expect(s.history.loadRecording(for: entry)?.samples.count == old.samples.count)
        }
        let after = await s.history.recordingsByteCount()
        #expect(after < before / 5)

        await s.history.compressLegacyRecordings()
        #expect(s.history.compressedRecordings == 3, "nothing left to do")
    }

    @Test func aWAVWhoseEncodeFailsStaysAsItWas() async throws {
        let s = try await store()
        defer { try? FileManager.default.removeItem(at: s.paths.root) }
        let failing = try legacy(s, seconds: 1.5)
        let other = try legacy(s, seconds: 1)
        let failingLength = failing.samples.count
        s.history.encodeOverride = { samples, url in
            if samples.count == failingLength { throw EncoderFailed() }
            try RecordingFile.aac(samples, url)
        }
        await s.history.compressLegacyRecordings()
        await s.settle()
        #expect(s.history.entry(id: failing.entry.id) == failing.entry, "untouched")
        #expect(s.history.entry(id: other.entry.id)?.audioFileName == "\(other.entry.id.uuidString).m4a")
        #expect(s.files == [failing.entry.audioFileName!, "\(other.entry.id.uuidString).m4a"], "no partial file left")
        #expect(s.history.compressedRecordings == 1)
    }

    @Test func aWAVWhoseCopyReadsBackShortStaysAsItWas() async throws {
        let s = try await store()
        defer { try? FileManager.default.removeItem(at: s.paths.root) }
        let old = try legacy(s, seconds: 2)
        s.history.encodeOverride = halfEncoder
        await s.history.compressLegacyRecordings()
        await s.settle()
        #expect(s.history.entry(id: old.entry.id) == old.entry)
        #expect(s.files == [old.entry.audioFileName!])
        #expect(s.history.loadRecording(for: old.entry)?.samples.count == old.samples.count)
        #expect(s.history.compressedRecordings == 0)
    }

    /// Crashed mid-way: a partial file, a finished .m4a whose entry still names the WAV (history.json not yet written),
    /// and a WAV whose entry already names its .m4a (the WAV not yet removed). The next launch sorts all three out.
    @Test func anInterruptedRunIsSafeToRunAgain() async throws {
        let paths = AppPaths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let settings = AppSettings.inMemory()
        let first = try await store(at: paths, settings: settings)
        let moved = try legacy(first, seconds: 2)
        let movedAAC = "\(moved.entry.id.uuidString).m4a"
        try RecordingFile.aac(speechLike(seconds: 0.5), first.url(movedAAC))
        let written = try legacy(first, seconds: 1)
        let writtenAAC = "\(written.entry.id.uuidString).m4a"
        try RecordingFile.aac(written.samples, first.url(writtenAAC))
        var named = written.entry
        named.audioFileName = writtenAAC
        first.history.upsert(named)
        let partial = "\(UUID().uuidString)\(RecordingFile.partialSuffix)"
        try Data(repeating: 1, count: 50_000).write(to: first.url(partial))
        first.history.flush()
        let recordings = [moved.entry.audioFileName!, movedAAC, written.entry.audioFileName!, writtenAAC]
        let counted = recordings.reduce(Int64(0)) { $0 + Int64(size(first.url($1))) }
        #expect(await first.history.recordingsByteCount() == counted, "a partial file doesn't count")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)],
                                              ofItemAtPath: first.url(written.entry.audioFileName!).path)

        let next = try await store(at: paths, settings: settings)
        await next.settle()
        #expect(!next.exists(written.entry.audioFileName!), "a WAV no entry names is swept up")
        await next.history.compressLegacyRecordings()
        await next.settle()
        #expect(next.files == [movedAAC, writtenAAC])
        #expect(next.history.entry(id: moved.entry.id)?.audioFileName == movedAAC)
        let entry = try #require(next.history.entry(id: moved.entry.id))
        #expect(next.history.loadRecording(for: entry)?.samples.count == moved.samples.count, "made again from the WAV")
        #expect(next.history.entry(id: written.entry.id)?.audioFileName == writtenAAC)
    }

    @Test func aRecordingInUseIsLeftAlone() async throws {
        let s = try await store()
        defer { try? FileManager.default.removeItem(at: s.paths.root) }
        let busy = try legacy(s)
        let free = try legacy(s)
        s.history.isInUse = { $0 == busy.entry.id }
        await s.history.compressLegacyRecordings()
        await s.settle()
        #expect(s.history.entry(id: busy.entry.id) == busy.entry)
        #expect(s.exists(busy.entry.audioFileName!))
        #expect(s.history.entry(id: free.entry.id)?.audioFileName == "\(free.entry.id.uuidString).m4a")

        // Taken up while it's being encoded: it stays as it was, and its copy goes.
        let taken = OSAllocatedUnfairLock(initialState: false)
        s.history.isInUse = { _ in taken.withLock { $0 } }
        s.history.encodeOverride = { samples, url in
            taken.withLock { $0 = true }
            try RecordingFile.aac(samples, url)
        }
        await s.history.compressLegacyRecordings()
        await s.settle()
        #expect(s.history.entry(id: busy.entry.id) == busy.entry)
        #expect(s.files == [busy.entry.audioFileName!, "\(free.entry.id.uuidString).m4a"])
    }

    /// Taken up just as its copy took the recording's name, and saved again under that name before the conversion
    /// looked a second time: the save stays, only the copy would have gone.
    @Test func aSaveOverAPlacedCopyStays() async throws {
        let s = try await store()
        defer { try? FileManager.default.removeItem(at: s.paths.root) }
        let old = try legacy(s)
        let aac = "\(old.entry.id.uuidString).m4a"
        let again = Recording(id: old.entry.id, samples: speechLike(seconds: 3))
        var saved: String?
        s.history.isInUse = { _ in
            if saved == nil && s.exists(aac) { saved = s.history.saveAudio(again) }
            return saved != nil
        }
        await s.history.compressLegacyRecordings()
        #expect(s.history.compressedRecordings == 0)
        var updated = old.entry
        updated.audioFileName = try #require(saved)
        s.history.upsert(updated)
        await s.settle()
        #expect(s.files == [aac], "the WAV went with the save")
        #expect(s.load(old.entry.id)?.samples.count == again.samples.count)
    }

    /// Two copies of the app on one Recordings folder (an installed one and a bare build) convert the same WAV. The
    /// one that finds the WAV gone once its copy is made leaves the .m4a the other one placed: nothing else is left of
    /// the recording.
    @Test func aConversionThatLosesTheRaceLeavesTheWinnersFile() async throws {
        let paths = AppPaths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let settings = AppSettings.inMemory()
        let first = try await store(at: paths, settings: settings)
        let old = try legacy(first)
        first.history.flush()
        let second = try await store(at: paths, settings: settings)
        #expect(second.history.entry(id: old.entry.id)?.audioFileName == old.entry.audioFileName)

        // The second copy is encoding the WAV when the first one converts it and removes it.
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let encoding = OSAllocatedUnfairLock(initialState: false)
        second.history.encodeOverride = { samples, url in
            encoding.withLock { $0 = true }
            gate.wait()
            try RecordingFile.aac(samples, url)
        }
        let slower = Task { await second.history.compressLegacyRecordings() }
        try await waitUntil { encoding.withLock { $0 } }
        await first.history.compressLegacyRecordings()
        await first.settle()
        let aac = "\(old.entry.id.uuidString).m4a"
        #expect(first.files == [aac])

        gate.signal()
        await slower.value
        await second.settle()
        #expect(second.files == [aac])
        #expect(second.history.entry(id: old.entry.id)?.audioFileName == old.entry.audioFileName, "it names the WAV")
        #expect(second.load(old.entry.id)?.samples.count == old.samples.count, "and reads the .m4a in its place")
    }

    /// Home work on a recording keeps its WAV from being compressed under it (`DictationController.isInFlight`).
    @Test func homeWorkKeepsItsRecordingFromBeingCompressed() async throws {
        let h = DictationControllerTests.make(persistsHistory: true)
        let paths = try #require(h.paths)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        h.history.isInUse = { [weak controller = h.controller] in controller?.isInFlight($0) ?? false }
        h.history.load()
        try await waitUntil { h.history.isLoaded }
        let s = Store(history: h.history, paths: paths, settings: h.settings)
        try FileManager.default.createDirectory(at: paths.recordings, withIntermediateDirectories: true)
        let worked = try legacy(s)
        var release: CheckedContinuation<Void, Never>?
        var heard: [Int] = []
        h.controller.transcribeOverride = { recording, engine in
            heard.append(recording.samples.count)
            await withCheckedContinuation { release = $0 }
            return TranscriptResult(text: "from the WAV", engine: engine, processingTime: 0.1)
        }
        h.controller.retry(worked.entry, with: .parakeet)
        try await waitUntil { release != nil }
        #expect(heard == [worked.samples.count], "Home hears the WAV")

        await h.history.compressLegacyRecordings()
        #expect(h.history.entry(id: worked.entry.id) == worked.entry)
        release?.resume()
        try await waitUntil { h.history.entry(id: worked.entry.id)?.status == .success }
        await s.settle()
        let aac = "\(worked.entry.id.uuidString).m4a"
        #expect(h.history.entry(id: worked.entry.id)?.audioFileName == aac, "saved again, compressed")
        #expect(s.files == [aac], "and the WAV went with it")
    }

    /// Transcribe With on a transcript whose recording is an .m4a hears it, and knows the file it came from.
    @Test func homeWorkHearsAnAAC() async throws {
        let h = DictationControllerTests.make(persistsHistory: true)
        let paths = try #require(h.paths)
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let recording = Recording(samples: speechLike(seconds: 1.5))
        let name = try #require(h.history.saveAudio(recording))
        h.history.upsert(entry(recording.id, file: name, status: .success))
        var heard: [Recording] = []
        h.controller.transcribeOverride = { recording, engine in
            heard.append(recording)
            return TranscriptResult(text: "again", engine: engine, processingTime: 0.1)
        }
        h.controller.retry(try #require(h.history.entry(id: recording.id)), with: .geminiFlash)
        try await waitUntil { h.history.entry(id: recording.id)?.engine == .geminiFlash }
        #expect(heard.map(\.samples.count) == [recording.samples.count])
        #expect(heard.first?.aacFile == paths.recordingURL(fileName: name))
    }

    // MARK: Deleting

    @Test func deletingRemovesEitherFormat() async throws {
        let s = try await store()
        defer { try? FileManager.default.removeItem(at: s.paths.root) }
        s.history.deletedAudioGrace = .zero
        func pair(daysAgo: Double = 0) throws -> [TranscriptEntry] {
            let (wav, _) = try legacy(s, daysAgo: daysAgo)
            let recording = Recording(samples: speechLike(seconds: 0.5))
            let aac = entry(recording.id, file: s.history.saveAudio(recording), daysAgo: daysAgo)
            s.history.upsert(aac)
            return [wav, aac]
        }

        // Delete
        for entry in try pair() { s.history.delete(entry.id) }
        try await waitUntil { s.files.isEmpty }

        // Auto-delete
        let expired = try pair(daysAgo: 3)
        s.settings.autoDeleteHistoryDays = 1
        s.history.deleteExpired()
        await s.settle()
        #expect(s.history.entries.isEmpty && s.files.isEmpty && expired.count == 2)
        s.settings.autoDeleteHistoryDays = 0

        // Clear All
        _ = try pair()
        await s.settle()
        #expect(s.files.count == 2)
        s.history.clearAll()
        await s.settle()
        #expect(s.files.isEmpty)

        // Past the limit
        let oldest = try pair(daysAgo: 1)
        let base = Date()
        for i in 0..<HistoryStore.maxEntries {
            s.history.upsert(TranscriptEntry(createdAt: base.addingTimeInterval(Double(i)), text: "n\(i)",
                                             engine: .parakeet, audioDuration: 1, voicedSeconds: 1))
        }
        await s.settle()
        #expect(oldest.allSatisfy { s.history.entry(id: $0.id) == nil })
        #expect(s.files.isEmpty)
    }
}
