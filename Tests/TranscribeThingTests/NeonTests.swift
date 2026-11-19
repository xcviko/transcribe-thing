import Foundation
import Testing
@testable import TranscribeThing

// Gemini 4 Neon, the middle of the Gemini 4 family, between Hydrogen and Carbon: its engine and choice, its Reasoning
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

@Suite struct NeonModelTests {
    @Test func neonIsAGeminiOfItsOwnBetweenHydrogenAndCarbon() {
        #expect(EngineID.geminiNeon.rawValue == "geminiNeon" && ModelChoice.neon.rawValue == "neon")
        #expect(EngineID.geminiEngines == [.geminiFlash, .geminiHydrogen, .geminiNeon, .geminiCarbon])
        #expect(ModelChoice.allCases.filter(\.isGemini) == [.gemini, .hydrogen, .neon, .carbon])
        let neon = EngineID.geminiNeon
        #expect(neon.isGemini && neon.isCloud && !neon.isLocal && !neon.isRetired)
        #expect(neon.modelName == "Gemini 4 Neon" && neon.displayName == "Gemini 4 Neon")
        #expect(neon.shortName == "Gemini 4 Neon" && neon.glyph == "N")
        #expect(neon.openRouterModelID == "google/gemini-4-neon" && neon.provider == "Google AI Studio")
        #expect(neon.providerLine == "Google · via OpenRouter" && neon.badges == ["Cloud"])
        #expect(neon.factLine == "Newest · between Hydrogen and Carbon · about 3.6× Flash’s price per token")
        #expect(neon.approxDownloadBytes == nil)
        #expect(OpenRouterClient.engine(forModel: "google/gemini-4-neon") == .geminiNeon)
        #expect(ModelChoice.neon.modelName == "Gemini 4 Neon" && ModelChoice.neon.shortName == "Neon")
        #expect(ModelChoice.neon.chipName == "Gemini 4 Neon" && ModelChoice.neon.compactName == "Gemini 4 Neon")
        #expect(ModelChoice.sentenceList([.hydrogen, .neon, .carbon]) == ("Hydrogen, Neon and Carbon", true))
    }

    /// A lamp and a glyph of its own: no other model's symbol, letter or default color.
    @Test func itsMarksAreItsOwn() {
        let others = ModelChoice.allCases.filter { $0 != .neon }
        #expect(ModelChoice.neon.symbolName == "lightbulb.fill" && EngineID.geminiNeon.symbolName == "lightbulb.fill")
        #expect(!others.map(\.symbolName).contains("lightbulb.fill"))
        #expect(!EngineID.allCases.filter { $0 != .geminiNeon }.map(\.symbolName).contains("lightbulb.fill"))
        #expect(!EngineID.allCases.filter { $0 != .geminiNeon }.map(\.glyph).contains("N"))
        #expect(ModelChoice.neon.defaultColor == .orange)
        #expect(!others.map(\.defaultColor).contains(.orange))
    }

    /// Neon is Neon wherever a job or History names it; Flash stays Gemini, Hydrogen and Carbon their own.
    @Test func choicesAndEnginesMapBothWays() {
        #expect(ModelChoice(engine: .geminiNeon) == .neon && ModelChoice.neon.engine == .geminiNeon)
        #expect(ModelChoice(engine: .geminiFlash) == .gemini && ModelChoice(engine: .geminiHydrogen) == .hydrogen)
        #expect(ModelChoice(engine: .geminiCarbon) == .carbon)
        #expect(ModelChoice(stored: "neon") == .neon)
        #expect(ModelChoice.read(["gemini", "neon"]) == [.gemini, .neon])
    }

