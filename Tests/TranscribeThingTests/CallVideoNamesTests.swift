import AVFoundation
import Foundation
import os
import Testing
@testable import TranscribeThing

// A call made from a video gets its "Speaker 2"s named from the picture (`CallVideoNames`): a silent small copy of the
// video (`CallVideoCopy`) goes up through the person's endpoint's Files API with the transcript, and the model's sure
// answers become renames. No real request: the endpoint is `StubURLProtocol`, or the step's request is a fake.

private func transcript(_ speakers: [String]) -> CallTranscript {
    CallTranscript(segments: speakers.enumerated().map { index, speaker in
        CallTranscript.Segment(start: Double(index * 5), end: Double(index * 5 + 4), side: .remote, speaker: speaker,
                               text: "Фраза \(index).")
    })
}

private func sure(_ name: String?) -> CallVideoNames.Guess { CallVideoNames.Guess(name: name, isSure: true) }

@Suite struct CallVideoNamesAnswerTests {
    /// The answer as asked for: a JSON object by speaker, each with a name (or null) and how sure.
    @Test func aPlainAnswerReads() throws {
        let answer = #"{"Speaker 1": {"name": "Ангелина Д.", "confidence": "high"}, "Speaker 4": {"name": "Pablo", "confidence": "low"}, "Speaker 2": {"name": null, "confidence": "low"}}"#
        let guesses = try #require(CallVideoNames.parse(answer))
        #expect(guesses == [
            "Speaker 1": .init(name: "Ангелина Д.", isSure: true),
            "Speaker 4": .init(name: "Pablo", isSure: false),
            "Speaker 2": .init(name: nil, isSure: false),
        ])
    }

    /// What models put around it: a code fence, a sentence before and after, a brace inside a name, a bare name.
    @Test func whatsAroundTheObjectIsLeftOut() throws {
        let answer = """
            Here is who is who {as asked}:
            ```json
            {"Speaker 1": {"name": "Ann {PM}", "confidence": "HIGH"},
             "Speaker 2": "Bob",
             "Speaker 3": {"name": "  ", "confidence": "high"}}
            ```
            Hope this helps.
            """
        let guesses = try #require(CallVideoNames.parse(answer))
        #expect(guesses["Speaker 1"] == .init(name: "Ann {PM}", isSure: true))
        #expect(guesses["Speaker 2"] == .init(name: "Bob", isSure: false), "a bare name: not said to be sure")
        #expect(guesses["Speaker 3"] == .init(name: nil, isSure: true))
    }

    @Test func anAnswerWithoutAnObjectIsNone() {
        #expect(CallVideoNames.parse("I can't tell who is who.") == nil)
        #expect(CallVideoNames.parse("{\"Speaker 1\": {\"name\": \"Ann\"") == nil, "cut off")
        #expect(CallVideoNames.parse("{}") == [:])
    }

    /// The prompt says what was measured to work, for any call app, with the transcript at its end as the speakers
    /// were named; it asks only who is who.
    @Test func thePromptAsksOnlyWhoIsWho() {
        let prompt = CallVideoNames.prompt(transcript(["Speaker 1", "Sam"]))
        #expect(prompt.hasPrefix("You get the video of a call (a screen recording without sound: the call or meeting "
                                 + "app, if one is on screen, shows each participant's tile with their name"))
        #expect(prompt.contains(#"{"<speaker as in the transcript>": {"name": "<the name on their tile>", "confidence": "high" | "low"}}"#))
        #expect(prompt.contains("give \"name\": null. Don't change, add or judge anything else."))
        #expect(prompt.hasSuffix("Transcript:\n[00:00-00:04] Speaker 1: Фраза 0.\n[00:05-00:09] Sam: Фраза 1."))
        #expect(!prompt.contains("Discord") && !prompt.contains("—"))
    }
}

@Suite struct CallVideoNamesRulesTests {
    private let speakers = transcript(["Sam", "Speaker 1", "Олег", "Speaker 2", "Participant 3", "Nearby 1"])

    /// Only a speaker the audio couldn't name: one it named from the conversation keeps that name, and so does
    /// someone in the room.
    @Test func onlyGenericSpeakersAreRenamed() {
        let renames = CallVideoNames.renames([
            "Speaker 1": sure("Ангелина Д."), "Олег": sure("Oleg Ivanov"), "Participant 3": sure("Pablo"),
            "Nearby 1": sure("Kate"),
        ], transcript: speakers, speakerNames: [:], me: "Sam")
        #expect(renames == ["Speaker 1": "Ангелина Д.", "Participant 3": "Pablo"])
    }

