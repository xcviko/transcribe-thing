import AppKit
import Foundation
import Testing
@testable import TranscribeThing

// Parakeet through OpenRouter’s speech-to-text endpoint: engine metadata, wire format, a request per 5 minutes,
// provider lookup, history and notices.

private let rate = 16_000

/// `block` repeated to fill `seconds` (a memcpy per block: synthetic minutes of audio stay cheap to build).
private func tiled(_ block: [Float], seconds: Double) -> [Float] {
    let count = Int(seconds * Double(rate))
    var out: [Float] = []
    out.reserveCapacity(count)
    while out.count < count { out.append(contentsOf: block.prefix(count - out.count)) }
    return out
}

/// One second of 220 Hz: a whole number of cycles, so repeats join without a click.
private let toneSecond: [Float] = (0..<rate).map { Float(sin(2 * .pi * 220 * Double($0) / Double(rate))) }

private func tone(_ seconds: Double, amplitude: Float = 0.2) -> [Float] {
    tiled(toneSecond.map { $0 * amplitude }, seconds: seconds)
}

private func silence(_ seconds: Double) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * Double(rate)))
}

/// Three seconds of room noise at about −58 dBFS (deterministic xorshift).
private let noiseBlock: [Float] = {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    let amplitude = Float(0.001_26 * 3.0.squareRoot())
    return (0..<(3 * rate)).map { _ in
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(Double(state % 2_000_001) / 1_000_000 - 1) * amplitude
    }
}()

private func roomNoise(_ seconds: Double) -> [Float] { tiled(noiseBlock, seconds: seconds) }

/// Three seconds of speech-like audio: 0.2 s syllables (a harmonic stack under a raised-cosine envelope) with
/// 0.1 s pauses, over room noise. A steady tone would read as noise to `SpeechAnalyzer`.
private let babbleBlock: [Float] = {
    let syllable = Int(0.2 * Double(rate)), period = Int(0.3 * Double(rate))
    return noiseBlock.indices.map { index in
        let i = index % period
        guard i < syllable else { return noiseBlock[index] }
        let t = Double(i) / Double(rate)
        let envelope = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(syllable))
        let voice = sin(2 * .pi * 150 * t) + 0.5 * sin(4 * .pi * 150 * t) + 0.25 * sin(6 * .pi * 150 * t)
        return noiseBlock[index] + Float(0.15 * envelope * voice)
    }
}()

private func babble(_ seconds: Double) -> [Float] { tiled(babbleBlock, seconds: seconds) }

private func json(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// The file a transcription request body carries: its format, and how many samples it reads back as.
private func upload(inRequestBody body: Data) -> (format: String, samples: Int)? {
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let audio = object["input_audio"] as? [String: Any], let format = audio["format"] as? String,
          let base64 = audio["data"] as? String, let data = Data(base64Encoded: base64) else { return nil }
    if format == "wav" { return WAVEncoder.decode(data).map { (format, $0.count) } }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).\(format)")
    defer { try? FileManager.default.removeItem(at: url) }
    guard (try? data.write(to: url)) != nil, let samples = try? AudioFileLoader.load16kMono(url) else { return nil }
    return (format, samples.count)
}

private func uploads(_ bodies: [Data]) async -> [(format: String, samples: Int)] {
    await offMain { bodies.map { upload(inRequestBody: $0) ?? ("?", 0) } }
}

private let unsupportedFormat = StubURLProtocol.Reply(
    status: 400, body: #"{"error":{"code":400,"message":"Unsupported audio format: flac"}}"#)

/// Heavy synthetic audio work stays off the main actor, where other suites' timers must keep firing on time.
private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached(priority: .userInitiated) { work() }.value
}

