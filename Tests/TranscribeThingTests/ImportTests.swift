import AVFoundation
import Foundation
import Testing
@testable import TranscribeThing

// MARK: - Reading a file

@Suite struct ImportedAudioTests {
    /// Bursts of a 220 Hz tone over a quiet floor: what the speech analyzer takes for talking.
    static func speechLike(seconds: Double, rate: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            let loud = t.truncatingRemainder(dividingBy: 0.5) < 0.3
            return Float(sin(2 * .pi * 220 * t) * (loud ? 0.2 : 0.002))
        }
    }

    /// Writes `samples` to every channel of a new file at `rate`, as `format` (LPCM or AAC).
    static func write(_ samples: [Float], rate: Double, channels: Int, format: AudioFormatID,
                      name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        var settings: [String: Any] = [AVFormatIDKey: format, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels]
        if format == kAudioFormatLinearPCM {
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
        }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<channels {
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![channel].update(from: source.baseAddress!, count: samples.count)
            }
        }
        try file.write(from: buffer)
        return url
    }

    @Test func aStereoWAVAt44kReadsAs16kMono() async throws {
        let url = try Self.write(Self.speechLike(seconds: 3, rate: 44_100), rate: 44_100, channels: 2,
                                 format: kAudioFormatLinearPCM, name: "interview.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = try await ImportedAudio.read(url)
        #expect(file.fileName == "interview.wav")
        #expect(abs(file.duration - 3) < 0.05)
        #expect(file.speech.voicedSeconds > 1 && !file.speech.isSilent)
    }

    @Test func anM4AReads() async throws {
        let url = try Self.write(Self.speechLike(seconds: 2, rate: 48_000), rate: 48_000, channels: 1,
                                 format: kAudioFormatMPEG4AAC, name: "voice note.m4a")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = try await ImportedAudio.read(url)
        #expect(abs(file.duration - 2) < 0.1)
        #expect(file.speech.voicedSeconds > 0.5)
    }

    @Test func silenceIsntTranscribed() async throws {
        let url = try Self.write(Array(repeating: 0, count: 32_000), rate: 16_000, channels: 1,
                                 format: kAudioFormatLinearPCM, name: "quiet.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await #expect(throws: ImportedAudio.ReadError.silent) { try await ImportedAudio.read(url) }
    }

    @Test func aDocumentIsntAudio() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("notes.txt")
        try Data("not audio".utf8).write(to: url)
        await #expect(throws: ImportedAudio.ReadError.unreadable) { try await ImportedAudio.read(url) }
    }
}

// MARK: - Into History

@MainActor
@Suite(.serialized) struct ImportedFileControllerTests {
    private typealias H = DictationControllerTests

    private static func file(seconds: Double = 4) -> ImportedAudio {
        ImportedAudio(fileName: "interview.mp3", samples: Array(repeating: 0.1, count: Int(16_000 * seconds)),
                      speech: SpeechStats(voicedSeconds: seconds * 0.8, peakDBFS: -10, isSilent: false))
    }

    /// A file becomes a row of its own, marked with its name, and the model picked makes its transcript without
    /// pasting anything.
    @Test func aFileBecomesATranscriptMarkedWithItsName() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()))
        var asked: [(seconds: Double, engine: EngineID)] = []
        h.controller.transcribeOverride = { recording, engine in
            asked.append((recording.duration, engine))
            try await Task.sleep(for: .milliseconds(30))
            return TranscriptResult(text: "What the file said.", engine: engine, processingTime: 0.5)
        }
        h.controller.insertOverride = { _ in Issue.record("a file's transcript is never pasted"); return .pasted }
        h.controller.transcribe(Self.file(), as: .transcription(.geminiFlash))
        let id = try #require(h.history.entries.first?.id)
        #expect(h.history.entries.first?.importedFrom == "interview.mp3")
        #expect(h.controller.runningVersions[id] == .transcription(.geminiFlash), "the row shows it running")
        try await waitUntil { h.history.entry(id: id)?.status == .success }
        let entry = try #require(h.history.entry(id: id))
        #expect(entry.text == "What the file said." && entry.engine == .geminiFlash)
        #expect(entry.importedFrom == "interview.mp3" && entry.audioDuration == 4)
        #expect(asked.map(\.engine) == [.geminiFlash] && asked.first?.seconds == 4)
        #expect(h.toasts.notices.isEmpty && h.controller.machine.activeJobs == 0)
    }

    @Test func aFileThatFailsSaysWhyAndKeepsItsName() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()))
        h.controller.transcribeOverride = { _, _ in throw AppError.engineFailed(.parakeetCloud, "boom") }
        h.controller.transcribe(Self.file(), as: .transcription(.parakeetCloud))
        let id = try #require(h.history.entries.first?.id)
        try await waitUntil { h.history.entry(id: id)?.status == .failed }
        #expect(h.history.entry(id: id)?.importedFrom == "interview.mp3")
    }

    @Test func polishWorksOnAFile() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()))
        h.controller.transcribeOverride = { _, engine in
            TranscriptResult(text: "The message.", engine: engine, processingTime: 0.5)
        }
        h.controller.transcribe(Self.file(), as: .polish)
        let id = try #require(h.history.entries.first?.id)
        try await waitUntil { h.history.entry(id: id)?.status == .success }
        #expect(h.history.entry(id: id)?.currentKind == .polish)
    }

    /// Words, speed and time saved are the user's own talking: a file's transcript stays out of them.
    @Test func filesStayOutOfTheStats() {
        let now = Date()
        let spoken = TranscriptEntry(createdAt: now, text: "one two three", engine: .parakeet, audioDuration: 3,
                                     voicedSeconds: 3)
        let imported = TranscriptEntry(createdAt: now, text: "a b c d e f", engine: .geminiFlash, audioDuration: 60,
                                       voicedSeconds: 50, importedFrom: "talk.mp3")
        let stats = HistoryStats.compute([spoken, imported], now: now, calendar: .current)
        #expect(stats.wordsThisWeek == 3 && stats.totalDictations == 1)
    }

    @Test func theFileNameIsKeptAndSearchable() throws {
        let entry = TranscriptEntry(text: "hello", engine: .geminiFlash, audioDuration: 3, voicedSeconds: 2,
                                    importedFrom: "Standup 10-09.m4a")
        let data = try JSONEncoder().encode(entry)
        #expect(try JSONDecoder().decode(TranscriptEntry.self, from: data).importedFrom == "Standup 10-09.m4a")
        #expect(HistoryGrouping.filter([entry], query: "standup").count == 1)
    }

    /// The dialog's models: the main one first, then Polish and Translate, and each says why it can't run.
    @Test func theMainModelComesFirst() {
        let choices = ImportChoices.make(main: .geminiFlash) { engine in
            engine.isLocal ? .needsDownload : .ready
        }
        #expect(choices.first?.kind == .transcription(.geminiFlash))
        #expect(choices.suffix(2).map(\.kind) == [.polish, .translation(polished: false)])
        #expect(choices.filter { !$0.isEnabled }.allSatisfy { $0.kind.engine.isLocal })
        #expect(Set(choices.map(\.kind)).count == choices.count)
    }
}