    /// History keeps Neon's versions under its name, and offers it in Transcribe With like the other Geminis.
    @Test func historyKindsNameNeon() {
        for kind in [TranscriptVersionKind.transcription(.geminiNeon), .polish(by: .geminiNeon),
                     .translation(polished: true, by: .geminiNeon)] {
            #expect(TranscriptVersionKind(rawValue: kind.rawValue) == kind, "\(kind.rawValue)")
            #expect(kind.dictationModel == .neon)
        }
        #expect(TranscriptVersionKind.polish(by: .geminiNeon).rawValue == "polish:geminiNeon")
        #expect(TranscriptVersionKind.polish(by: .geminiNeon).displayName == "Polished by Gemini 4 Neon")
        #expect(TranscriptVersionKind.transcript(by: .geminiNeon) == .transcription(.geminiNeon))
        #expect(TranscriptVersionKind.transcripts.contains(.transcription(.geminiNeon)))
        #expect(TranscriptVersionKind.rewrites.filter { $0.engine == .geminiNeon }
                == [.polish(by: .geminiNeon), .translation(polished: false, by: .geminiNeon)])
    }

    /// Neon offers Low, Medium and High, never Minimal (not known to work) or None, and thinks at Low until picked.
    @Test func neonThinksAtLowAndIsNotOfferedMinimal() {
        #expect(EngineID.geminiNeon.reasoningEfforts == [.low, .medium, .high])
        #expect(EngineID.geminiNeon.defaultReasoningEffort == .low)
        #expect(ReasoningEfforts.default[.geminiNeon] == .low)
        #expect(ReasoningEfforts.default[.geminiHydrogen] == .medium && ReasoningEfforts.default[.geminiFlash] == .medium)
    }

    /// Five minutes of silence before it's a stall, as Carbon; an answer without tags is still words, as Flash's.
    @Test func neonWaitsAsCarbonAndNeedsNoTags() {
        #expect(EngineID.geminiNeon.cloudTimeout == 300 && EngineID.geminiCarbon.cloudTimeout == 300)
        #expect(!EngineID.geminiNeon.answerNeedsTags)
        #expect(EngineID.allCases.filter(\.answerNeedsTags) == [.geminiCarbon])
    }

    /// A stored level for Neon is read; none leaves its Low; Minimal or None leaves its Low too.
    @Test func storedLevelsAreReadPerModel() throws {
        let decode = { (raw: String) throws -> ReasoningEfforts in
            try JSONDecoder().decode(ReasoningEfforts.self, from: Data(raw.utf8))
        }
        let old = try decode(#"{"geminiCarbon":"high","geminiFlash":"low","geminiHydrogen":"high"}"#)
        #expect(old[.geminiNeon] == .low && old[.geminiHydrogen] == .high && old[.geminiCarbon] == .high,
                "stored before Neon")
        let picked = try decode(#"{"geminiFlash":"low","geminiNeon":"medium"}"#)
        #expect(picked[.geminiNeon] == .medium && picked[.geminiFlash] == .low)
        var levels = try decode(#"{"geminiNeon":"minimal"}"#)
        #expect(levels[.geminiNeon] == .low)
        levels[.geminiNeon] = .minimal
        levels[.geminiNeon] = .off
        #expect(levels[.geminiNeon] == .low, "levels it isn't offered are refused")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(String(decoding: try encoder.encode(ReasoningEfforts.default), as: UTF8.self)
                == #"{"geminiCarbon":"low","geminiFlash":"medium","geminiHydrogen":"medium","geminiNeon":"low"}"#)
    }

    /// When Neon can't answer, a dictation falls back to the models on this Mac, as from any Gemini.
    @MainActor @Test func itFallsBackToTheModelsOnThisMac() {
        #expect(DictationController.fallbackCandidates(for: .geminiNeon) == [.gigaam])
    }
}

// MARK: - Settings

@MainActor
@Suite struct NeonSettingsTests {
    /// A fresh install lists Neon between Hydrogen and Carbon, switched off: GigaAM v3 is the main model and Flash its
    /// one step.
    @Test func aFreshInstallListsNeonAfterHydrogenSwitchedOff() throws {
        try withDefaults { defaults in
            let settings = load(defaults)
            #expect(settings.lineup.order == [.gigaam, .gemini, .hydrogen, .neon, .carbon])
            #expect(settings.lineup.main == .gigaam && settings.lineup.cycle == [.gigaam, .gemini])
            #expect(!settings.lineup.isSwitchable(.neon))
            #expect(settings.modelColors[.neon] == .orange && settings.modelColors[.hydrogen] == .pink)
            #expect(settings.reasoningEffort(for: .geminiNeon) == .low)
            #expect(LocalModel(engine: .geminiNeon) == nil && !settings.usesLocalModel(.geminiNeon))
        }
    }

    /// A lineup stored before Neon (Hydrogen in it, as 0.5.3 stored it) gets Neon appended at the end, switched off:
    /// nobody's fn ⇥ starts costing more by itself, and the main model, the order and hands-free stay.
    @Test func aLineupFromBeforeNeonGetsItAppendedSwitchedOff() throws {
        try withDefaults { defaults in
            let old = #"{"main":"hydrogen","order":["parakeet","gemini","hydrogen","carbon","gigaam"],"switchable":["parakeet","gemini"]}"#
            defaults.set(Data(old.utf8), forKey: SettingsKey.lineup.defaultsKey)
            defaults.set("gemini", forKey: SettingsKey.handsFreeModel.defaultsKey)
            let settings = load(defaults)
            #expect(settings.lineup.order == [.gigaam, .gemini, .hydrogen, .carbon, .neon])
            #expect(settings.lineup.main == .hydrogen && settings.lineup.cycle == [.hydrogen, .gigaam, .gemini])
            #expect(!settings.lineup.isSwitchable(.neon) && settings.handsFreeChoice == .gemini)
            #expect(load(defaults).lineup.order == [.gigaam, .gemini, .hydrogen, .carbon, .neon],
                    "stored as read")
        }
    }

    /// Switched on, Neon is a step of fn ⇥ and can be hands-free's model; as the main model too.
    @Test func neonInTheCycle() throws {
        let settings = AppSettings.inMemory()
        settings.lineup.setSwitchable(.neon, true)
        settings.handsFreeModel = .neon
        #expect(settings.lineup.steps == [.gemini, .neon] && settings.handsFreeChoice == .neon)
        settings.lineup.main = .neon
        #expect(settings.mainEngine == .geminiNeon && settings.lineup.cycle.first == .neon)
        #expect(settings.localModelsInUse == [.gigaam], "GigaAM, switched on when it stopped being main")
    }

    /// Pasting's rules from before Neon: Neon starts with Flash's checks, once. Changed later, it keeps its own.
    @Test func neonStartsWithFlashsPastingRulesOnce() throws {
        try withDefaults { defaults in
            defaults.set(try JSONEncoder().encode(["gemini", "hydrogen", "carbon"]),
                         forKey: SettingsKey.modelsAddingSpace.defaultsKey)
            defaults.set(try JSONEncoder().encode(["parakeet", "gigaam"]),
                         forKey: SettingsKey.modelsRemovingFinalPeriod.defaultsKey)
            for key in [SettingsKey.carbonPastingAdded, .gigaamPastingAdded, .hydrogenPastingAdded] {
                defaults.set(true, forKey: key.defaultsKey)
            }
            let settings = load(defaults)
            #expect(settings.modelsAddingSpace == [.gemini, .hydrogen, .neon, .carbon])
            #expect(settings.modelsRemovingFinalPeriod == [.gigaam], "Parakeet's own goes with it")
            #expect(settings.addsSpace(by: .neon, in: .pushToTalk))
            #expect(defaults.bool(forKey: SettingsKey.neonPastingAdded.defaultsKey))
            settings.modelsAddingSpace.remove(.neon)
            settings.modelsRemovingFinalPeriod.insert(.neon)
            let reloaded = load(defaults)
            #expect(reloaded.modelsAddingSpace == [.gemini, .hydrogen, .carbon], "a choice made since stays")
            #expect(reloaded.modelsRemovingFinalPeriod == [.neon, .gigaam])
        }
        // A fresh install has no rules to copy, and copies none later.
        try withDefaults { defaults in
            let settings = load(defaults)
            #expect(settings.modelsAddingSpace.isEmpty && settings.modelsRemovingFinalPeriod.isEmpty)
            #expect(defaults.bool(forKey: SettingsKey.neonPastingAdded.defaultsKey))
        }
        #expect(AppSettings.withNeonLikeFlash([.gemini]) == [.gemini, .neon])
        #expect(AppSettings.withNeonLikeFlash([.neon, .gigaam]) == [.gigaam])
    }

    /// A level picked for Neon sticks, apart from the other Geminis'.
    @Test func neonsLevelPersists() throws {
        try withDefaults { defaults in
            let settings = load(defaults)
            settings.reasoningEfforts[.geminiNeon] = .high
            let reloaded = load(defaults)
            #expect(reloaded.reasoningEffort(for: .geminiNeon) == .high)
            #expect(reloaded.reasoningEffort(for: .geminiFlash) == .medium)
            #expect(reloaded.reasoningEffort(for: .geminiHydrogen) == .medium)
            #expect(reloaded.reasoningEffort(for: .geminiCarbon) == .low)
        }
    }
}

