import Foundation
import Testing
@testable import TranscribeThing

// Gemini 4 Argon, the reasoning level each Gemini model is asked to think at, the model calls go to, and the removal of
// Parakeet v3 · Cloud: settings it leaves behind, requests per engine, calls, fn ⇥ and the CLI.

private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(atPath: suite + ".plist")
    }
    try body(defaults)
}

@MainActor
private func load(_ defaults: UserDefaults) -> AppSettings {
    AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() })
}

private func json(_ body: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

// MARK: - Settings

@MainActor
@Suite struct CloudParakeetRemovalSettingsTests {
    /// Parakeet ran through OpenRouter: the main model, hands-free and Pasting's rules said "Parakeet", and the
    /// runtime key said where. Parakeet is on this Mac now; the key goes, the rest stays Parakeet's.
    @Test func settingsThatChoseCloudParakeetRunParakeetOnThisMac() throws {
        try withDefaults { defaults in
            defaults.set("parakeetCloud", forKey: SettingsKey.selectedEngine.defaultsKey)
            var lineup = ModelLineup.default
            lineup.main = .gemini
            defaults.set(try JSONEncoder().encode(lineup), forKey: SettingsKey.lineup.defaultsKey)
            defaults.set("parakeet", forKey: SettingsKey.handsFreeModel.defaultsKey)
            defaults.set(try JSONEncoder().encode(["parakeet"]), forKey: SettingsKey.modelsAddingSpace.defaultsKey)
            let settings = load(defaults)
            #expect(settings.handsFreeModel == .parakeet && settings.handsFreeChoice == .parakeet)
            #expect(settings.handsFreeChoice?.engine == .parakeet)
            #expect(settings.modelsAddingSpace == [.parakeet])
            #expect(settings.usesLocalParakeet, "Parakeet in the cycle is Parakeet on this Mac: it's worth loading")
            #expect(defaults.object(forKey: SettingsKey.selectedEngine.defaultsKey) == nil)

            defaults.set(try JSONEncoder().encode(ModelLineup.default), forKey: SettingsKey.lineup.defaultsKey)
            defaults.set("parakeetCloud", forKey: SettingsKey.selectedEngine.defaultsKey)
            #expect(load(defaults).mainEngine == .parakeet, "the main model on OpenRouter is the one on this Mac")
        }
    }

    /// A lineup stored before Argon gets it appended, switched off: nobody's fn ⇥ starts costing more by itself.
    @Test func aLineupFromBeforeArgonGetsItSwitchedOff() throws {
        try withDefaults { defaults in
            let old = #"{"main":"parakeet","order":["gemini","parakeet"],"switchable":["gemini"]}"#
            defaults.set(Data(old.utf8), forKey: SettingsKey.lineup.defaultsKey)
            let settings = load(defaults)
            #expect(settings.lineup.order == [.gemini, .parakeet, .argon])
            #expect(settings.lineup.cycle == [.parakeet, .gemini])
            #expect(settings.modelColors[.argon] == .blue)
        }
    }

    /// Pasting's rules from before Argon: Argon starts with Flash's checks, once. Unchecked later, it stays unchecked.
    @Test func argonStartsWithFlashsPastingRulesOnce() throws {
        try withDefaults { defaults in
            defaults.set(try JSONEncoder().encode(["gemini", "parakeet"]),
                         forKey: SettingsKey.modelsAddingSpace.defaultsKey)
            defaults.set(try JSONEncoder().encode(["parakeet"]), forKey: SettingsKey.modelsRemovingFinalPeriod.defaultsKey)
            let settings = load(defaults)
            #expect(settings.modelsAddingSpace == [.parakeet, .gemini, .argon])
            #expect(settings.modelsRemovingFinalPeriod == [.parakeet])
            #expect(settings.addsSpace(by: .argon, in: .pushToTalk))
            settings.modelsAddingSpace.remove(.argon)
            #expect(load(defaults).modelsAddingSpace == [.parakeet, .gemini], "a choice made since stays")
        }
        try withDefaults { defaults in
            let settings = load(defaults)
            #expect(settings.modelsAddingSpace.isEmpty && settings.modelsRemovingFinalPeriod.isEmpty)
            #expect(defaults.bool(forKey: SettingsKey.argonPastingAdded.defaultsKey))
        }
        #expect(AppSettings.withArgonLikeFlash([.gemini]) == [.gemini, .argon])
        #expect(AppSettings.withArgonLikeFlash([.argon]) == [])
    }

    /// No level stored: both Gemini models think at Medium. A level a model doesn't take (Minimal, a newer build's)
    /// leaves its Medium; the old per-model key from an older build goes.
    @Test func reasoningLevelsDefaultToMediumAndReadLeniently() throws {
        try withDefaults { defaults in
            let settings = load(defaults)
            #expect(settings.reasoningEffort(for: .geminiFlash) == .medium)
            #expect(settings.reasoningEffort(for: .geminiArgon) == .medium)
            #expect(settings.reasoningEffort(for: .parakeet) == nil)
        }
        try withDefaults { defaults in
            defaults.set(try JSONEncoder().encode(["geminiFlash": "high", "geminiArgon": "minimal", "parakeet": "low",
                                                   "geminiFuture": "high"]),
                         forKey: SettingsKey.geminiReasoningEfforts.defaultsKey)
            defaults.set(try JSONEncoder().encode(["geminiFlash": "low"]), forKey: SettingsKey.reasoningEfforts.defaultsKey)
            let settings = load(defaults)
            #expect(settings.reasoningEffort(for: .geminiFlash) == .high)
            #expect(settings.reasoningEffort(for: .geminiArgon) == .medium)
            #expect(settings.reasoningEffort(for: .parakeet) == nil)
            #expect(defaults.object(forKey: SettingsKey.reasoningEfforts.defaultsKey) == nil)
            settings.reasoningEfforts[.geminiArgon] = .minimal
            settings.reasoningEfforts[.geminiArgon] = .off
            #expect(settings.reasoningEffort(for: .geminiArgon) == .medium, "levels it doesn't take are refused")
            settings.reasoningEfforts[.geminiArgon] = .low
            #expect(load(defaults).reasoningEffort(for: .geminiArgon) == .low)
        }
    }

    @Test(arguments: ["parakeetCloud", "geminiPro", "parakeet", "junk"])
    func callsNeedAGeminiThisBuildRuns(_ raw: String) throws {
        try withDefaults { defaults in
            defaults.set(raw, forKey: SettingsKey.callEngine.defaultsKey)
            #expect(load(defaults).callEngine == .geminiFlash)
        }
        let settings = AppSettings.inMemory()
        settings.callEngine = .geminiArgon
        #expect(settings.callModel == CallModel(engine: .geminiArgon, effort: .medium))
        settings.reasoningEfforts[.geminiArgon] = .high
        #expect(settings.callModel == CallModel(engine: .geminiArgon, effort: .high))
        settings.callEngine = .parakeet
        #expect(settings.callEngine == .geminiFlash)
    }
}

// MARK: - Requests

@MainActor
@Suite struct ArgonRequestTests {
    private func service(_ replies: [StubURLProtocol.Reply]) -> (TranscriptionService, String) {
        let (client, host) = StubURLProtocol.client(replies)
        let account = OpenRouterAccount(keyStore: .inMemory("sk-or-v1-test"), client: client, debounce: .zero)
        return (TranscriptionService(models: ModelStore.preview(states: [:]), account: account, client: client), host)
    }

    private let speech = Recording(samples: [Float](repeating: 0.1, count: 16_000))

    /// Each Gemini model goes with its own slug, at the level picked for it, pinned to Google AI Studio, with its own
    /// stall timeout.
    @Test func eachModelGoesWithItsSlugAndItsLevel() async throws {
        let (service, host) = service([.stream(SSE.answer("<transcript>Argon.</transcript>")),
                                       .stream(SSE.answer("<transcript>Flash.</transcript>"))])
        service.reasoningEffort = { [.geminiArgon: ReasoningEffort.high, .geminiFlash: .low][$0] }
        let argon = try await service.transcribe(speech, engine: .geminiArgon)
        let flash = try await service.transcribe(speech, engine: .geminiFlash)
        #expect(argon.text == "Argon." && argon.reasoningEffort == .high && argon.engine == .geminiArgon)
        #expect(flash.text == "Flash." && flash.reasoningEffort == .low)
        let bodies = try StubURLProtocol.registry.bodies(for: host).map(json)
        #expect(bodies.map { $0["model"] as? String } == ["google/gemini-4-argon", "google/gemini-3.8-flash"])
        #expect(bodies.map { ($0["reasoning"] as? [String: Any])?["effort"] as? String } == ["high", "low"])
        #expect(bodies.allSatisfy { ($0["provider"] as? [String: Any])?["only"] as? [String] == ["google-ai-studio"] })
        #expect(bodies.map { $0["max_tokens"] as? Int } == [32_768 + 16_384, 32_768], "high thinks longer")
        let timeouts = StubURLProtocol.registry.requests(for: host).map(\.timeoutInterval)
        #expect(timeouts == [240, 120])
        #expect(argon.metadata().modelID == "google/gemini-4-argon" && argon.metadata().reasoningEffort == .high)
    }

    /// `--effort` (or any caller's own level) wins over the one picked.
    @Test func anExplicitLevelWins() async throws {
        let (service, host) = service([.stream(SSE.answer("<transcript>x</transcript>"))])
        service.reasoningEffort = { _ in .high }
        _ = try await service.transcribe(speech, engine: .geminiArgon, effort: .low)
        let body = try json(try #require(StubURLProtocol.registry.bodies(for: host).first))
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "low")
    }

    /// Without the app's settings (the CLI) each model thinks at its default, Medium.
    @Test func theDefaultLevelIsMedium() {
        let (service, _) = service([])
        #expect(service.reasoningEffort(.geminiArgon) == .medium && service.reasoningEffort(.geminiFlash) == .medium)
        #expect(service.reasoningEffort(.parakeet) == nil)
    }

    /// A selection's model goes at the level it's asked for: Flash's and Argon's own model IDs, Medium by default.
    @Test func polishSelectionGoesAtTheModelsLevel() throws {
        let route = try #require(PolishSelectionModel.geminiFlash.route(effort: .high))
        #expect(route.model == "google/gemini-3.8-flash" && route.effort == "high" && route.streamsReasoning)
        #expect(PolishSelectionModel.geminiFlash.route?.effort == "medium")
        let argon = try #require(PolishSelectionModel.geminiArgon.route(effort: .low))
        #expect(argon.model == "google/gemini-4-argon" && argon.effort == "low" && argon.streamsReasoning)
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
    /// The audio request and the summary's text request go to the model picked for calls, at its level, read as each
    /// request goes.
    @Test func bothRequestsFollowTheCallModel() async throws {
        let (client, host) = StubURLProtocol.client([.stream(SSE.answer("[00:00-00:02] Anna: Hi.")),
                                                     .stream(SSE.answer("<summary>Hi.</summary>")),
                                                     .stream(SSE.answer("[00:00-00:02] Anna: Hi."))])
        let account = OpenRouterAccount(keyStore: .inMemory("sk-or-v1-test"), client: client, debounce: .zero)
        var model = CallModel(engine: .geminiArgon, effort: .high)
        let send = CallTranscriber.openRouter(client: client, account: account, model: { model })
        let sendText = CallTranscriber.openRouterText(client: client, account: account, model: { model })
        _ = try await send(Data([1, 2]), "Transcribe the call.", 2, nil)
        _ = try await sendText("Anna: Hi.", "Sum it up.")
        model = CallModel(engine: .geminiFlash, effort: .low)
        _ = try await send(Data([1, 2]), "Transcribe the call.", 2, nil)
        let bodies = try StubURLProtocol.registry.bodies(for: host).map(json)
        #expect(bodies.map { $0["model"] as? String }
                == ["google/gemini-4-argon", "google/gemini-4-argon", "google/gemini-3.8-flash"])
        #expect(bodies.map { ($0["reasoning"] as? [String: Any])?["effort"] as? String } == ["high", "high", "low"])
        #expect(StubURLProtocol.registry.requests(for: host).first?.timeoutInterval == 240)
    }

    /// Through the user's endpoint too: the same slug, which it takes without "google/".
    @Test func theProxyGetsTheCallModel() async throws {
        let (proxy, proxyHost) = ProxyFixture.proxy([.stream(SSE.answer("[00:00-00:02] Sam: Hi.")),
                                                     .stream(SSE.answer("Summary."))])
        let (client, openRouterHost) = StubURLProtocol.client([])
        let account = OpenRouterAccount(keyStore: .inMemory(nil), client: client, debounce: .zero)
        let model = CallModel(engine: .geminiArgon, effort: .low)
        let send = CallTranscriber.openRouter(client: client, account: account, proxy: proxy, model: { model })
        let sendText = CallTranscriber.openRouterText(client: client, account: account, proxy: proxy, model: { model })
        _ = try await send(Data([1, 2]), "The call.", 2, nil)
        _ = try await sendText("Sam: Hi.", "Sum it up.")
        let bodies = try StubURLProtocol.registry.bodies(for: proxyHost).map(json)
        #expect(bodies.map { $0["model"] as? String } == ["google/gemini-4-argon", "google/gemini-4-argon"])
        #expect(bodies.map { ($0["reasoning"] as? [String: Any])?["effort"] as? String } == ["low", "low"])
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).isEmpty)
    }

    @Test func theDefaultCallModelIsFlashAtMedium() {
        #expect(CallModel.default == CallModel(engine: .geminiFlash, effort: .medium))
        #expect(AppSettings.inMemory().callModel == .default)
        #expect(CallModel(engine: .geminiArgon, effort: .high).modelID == "google/gemini-4-argon")
    }
}

