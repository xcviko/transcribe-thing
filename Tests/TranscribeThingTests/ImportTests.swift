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

    /// Gemini stopping short of the end keeps what it wrote: the row has that text, its details say it finished for
    /// length, and the row says it may be cut off. With nothing written, the row fails as before.
    @Test func whatGeminiWroteBeforeStoppingShortIsKept() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()))
        h.controller.transcribeOverride = { _, _ in throw AppError.openRouterTruncated("The first hour of the talk.") }
        h.controller.transcribe(Self.file(), as: .transcription(.geminiFlash))
        let id = try #require(h.history.entries.first?.id)
        try await waitUntil { h.history.entry(id: id)?.status == .success }
        let entry = try #require(h.history.entry(id: id))
        #expect(entry.text == "The first hour of the talk." && entry.importedFrom == "interview.mp3")
        #expect(entry.currentVersion?.metadata.finishReason == "length")
        #expect(entry.currentVersion?.metadata.processingTime == nil)
        let failure = try #require(h.controller.homeFailures[id])
        #expect(failure.kind == .transcription(.geminiFlash) && failure.reason.contains("may be cut off"))
        #expect(h.toasts.notices.isEmpty)

        h.controller.transcribeOverride = { _, _ in throw AppError.openRouterTruncated(" ") }
        h.controller.transcribe(Self.file(), as: .transcription(.geminiFlash))
        let empty = try #require(h.history.entries.first?.id)
        try await waitUntil { h.history.entry(id: empty)?.status == .failed }
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

// MARK: - Reading and asking

/// What happens between a drop and the model dialog, whichever page is showing (`FileImport` lives with the Hub).
@MainActor
@Suite(.serialized) struct FileImportTests {
    private final class Started {
        var files: [(name: String, kind: TranscriptVersionKind)] = []
    }

    /// Each file reads in `delay`; a ".txt" isn't audio. Every model is ready unless `ready` says otherwise.
    private static func make(delay: Duration = .milliseconds(20), ready: Bool = true) -> (FileImport, Started) {
        let imports = FileImport()
        let started = Started()
        imports.settle = .zero
        imports.read = { url async throws(ImportedAudio.ReadError) -> ImportedAudio in
            try? await Task.sleep(for: delay)
            guard url.pathExtension != "txt" else { throw .unreadable }
            return ImportedAudio(fileName: url.lastPathComponent, samples: Array(repeating: 0.1, count: 64_000),
                                 speech: SpeechStats(voicedSeconds: 3, peakDBFS: -10, isSilent: false))
        }
        imports.choices = { seconds in
            ImportChoices.make(main: .parakeet, seconds: seconds) { _ in ready ? .ready : .needsKey }
        }
        imports.start = { file, kind in started.files.append((file.fileName, kind)) }
        return (imports, started)
    }

    private static func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    /// A second drop (or ⌘O) while the first files are read isn't ignored: its files join theirs, in one dialog.
    @Test func filesAddedWhileOthersAreReadJoinTheirBatch() async throws {
        let (imports, started) = Self.make()
        imports.add([Self.url("one.mp3")])
        imports.add([Self.url("two.m4a")])
        #expect(imports.reading == ["one.mp3", "two.m4a"])
        try await waitUntil { imports.prompt == .models }
        #expect(imports.pending.map(\.fileName) == ["one.mp3", "two.m4a"] && imports.reading.isEmpty)
        imports.transcribe(imports.pending, as: .transcription(.parakeet))
        #expect(started.files.map(\.name) == ["one.mp3", "two.m4a"])
        #expect(started.files.allSatisfy { $0.kind == .transcription(.parakeet) })
        #expect(imports.pending.isEmpty && imports.prompt == nil)
    }