// MARK: - Requests

@MainActor
@Suite struct NeonRequestTests {
    private func service(_ replies: [StubURLProtocol.Reply]) -> (TranscriptionService, String) {
        let (client, host) = StubURLProtocol.client(replies)
        let account = OpenRouterAccount(keyStore: .inMemory("sk-or-v1-test"), client: client, debounce: .zero)
        return (TranscriptionService(models: ModelStore.preview(states: [:]), account: account, client: client), host)
    }

    private let speech = Recording(samples: [Float](repeating: 0.1, count: 16_000))

    /// Neon goes with its own slug, at its own default (Low) without the app's settings, pinned to Google AI Studio,
    /// with Carbon's 5-minute stall timeout; what OpenRouter says it cost is kept.
    @Test func neonGoesWithItsSlugLevelAndTimeout() async throws {
        let usage = #"{"prompt_tokens":400,"completion_tokens":120,"total_tokens":520,"cost":0.0030,"completion_tokens_details":{"reasoning_tokens":50}}"#
        let (service, host) = service([
            .stream(SSE.answer("<transcript>Neon.</transcript>", model: "google/gemini-4-neon",
                               provider: "Google AI Studio", usage: usage)),
            .stream(SSE.answer("<transcript>Hydrogen.</transcript>")),
        ])
        let neon = try await service.transcribe(speech, engine: .geminiNeon)
        let hydrogen = try await service.transcribe(speech, engine: .geminiHydrogen)
        #expect(neon.text == "Neon." && neon.engine == .geminiNeon && neon.reasoningEffort == .low)
        #expect(neon.costUSD == 0.0030 && neon.usage?.reasoningTokens == 50)
        #expect(hydrogen.reasoningEffort == .medium)
        let bodies = try StubURLProtocol.registry.bodies(for: host).map(json)
        #expect(bodies.map { $0["model"] as? String } == ["google/gemini-4-neon", "google/gemini-4-hydrogen"])
        #expect(bodies.map { ($0["reasoning"] as? [String: Any])?["effort"] as? String } == ["low", "medium"])
        #expect(bodies.allSatisfy { ($0["provider"] as? [String: Any])?["only"] as? [String] == ["google-ai-studio"] })
        #expect(StubURLProtocol.registry.requests(for: host).map(\.timeoutInterval) == [300, 120])
        #expect(neon.metadata().modelID == "google/gemini-4-neon" && neon.metadata().reasoningEffort == .low)
    }

