import Foundation
import Testing
@testable import TranscribeThing

// The choice of clean-up model: Gemini 3.5 Flash Lite (the default), Gemini 3 Flash or GPT-6 Luna. What each request carries, the
// settings and their migration, and the dictation and History clean-ups made by the selected model.

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
    @Test func eachModelHasItsSlugProviderAndLevels() {
        #expect(CleanupModel.allCases == [.geminiFlashLite, .gemini3Flash, .gpt6Luna])
        #expect(CleanupModel.default == .geminiFlashLite)
        #expect(CleanupModel.geminiFlashLite.openRouterModelID == "google/gemini-3.5-flash-lite")
        #expect(CleanupModel.gpt6Luna.openRouterModelID == "openai/gpt-6-luna")
        #expect(CleanupModel.geminiFlashLite.modelName == "Gemini 3.5 Flash Lite")
        #expect(CleanupModel.gpt6Luna.modelName == "GPT-6 Luna")
        #expect(CleanupModel.geminiFlashLite.providerName == "Google AI Studio")
        #expect(CleanupModel.gpt6Luna.providerName == "OpenAI")
        #expect(CleanupModel.gpt6Luna.provider == .init(only: ["openai"], allowFallbacks: false))
        #expect(CleanupModel.geminiFlashLite.provider == .googleAIStudio)
        #expect(CleanupModel.gpt6Luna.reasoningEfforts.first == .off && CleanupModel.gpt6Luna.defaultReasoningEffort == .off)
        #expect(CleanupModel(rawValue: "geminiFlashLite") == .geminiFlashLite && CleanupModel(rawValue: "gpt6Luna") == .gpt6Luna
                && CleanupModel(rawValue: "gemini3Flash") == .gemini3Flash, "persisted names")
        // Gemini 3 Flash at Minimal: as close to no thinking as Gemini 3 goes (OpenRouter offers no "none").
        #expect(CleanupModel.gemini3Flash.openRouterModelID == "google/gemini-3-flash-preview")
        #expect(CleanupModel.gemini3Flash.modelName == "Gemini 3 Flash")
        #expect(CleanupModel.gemini3Flash.provider == .googleAIStudio)
        #expect(CleanupModel.gemini3Flash.reasoningEfforts == [.minimal, .low, .medium, .high])
        #expect(CleanupModel.gemini3Flash.defaultReasoningEffort == .minimal)
    }

    @Test(arguments: [(ReasoningEffort.off, "none"), (.low, "low"), (.medium, "medium"), (.high, "high"),
                      (.minimal, "low")])
    func lunaIsPinnedToOpenAIAtItsLevel(_ effort: ReasoningEffort, _ sent: String) throws {
        let json = try body(.cleanup(route: CleanupModel.gpt6Luna.route(effort: effort), systemPrompt: "Tidy it.",
                                     transcript: "привет"))
        #expect(Set(json.keys) == ["model", "messages", "reasoning", "provider", "max_tokens", "stream"])
        #expect(json["model"] as? String == "openai/gpt-6-luna")
        let provider = try #require(json["provider"] as? [String: Any])
        #expect(provider["only"] as? [String] == ["openai"] && provider["allow_fallbacks"] as? Bool == false)
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == sent && reasoning["exclude"] as? Bool == true)
        #expect(reasoning.count == 2)
        let level = try #require(ReasoningEffort(rawValue: sent))
        #expect(json["max_tokens"] as? Int == CleanupModel.maxTokens(forCharacterCount: 6, effort: level))
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(messages[1]["content"] as? String == "<transcript>\nпривет\n</transcript>")
    }

    @Test(arguments: [(ReasoningEffort.minimal, "minimal"), (.low, "low"), (.high, "high"), (.off, "minimal")])
    func flashLiteStaysOnGoogleAIStudio(_ effort: ReasoningEffort, _ sent: String) throws {
        let json = try body(.cleanup(route: CleanupModel.geminiFlashLite.route(effort: effort), systemPrompt: "Tidy it.",
                                     transcript: "hi"))
        #expect(json["model"] as? String == "google/gemini-3.5-flash-lite")
        let provider = try #require(json["provider"] as? [String: Any])
        #expect(provider["only"] as? [String] == ["google-ai-studio"] && provider["allow_fallbacks"] as? Bool == false)
        #expect((json["reasoning"] as? [String: Any])?["effort"] as? String == sent, "Flash Lite never gets none")
    }

    /// Gemini 3 Flash goes to Google AI Studio only, and "no thinking" is sent as Minimal.
    @Test(arguments: [(ReasoningEffort.off, "minimal"), (.minimal, "minimal"), (.medium, "medium")])
    func gemini3FlashStaysOnGoogleAIStudio(_ effort: ReasoningEffort, _ sent: String) throws {
        let json = try body(.cleanup(route: CleanupModel.gemini3Flash.route(effort: effort), systemPrompt: "Tidy it.",
                                     transcript: "hi"))
        #expect(json["model"] as? String == "google/gemini-3-flash-preview")
        let provider = try #require(json["provider"] as? [String: Any])
        #expect(provider["only"] as? [String] == ["google-ai-studio"] && provider["allow_fallbacks"] as? Bool == false)
        #expect((json["reasoning"] as? [String: Any])?["effort"] as? String == sent)
    }

    @Test func noThinkingIsSizedLikeMinimal() {
        for count in [0, 200, 7_000, 200_000] {
            #expect(CleanupModel.maxTokens(forCharacterCount: count, effort: .off)
                    == CleanupModel.maxTokens(forCharacterCount: count, effort: .minimal))
        }
        #expect(CleanupModel.maxTokens(forCharacterCount: 7_000, effort: .off) == 8_024)
    }
}

