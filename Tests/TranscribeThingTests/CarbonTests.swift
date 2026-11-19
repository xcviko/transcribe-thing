import Foundation
import Testing
@testable import TranscribeThing

// Gemini 4 Carbon, a second Gemini next to Flash: its engine and choice, its Reasoning level and stall timeout, the
// lineup and Pasting rules it joins, its requests, the pill's estimate, the CLI and dictations on it.

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

@Suite struct CarbonModelTests {
    @Test func carbonIsAGeminiOfItsOwn() {
        #expect(EngineID.geminiCarbon.rawValue == "geminiCarbon" && ModelChoice.carbon.rawValue == "carbon")
        #expect(EngineID.offered == [.gigaam, .geminiFlash, .geminiHydrogen, .geminiNeon, .geminiCarbon])
        #expect(EngineID.geminiEngines == [.geminiFlash, .geminiHydrogen, .geminiNeon, .geminiCarbon])
        #expect(ModelChoice.allCases == [.gigaam, .gemini, .hydrogen, .neon, .carbon])
        let carbon = EngineID.geminiCarbon
        #expect(carbon.isGemini && carbon.isCloud && !carbon.isRetired)
        #expect(carbon.modelName == "Gemini 4 Carbon" && carbon.displayName == "Gemini 4 Carbon")
        #expect(carbon.shortName == "Gemini 4 Carbon" && carbon.glyph == "C" && carbon.symbolName == "atom")
        #expect(carbon.openRouterModelID == "google/gemini-4-carbon" && carbon.provider == "Google AI Studio")
        #expect(carbon.factLine == "Top of Gemini 4 · slower · about 2.7× Flash’s cost")
        #expect(OpenRouterClient.engine(forModel: "google/gemini-4-carbon") == .geminiCarbon)
        #expect(ModelChoice.carbon.modelName == "Gemini 4 Carbon" && ModelChoice.carbon.shortName == "Carbon")
        #expect(ModelChoice.carbon.chipName == "Gemini 4 Carbon" && ModelChoice.carbon.compactName == "Gemini 4 Carbon")
        #expect(ModelChoice.carbon.symbolName == "atom" && ModelChoice.carbon.isGemini)
        #expect(ModelChoice.sentenceList([.gemini, .carbon]) == ("Flash and Carbon", true))
    }

    /// Carbon is Carbon wherever a job or History names it; Flash and the retired Geminis stay Gemini, and the stored
    /// "argon" still reads as Flash, never as Carbon.
    @Test func choicesAndEnginesMapBothWays() {
        #expect(ModelChoice(engine: .geminiCarbon) == .carbon && ModelChoice.carbon.engine == .geminiCarbon)
        for engine in [EngineID.geminiFlash, .geminiArgon, .geminiPro] {
            #expect(ModelChoice(engine: engine) == .gemini, "\(engine)")
        }
        #expect(ModelChoice(engine: .parakeet) == .gigaam && ModelChoice(engine: .parakeetCloud) == .gigaam)
        #expect(ModelChoice(stored: "argon") == .gemini && ModelChoice(stored: "carbon") == .carbon)
        #expect(ModelChoice.read(["argon", "carbon"]) == [.carbon], "Argon's own checks are dropped, Carbon's kept")
    }

