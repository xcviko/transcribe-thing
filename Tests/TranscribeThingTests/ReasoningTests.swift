import Foundation
import Testing
@testable import TranscribeThing

// The fixed reasoning level of each model, the metadata every cloud answer leaves behind, and the text request
// Polish Selection sends: request and service.

private func object(_ body: OpenRouterChatRequest) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: body.encoded()) as? [String: Any])
}

/// A streamed answer with its usage and timing in the accounting chunk, as OpenRouter sends it.
private func chatReply(_ content: String, cost: Double = 0.0002, reasoning: Int = 0, reasoningText: String? = nil,
                       finish: String = "stop", id: String = "gen-text-1", model: String = "google/gemini-3.8-flash",
                       provider: String = "Google AI Studio") -> StubURLProtocol.Reply {
    .stream(SSE.answer(content, reasoning: reasoningText, finish: finish, id: id, model: model, provider: provider,
                       usage: #"{"prompt_tokens":400,"completion_tokens":\#(reasoning + 80),"total_tokens":\#(reasoning + 480),"cost":\#(cost),"completion_tokens_details":{"reasoning_tokens":\#(reasoning)}}"#,
                       generationTime: 1850))
}

// MARK: - Levels

@Suite struct ReasoningEffortTests {
    @Test func eachGeminiOffersLowMediumAndHighAndStartsAtMedium() {
        for engine in EngineID.geminiEngines {
            #expect(engine.reasoningEfforts == [.low, .medium, .high], "no Minimal, no None")
            #expect(engine.defaultReasoningEffort == .medium)
        }
        for engine in [EngineID.parakeet, .parakeetCloud, .geminiArgon, .geminiPro] {
            #expect(engine.reasoningEfforts.isEmpty && engine.defaultReasoningEffort == nil, "\(engine)")
        }
        #expect(ReasoningEffort.allCases.map(\.rawValue) == ["none", "minimal", "low", "medium", "high"])
        #expect(ReasoningEffort.off.title == "None" && ReasoningEffort.medium.title == "Medium")
    }
}

@MainActor
@Suite struct ReasoningSettingsTests {
    private func defaults() -> UserDefaults {
        let name = "tt-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func freshSettings() {
        let settings = AppSettings.inMemory()
        #expect(settings.lineup.steps == [.gemini], "Gemini is the Switch model step")
    }

    /// The prompts Models used to edit are fixed in code now, and clean-up is gone. Whatever an older build stored (a
    /// cleared prompt, one of the user's own) is removed at load.
    @Test(arguments: ["", "Tidy it."])
    func promptsAnOlderBuildStoredAreRemovedAtLoad(_ stored: String) {
        let store = defaults()
        store.set(stored, forKey: SettingsKey.geminiSystemPrompt.defaultsKey)
        store.set(stored, forKey: SettingsKey.cleanupSystemPrompt.defaultsKey)
        let settings = AppSettings(defaults: store, microphoneProbe: { MicrophoneMigrationProbe() })
        #expect(store.object(forKey: SettingsKey.geminiSystemPrompt.defaultsKey) == nil)
        #expect(store.object(forKey: SettingsKey.cleanupSystemPrompt.defaultsKey) == nil)
        #expect(settings.lineup.steps == [.gemini])
    }

    @Test func everythingPersists() {
        let store = defaults()
        let settings = AppSettings(defaults: store, microphoneProbe: { MicrophoneMigrationProbe() })
        settings.lineup.setSwitchable(.gemini, false)
        let reloaded = AppSettings(defaults: store, microphoneProbe: { MicrophoneMigrationProbe() })
        #expect(!reloaded.lineup.isSwitchable(.gemini))
    }