    /// The level picked in Models goes with every request to Neon.
    @Test func thePickedLevelGoes() async throws {
        let (service, host) = service([.stream(SSE.answer("<transcript>x</transcript>"))])
        service.reasoningEffort = { $0 == .geminiNeon ? .medium : .high }
        _ = try await service.transcribe(speech, engine: .geminiNeon)
        let body = try json(try #require(StubURLProtocol.registry.bodies(for: host).first))
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "medium")
    }

    /// Through the user's endpoint: the same slug (the endpoint drops "google/" itself), the same stall timeout, and
    /// the cost it reports. Nothing goes to OpenRouter.
    @Test func theEndpointGetsNeon() async throws {
        let usage = #"{"prompt_tokens":120,"completion_tokens":40,"total_tokens":160,"cost":0.0021,"completion_tokens_details":{"reasoning_tokens":12}}"#
        let (proxy, proxyHost) = ProxyFixture.proxy([
            .stream(SSE.answer("<transcript>Привет.</transcript>", id: "chatcmpl-n1", model: "google/gemini-4-neon",
                               usage: usage)),
        ])
        let (service, openRouterHost) = ProxyFixture.service(proxy: proxy)
        let result = try await service.transcribe(ProxyFixture.speech(), engine: .geminiNeon)
        #expect(result.text == "Привет." && result.costUSD == 0.0021)
        let body = try json(try #require(StubURLProtocol.registry.bodies(for: proxyHost).first))
        #expect(body["model"] as? String == "google/gemini-4-neon")
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "low")
        #expect(StubURLProtocol.registry.requests(for: proxyHost).map(\.timeoutInterval) == [300])
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).isEmpty)
    }
}

// MARK: - The pill's estimate

@Suite struct NeonTokenEstimateTests {
    private func entry(_ modelID: String, reasoningTokens: Int, reasoningCharacters: Int) -> TranscriptEntry {
        let usage = TokenUsage(completionTokens: reasoningTokens, reasoningTokens: reasoningTokens)
        let version = TranscriptVersion(kind: .transcription(.geminiNeon), text: "",
                                        metadata: TranscriptMetadata(modelID: modelID, usage: usage,
                                                                     reasoningCharacters: reasoningCharacters))
        return TranscriptEntry(engine: .geminiNeon, audioDuration: 5, voicedSeconds: 4, versions: [version])
    }