    /// History keeps Carbon's versions under its name, Argon's under Argon's.
    @Test func historyKindsNameCarbon() throws {
        for kind in [TranscriptVersionKind.transcription(.geminiCarbon), .polish(by: .geminiCarbon),
                     .translation(polished: true, by: .geminiCarbon)] {
            #expect(TranscriptVersionKind(rawValue: kind.rawValue) == kind, "\(kind.rawValue)")
            #expect(kind.dictationModel == .carbon)
        }
        #expect(TranscriptVersionKind.polish(by: .geminiCarbon).rawValue == "polish:geminiCarbon")
        #expect(TranscriptVersionKind(rawValue: "polish:geminiArgon") == .polish(by: .geminiArgon))
        #expect(TranscriptVersionKind.transcription(.geminiArgon).dictationModel == .gemini)
        #expect(TranscriptVersionKind.polish(by: .geminiCarbon).displayName == "Polished by Gemini 4 Carbon")
        #expect(TranscriptVersionKind.rewrites == [.polish(by: .geminiFlash), .polish(by: .geminiHydrogen),
                                                   .polish(by: .geminiNeon), .polish(by: .geminiCarbon),
                                                   .translation(polished: false, by: .geminiFlash),
                                                   .translation(polished: false, by: .geminiHydrogen),
                                                   .translation(polished: false, by: .geminiNeon),
                                                   .translation(polished: false, by: .geminiCarbon)])
    }

    /// Carbon thinks at Low until picked, Flash at Medium; each offers Low, Medium and High.
    @Test func eachGeminiHasItsOwnDefaultLevel() {
        #expect(EngineID.geminiCarbon.reasoningEfforts == [.low, .medium, .high])
        #expect(EngineID.geminiCarbon.defaultReasoningEffort == .low)
        #expect(EngineID.geminiFlash.defaultReasoningEffort == .medium)
        #expect(EngineID.geminiArgon.defaultReasoningEffort == nil, "retired: it never runs")
        #expect(ReasoningEfforts.default[.geminiCarbon] == .low && ReasoningEfforts.default[.geminiFlash] == .medium)
    }

    /// Carbon often sends nothing for 2-5 minutes before its first byte: 5 minutes of silence before it's a stall.
    /// Only Carbon's answer has to come in tags to be pasted.
    @Test func carbonWaitsLongerAndAnswersInTags() {
        #expect(EngineID.geminiCarbon.cloudTimeout == 300)
        #expect(EngineID.geminiFlash.cloudTimeout == 120)
        #expect(EngineID.allCases.filter(\.answerNeedsTags) == [.geminiCarbon])
    }

    /// A stored level for Carbon is read; none leaves its Low; one it doesn't take leaves its Low too.
    @Test func storedLevelsAreReadPerModel() throws {
        let decode = { (raw: String) throws -> ReasoningEfforts in
            try JSONDecoder().decode(ReasoningEfforts.self, from: Data(raw.utf8))
        }
        let old = try decode(#"{"geminiFlash":"high"}"#)
        #expect(old[.geminiFlash] == .high && old[.geminiCarbon] == .low, "stored before Carbon")
        let picked = try decode(#"{"geminiFlash":"low","geminiCarbon":"high"}"#)
        #expect(picked[.geminiFlash] == .low && picked[.geminiCarbon] == .high)
        var levels = try decode(#"{"geminiCarbon":"minimal"}"#)
        #expect(levels[.geminiCarbon] == .low)
        levels[.geminiCarbon] = .off
        #expect(levels[.geminiCarbon] == .low, "levels it doesn't take are refused")
    }
}

// MARK: - Settings

@MainActor
@Suite struct CarbonSettingsTests {
    /// A fresh install lists Carbon after Flash, Hydrogen and Neon, switched off: GigaAM v3 is the main model and Flash
    /// its one step.
    @Test func aFreshInstallListsCarbonSwitchedOff() throws {
        try withDefaults { defaults in
            let settings = load(defaults)
            #expect(settings.lineup.order == [.gigaam, .gemini, .hydrogen, .neon, .carbon])
            #expect(settings.lineup.main == .gigaam && settings.lineup.cycle == [.gigaam, .gemini])
            #expect(!settings.lineup.isSwitchable(.carbon))
            #expect(settings.modelColors[.carbon] == .blue && settings.modelColors[.gemini] == .violet)
            #expect(settings.reasoningEffort(for: .geminiCarbon) == .low)
        }
    }

    /// A lineup stored before Carbon gets it appended, switched off: nobody's fn ⇥ starts costing more by itself, and
    /// the main model stays.
    @Test func aLineupFromBeforeCarbonGetsItAppendedSwitchedOff() throws {
        try withDefaults { defaults in
            let old = #"{"main":"gemini","order":["gemini","parakeet"],"switchable":["parakeet"]}"#
            defaults.set(Data(old.utf8), forKey: SettingsKey.lineup.defaultsKey)
            defaults.set("parakeet", forKey: SettingsKey.handsFreeModel.defaultsKey)
            let settings = load(defaults)
            #expect(settings.lineup.order == [.gemini, .gigaam, .hydrogen, .neon, .carbon], "GigaAM in Parakeet's place")
            #expect(settings.lineup.main == .gemini && settings.lineup.cycle == [.gemini, .gigaam])
            #expect(!settings.lineup.isSwitchable(.carbon) && settings.handsFreeChoice == .gigaam)
            #expect(load(defaults).lineup.order == [.gemini, .gigaam, .hydrogen, .neon, .carbon],
                    "stored as read")
        }
        // From the days of Argon: Argon is Flash, and Carbon doesn't take its place.
        try withDefaults { defaults in
            let argon = #"{"main":"argon","order":["parakeet","argon","gemini"],"switchable":["parakeet","argon"]}"#
            defaults.set(Data(argon.utf8), forKey: SettingsKey.lineup.defaultsKey)
            defaults.set("argon", forKey: SettingsKey.handsFreeModel.defaultsKey)
            let settings = load(defaults)
            #expect(settings.lineup.main == .gemini
                    && settings.lineup.order == [.gigaam, .gemini, .hydrogen, .neon, .carbon])
            #expect(!settings.lineup.isSwitchable(.carbon))
        }
    }

    /// Pasting's rules from before Carbon: Carbon starts with Flash's checks, once. Unchecked later, it stays unchecked.
    /// (GigaAM, which came after, starts with the retired Parakeet's, and Hydrogen and Neon, after that, with Flash's.)
    @Test func carbonStartsWithFlashsPastingRulesOnce() throws {
        try withDefaults { defaults in
            defaults.set(try JSONEncoder().encode(["parakeet", "gemini"]),
                         forKey: SettingsKey.modelsAddingSpace.defaultsKey)
            defaults.set(try JSONEncoder().encode(["parakeet"]), forKey: SettingsKey.modelsRemovingFinalPeriod.defaultsKey)
            let settings = load(defaults)
            #expect(settings.modelsAddingSpace == [.gemini, .hydrogen, .neon, .carbon, .gigaam])
            #expect(settings.modelsRemovingFinalPeriod == [.gigaam])
            #expect(settings.addsSpace(by: .carbon, in: .pushToTalk))
            #expect(defaults.bool(forKey: SettingsKey.carbonPastingAdded.defaultsKey))
            settings.modelsAddingSpace.remove(.carbon)
            settings.modelsRemovingFinalPeriod.insert(.carbon)
            let reloaded = load(defaults)
            #expect(reloaded.modelsAddingSpace == [.gemini, .hydrogen, .neon, .gigaam], "a choice made since stays")
            #expect(reloaded.modelsRemovingFinalPeriod == [.carbon, .gigaam])
        }
        try withDefaults { defaults in
            let settings = load(defaults)
            #expect(settings.modelsAddingSpace.isEmpty && settings.modelsRemovingFinalPeriod.isEmpty)
            #expect(defaults.bool(forKey: SettingsKey.carbonPastingAdded.defaultsKey))
        }
        #expect(AppSettings.withCarbonLikeFlash([.gemini]) == [.gemini, .carbon])
        #expect(AppSettings.withCarbonLikeFlash([.carbon, .gigaam]) == [.gigaam])
    }

    /// A level picked for Carbon sticks, apart from Flash's.
    @Test func carbonsLevelPersists() throws {
        try withDefaults { defaults in
            let settings = load(defaults)
            settings.reasoningEfforts[.geminiCarbon] = .high
            let reloaded = load(defaults)
            #expect(reloaded.reasoningEffort(for: .geminiCarbon) == .high)
            #expect(reloaded.reasoningEffort(for: .geminiFlash) == .medium)
        }
    }
}

