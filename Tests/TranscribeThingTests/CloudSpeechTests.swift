import AppKit
import Foundation
import Testing
@testable import TranscribeThing

// Parakeet through OpenRouter's speech-to-text endpoint: engine metadata, wire format, one request per recording,
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

/// Samples in the WAV carried by a transcription request body.
private func wavSampleCount(inRequestBody body: Data) -> Int? {
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let audio = object["input_audio"] as? [String: Any], let base64 = audio["data"] as? String,
          let wav = Data(base64Encoded: base64) else { return nil }
    return WAVEncoder.decode(wav)?.count
}

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
        #expect(EngineID.allCases.map(\.rawValue) == ["parakeet", "parakeetCloud", "geminiFlash", "geminiPro"])
        #expect(EngineID.localEngines == [.parakeet])
        #expect(EngineID.cloudEngines == [.parakeetCloud, .geminiFlash, .geminiPro])
        #expect(EngineID.cloudTranscriptionEngines == [.parakeetCloud])
        #expect(EngineID.cloudChatEngines == [.geminiFlash, .geminiPro])
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
        #expect(EngineID.geminiFlash.provider == "Google AI Studio" && EngineID.geminiPro.provider == "Google AI Studio")
        #expect(EngineID.parakeet.provider == nil)
        for engine in EngineID.cloudTranscriptionEngines {
            #expect(engine.isCloud && !engine.isLocal)
            #expect(engine.cloudAPI == .transcriptions)
            #expect(engine.badges == ["Cloud"])
            #expect(engine.approxDownloadBytes == nil)
            #expect(engine.cloudTimeout == 180)
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

    @Test @MainActor func onlyGeminiShortensTheRecordingLimit() {
        let settings = AppSettings.inMemory()
        settings.maxRecordingMinutes = 20
        for engine in EngineID.allCases {
            let expected: TimeInterval = engine.cloudAPI == .chatCompletions ? 7 * 60 : 20 * 60
            #expect(settings.maxRecordingDuration(for: engine) == expected, "\(engine)")
        }
        for engine in EngineID.mainCandidates {
            settings.selectedEngine = engine
            #expect(settings.effectiveMaxRecordingDuration == 20 * 60, "\(engine)")
        }
    }

    @Test func slowNoticeThresholdIsOnePerEngineKind() {
        #expect(DictationController.slowNoticeDelay(for: .parakeet) == 3)
        #expect(DictationController.slowNoticeDelay(for: .parakeetCloud) == 10)
        #expect(DictationController.slowNoticeDelay(for: .geminiFlash) == 12)
    }

    @Test func cloudSessionTimeouts() {
        let config = URLSession.openRouterCloud.configuration
        #expect(config.timeoutIntervalForRequest == 180)
        #expect(config.timeoutIntervalForResource == 330)
    }
}

// MARK: - Request and response

@Suite struct OpenRouterSpeechWireTests {
    @Test func requestCarriesModelAndAudioOnly() throws {
        let body = try json(OpenRouterSpeechRequest.wav(model: "nvidia/parakeet-tdt-0.6b-v3",
                                                        audioBase64: "UklG+/==").encoded())
        #expect(Set(body.keys) == ["model", "input_audio"], "no language, provider routing, temperature or format")
        #expect(body["model"] as? String == "nvidia/parakeet-tdt-0.6b-v3")
        let audio = try #require(body["input_audio"] as? [String: Any])
        #expect(audio["data"] as? String == "UklG+/==")
        #expect(audio["format"] as? String == "wav")
        #expect(audio.count == 2)
    }

