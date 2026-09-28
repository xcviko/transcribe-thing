import Foundation
import Testing
@testable import TranscribeThing

// The clean-up model: GPT-6 Luna, always without thinking; Gemini 3.5 Flash Lite is retired. What each request
// carries, and the dictation and History clean-ups Luna makes.

private func lunaReply(_ content: String) -> StubURLProtocol.Reply {
    StubURLProtocol.Reply(body: #"""
    {"id":"gen-luna","model":"openai/gpt-6-luna","provider":"OpenAI","service_tier":"default",
     "choices":[{"finish_reason":"stop","message":{"content":"\#(content)"}}],
     "usage":{"prompt_tokens":400,"completion_tokens":20,"total_tokens":420,"cost":0.00006}}
    """#)
}

private func body(_ request: OpenRouterChatRequest) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
}

// MARK: - Models and requests

@Suite struct CleanupModelRoutingTests {
    @Test func lunaIsTheOneThatRunsFlashLiteIsRetired() {
        #expect(CleanupModel.allCases == [.geminiFlashLite, .gpt6Luna], "Flash Lite stays readable")
        #expect(CleanupModel.offered == [.gpt6Luna])
        #expect(CleanupModel.default == .gpt6Luna)
        #expect(CleanupModel.geminiFlashLite.isRetired && !CleanupModel.gpt6Luna.isRetired)
        #expect(CleanupModel.gpt6Luna.openRouterModelID == "openai/gpt-6-luna")
        #expect(CleanupModel.gpt6Luna.modelName == "GPT-6 Luna" && CleanupModel.gpt6Luna.shortName == "GPT-6 Luna")
        #expect(CleanupModel.geminiFlashLite.modelName == "Gemini 3.5 Flash Lite")
        #expect(CleanupModel.geminiFlashLite.shortName == "Flash Lite")
        #expect(CleanupModel.gpt6Luna.providerName == "OpenAI")
        #expect(CleanupModel.gpt6Luna.provider == .init(only: ["openai"], allowFallbacks: false))
        #expect(CleanupModel.gpt6Luna.reasoningEffort == .off)
        #expect(CleanupModel.geminiFlashLite.reasoningEffort == nil && CleanupModel.geminiFlashLite.route == nil,
                "a retired model has no request")
        #expect(CleanupModel(rawValue: "geminiFlashLite") == .geminiFlashLite && CleanupModel(rawValue: "gpt6Luna") == .gpt6Luna,
                "persisted names")
    }

    @Test func lunaAlwaysSendsNoneAndIsPinnedToOpenAI() throws {
        let route = try #require(CleanupModel.gpt6Luna.route)
        let json = try body(.cleanup(route: route, systemPrompt: "Tidy it.", transcript: "привет"))
        #expect(Set(json.keys) == ["model", "messages", "reasoning", "provider", "max_tokens", "stream"])
        #expect(json["model"] as? String == "openai/gpt-6-luna")
        let provider = try #require(json["provider"] as? [String: Any])
        #expect(provider["only"] as? [String] == ["openai"] && provider["allow_fallbacks"] as? Bool == false)
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == "none" && reasoning["exclude"] as? Bool == true)
        #expect(reasoning.count == 2)
        #expect(json["max_tokens"] as? Int == CleanupModel.maxTokens(forCharacterCount: 6, effort: .off))
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(messages[1]["content"] as? String == "<transcript>\nпривет\n</transcript>")
    }

    /// `EngineCLI --clean-up-effort`: another level, sent as given, with `max_tokens` sized for it.
    @Test(arguments: [(ReasoningEffort.low, "low"), (.medium, "medium"), (.high, "high"), (.minimal, "minimal")])
    func anotherLevelForLunaIsSentAsGiven(_ effort: ReasoningEffort, _ sent: String) throws {
        let json = try body(.cleanup(route: CleanupModel.gpt6Luna.route(effort: effort), systemPrompt: "Tidy it.",
                                     transcript: "hi"))
        #expect(json["model"] as? String == "openai/gpt-6-luna")
        #expect((json["reasoning"] as? [String: Any])?["effort"] as? String == sent)
        #expect(json["max_tokens"] as? Int == CleanupModel.maxTokens(forCharacterCount: 2, effort: effort))
    }

    @Test func noThinkingIsSizedLikeMinimal() {
        for count in [0, 200, 7_000, 200_000] {
            #expect(CleanupModel.maxTokens(forCharacterCount: count, effort: .off)
                    == CleanupModel.maxTokens(forCharacterCount: count, effort: .minimal))
        }
        #expect(CleanupModel.maxTokens(forCharacterCount: 7_000, effort: .off) == 8_024)
    }
}

// MARK: - Service

@MainActor
@Suite struct CleanupModelServiceTests {
    private func makeService(_ replies: [StubURLProtocol.Reply]) -> (TranscriptionService, String, AppSettings) {
        let settings = AppSettings.inMemory()
        let store = ModelStore.preview(states: [.parakeet: .ready])
        let (client, host) = StubURLProtocol.client(replies)
        let keychain = KeychainStore.inMemory([KeychainStore.openRouterAccount: "sk-or-v1-test"])
        let account = OpenRouterAccount(keychain: keychain, client: client, debounce: .zero)
        let service = TranscriptionService(models: store, account: account, client: client, settings: settings,
                                           providerLookupDelay: .milliseconds(10))
        return (service, host, settings)
    }

    @Test func lunaGetsTheRequestWithoutThinking() async throws {
        let (service, host, _) = makeService([lunaReply("Hello.")])
        let result = try await service.cleanUp("hello", of: .parakeet)
        #expect(result.text == "Hello.")
        #expect(result.modelID == "openai/gpt-6-luna" && result.provider == "OpenAI")
        #expect(result.reasoningEffort == .off)
        #expect(result.version(.cleanup(of: .parakeet, by: .gpt6Luna)).metadata.reasoningEffort == .off)
        let sent = try #require(JSONSerialization.jsonObject(with: StubURLProtocol.registry.bodies(for: host)[0]) as? [String: Any])
        #expect(sent["model"] as? String == "openai/gpt-6-luna")
        #expect((sent["provider"] as? [String: Any])?["only"] as? [String] == ["openai"])
        #expect((sent["provider"] as? [String: Any])?["allow_fallbacks"] as? Bool == false)
        #expect((sent["reasoning"] as? [String: Any])?["effort"] as? String == "none")
        #expect(sent["max_tokens"] as? Int == CleanupModel.maxTokens(forCharacterCount: 5, effort: .off))
        #expect((sent["messages"] as? [[String: Any]])?.first?["content"] as? String == CleanupModel.examplePrompt)
    }

    @Test func aRetiredModelNeverRuns() async throws {
        let (service, host, _) = makeService([lunaReply("Hi.")])
        await #expect(throws: AppError.self) { try await service.cleanUp("hi", of: .parakeet, by: .geminiFlashLite) }
        #expect(StubURLProtocol.registry.requests(for: host).isEmpty)
    }
}

// MARK: - Dictation and History

@MainActor
@Suite(.serialized) struct CleanupModelPipelineTests {
    private typealias H = DictationControllerTests

    private func cleaned(_ text: String, engine: EngineID = .parakeet) -> TranscriptResult {
        var result = TranscriptResult(text: text, engine: engine, processingTime: 1.1, costUSD: 0.00006,
                                      provider: "OpenAI", generationID: "gen-luna")
        result.modelID = CleanupModel.gpt6Luna.openRouterModelID
        result.reasoningEffort = .off
        result.usedSystemPrompt = true
        return result
    }

    @Test func aDictationIsCleanedUpByLuna() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        h.settings.cleanupSystemPrompt = CleanupModel.examplePrompt
        var running: [TranscriptVersionKind] = []
        h.controller.cleanupOverride = { _, _ in
            running.append(contentsOf: h.controller.runningVersions.values)
            return self.cleaned("Hello there.")
        }
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "um hello there", engine: engine, processingTime: 0.3) }
        var pasted: [String] = []
        h.controller.insertOverride = { text, _ in pasted.append(text); return .pasted }
        let r = H.recording()
        h.controller.enqueue(r, engine: .parakeet, delivery: .paste(targetPID: nil), cleansUp: true)
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id) != nil }
        #expect(pasted == ["Hello there."])
        #expect(running == [.cleanup(of: .parakeet, by: .gpt6Luna)])
        let entry = try #require(h.history.entry(id: r.id))
        #expect(entry.versions.map(\.kind) == [.transcription(.parakeet), .cleanup(of: .parakeet, by: .gpt6Luna)])
        #expect(entry.currentVersion?.metadata.reasoningEffort == .off)
    }

    @Test func aFailedCleanUpNamesTheModelThatTried() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        h.settings.cleanupSystemPrompt = CleanupModel.examplePrompt
        h.controller.cleanupOverride = { _, _ in throw AppError.openRouterTruncated("") }
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "raw", engine: engine, processingTime: 0.3) }
        h.controller.insertOverride = { _, _ in .pasted }
        let r = H.recording()
        h.controller.enqueue(r, engine: .parakeet, delivery: .paste(targetPID: nil), cleansUp: true)
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id) != nil }
        let notice = try #require(h.toasts.notices.first { $0.dedupeKey == "cleanup.fallback" })
        #expect(notice.title == "Couldn’t clean up · pasted the original")
        #expect(notice.body == "GPT-6 Luna stopped before finishing.")
    }

    @Test func failureReasonsNameTheModelAndItsProvider() {
        let luna = { (error: AppError?) in DictationController.cleanupFailureReason(error, model: .gpt6Luna) }
        #expect(luna(nil) == "GPT-6 Luna returned no text.")
        #expect(luna(.timeout(.parakeet)) == "GPT-6 Luna took too long.")
        #expect(luna(.openRouterProviderUnavailable("")) == "OpenAI is unavailable.")
        #expect(luna(.openRouterNoRoute("")) == "OpenRouter found no OpenAI route for your key.")
        #expect(luna(.openRouterBadRequest("")) == "GPT-6 Luna couldn’t process the text.")
        #expect(luna(.openRouterRefused("")) == "GPT-6 Luna couldn’t process the text.")
        #expect(luna(.openRouterInvalidKey("")) == "Your OpenRouter key was rejected.")
        for error in [AppError.openRouterTruncated(""), .openRouterBadRequest(""), .openRouterRefused(""),
                      .openRouterServer(""), .openRouterNoRoute(""), .openRouterRateLimited(retryAfter: nil),
                      .timeout(.parakeet)] {
            #expect(!luna(error).contains("Flash Lite") && !luna(error).contains("Gemini")
                    && !luna(error).contains("recording"), "\(error)")
        }
    }

    /// An entry Flash Lite already tidied can still get Luna's clean-up; both stay in its Versions menu.
    @Test func historyCleansUpWithLunaOnceBesideFlashLitesVersion() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()))
        h.settings.cleanupSystemPrompt = CleanupModel.examplePrompt
        var entry = TranscriptEntry(text: "um hello", engine: .parakeet, audioDuration: 3, voicedSeconds: 2)
        let flashLite = TranscriptVersionKind.cleanup(of: .parakeet, by: .geminiFlashLite)
        entry.addVersion(TranscriptVersion(kind: flashLite, text: "Hello", metadata: TranscriptMetadata()))
        h.history.upsert(entry)
        var asked = 0
        h.controller.cleanupOverride = { _, source in
            asked += 1
            return self.cleaned("Hello.", engine: source)
        }
        let luna = TranscriptVersionKind.cleanup(of: .parakeet, by: .gpt6Luna)
        h.controller.makeVersion(luna, of: entry)
        #expect(h.controller.runningVersions[entry.id] == luna)
        try await waitUntil { h.history.entry(id: entry.id)?.versions.count == 3 }
        try await waitUntil { h.controller.runningVersions.isEmpty }
        let updated = try #require(h.history.entry(id: entry.id))
        #expect(updated.currentKind == luna && updated.text == "Hello.")
        #expect(updated.versions.map(\.kind) == [.transcription(.parakeet), flashLite, luna])
        #expect(h.toasts.notices.contains { $0.title == "Cleaned up with GPT-6 Luna" })

        // Luna again only shows its version.
        h.controller.showVersion(.transcription(.parakeet), of: entry.id)
        h.controller.makeVersion(luna, of: updated)
        #expect(asked == 1 && h.history.entry(id: entry.id)?.currentKind == luna)
    }
}