    /// Never the person: not their speaker (their own handle on a tile is no name to give them), and no one else gets
    /// their name.
    @Test func neverThePerson() {
        let mine = transcript(["Матвей", "Speaker 1", "Speaker 2"])
        let renames = CallVideoNames.renames([
            "Матвей": sure("package.json"), "Speaker 1": sure("матвей"), "Speaker 2": sure("Me"),
        ], transcript: mine, speakerNames: [:], me: "Матвей")
        #expect(renames.isEmpty)
        #expect(CallVideoNames.renames(["Me": sure("Sam")], transcript: transcript(["Me", "Speaker 1"]),
                                       speakerNames: [:], me: "Me").isEmpty)
    }

    /// Never two speakers to one name: two given the same, neither; one given a name another already has, not it.
    @Test func neverTwoSpeakersToOneName() {
        let renames = CallVideoNames.renames([
            "Speaker 1": sure("Pablo"), "Speaker 2": sure("pablo"), "Participant 3": sure("Олег"),
        ], transcript: speakers, speakerNames: [:], me: "Sam")
        #expect(renames.isEmpty)
    }

    /// A name the person gave stays, and no one else takes it.
    @Test func theirRenamesWin() {
        let renames = CallVideoNames.renames([
            "Speaker 1": sure("Ann"), "Speaker 2": sure("Аня"), "Participant 3": sure("Pablo"),
        ], transcript: speakers, speakerNames: ["Speaker 1": "Аня"], me: "Sam")
        #expect(renames == ["Participant 3": "Pablo"])
    }

    /// Unsure, no name, a generic name, something too long to be a name: nothing.
    @Test func onlySureNamesCount() {
        let renames = CallVideoNames.renames([
            "Speaker 1": .init(name: "Ann", isSure: false), "Speaker 2": sure(nil), "Participant 3": sure("Speaker 7"),
        ], transcript: speakers, speakerNames: [:], me: "Sam")
        #expect(renames.isEmpty)
        let long = String(repeating: "a", count: CallVideoNames.maxNameLength + 1)
        #expect(CallVideoNames.renames(["Speaker 1": sure(long)], transcript: speakers, speakerNames: [:],
                                       me: "Sam").isEmpty)
    }

    /// The model's keys matched to the transcript's speakers whatever their case.
    @Test func keysMatchWhateverTheirCase() {
        #expect(CallVideoNames.renames(["speaker 1": sure("Ann")], transcript: speakers, speakerNames: [:], me: "Sam")
                == ["Speaker 1": "Ann"])
    }

    @Test func genericNames() {
        for name in ["Speaker 1", "speaker 12", "Participant 3", "Participant2"] { #expect(CallVideoNames.isGeneric(name)) }
        for name in ["Sam", "Nearby 1", "Speaker", "Speaker One", "Олег 2"] { #expect(!CallVideoNames.isGeneric(name)) }
    }
}

// MARK: - The endpoint

@MainActor @Suite(.serialized) struct CallVideoNamesEndpointTests {
    /// A file of `bytes` bytes, 0, 1, 2…
    private static func file(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).mp4")
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    private static func started(_ host: String) -> StubURLProtocol.Reply {
        StubURLProtocol.Reply(headers: ["x-goog-upload-url": "https://\(host)/upload/v1beta/files?upload_id=u1",
                                        "X-Goog-Upload-Status": "active"])
    }

    private static let uploaded = StubURLProtocol.Reply(
        headers: ["Content-Type": "application/json"],
        body: #"{"file":{"name":"files/abc","uri":"https://files.example/v1beta/files/abc","mimeType":"video/mp4","state":"ACTIVE"}}"#)

    /// The upload as Gemini's Files API takes it: a start at the endpoint's root that says the size and type, then the
    /// file in pieces, each at its offset, the last one finishing it; the key with every request to the endpoint.
    @Test func theVideoGoesUpInPieces() async throws {
        // The start's answer names an upload address on the endpoint's own host.
        let (stub, stubHost) = ProxyFixture.client([])
        StubURLProtocol.registry.enqueue([Self.started(stubHost), .init(), .init(), Self.uploaded], host: stubHost)
        let video = try Self.file(bytes: 10)
        defer { try? FileManager.default.removeItem(at: video) }

        let file = try await stub.uploadVideo(video, displayName: "call-video.mp4", apiKey: ProxyFixture.key,
                                              chunkBytes: 4)
        #expect(file == OpenRouterClient.UploadedFile(uri: "https://files.example/v1beta/files/abc", bytes: 10))

        let requests = StubURLProtocol.registry.requests(for: stubHost)
        let bodies = StubURLProtocol.registry.bodies(for: stubHost)
        try #require(requests.count == 4)
        let start = requests[0]
        #expect(start.url?.absoluteString == "https://\(stubHost)/upload/v1beta/files", "the root, not /api/v1")
        #expect(start.httpMethod == "POST")
        #expect(start.value(forHTTPHeaderField: "x-goog-api-key") == ProxyFixture.key)
        #expect(start.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(start.value(forHTTPHeaderField: "X-Goog-Upload-Protocol") == "resumable")
        #expect(start.value(forHTTPHeaderField: "X-Goog-Upload-Command") == "start")
        #expect(start.value(forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length") == "10")
        #expect(start.value(forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type") == "video/mp4")
        #expect(ProxyFixture.json(bodies[0])["file"] as? [String: String] == ["display_name": "call-video.mp4"])

        let pieces = Array(requests.dropFirst())
        #expect(pieces.map { $0.url?.absoluteString } == Array(repeating:
            "https://\(stubHost)/upload/v1beta/files?upload_id=u1", count: 3))
        #expect(pieces.map { $0.value(forHTTPHeaderField: "X-Goog-Upload-Offset") } == ["0", "4", "8"])
        #expect(pieces.map { $0.value(forHTTPHeaderField: "X-Goog-Upload-Command") }
                == ["upload", "upload", "upload, finalize"])
        #expect(pieces.allSatisfy { $0.value(forHTTPHeaderField: "x-goog-api-key") == ProxyFixture.key })
        #expect(bodies.dropFirst().reduce(Data(), +) == (try Data(contentsOf: video)))
    }

    /// An upload address on another host gets the bytes, never the key.
    @Test func theKeyStaysWithTheEndpoint() async throws {
        let (client, host) = ProxyFixture.client([])
        let (_, elsewhere) = ProxyFixture.client([.init(), Self.uploaded])
        StubURLProtocol.registry.enqueue([Self.started(elsewhere)], host: host)
        let video = try Self.file(bytes: 6)
        defer { try? FileManager.default.removeItem(at: video) }

        _ = try await client.uploadVideo(video, displayName: "v.mp4", apiKey: ProxyFixture.key, chunkBytes: 4)
        let pieces = StubURLProtocol.registry.requests(for: elsewhere)
        #expect(pieces.count == 2)
        #expect(pieces.allSatisfy { $0.value(forHTTPHeaderField: "x-goog-api-key") == nil })
    }

    /// The endpoint's no is its failure as a request's would be.
    @Test func aRefusedUploadIsTheEndpointsFailure() async throws {
        let (client, _) = ProxyFixture.client([ProxyFixture.error(401, "Invalid API key", code: "401")])
        let video = try Self.file(bytes: 6)
        defer { try? FileManager.default.removeItem(at: video) }
        await #expect(throws: AppError.vertexProxy(.keyRejected("Invalid API key"))) {
            try await client.uploadVideo(video, displayName: "v.mp4", apiKey: ProxyFixture.key)
        }
    }

    @Test(arguments: [
        ("https://h.example/api/v1", "https://h.example"),
        ("https://h.example/v1", "https://h.example"),
        ("https://h.example/proxy/api/v1", "https://h.example/proxy"),
    ])
    func theFilesAPIIsAtTheRoot(_ base: String, _ root: String) {
        #expect(OpenRouterClient.filesRoot(apiBase: URL(string: base)!)?.absoluteString == root)
    }

    /// The step's live request through the endpoint: the upload, then one chat request with the video by its file's
    /// uri (looked at agentically) and the prompt, to the Calls model at its level; the answer and its cost back.
    @Test func theStepUploadsThenAsks() async throws {
        let settings = AppSettings.inMemory()
        settings.callEngine = .geminiArgon
        let (proxy, host) = ProxyFixture.proxy(settings: settings)
        let answer = #"{"Speaker 1": {"name": "Pablo", "confidence": "high"}}"#
        StubURLProtocol.registry.enqueue([
            Self.started(host), Self.uploaded,
            .stream(SSE.answer(answer, reasoning: "Looking at the tiles.", id: "chatcmpl-v1",
                               usage: #"{"prompt_tokens":9000,"completion_tokens":300,"total_tokens":9300,"cost":0.034}"#)),
        ], host: host)
        let video = try Self.file(bytes: 1000)
        defer { try? FileManager.default.removeItem(at: video) }

        let names = CallTranscriber.endpointVideoNames(proxy: proxy, model: { settings.callModel })
        #expect(names.isAvailable())
        let result = try await names.send(video, "Who is who?")
        #expect(result.text == answer && result.costUSD == 0.034)

        let requests = StubURLProtocol.registry.requests(for: host)
        try #require(requests.count == 3)
        #expect(requests[2].url?.absoluteString == "https://\(host)/api/v1/chat/completions")
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer \(ProxyFixture.key)")
        let body = ProxyFixture.json(StubURLProtocol.registry.bodies(for: host)[2])
        #expect(body["model"] as? String == "google/gemini-4-argon")
        #expect(body["provider"] == nil && body["stream"] as? Bool == true)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1 && messages[0]["role"] as? String == "user")
        let parts = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(parts.count == 2)
        #expect(parts[0]["type"] as? String == "video_url")
        #expect(parts[0]["video_url"] as? [String: String]
                == ["url": "https://files.example/v1beta/files/abc", "processing": "agentic"])
        #expect(parts[1]["type"] as? String == "text" && parts[1]["text"] as? String == "Who is who?")
    }

    /// OpenRouter picked: the step doesn't run, and nothing goes anywhere.
    @Test func throughOpenRouterTheStepDoesntRun() {
        let (proxy, host) = ProxyFixture.proxy(enabled: false)
        #expect(!CallTranscriber.endpointVideoNames(proxy: proxy).isAvailable())
        #expect(StubURLProtocol.registry.requests(for: host).isEmpty)
    }
}

