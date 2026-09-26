import AppKit
import Foundation
import Testing
@testable import TranscribeThing

// Parakeet and Whisper through OpenRouter's speech-to-text endpoint: engine metadata, wire format, chunking,
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

private func sample(atSeconds seconds: Double) -> Int { Int(seconds * Double(rate)) }

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

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
    return StubURLProtocol.Reply(body: #"{"data":{"id":"gen-1","api_type":"stt","model":"openai/whisper-large-v3-turbo","provider_name":\#(name),"total_cost":0.0001,"created_at":"2026-09-27T10:00:00Z"}}"#)
}

// MARK: - Engine metadata

@Suite struct CloudEngineFactsTests {
    @Test func rawValuesAreStableAndOrderIsLocalThenCloudSpeechThenGemini() {
        #expect(EngineID.allCases.map(\.rawValue)
            == ["parakeet", "whisper", "parakeetCloud", "whisperCloud", "geminiFlash", "geminiPro"])
        #expect(EngineID.localEngines == [.parakeet, .whisper])
        #expect(EngineID.cloudEngines == [.parakeetCloud, .whisperCloud, .geminiFlash, .geminiPro])
        #expect(EngineID.cloudTranscriptionEngines == [.parakeetCloud, .whisperCloud])
        #expect(EngineID.cloudChatEngines == [.geminiFlash, .geminiPro])
    }

    @Test func namesTellLocalAndCloudApart() {
        #expect(Set(EngineID.allCases.map(\.displayName)).count == EngineID.allCases.count)
        #expect(Set(EngineID.allCases.map(\.shortName)).count == EngineID.allCases.count)
        #expect(EngineID.parakeetCloud.shortName == "Parakeet v3 · Cloud")
        #expect(EngineID.whisperCloud.shortName == "Whisper Turbo · Cloud")
        #expect(EngineID.parakeetCloud.modelName == EngineID.parakeet.displayName)
        #expect(EngineID.whisperCloud.modelName == EngineID.whisper.displayName)
    }

    @Test func cloudSpeechFacts() {
        #expect(EngineID.parakeetCloud.openRouterModelID == "nvidia/parakeet-tdt-0.6b-v3")
        #expect(EngineID.whisperCloud.openRouterModelID == "openai/whisper-large-v3-turbo")
        #expect(EngineID.parakeetCloud.preferredProvider == "Together")
        #expect(EngineID.whisperCloud.preferredProvider == "Groq")
        #expect(EngineID.parakeetCloud.providerRoutingNote == nil)
        #expect(EngineID.whisperCloud.providerRoutingNote?.contains("Groq or DeepInfra") == true)
        for engine in EngineID.cloudTranscriptionEngines {
            #expect(engine.isCloud && !engine.isLocal)
            #expect(engine.cloudAPI == .transcriptions)
            #expect(engine.badges == ["Cloud"])
            #expect(engine.approxDownloadBytes == nil)
            #expect(engine.cloudTimeout > 60 && engine.cloudTimeout < 120)
            #expect(engine.localCounterpart?.cloudCounterpart == engine)
            #expect(OpenRouterClient.engine(forModel: engine.openRouterModelID!) == engine)
        }
        #expect(EngineID.whisperCloud.acceptsLanguageHint && !EngineID.parakeetCloud.acceptsLanguageHint)
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
            settings.selectedEngine = engine
            let expected: TimeInterval = engine.cloudAPI == .chatCompletions ? 7 * 60 : 20 * 60
            #expect(settings.effectiveMaxRecordingDuration == expected, "\(engine)")
        }
    }

    @Test func slowNoticeAllowanceGrowsWithChunks() {
        #expect(DictationController.slowNoticeDelay(for: .parakeet, audioSeconds: 300) == 3)
        #expect(DictationController.slowNoticeDelay(for: .geminiFlash, audioSeconds: 300) == 12)
        #expect(DictationController.slowNoticeDelay(for: .whisperCloud, audioSeconds: 20) == 10)
        #expect(DictationController.slowNoticeDelay(for: .whisperCloud, audioSeconds: 120) == 18)
    }
}