    /// No level stored: Gemini thinks at Medium. A level it doesn't take (Minimal, a newer build's) leaves its Medium;
    /// the old per-model key from an older build goes. A level picked sticks.
    @Test func levelsDefaultToMediumAndReadLeniently() throws {
        let fresh = AppSettings(defaults: defaults(), microphoneProbe: { MicrophoneMigrationProbe() })
        #expect(fresh.reasoningEffort(for: .geminiFlash) == .medium)
        #expect(fresh.reasoningEffort(for: .parakeet) == nil)

        let store = defaults()
        store.set(try JSONEncoder().encode(["geminiFlash": "minimal", "parakeet": "low", "geminiFuture": "high"]),
                  forKey: SettingsKey.geminiReasoningEfforts.defaultsKey)
        store.set(try JSONEncoder().encode(["geminiFlash": "low"]), forKey: SettingsKey.reasoningEfforts.defaultsKey)
        let settings = AppSettings(defaults: store, microphoneProbe: { MicrophoneMigrationProbe() })
        #expect(settings.reasoningEffort(for: .geminiFlash) == .medium)
        #expect(settings.reasoningEffort(for: .parakeet) == nil)
        #expect(store.object(forKey: SettingsKey.reasoningEfforts.defaultsKey) == nil)
        settings.reasoningEfforts[.geminiFlash] = .minimal
        settings.reasoningEfforts[.geminiFlash] = .off
        #expect(settings.reasoningEffort(for: .geminiFlash) == .medium, "levels it doesn't take are refused")
        settings.reasoningEfforts[.geminiFlash] = .high
        #expect(AppSettings(defaults: store, microphoneProbe: { MicrophoneMigrationProbe() })
                    .reasoningEffort(for: .geminiFlash) == .high)
    }
}

// MARK: - The level on the wire

@MainActor
@Suite struct ReasoningLevelRequestTests {
    private func service(_ replies: [StubURLProtocol.Reply]) -> (TranscriptionService, String) {
        let (client, host) = StubURLProtocol.client(replies)
        let account = OpenRouterAccount(keyStore: .inMemory("sk-or-v1-test"), client: client, debounce: .zero)
        return (TranscriptionService(models: ModelStore.preview(states: [:]), account: account, client: client), host)
    }

    private let speech = Recording(samples: [Float](repeating: 0.1, count: 16_000))