// MARK: - Requests

@MainActor
@Suite struct CarbonRequestTests {
    private func service(_ replies: [StubURLProtocol.Reply]) -> (TranscriptionService, String) {
        let (client, host) = StubURLProtocol.client(replies)
        let account = OpenRouterAccount(keyStore: .inMemory("sk-or-v1-test"), client: client, debounce: .zero)
        return (TranscriptionService(models: ModelStore.preview(states: [:]), account: account, client: client), host)
    }

    private let speech = Recording(samples: [Float](repeating: 0.1, count: 16_000))

    /// Carbon goes with its own slug, at its own default (Low) without the app's settings, pinned to Google AI Studio,
    /// with its 5-minute stall timeout; what OpenRouter says it cost is kept.
    @Test func carbonGoesWithItsSlugLevelAndTimeout() async throws {
        let usage = #"{"prompt_tokens":400,"completion_tokens":120,"total_tokens":520,"cost":0.0031,"completion_tokens_details":{"reasoning_tokens":40}}"#
        let (service, host) = service([
            .stream(SSE.answer("<transcript>Carbon.</transcript>", model: "google/gemini-4-carbon",
                               provider: "Google AI Studio", usage: usage)),
            .stream(SSE.answer("<transcript>Flash.</transcript>")),
        ])
        let carbon = try await service.transcribe(speech, engine: .geminiCarbon)
        let flash = try await service.transcribe(speech, engine: .geminiFlash)
        #expect(carbon.text == "Carbon." && carbon.engine == .geminiCarbon && carbon.reasoningEffort == .low)
        #expect(carbon.costUSD == 0.0031 && carbon.usage?.reasoningTokens == 40)
        #expect(flash.reasoningEffort == .medium)
        let bodies = try StubURLProtocol.registry.bodies(for: host).map(json)
        #expect(bodies.map { $0["model"] as? String } == ["google/gemini-4-carbon", "google/gemini-3.8-flash"])
        #expect(bodies.map { ($0["reasoning"] as? [String: Any])?["effort"] as? String } == ["low", "medium"])
        #expect(bodies.allSatisfy { ($0["provider"] as? [String: Any])?["only"] as? [String] == ["google-ai-studio"] })
        #expect(StubURLProtocol.registry.requests(for: host).map(\.timeoutInterval) == [300, 120])
        #expect(carbon.metadata().modelID == "google/gemini-4-carbon" && carbon.metadata().reasoningEffort == .low)
        #expect(carbon.metadata().costUSD == 0.0031)
    }

