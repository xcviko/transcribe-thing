import Foundation
import Testing
@testable import TranscribeThing

// Gemini 4 Hydrogen, Google's newer Flash-class model, between Flash and Carbon: its engine and choice, its Reasoning
// levels and stall timeout, the lineup and Pasting rules it joins, its requests, the pill's estimate, the CLI and
// dictations on it.

private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suite = "transcribe-thing-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

@MainActor
private func load(_ defaults: UserDefaults) -> AppSettings {
    AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() })
}

private func json(_ body: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

// MARK: - Engine and choice

@Suite struct HydrogenModelTests {
    @Test func hydrogenIsAGeminiOfItsOwnBetweenFlashAndCarbon() {
        #expect(EngineID.geminiHydrogen.rawValue == "geminiHydrogen" && ModelChoice.hydrogen.rawValue == "hydrogen")
        #expect(EngineID.geminiEngines == [.geminiFlash, .geminiHydrogen, .geminiCarbon])
        #expect(ModelChoice.allCases.filter(\.isGemini) == [.gemini, .hydrogen, .carbon])
        let hydrogen = EngineID.geminiHydrogen
        #expect(hydrogen.isGemini && hydrogen.isCloud && !hydrogen.isLocal && !hydrogen.isRetired)
        #expect(hydrogen.modelName == "Gemini 4 Hydrogen" && hydrogen.displayName == "Gemini 4 Hydrogen")
        #expect(hydrogen.shortName == "Gemini 4 Hydrogen" && hydrogen.glyph == "H")
        #expect(hydrogen.openRouterModelID == "google/gemini-4-hydrogen" && hydrogen.provider == "Google AI Studio")
        #expect(hydrogen.providerLine == "Google · via OpenRouter" && hydrogen.badges == ["Cloud"])
        #expect(hydrogen.factLine == "Newer than Flash · faster on long dictations · about 2× Flash’s price per token")
        #expect(hydrogen.approxDownloadBytes == nil)
        #expect(OpenRouterClient.engine(forModel: "google/gemini-4-hydrogen") == .geminiHydrogen)
        #expect(ModelChoice.hydrogen.modelName == "Gemini 4 Hydrogen" && ModelChoice.hydrogen.shortName == "Hydrogen")
        #expect(ModelChoice.hydrogen.chipName == "Gemini 4 Hydrogen"
                && ModelChoice.hydrogen.compactName == "Gemini 4 Hydrogen")
        #expect(ModelChoice.sentenceList([.gemini, .hydrogen, .carbon]) == ("Flash, Hydrogen and Carbon", true))
    }

    /// A drop and a glyph of its own: no other model's symbol, letter or default color.
    @Test func itsMarksAreItsOwn() {
        let others = ModelChoice.allCases.filter { $0 != .hydrogen }
        #expect(ModelChoice.hydrogen.symbolName == "drop.fill" && EngineID.geminiHydrogen.symbolName == "drop.fill")
        #expect(!others.map(\.symbolName).contains("drop.fill"))
        #expect(!EngineID.allCases.filter { $0 != .geminiHydrogen }.map(\.symbolName).contains("drop.fill"))
        #expect(!EngineID.allCases.filter { $0 != .geminiHydrogen }.map(\.glyph).contains("H"))
        #expect(ModelChoice.hydrogen.defaultColor == .pink)
        #expect(!others.map(\.defaultColor).contains(.pink))
    }

    /// Hydrogen is Hydrogen wherever a job or History names it; Flash stays Gemini.
    @Test func choicesAndEnginesMapBothWays() {
        #expect(ModelChoice(engine: .geminiHydrogen) == .hydrogen && ModelChoice.hydrogen.engine == .geminiHydrogen)
        #expect(ModelChoice(engine: .geminiFlash) == .gemini && ModelChoice(engine: .geminiCarbon) == .carbon)
        #expect(ModelChoice(stored: "hydrogen") == .hydrogen)
        #expect(ModelChoice.read(["gemini", "hydrogen"]) == [.gemini, .hydrogen])
    }

    /// History keeps Hydrogen's versions under its name.
    @Test func historyKindsNameHydrogen() {
        for kind in [TranscriptVersionKind.transcription(.geminiHydrogen), .polish(by: .geminiHydrogen),
                     .translation(polished: true, by: .geminiHydrogen)] {
            #expect(TranscriptVersionKind(rawValue: kind.rawValue) == kind, "\(kind.rawValue)")
            #expect(kind.dictationModel == .hydrogen)
        }
        #expect(TranscriptVersionKind.polish(by: .geminiHydrogen).rawValue == "polish:geminiHydrogen")
        #expect(TranscriptVersionKind.polish(by: .geminiHydrogen).displayName == "Polished by Gemini 4 Hydrogen")
        #expect(TranscriptVersionKind.rewrites.filter { $0.engine == .geminiHydrogen }
                == [.polish(by: .geminiHydrogen), .translation(polished: false, by: .geminiHydrogen)])
    }

    /// Hydrogen offers Low, Medium and High, never Minimal (it refuses it) or None, and thinks at Medium until picked.
    @Test func hydrogenThinksAtMediumAndRefusesMinimal() {
        #expect(EngineID.geminiHydrogen.reasoningEfforts == [.low, .medium, .high])
        #expect(EngineID.geminiHydrogen.defaultReasoningEffort == .medium)
        #expect(ReasoningEfforts.default[.geminiHydrogen] == .medium)
        #expect(ReasoningEfforts.default[.geminiCarbon] == .low && ReasoningEfforts.default[.geminiFlash] == .medium)
    }

    /// Two minutes of silence before it's a stall, as Flash; an answer without tags is still words, as Flash's.
    @Test func hydrogenWaitsAsFlashAndNeedsNoTags() {
        #expect(EngineID.geminiHydrogen.cloudTimeout == 120)
        #expect(!EngineID.geminiHydrogen.answerNeedsTags)
        #expect(EngineID.allCases.filter(\.answerNeedsTags) == [.geminiCarbon])
    }

    /// A stored level for Hydrogen is read; none leaves its Medium; Minimal or None leaves its Medium too.
    @Test func storedLevelsAreReadPerModel() throws {
        let decode = { (raw: String) throws -> ReasoningEfforts in
            try JSONDecoder().decode(ReasoningEfforts.self, from: Data(raw.utf8))
        }
        let old = try decode(#"{"geminiCarbon":"high","geminiFlash":"low"}"#)
        #expect(old[.geminiHydrogen] == .medium && old[.geminiFlash] == .low && old[.geminiCarbon] == .high,
                "stored before Hydrogen")
        let picked = try decode(#"{"geminiFlash":"low","geminiHydrogen":"high"}"#)
        #expect(picked[.geminiHydrogen] == .high && picked[.geminiFlash] == .low)
        var levels = try decode(#"{"geminiHydrogen":"minimal"}"#)
        #expect(levels[.geminiHydrogen] == .medium)
        levels[.geminiHydrogen] = .minimal
        levels[.geminiHydrogen] = .off
        #expect(levels[.geminiHydrogen] == .medium, "levels it doesn't take are refused")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(String(decoding: try encoder.encode(ReasoningEfforts.default), as: UTF8.self)
                == #"{"geminiCarbon":"low","geminiFlash":"medium","geminiHydrogen":"medium"}"#)
    }

    /// When Hydrogen can't answer, a dictation falls back to the models on this Mac, as from any Gemini.
    @MainActor @Test func itFallsBackToTheModelsOnThisMac() {
        #expect(DictationController.fallbackCandidates(for: .geminiHydrogen) == [.parakeet, .gigaam])
    }
}

// MARK: - Settings

@MainActor
@Suite struct HydrogenSettingsTests {
    /// A fresh install lists Hydrogen between Flash and Carbon, switched off: Parakeet is the main model and Flash its
    /// one step.
    @Test func aFreshInstallListsHydrogenAfterFlashSwitchedOff() throws {
        try withDefaults { defaults in
            let settings = load(defaults)
            #expect(settings.lineup.order == [.parakeet, .gemini, .hydrogen, .carbon, .gigaam])
            #expect(settings.lineup.main == .parakeet && settings.lineup.cycle == [.parakeet, .gemini])
            #expect(!settings.lineup.isSwitchable(.hydrogen))
            #expect(settings.modelColors[.hydrogen] == .pink && settings.modelColors[.gemini] == .violet)
            #expect(settings.reasoningEffort(for: .geminiHydrogen) == .medium)
            #expect(settings.localModel(for: .geminiHydrogen) == nil && !settings.usesLocalModel(.geminiHydrogen))
        }
    }

    /// A lineup stored before Hydrogen gets it appended at the end, switched off: nobody's fn ⇥ starts costing more by
    /// itself, and the main model, the order and hands-free stay.
    @Test func aLineupFromBeforeHydrogenGetsItAppendedSwitchedOff() throws {
        try withDefaults { defaults in
            let old = #"{"main":"carbon","order":["parakeet","carbon","gemini","gigaam"],"switchable":["parakeet","gemini"]}"#
            defaults.set(Data(old.utf8), forKey: SettingsKey.lineup.defaultsKey)
            defaults.set("gemini", forKey: SettingsKey.handsFreeModel.defaultsKey)
            let settings = load(defaults)
            #expect(settings.lineup.order == [.parakeet, .carbon, .gemini, .gigaam, .hydrogen])
            #expect(settings.lineup.main == .carbon && settings.lineup.cycle == [.carbon, .gemini, .parakeet])
            #expect(!settings.lineup.isSwitchable(.hydrogen) && settings.handsFreeChoice == .gemini)
            #expect(load(defaults).lineup.order == [.parakeet, .carbon, .gemini, .gigaam, .hydrogen], "stored as read")
        }
    }

    /// Switched on, Hydrogen is a step of fn ⇥ and can be hands-free's model; as the main model too.
    @Test func hydrogenInTheCycle() throws {
        let settings = AppSettings.inMemory()
        settings.lineup.setSwitchable(.hydrogen, true)
        settings.handsFreeModel = .hydrogen
        #expect(settings.lineup.steps == [.gemini, .hydrogen] && settings.handsFreeChoice == .hydrogen)
        settings.lineup.main = .hydrogen
        #expect(settings.mainEngine == .geminiHydrogen && settings.lineup.cycle.first == .hydrogen)
        #expect(settings.localModelsInUse == [.parakeet], "Parakeet, switched on when it stopped being main")
    }

    /// Pasting's rules from before Hydrogen: Hydrogen starts with Flash's checks, once. Changed later, it keeps its own.
    @Test func hydrogenStartsWithFlashsPastingRulesOnce() throws {
        try withDefaults { defaults in
            defaults.set(try JSONEncoder().encode(["gemini", "carbon"]), forKey: SettingsKey.modelsAddingSpace.defaultsKey)
            defaults.set(try JSONEncoder().encode(["parakeet", "gigaam"]),
                         forKey: SettingsKey.modelsRemovingFinalPeriod.defaultsKey)
            defaults.set(true, forKey: SettingsKey.carbonPastingAdded.defaultsKey)
            defaults.set(true, forKey: SettingsKey.gigaamPastingAdded.defaultsKey)
            let settings = load(defaults)
            #expect(settings.modelsAddingSpace == [.gemini, .hydrogen, .carbon])
            #expect(settings.modelsRemovingFinalPeriod == [.parakeet, .gigaam])
            #expect(settings.addsSpace(by: .hydrogen, in: .pushToTalk))
            #expect(defaults.bool(forKey: SettingsKey.hydrogenPastingAdded.defaultsKey))
            settings.modelsAddingSpace.remove(.hydrogen)
            settings.modelsRemovingFinalPeriod.insert(.hydrogen)
            let reloaded = load(defaults)
            #expect(reloaded.modelsAddingSpace == [.gemini, .carbon], "a choice made since stays")
            #expect(reloaded.modelsRemovingFinalPeriod == [.parakeet, .hydrogen, .gigaam])
        }
        // A fresh install has no rules to copy, and copies none later.
        try withDefaults { defaults in
            let settings = load(defaults)
            #expect(settings.modelsAddingSpace.isEmpty && settings.modelsRemovingFinalPeriod.isEmpty)
            #expect(defaults.bool(forKey: SettingsKey.hydrogenPastingAdded.defaultsKey))
        }
        #expect(AppSettings.withHydrogenLikeFlash([.gemini]) == [.gemini, .hydrogen])
        #expect(AppSettings.withHydrogenLikeFlash([.hydrogen, .parakeet]) == [.parakeet])
    }

    /// A level picked for Hydrogen sticks, apart from Flash's and Carbon's.
    @Test func hydrogensLevelPersists() throws {
        try withDefaults { defaults in
            let settings = load(defaults)
            settings.reasoningEfforts[.geminiHydrogen] = .low
            let reloaded = load(defaults)
            #expect(reloaded.reasoningEffort(for: .geminiHydrogen) == .low)
            #expect(reloaded.reasoningEffort(for: .geminiFlash) == .medium)
            #expect(reloaded.reasoningEffort(for: .geminiCarbon) == .low)
        }
    }
}

// MARK: - Requests

@MainActor
@Suite struct HydrogenRequestTests {
    private func service(_ replies: [StubURLProtocol.Reply]) -> (TranscriptionService, String) {
        let (client, host) = StubURLProtocol.client(replies)
        let account = OpenRouterAccount(keyStore: .inMemory("sk-or-v1-test"), client: client, debounce: .zero)
        return (TranscriptionService(models: ModelStore.preview(states: [:]), account: account, client: client), host)
    }

    private let speech = Recording(samples: [Float](repeating: 0.1, count: 16_000))

    /// Hydrogen goes with its own slug, at its own default (Medium) without the app's settings, pinned to Google AI
    /// Studio, with Flash's 2-minute stall timeout; what OpenRouter says it cost is kept.
    @Test func hydrogenGoesWithItsSlugLevelAndTimeout() async throws {
        let usage = #"{"prompt_tokens":400,"completion_tokens":120,"total_tokens":520,"cost":0.0012,"completion_tokens_details":{"reasoning_tokens":60}}"#
        let (service, host) = service([
            .stream(SSE.answer("<transcript>Hydrogen.</transcript>", model: "google/gemini-4-hydrogen",
                               provider: "Google AI Studio", usage: usage)),
            .stream(SSE.answer("<transcript>Carbon.</transcript>")),
        ])
        let hydrogen = try await service.transcribe(speech, engine: .geminiHydrogen)
        let carbon = try await service.transcribe(speech, engine: .geminiCarbon)
        #expect(hydrogen.text == "Hydrogen." && hydrogen.engine == .geminiHydrogen && hydrogen.reasoningEffort == .medium)
        #expect(hydrogen.costUSD == 0.0012 && hydrogen.usage?.reasoningTokens == 60)
        #expect(carbon.reasoningEffort == .low)
        let bodies = try StubURLProtocol.registry.bodies(for: host).map(json)
        #expect(bodies.map { $0["model"] as? String } == ["google/gemini-4-hydrogen", "google/gemini-4-carbon"])
        #expect(bodies.map { ($0["reasoning"] as? [String: Any])?["effort"] as? String } == ["medium", "low"])
        #expect(bodies.allSatisfy { ($0["provider"] as? [String: Any])?["only"] as? [String] == ["google-ai-studio"] })
        #expect(StubURLProtocol.registry.requests(for: host).map(\.timeoutInterval) == [120, 300])
        #expect(hydrogen.metadata().modelID == "google/gemini-4-hydrogen" && hydrogen.metadata().reasoningEffort == .medium)
    }

    /// The level picked in Models goes with every request to Hydrogen.
    @Test func thePickedLevelGoes() async throws {
        let (service, host) = service([.stream(SSE.answer("<transcript>x</transcript>"))])
        service.reasoningEffort = { $0 == .geminiHydrogen ? .low : .high }
        _ = try await service.transcribe(speech, engine: .geminiHydrogen)
        let body = try json(try #require(StubURLProtocol.registry.bodies(for: host).first))
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "low")
    }

    /// Through the user's endpoint: the same slug (the endpoint drops "google/" itself), the same stall timeout, and
    /// the cost it reports. Nothing goes to OpenRouter.
    @Test func theEndpointGetsHydrogen() async throws {
        let usage = #"{"prompt_tokens":120,"completion_tokens":40,"total_tokens":160,"cost":0.0009,"completion_tokens_details":{"reasoning_tokens":12}}"#
        let (proxy, proxyHost) = ProxyFixture.proxy([
            .stream(SSE.answer("<transcript>Привет.</transcript>", id: "chatcmpl-h1", model: "google/gemini-4-hydrogen",
                               usage: usage)),
        ])
        let (service, openRouterHost) = ProxyFixture.service(proxy: proxy)
        let result = try await service.transcribe(ProxyFixture.speech(), engine: .geminiHydrogen)
        #expect(result.text == "Привет." && result.costUSD == 0.0009)
        let body = try json(try #require(StubURLProtocol.registry.bodies(for: proxyHost).first))
        #expect(body["model"] as? String == "google/gemini-4-hydrogen")
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "medium")
        #expect(StubURLProtocol.registry.requests(for: proxyHost).map(\.timeoutInterval) == [120])
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).isEmpty)
    }
}