// MARK: - Settings

@MainActor
@Suite struct CleanupModelSettingsTests {
    private func defaults() -> UserDefaults {
        let name = "tt-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func settings(_ store: UserDefaults) -> AppSettings {
        AppSettings(defaults: store, microphoneProbe: { MicrophoneMigrationProbe() })
    }

    @Test func flashLiteByDefaultEachModelAtItsOwnDefault() {
        let settings = AppSettings.inMemory()
        #expect(settings.cleanupModel == .geminiFlashLite)
        #expect(settings.cleanupReasoningEffort == .low)
        #expect(settings.cleanupReasoningEffort(for: .geminiFlashLite) == .low)
        #expect(settings.cleanupReasoningEffort(for: .gpt6Luna) == .off)
    }

    @Test func eachModelKeepsItsOwnLevel() {
        let settings = AppSettings.inMemory()
        settings.cleanupReasoningEffort = .minimal
        settings.cleanupModel = .gpt6Luna
        #expect(settings.cleanupReasoningEffort == .off, "Luna's own level, not Flash Lite's")
        settings.cleanupReasoningEffort = .medium
        #expect(settings.cleanupReasoningEffort(for: .gpt6Luna) == .medium)
        #expect(settings.cleanupReasoningEffort(for: .geminiFlashLite) == .minimal)
        settings.cleanupModel = .geminiFlashLite
        #expect(settings.cleanupReasoningEffort == .minimal)
    }

    @Test func levelsStayWithinWhatTheModelOffers() {
        let settings = AppSettings.inMemory()
        settings.setCleanupReasoningEffort(.minimal, for: .gpt6Luna)
        #expect(settings.cleanupReasoningEffort(for: .gpt6Luna) == .low)
        settings.setCleanupReasoningEffort(.off, for: .geminiFlashLite)
        #expect(settings.cleanupReasoningEffort(for: .geminiFlashLite) == .minimal, "Flash Lite can't skip thinking")
    }

    @Test func theModelAndBothLevelsPersist() {
        let store = defaults()
        let first = settings(store)
        first.cleanupModel = .gpt6Luna
        first.setCleanupReasoningEffort(.high, for: .gpt6Luna)
        first.setCleanupReasoningEffort(.medium, for: .geminiFlashLite)
        let reloaded = settings(store)
        #expect(reloaded.cleanupModel == .gpt6Luna)
        #expect(reloaded.cleanupReasoningEffort(for: .gpt6Luna) == .high)
        #expect(reloaded.cleanupReasoningEffort(for: .geminiFlashLite) == .medium)
        #expect(store.string(forKey: SettingsKey.cleanupModel.defaultsKey) == "gpt6Luna")
    }

    @Test func theOldLevelBecomesFlashLitesOnce() {
        let store = defaults()
        store.set("minimal", forKey: SettingsKey.cleanupReasoningEffort.defaultsKey)
        let migrated = settings(store)
        #expect(migrated.cleanupModel == .geminiFlashLite, "nothing changes for someone who never chose")
        #expect(migrated.cleanupReasoningEffort(for: .geminiFlashLite) == .minimal)
        #expect(migrated.cleanupReasoningEffort(for: .gpt6Luna) == .off)
        #expect(store.object(forKey: SettingsKey.cleanupReasoningEffort.defaultsKey) == nil, "the old key goes")
        #expect(store.object(forKey: SettingsKey.cleanupReasoningEfforts.defaultsKey) != nil)
        let again = settings(store)
        #expect(again.cleanupReasoningEffort(for: .geminiFlashLite) == .minimal)
    }