// MARK: - Request and response

@Suite struct OpenRouterSpeechWireTests {
    @Test func requestCarriesModelAudioAndLanguageOnly() throws {
        let body = try json(OpenRouterSpeechRequest.wav(model: "openai/whisper-large-v3-turbo",
                                                        audioBase64: "UklG+/==", language: " DE ").encoded())
        #expect(Set(body.keys) == ["model", "input_audio", "language"], "no provider routing, temperature or format")
        #expect(body["model"] as? String == "openai/whisper-large-v3-turbo")
        #expect(body["language"] as? String == "de")
        let audio = try #require(body["input_audio"] as? [String: Any])
        #expect(audio["data"] as? String == "UklG+/==")
        #expect(audio["format"] as? String == "wav")
        #expect(audio.count == 2)
    }

    @Test(arguments: [nil, "", "  \n"] as [String?])
    func blankLanguageIsOmitted(_ language: String?) throws {
        let body = try json(OpenRouterSpeechRequest.wav(model: "nvidia/parakeet-tdt-0.6b-v3", audioBase64: "AA==",
                                                        language: language).encoded())
        #expect(Set(body.keys) == ["model", "input_audio"])
    }

    @Test func base64SlashesAreNotEscaped() throws {
        let raw = String(decoding: try OpenRouterSpeechRequest.wav(model: "openai/whisper-large-v3-turbo",
                                                                   audioBase64: "ab/cd+/ef==", language: nil).encoded(),
                         as: UTF8.self)
        #expect(raw.contains("ab/cd+/ef==") && raw.contains("openai/whisper-large-v3-turbo") && !raw.contains("\\/"))
    }