// MARK: - The pill's estimate

@Suite struct HydrogenTokenEstimateTests {
    private func entry(_ modelID: String, reasoningTokens: Int, reasoningCharacters: Int) -> TranscriptEntry {
        let usage = TokenUsage(completionTokens: reasoningTokens, reasoningTokens: reasoningTokens)
        let version = TranscriptVersion(kind: .transcription(.geminiHydrogen), text: "",
                                        metadata: TranscriptMetadata(modelID: modelID, usage: usage,
                                                                     reasoningCharacters: reasoningCharacters))
        return TranscriptEntry(engine: .geminiHydrogen, audioDuration: 5, voicedSeconds: 4, versions: [version])
    }

    /// Hydrogen's count learns from Hydrogen's own versions, never from Flash's, and Flash's never from Hydrogen's.
    @Test func hydrogensEstimateIsItsOwn() throws {
        let hydrogen = try #require(EngineID.geminiHydrogen.openRouterModelID)
        let flash = try #require(EngineID.geminiFlash.openRouterModelID)
        let entries = [entry(hydrogen, reasoningTokens: 2_000, reasoningCharacters: 1_000),
                       entry(flash, reasoningTokens: 9_000, reasoningCharacters: 1_000)]
        #expect(TokenEstimate.learned(from: entries, modelID: hydrogen).reasoningPerCharacter == 2)
        #expect(TokenEstimate.learned(from: entries, modelID: flash).reasoningPerCharacter == 9)
        #expect(TokenEstimate.learned(from: [entries[1]], modelID: hydrogen) == TokenEstimate(),
                "no Hydrogen history yet: the defaults")
    }
}