    /// Files read while the dialog is up are asked about with the ones it shows.
    @Test func filesAddedWhileTheDialogIsUpJoinIt() async throws {
        let (imports, _) = Self.make()
        imports.add([Self.url("one.mp3")])
        try await waitUntil { imports.prompt == .models }
        imports.add([Self.url("two.mp3")])
        try await waitUntil { imports.pending.count == 2 && imports.prompt == .models }
        imports.dialogDismissed()
        #expect(imports.pending.isEmpty && imports.prompt == nil)
    }

    /// A file that can't be read is said first; the dialog for the others follows once the alert is dismissed.
    @Test func aFileThatCantBeReadIsSaidBeforeTheDialog() async throws {
        let (imports, started) = Self.make()
        imports.settle = .milliseconds(10)
        imports.add([Self.url("talk.mp3"), Self.url("notes.txt")])
        try await waitUntil { imports.prompt == .problem }
        #expect(imports.problem?.title == "Can’t transcribe “notes.txt”")
        #expect(imports.pending.map(\.fileName) == ["talk.mp3"])
        imports.problemDismissed()
        #expect(imports.prompt == nil, "the alert goes before the dialog comes")
        try await waitUntil { imports.prompt == .models }
        #expect(imports.problem == nil && started.files.isEmpty)
    }

    @Test func noModelReadySaysSoAndKeepsNothing() async throws {
        let (imports, _) = Self.make(ready: false)
        imports.add([Self.url("talk.mp3")])
        try await waitUntil { imports.prompt == .problem }
        #expect(imports.problem == FileImport.Problem(title: "No model can transcribe it right now",
                                                      message: "Needs key. Set one up in Models."))
        #expect(imports.pending.isEmpty)
        imports.problemDismissed()
        #expect(imports.prompt == nil && imports.problem == nil)
    }
}

// MARK: - Too long for Gemini

@Suite struct GeminiLengthTests {
    /// One Gemini request holds just under 1 h 48 min (16 kbps AAC in 19 MB of base64); Parakeet takes any length.
    @Test func oneRequestHoldsAboutAnHourAndThreeQuarters() {
        let limit = CloudAudio.maxChatSeconds()
        #expect(limit > 6_400 && limit < 6_500)
        #expect(CloudAudio.fitsChat(seconds: limit) && !CloudAudio.fitsChat(seconds: limit + 1))
        #expect(CloudAudio.fitsChat(seconds: 3_600))
    }

    /// A file past it isn't offered Gemini, Polish or Translate; Parakeet still is.
    @Test func aLongFileIsOfferedOnlyParakeet() {
        let choices = ImportChoices.make(main: .geminiFlash, seconds: 2 * 3_600) { _ in .ready }
        let gemini = choices.filter { $0.kind.engine.cloudAPI == .chatCompletions }
        #expect(gemini.map(\.kind) == [.transcription(.geminiFlash), .polish, .translation(polished: false)])
        #expect(gemini.allSatisfy { $0.blocker == .tooLongForGemini })
        #expect(gemini.first?.title == "Gemini 3.8 Flash · Too long, Parakeet takes any length")
        #expect(choices.filter(\.isEnabled).map(\.kind) == [.transcription(.parakeet), .transcription(.parakeetCloud)])
        let hour = ImportChoices.make(main: .geminiFlash, seconds: 3_600) { _ in .ready }
        #expect(hour.allSatisfy { $0.isEnabled })
    }

    /// A long row's Versions menu says the same of Gemini's actions.
    @Test func aLongRowsVersionsMenuPointsAtParakeet() {
        let entry = TranscriptEntry(text: "a podcast", engine: .parakeet, audioDuration: 3 * 3_600,
                                    voicedSeconds: 10_000, audioFileName: "x.m4a", importedFrom: "episode.mp3")
        let menu = VersionsMenu.make(for: entry, running: nil) { _ in .ready }
        #expect(menu.actions.first { $0.kind == .transcription(.parakeetCloud) }?.isEnabled == true)
        for kind: TranscriptVersionKind in [.transcription(.geminiFlash), .polish, .translation(polished: false)] {
            #expect(menu.actions.first { $0.kind == kind }?.blocker == .tooLongForGemini)
        }
    }
}