// MARK: - Dictation

@MainActor
@Suite(.serialized) struct ArgonDictationTests {
    typealias Rig = DictationResumeTests.Rig

    /// fn ⇥ reaches Argon once it's switched on, in the lineup's order, and the dictation goes to it.
    @Test func switchModelStepsToArgon() async throws {
        let (rig, _) = SwitchModelControllerTests.make()
        let c = rig.h.controller
        rig.h.settings.lineup.setSwitchable(.argon, true)
        var used: [EngineID] = []
        rig.result = { _, engine in
            used.append(engine)
            return "words"
        }
        SwitchModelControllerTests.hold(rig)
        var choices: [ModelChoice?] = []
        for _ in 0..<3 {
            c.handle(.cycleEngine)
            choices.append(c.modelOverride)
        }
        #expect(choices == [.gemini, .argon, nil])
        c.handle(.cycleEngine)
        c.handle(.cycleEngine)
        #expect(c.effectiveEngine == .geminiArgon && rig.h.pill.sessionModel == .argon)
        try await SwitchModelControllerTests.release(rig)
        #expect(used == [.geminiArgon])
        #expect(rig.h.history.entries.first?.engine == .geminiArgon)
    }

    /// Polish on Argon is Argon's: the version says so, and its paste follows Argon's rules.
    @Test func polishOnArgonIsArgons() async throws {
        let (rig, _) = SwitchModelControllerTests.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .argon
        var used: [EngineID] = []
        rig.result = { _, engine in
            used.append(engine)
            return "<message>Polished.</message>"
        }
        SwitchModelControllerTests.hold(rig)
        c.handle(.polish)
        #expect(c.isPolishing)
        try await SwitchModelControllerTests.release(rig)
        #expect(used == [.geminiArgon])
        let entry = try #require(rig.h.history.entries.first)
        #expect(entry.currentKind == .polish(by: .geminiArgon))
        #expect(entry.currentKind?.dictationModel == .argon)
        #expect(entry.currentVersion.map(VersionDetails.lines)?.first == "Polished by Gemini 4 Argon")
    }
}