// MARK: - CLI

@Suite struct HydrogenCLITests {
    private func options(_ extra: String...) -> EngineCLI.Options? {
        EngineCLI.Options(["transcribe-thing", "--transcribe", "/tmp/memo.m4a"] + extra)
    }

    @Test func hydrogenIsAnEngine() {
        #expect(options("--engine", "geminiHydrogen")?.engine == .geminiHydrogen)
        #expect(options("--engine", "hydrogen")?.engine == .geminiHydrogen)
        #expect(options("--engine", "gemini-4-hydrogen")?.engine == .geminiHydrogen)
        #expect(options("--engine", "geminiHydrogen", "--effort", "high")?.effort == .high)
        #expect(EngineCLI.Options.usage.contains("--engine parakeet|gigaam|geminiFlash|geminiHydrogen|geminiCarbon "))
    }

    /// `--model-status` lists it between Flash and Carbon, its columns still apart.
    @Test func modelStatusListsHydrogen() {
        let lines = EngineCLI.cloudModelLines()
        #expect(lines.count == 3)
        #expect(lines[1].hasPrefix("geminiHydrogen  Gemini 4 Hydrogen  google/gemini-4-hydrogen"))
        #expect(lines[1].hasSuffix("effort low|medium|high (default medium)"))
        #expect(lines[0].hasPrefix("geminiFlash ") && lines[2].hasPrefix("geminiCarbon "))
    }
}