// MARK: - The video

@Suite(.serialized) struct CallVideoCopyTests {
    /// `seconds` of a `width` × `height` picture at `fps`, each frame a different grey, with sound.
    static func movie(seconds: Double, width: Int, height: Int, fps: Int32 = 30) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("video-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let picture = dir.appendingPathComponent("picture.mov")
        let writer = try AVAssetWriter(outputURL: picture, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pool = try #require(adaptor.pixelBufferPool)
        for frame in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            let buffer = try #require(made)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 7 % 255),
                   CVPixelBufferGetBytesPerRow(buffer) * height)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try #require(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        let sound = try ImportedAudioTests.write(ImportedAudioTests.speechLike(seconds: seconds, rate: 48_000),
                                                 rate: 48_000, channels: 1, format: kAudioFormatMPEG4AAC,
                                                 name: "sound.m4a")
        defer { try? FileManager.default.removeItem(at: sound.deletingLastPathComponent()) }
        return try await ImportedAudioTests.mux(video: picture, audio: sound, name: "call.mp4", as: .mp4)
    }

    /// A 1280 × 720 call at 30 frames a second with sound becomes 960 × 540 at 5 a second, H.264, with no sound, as
    /// long as it was.
    @Test func theCopyIsSmallSilentAndSlow() async throws {
        let source = try await Self.movie(seconds: 2, width: 1280, height: 720)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        #expect(try await !AVURLAsset(url: source).loadTracks(withMediaType: .audio).isEmpty, "the source has sound")
        let copy = source.deletingLastPathComponent().appendingPathComponent("copy.mp4")

        try await CallVideoCopy.make(from: source, to: copy)
        let asset = AVURLAsset(url: copy)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 960, height: 540))
        let formats = try await track.load(.formatDescriptions)
        #expect(formats.first.map(CMFormatDescriptionGetMediaSubType) == kCMVideoCodecType_H264)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2) < 0.3)
        // Frames counted as read back.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
        }
        #expect((9...11).contains(times.count), "5 a second, not 30: \(times.count)")
        #expect(times.first.map { abs($0) < 0.01 } == true && times == times.sorted(), "from 0, in order: \(times)")
    }

    /// A small picture isn't made larger; sizes stay even.
    @Test func sizes() {
        #expect(CallVideoCopy.outputSize(for: CGSize(width: 1920, height: 1080)) == CGSize(width: 960, height: 540))
        #expect(CallVideoCopy.outputSize(for: CGSize(width: 640, height: 480)) == CGSize(width: 640, height: 480))
        #expect(CallVideoCopy.outputSize(for: CGSize(width: 2560, height: 1601)) == CGSize(width: 960, height: 600))
        #expect(CallVideoCopy.outputSize(for: .zero) == .zero)
    }

    @Test func aMissingFileOrOneWithoutPictureIsSaidSo() async throws {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("gone-\(UUID().uuidString).mp4")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("copy-\(UUID().uuidString).mp4")
        await #expect(throws: CallVideoCopy.Failure.unreadable) { try await CallVideoCopy.make(from: gone, to: copy) }
        let sound = try ImportedAudioTests.write(ImportedAudioTests.speechLike(seconds: 1, rate: 48_000), rate: 48_000,
                                                 channels: 1, format: kAudioFormatMPEG4AAC, name: "sound.m4a")
        defer { try? FileManager.default.removeItem(at: sound.deletingLastPathComponent()) }
        await #expect(throws: CallVideoCopy.Failure.noPicture) { try await CallVideoCopy.make(from: sound, to: copy) }
    }
}

