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
        #expect(!file.isVideo && file.url == url)
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

    /// `seconds` of a 64 × 64 H.264 picture with no sound, in a new .mov.
    static func writeSilentVideo(seconds: Double, name: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pool = try #require(adaptor.pixelBufferPool)
        for frame in 0...Int(seconds * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            try #require(adaptor.append(try #require(buffer), withPresentationTime: CMTime(value: CMTimeValue(frame),
                                                                                         timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return url
    }

    /// `video`'s picture and `audio`'s sound in one new file `name` beside the video, as they are (passthrough).
    static func mux(video: URL, audio: URL, name: String, as type: AVFileType) async throws -> URL {
        let url = video.deletingLastPathComponent().appendingPathComponent(name)
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
        let picture = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
        let sound = try #require(try await audioAsset.loadTracks(withMediaType: .audio).first)
        let duration = min(try await videoAsset.load(.duration), try await audioAsset.load(.duration))
        let range = CMTimeRange(start: .zero, duration: duration)
        let composition = AVMutableComposition()
        try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
            .insertTimeRange(range, of: picture, at: .zero)
        try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            .insertTimeRange(range, of: sound, at: .zero)
        let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await export.export(to: url, as: type)
        return url
    }

    /// An Ogg Opus voice note (Telegram's, WhatsApp's) reads: AVFoundation's asset reader takes Ogg on macOS 26, and
    /// the audio file reader it falls back to does too.
    @Test func anOggOpusVoiceNoteReads() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voice note.ogg")
        try #require(Data(base64Encoded: Self.oggOpus, options: .ignoreUnknownCharacters)).write(to: url)
        let file = try await ImportedAudio.read(url)
        #expect(file.fileName == "voice note.ogg")
        #expect(abs(file.duration - 2) < 0.1)
        #expect(file.speech.voicedSeconds > 0.5 && !file.speech.isSilent)
        await #expect(throws: ImportedAudio.ReadError.tooLong) { try await ImportedAudio.read(url, limit: 1) }
        let fallback = try AudioFileLoader.load16kMono(url)
        #expect(abs(Double(fallback.count) / Recording.sampleRate - 2) < 0.1)
    }

    /// 2 s of `speechLike`'s bursts at 48 kHz as Ogg Opus, 12 kbps mono: 3.5 KB. Made with ffmpeg (`aevalsrc`,
    /// `libopus`), as `afconvert -f Oggf -d opus` fails on macOS 26 ("ExtAudioFileWrite failed ('pck?')").
    private static let oggOpus = """
        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
        """

    /// A video's sound is what's transcribed; a video with none has nothing to hear.
    @Test func aVideosSoundReads() async throws {
        let video = try await Self.writeSilentVideo(seconds: 3, name: "screen.mov")
        defer { try? FileManager.default.removeItem(at: video.deletingLastPathComponent()) }
        await #expect(throws: ImportedAudio.ReadError.noAudio) { try await ImportedAudio.read(video) }

        let audio = try Self.write(Self.speechLike(seconds: 3, rate: 48_000), rate: 48_000, channels: 2,
                                   format: kAudioFormatMPEG4AAC, name: "sound.m4a")
        defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
        let movie = try await Self.mux(video: video, audio: audio, name: "meeting.mp4", as: .mp4)
        let file = try await ImportedAudio.read(movie)
        #expect(file.fileName == "meeting.mp4")
        #expect(file.isVideo && file.url == movie, "Calls keeps a video's path for its picture")
        #expect(abs(file.duration - 3) < 0.15)
        #expect(file.speech.voicedSeconds > 1)
    }

    /// Past the longest it takes (three hours; less here), a file isn't read.
    @Test func aFileTooLongIsntRead() async throws {
        let url = try Self.write(Self.speechLike(seconds: 3, rate: 16_000), rate: 16_000, channels: 1,
                                 format: kAudioFormatLinearPCM, name: "lecture.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await #expect(throws: ImportedAudio.ReadError.tooLong) { try await ImportedAudio.read(url, limit: 2) }
        #expect(try await ImportedAudio.read(url, limit: 4).duration == 3)
        #expect(ImportedAudio.ReadError.tooLong.message == "It’s longer than 3 hours.")
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
        h.controller.transcribeOverride = { _, _ in throw AppError.engineFailed(.geminiFlash, "boom") }
        h.controller.transcribe(Self.file(), as: .transcription(.geminiFlash))
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
        h.controller.transcribe(Self.file(), as: .polish())
        let id = try #require(h.history.entries.first?.id)
        try await waitUntil { h.history.entry(id: id)?.status == .success }
        #expect(h.history.entry(id: id)?.currentKind == .polish())
    }

    /// Words, speed and dictations are the user's own talking: a file's transcript stays out of them.
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
        #expect(choices.suffix(TranscriptVersionKind.rewrites.count).map(\.kind) == TranscriptVersionKind.rewrites)
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
        let gemini = choices.filter { $0.kind.engine.isGemini }
        #expect(gemini.map(\.kind) == [.transcription(.geminiFlash), .polish(by: .geminiFlash),
                                       .translation(polished: false, by: .geminiFlash)])
        #expect(gemini.allSatisfy { $0.blocker == .tooLongForGemini })
        #expect(gemini.first?.title == "Gemini 3.8 Flash · Too long, Parakeet takes any length")
        #expect(choices.filter(\.isEnabled).map(\.kind) == [.transcription(.parakeet)])
        let hour = ImportChoices.make(main: .geminiFlash, seconds: 3_600) { _ in .ready }
        #expect(hour.allSatisfy { $0.isEnabled })
    }

    /// A long row's Versions menu says the same of Gemini's actions.
    @Test func aLongRowsVersionsMenuPointsAtParakeet() {
        let entry = TranscriptEntry(text: "a podcast", engine: .parakeet, audioDuration: 3 * 3_600,
                                    voicedSeconds: 10_000, audioFileName: "x.m4a", importedFrom: "episode.mp3")
        let menu = VersionsMenu.make(for: entry, running: nil) { _ in .ready }
        #expect(menu.actions.first { $0.kind == .transcription(.parakeet) } == nil, "it has Parakeet's already")
        for kind in [.transcription(.geminiFlash)] + TranscriptVersionKind.rewrites {
            #expect(menu.actions.first { $0.kind == kind }?.blocker == .tooLongForGemini)
        }
    }
}