    /// The level picked in Models goes with every request to Carbon.
    @Test func thePickedLevelGoes() async throws {
        let (service, host) = service([.stream(SSE.answer("<transcript>x</transcript>"))])
        service.reasoningEffort = { $0 == .geminiCarbon ? .high : .low }
        _ = try await service.transcribe(speech, engine: .geminiCarbon)
        let body = try json(try #require(StubURLProtocol.registry.bodies(for: host).first))
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "high")
        #expect(body["max_tokens"] as? Int == 32_768 + 16_384, "High thinks longer")
    }

    /// Through the user's endpoint: the same slug (the endpoint drops "google/" itself), the same stall timeout, and
    /// the cost it reports.
    @Test func theEndpointGetsCarbon() async throws {
        let usage = #"{"prompt_tokens":120,"completion_tokens":40,"total_tokens":160,"cost":0.0042,"completion_tokens_details":{"reasoning_tokens":12}}"#
        let (proxy, proxyHost) = ProxyFixture.proxy([
            .stream(SSE.answer("<transcript>Привет.</transcript>", id: "chatcmpl-c1", model: "google/gemini-4-carbon",
                               usage: usage)),
        ])
        let (service, openRouterHost) = ProxyFixture.service(proxy: proxy)
        let result = try await service.transcribe(ProxyFixture.speech(), engine: .geminiCarbon)
        #expect(result.text == "Привет." && result.costUSD == 0.0042)
        let body = try json(try #require(StubURLProtocol.registry.bodies(for: proxyHost).first))
        #expect(body["model"] as? String == "google/gemini-4-carbon")
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "low")
        #expect(StubURLProtocol.registry.requests(for: proxyHost).map(\.timeoutInterval) == [300])
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).isEmpty)
    }
}

// MARK: - The pill's estimate

@Suite struct CarbonTokenEstimateTests {
    private func entry(_ modelID: String, reasoningTokens: Int, reasoningCharacters: Int) -> TranscriptEntry {
        let usage = TokenUsage(completionTokens: reasoningTokens, reasoningTokens: reasoningTokens)
        let version = TranscriptVersion(kind: .transcription(.geminiCarbon), text: "",
                                        metadata: TranscriptMetadata(modelID: modelID, usage: usage,
                                                                     reasoningCharacters: reasoningCharacters))
        return TranscriptEntry(engine: .geminiCarbon, audioDuration: 5, voicedSeconds: 4, versions: [version])
    }

    /// Carbon's count learns from Carbon's own versions, never from Flash's, and Flash's never from Carbon's.
    @Test func carbonsEstimateIsItsOwn() throws {
        let carbon = try #require(EngineID.geminiCarbon.openRouterModelID)
        let flash = try #require(EngineID.geminiFlash.openRouterModelID)
        let entries = [entry(carbon, reasoningTokens: 3_000, reasoningCharacters: 1_000),
                       entry(flash, reasoningTokens: 9_000, reasoningCharacters: 1_000)]
        #expect(TokenEstimate.learned(from: entries, modelID: carbon).reasoningPerCharacter == 3)
        #expect(TokenEstimate.learned(from: entries, modelID: flash).reasoningPerCharacter == 9)
        #expect(TokenEstimate.learned(from: [entries[1]], modelID: carbon) == TokenEstimate(),
                "no Carbon history yet: the defaults")
    }
}

// MARK: - CLI

@Suite struct CarbonCLITests {
    private func options(_ extra: String...) -> EngineCLI.Options? {
        EngineCLI.Options(["transcribe-thing", "--transcribe", "/tmp/memo.m4a"] + extra)
    }