// MARK: - In the transcriber

@MainActor @Suite(.serialized) struct CallVideoNamesFlowTests {
    /// What the fake step was sent: the copy's size and tracks as it was when sent, and the prompt.
    private final class Sent: Sendable {
        let prompts = OSAllocatedUnfairLock(initialState: [String]())
        let copies = OSAllocatedUnfairLock(initialState: [URL]())
        let hadSound = OSAllocatedUnfairLock(initialState: [Bool]())
    }

    private nonisolated static let transcriptAnswer = """
        [00:00-00:01] Speaker 1: Всем привет.
        [00:01-00:02] Олег: Привет.
        [00:02-00:03] Speaker 2: Начнём.
        """

    /// A store, a transcriber whose transcript requests answer `transcriptAnswer`, its names step `send`, and a call
    /// made from `file` as a video (or not).
    private static func setUp(available: Bool = true, file: URL?, isVideo: Bool = true, waits: Bool = true,
                              send: @escaping CallTranscriber.SendVideo)
        async throws -> (CallStore, CallTranscriber, UUID) {
        let store = CallStore(paths: .temporary(), settings: .inMemory())
        store.load()
        let transcriber = CallTranscriber(store: store, send: { _, _, _, _ in
            CloudResult(text: transcriptAnswer, costUSD: 0.01)
        }, videoNames: CallTranscriber.VideoNames(isAvailable: { available }, send: send))
        transcriber.userName = { "Sam" }
        transcriber.log = DiagnosticLog()
        let samples = ImportedAudioTests.speechLike(seconds: 3, rate: Recording.sampleRate)
        let audio = ImportedAudio(fileName: file?.lastPathComponent ?? "call.mp4", samples: samples,
                                  speech: SpeechAnalyzer.stats(for: samples), url: file, isVideo: isVideo)
        let record = try #require(await transcriber.importFile(audio))
        if waits { await transcriber.waitUntilIdle() }
        return (store, transcriber, record.id)
    }