private func speechReply(_ text: String, cost: Double? = nil, generation: String? = nil,
                         provider: String? = nil) -> StubURLProtocol.Reply {
    var headers: [String: String] = [:]
    if let generation { headers["X-Generation-Id"] = generation }
    if let provider { headers["X-Provider-Name"] = provider }
    let usage = cost.map { #","usage":{"seconds":12.5,"cost":\#($0)}"# } ?? ""
    return StubURLProtocol.Reply(headers: headers, body: #"{"text":"\#(text)"\#(usage)}"#)
}

private func generationReply(_ provider: String?) -> StubURLProtocol.Reply {
    let name = provider.map { "\"\($0)\"" } ?? "null"
    return StubURLProtocol.Reply(body: #"{"data":{"id":"gen-1","api_type":"stt","model":"nvidia/parakeet-tdt-0.6b-v3","provider_name":\#(name),"total_cost":0.0001,"created_at":"2026-09-27T10:00:00Z"}}"#)
}

// MARK: - Engine metadata

@Suite struct CloudEngineFactsTests {
    @Test func rawValuesAreStableAndOrderIsLocalThenCloudSpeechThenGemini() {
        #expect(EngineID.allCases.map(\.rawValue) == ["parakeet", "parakeetCloud", "geminiFlash", "geminiPro"],
                "Gemini 3.1 Pro stays readable, retired")
        #expect(EngineID.offered == [.parakeet, .parakeetCloud, .geminiFlash])
        #expect(EngineID.allCases.filter(\.isRetired) == [.geminiPro])
        #expect(EngineID.localEngines == [.parakeet])
        #expect(EngineID.cloudEngines == [.parakeetCloud, .geminiFlash])
        #expect(EngineID.cloudTranscriptionEngines == [.parakeetCloud])
        #expect(EngineID.cloudChatEngines == [.geminiFlash])
    }

    @Test func namesTellLocalAndCloudApart() {
        #expect(Set(EngineID.allCases.map(\.displayName)).count == EngineID.allCases.count)
        #expect(Set(EngineID.allCases.map(\.shortName)).count == EngineID.allCases.count)
        #expect(EngineID.parakeetCloud.shortName == "Parakeet v3 · Cloud")
        #expect(EngineID.parakeetCloud.modelName == EngineID.parakeet.displayName)
    }

    @Test func cloudSpeechFacts() {
        #expect(EngineID.parakeetCloud.openRouterModelID == "nvidia/parakeet-tdt-0.6b-v3")
        #expect(EngineID.parakeetCloud.provider == "Together")
        #expect(EngineID.geminiFlash.provider == "Google AI Studio")
        #expect(EngineID.parakeet.provider == nil)
        for engine in EngineID.cloudTranscriptionEngines {
            #expect(engine.isCloud && !engine.isLocal)
            #expect(engine.cloudAPI == .transcriptions)
            #expect(engine.badges == ["Cloud"])
            #expect(engine.approxDownloadBytes == nil)
            #expect(engine.cloudTimeout == 180, "per segment of at most 5 minutes")
            #expect(engine.localCounterpart?.cloudCounterpart == engine)
            #expect(OpenRouterClient.engine(forModel: engine.openRouterModelID!) == engine)
        }
        #expect(EngineID.geminiFlash.cloudAPI == .chatCompletions)
        #expect(EngineID.parakeet.cloudAPI == nil)
    }

    @Test(arguments: EngineID.allCases)
    @MainActor func symbolsExist(_ engine: EngineID) {
        #expect(NSImage(systemSymbolName: engine.symbolName, accessibilityDescription: nil) != nil)
    }

    /// Gemini's answer streams, so its timeout is a stall one, the same for any length of audio: two minutes without a
    /// byte (OpenRouter's comments keep a busy model's connection alive).
    @Test func geminisTimeoutIsAStallTimeout() {
        #expect(EngineID.geminiFlash.cloudTimeout == 120)
        #expect(EngineID.parakeetCloud.cloudTimeout == 180)
        #expect(EngineID.parakeet.cloudTimeout == 0)
    }

    @Test func cloudSessionTimeouts() {
        let config = URLSession.openRouterCloud.configuration
        #expect(config.timeoutIntervalForRequest == 180)
        #expect(config.timeoutIntervalForResource == 10_800, "a whole request, however long its answer streams")
    }
}

// MARK: - Request and response

@Suite struct OpenRouterSpeechWireTests {
    @Test(arguments: UploadFormat.allCases)
    func requestCarriesModelAndAudioOnly(_ format: UploadFormat) throws {
        let body = try json(OpenRouterSpeechRequest.audio(model: "nvidia/parakeet-tdt-0.6b-v3",
                                                          audioBase64: "ZkxhQw+/==", format: format.rawValue).encoded())
        #expect(Set(body.keys) == ["model", "input_audio"], "no language, provider routing, temperature or format")
        #expect(body["model"] as? String == "nvidia/parakeet-tdt-0.6b-v3")
        let audio = try #require(body["input_audio"] as? [String: Any])
        #expect(audio["data"] as? String == "ZkxhQw+/==")
        #expect(audio["format"] as? String == format.rawValue)
        #expect(audio.count == 2)
    }

    @Test func base64SlashesAreNotEscaped() throws {
        let raw = String(decoding: try OpenRouterSpeechRequest.audio(model: "nvidia/parakeet-tdt-0.6b-v3",
                                                                     audioBase64: "ab/cd+/ef==", format: "flac").encoded(),
                         as: UTF8.self)
        #expect(raw.contains("ab/cd+/ef==") && raw.contains("nvidia/parakeet-tdt-0.6b-v3") && !raw.contains("\\/"))
    }

    /// However OpenRouter or the provider words it, a 415, or a 400, 422, 500 or 502 that refuses the file's format,
    /// type or decoding, refuses the upload's format; any other failure is what it always was.
    @Test func formatRefusals() {
        let refusals: [(Int, String)] = [
            (415, ""),
            (415, #"{"error":{"code":415,"message":"Unsupported Media Type"}}"#),
            (400, #"{"error":{"code":400,"message":"Unsupported audio format: flac"}}"#),
            (400, #"{"error":{"code":400,"message":"Invalid file type. Supported types: wav, mp3."}}"#),
            (422, #"{"error":{"code":422,"message":"input_audio.format 'flac' is not supported by this model"}}"#),
            (400, #"{"error":{"code":400,"message":"Provider returned error","metadata":{"raw":"{\"error\":{\"message\":\"Could not decode the audio\"}}","provider_name":"Together"}}}"#),
            (400, "codec not supported"),
            (400, #"{"error":{"code":400,"message":"FLAC isn’t supported: unsupported file extension"}}"#),
            (400, #"{"error":{"code":400,"message":"Provider returned error","metadata":{"raw":"Error:\nUnsupported audio: flac"}}}"#),
            (500, #"{"error":{"code":500,"message":"Provider returned error","metadata":{"error_type":"unmapped","raw":"Unsupported audio format: flac"}}}"#),
            (502, #"{"error":{"code":502,"message":"Provider could not decode the audio format"}}"#),
        ]
        for (status, body) in refusals {
            #expect(OpenRouterErrorMapper.refusesAudioFormat(status: status, body: Data(body.utf8)), "\(status) \(body)")
        }
        let others: [(Int, String)] = [
            (400, #"{"error":{"code":400,"message":"Invalid audio"}}"#),
            (400, #"{"error":{"code":400,"message":"Invalid request parameters"}}"#),
            (400, #"{"error":{"code":400,"message":"Request payload too large"}}"#),
            // "format" inside another word, an identifier or an encoding names no file format; "flac" and "invalid"
            // turn up in errors about anything.
            (400, #"{"error":{"code":400,"message":"Invalid request: some required information is missing"}}"#),
            (400, #"{"error":{"code":400,"message":"Invalid value for response_format"}}"#),
            (400, #"{"error":{"code":400,"message":"Invalid base64 encoding in input_audio.data"}}"#),
            (400, #"{"error":{"code":400,"message":"Provider returned error","metadata":{"raw":"{\"error\":{\"message\":\"Parameter 'language' is not allowed for audio.flac\",\"type\":\"invalid_request_error\"}}","provider_name":"Together"}}}"#),
            (413, #"{"error":{"code":413,"message":"Unsupported format: too large"}}"#),
            (500, #"{"error":{"code":500,"message":"Internal Server Error","metadata":{"error_type":"unmapped"}}}"#),
            (503, #"{"error":{"code":503,"message":"Provider could not decode the audio format"}}"#),
            (401, #"{"error":{"message":"User not found.","code":401}}"#),
        ]
        for (status, body) in others {
            #expect(!OpenRouterErrorMapper.refusesAudioFormat(status: status, body: Data(body.utf8)), "\(status) \(body)")
        }
    }

    /// Whole words, however the body quotes them: JSON's escapes part words, an apostrophe doesn't.
    @Test func wordsOfABody() {
        let body = #"{"message":"Couldn’t read","raw":"{\"error\":\"Error:\\nCan’t decode 'audio.flac'\"}"}"#
        #expect(OpenRouterErrorMapper.words(of: Data(body.utf8))
            == " message couldn't read raw error error can't decode audio flac ")
    }

    @Test func successDecodesTextAndCost() throws {
        let data = Data(#"{"text":"  Hello, world. ","usage":{"seconds":9.2,"total_tokens":113,"cost":0.000508}}"#.utf8)
        let result = try OpenRouterErrorMapper.speechSuccess(data: data, engine: .parakeetCloud)
        #expect(result == CloudResult(text: "Hello, world.", costUSD: 0.000508, audioSeconds: 9.2))
    }

    @Test func emptyTextIsNotAnErrorHere() throws {
        let result = try OpenRouterErrorMapper.speechSuccess(data: Data(#"{"text":""}"#.utf8), engine: .parakeetCloud)
        #expect(result.text.isEmpty)
    }

    @Test func failuresInsideA200() {
        #expect(throws: AppError.openRouterProviderUnavailable("Upstream error")) {
            try OpenRouterErrorMapper.speechSuccess(data: Data(#"{"error":{"code":502,"message":"Upstream error"}}"#.utf8),
                                                    engine: .parakeetCloud)
        }
        #expect(throws: AppError.openRouterServer("OpenRouter sent no transcript.")) {
            try OpenRouterErrorMapper.speechSuccess(data: Data(#"{"usage":{"cost":0}}"#.utf8), engine: .parakeetCloud)
        }
        #expect(throws: AppError.openRouterServer("OpenRouter sent a response \(Brand.name) couldn’t read.")) {
            try OpenRouterErrorMapper.speechSuccess(data: Data("<html>".utf8), engine: .parakeetCloud)
        }
    }

    @Test func noRouteHintNamesTheSpeechProvider() {
        let error = OpenRouterErrorMapper.httpError(
            status: 404, data: Data(#"{"error":{"code":404,"message":"No endpoints found for nvidia/parakeet-tdt-0.6b-v3."}}"#.utf8),
            retryAfter: nil, engine: .parakeetCloud)
        guard case .openRouterNoRoute(let message) = error else {
            Issue.record("expected no route, got \(error)")
            return
        }
        #expect(message.contains("Parakeet v3") && message.contains("let Together through"))
        #expect(!message.contains("Google"))
        #expect(OpenRouterErrorMapper.noRouteHint(for: .geminiFlash) == OpenRouterErrorMapper.noRouteHint)
    }
}

// MARK: - Client over a stubbed network

@Suite struct OpenRouterSpeechClientTests {
    private let wav = WAVEncoder.pcm16(tone(1))

    private func call(_ client: OpenRouterClient, model: String = "nvidia/parakeet-tdt-0.6b-v3") async throws -> CloudResult {
        try await client.transcribeSpeech(audio: wav, format: "wav", model: model, apiKey: "sk-or-v1-test", timeout: 180)
    }

    /// A refusal of the file's format isn't an `AppError` but says what it would have been, so the file can go again
    /// in another format; it's never sent again as it is.
    @Test func aRefusedFormatSaysSo() async throws {
        let flac = try CloudAudio.flac(tone(1))
        let (client, host) = StubURLProtocol.client([unsupportedFormat, speechReply("never")])
        await #expect(throws: OpenRouterClient.AudioFormatRefused(
            format: "flac", error: .openRouterBadRequest("Unsupported audio format: flac"))) {
            try await client.transcribeSpeech(audio: flac, format: "flac", model: "nvidia/parakeet-tdt-0.6b-v3",
                                              apiKey: "sk-or-v1-test", timeout: 180)
        }
        #expect(StubURLProtocol.registry.requests(for: host).count == 1)
        let sent = try #require(StubURLProtocol.registry.bodies(for: host).first)
        #expect(upload(inRequestBody: sent)?.format == "flac")
        #expect(upload(inRequestBody: sent)?.samples == rate)
    }

    /// OpenRouter reports a provider's error it can't classify as a 500, and one it can't read as a 502 or inside a
    /// 200: one that says the format was refused isn't sent again as it is either. One that doesn't is retried as
    /// ever.
    @Test func aRefusalReportedAsAServerErrorSaysSo() async throws {
        let flac = try CloudAudio.flac(tone(1))
        let cases: [(StubURLProtocol.Reply, AppError)] = [
            (.init(status: 500, body: #"{"error":{"code":500,"message":"Provider returned error","metadata":{"error_type":"unmapped","raw":"Unsupported audio format: flac"}}}"#),
             .openRouterServer("Provider returned error")),
            (.init(body: #"{"error":{"code":502,"message":"Provider could not decode the audio"}}"#),
             .openRouterProviderUnavailable("Provider could not decode the audio")),
        ]
        for (reply, error) in cases {
            let (client, host) = StubURLProtocol.client([reply, speechReply("never")])
            await #expect(throws: OpenRouterClient.AudioFormatRefused(format: "flac", error: error)) {
                try await client.transcribeSpeech(audio: flac, format: "flac", model: "nvidia/parakeet-tdt-0.6b-v3",
                                                  apiKey: "sk-or-v1-test", timeout: 180)
            }
            #expect(StubURLProtocol.registry.requests(for: host).count == 1, "\(error)")
        }

        let unmapped = StubURLProtocol.Reply(status: 500, body: #"{"error":{"code":500,"message":"Internal Server Error","metadata":{"error_type":"unmapped"}}}"#)
        let (client, host) = StubURLProtocol.client([unmapped, speechReply("ok")])
        #expect(try await call(client).text == "ok")
        #expect(StubURLProtocol.registry.requests(for: host).count == 2)
    }

    @Test func postsToTheTranscriptionEndpoint() async throws {
        let (client, host) = StubURLProtocol.client([speechReply(" Hallo. ", cost: 0.0001, generation: "gen-abc")])
        let result = try await call(client)
        #expect(result.text == "Hallo.")
        #expect(result.costUSD == 0.0001)
        #expect(result.generationID == "gen-abc")
        #expect(result.provider == nil)

        let request = try #require(StubURLProtocol.registry.requests(for: host).first)
        #expect(request.url?.path == "/api/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 180)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-v1-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == "transcribe-thing")
        let body = try json(try #require(StubURLProtocol.registry.bodies(for: host).first))
        #expect(Set(body.keys) == ["model", "input_audio"])
        #expect(upload(inRequestBody: StubURLProtocol.registry.bodies(for: host)[0])?.samples == rate)
    }

    @Test func providerHeaderIsTakenWhenPresent() async throws {
        let (client, _) = StubURLProtocol.client([speechReply("Hi.", generation: "gen-1", provider: "Together")])
        #expect(try await call(client).provider == "Together")
    }

    @Test func invalidKeyMapsAndIsNotRetried() async throws {
        let (client, host) = StubURLProtocol.client([.init(status: 401, body: #"{"error":{"message":"User not found.","code":401}}"#)])
        await #expect(throws: AppError.openRouterInvalidKey("User not found.")) { try await call(client) }
        #expect(StubURLProtocol.registry.requests(for: host).count == 1)
    }

    @Test func transientFailuresAreRetriedOnce() async throws {
        let overloaded = StubURLProtocol.Reply(status: 503, body: #"{"error":{"code":503,"message":"Overloaded"}}"#)
        let (client, host) = StubURLProtocol.client([overloaded, speechReply("ok")])
        #expect(try await call(client).text == "ok")
        #expect(StubURLProtocol.registry.requests(for: host).count == 2)

        let upstream = StubURLProtocol.Reply(body: #"{"error":{"code":502,"message":"Upstream error"}}"#)
        let (second, secondHost) = StubURLProtocol.client([upstream, upstream, speechReply("never")])
        await #expect(throws: AppError.openRouterProviderUnavailable("Upstream error")) { try await call(second) }
        #expect(StubURLProtocol.registry.requests(for: secondHost).count == 2)
    }

    @Test func finalFailuresAreNotRetried() async throws {
        let cases: [(StubURLProtocol.Reply, AppError)] = [
            (.init(status: 402, body: #"{"error":{"code":402,"message":"Insufficient credits"}}"#),
             .openRouterNoCredits("Insufficient credits")),
            (.init(status: 400, body: #"{"error":{"code":400,"message":"Invalid audio"}}"#),
             .openRouterBadRequest("Invalid audio")),
            (.init(status: 413, body: #"{"error":{"code":413,"message":"Request payload too large"}}"#),
             .recordingTooLarge),
            (.init(status: 524, body: #"{"error":{"code":524,"message":"Request timed out."}}"#),
             .timeout(.parakeetCloud)),
            (.init(error: .timedOut), .timeout(.parakeetCloud)),
            (.init(error: .notConnectedToInternet), .offline),
        ]
        for (reply, expected) in cases {
            let (client, host) = StubURLProtocol.client([reply, speechReply("never")])
            await #expect(throws: expected) { try await call(client) }
            #expect(StubURLProtocol.registry.requests(for: host).count == 1, "\(expected)")
        }
    }

    @Test func liveInvalidKeyShapeMapsToInvalidKey() {
        // Body OpenRouter returned on 2026-09-27 for `Authorization: Bearer sk-or-v1-invalid` on this endpoint.
        let error = OpenRouterErrorMapper.httpError(status: 401, data: Data(#"{"error":{"message":"User not found.","code":401}}"#.utf8),
                                                    retryAfter: nil, engine: .parakeetCloud)
        #expect(error == .openRouterInvalidKey("User not found."))
    }
}

// MARK: - Generation lookup

@Suite struct OpenRouterGenerationTests {
    @Test func decodesTheProviderName() async throws {
        let (client, host) = StubURLProtocol.client([generationReply("Together")])
        #expect(try await client.generationProvider(id: "gen-1 2", apiKey: "sk-or-v1-test") == "Together")
        let request = try #require(StubURLProtocol.registry.requests(for: host).first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api/v1/generation")
        let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query == [URLQueryItem(name: "id", value: "gen-1 2")])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-v1-test")
    }

    @Test func notRecordedYetIsNil() async throws {
        let (client, _) = StubURLProtocol.client([.init(status: 404, body: #"{"error":{"code":404,"message":"Generation not found"}}"#),
                                                  generationReply(nil)])
        #expect(try await client.generationProvider(id: "gen-1", apiKey: "k") == nil)
        #expect(try await client.generationProvider(id: "gen-1", apiKey: "k") == nil)
    }

    @Test func otherFailuresThrow() async throws {
        let (client, _) = StubURLProtocol.client([.init(status: 401, body: #"{"error":{"message":"User not found.","code":401}}"#)])
        await #expect(throws: AppError.openRouterInvalidKey("User not found.")) {
            try await client.generationProvider(id: "gen-1", apiKey: "k")
        }
    }
}

// MARK: - TranscriptionService

@MainActor
@Suite struct CloudSpeechServiceTests {
    private func makeService(_ replies: [StubURLProtocol.Reply], key: String? = "sk-or-v1-test")
        -> (TranscriptionService, String, OpenRouterAccount) {
        let store = ModelStore.preview(states: [.parakeet: .ready])
        let (client, host) = StubURLProtocol.client(replies)
        let keyStore = KeyFileStore.inMemory(key)
        let account = OpenRouterAccount(keyStore: keyStore, client: client, debounce: .zero)
        let service = TranscriptionService(models: store, account: account, client: client,
                                           providerLookupDelay: .milliseconds(10))
        return (service, host, account)
    }

    private func speech(_ seconds: Double) -> Recording { Recording(samples: tone(seconds)) }

    @Test func aFiveMinuteRecordingIsOneRequest() async throws {
        // 9.6 MB as WAV, a little over half that as FLAC: the speech endpoint takes it whole.
        let audio = await offMain { babble(300) }
        let (service, host, _) = makeService([speechReply("The whole talk.", cost: 0.004, generation: "gen-1")])
        let result = try await service.transcribe(Recording(samples: audio), engine: .parakeetCloud)
        #expect(result.text == "The whole talk.")
        #expect(result.engine == .parakeetCloud)
        #expect(result.costUSD == 0.004)
        #expect(result.audioSeconds == 12.5)
        #expect(result.generationID == "gen-1")
        #expect(result.provider == nil)
        #expect(result.processingTime > 0)

        let requests = StubURLProtocol.registry.requests(for: host)
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.path == "/api/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 180)
        let bodies = StubURLProtocol.registry.bodies(for: host)
        #expect(bodies.count == 1)
        let body = try #require(bodies.first)
        let fields = await offMain { () -> (model: String?, keys: Set<String>, upload: (format: String, samples: Int)?) in
            let object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            return (object["model"] as? String, Set(object.keys), upload(inRequestBody: body))
        }
        #expect(fields.model == "nvidia/parakeet-tdt-0.6b-v3")
        #expect(fields.keys == ["model", "input_audio"], "no language, no provider routing")
        #expect(fields.upload?.format == "flac")
        #expect(fields.upload?.samples == audio.count)
        let flac = try #require(result.uploads.first)
        #expect(result.uploads.count == 1 && flac.format == .flac)
        #expect(flac.bytes < WAVEncoder.pcm16(audio).count * 7 / 10, "lossless, in far fewer bytes than WAV")
    }

    /// Past 5 minutes Parakeet goes in segments cut in pauses, a request each, in order: the texts join with a space
    /// (a segment with none adds nothing), the billed seconds and costs add up, and the first segment's generation
    /// stands for the whole.
    @Test func aTwelveMinuteRecordingGoesInThreeSegments() async throws {
        let audio = await offMain { babble(288) + silence(2) + babble(290) + silence(2) + babble(138) }
        let (service, host, _) = makeService([
            speechReply(" First part. ", cost: 0.002, generation: "gen-1"),
            speechReply("", cost: 0.001, generation: "gen-2", provider: "Together"),
            speechReply("Third part.", cost: 0.003, generation: "gen-3"),
        ])
        let result = try await service.transcribe(Recording(samples: audio), engine: .parakeetCloud)
        #expect(result.text == "First part. Third part.")
        #expect(result.audioSeconds == 37.5)
        #expect(abs((result.costUSD ?? 0) - 0.006) < 1e-12)
        #expect(result.generationID == "gen-1")
        #expect(result.provider == "Together")

        let requests = StubURLProtocol.registry.requests(for: host)
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.timeoutInterval == 180 }, "3 minutes per segment")
        let sent = await uploads(StubURLProtocol.registry.bodies(for: host))
        #expect(sent.map(\.format) == ["flac", "flac", "flac"])
        #expect(sent.map(\.samples).reduce(0, +) == audio.count, "every sample, once")
        #expect(sent.allSatisfy { $0.samples <= 300 * 16_000 })
        #expect(result.uploads.map(\.format) == [.flac, .flac, .flac])
    }

    /// A segment whose FLAC OpenRouter refuses goes again as WAV at once; the segments after it, and every later
    /// dictation, go as WAV from the start.
    @Test func aRefusedFLACGoesAgainAsWAVFromThenOn() async throws {
        let audio = await offMain { babble(288) + silence(2) + babble(290) + silence(2) + babble(138) }
        let (service, host, _) = makeService([
            speechReply("First part.", cost: 0.002, generation: "gen-1"),
            .init(status: 415, body: #"{"error":{"code":415,"message":"Unsupported Media Type"}}"#),
            speechReply("Second part.", cost: 0.002),
            speechReply("Third part.", cost: 0.001),
            speechReply("Later."),
        ])
        #expect(service.speechFormat == .flac)
        let result = try await service.transcribe(Recording(samples: audio), engine: .parakeetCloud)
        #expect(result.text == "First part. Second part. Third part.")
        #expect(abs((result.costUSD ?? 0) - 0.005) < 1e-12)
        #expect(result.uploads.map(\.format) == [.flac, .wav, .wav])
        #expect(service.speechFormat == .wav)

        let sent = await uploads(StubURLProtocol.registry.bodies(for: host))
        #expect(sent.map(\.format) == ["flac", "flac", "wav", "wav"])
        #expect(sent[1].samples == sent[2].samples, "the refused segment, again")
        #expect(sent[0].samples + sent[2].samples + sent[3].samples == audio.count)

        let later = try await service.transcribe(speech(3), engine: .parakeetCloud)
        #expect(later.text == "Later." && later.uploads.map(\.format) == [.wav])
        let all = await uploads(StubURLProtocol.registry.bodies(for: host))
        #expect(all.map(\.format).last == "wav")
    }

    /// A refusal worded as a 400 falls back the same way, and a dictation doesn't fail for it.
    @Test func aBadRequestRefusingTheFormatFallsBackToo() async throws {
        let (service, host, _) = makeService([unsupportedFormat, speechReply("Hallo.")])
        let result = try await service.transcribe(speech(3), engine: .parakeetCloud)
        #expect(result.text == "Hallo." && result.uploads.map(\.format) == [.wav])
        #expect(await uploads(StubURLProtocol.registry.bodies(for: host)).map(\.format) == ["flac", "wav"])
        #expect(service.speechFormat == .wav)
    }

    /// A refusal OpenRouter reports as a server error (a provider's error it can't classify) falls back the same way,
    /// at once, instead of sending the same FLAC again and failing the dictation.
    @Test func aRefusalReportedAsAServerErrorFallsBackToo() async throws {
        let unmapped = StubURLProtocol.Reply(status: 500, body: #"{"error":{"code":500,"message":"Provider returned error","metadata":{"error_type":"unmapped","raw":"Unsupported audio format: flac"}}}"#)
        let (service, host, _) = makeService([unmapped, speechReply("Hallo.")])
        let result = try await service.transcribe(speech(2), engine: .parakeetCloud)
        #expect(result.text == "Hallo." && result.uploads.map(\.format) == [.wav])
        #expect(await uploads(StubURLProtocol.registry.bodies(for: host)).map(\.format) == ["flac", "wav"])
        #expect(service.speechFormat == .wav)
    }

    /// A bad request that isn't about the format fails the dictation as it is: no WAV sent after it, and FLAC stays.
    @Test func aBadRequestNotAboutTheFormatFailsAsItIs() async throws {
        let message = "Invalid request: some required information is missing"
        let (service, host, _) = makeService([
            .init(status: 400, body: #"{"error":{"code":400,"message":"\#(message)"}}"#), speechReply("never"),
        ])
        await #expect(throws: AppError.openRouterBadRequest(message)) {
            try await service.transcribe(speech(2), engine: .parakeetCloud)
        }
        #expect(await uploads(StubURLProtocol.registry.bodies(for: host)).map(\.format) == ["flac"])
        #expect(service.speechFormat == .flac)
    }

    /// A WAV refused as if for its format has nothing to fall back to: it fails as the bad request it is.
    @Test func aRefusedWAVFails() async throws {
        let refusal = StubURLProtocol.Reply(status: 400, body: #"{"error":{"code":400,"message":"Unsupported format"}}"#)
        let (service, host, _) = makeService([unsupportedFormat, refusal, speechReply("never")])
        await #expect(throws: AppError.openRouterBadRequest("Unsupported format")) {
            try await service.transcribe(speech(3), engine: .parakeetCloud)
        }
        #expect(await uploads(StubURLProtocol.registry.bodies(for: host)).map(\.format) == ["flac", "wav"])
    }

    /// Audio FLAC can't hold (shorter than one packet) goes as WAV, and the next segment tries FLAC again: an encoder
    /// failure isn't OpenRouter's refusal.
    @Test func aFailedFLACEncodeSendsWAV() async throws {
        let (service, host, _) = makeService([speechReply("Hi."), speechReply("Hello.")])
        #expect(try await service.transcribe(speech(0.2), engine: .parakeetCloud).uploads.map(\.format) == [.wav])
        #expect(service.speechFormat == .flac)
        _ = try await service.transcribe(speech(1), engine: .parakeetCloud)
        #expect(await uploads(StubURLProtocol.registry.bodies(for: host)).map(\.format) == ["wav", "flac"])
    }

    /// `EngineCLI --upload` sends the format it names; a refusal of it fails the run instead of going as WAV.
    @Test func aForcedFormatIsSentAndNotFallenBackFrom() async throws {
        let (service, host, _) = makeService([speechReply("As M4A."), speechReply("As WAV."), unsupportedFormat,
                                              speechReply("never")])
        #expect(try await service.transcribe(speech(3), engine: .parakeetCloud, upload: .m4a).text == "As M4A.")
        #expect(try await service.transcribe(speech(3), engine: .parakeetCloud, upload: .wav).text == "As WAV.")
        await #expect(throws: AppError.openRouterBadRequest("Unsupported audio format: flac")) {
            try await service.transcribe(speech(3), engine: .parakeetCloud, upload: .flac)
        }
        let sent = await uploads(StubURLProtocol.registry.bodies(for: host))
        #expect(sent.map(\.format) == ["m4a", "wav", "flac"])
        #expect(sent.allSatisfy { abs($0.samples - 3 * rate) <= rate / 10 })
        #expect(service.speechFormat == .flac, "a forced format teaches the app nothing")
    }

    @Test func parakeetSendsNoLanguageOrPrompt() async throws {
        let (service, host, _) = makeService([speechReply("Dzień dobry.", provider: "Together")])
        let result = try await service.transcribe(speech(3), engine: .parakeetCloud)
        #expect(result.text == "Dzień dobry.")
        #expect(result.provider == "Together")
        #expect(result.usedSystemPrompt == false, "Gemini's prompt isn't for speech models")
        let body = try json(try #require(StubURLProtocol.registry.bodies(for: host).first))
        #expect(Set(body.keys) == ["model", "input_audio"])
        #expect(body["model"] as? String == "nvidia/parakeet-tdt-0.6b-v3")
    }

    @Test func aFailedRequestFailsTheDictation() async throws {
        let (service, host, account) = makeService([
            .init(status: 402, body: #"{"error":{"code":402,"message":"Insufficient credits"}}"#), speechReply("never"),
        ])
        await #expect(throws: AppError.openRouterNoCredits("Insufficient credits")) {
            try await service.transcribe(speech(3), engine: .parakeetCloud)
        }
        #expect(StubURLProtocol.registry.requests(for: host).count == 1)
        #expect(account.status == .noCredit(nil))
    }

    @Test func aTransientFailureIsRetriedOnceForTheWholeRecording() async throws {
        let audio = await offMain { babble(90) }
        let (service, host, _) = makeService([
            .init(status: 503, body: #"{"error":{"code":503,"message":"Overloaded"}}"#), speechReply("ok", generation: "gen-2"),
        ])
        let result = try await service.transcribe(Recording(samples: audio), engine: .parakeetCloud)
        #expect(result.text == "ok" && result.generationID == "gen-2")
        let sent = await uploads(StubURLProtocol.registry.bodies(for: host))
        #expect(sent.map(\.format) == ["flac", "flac"])
        #expect(sent.map(\.samples) == [audio.count, audio.count])
    }

    @Test func tooLargeForOpenRouterIsReportedNotRetried() async throws {
        let (service, host, _) = makeService([
            .init(status: 413, body: #"{"error":{"code":413,"message":"Request payload too large"}}"#), speechReply("never"),
        ])
        await #expect(throws: AppError.recordingTooLarge) {
            try await service.transcribe(speech(3), engine: .parakeetCloud)
        }
        #expect(StubURLProtocol.registry.requests(for: host).count == 1)
    }

    @Test func textOnANearlySilentRecordingIsKept() async throws {
        // Parakeet doesn't make up subtitle credits on silence, so nothing it returns is filtered out.
        let faint = babble(0.3) + roomNoise(3)
        let (service, _, _) = makeService([speechReply("Thanks for watching!")])
        #expect(try await service.transcribe(Recording(samples: faint), engine: .parakeetCloud).text
            == "Thanks for watching!")
    }

    /// No text back means no speech heard, on speech-like audio as on silence: an empty result, not an error.
    @Test func noTextIsAnEmptyResultNotAnError() async throws {
        let (service, _, _) = makeService([speechReply(""), speechReply("  ")])
        #expect(try await service.transcribe(speech(2), engine: .parakeetCloud).text.isEmpty)
        #expect(try await service.transcribe(Recording(samples: silence(2)), engine: .parakeetCloud).text.isEmpty)
    }

    @Test func missingKeyStopsBeforeTheNetwork() async throws {
        let (service, host, _) = makeService([speechReply("never")], key: nil)
        await #expect(throws: AppError.openRouterMissingKey) {
            try await service.transcribe(speech(1), engine: .parakeetCloud)
        }
        #expect(StubURLProtocol.registry.requests(for: host).isEmpty)
    }

    @Test func servedProviderToleratesALateGenerationRecord() async throws {
        let (service, host, _) = makeService([.init(status: 404, body: #"{"error":{"code":404,"message":"Not found"}}"#),
                                              generationReply("Together")])
        #expect(await service.servedProvider(generationID: "gen-1") == "Together")
        #expect(StubURLProtocol.registry.requests(for: host).count == 2)
    }

    @Test func servedProviderGivesUpQuietly() async throws {
        let notFound = StubURLProtocol.Reply(status: 404, body: #"{"error":{"code":404,"message":"Not found"}}"#)
        let (service, host, _) = makeService([notFound, notFound])
        #expect(await service.servedProvider(generationID: "gen-1") == nil)
        #expect(StubURLProtocol.registry.requests(for: host).count == 2)

        let (failing, failingHost, _) = makeService([.init(status: 500, body: "oops"), generationReply("Together")])
        #expect(await failing.servedProvider(generationID: "gen-1") == nil)
        #expect(StubURLProtocol.registry.requests(for: failingHost).count == 1, "only a 404 is worth asking again")

        let (keyless, keylessHost, _) = makeService([generationReply("Together")], key: nil)
        #expect(await keyless.servedProvider(generationID: "gen-1") == nil)
        #expect(StubURLProtocol.registry.requests(for: keylessHost).isEmpty)
    }

    @Test func servedProviderIsOneLookupForTheOneGeneration() async throws {
        let (service, host, _) = makeService([generationReply("Together"), generationReply("Someone Else")])
        #expect(await service.servedProvider(generationID: "gen-1") == "Together")
        let requests = StubURLProtocol.registry.requests(for: host)
        #expect(requests.count == 1)
        let url = try #require(requests.first?.url)
        #expect(url.path == "/api/v1/generation")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "id", value: "gen-1")])
    }
}

// MARK: - History and delivery

@MainActor
@Suite(.serialized) struct CloudSpeechHistoryTests {
    @Test func historyWithoutProviderStillLoads() async throws {
        let paths = AppPaths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let old = #"""
        {"version":1,"entries":[{"audioDuration":4.5,"costUSD":0.0012,"createdAt":"2026-09-20T10:00:00.250Z",
        "engine":"geminiFlash","id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","processingTime":1.5,"status":"success",
        "text":"Hello","voicedSeconds":3.25}]}
        """#
        try Data(old.utf8).write(to: paths.historyFile)
        let settings = AppSettings.inMemory()
        let store = HistoryStore(paths: paths, settings: settings)
        store.load()
        try await waitUntil { store.isLoaded }
        let entry = try #require(store.entries.first)
        #expect(entry.text == "Hello" && entry.engine == .geminiFlash && entry.provider == nil)

        store.upsert(TranscriptEntry(text: "Cześć", engine: .parakeetCloud, audioDuration: 2, voicedSeconds: 1.5,
                                     processingTime: 0.8, costUSD: 0.00005, provider: "Together"))
        store.flush()
        let raw = String(decoding: try Data(contentsOf: paths.historyFile), as: UTF8.self)
        #expect(raw.contains(#""provider":"Together""#) && raw.contains(#""engine":"parakeetCloud""#))
        // Flat for older builds and in its version: absent, not null, when unknown.
        #expect(raw.components(separatedBy: #""provider""#).count == 3, "absent, not null, when unknown")

        let reloaded = HistoryStore(paths: paths, settings: settings)
        reloaded.load()
        try await waitUntil { reloaded.isLoaded }
        #expect(reloaded.entries.map(\.provider) == ["Together", nil])
    }

    @Test func historyFromBeforeWhisperWasRemovedKeepsEveryEntry() async throws {
        let paths = AppPaths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        // Written by a build that still offered Whisper on this Mac and through OpenRouter, plus one entry from
        // an engine no build of this one knows.
        let old = #"""
        {"version":1,"entries":[
        {"audioDuration":6,"createdAt":"2026-09-26T10:04:00.000Z","engine":"whisperCloud",
         "id":"11111111-1111-1111-1111-111111111111","processingTime":1.1,"status":"success","text":"Cloud text",
         "voicedSeconds":5,"costUSD":0.00016,"provider":"Groq"},
        {"audioDuration":5,"createdAt":"2026-09-26T10:03:00.000Z","engine":"whisper",
         "id":"22222222-2222-2222-2222-222222222222","processingTime":0.9,"status":"success","text":"Local text",
         "voicedSeconds":4},
        {"audioDuration":7,"createdAt":"2026-09-26T10:02:00.000Z","engine":"whisper","errorMessage":"Couldn’t transcribe",
         "id":"33333333-3333-3333-3333-333333333333","status":"failed","text":"","voicedSeconds":6},
        {"audioDuration":3,"createdAt":"2026-09-26T10:01:00.000Z","engine":"someFutureEngine",
         "id":"44444444-4444-4444-4444-444444444444","status":"success","text":"From the future","voicedSeconds":2},
        {"audioDuration":4,"createdAt":"2026-09-26T10:00:00.000Z","engine":"geminiFlash",
         "id":"55555555-5555-5555-5555-555555555555","status":"success","text":"Gemini text","voicedSeconds":3}
        ]}
        """#
        try Data(old.utf8).write(to: paths.historyFile)
        let settings = AppSettings.inMemory()
        let store = HistoryStore(paths: paths, settings: settings)
        store.load()
        try await waitUntil { store.isLoaded }

        // Each removed engine reads as Parakeet v3 on the same side; the rest of the entry is untouched.
        #expect(store.entries.map(\.engine) == [.parakeetCloud, .parakeet, .parakeet, .geminiFlash])
        #expect(store.entries.map(\.text) == ["Cloud text", "Local text", "", "Gemini text"])
        let cloud = try #require(store.entries.first)
        #expect(cloud.provider == "Groq" && cloud.costUSD == 0.00016 && cloud.processingTime == 1.1)
        let failed = try #require(store.entries.first { $0.status == .failed })
        #expect(failed.engine == .parakeet && failed.errorMessage == "Couldn’t transcribe")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
        #expect(!siblings.contains { $0.hasPrefix("history-unreadable") }, "the file was read, not set aside")

        store.flush()
        let raw = String(decoding: try Data(contentsOf: paths.historyFile), as: UTF8.self)
        #expect(raw.contains(#""engine":"parakeetCloud""#) && !raw.contains(#""engine":"whisper"#))
    }

    @Test func deliveredCloudTranscriptLearnsItsProvider() async throws {
        let h = DictationControllerTests.make()
        var asked: [String] = []
        h.controller.providerLookupOverride = { id in
            asked.append(id)
            return "Together"
        }
        h.controller.transcribeOverride = { _, engine in
            TranscriptResult(text: "Hallo", engine: engine, processingTime: 0.4, costUSD: 0.00001,
                             generationID: "gen-1")
        }
        h.controller.insertOverride = { _, _ in .pasted }
        let recording = DictationControllerTests.recording()
        h.controller.enqueue(recording, engine: .parakeetCloud, targetPID: nil)
        try await waitUntil { h.history.entry(id: recording.id)?.provider != nil }
        #expect(h.history.entry(id: recording.id)?.provider == "Together")
        #expect(asked == ["gen-1"])
    }

    @Test func aResponseThatSaidItAllNeedsNoLookup() async throws {
        let h = DictationControllerTests.make()
        h.controller.providerLookupOverride = { _ in
            Issue.record("no lookup when the response named the provider and the cost")
            return nil
        }
        h.controller.transcribeOverride = { _, engine in
            TranscriptResult(text: "Hallo", engine: engine, processingTime: 0.4, costUSD: 0.00001,
                             provider: "Together", generationID: "gen-1")
        }
        h.controller.insertOverride = { _, _ in .pasted }
        let recording = DictationControllerTests.recording()
        h.controller.enqueue(recording, engine: .parakeetCloud, targetPID: nil)
        try await waitUntil { h.history.entry(id: recording.id) != nil }
        #expect(h.history.entry(id: recording.id)?.provider == "Together")
    }

    @Test func aMissingKeyRefusesCloudSpeechBeforeRecording() throws {
        let h = DictationControllerTests.make(models: [.parakeet: .ready], keyStatus: .missing)
        h.settings.parakeetEngine = .parakeetCloud
        h.controller.send(.handsFreeToggle)
        #expect(h.recorder.starts == 0)
        #expect(h.controller.machine.capture == .idle)
        let notice = try #require(h.toasts.notices.first)
        #expect(notice.title == "Add your OpenRouter key")
        #expect(notice.body == "Parakeet v3 · Cloud needs a key to transcribe.")
        #expect(notice.actions.map(\.kind) == [.openHub(.models), .selectEngine(.parakeet)])
    }

    @Test func aFailedCloudDictationOffersTheSameModelOnThisMacFirst() async throws {
        let h = DictationControllerTests.make(models: [.parakeet: .ready], keyStatus: .valid(KeyInfo()))
        h.controller.transcribeOverride = { _, _ in throw AppError.openRouterRateLimited(retryAfter: nil) }
        let recording = DictationControllerTests.recording()
        h.controller.enqueue(recording, engine: .parakeetCloud, targetPID: nil)
        try await waitUntil { h.history.entry(id: recording.id)?.status == .failed }
        let notice = try #require(h.toasts.notices.first { $0.recordingID == recording.id })
        #expect(notice.title == "Parakeet v3 · Cloud is rate-limited")
        #expect(notice.actions.contains { $0.kind == .retryWith(.parakeet) })
        #expect(h.history.entry(id: recording.id)?.errorMessage == "Parakeet v3 · Cloud is rate-limited")
    }
}

// MARK: - Notices

@Suite struct CloudSpeechNoticeTests {
    /// Errors that name a Gemini engine themselves ("Gemini Flash took too long") are about Gemini either way.
    static let errorsWithoutGemini = NoticeCopyTests.allErrors.filter { !$0.code.lowercased().contains("gemini") }

    @Test(arguments: errorsWithoutGemini)
    func speechEnginesNeverTalkAboutGemini(_ error: AppError) {
        for engine in EngineID.cloudTranscriptionEngines {
            let notice = error.notice(recordingID: UUID(), fallbackEngine: .parakeet, engine: engine)
            let texts = [notice.title, notice.body ?? ""] + notice.actions.map(\.title)
            #expect(texts.allSatisfy { !$0.contains("Gemini") && !$0.contains("Google") }, "\(error) for \(engine)")
            #expect(!notice.title.hasSuffix("."))
            #expect(notice.title.first?.isUppercase == true || notice.title.hasPrefix("\(Brand.name) "))
        }
    }

    /// Nothing is refused up front, so "too large" is always OpenRouter's word, for Gemini as for Parakeet, and the
    /// model on this Mac is offered first.
    @Test(arguments: [EngineID.geminiFlash, .parakeetCloud])
    func tooLargeIsWhatOpenRouterSaid(_ engine: EngineID) {
        let notice = AppError.recordingTooLarge.notice(recordingID: UUID(), fallbackEngine: .parakeet, engine: engine)
        #expect(notice.title == "Too large to send to OpenRouter")
        #expect(notice.body?.hasPrefix(
            "OpenRouter refused this recording as too large. Parakeet v3 on this Mac takes any length.") == true)
        #expect(notice.primaryAction?.kind == .retryWith(.parakeet))
    }

    @Test func geminiCopyIsUnchanged() {
        for engine in [nil, EngineID.geminiFlash, .parakeet] {
            let notice = AppError.openRouterRateLimited(retryAfter: nil).notice(recordingID: nil, fallbackEngine: nil,
                                                                              engine: engine)
            #expect(notice.title == "Gemini is rate-limited")
        }
        #expect(AppError.offline.localizedDescription == "You’re offline. Gemini needs the internet.")
    }

    @Test func speechCopyNamesTheEngine() {
        #expect(AppError.openRouterProviderUnavailable("x").notice(recordingID: nil, fallbackEngine: nil,
                                                                   engine: .parakeetCloud).title
            == "Parakeet v3 · Cloud is unavailable")
        #expect(AppError.offline.notice(recordingID: nil, fallbackEngine: nil, engine: .parakeetCloud).body
            == "Parakeet v3 · Cloud needs the internet.")
        #expect(AppError.timeout(.parakeetCloud).notice(recordingID: nil, fallbackEngine: nil).body
            == "OpenRouter didn’t answer in time.")
    }
}