    private func json(_ body: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// Gemini goes with its slug, at the level picked for it, pinned to Google AI Studio, with its stall timeout;
    /// High thinks longer, so it gets more room.
    @Test func geminiGoesWithItsSlugAndItsLevel() async throws {
        let (service, host) = service([.stream(SSE.answer("<transcript>High.</transcript>")),
                                       .stream(SSE.answer("<transcript>Low.</transcript>"))])
        var level = ReasoningEffort.high
        service.reasoningEffort = { $0 == .geminiFlash ? level : nil }
        let high = try await service.transcribe(speech, engine: .geminiFlash)
        level = .low
        let low = try await service.transcribe(speech, engine: .geminiFlash)
        #expect(high.text == "High." && high.reasoningEffort == .high && high.engine == .geminiFlash)
        #expect(low.text == "Low." && low.reasoningEffort == .low)
        let bodies = try StubURLProtocol.registry.bodies(for: host).map(json)
        #expect(bodies.map { $0["model"] as? String } == ["google/gemini-3.8-flash", "google/gemini-3.8-flash"])
        #expect(bodies.map { ($0["reasoning"] as? [String: Any])?["effort"] as? String } == ["high", "low"])
        #expect(bodies.allSatisfy { ($0["provider"] as? [String: Any])?["only"] as? [String] == ["google-ai-studio"] })
        #expect(bodies.map { $0["max_tokens"] as? Int } == [32_768 + 16_384, 32_768], "high thinks longer")
        #expect(StubURLProtocol.registry.requests(for: host).map(\.timeoutInterval) == [120, 120])
        #expect(high.metadata().modelID == "google/gemini-3.8-flash" && high.metadata().reasoningEffort == .high)
    }

    /// `--effort` (or any caller's own level) wins over the one picked.
    @Test func anExplicitLevelWins() async throws {
        let (service, host) = service([.stream(SSE.answer("<transcript>x</transcript>"))])
        service.reasoningEffort = { _ in .high }
        _ = try await service.transcribe(speech, engine: .geminiFlash, effort: .low)
        let body = try json(try #require(StubURLProtocol.registry.bodies(for: host).first))
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "low")
    }

    /// Without the app's settings (the CLI) Gemini thinks at its default, Medium.
    @Test func theDefaultLevelIsMedium() {
        let (service, _) = service([])
        #expect(service.reasoningEffort(.geminiFlash) == .medium)
        #expect(service.reasoningEffort(.parakeet) == nil)
    }

    /// A selection goes at the level it's asked for, Medium by default.
    @Test func polishSelectionGoesAtTheModelsLevel() throws {
        let route = try #require(PolishSelectionModel.geminiFlash.route(effort: .high))
        #expect(route.model == "google/gemini-3.8-flash" && route.effort == "high" && route.streamsReasoning)
        #expect(PolishSelectionModel.geminiFlash.route?.effort == "medium")
        #expect(PolishSelectionModel.gpt6Luna.route(effort: .high) == nil)
    }

    @Test func aTranscriptionsBudgetGrowsAtHigh() {
        #expect(OpenRouterClient.transcriptionMaxTokens(audioSeconds: 60, effort: .low) == 32_768)
        #expect(OpenRouterClient.transcriptionMaxTokens(audioSeconds: 60, effort: .medium) == 32_768)
        #expect(OpenRouterClient.transcriptionMaxTokens(audioSeconds: 60, effort: .high) == 49_152)
        #expect(OpenRouterClient.transcriptionMaxTokens(audioSeconds: 3_600, effort: .high) == 65_536)
    }
}

// MARK: - Calls

@MainActor
@Suite struct CallModelRequestTests {
    private func json(_ body: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// The audio request and the summary's text request go to Gemini 3.8 Flash at the level calls go at, read as each
    /// request goes.
    @Test func bothRequestsFollowTheCallModel() async throws {
        let (client, host) = StubURLProtocol.client([.stream(SSE.answer("[00:00-00:02] Anna: Hi.")),
                                                     .stream(SSE.answer("<summary>Hi.</summary>")),
                                                     .stream(SSE.answer("[00:00-00:02] Anna: Hi."))])
        let account = OpenRouterAccount(keyStore: .inMemory("sk-or-v1-test"), client: client, debounce: .zero)
        let settings = AppSettings.inMemory()
        settings.reasoningEfforts[.geminiFlash] = .high
        let send = CallTranscriber.openRouter(client: client, account: account, model: { settings.callModel })
        let sendText = CallTranscriber.openRouterText(client: client, account: account, model: { settings.callModel })
        _ = try await send(Data([1, 2]), "Transcribe the call.", 2, nil)
        _ = try await sendText("Anna: Hi.", "Sum it up.")
        settings.reasoningEfforts[.geminiFlash] = .low
        _ = try await send(Data([1, 2]), "Transcribe the call.", 2, nil)
        let bodies = try StubURLProtocol.registry.bodies(for: host).map(json)
        #expect(bodies.map { $0["model"] as? String } == Array(repeating: "google/gemini-3.8-flash", count: 3))
        #expect(bodies.map { ($0["reasoning"] as? [String: Any])?["effort"] as? String } == ["high", "high", "low"])
        #expect(StubURLProtocol.registry.requests(for: host).first?.timeoutInterval == 120)
    }

    /// Through the user's endpoint too: the same slug, which it takes without "google/".
    @Test func theProxyGetsTheCallModel() async throws {
        let (proxy, proxyHost) = ProxyFixture.proxy([.stream(SSE.answer("[00:00-00:02] Sam: Hi.")),
                                                     .stream(SSE.answer("Summary."))])
        let (client, openRouterHost) = StubURLProtocol.client([])
        let account = OpenRouterAccount(keyStore: .inMemory(nil), client: client, debounce: .zero)
        let model = CallModel(engine: .geminiFlash, effort: .low)
        let send = CallTranscriber.openRouter(client: client, account: account, proxy: proxy, model: { model })
        let sendText = CallTranscriber.openRouterText(client: client, account: account, proxy: proxy, model: { model })
        _ = try await send(Data([1, 2]), "The call.", 2, nil)
        _ = try await sendText("Sam: Hi.", "Sum it up.")
        let bodies = try StubURLProtocol.registry.bodies(for: proxyHost).map(json)
        #expect(bodies.map { $0["model"] as? String } == ["google/gemini-3.8-flash", "google/gemini-3.8-flash"])
        #expect(bodies.map { ($0["reasoning"] as? [String: Any])?["effort"] as? String } == ["low", "low"])
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).isEmpty)
    }

    @Test func theDefaultCallModelIsFlashAtMedium() {
        #expect(CallModel.default == CallModel(engine: .geminiFlash, effort: .medium))
        #expect(AppSettings.inMemory().callModel == .default)
        #expect(CallModel.default.modelID == "google/gemini-3.8-flash")
    }
}

// MARK: - Requests