    @Test func successDecodesTextAndCost() throws {
        let data = Data(#"{"text":"  Hello, world. ","usage":{"seconds":9.2,"total_tokens":113,"cost":0.000508}}"#.utf8)
        let result = try OpenRouterErrorMapper.speechSuccess(data: data, engine: .whisperCloud)
        #expect(result == CloudResult(text: "Hello, world.", costUSD: 0.000508))
    }

    @Test func emptyTextIsNotAnErrorHere() throws {
        let result = try OpenRouterErrorMapper.speechSuccess(data: Data(#"{"text":""}"#.utf8), engine: .parakeetCloud)
        #expect(result.text.isEmpty)
    }

    @Test func failuresInsideA200() {
        #expect(throws: AppError.openRouterProviderUnavailable("Upstream error")) {
            try OpenRouterErrorMapper.speechSuccess(data: Data(#"{"error":{"code":502,"message":"Upstream error"}}"#.utf8),
                                                    engine: .whisperCloud)
        }
        #expect(throws: AppError.openRouterServer("OpenRouter sent no transcript.")) {
            try OpenRouterErrorMapper.speechSuccess(data: Data(#"{"usage":{"cost":0}}"#.utf8), engine: .whisperCloud)
        }
        #expect(throws: AppError.openRouterServer("OpenRouter sent a response \(Brand.name) couldn’t read.")) {
            try OpenRouterErrorMapper.speechSuccess(data: Data("<html>".utf8), engine: .whisperCloud)
        }
    }

    @Test func noRouteHintNamesTheSpeechProviders() {
        let error = OpenRouterErrorMapper.httpError(
            status: 404, data: Data(#"{"error":{"code":404,"message":"No endpoints found for openai/whisper-large-v3-turbo."}}"#.utf8),
            retryAfter: nil, engine: .whisperCloud)
        guard case .openRouterNoRoute(let message) = error else {
            Issue.record("expected no route, got \(error)")
            return
        }
        #expect(message.contains("Groq or DeepInfra"))
        #expect(!message.contains("Google"))
        #expect(OpenRouterErrorMapper.noRouteHint(for: .geminiFlash) == OpenRouterErrorMapper.noRouteHint)
    }
}

// MARK: - Client over a stubbed network

@Suite struct OpenRouterSpeechClientTests {
    private let wav = WAVEncoder.pcm16(tone(1))

    private func call(_ client: OpenRouterClient, model: String = "openai/whisper-large-v3-turbo",
                      language: String? = nil) async throws -> CloudResult {
        try await client.transcribeSpeech(wav: wav, model: model, language: language, apiKey: "sk-or-v1-test", timeout: 65)
    }

    @Test func postsToTheTranscriptionEndpoint() async throws {
        let (client, host) = StubURLProtocol.client([speechReply(" Hallo. ", cost: 0.0001, generation: "gen-abc")])
        let result = try await call(client, language: "de")
        #expect(result.text == "Hallo.")
        #expect(result.costUSD == 0.0001)
        #expect(result.generationID == "gen-abc")
        #expect(result.provider == nil)

        let request = try #require(StubURLProtocol.registry.requests(for: host).first)
        #expect(request.url?.path == "/api/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 65)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-v1-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Title") == "transcribe-thing")
        let body = try json(try #require(StubURLProtocol.registry.bodies(for: host).first))
        #expect(Set(body.keys) == ["model", "input_audio", "language"])
        #expect(body["language"] as? String == "de")
        #expect(wavSampleCount(inRequestBody: StubURLProtocol.registry.bodies(for: host)[0]) == rate)
    }

    @Test func providerHeaderIsTakenWhenPresent() async throws {
        let (client, _) = StubURLProtocol.client([speechReply("Hi.", generation: "gen-1", provider: "Groq")])
        #expect(try await call(client).provider == "Groq")
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
             .timeout(.whisperCloud)),
            (.init(error: .timedOut), .timeout(.whisperCloud)),
            (.init(error: .notConnectedToInternet), .offline),
        ]
        for (reply, expected) in cases {
            let (client, host) = StubURLProtocol.client([reply, speechReply("never")])
            await #expect(throws: expected) { try await call(client) }
            #expect(StubURLProtocol.registry.requests(for: host).count == 1, "\(expected)")
        }
    }

    @Test func oversizedChunkNeverLeavesTheMac() async throws {
        let (client, host) = StubURLProtocol.client([speechReply("never")])
        await #expect(throws: AppError.recordingTooLarge) {
            try await client.transcribeSpeech(wav: Data(count: 15_000_000), model: "nvidia/parakeet-tdt-0.6b-v3",
                                              language: nil, apiKey: "k", timeout: 65)
        }
        #expect(StubURLProtocol.registry.requests(for: host).isEmpty)
    }

    @Test func liveInvalidKeyShapeMapsToInvalidKey() {
        // Body OpenRouter returned on 2026-09-27 for `Authorization: Bearer sk-or-v1-invalid` on this endpoint.
        let error = OpenRouterErrorMapper.httpError(status: 401, data: Data(#"{"error":{"message":"User not found.","code":401}}"#.utf8),
                                                    retryAfter: nil, engine: .whisperCloud)
        #expect(error == .openRouterInvalidKey("User not found."))
    }
}

// MARK: - Generation lookup

@Suite struct OpenRouterGenerationTests {
    @Test func decodesTheProviderName() async throws {
        let (client, host) = StubURLProtocol.client([generationReply("Groq")])
        #expect(try await client.generationProvider(id: "gen-1 2", apiKey: "sk-or-v1-test") == "Groq")
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

// MARK: - Chunk boundaries

@Suite struct CloudChunkerTests {
    private func expectCovers(_ ranges: [Range<Int>], count: Int) {
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == count)
        for (a, b) in zip(ranges, ranges.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
        #expect(ranges.allSatisfy { !$0.isEmpty && $0.count <= sample(atSeconds: CloudChunker.maxChunkSeconds) })
    }

    @Test func shortRecordingsStayWhole() {
        #expect(CloudChunker.ranges(for: []) == [])
        let audio = tone(50)
        #expect(CloudChunker.ranges(for: audio) == [0..<audio.count])
    }

    @Test func cutsLandInTheQuietGaps() {
        // Talking with pauses at 44.0–44.5 s and 88.0–88.4 s, and a longer pause at 30 s that is too early to use.
        let audio = tone(30) + silence(1) + tone(13) + silence(0.5) + tone(43.5) + silence(0.4) + tone(41.6)
        let ranges = CloudChunker.ranges(for: audio)
        #expect(ranges.count == 3)
        expectCovers(ranges, count: audio.count)
        let firstCut = ranges[0].upperBound, secondCut = ranges[1].upperBound
        #expect((sample(atSeconds: 44.0)...sample(atSeconds: 44.5)).contains(firstCut), "cut at \(Double(firstCut) / 16_000) s")
        #expect((sample(atSeconds: 88.0)...sample(atSeconds: 88.4)).contains(secondCut), "cut at \(Double(secondCut) / 16_000) s")
    }

    @Test func quietGapsInSpeechAreFound() {
        let audio = babble(44) + roomNoise(0.5) + babble(43.5) + roomNoise(0.4) + babble(31.6)
        let ranges = CloudChunker.ranges(for: audio)
        #expect(ranges.count == 3)
        expectCovers(ranges, count: audio.count)
        #expect((sample(atSeconds: 44.0)...sample(atSeconds: 44.5)).contains(ranges[0].upperBound))
        #expect((sample(atSeconds: 88.0)...sample(atSeconds: 88.4)).contains(ranges[1].upperBound))
    }

    @Test func aQuietMicStillCountsAsSpeech() async throws {
        // Speech peaking near −60 dBFS: under SilenceGuard's fixed −50 dBFS bar, still voice to the recorder's analyzer.
        let quiet = babble(60).map { $0 * 0.007 }
        #expect(SilenceGuard.voicedSeconds(quiet) < SilenceGuard.minimumVoicedSeconds)
        let ranges = CloudChunker.ranges(for: quiet)
        #expect(ranges.count == 2)
        var calls = 0
        _ = try await CloudChunker.transcribe(quiet, ranges: ranges, dropsSilencePhrases: false) { _ in
            calls += 1
            return CloudResult(text: "soft words")
        }
        #expect(calls == 2)
    }

    @Test func talkingWithoutPausesStillFitsTheLimit() {
        let audio = tone(151, amplitude: 0.3)
        let ranges = CloudChunker.ranges(for: audio)
        #expect(ranges.count == 4)
        expectCovers(ranges, count: audio.count)
        #expect(ranges.dropLast().allSatisfy { $0.count >= sample(atSeconds: 40) })
    }

    @Test func theLastChunkIsNeverASliver() {
        // The quietest spot is 0.3 s before the end: cutting there would leave a scrap of audio.
        let audio = tone(50.2) + silence(0.3)
        let ranges = CloudChunker.ranges(for: audio)
        #expect(ranges.count == 2)
        expectCovers(ranges, count: audio.count)
        #expect(ranges[1].count >= sample(atSeconds: CloudChunker.minimumTailSeconds))
    }

    @Test func aSearchRegionOneWindowLongDoesNotTrap() {
        let window = Int(CloudChunker.quietWindowSeconds * 100)
        #expect(CloudChunker.quietestCut(tone(1), in: 0..<(window * 160), frame: 160, windowFrames: window)
            == window * 160 / 2)
        // 0.31 s chunks leave a first search region of exactly one 0.3 s window.
        let audio = tone(5)
        let ranges = CloudChunker.ranges(for: audio, maxSeconds: 0.31)
        #expect(ranges.first?.lowerBound == 0 && ranges.last?.upperBound == audio.count)
        for (a, b) in zip(ranges, ranges.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
        #expect(ranges.allSatisfy { !$0.isEmpty && $0.count <= sample(atSeconds: 0.31) })
    }

    @Test func chunksAreSentInOrderAndCancellationStopsBetweenThem() async throws {
        let audio = babble(120)
        let ranges = CloudChunker.ranges(for: audio)
        #expect(ranges.count == 3)

        var sent: [Int] = []
        let transcript = try await CloudChunker.transcribe(audio, ranges: ranges, dropsSilencePhrases: false) { wav in
            let count = WAVEncoder.decode(wav)?.count ?? 0
            sent.append(count)
            return CloudResult(text: " part \(sent.count) ", provider: sent.count == 2 ? "DeepInfra" : "Groq",
                               costUSD: 0.001, generationID: "gen-\(sent.count)")
        }
        #expect(sent == ranges.map(\.count))
        #expect(transcript.text == "part 1 part 2 part 3")
        #expect(transcript.providers == ["Groq", "DeepInfra"])
        #expect(transcript.generationIDs == ["gen-1", "gen-2", "gen-3"])
        #expect(abs((transcript.costUSD ?? 0) - 0.003) < 1e-12)
        #expect(transcript.requestCount == 3)

        let calls = Counter()
        let cancelled = Task {
            try await CloudChunker.transcribe(audio, ranges: ranges, dropsSilencePhrases: false) { _ in
                calls.increment()
                withUnsafeCurrentTask { $0?.cancel() }
                return CloudResult(text: "first")
            }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(calls.value == 1)
    }

    @Test func silentChunksAreSkippedAndWhisperPhrasesDropped() async throws {
        let audio = babble(45) + roomNoise(40) + silence(15)
        let ranges = CloudChunker.ranges(for: audio)
        #expect(ranges.count == 3)
        var calls = 0
        let transcript = try await CloudChunker.transcribe(audio, ranges: ranges, dropsSilencePhrases: true) { _ in
            calls += 1
            return CloudResult(text: "Real words.")
        }
        #expect(calls == 1)
        #expect(transcript.text == "Real words.")
        #expect(transcript.costUSD == nil)

        let faint = babble(0.3) + roomNoise(3)
        let dropped = try await CloudChunker.transcribe(faint, ranges: [0..<faint.count], dropsSilencePhrases: true) { _ in
            CloudResult(text: "Thanks for watching!")
        }
        #expect(dropped.text.isEmpty && dropped.requestCount == 1)
    }
}

// MARK: - TranscriptionService

@MainActor
@Suite struct CloudSpeechServiceTests {
    private func makeService(_ replies: [StubURLProtocol.Reply], language: String? = nil, key: String? = "sk-or-v1-test")
        -> (TranscriptionService, String, OpenRouterAccount) {
        let settings = AppSettings.inMemory()
        settings.whisperLanguage = language
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

    @Test func longRecordingGoesUpInOrderedChunks() async throws {
        let audio = await offMain { babble(44) + roomNoise(0.5) + babble(43.5) + roomNoise(0.4) + babble(31.6) }
        let (service, host, _) = makeService([speechReply("one", cost: 0.001, generation: "gen-1"),
                                              speechReply("two", cost: 0.002, generation: "gen-2"),
                                              speechReply("three.", generation: "gen-3")], language: "de")
        let result = try await service.transcribe(Recording(samples: audio), engine: .whisperCloud)
        #expect(result.text == "one two three.")
        #expect(result.engine == .whisperCloud)
        #expect(abs((result.costUSD ?? 0) - 0.003) < 1e-12)
        #expect(result.generationIDs == ["gen-1", "gen-2", "gen-3"])
        #expect(result.provider == nil)
        #expect(result.processingTime > 0)

        let bodies = StubURLProtocol.registry.bodies(for: host)
        #expect(bodies.count == 3)
        let fields = await offMain {
            bodies.map { body -> (model: String?, language: String?, keys: Set<String>, samples: Int?) in
                let object = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
                return (object["model"] as? String, object["language"] as? String, Set(object.keys),
                        wavSampleCount(inRequestBody: body))
            }
        }
        var total = 0
        for field in fields {
            #expect(field.model == "openai/whisper-large-v3-turbo")
            #expect(field.language == "de")
            #expect(field.keys == ["model", "input_audio", "language"])
            let count = try #require(field.samples)
            #expect(count <= sample(atSeconds: 50))
            total += count
        }
        #expect(total == audio.count)
        #expect(StubURLProtocol.registry.requests(for: host).allSatisfy { $0.url?.path == "/api/v1/audio/transcriptions" })
    }

    @Test func parakeetSendsNoLanguage() async throws {
        let (service, host, _) = makeService([speechReply("Dzień dobry.", provider: "Together")], language: "pl")
        let result = try await service.transcribe(speech(3), engine: .parakeetCloud)
        #expect(result.text == "Dzień dobry.")
        #expect(result.provider == "Together")
        let body = try json(try #require(StubURLProtocol.registry.bodies(for: host).first))
        #expect(Set(body.keys) == ["model", "input_audio"])
        #expect(body["model"] as? String == "nvidia/parakeet-tdt-0.6b-v3")
    }

    @Test func aFailedChunkFailsTheDictationAndStopsSending() async throws {
        let audio = await offMain { babble(120) }
        let (service, host, account) = makeService([
            speechReply("one"), .init(status: 402, body: #"{"error":{"code":402,"message":"Insufficient credits"}}"#),
            speechReply("never"),
        ])
        await #expect(throws: AppError.openRouterNoCredits("Insufficient credits")) {
            try await service.transcribe(Recording(samples: audio), engine: .whisperCloud)
        }
        #expect(StubURLProtocol.registry.requests(for: host).count == 2)
        #expect(account.status == .noCredit(nil))
    }

    @Test func noTextOnSpeechIsEmptyResultAndOnSilenceNoSpeech() async throws {
        let (service, _, _) = makeService([speechReply(""), speechReply("")])
        await #expect(throws: AppError.emptyResult(.parakeetCloud)) {
            try await service.transcribe(speech(2), engine: .parakeetCloud)
        }
        await #expect(throws: AppError.noSpeech) {
            try await service.transcribe(Recording(samples: silence(2)), engine: .parakeetCloud)
        }
    }

    @Test func missingKeyStopsBeforeTheNetwork() async throws {
        let (service, host, _) = makeService([speechReply("never")], key: nil)
        await #expect(throws: AppError.openRouterMissingKey) {
            try await service.transcribe(speech(1), engine: .whisperCloud)
        }
        #expect(StubURLProtocol.registry.requests(for: host).isEmpty)
    }

    @Test func servedProviderToleratesALateGenerationRecord() async throws {
        let (service, host, _) = makeService([.init(status: 404, body: #"{"error":{"code":404,"message":"Not found"}}"#),
                                              generationReply("Groq")])
        #expect(await service.servedProvider(generationIDs: ["gen-1"]) == "Groq")
        #expect(StubURLProtocol.registry.requests(for: host).count == 2)
    }

    @Test func servedProviderGivesUpQuietly() async throws {
        let notFound = StubURLProtocol.Reply(status: 404, body: #"{"error":{"code":404,"message":"Not found"}}"#)
        let (service, host, _) = makeService([notFound, notFound])
        #expect(await service.servedProvider(generationIDs: ["gen-1"]) == nil)
        #expect(StubURLProtocol.registry.requests(for: host).count == 2)

        let (failing, failingHost, _) = makeService([.init(status: 500, body: "oops"), generationReply("Groq")])
        #expect(await failing.servedProvider(generationIDs: ["gen-1"]) == nil)
        #expect(StubURLProtocol.registry.requests(for: failingHost).count == 1, "only a 404 is worth asking again")

        let (keyless, keylessHost, _) = makeService([generationReply("Groq")], key: nil)
        #expect(await keyless.servedProvider(generationIDs: ["gen-1"]) == nil)
        #expect(StubURLProtocol.registry.requests(for: keylessHost).isEmpty)
    }

    @Test func servedProviderListsEachProviderOnce() async throws {
        let (service, _, _) = makeService([generationReply("Groq"), generationReply("DeepInfra"), generationReply("Groq")])
        #expect(await service.servedProvider(generationIDs: ["gen-1", "gen-2", "gen-3"]) == "Groq, DeepInfra")
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

        store.upsert(TranscriptEntry(text: "Cześć", engine: .whisperCloud, audioDuration: 2, voicedSeconds: 1.5,
                                     processingTime: 0.8, costUSD: 0.00002, provider: "Groq"))
        store.flush()
        let raw = String(decoding: try Data(contentsOf: paths.historyFile), as: UTF8.self)
        #expect(raw.contains(#""provider":"Groq""#) && raw.contains(#""engine":"whisperCloud""#))
        #expect(raw.components(separatedBy: #""provider""#).count == 2, "absent, not null, when unknown")

        let reloaded = HistoryStore(paths: paths, settings: settings)
        reloaded.load()
        try await waitUntil { reloaded.isLoaded }
        #expect(reloaded.entries.map(\.provider) == ["Groq", nil])
    }

    @Test func deliveredCloudTranscriptLearnsItsProvider() async throws {
        let h = DictationControllerTests.make()
        var asked: [[String]] = []
        h.controller.providerLookupOverride = { ids in
            asked.append(ids)
            return "Groq"
        }
        h.controller.transcribeOverride = { _, engine in
            TranscriptResult(text: "Hallo", engine: engine, processingTime: 0.4, costUSD: 0.00001,
                             generationIDs: ["gen-1"])
        }
        h.controller.insertOverride = { _, _ in .pasted }
        let recording = DictationControllerTests.recording()
        h.controller.enqueue(recording, engine: .whisperCloud, delivery: .paste(targetPID: nil))
        try await waitUntil { h.history.entry(id: recording.id)?.provider != nil }
        #expect(h.history.entry(id: recording.id)?.provider == "Groq")
        #expect(asked == [["gen-1"]])
    }

    @Test func aProviderFromTheResponseNeedsNoLookup() async throws {
        let h = DictationControllerTests.make()
        h.controller.providerLookupOverride = { _ in
            Issue.record("no lookup when the response named the provider")
            return nil
        }
        h.controller.transcribeOverride = { _, engine in
            TranscriptResult(text: "Hallo", engine: engine, processingTime: 0.4, provider: "Together",
                             generationIDs: ["gen-1"])
        }
        h.controller.insertOverride = { _, _ in .pasted }
        let recording = DictationControllerTests.recording()
        h.controller.enqueue(recording, engine: .parakeetCloud, delivery: .paste(targetPID: nil))
        try await waitUntil { h.history.entry(id: recording.id) != nil }
        #expect(h.history.entry(id: recording.id)?.provider == "Together")
    }

    @Test func aMissingKeyRefusesCloudSpeechBeforeRecording() throws {
        let h = DictationControllerTests.make(models: [.parakeet: .ready, .whisper: .ready], keyStatus: .missing)
        h.settings.selectedEngine = .whisperCloud
        h.controller.send(.handsFreeToggle)
        #expect(h.recorder.starts == 0)
        #expect(h.controller.machine.capture == .idle)
        let notice = try #require(h.toasts.notices.first)
        #expect(notice.title == "Add your OpenRouter key")
        #expect(notice.body == "Whisper Turbo · Cloud needs a key to transcribe.")
        #expect(notice.actions.map(\.kind) == [.openHub(.models), .selectEngine(.whisper)])
    }

    @Test func aFailedCloudDictationOffersTheSameModelOnThisMacFirst() async throws {
        let h = DictationControllerTests.make(models: [.parakeet: .ready, .whisper: .ready])
        h.controller.transcribeOverride = { _, _ in throw AppError.openRouterRateLimited(retryAfter: nil) }
        let recording = DictationControllerTests.recording()
        h.controller.enqueue(recording, engine: .whisperCloud, delivery: .paste(targetPID: nil))
        try await waitUntil { h.history.entry(id: recording.id)?.status == .failed }
        let notice = try #require(h.toasts.notices.first { $0.recordingID == recording.id })
        #expect(notice.title == "Whisper Turbo · Cloud is rate-limited")
        #expect(notice.actions.contains { $0.kind == .retryWith(.whisper) })
        #expect(h.history.entry(id: recording.id)?.errorMessage == "Whisper Turbo · Cloud is rate-limited")
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
        #expect(AppError.offline.notice(recordingID: nil, fallbackEngine: nil, engine: .whisperCloud).body
            == "Whisper Turbo · Cloud needs the internet.")
        #expect(AppError.timeout(.parakeetCloud).notice(recordingID: nil, fallbackEngine: nil).body
            == "OpenRouter didn’t answer in time.")
    }
}