    /// Done transcribing (and summing up), the step sends the copy and the transcript; the sure names go on the
    /// speakers still unnamed, as renames; what it cost is added; its answer is kept with the others; the copy is gone.
    @Test func aVideosSpeakersGetTheirNames() async throws {
        let source = try await CallVideoCopyTests.movie(seconds: 1, width: 320, height: 240)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let sent = Sent()
        let answer = """
            ```json
            {"Speaker 1": {"name": "Ангелина Д.", "confidence": "high"}, "Олег": {"name": "Oleg I.", "confidence": "high"},
             "Speaker 2": {"name": "Pablo", "confidence": "low"}}
            ```
            """
        let (store, _, id) = try await Self.setUp(file: source) { video, prompt in
            sent.prompts.withLock { $0.append(prompt) }
            sent.copies.withLock { $0.append(video) }
            let sound = try await !AVURLAsset(url: video).loadTracks(withMediaType: .audio).isEmpty
            sent.hadSound.withLock { $0.append(sound) }
            return CloudResult(text: answer, costUSD: 0.05)
        }
        let call = try #require(store.call(id: id))
        #expect(call.status == .done)
        #expect(call.speakerNames == ["Speaker 1": "Ангелина Д."])
        #expect(call.name(of: "Speaker 1") == "Ангелина Д." && call.name(of: "Олег") == "Олег")
        #expect(abs((call.costUSD ?? 0) - 0.06) < 1e-9)
        #expect(store.namingSpeakers.isEmpty)
        let prompt = try #require(sent.prompts.withLock { $0 }.first)
        #expect(prompt.contains("[00:00-00:01] Speaker 1: Всем привет."))
        #expect(sent.hadSound.withLock { $0 } == [false])
        let copy = try #require(sent.copies.withLock { $0 }.first)
        #expect(!FileManager.default.fileExists(atPath: copy.path), "the copy is deleted")
        let kept = store.answersFolder(for: id).appendingPathComponent("names.txt")
        #expect(try String(contentsOf: kept, encoding: .utf8) == answer)
        // The words are the audio's, untouched.
        #expect(call.transcript?.segments.map(\.text) == ["Всем привет.", "Привет.", "Начнём."])
    }

