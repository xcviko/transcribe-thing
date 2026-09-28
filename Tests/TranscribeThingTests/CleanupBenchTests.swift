import Foundation
import Testing
@testable import TranscribeThing

// `transcribe-thing --cleanup-bench`: arguments, which history entries it takes, and the requests it sends through
// the app's clean-up path, over a stubbed network.

private typealias Bench = EngineCLI.CleanupBench

private func arguments(_ extra: String...) -> [String] {
    ["transcribe-thing", "--cleanup-bench", "--history", "/tmp/h.json"] + extra
}

private func reply(_ content: String, model: String = "openai/gpt-6-luna-20260922", provider: String = "OpenAI",
                   cost: Double = 0.00004, reasoning: Int = 0, tier: String = "default",
                   finish: String = "stop") -> StubURLProtocol.Reply {
    let escaped = content.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
    return StubURLProtocol.Reply(body: #"""
    {"id":"gen-b","model":"\#(model)","provider":"\#(provider)","service_tier":"\#(tier)",
     "choices":[{"finish_reason":"\#(finish)","message":{"content":"\#(escaped)"}}],
     "usage":{"prompt_tokens":300,"completion_tokens":\#(reasoning + 20),"total_tokens":\#(reasoning + 320),"cost":\#(cost),
              "completion_tokens_details":{"reasoning_tokens":\#(reasoning)}},
     "openrouter_metadata":{"generation_time":640}}
    """#)
}

private func version(_ kind: TranscriptVersionKind, _ text: String,
                     effort: ReasoningEffort? = nil) -> TranscriptVersion {
    TranscriptVersion(kind: kind, text: text, metadata: TranscriptMetadata(reasoningEffort: effort))
}

private func entry(minutesAgo: Double, status: TranscriptStatus = .success,
                   _ versions: [TranscriptVersion]) -> TranscriptEntry {
    TranscriptEntry(createdAt: Date(timeIntervalSince1970: 1_790_000_000 - minutesAgo * 60),
                    engine: versions.first?.engine ?? .parakeet, status: status, audioDuration: 5,
                    voicedSeconds: 4, versions: versions)
}

@Suite struct CleanupBenchOptionsTests {
    /// `--entry` takes one entry of the history, whatever its age.
    @Test func oneEntry() throws {
        let id = UUID()
        let options = try #require(Bench.Options(["transcribe-thing", "--cleanup-bench", "--history", "/tmp/h.json",
                                                  "--model", "openai/gpt-6-luna", "--effort", "none",
                                                  "--entry", id.uuidString]))
        #expect(options.entry == id)
        #expect(Bench.Options(["transcribe-thing", "--cleanup-bench", "--history", "/tmp/h.json", "--model",
                               "openai/gpt-6-luna", "--effort", "none", "--entry", "nope"]) == nil)
    }

    @Test func parsesAModelEffortCountAndOutput() throws {
        let options = try #require(Bench.Options(arguments("--model", "openai/gpt-6-luna", "--effort", "none",
                                                           "--count", "7", "--out", "/tmp/r.json")))
        #expect(options.history.path == "/tmp/h.json")
        #expect(options.count == 7)
        #expect(options.out?.path == "/tmp/r.json")
        #expect(options.route.model == "openai/gpt-6-luna")
        #expect(options.route.effort == "none")
        #expect(options.route.budget == .off, "no thinking gets the smallest max_tokens")
        #expect(CleanupModel.maxTokens(forCharacterCount: 10, effort: .off)
                == CleanupModel.maxTokens(forCharacterCount: 10, effort: .minimal))
        #expect(options.route == CleanupModel.gpt6Luna.route, "what the app sends for Luna")
        #expect(options.route.provider == .init(only: ["openai"], allowFallbacks: false))
    }

    @Test func pinsEachModelToItsOwnProviderUnlessToldOtherwise() throws {
        let gemini = try #require(Bench.Options(arguments("--model", "google/gemini-3.5-flash-lite", "--effort", "low")))
        #expect(gemini.route == CleanupRoute(model: "google/gemini-3.5-flash-lite", effort: .low, provider: .googleAIStudio),
                "pinned to Google AI Studio like every Gemini request")
        #expect(gemini.count == 20 && gemini.out == nil)
        let azure = try #require(Bench.Options(arguments("--model", "openai/gpt-6-luna", "--effort", "none",
                                                         "--provider", "azure")))
        #expect(azure.route.provider.only == ["azure"])
        #expect(Bench.Options(arguments("--model", "mistral/small", "--effort", "low")) == nil,
                "no known provider and none given")
        #expect(Bench.Options(arguments("--model", "mistral/small", "--effort", "low", "--provider", "mistral")) != nil)
    }

    @Test func rejectsWhatItCantRun() {
        #expect(Bench.Options(arguments("--effort", "low")) == nil, "no model")
        #expect(Bench.Options(arguments("--model", "openai/gpt-6-luna")) == nil, "no effort")
        #expect(Bench.Options(arguments("--model", "openai/gpt-6-luna", "--effort", "extreme")) == nil)
        #expect(Bench.Options(arguments("--model", "gpt-6-luna", "--effort", "none")) == nil, "not a slug")
        #expect(Bench.Options(arguments("--model", "openai/gpt-6-luna", "--effort", "none", "--count", "0")) == nil)
        #expect(Bench.Options(arguments("--model", "openai/gpt-6-luna", "--effort", "none", "--count", "x")) == nil)
        #expect(Bench.Options(["transcribe-thing", "--cleanup-bench", "--model", "openai/gpt-6-luna",
                               "--effort", "none"]) == nil, "no history")
        #expect(Bench.Options(arguments("--model", "openai/gpt-6-luna", "--effort", "none", "--provider")) == nil)
    }

    @Test func levelsAboveHighGetTheMostRoom() {
        #expect(Bench.Options.budget(for: "xhigh") == .high && Bench.Options.budget(for: "max") == .high)
        #expect(Bench.Options.budget(for: "medium") == .medium)
    }

    @Test func theEngineCLIHandlesTheFlag() {
        #expect(EngineCLI.handles(["transcribe-thing", "--cleanup-bench"]))
    }
}

@Suite struct CleanupBenchSelectionTests {
    @Test func takesTheMostRecentParakeetTranscriptsWithTheirReferences() {
        let entries = [
            entry(minutesAgo: 30, [version(.transcription(.parakeet), "old one")]),
            entry(minutesAgo: 1, [version(.transcription(.geminiFlash), "Only Gemini.")]),
            entry(minutesAgo: 2, [version(.transcription(.parakeet), "  newest  "),
                                  version(.transcription(.geminiFlash), "Newest."),
                                  version(.cleanup(of: .parakeet, by: .geminiFlashLite), "Newest!", effort: .minimal),
                                  version(.cleanup(of: .parakeet, by: .gpt6Luna), "Newest, Luna.", effort: .off)]),
            entry(minutesAgo: 3, status: .failed, []),
            entry(minutesAgo: 4, [version(.transcription(.parakeet), "   ")]),
            entry(minutesAgo: 5, [version(.transcription(.parakeetCloud), "cloud parakeet")]),
            entry(minutesAgo: 10, [version(.transcription(.parakeet), "second")]),
        ]
        let items = Bench.select(entries, count: 2)
        #expect(items.map(\.parakeet) == ["newest", "second"])
        #expect(items[0].geminiFlash == "Newest." && items[0].flashLite == "Newest!")
        #expect(items[0].flashLiteEffort == "minimal")
        #expect(items[1].geminiFlash == nil && items[1].flashLite == nil)
        #expect(Bench.select(entries, count: 10).count == 3)
    }

    @Test func readsAHistoryFileAsTheAppWritesIt() throws {
        let json = #"""
        {"version":1,"entries":[
         {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","createdAt":"2026-09-27T10:00:00.000Z","status":"success",
          "audioDuration":3,"voicedSeconds":2,"engine":"parakeet","currentVersion":"parakeet",
          "versions":[{"kind":"parakeet","text":"ну привет","metadata":{"createdAt":"2026-09-27T10:00:00.000Z"}},
                      {"kind":"fromTheFuture","text":"x","metadata":{"createdAt":"2026-09-27T10:00:00.000Z"}}]},
         {"id":"nope"}
        ]}
        """#
        let entries = try HistoryStore.readEntries(from: Data(json.utf8))
        #expect(entries.count == 1)
        #expect(Bench.select(entries, count: 5).map(\.parakeet) == ["ну привет"])
    }

    @Test func summaryStatistics() {
        #expect(Bench.median([1, 2, 3]) == 2 && Bench.median([1, 2, 3, 10]) == 3 && Bench.median([]) == nil)
        #expect(Bench.percentile(Array(1...20), 0.9) == 18 && Bench.percentile([5], 0.9) == 5)
        #expect(Bench.percentile(Array(1...10), 0.9) == 9)
    }
}

@MainActor
@Suite struct CleanupBenchRunTests {
    private func service(_ replies: [StubURLProtocol.Reply]) -> (TranscriptionService, String) {
        let (client, host) = StubURLProtocol.client(replies)
        let keychain = KeychainStore.inMemory([KeychainStore.openRouterAccount: "sk-or-v1-test"])
        let account = OpenRouterAccount(keychain: keychain, client: client, debounce: .zero)
        let service = TranscriptionService(models: ModelStore.preview(states: [:]), account: account, client: client)
        return (service, host)
    }

    @Test func sendsTheAppsCleanupRequestToTheChosenModelAndRecordsEachAnswer() async throws {
        let options = try #require(Bench.Options(arguments("--model", "openai/gpt-6-luna", "--effort", "none")))
        let items = [
            Bench.Item(id: UUID(), createdAt: Date(), parakeet: "ну короче это тест", geminiFlash: "Короче, это тест.",
                       flashLite: "Короче, это тест.", flashLiteEffort: "minimal"),
            Bench.Item(id: UUID(), createdAt: Date(), parakeet: "Уже чисто."),
            Bench.Item(id: UUID(), createdAt: Date(), parakeet: "сломается"),
        ]
        let (service, host) = service([
            reply("<transcript>\nКороче, это тест.\n</transcript>"),
            reply("Уже чисто.", tier: "flex"),
            StubURLProtocol.Reply(status: 400, body: #"{"error":{"code":400,"message":"Unsupported effort"}}"#),
        ])
        var seen: [Int] = []
        let rows = await Bench.run(items, route: options.route, service: service) { index, _ in seen.append(index) }
        #expect(seen == [0, 1, 2])

        let bodies = StubURLProtocol.registry.bodies(for: host)
        #expect(bodies.count == 3, "one request each, sequentially, no retry for a 400")
        let body = try #require(JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        #expect(body["model"] as? String == "openai/gpt-6-luna")
        #expect(body["reasoning"] as? [String: AnyHashable] == ["effort": "none", "exclude": true])
        #expect(body["provider"] as? [String: AnyHashable] == ["only": ["openai"], "allow_fallbacks": false])
        #expect(body["max_tokens"] as? Int == CleanupModel.maxTokens(forCharacterCount: 18, effort: .minimal))
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == CleanupModel.systemPrompt)
        #expect(messages[1]["content"] as? String == "<transcript>\nну короче это тест\n</transcript>")

        #expect(rows[0].output == "Короче, это тест." && rows[0].identical == false)
        #expect(rows[0].costUSD == 0.00004 && rows[0].promptTokens == 300 && rows[0].completionTokens == 20)
        #expect(rows[0].reasoningTokens == 0 && rows[0].generationMs == 640 && rows[0].finishReason == "stop")
        #expect(rows[0].provider == "OpenAI" && rows[0].model == "openai/gpt-6-luna-20260922")
        #expect(rows[0].referenceGeminiFlash == "Короче, это тест." && rows[0].existingFlashLiteEffort == "minimal")
        #expect(rows[0].inputCharacters == 18 && rows[0].error == nil)
        #expect(rows[1].identical == true && rows[1].serviceTier == "flex")
        #expect(rows[2].output == nil && rows[2].identical == nil)
        #expect(rows[2].error?.hasPrefix("openRouterBadRequest") == true)

        let summary = Bench.summarize(rows)
        #expect(summary.count == 3 && summary.succeeded == 2 && summary.failures == 1)
        #expect(summary.identicalToInput == 1)
        #expect(summary.medianGenerationMs == 640 && summary.meanPromptTokens == 300)
        #expect(abs(summary.totalCostUSD - 0.00008) < 1e-12)
        #expect(abs((summary.costPerDictationUSD ?? 0) - 0.00004) < 1e-12)
        #expect(summary.providers == ["OpenAI"] && summary.serviceTiers == ["default", "flex"])
    }

    @Test func theAppsOwnCleanupGoesToLunaWithoutThinking() async throws {
        let (service, host) = service([reply("Ok.")])
        let result = try await service.cleanUp("ok", of: .parakeet)
        #expect(result.reasoningEffort == .off)
        let body = try #require(JSONSerialization.jsonObject(with: StubURLProtocol.registry.bodies(for: host)[0])
            as? [String: Any])
        #expect(body["model"] as? String == CleanupModel.gpt6Luna.openRouterModelID)
        #expect(body["reasoning"] as? [String: AnyHashable] == ["effort": "none", "exclude": true])
        #expect(body["provider"] as? [String: AnyHashable] == ["only": ["openai"], "allow_fallbacks": false])
        #expect(body["max_tokens"] as? Int == CleanupModel.maxTokens(forCharacterCount: 2, effort: .off))
    }
}