    @Test func aNewerStoredLevelWinsOverTheOldKey() throws {
        let store = defaults()
        store.set(try JSONEncoder().encode(["geminiFlashLite": "high", "gpt6Luna": "low", "gone": "low"]),
                  forKey: SettingsKey.cleanupReasoningEfforts.defaultsKey)
        store.set("minimal", forKey: SettingsKey.cleanupReasoningEffort.defaultsKey)
        let loaded = settings(store)
        #expect(loaded.cleanupReasoningEffort(for: .geminiFlashLite) == .high)
        #expect(loaded.cleanupReasoningEffort(for: .gpt6Luna) == .low)
        #expect(store.object(forKey: SettingsKey.cleanupReasoningEffort.defaultsKey) == nil)
    }

    @Test func anUnknownStoredModelLeavesFlashLite() {
        let store = defaults()
        store.set("gpt9", forKey: SettingsKey.cleanupModel.defaultsKey)
        #expect(settings(store).cleanupModel == .geminiFlashLite)
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

    @Test func theSelectedModelGetsTheRequestAtItsOwnLevel() async throws {
        let (service, host, settings) = makeService([lunaReply("Hello.")])
        settings.cleanupReasoningEffort = .high  // Flash Lite's
        settings.cleanupModel = .gpt6Luna
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
        #expect((sent["messages"] as? [[String: Any]])?.first?["content"] as? String == CleanupModel.examplePrompt,
                "the same prompt for every model")
    }

    @Test func anExplicitModelWinsOverTheSelectedOne() async throws {
        let (service, host, settings) = makeService([lunaReply("Hi.")])
        settings.cleanupModel = .geminiFlashLite
        _ = try await service.cleanUp("hi", of: .parakeet, by: .gpt6Luna)
        let sent = try #require(JSONSerialization.jsonObject(with: StubURLProtocol.registry.bodies(for: host)[0]) as? [String: Any])
        #expect(sent["model"] as? String == "openai/gpt-6-luna")
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

    @Test func aDictationIsCleanedUpByTheSelectedModel() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        h.settings.cleanupSystemPrompt = CleanupModel.examplePrompt
        h.settings.cleanupModel = .gpt6Luna
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
        h.settings.cleanupModel = .gpt6Luna
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
        let flash = DictationController.cleanupFailureReason(.openRouterNoRoute(""), model: .geminiFlashLite)
        #expect(flash == "OpenRouter found no Google AI Studio route for your key.")
        for error in [AppError.openRouterTruncated(""), .openRouterBadRequest(""), .timeout(.parakeet)] {
            #expect(!luna(error).contains("Flash Lite") && !luna(error).contains("Gemini"), "\(error)")
        }
    }

    @Test func historyCleansUpWithEachModelOnceWhateverIsSelected() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()))
        h.settings.cleanupSystemPrompt = CleanupModel.examplePrompt
        h.settings.cleanupModel = .geminiFlashLite
        let entry = TranscriptEntry(text: "um hello", engine: .parakeet, audioDuration: 3, voicedSeconds: 2)
        h.history.upsert(entry)
        var asked = 0
        h.controller.cleanupOverride = { _, source in
            asked += 1
            return self.cleaned("Hello.", engine: source)
        }
        let luna = TranscriptVersionKind.cleanup(of: .parakeet, by: .gpt6Luna)
        h.controller.makeVersion(luna, of: entry)
        #expect(h.controller.runningVersions[entry.id] == luna)
        try await waitUntil { h.history.entry(id: entry.id)?.versions.count == 2 }
        try await waitUntil { h.controller.runningVersions.isEmpty }
        let updated = try #require(h.history.entry(id: entry.id))
        #expect(updated.currentKind == luna && updated.text == "Hello.")
        #expect(h.toasts.notices.contains { $0.title == "Cleaned up with GPT-6 Luna" })

        // Luna again only shows its version; Flash Lite can still tidy the same text.
        h.controller.showVersion(.transcription(.parakeet), of: entry.id)
        h.controller.makeVersion(luna, of: updated)
        #expect(asked == 1 && h.history.entry(id: entry.id)?.currentKind == luna)
        h.controller.makeVersion(.cleanup(of: .parakeet, by: .geminiFlashLite), of: updated)
        try await waitUntil { h.history.entry(id: entry.id)?.versions.count == 3 }
        #expect(asked == 2)
        #expect(h.history.entry(id: entry.id)?.versions.map(\.kind)
                == [.transcription(.parakeet), luna, .cleanup(of: .parakeet, by: .geminiFlashLite)])
    }
}