    /// Neon's count learns from Neon's own versions, never from Carbon's, and Carbon's never from Neon's.
    @Test func neonsEstimateIsItsOwn() throws {
        let neon = try #require(EngineID.geminiNeon.openRouterModelID)
        let carbon = try #require(EngineID.geminiCarbon.openRouterModelID)
        let entries = [entry(neon, reasoningTokens: 4_000, reasoningCharacters: 1_000),
                       entry(carbon, reasoningTokens: 7_000, reasoningCharacters: 1_000)]
        #expect(TokenEstimate.learned(from: entries, modelID: neon).reasoningPerCharacter == 4)
        #expect(TokenEstimate.learned(from: entries, modelID: carbon).reasoningPerCharacter == 7)
        #expect(TokenEstimate.learned(from: [entries[1]], modelID: neon) == TokenEstimate(),
                "no Neon history yet: the defaults")
    }
}

// MARK: - CLI

@Suite struct NeonCLITests {
    private func options(_ extra: String...) -> EngineCLI.Options? {
        EngineCLI.Options(["transcribe-thing", "--transcribe", "/tmp/memo.m4a"] + extra)
    }

    @Test func neonIsAnEngine() {
        #expect(options("--engine", "geminiNeon")?.engine == .geminiNeon)
        #expect(options("--engine", "neon")?.engine == .geminiNeon)
        #expect(options("--engine", "gemini-4-neon")?.engine == .geminiNeon)
        #expect(options("--engine", "geminiNeon", "--effort", "medium")?.effort == .medium)
        #expect(EngineCLI.Options.usage
                    .contains("--engine gigaam|geminiFlash|geminiHydrogen|geminiNeon|geminiCarbon "))
    }

    /// `--model-status` lists it between Hydrogen and Carbon, its columns lined up with theirs.
    @Test func modelStatusListsNeon() {
        let lines = EngineCLI.cloudModelLines()
        #expect(lines.count == 4)
        #expect(lines[2].hasPrefix("geminiNeon      Gemini 4 Neon      google/gemini-4-neon"))
        #expect(lines[2].hasSuffix("effort low|medium|high (default low)"))
        #expect(lines[1].hasPrefix("geminiHydrogen ") && lines[3].hasPrefix("geminiCarbon "))
    }
}

// MARK: - Dictation

@MainActor
@Suite(.serialized) struct NeonDictationTests {
    typealias H = DictationControllerTests

    /// fn ⇥ reaches Neon once it's switched on, in the lineup's order (after Flash; Hydrogen is off), and the
    /// dictation goes to it, pasted by Neon's own Pasting rules.
    @Test func switchModelStepsToNeon() async throws {
        let (rig, _) = SwitchModelControllerTests.make()
        let c = rig.h.controller
        rig.h.settings.lineup.setSwitchable(.neon, true)
        rig.h.settings.modelsAddingSpace = [.neon]
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
        #expect(choices == [.gemini, .neon, nil])
        c.handle(.cycleEngine)
        c.handle(.cycleEngine)
        #expect(c.effectiveEngine == .geminiNeon && rig.h.pill.sessionModel == .neon)
        try await SwitchModelControllerTests.release(rig)
        #expect(used == [.geminiNeon])
        #expect(rig.pasted == ["Words. "], "Neon's rules: a space, and Flash's final period rule isn't Neon's")
        #expect(rig.h.history.entries.first?.engine == .geminiNeon)
    }

    /// Polish on Neon is Neon's: the request goes to Neon, and the version says so.
    @Test func polishOnNeonIsNeons() async throws {
        let (rig, _) = SwitchModelControllerTests.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .neon
        var used: [EngineID] = []
        rig.result = { _, engine in
            used.append(engine)
            return "Polished."
        }
        SwitchModelControllerTests.hold(rig)
        c.handle(.polish)
        #expect(c.isPolishing)
        try await SwitchModelControllerTests.release(rig)
        #expect(used == [.geminiNeon])
        let entry = try #require(rig.h.history.entries.first)
        #expect(entry.currentKind == .polish(by: .geminiNeon))
        #expect(entry.currentKind?.dictationModel == .neon)
        #expect(entry.currentVersion.map(VersionDetails.lines)?.first == "Polished by Gemini 4 Neon")
    }

    /// Neon isn't held to its tags, as Carbon is: an answer without them is still words, and is pasted.
    @Test func neonsUntaggedAnswerIsPasted() async throws {
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
        h.controller.enqueue(r, engine: .geminiNeon)
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id) != nil }
        #expect(pasted == ["Созвонимся завтра."])
        let entry = try #require(h.history.entry(id: r.id))
        #expect(entry.engine == .geminiNeon && entry.status == .success)
    }
}