// MARK: - CLI

@Suite struct ArgonCLITests {
    private func options(_ extra: String...) -> EngineCLI.Options? {
        EngineCLI.Options(["transcribe-thing", "--transcribe", "/tmp/memo.m4a"] + extra)
    }

    @Test func argonIsAnEngineAndCloudParakeetIsNot() {
        #expect(options("--engine", "geminiArgon")?.engine == .geminiArgon)
        #expect(options("--engine", "argon")?.engine == .geminiArgon)
        #expect(options("--engine", "gemini-4-argon")?.engine == .geminiArgon)
        #expect(options("--engine", "parakeetCloud") == nil)
        #expect(options("--engine", "cloudParakeet") == nil)
        #expect(options("--engine", "geminiPro") == nil)
        #expect(options("--engine", "parakeetCloud", "--speech-model", "openai/whisper") == nil)
        #expect(EngineCLI.Options.usage.contains("--engine parakeet|geminiFlash|geminiArgon"))
        #expect(!EngineCLI.Options.usage.contains("parakeetCloud"))
    }

    @Test func modelStatusListsTheCloudModels() {
        let lines = EngineCLI.cloudModelLines()
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("geminiFlash") && lines[0].contains("google/gemini-3.8-flash"))
        #expect(lines[1].hasPrefix("geminiArgon") && lines[1].contains("Gemini 4 Argon")
                && lines[1].contains("google/gemini-4-argon"))
        #expect(lines.allSatisfy { $0.hasSuffix("effort low|medium|high (default medium)") })
        #expect(!lines.joined().contains("parakeet"))
    }
}
