import Foundation
import Testing
@testable import TranscribeThing

// Gemini 3.1 Pro, Gemini 3.5 Flash Lite, Parakeet v3 · Cloud, Gemini 4 Argon, Parakeet v3 on this Mac, GigaAM v3 e2e
// and GigaAM Multilingual are retired: History keeps reading, naming and drawing what they wrote, settings an older
// build stored about them (and the Thinking levels and clean-up model choice that are gone) load as the model that took
// their place, nothing runs them, and the files a retired model on this Mac left are listed to delete, never deleted
// by themselves.

/// A history file as the app writes it: a transcript only Gemini 3.1 Pro wrote, one where Pro's version is current
/// over Parakeet's and Flash Lite's clean-up, a cloud Parakeet one showing Flash Lite's clean-up, and a failed Pro
/// dictation.
private let historyFile = #"""
{"version":1,"entries":[
 {"id":"0A6F2C4E-1111-4A7B-9C3D-5E6F7A8B9C01","createdAt":"2026-09-20T09:00:00.000Z","status":"success",
  "audioDuration":17.9,"voicedSeconds":15.4,"engine":"geminiPro","text":"Only Pro heard this.","costUSD":0.0094,
  "provider":"Google AI Studio","processingTime":6.8,"currentVersion":"geminiPro",
  "versions":[{"kind":"geminiPro","text":"Only Pro heard this.","metadata":{"createdAt":"2026-09-20T09:00:00.000Z",
    "modelID":"google/gemini-3.1-pro-preview","provider":"Google AI Studio","generationID":"gen-pro","reasoningEffort":"high",
    "usage":{"promptTokens":900,"audioTokens":860,"cachedTokens":0,"completionTokens":4200,"reasoningTokens":4000,"totalTokens":5100},
    "costUSD":0.0094,"processingTime":6.8,"generationTime":6.1,"usedSystemPrompt":true,"finishReason":"stop"}}]},
 {"id":"0A6F2C4E-2222-4A7B-9C3D-5E6F7A8B9C02","createdAt":"2026-09-19T09:00:00.000Z","status":"success",
  "audioDuration":40,"voicedSeconds":35,"engine":"geminiPro","text":"Pro again.","audioFileName":"two.wav",
  "currentVersion":"geminiPro",
  "versions":[{"kind":"parakeet","text":"um pro again","metadata":{"createdAt":"2026-09-19T09:00:00.000Z","processingTime":0.4}},
              {"kind":"cleanup:parakeet","text":"Pro again?","metadata":{"createdAt":"2026-09-19T09:00:02.000Z",
                "modelID":"google/gemini-3.5-flash-lite","provider":"Google AI Studio","reasoningEffort":"low",
                "costUSD":0.0003,"processingTime":1.4,"usedSystemPrompt":true,"finishReason":"stop"}},
              {"kind":"geminiPro","text":"Pro again.","metadata":{"createdAt":"2026-09-19T09:01:00.000Z",
                "modelID":"google/gemini-3.1-pro-preview","reasoningEffort":"high","processingTime":9.2}}]},
 {"id":"0A6F2C4E-3333-4A7B-9C3D-5E6F7A8B9C03","createdAt":"2026-09-18T09:00:00.000Z","status":"success",
  "audioDuration":5,"voicedSeconds":4,"engine":"parakeetCloud","text":"Tidied.","provider":"Google AI Studio",
  "currentVersion":"cleanup:parakeetCloud",
  "versions":[{"kind":"parakeetCloud","text":"tidied","metadata":{"createdAt":"2026-09-18T09:00:00.000Z","provider":"Together"}},
              {"kind":"cleanup:parakeetCloud","text":"Tidied.","metadata":{"createdAt":"2026-09-18T09:00:01.000Z",
                "modelID":"google/gemini-3.5-flash-lite","provider":"Google AI Studio","reasoningEffort":"minimal"}}]},
 {"id":"0A6F2C4E-4444-4A7B-9C3D-5E6F7A8B9C04","createdAt":"2026-09-17T09:00:00.000Z","status":"failed",
  "audioDuration":23.4,"voicedSeconds":19.8,"engine":"geminiPro","text":"","errorMessage":"Gemini Pro took too long",
  "audioFileName":"failed.wav"}
]}
"""#

@Suite struct RetiredModelHistoryTests {
    private func entries() throws -> [TranscriptEntry] {
        try HistoryStore.readEntries(from: Data(historyFile.utf8))
    }

    @Test func aTranscriptOnlyGemini31ProWroteReadsAsBefore() throws {
        let entries = try entries()
        #expect(entries.count == 4, "no entry is lost")
        let pro = try #require(entries.first)
        #expect(pro.engine == .geminiPro && pro.status == .success)
        #expect(pro.versions.map(\.kind) == [.transcription(.geminiPro)])
        #expect(pro.currentKind == .transcription(.geminiPro) && pro.text == "Only Pro heard this.")
        #expect(pro.currentKind?.displayName == "Gemini 3.1 Pro" && pro.engine.shortName == "Gemini 3.1 Pro")
        #expect(pro.engine.glyph == "Pro" && pro.costUSD == 0.0094 && pro.provider == "Google AI Studio")
        let version = try #require(pro.currentVersion)
        #expect(VersionDetails.lines(for: version) == [
            "Gemini 3.1 Pro",
            "google/gemini-3.1-pro-preview via Google AI Studio",
            "Reasoning: High",
            "Tokens: 900 in (860 audio) · 200 out · 4k thinking",
            "Cost: $0.0094",
            "Took 6.8 s · model 6.1 s",
            "System prompt: yes",
        ])
    }

    @Test func retiredVersionsBesideOthersKeepTheirPlaceAndNames() throws {
        let entries = try entries()
        let mixed = entries[1]
        #expect(mixed.versions.map(\.kind) == [.transcription(.parakeet), .cleanup(of: .parakeet, by: .geminiFlashLite),
                                               .transcription(.geminiPro)])
        #expect(mixed.versions.map(\.kind.displayName)
                == ["Parakeet v3", "Parakeet v3 + Clean-up by Flash Lite", "Gemini 3.1 Pro"])
        #expect(mixed.currentKind == .transcription(.geminiPro) && mixed.text == "Pro again.",
                "the current version stays a retired model's")
        #expect(mixed.version(.cleanup(of: .parakeet, by: .geminiFlashLite))?.metadata.reasoningEffort == .low)

        let tidied = entries[2]
        #expect(tidied.currentKind == .cleanup(of: .parakeetCloud, by: .geminiFlashLite) && tidied.text == "Tidied.")
        #expect(EngineGlyph(engine: tidied.engine, provider: tidied.provider, cleanupModel: tidied.currentKind?.cleanupModel).label
                == "Parakeet v3 · Cloud + Clean-up by Flash Lite · via Google AI Studio")
        #expect(tidied.currentVersion.map(VersionDetails.lines)?.contains("Reasoning: Minimal") == true)

        let failed = entries[3]
        #expect(failed.status == .failed && failed.engine == .geminiPro && failed.versions.isEmpty)
        #expect(failed.errorMessage == "Gemini Pro took too long")
    }

    /// Saved again (after any change to the history), retired versions are written as they were read.
    @Test func retiredVersionsAreWrittenBackUnchanged() throws {
        let entries = try entries()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for entry in entries {
            #expect(try decoder.decode(TranscriptEntry.self, from: encoder.encode(entry)) == entry)
        }
        let json = String(decoding: try encoder.encode(entries[1]), as: UTF8.self)
        #expect(json.contains(#""kind":"geminiPro""#) && json.contains(#""kind":"cleanup:parakeet""#))
        #expect(json.contains(#""currentVersion":"geminiPro""#))
    }
}

// MARK: - Settings

@MainActor
@Suite struct RetiredModelSettingsTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        try body(defaults)
    }

    private func load(_ defaults: UserDefaults) -> AppSettings {
        AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() })
    }

    /// Everything an older build could have stored about the retired models, the Thinking levels and the clean-up
    /// model choice.
    private func storeOldSettings(_ defaults: UserDefaults, switchEngines: [String]) throws {
        defaults.set("geminiPro", forKey: SettingsKey.selectedEngine.defaultsKey)
        defaults.set(try JSONEncoder().encode(switchEngines), forKey: SettingsKey.switchEngines.defaultsKey)
        defaults.set(try JSONEncoder().encode(["geminiFlash": "high", "geminiPro": "low"]),
                     forKey: SettingsKey.reasoningEfforts.defaultsKey)
        defaults.set("geminiFlashLite", forKey: SettingsKey.cleanupModel.defaultsKey)
        defaults.set(try JSONEncoder().encode(["geminiFlashLite": "minimal", "gpt6Luna": "high"]),
                     forKey: SettingsKey.cleanupReasoningEfforts.defaultsKey)
        defaults.set("medium", forKey: SettingsKey.cleanupReasoningEffort.defaultsKey)
    }

    @Test func storedRetiredModelsAndLevelsLoadWithoutThem() throws {
        try withDefaults { defaults in
            try storeOldSettings(defaults, switchEngines: ["geminiFlash", "geminiPro"])
            let settings = load(defaults)
            // Gemini 3.1 Pro was the main model: Gemini 3.8 Flash is, and the old key goes.
            #expect(defaults.object(forKey: SettingsKey.selectedEngine.defaultsKey) == nil)
            #expect(settings.lineup.main == .gemini)
            #expect(settings.lineup.cycle == [.gemini, .gigaam])
            for key in [SettingsKey.reasoningEfforts, .cleanupModel, .cleanupReasoningEfforts, .cleanupReasoningEffort] {
                #expect(defaults.object(forKey: key.defaultsKey) == nil, "\(key) is removed at load")
            }
            #expect(load(defaults).lineup == settings.lineup, "and again next launch")
        }
        try withDefaults { defaults in
            try storeOldSettings(defaults, switchEngines: ["geminiPro"])
            let settings = load(defaults)
            #expect(!settings.lineup.switchable.contains(.gemini) && settings.lineup.switchable.contains(.gigaam),
                    "Pro alone taking part isn't Flash taking part")
        }
    }

    /// The old levels never reach a request: Gemini 3.8 Flash thinks at medium, its default.
    @Test func oldStoredLevelsNeverReachTheWire() async throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        try storeOldSettings(defaults, switchEngines: ["geminiFlash", "geminiPro"])
        _ = load(defaults)
        let replies = [StubURLProtocol.Reply.stream(SSE.answer("Hallo."))]
        let (client, host) = StubURLProtocol.client(replies)
        let keyStore = KeyFileStore.inMemory("sk-or-v1-test")
        let account = OpenRouterAccount(keyStore: keyStore, client: client, debounce: .zero)
        let service = TranscriptionService(models: ModelStore.preview(states: [:]), account: account, client: client)
        let transcribed = try await service.transcribe(Recording(samples: [Float](repeating: 0.1, count: 16_000)),
                                                       engine: .geminiFlash)
        #expect(transcribed.reasoningEffort == .medium)
        let bodies = try StubURLProtocol.registry.bodies(for: host).map {
            try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        #expect(bodies.map { $0["model"] as? String } == ["google/gemini-3.8-flash"])
        #expect(bodies.map { $0["reasoning"] as? [String: AnyHashable] } == [["effort": "medium", "exclude": false]])
    }
}

// MARK: - Never run

@MainActor
@Suite struct RetiredModelRunTests {
    @Test func gemini31ProNeverRuns() async throws {
        let (client, host) = StubURLProtocol.client([StubURLProtocol.Reply.stream(SSE.answer("Hallo."))])
        let keyStore = KeyFileStore.inMemory("sk-or-v1-test")
        let account = OpenRouterAccount(keyStore: keyStore, client: client, debounce: .zero)
        let service = TranscriptionService(models: ModelStore.preview(states: [:]), account: account, client: client)
        await #expect(throws: AppError.self) {
            try await service.transcribe(Recording(samples: [Float](repeating: 0.1, count: 16_000)), engine: .geminiPro)
        }
        #expect(StubURLProtocol.registry.requests(for: host).isEmpty)
    }

    @Test func gemini4ArgonNeverRuns() async throws {
        let (client, host) = StubURLProtocol.client([StubURLProtocol.Reply.stream(SSE.answer("Hallo."))])
        let account = OpenRouterAccount(keyStore: .inMemory("sk-or-v1-test"), client: client, debounce: .zero)
        let service = TranscriptionService(models: ModelStore.preview(states: [:]), account: account, client: client)
        await #expect(throws: AppError.self) {
            try await service.transcribe(Recording(samples: [Float](repeating: 0.1, count: 16_000)), engine: .geminiArgon)
        }
        #expect(StubURLProtocol.registry.requests(for: host).isEmpty)
        #expect(PolishSelectionModel.geminiArgon.route == nil, "nor polishes a selection")
    }

    @Test func nothingOffersARetiredModel() {
        #expect(!EngineID.offered.contains(.parakeet))
        #expect(!EngineID.offered.contains(.geminiPro))
        #expect(!EngineID.offered.contains(.parakeetCloud))
        #expect(!EngineID.offered.contains(.geminiArgon))
        #expect(!EngineID.offered.contains(.geminiHydrogen) && !EngineID.offered.contains(.geminiCarbon))
        #expect(EngineID.geminiEngines == [.geminiFlash, .geminiNeon])
        #expect(TranscriptVersionKind.rewrites == [.polish(by: .geminiFlash), .polish(by: .geminiNeon),
                                                   .translation(polished: false, by: .geminiFlash),
                                                   .translation(polished: false, by: .geminiNeon)])
        #expect(AppSettings.inMemory().lineup.cycle.map { $0.engine }
                == [.gigaam, .geminiFlash])
        #expect(ModelLineup.default.order == ModelChoice.allCases
                && ModelChoice.allCases == [.gigaam, .gemini, .neon])
        for engine in EngineID.allCases {
            #expect(DictationController.fallbackCandidates(for: engine).allSatisfy { !$0.isRetired })
        }
        #expect(ModelChoice(engine: .geminiPro) == .gemini, "a job it made reads as Gemini")
        #expect(ModelChoice(engine: .geminiArgon) == .gemini, "a job it made reads as Gemini")
        #expect(ModelChoice(engine: .parakeet) == .gigaam, "a job it made reads as GigaAM")
        // A lineup stored with Parakeet as the main model and Argon in it reads as GigaAM and Flash: a file goes to
        // what's offered.
        let stored = Data(#"{"main":"parakeet","order":["parakeet","argon"],"switchable":["argon"]}"#.utf8)
        let lineup = (try? JSONDecoder().decode(ModelLineup.self, from: stored)) ?? .default
        #expect(lineup.main == .gigaam)
        let imports = ImportChoices.make(lineup: lineup) { _ in .ready }
        let kinds = ImportChoices.Mode.allCases.flatMap { imports.rows($0) }.compactMap(\.kind)
        #expect(kinds.allSatisfy { $0.isOffered && !$0.engine.isRetired })
        #expect(TranscriptVersionKind.transcripts.allSatisfy { $0.isOffered && $0.gigaamVariant?.isRetired != true })
    }

    /// `--engine` takes the models the app runs: GigaAM, Gemini 3.8 Flash and Gemini 4 Neon, by any spelling. The
    /// retired ones are no engine at all.
    @Test func theCLITakesOnlyTheModelsTheAppRuns() {
        func options(_ extra: String...) -> EngineCLI.Options? {
            EngineCLI.Options(["transcribe-thing", "--transcribe", "/tmp/memo.m4a"] + extra)
        }
        #expect(options("--engine", "geminiFlash")?.engine == .geminiFlash)
        #expect(options("--engine", "gemini-flash")?.engine == .geminiFlash)
        #expect(options("--engine", "gigaam")?.engine == .gigaam)
        for retired in ["geminiArgon", "argon", "gemini-4-argon", "parakeetCloud", "cloudParakeet", "geminiPro",
                        "parakeet", "Parakeet", "geminiHydrogen", "hydrogen", "geminiCarbon", "carbon"] {
            #expect(options("--engine", retired) == nil, "\(retired)")
        }
        #expect(options("--engine", "parakeetCloud", "--speech-model", "openai/whisper") == nil)
        #expect(EngineCLI.Options.usage.contains("--engine gigaam|geminiFlash|geminiNeon "))
        #expect(!EngineCLI.Options.usage.contains("parakeet") && !EngineCLI.Options.usage.contains("Argon"))
        let lines = EngineCLI.cloudModelLines()
        #expect(lines.count == 2 && !lines.joined().contains("argon") && !lines.joined().contains("carbon"))
        #expect(lines[0].hasPrefix("geminiFlash") && lines[0].contains("google/gemini-3.8-flash"))
        #expect(lines[0].hasSuffix("effort low|medium|high (default medium)"))
    }
}

// MARK: - Gemini 4 Hydrogen and Gemini 4 Carbon

@Suite struct RetiredHydrogenAndCarbonTests {
    /// What Gemini 4 Hydrogen and Carbon wrote stays in History under their names, in the color of Neon, which took
    /// their place; nothing offers them, and what's made from a row of theirs is a model's this build runs.
    @Test func theirVersionsStayAndNothingOffersThem() {
        for engine in [EngineID.geminiHydrogen, .geminiCarbon] {
            #expect(engine.isRetired && engine.replacement == .geminiNeon)
            #expect(ModelColors.default.color(of: engine) == ModelChoice.neon.defaultColor)
            for kind in [TranscriptVersionKind.transcription(engine), .polish(by: engine),
                         .translation(polished: true, by: engine)] {
                #expect(TranscriptVersionKind(rawValue: kind.rawValue) == kind, "\(kind.rawValue)")
            }
            let entry = TranscriptEntry(text: "x", engine: engine, audioDuration: 20, voicedSeconds: 10,
                                        audioFileName: "a.wav")
            let menu = VersionsMenu.make(for: entry, running: nil, readiness: { _ in .ready })
            #expect(menu.versions.map(\.kind) == [.transcription(engine)])
            #expect(!menu.actions.isEmpty && menu.actions.allSatisfy { !$0.kind.engine.isRetired })
        }
        #expect(EngineID.geminiHydrogen.modelName == "Gemini 4 Hydrogen")
        #expect(EngineID.geminiCarbon.modelName == "Gemini 4 Carbon")
    }
}

// MARK: - Parakeet v3 · Cloud

@MainActor
@Suite struct CloudParakeetRemovalSettingsTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        try body(defaults)
    }

    private func load(_ defaults: UserDefaults) -> AppSettings {
        AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() })
    }

    /// Parakeet ran through OpenRouter: the main model, hands-free and Pasting's rules said "Parakeet", and the
    /// runtime key said where. Parakeet is retired on this Mac too: the key goes, and GigaAM has what was Parakeet's.
    @Test func settingsThatChoseCloudParakeetRunGigaAMOnThisMac() throws {
        try withDefaults { defaults in
            defaults.set("parakeetCloud", forKey: SettingsKey.selectedEngine.defaultsKey)
            var lineup = ModelLineup.default
            lineup.main = .gemini
            defaults.set(try JSONEncoder().encode(lineup), forKey: SettingsKey.lineup.defaultsKey)
            defaults.set("parakeet", forKey: SettingsKey.handsFreeModel.defaultsKey)
            defaults.set(try JSONEncoder().encode(["parakeet"]), forKey: SettingsKey.modelsAddingSpace.defaultsKey)
            let settings = load(defaults)
            #expect(settings.handsFreeModel == .gigaam && settings.handsFreeChoice == .gigaam)
            #expect(settings.handsFreeChoice?.engine == .gigaam)
            #expect(settings.modelsAddingSpace == [.gigaam], "GigaAM, new since, starts with Parakeet's")
            #expect(settings.usesLocalModel(.gigaam), "GigaAM in the cycle is worth loading")
            #expect(defaults.object(forKey: SettingsKey.selectedEngine.defaultsKey) == nil)

            defaults.set(try JSONEncoder().encode(ModelLineup.default), forKey: SettingsKey.lineup.defaultsKey)
            defaults.set("parakeetCloud", forKey: SettingsKey.selectedEngine.defaultsKey)
            #expect(load(defaults).mainEngine == .gigaam, "the main model on OpenRouter is the one on this Mac")
        }
    }
}


// MARK: - Gemini 4 Argon

/// A history file with what Gemini 4 Argon wrote, in the forms the app stored it: a transcript only Argon heard (its
/// slug written with an escaped slash, as JSONEncoder writes it), a Parakeet transcript Argon polished and translated
/// (the polish current), a selection Argon polished, and a long dictation Argon heard no speech in.
private let argonHistoryFile = #"""
{"version":1,"entries":[
 {"id":"1B7A3D5F-1111-4C8D-9E0F-6A7B8C9D0E01","createdAt":"2026-10-14T09:00:00.000Z","status":"success",
  "audioDuration":12.5,"voicedSeconds":10.1,"engine":"geminiArgon","text":"Argon heard this.","costUSD":0.0123,
  "provider":"Google AI Studio","processingTime":9.4,"currentVersion":"geminiArgon","audioFileName":"argon.m4a",
  "versions":[{"kind":"geminiArgon","text":"Argon heard this.","metadata":{"createdAt":"2026-10-14T09:00:00.000Z",
    "modelID":"google\/gemini-4-argon","provider":"Google AI Studio","generationID":"gen-argon","reasoningEffort":"high",
    "costUSD":0.0123,"processingTime":9.4,"usedSystemPrompt":true,"finishReason":"stop"}}]},
 {"id":"1B7A3D5F-2222-4C8D-9E0F-6A7B8C9D0E02","createdAt":"2026-10-14T08:00:00.000Z","status":"success",
  "audioDuration":30,"voicedSeconds":25,"engine":"parakeet","text":"Polished by Argon.","audioFileName":"two.m4a",
  "currentVersion":"polish:geminiArgon",
  "versions":[{"kind":"parakeet","text":"um polished by argon","metadata":{"createdAt":"2026-10-14T08:00:00.000Z","processingTime":0.4}},
              {"kind":"polish:geminiArgon","text":"Polished by Argon.","metadata":{"createdAt":"2026-10-14T08:01:00.000Z",
                "modelID":"google\/gemini-4-argon","reasoningEffort":"medium","processingTime":11.2}},
              {"kind":"translation:geminiArgon","text":"Отполировал Argon.","metadata":{"createdAt":"2026-10-14T08:02:00.000Z",
                "modelID":"google\/gemini-4-argon","reasoningEffort":"medium"}}]},
 {"id":"1B7A3D5F-3333-4C8D-9E0F-6A7B8C9D0E03","createdAt":"2026-10-14T07:00:00.000Z","status":"success",
  "audioDuration":0,"voicedSeconds":0,"engine":"geminiArgon","text":"Selected, then polished.",
  "currentVersion":"selection:geminiArgon",
  "versions":[{"kind":"selection:geminiArgon","text":"Selected, then polished.","metadata":{"createdAt":"2026-10-14T07:00:00.000Z",
    "modelID":"google\/gemini-4-argon","reasoningEffort":"medium"}}]},
 {"id":"1B7A3D5F-4444-4C8D-9E0F-6A7B8C9D0E04","createdAt":"2026-10-14T06:00:00.000Z","status":"failed",
  "audioDuration":32,"voicedSeconds":21.67,"engine":"geminiArgon","text":"","errorMessage":"Gemini 4 Argon heard no speech",
  "modelAnswer":"<message>\n\n</message>","audioFileName":"failed.m4a"}
]}
"""#

@Suite struct RetiredArgonHistoryTests {
    private func entries() throws -> [TranscriptEntry] {
        try HistoryStore.readEntries(from: Data(argonHistoryFile.utf8))
    }

    @Test func aTranscriptOnlyArgonWroteReadsUnderItsName() throws {
        let entries = try entries()
        #expect(entries.count == 4, "no entry is lost")
        let argon = try #require(entries.first)
        #expect(argon.engine == .geminiArgon && argon.status == .success && argon.text == "Argon heard this.")
        #expect(argon.versions.map(\.kind) == [.transcription(.geminiArgon)])
        #expect(argon.currentKind?.displayName == "Gemini 4 Argon" && argon.engine.shortName == "Gemini 4 Argon")
        #expect(argon.engine.glyph == "A" && argon.costUSD == 0.0123 && argon.provider == "Google AI Studio")
        #expect(EngineGlyph(engine: argon.engine).label == "Gemini 4 Argon")
        #expect(EngineGlyph(engine: argon.engine).color == ModelColors.default[.gemini], "it wears Flash's color")
        let lines = VersionDetails.lines(for: try #require(argon.currentVersion))
        #expect(Array(lines.prefix(3))
                == ["Gemini 4 Argon", "google/gemini-4-argon via Google AI Studio", "Reasoning: High"])
    }

    @Test func argonsPolishTranslationAndSelectionReadUnderItsName() throws {
        let entries = try entries()
        let rewritten = entries[1]
        #expect(rewritten.versions.map(\.kind) == [.transcription(.parakeet), .polish(by: .geminiArgon),
                                                   .translation(polished: false, by: .geminiArgon)])
        #expect(rewritten.versions.map(\.kind.displayName)
                == ["Parakeet v3", "Polished by Gemini 4 Argon", "Translated by Gemini 4 Argon"])
        #expect(rewritten.currentKind == .polish(by: .geminiArgon) && rewritten.text == "Polished by Argon.",
                "the current version stays Argon's")
        #expect(rewritten.currentKind?.dictationModel == .gemini, "pasted again by Gemini's rules")

        let selection = entries[2]
        #expect(selection.isSelection && selection.currentKind == .selection(.geminiArgon))
        #expect(selection.currentKind?.displayName == "Selection polished by Gemini 4 Argon")
        #expect(selection.text == "Selected, then polished.")

        let failed = entries[3]
        #expect(failed.status == .failed && failed.engine == .geminiArgon && failed.versions.isEmpty)
        #expect(failed.errorMessage == "Gemini 4 Argon heard no speech")
        #expect(failed.modelAnswer == "<message>\n\n</message>")
    }

    /// Saved again (after any change to the history), Argon's versions are written as they were read.
    @Test func argonsVersionsAreWrittenBackUnchanged() throws {
        let entries = try entries()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for entry in entries {
            #expect(try decoder.decode(TranscriptEntry.self, from: encoder.encode(entry)) == entry)
        }
        let json = String(decoding: try encoder.encode(entries), as: UTF8.self)
        for raw in [#""kind":"geminiArgon""#, #""kind":"polish:geminiArgon""#, #""kind":"translation:geminiArgon""#,
                    #""kind":"selection:geminiArgon""#, #""currentVersion":"polish:geminiArgon""#,
                    #""engine":"geminiArgon""#] {
            #expect(json.contains(raw), "\(raw)")
        }
    }

    /// Whatever is made from an Argon row now is a model's this build runs (Gemini 3.8 Flash or Gemini 4 Neon, or
    /// GigaAM), never Argon's: Transcribe With, Polish and Translate, and a failed row's Retry With.
    @Test func nothingMadeFromAnArgonRowIsArgons() throws {
        let entries = try entries()
        let ready: (TranscriptVersionKind) -> EngineReadiness = { _ in .ready }
        let geminis: [TranscriptVersionKind] = [.transcription(.geminiFlash), .transcription(.geminiNeon)]
        let rewrites = TranscriptVersionKind.rewrites
        let argon = VersionsMenu.make(for: entries[0], running: nil, readiness: ready)
        #expect(argon.versions.map(\.kind) == [.transcription(.geminiArgon)])
        let gigaams: [TranscriptVersionKind] = [.gigaam(.v3)]
        let locals = gigaams
        #expect(argon.actions.map(\.kind) == locals + geminis + rewrites)
        #expect(argon.actions.allSatisfy { $0.isEnabled })

        let rewritten = VersionsMenu.make(for: entries[1], running: nil, readiness: ready)
        #expect(rewritten.actions.map(\.kind) == gigaams + geminis + rewrites,
                "Argon's polish and translation don't stand in for Flash's or Neon's")

        let failed = VersionsMenu.make(for: entries[3], running: nil, readiness: ready)
        #expect(failed.isRetry && failed.title == "Retry With")
        #expect(failed.actions.map(\.kind) == locals + geminis + rewrites)

        #expect(VersionsMenu.make(for: entries[2], running: nil, readiness: ready).actions.isEmpty,
                "a selection has no recording to make another version from")
    }
}

@MainActor
@Suite(.serialized) struct RetiredArgonHomeTests {
    typealias H = DictationControllerTests

    /// A failed Argon row from Home: its Retry goes to Flash, and the row becomes Flash's transcript. Polish on a
    /// transcript Argon wrote is Flash's polish, beside Argon's text.
    @Test func retryAndPolishOnAnArgonRowGoToFlash() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        var asked: [EngineID] = []
        h.controller.transcribeOverride = { _, engine in
            asked.append(engine)
            return TranscriptResult(text: "<message>Flash's.</message>", engine: engine, processingTime: 0.1)
        }
        h.controller.insertOverride = { _ in Issue.record("Home work is never pasted"); return .pasted }

        let failedRecording = H.recording()
        var failed = TranscriptEntry(id: failedRecording.id, createdAt: failedRecording.startedAt, text: "",
                                     engine: .geminiArgon, status: .failed, audioDuration: failedRecording.duration,
                                     voicedSeconds: 1, errorMessage: "Gemini 4 Argon heard no speech",
                                     audioFileName: h.history.saveAudio(failedRecording))
        failed.modelAnswer = "<message></message>"
        h.history.upsert(failed)
        let menu = VersionsMenu.make(for: failed, running: nil) { _ in .ready }
        let retry = try #require(menu.actions.first { $0.kind.engine == .geminiFlash })
        #expect(retry.kind == .transcription(.geminiFlash))
        h.controller.makeVersion(retry.kind, of: failed)
        try await waitUntil { h.history.entry(id: failed.id)?.status == .success }
        let retried = try #require(h.history.entry(id: failed.id))
        #expect(retried.engine == .geminiFlash && retried.currentKind == .transcription(.geminiFlash))

        let argonRecording = H.recording()
        let argon = TranscriptEntry(id: argonRecording.id, createdAt: argonRecording.startedAt, text: "Argon's.",
                                    engine: .geminiArgon, audioDuration: argonRecording.duration, voicedSeconds: 1,
                                    audioFileName: h.history.saveAudio(argonRecording))
        h.history.upsert(argon)
        h.controller.makeVersion(.polish(), of: argon)
        try await waitUntil { h.history.entry(id: argon.id)?.currentKind == .polish(by: .geminiFlash) }
        let polished = try #require(h.history.entry(id: argon.id))
        #expect(polished.versions.map(\.kind) == [.transcription(.geminiArgon), .polish(by: .geminiFlash)])
        #expect(polished.text == "Flash's.")
        #expect(asked == [.geminiFlash, .geminiFlash])
    }
}

@MainActor
@Suite struct RetiredArgonSettingsTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        try body(defaults)
    }

    private func load(_ defaults: UserDefaults) -> AppSettings {
        AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() })
    }

    private func store(_ defaults: UserDefaults, _ json: String, _ key: SettingsKey) {
        defaults.set(Data(json.utf8), forKey: key.defaultsKey)
    }

    private func stored(_ defaults: UserDefaults, _ key: SettingsKey) -> String? {
        if let string = defaults.string(forKey: key.defaultsKey) { return string }
        return defaults.data(forKey: key.defaultsKey).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Everything a build with Argon stored about it, as someone who stepped to Argon with fn ⇥ and dictated
    /// hands-free on it would have it: Argon is Gemini 3.8 Flash wherever it was picked, the rest of what was
    /// stored about Argon goes, and Flash keeps its own color, level and Pasting checks.
    @Test func whereArgonWasPickedFlashIsNow() throws {
        try withDefaults { defaults in
            store(defaults, #"{"main":"parakeet","order":["parakeet","gemini","argon"],"switchable":["parakeet","argon"]}"#,
                  .lineup)
            defaults.set("argon", forKey: SettingsKey.handsFreeModel.defaultsKey)
            defaults.set("geminiArgon", forKey: SettingsKey.callEngine.defaultsKey)
            store(defaults, #"{"geminiArgon":"high","geminiFlash":"low"}"#, .geminiReasoningEfforts)
            store(defaults, #"{"argon":"pink","gemini":"orange","parakeet":"graphite"}"#, .modelColors)
            store(defaults, #"["gemini","argon"]"#, .modelsAddingSpace)
            store(defaults, #"["parakeet","argon"]"#, .modelsRemovingFinalPeriod)
            defaults.set(true, forKey: SettingsKey.argonPastingAdded.defaultsKey)

            let settings = load(defaults)
            #expect(settings.lineup.main == .gigaam
                    && settings.lineup.order == [.gigaam, .gemini, .neon])
            #expect(settings.lineup.steps == [.gemini], "fn ⇥ steps to Flash where it stepped to Argon, not to Neon")
            #expect(settings.handsFreeModel == .gemini && settings.handsFreeChoice == .gemini)
            #expect(settings.callModel == .default, "calls keep their own model and level")
            #expect(settings.reasoningEffort(for: .geminiFlash) == .low && settings.reasoningEffort(for: .geminiArgon) == nil)
            #expect(settings.modelColors[.gemini] == .orange && settings.modelColors.parakeet == .graphite)
            #expect(settings.modelsAddingSpace == [.gemini, .neon], "Neon starts with Flash's checks")
            #expect(settings.modelsRemovingFinalPeriod == [.gigaam],
                    "Flash keeps its own checks, not Argon's; GigaAM starts with Parakeet's")
            #expect(settings.modelColors[.neon] == .orange, "Neon doesn't take Argon's color")

            // Stored as this build reads it: nothing names Argon any more.
            #expect(stored(defaults, .lineup)
                    == #"{"main":"gigaam","order":["gigaam","gemini","neon"],"switchable":["gigaam","gemini"]}"#)
            #expect(stored(defaults, .handsFreeModel) == "gemini")
            #expect(stored(defaults, .geminiReasoningEfforts)
                    == #"{"geminiFlash":"low","geminiNeon":"low"}"#)
            #expect(stored(defaults, .modelColors)
                    == #"{"gemini":"orange","gigaam":"green","neon":"orange","parakeet":"graphite"}"#)
            #expect(stored(defaults, .modelsAddingSpace) == #"["gemini","neon"]"#)
            #expect(stored(defaults, .modelsRemovingFinalPeriod) == #"["gigaam"]"#)
            #expect(defaults.object(forKey: SettingsKey.argonPastingAdded.defaultsKey) == nil)

            let again = load(defaults)
            #expect(again.lineup == settings.lineup && again.handsFreeModel == .gemini, "a reload changes nothing")
            #expect(again.callModel == settings.callModel && again.modelColors == settings.modelColors)
        }
    }

    /// Argon as the main model: Flash is, keeping its place in the order, and the old main model's step stays.
    @Test func anArgonMainModelBecomesFlash() throws {
        try withDefaults { defaults in
            store(defaults, #"{"main":"argon","order":["argon","parakeet","gemini"],"switchable":["parakeet"]}"#, .lineup)
            defaults.set("argon", forKey: SettingsKey.handsFreeModel.defaultsKey)
            let settings = load(defaults)
            #expect(settings.lineup.main == .gemini && settings.mainEngine == .geminiFlash)
            #expect(settings.lineup.order == [.gigaam, .gemini, .neon])
            #expect(settings.lineup.cycle == [.gemini, .gigaam])
            #expect(settings.handsFreeChoice == nil, "hands-free on Argon, the main model, is on the main model still")
            #expect(stored(defaults, .lineup)
                    == #"{"main":"gemini","order":["gigaam","gemini","neon"],"switchable":["gigaam"]}"#)
        }
    }

    /// Argon switched on with Flash off: Flash is switched on in its place, and it's what fn ⇥ reaches.
    @Test func argonSwitchedOnSwitchesFlashOn() throws {
        let lineup = try JSONDecoder().decode(ModelLineup.self, from: Data(
            #"{"main":"parakeet","order":["gemini","parakeet","argon"],"switchable":["argon"]}"#.utf8))
        #expect(lineup.order == [.gemini, .gigaam, .neon] && lineup.steps == [.gemini])
        let off = try JSONDecoder().decode(ModelLineup.self, from: Data(
            #"{"main":"parakeet","order":["parakeet","gemini","argon"],"switchable":[]}"#.utf8))
        #expect(off.steps.isEmpty, "Argon switched off switches nothing on")
    }

    /// A level picked for Argon alone leaves Flash at Medium (Neon at its Low), and Argon takes no level any more.
    @Test func anArgonLevelIsIgnored() throws {
        try withDefaults { defaults in
            store(defaults, #"{"geminiArgon":"high"}"#, .geminiReasoningEfforts)
            let settings = load(defaults)
            #expect(settings.reasoningEffort(for: .geminiFlash) == .medium)
            #expect(settings.reasoningEfforts == .default)
            settings.reasoningEfforts[.geminiArgon] = .high
            #expect(settings.reasoningEffort(for: .geminiArgon) == nil)
            #expect(stored(defaults, .geminiReasoningEfforts)
                    == #"{"geminiFlash":"medium","geminiNeon":"low"}"#)
        }
    }

    /// "argon" reads as Flash only where it was picked: main, hands-free, a step. Elsewhere it's dropped.
    @Test func storedArgonReadsAsFlashOnlyWhereItWasPicked() throws {
        #expect(ModelChoice(stored: "argon") == .gemini && ModelChoice(stored: "gemini") == .gemini)
        #expect(ModelChoice(stored: "parakeet") == .gigaam && ModelChoice(stored: "cleanup") == nil)
        #expect(ModelChoice(rawValue: "argon") == nil)
        #expect(ModelChoice.read(["argon", "gigaam"]) == [.gigaam])
        #expect(AppSettings.handsFreeModel(stored: "argon", lineup: .default) == .gemini)
        let colors = try JSONDecoder().decode(ModelColors.self, from: Data(#"{"argon":"pink"}"#.utf8))
        #expect(colors == .default)
    }
}

// MARK: - Parakeet v3, GigaAM v3 e2e and GigaAM Multilingual

/// A history file with what the retired models on this Mac wrote, as 0.5.4 stored it: a Parakeet dictation, one GigaAM
/// v3 e2e wrote, one GigaAM Multilingual wrote (beside Parakeet's, current), and a failed Parakeet dictation.
private let localHistoryFile = #"""
{"version":1,"entries":[
 {"id":"2C8B4E6A-1111-4D9E-8F0A-7B8C9D0E1F01","createdAt":"2026-11-18T09:00:00.000Z","status":"success",
  "audioDuration":5,"voicedSeconds":4,"engine":"parakeet","text":"Open Chrome DevTools.","audioFileName":"p.m4a",
  "currentVersion":"parakeet",
  "versions":[{"kind":"parakeet","text":"Open Chrome DevTools.","metadata":{"createdAt":"2026-11-18T09:00:00.000Z","processingTime":0.3}}]},
 {"id":"2C8B4E6A-2222-4D9E-8F0A-7B8C9D0E1F02","createdAt":"2026-11-18T08:00:00.000Z","status":"success",
  "audioDuration":4,"voicedSeconds":3,"engine":"gigaam","text":"Открой hrome.","audioFileName":"e.m4a",
  "currentVersion":"gigaam:gigaam-v3-e2e-ctc",
  "versions":[{"kind":"gigaam:gigaam-v3-e2e-ctc","text":"Открой hrome.","metadata":{"createdAt":"2026-11-18T08:00:00.000Z",
    "modelID":"gigaam-v3-e2e-ctc","processingTime":0.36}}]},
 {"id":"2C8B4E6A-3333-4D9E-8F0A-7B8C9D0E1F03","createdAt":"2026-11-18T07:00:00.000Z","status":"success",
  "audioDuration":4,"voicedSeconds":3,"engine":"parakeet","text":"open chrome","audioFileName":"m.m4a",
  "currentVersion":"gigaam:gigaam-multilingual-600m-ctc",
  "versions":[{"kind":"parakeet","text":"Open Chrome.","metadata":{"createdAt":"2026-11-18T07:00:00.000Z"}},
              {"kind":"gigaam:gigaam-multilingual-600m-ctc","text":"open chrome","metadata":{"createdAt":"2026-11-18T07:00:01.000Z",
                "modelID":"gigaam-multilingual-600m-ctc"}}]},
 {"id":"2C8B4E6A-4444-4D9E-8F0A-7B8C9D0E1F04","createdAt":"2026-11-18T06:00:00.000Z","status":"failed",
  "audioDuration":6,"voicedSeconds":5,"engine":"parakeet","text":"","errorMessage":"Couldn’t transcribe",
  "audioFileName":"f.m4a"}
]}
"""#

@MainActor
@Suite struct RetiredLocalModelHistoryTests {
    private func entries() throws -> [TranscriptEntry] {
        try HistoryStore.readEntries(from: Data(localHistoryFile.utf8))
    }

    /// Parakeet's dictations read as before: its name, its P, its color (the one last picked for it).
    @Test func parakeetsTranscriptsKeepTheirNameGlyphAndColor() throws {
        let entries = try entries()
        #expect(entries.count == 4, "no entry is lost")
        let parakeet = entries[0]
        #expect(parakeet.engine == .parakeet && parakeet.currentKind == .transcription(.parakeet))
        #expect(parakeet.text == "Open Chrome DevTools." && parakeet.currentKind?.displayName == "Parakeet v3")
        #expect(parakeet.engine.glyph == "P" && parakeet.engine.symbolName == "bolt.fill")
        let colors = try JSONDecoder().decode(ModelColors.self, from: Data(#"{"parakeet":"teal","gigaam":"green"}"#.utf8))
        #expect(EngineGlyph(engine: parakeet.engine, colors: colors).color == .teal)
        #expect(EngineGlyph(engine: parakeet.engine).color == .graphite, "the plain pill's, as by default")
        #expect(EngineGlyph(engine: parakeet.engine).label == "Parakeet v3")
        #expect(VersionDetails.lines(for: try #require(parakeet.currentVersion)) == ["Parakeet v3", "Took 0.3 s"])
    }

    /// GigaAM v3 e2e's and Multilingual's read under their names, current where they were, beside Parakeet's.
    @Test func retiredGigaAMVersionsReadUnderTheirNames() throws {
        let entries = try entries()
        let e2e = entries[1]
        #expect(e2e.currentKind == .gigaam(.v3e2e) && e2e.text == "Открой hrome.")
        #expect(e2e.currentKind?.displayName == "GigaAM v3 e2e" && e2e.engine.glyph == "G")
        #expect(VersionDetails.lines(for: try #require(e2e.currentVersion)).prefix(2) == ["GigaAM v3 e2e", "gigaam-v3-e2e-ctc"])
        let multilingual = entries[2]
        #expect(multilingual.versions.map(\.kind) == [.transcription(.parakeet), .gigaam(.multilingual)])
        #expect(multilingual.currentKind == .gigaam(.multilingual) && multilingual.text == "open chrome")
        #expect(multilingual.versions.map(\.kind.displayName) == ["Parakeet v3", "GigaAM Multilingual"])
    }

    /// Their versions are switched to as any other; what they offer is GigaAM v3 and the Geminis, never themselves.
    /// A failed Parakeet dictation retries with GigaAM v3.
    @Test func theyAreVersionsNeverActions() throws {
        let entries = try entries()
        let ready: (TranscriptVersionKind) -> EngineReadiness = { _ in .ready }
        let offered = TranscriptVersionKind.transcripts + TranscriptVersionKind.rewrites
        let multilingual = VersionsMenu.make(for: entries[2], running: nil, readiness: ready)
        #expect(multilingual.versions.map(\.title) == ["Parakeet v3", "GigaAM Multilingual"])
        #expect(multilingual.actions.map(\.kind) == offered)
        #expect(multilingual.actions.first?.title == "GigaAM v3")
        let retired: [TranscriptVersionKind] = [.transcription(.parakeet), .gigaam(.v3e2e), .gigaam(.multilingual)]
        for entry in entries {
            let menu = VersionsMenu.make(for: entry, running: nil, readiness: ready)
            #expect(!menu.actions.contains { retired.contains($0.kind) }, "\(entry.id)")
        }
        let failed = VersionsMenu.make(for: entries[3], running: nil, readiness: ready)
        #expect(failed.isRetry && failed.actions.map(\.kind) == offered)
    }

    /// Saved again, they're written as they were read.
    @Test func theyAreWrittenBackUnchanged() throws {
        let entries = try entries()
        for entry in entries {
            #expect(try JSONDecoder().decode(TranscriptEntry.self, from: JSONEncoder().encode(entry)) == entry)
        }
        let json = String(decoding: try JSONEncoder().encode(entries[2]), as: UTF8.self)
        #expect(json.contains(#""kind":"parakeet""#) && json.contains(#""currentVersion":"gigaam:gigaam-multilingual-600m-ctc""#))
    }
}

@MainActor
@Suite struct RetiredLocalModelRunTests {
    /// Parakeet never runs: a request for it fails before anything loads.
    @Test func parakeetNeverRuns() async throws {
        let fake = FakeEngine(.gigaam, installed: true)
        let store = ModelStore(paths: .temporary(), settings: .inMemory(), engines: [.gigaam(.v3): fake],
                               gate: InferenceGate(), freeDiskBytes: { 50_000_000_000 })
        await store.refreshFromDisk()
        let account = OpenRouterAccount(keyStore: .inMemory(), client: OpenRouterClient(), debounce: .zero)
        let service = TranscriptionService(models: store, account: account, client: OpenRouterClient())
        await #expect(throws: AppError.engineFailed(.parakeet, "Parakeet v3 is no longer offered.")) {
            try await service.transcribe(Recording(samples: [Float](repeating: 0.1, count: 16_000)), engine: .parakeet)
        }
        #expect(await fake.transcribeCount == 0 && store.model(for: .parakeet) == nil)
        #expect(EngineID.parakeet.isRetired && EngineID.parakeet.replacement == .gigaam)
        #expect(EngineID.parakeetCloud.replacement == .gigaam && EngineID.geminiArgon.replacement == .geminiFlash)
        #expect(EngineID.gigaam.replacement == .gigaam && EngineID.geminiNeon.replacement == .geminiNeon)
        #expect(GigaAMEngine.Variant.v3e2e.isRetired && GigaAMEngine.Variant.multilingual.isRetired)
        #expect(!GigaAMEngine.Variant.v3.isRetired)
    }
}

@MainActor
@Suite struct RetiredParakeetSettingsTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        try body(defaults)
    }

    private func load(_ defaults: UserDefaults) -> AppSettings {
        AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() })
    }

    private func store(_ defaults: UserDefaults, _ json: String, _ key: SettingsKey) {
        defaults.set(Data(json.utf8), forKey: key.defaultsKey)
    }

    private func stored(_ defaults: UserDefaults, _ key: SettingsKey) -> String? {
        if let string = defaults.string(forKey: key.defaultsKey) { return string }
        return defaults.data(forKey: key.defaultsKey).map { String(decoding: $0, as: UTF8.self) }
    }

    /// 0.5.4's settings with Parakeet the main model, GigaAM on in v3 e2e: GigaAM v3 is the main model in Parakeet's
    /// place, the cycle steps on from it as it did, the version picked goes, GigaAM keeps its own Pasting checks and
    /// color, and Parakeet's color stays for History.
    @Test func whereParakeetWasMainGigaAMv3IsNow() throws {
        try withDefaults { defaults in
            store(defaults, #"{"main":"parakeet","order":["parakeet","gemini","hydrogen","neon","carbon","gigaam"],"switchable":["gemini","gigaam"]}"#,
                  .lineup)
            defaults.set("gemini", forKey: SettingsKey.handsFreeModel.defaultsKey)
            defaults.set("gigaam-v3-e2e-ctc", forKey: SettingsKey.gigaamVariant.defaultsKey)
            store(defaults, #"{"carbon":"blue","gemini":"violet","gigaam":"orange","hydrogen":"pink","neon":"orange","parakeet":"teal"}"#,
                  .modelColors)
            store(defaults, #"["gemini","hydrogen","neon","carbon"]"#, .modelsAddingSpace)
            store(defaults, #"["parakeet"]"#, .modelsRemovingFinalPeriod)
            for key in [SettingsKey.carbonPastingAdded, .gigaamPastingAdded, .hydrogenPastingAdded, .neonPastingAdded] {
                defaults.set(true, forKey: key.defaultsKey)
            }

            let settings = load(defaults)
            #expect(settings.lineup.main == .gigaam && settings.mainEngine == .gigaam)
            #expect(settings.lineup.order == [.gigaam, .gemini, .neon])
            #expect(settings.lineup.cycle == [.gigaam, .gemini] && settings.handsFreeChoice == .gemini)
            #expect(settings.localModelsInUse == [.gigaam] && LocalModel(engine: settings.mainEngine) == .gigaam(.v3))
            #expect(defaults.object(forKey: SettingsKey.gigaamVariant.defaultsKey) == nil, "v3 e2e reads as v3")
            #expect(settings.modelsRemovingFinalPeriod.isEmpty, "GigaAM keeps its own checks; Parakeet's go with it")
            #expect(settings.modelColors[.gigaam] == .orange && settings.modelColors.parakeet == .teal)

            #expect(stored(defaults, .lineup)
                    == #"{"main":"gigaam","order":["gigaam","gemini","neon"],"switchable":["gigaam","gemini"]}"#)
            #expect(stored(defaults, .modelsRemovingFinalPeriod) == "[]")
            #expect(stored(defaults, .modelColors)
                    == #"{"gemini":"violet","gigaam":"orange","neon":"orange","parakeet":"teal"}"#)
            let again = load(defaults)
            #expect(again.lineup == settings.lineup && again.modelColors == settings.modelColors, "a reload changes nothing")
        }
    }

    /// Parakeet as a step of the cycle and hands-free's model: GigaAM is both, in Parakeet's place in the order.
    @Test func aParakeetStepAndHandsFreeModelAreGigaAMs() throws {
        try withDefaults { defaults in
            store(defaults, #"{"main":"gemini","order":["gemini","parakeet","gigaam"],"switchable":["parakeet"]}"#, .lineup)
            defaults.set("parakeet", forKey: SettingsKey.handsFreeModel.defaultsKey)
            let settings = load(defaults)
            #expect(settings.lineup.order == [.gemini, .gigaam, .neon])
            #expect(settings.lineup.cycle == [.gemini, .gigaam] && settings.usesLocalModel(.gigaam))
            #expect(settings.handsFreeModel == .gigaam && settings.handsFreeChoice == .gigaam)
            #expect(stored(defaults, .handsFreeModel) == "gigaam")
        }
        // GigaAM already first and main, Parakeet later in the order: GigaAM keeps its own place.
        try withDefaults { defaults in
            store(defaults, #"{"main":"gigaam","order":["gigaam","hydrogen","parakeet","gemini","carbon","neon"],"switchable":["gigaam","neon"]}"#,
                  .lineup)
            defaults.set("neon", forKey: SettingsKey.handsFreeModel.defaultsKey)
            let settings = load(defaults)
            #expect(settings.lineup.order == [.gigaam, .neon, .gemini], "Neon at the removed Hydrogen's place")
            #expect(settings.lineup.cycle == [.gigaam, .neon] && settings.handsFreeChoice == .neon)
        }
        #expect(AppSettings.handsFreeModel(stored: "parakeet", lineup: .default) == .gigaam)
    }

    /// GigaAM's picked version, whichever it was (or a newer build's), goes at load: GigaAM runs v3.
    @Test(arguments: ["gigaam-v3-ctc", "gigaam-v3-e2e-ctc", "gigaam-multilingual-600m-ctc", "gigaam-v4-ctc"])
    func aStoredGigaAMVersionReadsAsV3(_ raw: String) throws {
        try withDefaults { defaults in
            defaults.set(raw, forKey: SettingsKey.gigaamVariant.defaultsKey)
            let settings = load(defaults)
            #expect(defaults.object(forKey: SettingsKey.gigaamVariant.defaultsKey) == nil)
            let models = ModelStore.preview(states: [.gigaam: .ready], settings: settings)
            #expect(models.model(for: .gigaam) == .gigaam(.v3) && models.state(model: .gigaam(.v3)) == .ready)
            #expect(ModelChoice.gigaam.modelName == "GigaAM v3" && TranscriptVersionKind.transcript(by: .gigaam) == .gigaam(.v3))
        }
    }
}

@MainActor
@Suite(.serialized) struct RetiredParakeetHomeTests {
    typealias H = DictationControllerTests

    /// A Parakeet dictation the app quit during, from before the update: its Continue says what GigaAM v3 needs, and
    /// goes on with it, GigaAM having taken Parakeet's place.
    @Test func anInterruptedParakeetRowGoesOnWithGigaAM() async throws {
        let h = H.make(models: [.gigaam: .ready], keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        var asked: [EngineID] = []
        h.controller.transcribeOverride = { _, engine in
            asked.append(engine)
            return TranscriptResult(text: "открой хром", engine: engine, processingTime: 0.1)
        }
        h.controller.insertOverride = { _ in Issue.record("Home work is never pasted"); return .pasted }
        let recording = H.recording()
        var row = TranscriptEntry(id: recording.id, createdAt: recording.startedAt, text: "", engine: .parakeet,
                                  status: .failed, audioDuration: recording.duration, voicedSeconds: 1,
                                  errorMessage: TranscriptEntry.Interruption.whileTranscribing.message,
                                  audioFileName: h.history.saveAudio(recording))
        row.interruption = .whileTranscribing
        h.history.upsert(row)

        let context = HubContext(env: .preview())
        context.models = .preview(states: [.gigaam: .notInstalled])
        #expect(context.continueBlocker(for: row) == "Not downloaded", "GigaAM's, not Parakeet's")
        context.models = .preview(states: [.gigaam: .ready])
        #expect(context.continueBlocker(for: row) == nil)

        h.controller.continueDictation(row)
        try await waitUntil { h.history.entry(id: row.id)?.status == .success }
        #expect(asked == [.gigaam])
        let done = try #require(h.history.entry(id: row.id))
        #expect(done.currentKind == .gigaam(.v3) && done.text == "открой хром")
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct LeftoverModelTests {
    /// A models folder as an update from 0.5.4 finds it: GigaAM v3 in use, and what Parakeet, GigaAM v3 e2e and an
    /// unfinished Multilingual download left.
    private func makeFolder() throws -> AppPaths {
        let paths = AppPaths.temporary()
        let fm = FileManager.default
        for (folder, bytes) in [("gigaam-v3-ctc", 300), ("parakeet-tdt-0.6b-v3", 200), ("gigaam-v3-e2e-ctc", 120),
                                ("gigaam-multilingual-600m-ctc.partial", 80)] {
            let file = paths.models.appendingPathComponent(folder).appendingPathComponent("weights/weight.bin")
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes * 1024).write(to: file)
        }
        return paths
    }

    private func makeStore(_ paths: AppPaths) -> (ModelStore, FakeEngine) {
        let fake = FakeEngine(.gigaam, installed: true)
        return (ModelStore(paths: paths, settings: .inMemory(), engines: [.gigaam(.v3): fake], gate: InferenceGate(),
                           freeDiskBytes: { 50_000_000_000 }), fake)
    }

    private func exists(_ paths: AppPaths, _ folder: String) -> Bool {
        FileManager.default.fileExists(atPath: paths.models.appendingPathComponent(folder).path)
    }

    /// Each retired model with a folder on disk is listed, Parakeet first, with what it takes; GigaAM v3's own folder
    /// never is. Launch deletes nothing.
    @Test func leftoversAreListedWithTheirSizeAndNothingIsDeletedByItself() async throws {
        let paths = try makeFolder()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let (store, _) = makeStore(paths)
        store.start()
        await waitForObserved { store.hasScannedDisk && store.state(of: .gigaam) == .ready }
        #expect(store.leftoverModels == [.parakeet, .gigaamV3e2e, .gigaamMultilingual])
        #expect(store.leftovers.values.allSatisfy { $0 > 0 })
        #expect(try #require(store.leftovers[.parakeet]) > #require(store.leftovers[.gigaamV3e2e]))
        #expect(store.diskUsageBytes >= store.leftovers.values.reduce(0, +))
        for folder in ["gigaam-v3-ctc", "parakeet-tdt-0.6b-v3", "gigaam-v3-e2e-ctc", "gigaam-multilingual-600m-ctc.partial"] {
            #expect(exists(paths, folder), "\(folder) is still there")
        }
        #expect(RetiredLocalModel.allCases.map(\.displayName) == ["Parakeet v3", "GigaAM v3 e2e", "GigaAM Multilingual"])
        #expect(RetiredLocalModel.allCases.map(\.engine) == [.parakeet, .gigaam, .gigaam])
    }

    /// Delete takes a leftover's folders and nothing else; once none is left, the list is empty.
    @Test func deleteTakesOnlyThatLeftover() async throws {
        let paths = try makeFolder()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let (store, fake) = makeStore(paths)
        await store.refreshFromDisk()
        await store.deleteLeftover(.parakeet)
        #expect(!exists(paths, "parakeet-tdt-0.6b-v3") && exists(paths, "gigaam-v3-e2e-ctc") && exists(paths, "gigaam-v3-ctc"))
        #expect(store.leftoverModels == [.gigaamV3e2e, .gigaamMultilingual] && store.deletingLeftovers.isEmpty)
        await store.deleteLeftover(.gigaamV3e2e)
        await store.deleteLeftover(.gigaamMultilingual)
        #expect(store.leftoverModels.isEmpty && store.leftovers.isEmpty)
        #expect(exists(paths, "gigaam-v3-ctc") && fake.isInstalled(), "GigaAM v3 stays")
        await store.deleteLeftover(.parakeet)
        #expect(store.leftoverModels.isEmpty, "deleting what isn't there does nothing")
    }

    /// The preview shows leftovers and deletes nothing.
    @Test func thePreviewNeverDeletes() async {
        let store = ModelStore.preview(states: [.gigaam: .ready], leftovers: [.parakeet: 632_400_000])
        await store.deleteLeftover(.parakeet)
        #expect(store.leftoverModels == [.parakeet])
    }

    /// What On this Mac says under them, and under each.
    @Test func theFooterNamesWhatsLeft() {
        #expect(LeftoverModelCopy.note == "No longer used")
        #expect(LeftoverModelCopy.footer([]) == nil)
        #expect(LeftoverModelCopy.footer([.parakeet])
                == "Parakeet v3 is no longer used. History keeps what it wrote; delete its files to free the space.")
        #expect(LeftoverModelCopy.footer(RetiredLocalModel.allCases)
                == "Parakeet v3, GigaAM v3 e2e and GigaAM Multilingual are no longer used. History keeps what they "
                    + "wrote; delete their files to free the space.")
    }
}