    /// Calls through OpenRouter: no step.
    @Test func throughOpenRouterItIsSkipped() async throws {
        let source = try await CallVideoCopyTests.movie(seconds: 1, width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let (store, _, id) = try await Self.setUp(available: false, file: source) { _, _ in
            calls.withLock { $0 += 1 }
            return CloudResult(text: "{}")
        }
        #expect(calls.withLock { $0 } == 0)
        #expect(store.call(id: id)?.status == .done && store.call(id: id)?.speakerNames.isEmpty == true)
    }

    /// A file with no picture, or a video that's no longer where it was: no step.
    @Test(arguments: [false, true])
    func anAudioFileOrAMissingVideoIsSkipped(_ missing: Bool) async throws {
        let source = try await CallVideoCopyTests.movie(seconds: 1, width: 64, height: 64)
        try FileManager.default.removeItem(at: source.deletingLastPathComponent())
        let audioOnly = missing ? nil : try ImportedAudioTests.write(
            ImportedAudioTests.speechLike(seconds: 1, rate: 48_000), rate: 48_000, channels: 1,
            format: kAudioFormatMPEG4AAC, name: "memo.m4a")
        defer { if let audioOnly { try? FileManager.default.removeItem(at: audioOnly.deletingLastPathComponent()) } }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let (store, _, id) = try await Self.setUp(file: audioOnly ?? source, isVideo: missing) { _, _ in
            calls.withLock { $0 += 1 }
            return CloudResult(text: "{}")
        }
        #expect(calls.withLock { $0 } == 0)
        #expect(store.call(id: id)?.status == .done)
    }

    /// The step failing leaves the call done as it was: no names, no cost added.
    @Test func aFailureNeverFailsTheCall() async throws {
        let source = try await CallVideoCopyTests.movie(seconds: 1, width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let (store, _, id) = try await Self.setUp(file: source) { _, _ in
            throw AppError.vertexProxy(.tooLarge)
        }
        let call = try #require(store.call(id: id))
        #expect(call.status == .done && call.error == nil && call.speakerNames.isEmpty && call.costUSD == 0.01)
        #expect(store.namingSpeakers.isEmpty)
    }

    /// A name the person gives while the step runs wins over the step's.
    @Test func aRenameMeanwhileWins() async throws {
        let source = try await CallVideoCopyTests.movie(seconds: 1, width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let released = OSAllocatedUnfairLock(initialState: false)
        let (store, transcriber, id) = try await Self.setUp(file: source, waits: false) { _, _ in
            while !released.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
            return CloudResult(text: #"{"Speaker 1": {"name": "Ann", "confidence": "high"}, "Speaker 2": {"name": "Bob", "confidence": "high"}}"#)
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while !store.namingSpeakers.contains(id), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(transcriber.isNamingSpeakers(id))
        store.rename(speaker: "Speaker 1", to: "Аня", in: id)
        released.withLock { $0 = true }
        await transcriber.waitUntilIdle()
        #expect(store.call(id: id)?.speakerNames == ["Speaker 1": "Аня", "Speaker 2": "Bob"])
    }

    /// Transcribe Again stops a step still running: its names were for the old transcript's speakers.
    @Test func transcribingAgainStopsTheStep() async throws {
        let source = try await CallVideoCopyTests.movie(seconds: 1, width: 64, height: 64)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let (store, transcriber, id) = try await Self.setUp(file: source, waits: false) { _, _ in
            let number = asked.withLock { $0 += 1; return $0 }
            if number == 1 { try await Task.sleep(for: .seconds(30)) }
            return CloudResult(text: #"{"Speaker 1": {"name": "Ann", "confidence": "high"}}"#)
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while asked.withLock({ $0 }) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        transcriber.retranscribe(id)
        #expect(!store.namingSpeakers.contains(id))
        await transcriber.waitUntilIdle()
        #expect(asked.withLock { $0 } == 2, "the new transcript gets a step of its own")
        #expect(store.call(id: id)?.speakerNames == ["Speaker 1": "Ann"])
    }
}
