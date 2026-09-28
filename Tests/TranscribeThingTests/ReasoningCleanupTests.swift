import Foundation
import Testing
@testable import TranscribeThing

// Reasoning levels per Gemini model, the metadata every cloud answer leaves behind, and the Gemini 3.5 Flash Lite
// clean-up of Parakeet transcripts: request, service, and the dictation pipeline around it.

private func object(_ body: OpenRouterChatRequest) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: body.encoded()) as? [String: Any])
}

private func chatReply(_ content: String, cost: Double = 0.0002, reasoning: Int = 120, finish: String = "stop",
                       id: String = "gen-clean-1") -> StubURLProtocol.Reply {
    let escaped = content.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
    return StubURLProtocol.Reply(body: #"""
    {"id":"\#(id)","model":"google/gemini-3.5-flash-lite","provider":"Google AI Studio",
     "choices":[{"finish_reason":"\#(finish)","message":{"content":"\#(escaped)"}}],
     "usage":{"prompt_tokens":400,"completion_tokens":\#(reasoning + 80),"total_tokens":\#(reasoning + 480),"cost":\#(cost),
              "completion_tokens_details":{"reasoning_tokens":\#(reasoning)}},
     "openrouter_metadata":{"generation_time":1850}}
    """#)
}

// MARK: - Levels

@Suite struct ReasoningEffortTests {
    @Test func levelsAreWhatOpenRouterListsPerModel() {
        #expect(EngineID.geminiFlash.reasoningEfforts == [.low, .medium, .high], "3.8 Flash can't turn thinking off")
        #expect(EngineID.geminiPro.reasoningEfforts == [.low, .medium, .high])
        #expect(CleanupModel.reasoningEfforts == [.minimal, .low, .medium, .high])
        #expect(EngineID.parakeet.reasoningEfforts.isEmpty && EngineID.parakeetCloud.reasoningEfforts.isEmpty)
        #expect(ReasoningEffort.allCases.map(\.rawValue) == ["minimal", "low", "medium", "high"], "no none")
    }

    @Test func defaults() {
        #expect(EngineID.geminiFlash.defaultReasoningEffort == .low)
        #expect(EngineID.geminiPro.defaultReasoningEffort == .high)
        #expect(EngineID.parakeet.defaultReasoningEffort == nil)
        #expect(CleanupModel.defaultReasoningEffort == .low)
    }

    @Test func anUnsupportedLevelMovesToTheNearestHigherOnATie() {
        #expect(ReasoningEffort.minimal.nearest(in: [.low, .medium, .high]) == .low)
        #expect(ReasoningEffort.medium.nearest(in: [.minimal, .high]) == .high)
        #expect(ReasoningEffort.high.nearest(in: [.minimal, .low]) == .low)
        #expect(ReasoningEffort.low.nearest(in: []) == .low)
        #expect(ReasoningEffort.medium.nearest(in: [.low, .medium]) == .medium)
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
        #expect(settings.reasoningEffort(for: .geminiFlash) == .low)
        #expect(settings.reasoningEffort(for: .geminiPro) == .high)
        #expect(settings.reasoningEffort(for: .parakeet) == nil)
        #expect(settings.cleanupReasoningEffort == .low)
        #expect(settings.cleanupSystemPrompt.isEmpty && !settings.cleanupEnabled && !settings.isCleanupActive)
    }

    @Test func levelsStayWithinWhatEachModelSupports() {
        let settings = AppSettings.inMemory()
        settings.setReasoningEffort(.minimal, for: .geminiFlash)
        #expect(settings.reasoningEffort(for: .geminiFlash) == .low)
        settings.setReasoningEffort(.medium, for: .geminiPro)
        #expect(settings.reasoningEffort(for: .geminiPro) == .medium)
        settings.setReasoningEffort(.high, for: .parakeet)
        #expect(settings.reasoningEffort(for: .parakeet) == nil)
        settings.cleanupReasoningEffort = .minimal
        #expect(settings.cleanupReasoningEffort == .minimal)
    }

    @Test func cleanUpNeedsTheSwitchAndAPrompt() {
        let settings = AppSettings.inMemory()
        settings.cleanupEnabled = true
        #expect(!settings.isCleanupActive, "an empty prompt would make the model answer the text")
        settings.cleanupSystemPrompt = "  \n "
        #expect(!settings.isCleanupActive && !settings.hasCleanupPrompt)
        settings.cleanupSystemPrompt = CleanupModel.examplePrompt
        #expect(settings.isCleanupActive)
        settings.cleanupEnabled = false
        #expect(!settings.isCleanupActive)
    }

    @Test func everythingPersists() {
        let store = defaults()
        let settings = AppSettings(defaults: store, microphoneProbe: { MicrophoneMigrationProbe() })
        settings.setReasoningEffort(.high, for: .geminiFlash)
        settings.setReasoningEffort(.medium, for: .geminiPro)
        settings.cleanupEnabled = true
        settings.cleanupSystemPrompt = "Tidy it."
        settings.cleanupReasoningEffort = .medium
        let reloaded = AppSettings(defaults: store, microphoneProbe: { MicrophoneMigrationProbe() })
        #expect(reloaded.reasoningEffort(for: .geminiFlash) == .high)
        #expect(reloaded.reasoningEffort(for: .geminiPro) == .medium)
        #expect(reloaded.cleanupEnabled && reloaded.cleanupSystemPrompt == "Tidy it.")
        #expect(reloaded.cleanupReasoningEffort == .medium)
    }

    @Test func storedLevelsAreNormalizedOnLoad() throws {
        let store = defaults()
        store.set(try JSONEncoder().encode(["geminiFlash": "minimal", "parakeet": "high", "gone": "low",
                                            "geminiPro": "extreme"]),
                  forKey: SettingsKey.reasoningEfforts.defaultsKey)
        let settings = AppSettings(defaults: store, microphoneProbe: { MicrophoneMigrationProbe() })
        #expect(settings.reasoningEffort(for: .geminiFlash) == .low)
        #expect(settings.reasoningEffort(for: .geminiPro) == .high, "an unknown level falls back to the default")
        #expect(settings.reasoningEffort(for: .parakeet) == nil)
    }
}

// MARK: - Requests

@Suite struct ReasoningRequestTests {
    @Test(arguments: [ReasoningEffort.low, .medium, .high])
    func transcriptionSendsTheLevel(_ effort: ReasoningEffort) throws {
        for model in ["google/gemini-3.8-flash", "google/gemini-3.1-pro-preview"] {
            let json = try object(.transcription(model: model, audioBase64: "AA==", systemPrompt: nil, effort: effort))
            let reasoning = try #require(json["reasoning"] as? [String: Any])
            #expect(reasoning["effort"] as? String == effort.rawValue)
            #expect(reasoning["exclude"] as? Bool == true)
            #expect(reasoning.count == 2, "effort only: no max_tokens, no enabled")
            #expect(json["reasoning_effort"] == nil)
            let provider = try #require(json["provider"] as? [String: Any])
            #expect(provider["only"] as? [String] == ["google-ai-studio"] && provider["allow_fallbacks"] as? Bool == false)
        }
    }

    @Test(arguments: ReasoningEffort.allCases)
    func cleanupIsTextInTextOutPinnedToGoogle(_ effort: ReasoningEffort) throws {
        let json = try object(.cleanup(model: CleanupModel.openRouterModelID, systemPrompt: "  Tidy it.\n",
                                       transcript: "Можешь, пожалуйста, убрать это?", effort: effort))
        #expect(Set(json.keys) == ["model", "messages", "reasoning", "provider", "max_tokens", "stream"])
        #expect(json["model"] as? String == "google/gemini-3.5-flash-lite")
        #expect(json["temperature"] == nil)
        #expect(json["stream"] as? Bool == false)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system" && messages[0]["content"] as? String == "Tidy it.")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "<transcript>\nМожешь, пожалуйста, убрать это?\n</transcript>")
        let reasoning = try #require(json["reasoning"] as? [String: Any])
        #expect(reasoning["effort"] as? String == effort.rawValue && reasoning["exclude"] as? Bool == true)
        let provider = try #require(json["provider"] as? [String: Any])
        #expect(provider["only"] as? [String] == ["google-ai-studio"] && provider["allow_fallbacks"] as? Bool == false)
        #expect(json["max_tokens"] as? Int == CleanupModel.maxTokens(forCharacterCount: 31, effort: effort))
    }

    @Test func cleanupBudgetGrowsWithTheTextAndTheLevel() {
        #expect(CleanupModel.maxTokens(forCharacterCount: 200, effort: .minimal) == 4_096)
        #expect(CleanupModel.maxTokens(forCharacterCount: 7_000, effort: .low) == 9_048)
        #expect(CleanupModel.maxTokens(forCharacterCount: 7_000, effort: .high) == 23_384)
        #expect(CleanupModel.maxTokens(forCharacterCount: 200_000, effort: .high) == 65_536)
        #expect(CleanupModel.timeout(forCharacterCount: 0) == 12)
        #expect(CleanupModel.timeout(forCharacterCount: 4_000) == 22)
        #expect(CleanupModel.timeout(forCharacterCount: 100_000) == 45)
    }

    @Test func geminiRequestsAskForOpenRouterMetadata() {
        let request = OpenRouterClient().makeTranscriptionRequest(body: Data("{}".utf8), apiKey: "k", timeout: 20)
        #expect(request.value(forHTTPHeaderField: "X-OpenRouter-Metadata") == "enabled")
    }

    @Test func theCleanedTextLosesWhatTheModelWrappedAroundIt() {
        #expect(CleanupModel.cleanedText(from: "  Hello there.  ") == "Hello there.")
        #expect(CleanupModel.cleanedText(from: "<transcript>\nПривет.\n</transcript>") == "Привет.")
        #expect(CleanupModel.cleanedText(from: "```text\nHello.\n```") == "Hello.")
        #expect(CleanupModel.cleanedText(from: "\"Hello.\"") == "Hello.")
        #expect(CleanupModel.cleanedText(from: "«Привет»") == "Привет")
        #expect(CleanupModel.cleanedText(from: #""A" and "B""#) == #""A" and "B""#, "inner quotes stay")
    }

    @Test func theExamplePromptKeepsTheLanguageAndNeverAnswers() {
        let prompt = CleanupModel.examplePrompt
        #expect(prompt.contains("<transcript>"))
        #expect(prompt.contains("never translate"))
        #expect(prompt.contains("don’t answer it") || prompt.contains("don't answer it"))
        #expect(!prompt.contains("\\\n"))
    }
}

// MARK: - Metadata from responses

@Suite struct ResponseMetadataTests {
    @Test func chatUsageIsReadInFull() throws {
        let body = #"""
        {"id":"gen-17","model":"google/gemini-3.8-flash","provider":"Google AI Studio","service_tier":"standard",
         "choices":[{"finish_reason":"stop","native_finish_reason":"STOP","message":{"content":"Текст."}}],
         "usage":{"prompt_tokens":1925,"completion_tokens":17900,"total_tokens":19825,"cost":0.0704,"is_byok":false,
                  "prompt_tokens_details":{"cached_tokens":0,"audio_tokens":1800},
                  "completion_tokens_details":{"reasoning_tokens":17700},
                  "cost_details":{"upstream_inference_cost":null}},
         "openrouter_metadata":{"generation_time":74512,"attempt":1}}
        """#
        let result = try OpenRouterErrorMapper.success(data: Data(body.utf8), engine: .geminiFlash)
        #expect(result.text == "Текст.")
        #expect(result.generationID == "gen-17" && result.model == "google/gemini-3.8-flash")
        #expect(result.provider == "Google AI Studio" && result.costUSD == 0.0704)
        #expect(result.finishReason == "stop")
        #expect(result.generationTime == 74.512)
        #expect(result.usage == TokenUsage(promptTokens: 1925, audioTokens: 1800, cachedTokens: 0,
                                           completionTokens: 17_900, reasoningTokens: 17_700, totalTokens: 19_825))
        #expect(result.usage?.outputTokens == 200)
        #expect(result.reasoningTokens == 17_700)
    }

    @Test func aBareResponseLeavesTheMetadataEmpty() throws {
        let body = #"{"choices":[{"finish_reason":"stop","message":{"content":"Hi"}}]}"#
        let result = try OpenRouterErrorMapper.success(data: Data(body.utf8), engine: .geminiPro)
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
        result.reasoningEffort = .low
        result.usage = TokenUsage(promptTokens: 10, reasoningTokens: 17_700)
        result.usedSystemPrompt = false
        result.finishReason = "stop"
        result.generationTime = 74
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let version = result.version(createdAt: date)
        #expect(version.kind == .transcription(.geminiFlash) && version.text == "Hi")
        #expect(version.metadata == TranscriptMetadata(createdAt: date, modelID: "google/gemini-3.8-flash",
                                                       provider: "Google AI Studio", generationID: "gen-1",
                                                       reasoningEffort: .low, usage: TokenUsage(promptTokens: 10, reasoningTokens: 17_700),
                                                       costUSD: 0.07, processingTime: 76, generationTime: 74,
                                                       usedSystemPrompt: false, finishReason: "stop"))
        #expect(result.version(.cleanup(of: .parakeet)).kind == .cleanup(of: .parakeet))
    }
}

// MARK: - Service

@MainActor
@Suite struct CleanupServiceTests {
    private func makeService(_ replies: [StubURLProtocol.Reply], key: String? = "sk-or-v1-test",
                             prompt: String = CleanupModel.examplePrompt)
        -> (TranscriptionService, String, AppSettings) {
        let settings = AppSettings.inMemory()
        settings.cleanupSystemPrompt = prompt
        settings.cleanupReasoningEffort = .minimal
        let store = ModelStore.preview(states: [.parakeet: .ready])
        let (client, host) = StubURLProtocol.client(replies)
        let keychain = KeychainStore.inMemory(key.map { [KeychainStore.openRouterAccount: $0] } ?? [:])
        let account = OpenRouterAccount(keychain: keychain, client: client, debounce: .zero)
        let service = TranscriptionService(models: store, account: account, client: client, settings: settings,
                                           providerLookupDelay: .milliseconds(10))
        return (service, host, settings)
    }

    @Test func cleanUpSendsThePromptAndTheTranscriptAndRecordsTheMetadata() async throws {
        let (service, host, _) = makeService([chatReply("<transcript>\nМожешь убрать это?\n</transcript>")])
        let result = try await service.cleanUp("можешь ну убрать убрать это", of: .parakeet)
        #expect(result.text == "Можешь убрать это?")
        #expect(result.engine == .parakeet)
        #expect(result.modelID == "google/gemini-3.5-flash-lite")
        #expect(result.reasoningEffort == .minimal && result.usedSystemPrompt == true)
        #expect(result.costUSD == 0.0002 && result.usage?.reasoningTokens == 120)
        #expect(result.generationID == "gen-clean-1" && result.provider == "Google AI Studio")
        #expect(result.generationTime == 1.85 && result.finishReason == "stop")

        let request = try #require(StubURLProtocol.registry.requests(for: host).first)
        #expect(request.url?.path == "/api/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-v1-test")
        let body = try #require(JSONSerialization.jsonObject(with: StubURLProtocol.registry.bodies(for: host)[0]) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == CleanupModel.examplePrompt)
        #expect(messages[1]["content"] as? String == "<transcript>\nможешь ну убрать убрать это\n</transcript>")
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "minimal")
    }

    @Test func anEmptyPromptOrNoKeyNeverReachesTheNetwork() async throws {
        let (noPrompt, host, _) = makeService([chatReply("x")], prompt: "  ")
        await #expect(throws: AppError.self) { try await noPrompt.cleanUp("text", of: .parakeet) }
        #expect(StubURLProtocol.registry.requests(for: host).isEmpty)
        let (noKey, keyHost, _) = makeService([chatReply("x")], key: nil)
        await #expect(throws: AppError.openRouterMissingKey) { try await noKey.cleanUp("text", of: .parakeet) }
        #expect(StubURLProtocol.registry.requests(for: keyHost).isEmpty)
    }

    @Test func aCutOffAnswerIsAFailureNeverText() async throws {
        let (service, _, _) = makeService([chatReply("Half a sen", finish: "length")])
        await #expect(throws: AppError.openRouterTruncated("Half a sen")) {
            try await service.cleanUp("text", of: .parakeetCloud)
        }
    }

    @Test func geminiTranscriptionRecordsItsLevelAndUsage() async throws {
        let settings = AppSettings.inMemory()
        settings.setReasoningEffort(.medium, for: .geminiPro)
        let store = ModelStore.preview(states: [.parakeet: .ready])
        let (client, host) = StubURLProtocol.client([chatReply("Hallo.", cost: 0.01, reasoning: 900, id: "gen-g")])
        let keychain = KeychainStore.inMemory([KeychainStore.openRouterAccount: "sk-or-v1-test"])
        let account = OpenRouterAccount(keychain: keychain, client: client, debounce: .zero)
        let service = TranscriptionService(models: store, account: account, client: client, settings: settings)
        let samples = (0..<16_000).map { 0.1 * sin(Float($0) * 0.09) }
        let result = try await service.transcribe(Recording(samples: samples), engine: .geminiPro)
        #expect(result.reasoningEffort == .medium && result.usedSystemPrompt == false)
        #expect(result.usage?.reasoningTokens == 900 && result.generationID == "gen-g")
        let body = try #require(JSONSerialization.jsonObject(with: StubURLProtocol.registry.bodies(for: host)[0]) as? [String: Any])
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "medium")
    }
}

// MARK: - The dictation pipeline

@MainActor
@Suite(.serialized) struct CleanupPipelineTests {
    private typealias H = DictationControllerTests

    private func harness(enabled: Bool = true, prompt: String = CleanupModel.examplePrompt) -> H.Harness {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        h.settings.cleanupEnabled = enabled
        h.settings.cleanupSystemPrompt = prompt
        return h
    }

    private func cleaned(_ text: String, cost: Double = 0.0002) -> TranscriptResult {
        var result = TranscriptResult(text: text, engine: .parakeet, processingTime: 0.9, costUSD: cost,
                                      provider: "Google AI Studio", generationID: "gen-c")
        result.modelID = CleanupModel.openRouterModelID
        result.reasoningEffort = .low
        result.usedSystemPrompt = true
        return result
    }

    /// Dictates with `engine`, returns the recording's id once the job is done.
    private func dictate(_ h: H.Harness, engine: EngineID = .parakeet, text: String = "um so like hello hello there",
                         pasted: @escaping (String) -> Void) async throws -> UUID {
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: text, engine: engine, processingTime: 0.3) }
        h.controller.insertOverride = { text, _ in pasted(text); return .pasted }
        let r = H.recording()
        h.controller.enqueue(r, engine: engine, delivery: .paste(targetPID: nil))
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id) != nil }
        return r.id
    }

    @Test func aCleanedUpDictationPastesTheCleanTextAndKeepsBothVersions() async throws {
        let h = harness()
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        var asked: [(String, EngineID)] = []
        var pillWhileCleaning: PillPhase?
        h.controller.cleanupOverride = { text, source in
            asked.append((text, source))
            pillWhileCleaning = h.pill.phase
            try await Task.sleep(for: .milliseconds(30))
            #expect(h.controller.runningVersions.values.contains(.cleanup(of: .parakeet)))
            return self.cleaned("Hello there.")
        }
        var pasted: [String] = []
        let id = try await dictate(h) { pasted.append($0) }
        #expect(pasted == ["Hello there."])
        #expect(asked.map(\.0) == ["um so like hello hello there"] && asked.map(\.1) == [.parakeet])
        #expect(pillWhileCleaning == .processing)
        let entry = try #require(h.history.entry(id: id))
        #expect(entry.versions.map(\.kind) == [.transcription(.parakeet), .cleanup(of: .parakeet)])
        #expect(entry.currentKind == .cleanup(of: .parakeet))
        #expect(entry.text == "Hello there." && entry.engine == .parakeet)
        #expect(entry.version(.transcription(.parakeet))?.text == "um so like hello hello there")
        let meta = try #require(entry.currentVersion?.metadata)
        #expect(meta.modelID == "google/gemini-3.5-flash-lite" && meta.reasoningEffort == .low)
        #expect(meta.costUSD == 0.0002 && meta.usedSystemPrompt == true)
        #expect(!h.toasts.notices.contains { $0.dedupeKey == "cleanup.fallback" })
        #expect(h.controller.runningVersions.isEmpty)
    }

    @Test(arguments: ["failure", "timeout", "empty"])
    func aCleanUpThatDoesntWorkPastesTheOriginalQuietly(_ how: String) async throws {
        let h = harness()
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        h.controller.cleanupTimeoutOverride = 0.15
        h.controller.cleanupOverride = { _, source in
            switch how {
            case "failure": throw AppError.openRouterProviderUnavailable("down")
            case "timeout":
                try await Task.sleep(for: .seconds(5))
                return self.cleaned("too late")
            default: return self.cleaned("  \n")
            }
        }
        var pasted: [String] = []
        let id = try await dictate(h) { pasted.append($0) }
        #expect(pasted == ["um so like hello hello there"])
        let entry = try #require(h.history.entry(id: id))
        #expect(entry.versions.map(\.kind) == [.transcription(.parakeet)])
        #expect(entry.text == "um so like hello hello there")
        let notice = try #require(h.toasts.notices.first { $0.dedupeKey == "cleanup.fallback" })
        #expect(notice.title == "Couldn’t clean up · pasted the original")
        #expect(notice.style == .info && notice.sound == nil && notice.actions.isEmpty)
    }

    @Test func cancelingTheCleanUpKeepsTheFinishedTranscriptInHistoryUnpasted() async throws {
        let h = harness()
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        h.controller.cleanupOverride = { _, _ in
            try await Task.sleep(for: .seconds(5))
            return self.cleaned("too late")
        }
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "raw text", engine: engine, processingTime: 0.3) }
        h.controller.insertOverride = { _, _ in Issue.record("a canceled dictation is never pasted"); return .pasted }
        let r = H.recording()
        h.controller.enqueue(r, engine: .parakeet, delivery: .paste(targetPID: nil))
        try await waitUntil { h.controller.runningVersions[r.id] == .cleanup(of: .parakeet) }
        h.controller.handle(.cancel)
        #expect(h.controller.machine.activeJobs == 0)
        let entry = try #require(h.history.entry(id: r.id))
        #expect(entry.status == .success && entry.text == "raw text")
        #expect(entry.versions.map(\.kind) == [.transcription(.parakeet)])
        let card = try #require(h.toasts.notices.first { $0.transcript == "raw text" })
        #expect(card.title == "Clean-up canceled")
        #expect(card.actions.map(\.kind) == [.pasteText("raw text"), .copyText("raw text")])
        #expect(!h.toasts.notices.contains { $0.dedupeKey == "dictation.canceled" })
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.history.entry(id: r.id)?.versions.count == 1)
    }

    @Test(arguments: [KeyStatus.missing, .invalid("User not found."), .noCredit(nil)])
    func aKeyThatCantWorkSkipsTheRequestAndPointsToModels(_ key: KeyStatus) async throws {
        let h = H.make(keyStatus: key, persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        h.settings.cleanupEnabled = true
        h.settings.cleanupSystemPrompt = CleanupModel.examplePrompt
        h.controller.cleanupOverride = { _, _ in
            Issue.record("no request with a key that can't work")
            return self.cleaned("x")
        }
        var pasted: [String] = []
        _ = try await dictate(h) { pasted.append($0) }
        #expect(pasted == ["um so like hello hello there"])
        let notice = try #require(h.toasts.notices.first { $0.dedupeKey == "cleanup.fallback" })
        #expect(notice.title == "Couldn’t clean up · pasted the original")
        #expect(notice.body == DictationController.cleanupFailureReason(
            key == .missing ? .openRouterMissingKey : key == .noCredit(nil) ? .openRouterNoCredits("") : .openRouterInvalidKey("")))
        #expect(notice.actions.map(\.kind) == [.openHub(.models)])
    }

    @Test func cleanUpFailuresSpeakOfFlashLiteAndTheText() {
        let reason = DictationController.cleanupFailureReason
        #expect(reason(.openRouterTruncated("")) == "Flash Lite stopped before finishing.")
        #expect(reason(.openRouterBadRequest("")) == "Flash Lite couldn’t process the text.")
        #expect(reason(.openRouterRefused("")) == "Flash Lite couldn’t process the text.")
        #expect(reason(.openRouterProviderUnavailable("")) == "Google AI Studio is unavailable.")
        #expect(reason(.openRouterInvalidKey("")) == "Your OpenRouter key was rejected.")
        for error in [AppError.openRouterTruncated(""), .openRouterBadRequest(""), .openRouterRefused(""),
                      .openRouterServer(""), .openRouterNoRoute(""), .openRouterRateLimited(retryAfter: nil)] {
            #expect(!reason(error).contains("Gemini") && !reason(error).contains("recording"), "\(error)")
        }
    }

    @Test func offOrWithoutAPromptNothingIsCleanedUp() async throws {
        for (enabled, prompt) in [(false, CleanupModel.examplePrompt), (true, ""), (true, "   ")] {
            let h = harness(enabled: enabled, prompt: prompt)
            defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
            h.controller.cleanupOverride = { _, _ in
                Issue.record("no clean-up")
                return self.cleaned("x")
            }
            var pasted: [String] = []
            let id = try await dictate(h) { pasted.append($0) }
            #expect(pasted == ["um so like hello hello there"])
            #expect(h.history.entry(id: id)?.versions.count == 1)
            #expect(h.toasts.notices.isEmpty)
        }
    }

    @Test func geminiDictationsAreNotCleanedUpButCloudParakeetIs() async throws {
        let h = harness()
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        var sources: [EngineID] = []
        h.controller.cleanupOverride = { _, source in
            sources.append(source)
            var result = self.cleaned("Clean.")
            result.engine = source
            return result
        }
        var pasted: [String] = []
        _ = try await dictate(h, engine: .geminiFlash, text: "Gemini text.") { pasted.append($0) }
        let cloud = try await dictate(h, engine: .parakeetCloud, text: "cloud text") { pasted.append($0) }
        #expect(pasted == ["Gemini text.", "Clean."])
        #expect(sources == [.parakeetCloud])
        #expect(h.history.entry(id: cloud)?.currentKind == .cleanup(of: .parakeetCloud))
    }

    @Test func transcribeWithFromHistoryIsNotCleanedUpAutomatically() async throws {
        let h = harness(enabled: false)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        let id = try await dictate(h, engine: .geminiFlash, text: "Gemini text.") { _ in }
        h.settings.cleanupEnabled = true
        h.controller.cleanupOverride = { _, _ in
            Issue.record("no clean-up for a new version of an existing row")
            return self.cleaned("x")
        }
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "parakeet text", engine: engine, processingTime: 0.3) }
        h.controller.makeVersion(.transcription(.parakeet), of: try #require(h.history.entry(id: id)))
        try await waitUntil { h.history.entry(id: id)?.versions.count == 2 && h.controller.machine.activeJobs == 0 }
        #expect(h.history.entry(id: id)?.currentKind == .transcription(.parakeet))
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

    @Test func cleanUpFromHistoryWorksWithoutTheAudio() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()))
        h.settings.cleanupSystemPrompt = CleanupModel.examplePrompt
        let entry = parakeetEntry()
        h.history.upsert(entry)
        var asked: [String] = []
        h.controller.cleanupOverride = { text, source in
            asked.append(text)
            try await Task.sleep(for: .milliseconds(30))
            return TranscriptResult(text: "Hello.", engine: source, processingTime: 0.8, costUSD: 0.0001)
        }
        h.controller.insertOverride = { _, _ in Issue.record("never pasted"); return .pasted }
        h.controller.makeVersion(.cleanup(of: .parakeet), of: entry)
        #expect(h.controller.runningVersions[entry.id] == .cleanup(of: .parakeet))
        // Nothing else runs for it meanwhile.
        h.controller.makeVersion(.cleanup(of: .parakeet), of: entry)
        try await waitUntil { h.history.entry(id: entry.id)?.versions.count == 2 }
        try await waitUntil { h.controller.runningVersions.isEmpty }
        #expect(asked == ["um hello hello"])
        let updated = try #require(h.history.entry(id: entry.id))
        #expect(updated.currentKind == .cleanup(of: .parakeet) && updated.text == "Hello.")
        #expect(updated.createdAt == entry.createdAt)
        let card = try #require(h.toasts.notices.first { $0.transcript == "Hello." })
        #expect(card.title == "Cleaned up with Flash Lite")
        #expect(card.actions.map(\.kind) == [.pasteText("Hello."), .copyText("Hello.")])
        #expect(h.controller.machine.activeJobs == 0, "a clean-up from History isn't a dictation job")

        // Never twice: asking again shows the version it has.
        h.controller.showVersion(.transcription(.parakeet), of: entry.id)
        h.controller.makeVersion(.cleanup(of: .parakeet), of: try #require(h.history.entry(id: entry.id)))
        #expect(asked.count == 1)
        #expect(h.history.entry(id: entry.id)?.currentKind == .cleanup(of: .parakeet))
    }

    @Test func aFailedCleanUpFromHistoryLeavesTheRowAndSaysWhy() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()))
        h.settings.cleanupSystemPrompt = CleanupModel.examplePrompt
        h.controller.cleanupTimeoutOverride = 0.1
        let entry = parakeetEntry()
        h.history.upsert(entry)
        h.controller.cleanupOverride = { _, _ in
            try await Task.sleep(for: .seconds(5))
            return TranscriptResult(text: "late", engine: .parakeet, processingTime: 5)
        }
        h.controller.makeVersion(.cleanup(of: .parakeet), of: entry)
        try await waitUntil { h.toasts.notices.contains { $0.title == "Couldn’t clean up" } }
        #expect(h.history.entry(id: entry.id) == entry)
        #expect(h.toasts.notices.first { $0.title == "Couldn’t clean up" }?.body == "Flash Lite took too long.")
        try await waitUntil { h.controller.runningVersions.isEmpty }
    }

    @Test func cleanUpFromHistoryWithoutAPromptPointsToTheSetting() {
        let h = H.make(keyStatus: .valid(KeyInfo()))
        let entry = parakeetEntry()
        h.history.upsert(entry)
        h.controller.cleanupOverride = { _, _ in
            Issue.record("no request without a prompt")
            return TranscriptResult(text: "x", engine: .parakeet, processingTime: 0)
        }
        h.controller.makeVersion(.cleanup(of: .parakeet), of: entry)
        #expect(h.toasts.notices.first?.title == "Clean-up needs a prompt")
        #expect(h.controller.runningVersions.isEmpty)
    }

    @Test func theSameModelNeverTranscribesARecordingTwice() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        var runs: [EngineID] = []
        h.controller.transcribeOverride = { _, engine in
            runs.append(engine)
            return TranscriptResult(text: "text by \(engine.rawValue)", engine: engine, processingTime: 0.2)
        }
        h.controller.insertOverride = { _, _ in .pasted }
        let r = H.recording()
        h.controller.enqueue(r, engine: .parakeet, delivery: .paste(targetPID: nil))
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id) != nil }
        h.controller.makeVersion(.transcription(.geminiFlash), of: try #require(h.history.entry(id: r.id)))
        try await waitUntil { h.history.entry(id: r.id)?.versions.count == 2 && h.controller.machine.activeJobs == 0 }
        h.controller.showVersion(.transcription(.parakeet), of: r.id)
        h.controller.makeVersion(.transcription(.geminiFlash), of: try #require(h.history.entry(id: r.id)))
        h.controller.retry(try #require(h.history.entry(id: r.id)), with: .parakeet)
        #expect(h.controller.machine.activeJobs == 0)
        #expect(runs == [.parakeet, .geminiFlash])
        #expect(h.history.entry(id: r.id)?.currentKind == .transcription(.parakeet), "the version it has is shown")
    }

    @Test func theSlowNoticeOfTranscribeWithNeverOffersAModelTheRowHas() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        var runs: [EngineID] = []
        h.controller.transcribeOverride = { _, engine in
            runs.append(engine)
            if engine == .geminiPro { try await Task.sleep(for: .milliseconds(400)) }
            return TranscriptResult(text: "text by \(engine.rawValue)", engine: engine, processingTime: 0.2)
        }
        h.controller.insertOverride = { _, _ in .pasted }
        let r = H.recording()
        h.controller.enqueue(r, engine: .parakeet, delivery: .paste(targetPID: nil))
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id) != nil }
        h.controller.slowNoticeDelayOverride = 0.05
        h.controller.makeVersion(.transcription(.geminiPro), of: try #require(h.history.entry(id: r.id)))
        try await waitUntil { h.toasts.notices.contains { $0.dedupeKey == "slow.\(r.id)" } }
        let slow = try #require(h.toasts.notices.first { $0.dedupeKey == "slow.\(r.id)" })
        #expect(!slow.actions.contains { $0.kind == .retryWith(.parakeet) })
        // Even an action that names it (an older notice) doesn't run Parakeet again on the queued job.
        h.controller.perform(NoticeAction(title: "Use Parakeet v3 Instead", kind: .retryWith(.parakeet)), from: slow)
        try await waitUntil { h.history.entry(id: r.id)?.versions.count == 2 && h.controller.machine.activeJobs == 0 }
        #expect(runs == [.parakeet, .geminiPro])
        #expect(h.history.entry(id: r.id)?.version(.transcription(.parakeet))?.text == "text by parakeet")
        #expect(h.history.entry(id: r.id)?.currentKind == .transcription(.geminiPro))
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
        h.controller.insertOverride = { _, _ in .pasted }
        let r = H.recording()
        h.controller.enqueue(r, engine: .parakeetCloud, delivery: .paste(targetPID: nil))
        try await waitUntil { h.history.entry(id: r.id)?.provider != nil }
        let meta = try #require(h.history.entry(id: r.id)?.currentVersion?.metadata)
        #expect(meta.provider == "Together" && meta.latency == 0.4 && meta.generationTime == 0.35)
        #expect(meta.costUSD == 0.00001 && meta.generationID == "gen-1")
        #expect(asked == ["gen-1"])
    }
}