@Suite struct ReasoningRequestTests {
    @Test(arguments: [ReasoningEffort.low, .medium, .high])
    func transcriptionSendsTheLevel(_ effort: ReasoningEffort) throws {
        let json = try object(.transcription(model: "google/gemini-3.8-flash", audioBase64: "AA==", format: "wav",
                                             systemPrompt: nil, effort: effort, maxTokens: 32_768))
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == effort.rawValue)
        #expect(reasoning["exclude"] as? Bool == false, "its thought summaries stream, for the pill's count")
        #expect(reasoning.count == 2, "effort only: no max_tokens, no enabled")
        #expect(json["reasoning_effort"] == nil)
        let provider = try #require(json["provider"] as? [String: Any])
        #expect(provider["only"] as? [String] == ["google-ai-studio"] && provider["allow_fallbacks"] as? Bool == false)
    }

    /// Polish Selection's request: Gemini 3.8 Flash on Google AI Studio, thinking at medium with its thoughts
    /// streamed, the text as plain user text in tags.
    @Test func aTextRequestIsTextInTextOutPinnedToGoogle() throws {
        let route = try #require(PolishSelectionModel.geminiFlash.route)
        let json = try object(.text(route: route, systemPrompt: "  Polish it.\n", text: "Можешь, пожалуйста, убрать это?"))
        #expect(Set(json.keys) == ["model", "messages", "reasoning", "provider", "max_tokens", "stream"])
        #expect(json["model"] as? String == "google/gemini-3.8-flash")
        #expect(json["temperature"] == nil)
        #expect(json["stream"] as? Bool == true)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system" && messages[0]["content"] as? String == "Polish it.")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "<transcript>\nМожешь, пожалуйста, убрать это?\n</transcript>")
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "medium" && reasoning["exclude"] as? Bool == false)
        let provider = try #require(json["provider"] as? [String: Any])
        #expect(provider["only"] as? [String] == ["google-ai-studio"] && provider["allow_fallbacks"] as? Bool == false)
        #expect(json["max_tokens"] as? Int == TextRoute.maxTokens(forCharacterCount: 31, effort: .medium))
    }

    @Test func aTextRequestsBudgetGrowsWithTheTextAndTheLevel() {
        #expect(TextRoute.maxTokens(forCharacterCount: 200, effort: .minimal) == 4_096)
        #expect(TextRoute.maxTokens(forCharacterCount: 7_000, effort: .low) == 9_048)
        #expect(TextRoute.maxTokens(forCharacterCount: 7_000, effort: .medium) == 15_192)
        #expect(TextRoute.maxTokens(forCharacterCount: 7_000, effort: .high) == 23_384)
        #expect(TextRoute.maxTokens(forCharacterCount: 100_000, effort: .off) == 101_024)
        #expect(TextRoute.maxTokens(forCharacterCount: 200_000, effort: .high) == 128_000)
        for count in [0, 200, 7_000, 200_000] {
            #expect(TextRoute.maxTokens(forCharacterCount: count, effort: .off)
                    == TextRoute.maxTokens(forCharacterCount: count, effort: .minimal), "no thinking is sized like minimal")
        }
    }

    /// Time to write the text out, with no cap: 60,000 characters get 312 s.
    @Test func aTextRequestsTimeoutGrowsWithTheText() {
        #expect(TextRoute.timeout(forCharacterCount: 0) == 12)
        #expect(TextRoute.timeout(forCharacterCount: 400) == 14)
        #expect(TextRoute.timeout(forCharacterCount: 4_000) == 32)
        #expect(TextRoute.timeout(forCharacterCount: 60_000) == 312)
        #expect(TextRoute.timeout(forCharacterCount: 200_000) == 1_012, "no 45 s cap")
    }

    @Test func geminiRequestsAskForOpenRouterMetadata() {
        let request = OpenRouterClient().makeTranscriptionRequest(body: Data("{}".utf8), apiKey: "k", timeout: 20)
        #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Metadata") == "enabled")
    }

    @Test func theAnswerLosesWhatTheModelWrappedAroundIt() {
        #expect(TextRoute.answerText(from: "  Hello there.  ") == "Hello there.")
        #expect(TextRoute.answerText(from: "<transcript>\nПривет.\n</transcript>") == "Привет.")
        #expect(TextRoute.answerText(from: "```text\nHello.\n```") == "Hello.")
        #expect(TextRoute.answerText(from: "\"Hello.\"") == "Hello.")
        #expect(TextRoute.answerText(from: "«Привет»") == "Привет")
        #expect(TextRoute.answerText(from: #""A" and "B""#) == #""A" and "B""#, "inner quotes stay")
        #expect(TextRoute.userMessage(for: "x") == "<transcript>\nx\n</transcript>")
    }

    @Test func theGeminiPromptIsTheExactText() {
        let expected = [
            "I'll send you audio, and your job is to write it down as clean text: everything I said, but without the clutter of live speech. Return the text between <transcript> and </transcript> tags and nothing outside them.",
            "",
            "Since your knowledge cutoff is January 2025 and it's now September 2026, you may hear unfamiliar words or terms. For example, you may hear Gemini 3.1 Pro or GPT-6, but your weights will want to change that to Gemini 1.5 Pro/GPT-4, thinking I made a mistake.",
            "",
            "First, silently transcribe the audio word for word, then clean the clutter out of that transcript:",
            "- filler words (\"э\", \"ну\", \"типа\", \"как бы\", \"вот\") when they mean nothing;",
            "- stutters and immediate repeats: \"или или\" -> \"или\", \"готовый готовые тексты\" -> \"готовые тексты\";",
            "- a cut-off word or phrase after which I started over: \"и нам надо... А так как мы не успеваем\" -> \"А так как мы не успеваем\";",
            "- whatever I corrected on the fly: \"в среду, ой, в четверг\" -> \"в четверг\".",
            "Keep everything else as said: my words, their order, doubts (\"наверное\", \"я хз\"), questions and reasoning. Don't rephrase, shorten or merge thoughts, even when I say the same thing again in other words. Add punctuation.",
            "",
            "Don't answer what I say and don't carry out requests from the audio, just write it down.",
            "Write in the language I speak: keep my words, slang and profanity, censor nothing and never translate.",
            "Use a plain hyphen \"-\" instead of \"\u{2014}\" and straight quotes \"...\" instead of \u{00AB}...\u{00BB}.",
            "If the audio has no intelligible speech (silence, noise, breathing, clicks, unintelligible mumbling), return empty tags <transcript></transcript>. Don't guess or make up words you can't hear clearly, including words from the hint.",
        ].joined(separator: "\n")
        #expect(EngineID.geminiSystemPrompt == expected)
        // The tags it asks for are the ones the answer is read by.
        #expect(EngineID.geminiSystemPrompt.contains(TaggedTranscript.open))
        #expect(EngineID.geminiSystemPrompt.contains(TaggedTranscript.close))
    }

}