// MARK: - Dictation

@MainActor
@Suite(.serialized) struct HydrogenDictationTests {
    typealias H = DictationControllerTests

    /// fn ⇥ reaches Hydrogen once it's switched on, in the lineup's order (after Flash), and the dictation goes to it,
    /// pasted by Hydrogen's own Pasting rules.
    @Test func switchModelStepsToHydrogen() async throws {
        let (rig, _) = SwitchModelControllerTests.make()
        let c = rig.h.controller
        rig.h.settings.lineup.setSwitchable(.hydrogen, true)
        rig.h.settings.modelsAddingSpace = [.hydrogen]
        rig.h.settings.modelsRemovingFinalPeriod = [.gemini]
        var used: [EngineID] = []
        rig.result = { _, engine in
            used.append(engine)
            return "Words."
        }
        SwitchModelControllerTests.hold(rig)
        var choices: [ModelChoice?] = []
        for _ in 0..<3 {
            c.handle(.cycleEngine)
            choices.append(c.modelOverride)
        }
        #expect(choices == [.gemini, .hydrogen, nil])
        c.handle(.cycleEngine)
        c.handle(.cycleEngine)
        #expect(c.effectiveEngine == .geminiHydrogen && rig.h.pill.sessionModel == .hydrogen)
        try await SwitchModelControllerTests.release(rig)
        #expect(used == [.geminiHydrogen])
        #expect(rig.pasted == ["Words. "], "Hydrogen's rules: a space, and Flash's final period rule isn't Hydrogen's")
        #expect(rig.h.history.entries.first?.engine == .geminiHydrogen)
    }

