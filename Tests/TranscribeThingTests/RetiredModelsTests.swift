import Foundation
import Testing
@testable import TranscribeThing

// Gemini 3.1 Pro, Gemini 3.5 Flash Lite, Parakeet v3 · Cloud and Gemini 4 Argon are retired: History keeps reading,
// naming and drawing what they wrote, settings an older build stored about them (and the Thinking levels and clean-up
// model choice that are gone) load without them, and nothing runs them.

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
            #expect(settings.lineup.cycle == [.gemini, .parakeet])
            for key in [SettingsKey.reasoningEfforts, .cleanupModel, .cleanupReasoningEfforts, .cleanupReasoningEffort] {
                #expect(defaults.object(forKey: key.defaultsKey) == nil, "\(key) is removed at load")
            }
            #expect(load(defaults).lineup == settings.lineup, "and again next launch")
        }
        try withDefaults { defaults in
            try storeOldSettings(defaults, switchEngines: ["geminiPro"])
            let settings = load(defaults)
            #expect(!settings.lineup.switchable.contains(.gemini) && settings.lineup.switchable.contains(.parakeet),
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
        #expect(!EngineID.offered.contains(.geminiPro))
        #expect(!EngineID.offered.contains(.parakeetCloud))
        #expect(!EngineID.offered.contains(.geminiArgon))
        #expect(EngineID.geminiEngines == [.geminiFlash])
        #expect(TranscriptVersionKind.rewrites == [.polish(by: .geminiFlash), .translation(polished: false, by: .geminiFlash)])
        #expect(AppSettings.inMemory().lineup.cycle.map { $0.engine }
                == [.parakeet, .geminiFlash])
        #expect(ModelLineup.default.order == ModelChoice.allCases && ModelChoice.allCases == [.parakeet, .gemini])
        for engine in EngineID.allCases {
            #expect(DictationController.fallbackCandidates(for: engine).allSatisfy { !$0.isRetired })
        }
        #expect(ModelChoice(engine: .geminiPro) == .gemini, "a job it made reads as Gemini")
        #expect(ModelChoice(engine: .geminiArgon) == .gemini, "a job it made reads as Gemini")
        #expect(ImportChoices.make(main: .geminiFlash) { _ in .ready }.allSatisfy { !$0.kind.engine.isRetired })
    }

    /// `--engine` takes the models the app runs: Parakeet and Gemini 3.8 Flash, by any spelling. The retired ones
    /// are no engine at all.
    @Test func theCLITakesOnlyTheModelsTheAppRuns() {
        func options(_ extra: String...) -> EngineCLI.Options? {
            EngineCLI.Options(["transcribe-thing", "--transcribe", "/tmp/memo.m4a"] + extra)
        }
        #expect(options("--engine", "geminiFlash")?.engine == .geminiFlash)
        #expect(options("--engine", "gemini-flash")?.engine == .geminiFlash)
        #expect(options("--engine", "parakeet")?.engine == .parakeet)
        for retired in ["geminiArgon", "argon", "gemini-4-argon", "parakeetCloud", "cloudParakeet", "geminiPro"] {
            #expect(options("--engine", retired) == nil, "\(retired)")
        }
        #expect(options("--engine", "parakeetCloud", "--speech-model", "openai/whisper") == nil)
        #expect(EngineCLI.Options.usage.contains("--engine parakeet|geminiFlash "))
        #expect(!EngineCLI.Options.usage.contains("parakeetCloud") && !EngineCLI.Options.usage.contains("Argon"))
        let lines = EngineCLI.cloudModelLines()
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("geminiFlash") && lines[0].contains("google/gemini-3.8-flash"))
        #expect(lines[0].hasSuffix("effort low|medium|high (default medium)"))
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

    /// Whatever is made from an Argon row now is Gemini 3.8 Flash's (or Parakeet's): Transcribe With, Polish and
    /// Translate, and a failed row's Retry With.
    @Test func everythingMadeFromAnArgonRowIsFlashs() throws {
        let entries = try entries()
        let ready: (EngineID) -> EngineReadiness = { _ in .ready }
        let flashRewrites: [TranscriptVersionKind] = [.polish(by: .geminiFlash),
                                                      .translation(polished: false, by: .geminiFlash)]
        let argon = VersionsMenu.make(for: entries[0], running: nil, readiness: ready)
        #expect(argon.versions.map(\.kind) == [.transcription(.geminiArgon)])
        #expect(argon.actions.map(\.kind) == [.transcription(.parakeet), .transcription(.geminiFlash)] + flashRewrites)
        #expect(argon.actions.allSatisfy { $0.isEnabled })

        let rewritten = VersionsMenu.make(for: entries[1], running: nil, readiness: ready)
        #expect(rewritten.actions.map(\.kind) == [.transcription(.geminiFlash)] + flashRewrites,
                "Argon's polish and translation don't stand in for Flash's")

        let failed = VersionsMenu.make(for: entries[3], running: nil, readiness: ready)
        #expect(failed.isRetry && failed.title == "Retry With")
        #expect(failed.actions.map(\.kind) == [.transcription(.parakeet), .transcription(.geminiFlash)] + flashRewrites)

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
            #expect(settings.lineup.main == .parakeet && settings.lineup.order == [.parakeet, .gemini])
            #expect(settings.lineup.steps == [.gemini], "fn ⇥ steps to Flash where it stepped to Argon")
            #expect(settings.handsFreeModel == .gemini && settings.handsFreeChoice == .gemini)
            #expect(settings.callModel == CallModel(engine: .geminiFlash, effort: .low), "calls go at Flash's level")
            #expect(settings.reasoningEffort(for: .geminiFlash) == .low && settings.reasoningEffort(for: .geminiArgon) == nil)
            #expect(settings.modelColors[.gemini] == .orange && settings.modelColors[.parakeet] == .graphite)
            #expect(settings.modelsAddingSpace == [.gemini])
            #expect(settings.modelsRemovingFinalPeriod == [.parakeet], "Flash keeps its own checks, not Argon's")

            // Stored as this build reads it: nothing names Argon any more.
            #expect(stored(defaults, .lineup)
                    == #"{"main":"parakeet","order":["parakeet","gemini"],"switchable":["parakeet","gemini"]}"#)
            #expect(stored(defaults, .handsFreeModel) == "gemini")
            #expect(stored(defaults, .geminiReasoningEfforts) == #"{"geminiFlash":"low"}"#)
            #expect(stored(defaults, .modelColors) == #"{"gemini":"orange","parakeet":"graphite"}"#)
            #expect(stored(defaults, .modelsAddingSpace) == #"["gemini"]"#)
            #expect(stored(defaults, .modelsRemovingFinalPeriod) == #"["parakeet"]"#)
            #expect(defaults.object(forKey: SettingsKey.callEngine.defaultsKey) == nil)
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
            #expect(settings.lineup.order == [.parakeet, .gemini])
            #expect(settings.lineup.cycle == [.gemini, .parakeet])
            #expect(settings.handsFreeChoice == nil, "hands-free on Argon, the main model, is on the main model still")
            #expect(stored(defaults, .lineup) == #"{"main":"gemini","order":["parakeet","gemini"],"switchable":["parakeet"]}"#)
        }
    }

    /// Argon switched on with Flash off: Flash is switched on in its place, and it's what fn ⇥ reaches.
    @Test func argonSwitchedOnSwitchesFlashOn() throws {
        let lineup = try JSONDecoder().decode(ModelLineup.self, from: Data(
            #"{"main":"parakeet","order":["gemini","parakeet","argon"],"switchable":["argon"]}"#.utf8))
        #expect(lineup.order == [.gemini, .parakeet] && lineup.steps == [.gemini])
        let off = try JSONDecoder().decode(ModelLineup.self, from: Data(
            #"{"main":"parakeet","order":["parakeet","gemini","argon"],"switchable":[]}"#.utf8))
        #expect(off.steps.isEmpty, "Argon switched off switches nothing on")
    }

    /// The model calls went to is gone from the settings, whatever it was: calls go to Flash, at its level.
    @Test(arguments: ["geminiArgon", "geminiFlash", "parakeet", "junk"])
    func callsGoToFlashWhateverWasPicked(_ raw: String) throws {
        try withDefaults { defaults in
            defaults.set(raw, forKey: SettingsKey.callEngine.defaultsKey)
            let settings = load(defaults)
            #expect(settings.callModel == .default)
            #expect(defaults.object(forKey: SettingsKey.callEngine.defaultsKey) == nil)
            settings.reasoningEfforts[.geminiFlash] = .high
            #expect(settings.callModel == CallModel(engine: .geminiFlash, effort: .high))
        }
    }

    /// A level picked for Argon alone leaves Flash at Medium, and Argon takes no level any more.
    @Test func anArgonLevelIsIgnored() throws {
        try withDefaults { defaults in
            store(defaults, #"{"geminiArgon":"high"}"#, .geminiReasoningEfforts)
            let settings = load(defaults)
            #expect(settings.reasoningEffort(for: .geminiFlash) == .medium)
            #expect(settings.reasoningEfforts == .default)
            settings.reasoningEfforts[.geminiArgon] = .high
            #expect(settings.reasoningEffort(for: .geminiArgon) == nil)
            #expect(stored(defaults, .geminiReasoningEfforts) == #"{"geminiFlash":"medium"}"#)
        }
    }

    /// "argon" reads as Flash only where it was picked: main, hands-free, a step. Elsewhere it's dropped.
    @Test func storedArgonReadsAsFlashOnlyWhereItWasPicked() throws {
        #expect(ModelChoice(stored: "argon") == .gemini && ModelChoice(stored: "gemini") == .gemini)
        #expect(ModelChoice(stored: "parakeet") == .parakeet && ModelChoice(stored: "cleanup") == nil)
        #expect(ModelChoice(rawValue: "argon") == nil)
        #expect(ModelChoice.read(["argon", "parakeet"]) == [.parakeet])
        #expect(AppSettings.handsFreeModel(stored: "argon", lineup: .default) == .gemini)
        let colors = try JSONDecoder().decode(ModelColors.self, from: Data(#"{"argon":"pink"}"#.utf8))
        #expect(colors == .default)
    }
}

/// A call transcribed while Argon took calls: calls.json never named the model, so it reads as any other call, and
/// Transcribe Again goes to Gemini 3.8 Flash, whatever the settings still said.
@MainActor
@Suite struct RetiredArgonCallTests {
    @Test func aCallArgonTranscribedStillReads() throws {
        let json = """
            {"version":1,"calls":[{"id":"\(UUID().uuidString)","startedAt":"2026-10-14T10:00:00Z",
            "endedAt":"2026-10-14T10:05:00Z","appName":"Google Chrome","service":"meet","pageTitle":"Meet - abc-defg-hij",
            "status":"done","muteKnown":true,"micSilencedWhenMuted":true,"micFile":"mic.m4a","remoteFile":"remote.m4a",
            "micSeconds":300,"remoteSeconds":300,"costUSD":0.31,"speakerNames":{"Participant 1":"Pablo"},
            "transcript":{"segments":[{"start":1,"end":3,"side":"remote","speaker":"Participant 1","text":"Hola.","duringMute":false},
            {"start":4,"end":6,"side":"local","speaker":"Sam","text":"Hi.","duringMute":false}]},
            "summary":{"title":"Release plan","summary":"We planned the release.","keyPoints":["Friday"],"decided":["Ship"],
            "tasks":[{"id":"\(UUID().uuidString)","owner":"Sam","text":"Write notes","done":false}],"open":[],
            "createdAt":"2026-10-14T10:06:00Z"}}]}
            """
        let call = try #require(CallStore.readRecords(from: Data(json.utf8)).first)
        #expect(call.status == .done && call.costUSD == 0.31)
        #expect(call.transcript?.segments.map(\.text) == ["Hola.", "Hi."])
        #expect(call.name(of: "Participant 1") == "Pablo")
        #expect(call.summary?.title == "Release plan" && call.summary?.tasks.map(\.text) == ["Write notes"])
    }

    @Test func transcribeAgainGoesToFlash() async throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        defaults.set("geminiArgon", forKey: SettingsKey.callEngine.defaultsKey)
        defaults.set(Data(#"{"geminiArgon":"high","geminiFlash":"low"}"#.utf8),
                     forKey: SettingsKey.geminiReasoningEfforts.defaultsKey)
        let settings = AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() })
        let (client, host) = StubURLProtocol.client([.stream(SSE.answer("[00:00-00:02] Anna: Hi.")),
                                                     .stream(SSE.answer("<summary>Hi.</summary>"))])
        let account = OpenRouterAccount(keyStore: .inMemory("sk-or-v1-test"), client: client, debounce: .zero)
        let send = CallTranscriber.openRouter(client: client, account: account, model: { settings.callModel })
        let sendText = CallTranscriber.openRouterText(client: client, account: account, model: { settings.callModel })
        _ = try await send(Data([1, 2]), "Transcribe the call.", 2, nil)
        _ = try await sendText("Anna: Hi.", "Sum it up.")
        let bodies = try StubURLProtocol.registry.bodies(for: host).map {
            try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        #expect(bodies.map { $0["model"] as? String } == ["google/gemini-3.8-flash", "google/gemini-3.8-flash"])
        #expect(bodies.map { ($0["reasoning"] as? [String: Any])?["effort"] as? String } == ["low", "low"])
        #expect(StubURLProtocol.registry.requests(for: host).first?.timeoutInterval == 120)
    }
}