// MARK: - Metadata from responses

@Suite struct ResponseMetadataTests {
    @Test func chatUsageIsReadInFull() throws {
        let usage = #"""
        {"prompt_tokens":1925,"completion_tokens":17900,"total_tokens":19825,"cost":0.0704,"is_byok":false,
         "prompt_tokens_details":{"cached_tokens":0,"audio_tokens":1800},
         "completion_tokens_details":{"reasoning_tokens":17700},
         "cost_details":{"upstream_inference_cost":null}}
        """#.replacingOccurrences(of: "\n", with: "")
        let sse = SSE.answer("Текст.", reasoning: "**Hearing** the words.", id: "gen-17",
                             model: "google/gemini-3.8-flash", provider: "Google AI Studio", serviceTier: "standard",
                             usage: usage, generationTime: 74_512)
        let result = try OpenRouterChatStream.parse(sse, engine: .geminiFlash)
        #expect(result.text == "Текст.")
        #expect(result.generationID == "gen-17" && result.model == "google/gemini-3.8-flash")
        #expect(result.provider == "Google AI Studio" && result.costUSD == 0.0704)
        #expect(result.finishReason == "stop" && result.serviceTier == "standard")
        #expect(result.generationTime == 74.512)
        #expect(result.usage == TokenUsage(promptTokens: 1925, audioTokens: 1800, cachedTokens: 0,
                                           completionTokens: 17_900, reasoningTokens: 17_700, totalTokens: 19_825))
        #expect(result.usage?.outputTokens == 200)
        #expect(result.reasoningTokens == 17_700)
        #expect(result.reasoningCharacters == "**Hearing** the words.".count)
    }

    @Test func aBareStreamLeavesTheMetadataEmpty() throws {
        let sse = SSE.stream([SSE.chunk(id: nil, content: "Hi"), SSE.chunk(id: nil, finish: "stop")])
        let result = try OpenRouterChatStream.parse(sse, engine: .geminiFlash)
        #expect(result == CloudResult(text: "Hi", finishReason: "stop"))
    }

    @Test func theGenerationRecordAddsTimingAndProvider() throws {
        let body = #"""
        {"data":{"id":"gen-17","upstream_id":"x","total_cost":0.0704,"provider_name":"Google AI Studio","latency":71234,
                 "generation_time":74512.5,"moderation_latency":null,"tokens_prompt":1925,"tokens_completion":17900,
                 "native_tokens_prompt":1925,"native_tokens_completion":17900,"native_tokens_reasoning":17700,
                 "native_tokens_cached":0,"finish_reason":"stop","streamed":false,"api_type":"completions"}}
        """#
        let generation = try JSONDecoder().decode(OpenRouterDataEnvelope<OpenRouterGeneration>.self, from: Data(body.utf8)).data
        #expect(generation.details == GenerationDetails(provider: "Google AI Studio", costUSD: 0.0704, latency: 71.234,
                                                        generationTime: 74.5125, reasoningTokens: 17_700))
    }

    @Test func aResultBecomesAVersionWithEverything() {
        var result = TranscriptResult(text: "Hi", engine: .geminiFlash, processingTime: 76, costUSD: 0.07,
                                      provider: "Google AI Studio", generationID: "gen-1")
        result.modelID = "google/gemini-3.8-flash"
        result.reasoningEffort = .medium
        result.usage = TokenUsage(promptTokens: 10, reasoningTokens: 17_700)
        result.usedSystemPrompt = false
        result.finishReason = "stop"
        result.generationTime = 74
        result.timeToFirstToken = 61.5
        result.reasoningCharacters = 2_300
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let version = result.version(createdAt: date)
        #expect(version.kind == .transcription(.geminiFlash) && version.text == "Hi")
        #expect(version.metadata == TranscriptMetadata(createdAt: date, modelID: "google/gemini-3.8-flash",
                                                       provider: "Google AI Studio", generationID: "gen-1",
                                                       reasoningEffort: .medium, usage: TokenUsage(promptTokens: 10, reasoningTokens: 17_700),
                                                       costUSD: 0.07, processingTime: 76, timeToFirstToken: 61.5,
                                                       generationTime: 74, usedSystemPrompt: false,
                                                       finishReason: "stop", reasoningCharacters: 2_300))
    }
}

// MARK: - Service

@MainActor
@Suite struct TextRequestServiceTests {
    private func makeService(_ replies: [StubURLProtocol.Reply],
                             key: String? = "sk-or-v1-test") -> (TranscriptionService, String) {
        let store = ModelStore.preview(states: [.parakeet: .ready])
        let (client, host) = StubURLProtocol.client(replies)
        let keyStore = KeyFileStore.inMemory(key)
        let account = OpenRouterAccount(keyStore: keyStore, client: client, debounce: .zero)
        let service = TranscriptionService(models: store, account: account, client: client,
                                           providerLookupDelay: .milliseconds(10))
        return (service, host)
    }

    private var route: TextRoute { PolishSelectionModel.geminiFlash.route! }

    @Test func polishTextSendsThePromptAndTheTextAndRecordsTheMetadata() async throws {
        let (service, host) = makeService([chatReply("<transcript>\nМожешь убрать это?\n</transcript>")])
        let result = try await service.polishText("можешь ну убрать убрать это", route: route, prompt: " Polish it.\n")
        #expect(result.text == "Можешь убрать это?")
        #expect(result.engine == .geminiFlash)
        #expect(result.modelID == "google/gemini-3.8-flash")
        #expect(result.reasoningEffort == .medium && result.usedSystemPrompt == true)
        #expect(result.costUSD == 0.0002 && result.usage?.reasoningTokens == 0)
        #expect(result.generationID == "gen-text-1" && result.provider == "Google AI Studio")
        #expect(result.generationTime == 1.85 && result.finishReason == "stop")

        let request = try #require(StubURLProtocol.registry.requests(for: host).first)
        #expect(request.url?.path == "/api/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-v1-test")
        let body = try #require(JSONSerialization.jsonObject(with: StubURLProtocol.registry.bodies(for: host)[0]) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(messages[0]["content"] as? String == "Polish it.")
        #expect(messages[1]["content"] as? String == "<transcript>\nможешь ну убрать убрать это\n</transcript>")
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "medium")
    }

    /// An empty prompt would have the model answer the text instead of working on it.
    @Test func anEmptyPromptOrNoKeyNeverReachesTheNetwork() async throws {
        let (noPrompt, host) = makeService([chatReply("x")])
        await #expect(throws: AppError.self) { try await noPrompt.polishText("text", route: self.route, prompt: "  ") }
        #expect(StubURLProtocol.registry.requests(for: host).isEmpty)
        let (noKey, keyHost) = makeService([chatReply("x")], key: nil)
        await #expect(throws: AppError.openRouterMissingKey) {
            try await noKey.polishText("text", route: self.route, prompt: "Polish it.")
        }
        #expect(StubURLProtocol.registry.requests(for: keyHost).isEmpty)
    }

    /// A long answer writes for longer than its deadline: once it streams it runs to its end, instead of being paid
    /// for and thrown away.
    @Test func anAnswerThatKeepsWritingIsNeverCutOff() async throws {
        let words = ["Это ", "длинный ", "текст, ", "который ", "пишется ", "долго."]
        let sse = SSE.stream(words.map { SSE.chunk(id: "gen-long", content: $0) }
            + [SSE.chunk(id: "gen-long", finish: "stop")])
        let (service, _) = makeService([.stream(sse, pieceInterval: 0.1)])
        let started = ContinuousClock.now
        let result = try await service.polishText("raw", route: route, prompt: "Polish it.", timeout: 0.3)
        #expect(result.text == words.joined())
        #expect(started.duration(to: .now) > .milliseconds(500), "it wrote well past the deadline")
    }

    /// An answer that never starts gives up at the deadline (or its stall timeout, the same value).
    @Test func anAnswerThatNeverStartsGivesUp() async throws {
        let (service, _) = makeService([.stream(": OPENROUTER PROCESSING\n\n", staysOpen: true)])
        let started = ContinuousClock.now
        let error = await #expect(throws: AppError.self) {
            try await service.polishText("raw", route: self.route, prompt: "Polish it.", timeout: 0.3)
        }
        guard case .timeout? = error else {
            Issue.record("expected a timeout, got \(String(describing: error))")
            return
        }
        #expect(started.duration(to: .now) < .seconds(10), "never left waiting")
    }

    @Test func aCutOffAnswerIsAFailureNeverText() async throws {
        let (service, _) = makeService([chatReply("Half a sen", finish: "length")])
        await #expect(throws: AppError.openRouterTruncated("Half a sen")) {
            try await service.polishText("text", route: self.route, prompt: "Polish it.")
        }
    }

    /// Gemini 3.8 Flash always thinks at medium: there's no setting that could change it. Its streamed answer
    /// leaves the same record History always kept, and now how soon it started writing and how much it showed of
    /// its thinking.
    @Test func geminiTranscriptionThinksAtMediumAndRecordsItsUsage() async throws {
        let store = ModelStore.preview(states: [.parakeet: .ready])
        let (client, host) = StubURLProtocol.client([chatReply("Hallo.", cost: 0.01, reasoning: 900,
                                                               reasoningText: "**Listening** for German.", id: "gen-g",
                                                               model: "google/gemini-3.8-flash",
                                                               provider: "Google AI Studio")])
        let keyStore = KeyFileStore.inMemory("sk-or-v1-test")
        let account = OpenRouterAccount(keyStore: keyStore, client: client, debounce: .zero)
        let service = TranscriptionService(models: store, account: account, client: client)
        let samples = (0..<16_000).map { 0.1 * sin(Float($0) * 0.09) }
        let log = ProgressLog()
        let result = try await service.transcribe(Recording(samples: samples), engine: .geminiFlash,
                                                  progress: { log.record($0) })
        #expect(result.reasoningEffort == .medium && result.usedSystemPrompt == true)
        #expect(result.usage?.reasoningTokens == 900 && result.generationID == "gen-g")
        #expect(log.all.last == ChatStreamProgress(reasoningCharacters: "**Listening** for German.".count,
                                                   outputCharacters: "Hallo.".count))
        let metadata = result.version().metadata
        #expect(metadata.usage?.reasoningTokens == 900 && metadata.usage?.completionTokens == 980)
        #expect(metadata.costUSD == 0.01 && metadata.provider == "Google AI Studio")
        #expect(metadata.generationID == "gen-g" && metadata.generationTime == 1.85)
        #expect(metadata.modelID == "google/gemini-3.8-flash" && metadata.finishReason == "stop")
        #expect(metadata.reasoningCharacters == "**Listening** for German.".count)
        let firstToken = try #require(metadata.timeToFirstToken)
        #expect(firstToken >= 0 && firstToken <= result.processingTime)
        let body = try #require(JSONSerialization.jsonObject(with: StubURLProtocol.registry.bodies(for: host)[0]) as? [String: Any])
        #expect(body["model"] as? String == "google/gemini-3.8-flash")
        #expect(body["reasoning"] as? [String: AnyHashable] == ["effort": "medium", "exclude": false])
        #expect(body["stream"] as? Bool == true)
    }
}

// MARK: - History versions

@MainActor
@Suite(.serialized) struct HistoryVersionControllerTests {
    private typealias H = DictationControllerTests

    private func parakeetEntry(audio: Bool = false) -> TranscriptEntry {
        TranscriptEntry(text: "um hello hello", engine: .parakeet, audioDuration: 3, voicedSeconds: 2, processingTime: 0.3,
                        audioFileName: audio ? "gone.wav" : nil)
    }

    /// Clean-up is gone: asking History for one (nothing offers it any more) makes nothing and runs nothing.
    @Test func aCleanUpIsNeverMadeFromHistory() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()))
        let entry = parakeetEntry()
        h.history.upsert(entry)
        h.controller.transcribeOverride = { _, _ in
            Issue.record("nothing runs")
            return TranscriptResult(text: "x", engine: .parakeet, processingTime: 0)
        }
        h.controller.makeVersion(.cleanup(of: .parakeet, by: .gpt6Luna), of: entry)
        #expect(h.controller.runningVersions.isEmpty && h.controller.homeFailures.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.history.entry(id: entry.id) == entry)
        #expect(h.toasts.notices.isEmpty)
    }

    @Test func theSameModelNeverTranscribesARecordingTwice() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        var runs: [EngineID] = []
        h.controller.transcribeOverride = { _, engine in
            runs.append(engine)
            return TranscriptResult(text: "text by \(engine.rawValue)", engine: engine, processingTime: 0.2)
        }
        h.controller.insertOverride = { _ in .pasted }
        let r = H.recording()
        h.controller.enqueue(r, engine: .parakeet)
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id) != nil }
        h.controller.makeVersion(.transcription(.geminiFlash), of: try #require(h.history.entry(id: r.id)))
        try await waitUntil { h.history.entry(id: r.id)?.versions.count == 2 && h.controller.runningVersions.isEmpty }
        h.controller.showVersion(.transcription(.parakeet), of: r.id)
        h.controller.makeVersion(.transcription(.geminiFlash), of: try #require(h.history.entry(id: r.id)))
        h.controller.retry(try #require(h.history.entry(id: r.id)), with: .parakeet)
        #expect(h.controller.runningVersions.isEmpty)
        #expect(runs == [.parakeet, .geminiFlash])
        #expect(h.history.entry(id: r.id)?.currentKind == .transcription(.parakeet), "the version it has is shown")
    }

    @Test func aCloudVersionLearnsItsProviderAndTimingLater() async throws {
        let h = H.make()
        var asked: [String] = []
        h.controller.generationLookupOverride = { id in
            asked.append(id)
            return GenerationDetails(provider: "Together", costUSD: 0.00001, latency: 0.4, generationTime: 0.35)
        }
        h.controller.transcribeOverride = { _, engine in
            TranscriptResult(text: "Hallo", engine: engine, processingTime: 0.4, generationID: "gen-1")
        }
        h.controller.insertOverride = { _ in .pasted }
        let r = H.recording()
        h.controller.enqueue(r, engine: .geminiFlash)
        try await waitUntil { h.history.entry(id: r.id)?.provider != nil }
        let meta = try #require(h.history.entry(id: r.id)?.currentVersion?.metadata)
        #expect(meta.provider == "Together" && meta.latency == 0.4 && meta.generationTime == 0.35)
        #expect(meta.costUSD == 0.00001 && meta.generationID == "gen-1")
        #expect(asked == ["gen-1"])
    }

    /// A streamed answer names its provider in every chunk, but its timing only in OpenRouter's metadata: when that
    /// never came, the generation record fills it in, leaving what the stream said as it was.
    @Test func aStreamedVersionWithoutItsTimingLearnsItLater() async throws {
        let h = H.make()
        var asked: [String] = []
        h.controller.generationLookupOverride = { id in
            asked.append(id)
            return GenerationDetails(provider: "Google AI Studio (other)", costUSD: 9, latency: 3.2, generationTime: 2.9)
        }
        h.controller.transcribeOverride = { _, engine in
            var result = TranscriptResult(text: "Hallo", engine: engine, processingTime: 3.4, costUSD: 0.004,
                                          provider: "Google AI Studio", generationID: "gen-s")
            result.usage = TokenUsage(promptTokens: 900, completionTokens: 400, reasoningTokens: 380)
            return result
        }
        h.controller.insertOverride = { _ in .pasted }
        let r = H.recording()
        h.controller.enqueue(r, engine: .geminiFlash)
        try await waitUntil { h.history.entry(id: r.id)?.currentVersion?.metadata.generationTime != nil }
        let meta = try #require(h.history.entry(id: r.id)?.currentVersion?.metadata)
        #expect(meta.generationTime == 2.9 && meta.latency == 3.2)
        #expect(meta.provider == "Google AI Studio" && meta.costUSD == 0.004, "what the stream said stays")
        #expect(asked == ["gen-s"])
    }
}
