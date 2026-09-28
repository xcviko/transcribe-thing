import Foundation
import Testing
@testable import TranscribeThing

// Gemini 3.1 Pro and Gemini 3.5 Flash Lite are retired: History keeps reading, naming and drawing what they wrote,
// settings an older build stored about them (and the Thinking levels and clean-up model choice that are gone) load
// without them, and nothing runs them.

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
        #expect(pro.currentKind?.displayName == "Gemini 3.1 Pro" && pro.engine.shortName == "Gemini Pro")
        #expect(pro.engine.glyph == "Pro" && pro.costUSD == 0.0094 && pro.provider == "Google AI Studio")
        let version = try #require(pro.currentVersion)
        #expect(VersionDetails.lines(for: version) == [
            "Gemini 3.1 Pro",
            "google/gemini-3.1-pro-preview via Google AI Studio",
            "Thinking: High",
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
        #expect(tidied.currentVersion.map(VersionDetails.lines)?.contains("Thinking: Minimal") == true)

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
            #expect(settings.selectedEngine == .parakeet)
            #expect(settings.switchEngines == [.geminiFlash])
            #expect(settings.switchChoices == [.cleanup, .engine(.geminiFlash)])
            for key in [SettingsKey.reasoningEfforts, .cleanupModel, .cleanupReasoningEfforts, .cleanupReasoningEffort] {
                #expect(defaults.object(forKey: key.defaultsKey) == nil, "\(key) is removed at load")
            }
            #expect(load(defaults).switchEngines == [.geminiFlash], "and again next launch")
        }
        try withDefaults { defaults in
            try storeOldSettings(defaults, switchEngines: ["geminiPro"])
            let settings = load(defaults)
            #expect(settings.switchEngines.isEmpty && settings.switchChoices == [.cleanup],
                    "Pro alone taking part leaves clean-up alone, not a model the user switched off")
        }
    }

    /// The old levels never reach a request: Gemini 3.8 Flash thinks at medium and GPT-6 Luna not at all.
    @Test func oldStoredLevelsNeverReachTheWire() async throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        try storeOldSettings(defaults, switchEngines: ["geminiFlash", "geminiPro"])
        let settings = load(defaults)
        let replies = [StubURLProtocol.Reply(body: #"{"choices":[{"finish_reason":"stop","message":{"content":"Hallo."}}]}"#),
                       StubURLProtocol.Reply(body: #"{"choices":[{"finish_reason":"stop","message":{"content":"Hallo!"}}]}"#)]
        let (client, host) = StubURLProtocol.client(replies)
        let keychain = KeychainStore.inMemory([KeychainStore.openRouterAccount: "sk-or-v1-test"])
        let account = OpenRouterAccount(keychain: keychain, client: client, debounce: .zero)
        let service = TranscriptionService(models: ModelStore.preview(states: [:]), account: account, client: client,
                                           settings: settings)
        let transcribed = try await service.transcribe(Recording(samples: [Float](repeating: 0.1, count: 16_000)),
                                                       engine: .geminiFlash)
        let cleaned = try await service.cleanUp(transcribed.text, of: .parakeet)
        #expect(transcribed.reasoningEffort == .medium && cleaned.reasoningEffort == .off)
        let bodies = try StubURLProtocol.registry.bodies(for: host).map {
            try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        #expect(bodies.map { $0["model"] as? String } == ["google/gemini-3.8-flash", "openai/gpt-6-luna"])
        #expect(bodies.map { $0["reasoning"] as? [String: AnyHashable] }
                == [["effort": "medium", "exclude": true], ["effort": "none", "exclude": true]])
        #expect((bodies[1]["provider"] as? [String: Any])?["only"] as? [String] == ["openai"])
    }
}

// MARK: - Never run

@MainActor
@Suite struct RetiredModelRunTests {
    @Test func gemini31ProNeverRuns() async throws {
        let (client, host) = StubURLProtocol.client([StubURLProtocol.Reply(body: #"{"choices":[]}"#)])
        let keychain = KeychainStore.inMemory([KeychainStore.openRouterAccount: "sk-or-v1-test"])
        let account = OpenRouterAccount(keychain: keychain, client: client, debounce: .zero)
        let service = TranscriptionService(models: ModelStore.preview(states: [:]), account: account, client: client,
                                           settings: .inMemory())
        await #expect(throws: AppError.self) {
            try await service.transcribe(Recording(samples: [Float](repeating: 0.1, count: 16_000)), engine: .geminiPro)
        }
        #expect(StubURLProtocol.registry.requests(for: host).isEmpty)
    }

    @Test func nothingOffersARetiredModel() {
        #expect(!EngineID.offered.contains(.geminiPro) && !CleanupModel.offered.contains(.geminiFlashLite))
        #expect(!EngineID.mainCandidates.contains(.geminiPro) && !EngineID.switchCandidates.contains(.geminiPro))
        #expect(AppSettings.inMemory().switchChoices == [.cleanup, .engine(.geminiFlash)])
        for engine in EngineID.allCases {
            #expect(!DictationController.fallbackCandidates(for: engine, main: .parakeet).contains(.geminiPro))
        }
        #expect(PillPalette.accent(for: .engine(.geminiPro)) == nil, "no tint of its own")
    }
}