    @Test func carbonIsAnEngine() {
        #expect(options("--engine", "geminiCarbon")?.engine == .geminiCarbon)
        #expect(options("--engine", "carbon")?.engine == .geminiCarbon)
        #expect(options("--engine", "gemini-4-carbon")?.engine == .geminiCarbon)
        #expect(options("--engine", "geminiArgon") == nil, "retired")
        #expect(EngineCLI.Options.usage
                    .contains("--engine gigaam|geminiFlash|geminiHydrogen|geminiNeon|geminiCarbon "))
    }

    @Test func modelStatusListsCarbon() {
        let lines = EngineCLI.cloudModelLines()
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("geminiFlash ") && lines[0].hasSuffix("effort low|medium|high (default medium)"))
        #expect(lines[3].hasPrefix("geminiCarbon ") && lines[3].contains("Gemini 4 Carbon")
                && lines[3].contains("google/gemini-4-carbon"))
        #expect(lines[3].hasSuffix("effort low|medium|high (default low)"))
    }
}

// MARK: - Dictation

@MainActor
@Suite(.serialized) struct CarbonDictationTests {
    typealias Rig = DictationResumeTests.Rig
    typealias H = DictationControllerTests

    /// fn ⇥ reaches Carbon once it's switched on, in the lineup's order, and the dictation goes to it, pasted by
    /// Carbon's own Pasting rules.
    @Test func switchModelStepsToCarbon() async throws {
        let (rig, _) = SwitchModelControllerTests.make()
        let c = rig.h.controller
        rig.h.settings.lineup.setSwitchable(.carbon, true)
        rig.h.settings.modelsAddingSpace = [.carbon]
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
        #expect(choices == [.gemini, .carbon, nil])
        c.handle(.cycleEngine)
        c.handle(.cycleEngine)
        #expect(c.effectiveEngine == .geminiCarbon && rig.h.pill.sessionModel == .carbon)
        try await SwitchModelControllerTests.release(rig)
        #expect(used == [.geminiCarbon])
        #expect(rig.pasted == ["Words. "], "Carbon's rules: a space, and Flash's final period rule isn't Carbon's")
        #expect(rig.h.history.entries.first?.engine == .geminiCarbon)
    }

    /// Polish on Carbon is Carbon's: the request goes to Carbon, and the version says so.
    @Test func polishOnCarbonIsCarbons() async throws {
        let (rig, _) = SwitchModelControllerTests.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .carbon
        var used: [EngineID] = []
        rig.result = { _, engine in
            used.append(engine)
            return "Polished."
        }
        SwitchModelControllerTests.hold(rig)
        c.handle(.polish)
        #expect(c.isPolishing)
        try await SwitchModelControllerTests.release(rig)
        #expect(used == [.geminiCarbon])
        let entry = try #require(rig.h.history.entries.first)
        #expect(entry.currentKind == .polish(by: .geminiCarbon))
        #expect(entry.currentKind?.dictationModel == .carbon)
        #expect(entry.currentVersion.map(VersionDetails.lines)?.first == "Polished by Gemini 4 Carbon")
    }

    /// Carbon's answer with none of the tags it was asked for (stray tokens, as Argon wrote): nothing is pasted, and
    /// the recording stays as a failed row with the answer.
    @Test func carbonsUntaggedAnswerIsKeptNotPasted() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        var pasted: [String] = []
        h.controller.transcribeOverride = { _, engine in
            var result = TranscriptResult(text: "1 1 2 4 8", engine: engine, processingTime: 0.1)
            result.rawAnswer = "1 1 2 4 8\n<eos>"
            result.answerTags = TaggedTranscript.Tags.none
            return result
        }
        h.controller.insertOverride = { text in pasted.append(text); return .pasted }
        let r = UnheardSpeechTests.speech(voiced: 2.5)
        h.controller.enqueue(r, engine: .geminiCarbon)
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id) != nil }
        let entry = try #require(h.history.entry(id: r.id))
        #expect(entry.status == .failed && entry.modelAnswer == "1 1 2 4 8\n<eos>")
        #expect(entry.audioFileName != nil && entry.engine == .geminiCarbon)
        #expect(pasted.isEmpty)
    }

    /// Carbon's tagged answer is pasted as any other.
    @Test func carbonsTaggedAnswerIsPasted() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        var pasted: [String] = []
        h.controller.transcribeOverride = { _, engine in
            var result = TranscriptResult(text: "Созвонимся завтра.", engine: engine, processingTime: 0.1)
            result.answerTags = .pair
            return result
        }
        h.controller.insertOverride = { text in pasted.append(text); return .pasted }
        h.controller.enqueue(UnheardSpeechTests.speech(voiced: 2.5), engine: .geminiCarbon)
        try await waitUntil { !pasted.isEmpty }
        #expect(pasted == ["Созвонимся завтра."])
    }
}