    @Test func base64SlashesAreNotEscaped() throws {
        let raw = String(decoding: try OpenRouterSpeechRequest.wav(model: "nvidia/parakeet-tdt-0.6b-v3",
                                                                   audioBase64: "ab/cd+/ef==").encoded(),
                         as: UTF8.self)
        #expect(raw.contains("ab/cd+/ef==") && raw.contains("nvidia/parakeet-tdt-0.6b-v3") && !raw.contains("\\/"))
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
        try await client.transcribeSpeech(wav: wav, model: model, apiKey: "sk-or-v1-test", timeout: 180)
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
        #expect(wavSampleCount(inRequestBody: StubURLProtocol.registry.bodies(for: host)[0]) == rate)
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
        let settings = AppSettings.inMemory()
        settings.geminiSystemPrompt = "Never sent to speech models."
        let store = ModelStore.preview(states: [.parakeet: .ready])
        let (client, host) = StubURLProtocol.client(replies)
        let keychain = KeychainStore.inMemory(key.map { [KeychainStore.openRouterAccount: $0] } ?? [:])
        let account = OpenRouterAccount(keychain: keychain, client: client, debounce: .zero)
        let service = TranscriptionService(models: store, account: account, client: client, settings: settings,
                                           providerLookupDelay: .milliseconds(10))
        return (service, host, account)
    }

    private func speech(_ seconds: Double) -> Recording { Recording(samples: tone(seconds)) }

    @Test func aTenMinuteRecordingIsOneRequest() async throws {
        // 19.2 MB of WAV, more than Gemini's inline limit: the speech endpoint takes it whole, no local cap.
        let audio = await offMain { babble(600) }
        let (service, host, _) = makeService([speechReply("The whole talk.", cost: 0.004, generation: "gen-1")])
        let result = try await service.transcribe(Recording(samples: audio), engine: .parakeetCloud)
        #expect(result.text == "The whole talk.")
        #expect(result.engine == .parakeetCloud)
        #expect(result.costUSD == 0.004)
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
        let fields = await offMain { () -> (model: String?, keys: Set<String>, samples: Int?) in
            let object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            return (object["model"] as? String, Set(object.keys), wavSampleCount(inRequestBody: body))
        }
        #expect(fields.model == "nvidia/parakeet-tdt-0.6b-v3")
        #expect(fields.keys == ["model", "input_audio"], "no language, no provider routing")
        #expect(fields.samples == audio.count)
    }

    @Test func parakeetSendsNoLanguageOrPrompt() async throws {
        let (service, host, _) = makeService([speechReply("Dzień dobry.", provider: "Together")])
        let result = try await service.transcribe(speech(3), engine: .parakeetCloud)
        #expect(result.text == "Dzień dobry.")
        #expect(result.provider == "Together")
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
        let bodies = StubURLProtocol.registry.bodies(for: host)
        #expect(bodies.count == 2)
        let counts = await offMain { bodies.map { wavSampleCount(inRequestBody: $0) } }
        #expect(counts == [audio.count, audio.count])
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
        h.controller.enqueue(recording, engine: .parakeetCloud, delivery: .paste(targetPID: nil))
        try await waitUntil { h.history.entry(id: recording.id)?.provider != nil }
        #expect(h.history.entry(id: recording.id)?.provider == "Together")
        #expect(asked == ["gen-1"])
    }

    @Test func aProviderFromTheResponseNeedsNoLookup() async throws {
        let h = DictationControllerTests.make()
        h.controller.providerLookupOverride = { _ in
            Issue.record("no lookup when the response named the provider")
            return nil
        }
        h.controller.transcribeOverride = { _, engine in
            TranscriptResult(text: "Hallo", engine: engine, processingTime: 0.4, provider: "Together",
                             generationID: "gen-1")
        }
        h.controller.insertOverride = { _, _ in .pasted }
        let recording = DictationControllerTests.recording()
        h.controller.enqueue(recording, engine: .parakeetCloud, delivery: .paste(targetPID: nil))
        try await waitUntil { h.history.entry(id: recording.id) != nil }
        #expect(h.history.entry(id: recording.id)?.provider == "Together")
    }

    @Test func aMissingKeyRefusesCloudSpeechBeforeRecording() throws {
        let h = DictationControllerTests.make(models: [.parakeet: .ready], keyStatus: .missing)
        h.settings.selectedEngine = .parakeetCloud
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
        h.controller.enqueue(recording, engine: .parakeetCloud, delivery: .paste(targetPID: nil))
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