    /// Polish on Hydrogen is Hydrogen's: the request goes to Hydrogen, and the version says so.
    @Test func polishOnHydrogenIsHydrogens() async throws {
        let (rig, _) = SwitchModelControllerTests.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .hydrogen
        var used: [EngineID] = []
        rig.result = { _, engine in
            used.append(engine)
            return "Polished."
        }
        SwitchModelControllerTests.hold(rig)
        c.handle(.polish)
        #expect(c.isPolishing)
        try await SwitchModelControllerTests.release(rig)
        #expect(used == [.geminiHydrogen])
        let entry = try #require(rig.h.history.entries.first)
        #expect(entry.currentKind == .polish(by: .geminiHydrogen))
        #expect(entry.currentKind?.dictationModel == .hydrogen)
        #expect(entry.currentVersion.map(VersionDetails.lines)?.first == "Polished by Gemini 4 Hydrogen")
    }

    /// Hydrogen isn't held to its tags, as Carbon is: an answer without them is still words, and is pasted.
    @Test func hydrogensUntaggedAnswerIsPasted() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        var pasted: [String] = []
        h.controller.transcribeOverride = { _, engine in
            var result = TranscriptResult(text: "Созвонимся завтра.", engine: engine, processingTime: 0.1)
            result.answerTags = TaggedTranscript.Tags.none
            return result
        }
        h.controller.insertOverride = { text in pasted.append(text); return .pasted }
        let r = UnheardSpeechTests.speech(voiced: 2.5)
        h.controller.enqueue(r, engine: .geminiHydrogen)
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id) != nil }
        #expect(pasted == ["Созвонимся завтра."])
        let entry = try #require(h.history.entry(id: r.id))
        #expect(entry.engine == .geminiHydrogen && entry.status == .success)
    }
}
