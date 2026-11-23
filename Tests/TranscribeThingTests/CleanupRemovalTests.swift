import Foundation
import Testing
@testable import TranscribeThing

// Clean-up (Parakeet v3 + GPT-6 Luna) is gone. Settings an older build stored about it load as the closest thing
// left: Parakeet, and GigaAM since Parakeet was retired too; the clean-ups already in History stay readable, shown and
// switchable, and nothing makes new ones.

// MARK: - Settings

@MainActor
@Suite struct CleanupRemovalSettingsTests {
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

    private func lineup(_ json: String) throws -> ModelLineup {
        try JSONDecoder().decode(ModelLineup.self, from: Data(json.utf8))
    }

    private func stored(_ defaults: UserDefaults, _ key: SettingsKey) -> String? {
        if let string = defaults.string(forKey: key.defaultsKey) { return string }
        return defaults.data(forKey: key.defaultsKey).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Clean-up as the main model: Parakeet was, and GigaAM is now that Parakeet is retired too; clean-up leaves the
    /// order, and GigaAM takes Parakeet's place in it.
    @Test func aCleanupMainModelBecomesGigaAM() throws {
        let decoded = try lineup(#"{"main":"cleanup","order":["parakeet","cleanup","gemini"],"switchable":["gemini"]}"#)
        #expect(decoded.main == .gigaam)
        #expect(decoded.order == [.gigaam, .gemini, .neon])
        #expect(decoded.cycle == [.gigaam, .gemini])
        let reordered = try lineup(#"{"main":"cleanup","order":["gemini","cleanup","parakeet"],"switchable":["gemini"]}"#)
        #expect(reordered.main == .gigaam && reordered.order == [.gemini, .gigaam, .neon])
        #expect(reordered.cycle == [.gigaam, .gemini])
    }

    /// Switch model reached clean-up: it reaches GigaAM now, even where Parakeet itself was switched off.
    @Test func aSwitchableCleanupSwitchesGigaAMOn() throws {
        let decoded = try lineup(#"{"main":"gemini","order":["gemini","cleanup","parakeet"],"switchable":["cleanup"]}"#)
        #expect(decoded.main == .gemini && decoded.order == [.gemini, .gigaam, .neon])
        #expect(decoded.cycle == [.gemini, .gigaam])
        let off = try lineup(#"{"main":"gemini","order":["parakeet","cleanup","gemini"],"switchable":[]}"#)
        #expect(off.cycle == [.gemini], "clean-up wasn't a step: GigaAM stays off")
    }

    /// The load stores the lineup as this build reads it: "cleanup" and "parakeet" are gone from the settings for good.
    @Test func theLoadWritesTheLineupBackWithoutCleanup() throws {
        try withDefaults { defaults in
            let json = #"{"main":"cleanup","order":["parakeet","cleanup","gemini"],"switchable":["cleanup","gemini"]}"#
            defaults.set(Data(json.utf8), forKey: SettingsKey.lineup.defaultsKey)
            let settings = load(defaults)
            #expect(settings.lineup.main == .gigaam && settings.lineup.cycle == [.gigaam, .gemini])
            #expect(settings.mainEngine == .gigaam)
            #expect(stored(defaults, .lineup) == #"{"main":"gigaam","order":["gigaam","gemini","neon"],"switchable":["gigaam","gemini"]}"#)
            #expect(load(defaults).lineup == settings.lineup, "a reload changes nothing")
        }
    }

    /// A hands-free model of clean-up: GigaAM, which took Parakeet's place, where Switch model reaches it, else no
    /// model of its own.
    @Test func aCleanupHandsFreeModelBecomesGigaAM() throws {
        try withDefaults { defaults in
            let json = #"{"main":"gemini","order":["parakeet","cleanup","gemini"],"switchable":["cleanup"]}"#
            defaults.set(Data(json.utf8), forKey: SettingsKey.lineup.defaultsKey)
            defaults.set("cleanup", forKey: SettingsKey.handsFreeModel.defaultsKey)
            let settings = load(defaults)
            #expect(settings.handsFreeModel == .gigaam && settings.handsFreeChoice == .gigaam)
            #expect(stored(defaults, .handsFreeModel) == "gigaam")
        }
        // Clean-up was the main model's step and GigaAM is main now: hands-free stays on it.
        try withDefaults { defaults in
            let json = #"{"main":"parakeet","order":["parakeet","cleanup","gemini"],"switchable":["cleanup","gemini"]}"#
            defaults.set(Data(json.utf8), forKey: SettingsKey.lineup.defaultsKey)
            defaults.set("cleanup", forKey: SettingsKey.handsFreeModel.defaultsKey)
            let settings = load(defaults)
            #expect(settings.handsFreeModel == nil && settings.handsFreeChoice == nil)
            #expect(settings.lineup.cycle == [.gigaam, .gemini])
            #expect(stored(defaults, .handsFreeModel) == nil)
        }
        // No lineup stored (the default): GigaAM is the main model.
        try withDefaults { defaults in
            defaults.set("cleanup", forKey: SettingsKey.handsFreeModel.defaultsKey)
            #expect(load(defaults).handsFreeModel == nil)
        }
        #expect(AppSettings.handsFreeModel(stored: "gemini", lineup: .default) == .gemini, "others read as before")
        #expect(AppSettings.handsFreeModel(stored: "whisper", lineup: .default) == nil)
        #expect(AppSettings.handsFreeModel(stored: nil, lineup: .default) == nil)
    }

    /// General → Pasting's rules for clean-up have no model to hold for: they go, the others stay (and Gemini 4
    /// Neon, which came later, starts with Flash's).
    @Test func cleanupDropsOutOfThePastingRules() throws {
        try withDefaults { defaults in
            defaults.set(try JSONEncoder().encode(["cleanup", "gemini"]), forKey: SettingsKey.modelsAddingSpace.defaultsKey)
            defaults.set(try JSONEncoder().encode(["cleanup"]), forKey: SettingsKey.modelsRemovingFinalPeriod.defaultsKey)
            let settings = load(defaults)
            #expect(settings.modelsAddingSpace == [.gemini, .neon])
            #expect(settings.modelsRemovingFinalPeriod.isEmpty)
            #expect(stored(defaults, .modelsAddingSpace) == #"["gemini","neon"]"#)
            #expect(stored(defaults, .modelsRemovingFinalPeriod) == "[]")
        }
    }

    /// Clean-up as the main model: Parakeet took its place, and its Pasting rules too; GigaAM, which came later and
    /// has Parakeet's place now, starts with them, for good.
    @Test func cleanupsPastingRulesGoToGigaAMWhereItWasMain() throws {
        try withDefaults { defaults in
            let json = #"{"main":"cleanup","order":["parakeet","cleanup","gemini"],"switchable":["gemini"]}"#
            defaults.set(Data(json.utf8), forKey: SettingsKey.lineup.defaultsKey)
            defaults.set(try JSONEncoder().encode(["cleanup"]), forKey: SettingsKey.modelsAddingSpace.defaultsKey)
            defaults.set(try JSONEncoder().encode(["gemini"]), forKey: SettingsKey.modelsRemovingFinalPeriod.defaultsKey)
            let settings = load(defaults)
            #expect(settings.lineup.main == .gigaam)
            #expect(settings.modelsAddingSpace == [.gigaam]
                    && settings.modelsRemovingFinalPeriod == [.gemini, .neon])
            #expect(stored(defaults, .modelsAddingSpace) == #"["gigaam"]"#)
            #expect(load(defaults).modelsAddingSpace == [.gigaam], "it stays once the lineup is stored without it")
        }
        // Off for clean-up and on for Parakeet: every dictation went to clean-up, without it. GigaAM goes on so.
        try withDefaults { defaults in
            let json = #"{"main":"cleanup","order":["parakeet","cleanup","gemini"],"switchable":["gemini"]}"#
            defaults.set(Data(json.utf8), forKey: SettingsKey.lineup.defaultsKey)
            defaults.set(try JSONEncoder().encode(["parakeet", "gemini"]), forKey: SettingsKey.modelsAddingSpace.defaultsKey)
            #expect(load(defaults).modelsAddingSpace == [.gemini, .neon])
        }
    }

    /// Clean-up's color goes with it; the others keep theirs, the retired Parakeet's too.
    @Test func cleanupsColorIsDropped() throws {
        try withDefaults { defaults in
            let json = #"{"cleanup":"pink","gemini":"blue","parakeet":"teal"}"#
            defaults.set(Data(json.utf8), forKey: SettingsKey.modelColors.defaultsKey)
            let settings = load(defaults)
            #expect(settings.modelColors.parakeet == .teal && settings.modelColors[.gemini] == .blue)
            #expect(stored(defaults, .modelColors)
                    == #"{"gemini":"blue","gigaam":"green","neon":"orange","parakeet":"teal"}"#)
        }
    }

    @Test func onlyGigaAMAndTheGeminisAreLeft() {
        #expect(ModelChoice.allCases == [.gigaam, .gemini, .neon])
        #expect(ModelChoice(rawValue: ModelChoice.retiredCleanup) == nil)
        #expect(ModelChoice.read(["parakeet", "cleanup", "gemini"]) == [.gemini])
    }
}

// MARK: - History

/// A history file as the last builds with clean-up wrote it: a dictation GPT-6 Luna cleaned up (its clean-up the
/// current version), and one Flash Lite cleaned up before the choice of clean-up model.
private let historyFile = #"""
{"version":1,"entries":[
 {"id":"5B1E2C4E-1111-4A7B-9C3D-5E6F7A8B9C01","createdAt":"2026-10-01T09:00:00.000Z","status":"success",
  "audioDuration":8,"voicedSeconds":7,"engine":"parakeet","text":"Hello there.","audioFileName":"one.m4a",
  "currentVersion":"cleanup:parakeet:gpt6Luna",
  "versions":[{"kind":"parakeet","text":"um hello hello there","metadata":{"createdAt":"2026-10-01T09:00:00.000Z","processingTime":0.4}},
              {"kind":"cleanup:parakeet:gpt6Luna","text":"Hello there.","metadata":{"createdAt":"2026-10-01T09:00:01.000Z",
                "modelID":"openai/gpt-6-luna","provider":"OpenAI","reasoningEffort":"none","costUSD":0.00006,
                "processingTime":1.1,"usedSystemPrompt":true,"finishReason":"stop"}}]},
 {"id":"5B1E2C4E-2222-4A7B-9C3D-5E6F7A8B9C02","createdAt":"2026-09-01T09:00:00.000Z","status":"success",
  "audioDuration":5,"voicedSeconds":4,"engine":"parakeetCloud","text":"Tidied.","currentVersion":"cleanup:parakeetCloud",
  "versions":[{"kind":"parakeetCloud","text":"tidied","metadata":{"createdAt":"2026-09-01T09:00:00.000Z"}},
              {"kind":"cleanup:parakeetCloud","text":"Tidied.","metadata":{"createdAt":"2026-09-01T09:00:01.000Z"}}]}
]}
"""#

@MainActor
@Suite(.serialized) struct CleanupRemovalHistoryTests {
    private typealias H = DictationControllerTests
    private let luna = TranscriptVersionKind.cleanup(of: .parakeet, by: .gpt6Luna)

    private func entries() throws -> [TranscriptEntry] {
        try HistoryStore.readEntries(from: Data(historyFile.utf8))
    }

    private func menu(_ entry: TranscriptEntry) -> VersionsMenu {
        VersionsMenu.make(for: entry, running: nil, readiness: {
            EngineReadiness.of($0.engine, localState: .ready, keyStatus: .valid(KeyInfo()))
        })
    }

    @Test func anOldCleanUpStillDecodesAndShows() throws {
        let entries = try entries()
        #expect(entries.count == 2, "no entry is lost")
        let entry = entries[0]
        #expect(entry.versions.map(\.kind) == [.transcription(.parakeet), luna])
        #expect(entry.currentKind == luna && entry.text == "Hello there.")
        #expect(entry.currentKind?.displayName == "Parakeet v3 + Clean-up by GPT-6 Luna")
        let version = try #require(entry.currentVersion)
        #expect(version.metadata.reasoningEffort == .off && version.metadata.costUSD == 0.00006)
        #expect(VersionDetails.lines(for: version).first == "Parakeet v3 + Clean-up by GPT-6 Luna")
        let glyph = EngineGlyph(engine: entry.engine, provider: entry.provider, cleanupModel: entry.currentKind?.cleanupModel)
        #expect(glyph.label.hasPrefix("Parakeet v3 + Clean-up by GPT-6 Luna"))
        let flashLite = entries[1]
        #expect(flashLite.currentKind == .cleanup(of: .parakeetCloud, by: .geminiFlashLite) && flashLite.text == "Tidied.")
    }

    /// It survives being written again: nothing this build saves drops it.
    @Test func anOldCleanUpRoundTrips() throws {
        let entry = try entries()[0]
        let decoded = try JSONDecoder().decode(TranscriptEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded == entry)
    }

    /// The Versions menu lists the clean-up and checks it, and offers no Clean Up: only the other engines and Polish.
    @Test func theVersionsMenuListsItButOffersNoCleanUp() throws {
        let m = menu(try entries()[0])
        #expect(m.versions.map(\.title) == ["Parakeet v3", "Parakeet v3 + Clean-up by GPT-6 Luna"])
        #expect(m.versions.map(\.isCurrent) == [false, true])
        #expect(m.actions.map(\.kind) == [.gigaam(.v3), .transcription(.geminiFlash),
                                          .transcription(.geminiNeon)]
                + TranscriptVersionKind.rewrites)
        #expect(!m.actions.contains { $0.kind.isCleanup || $0.title.contains("Clean Up") })
    }

    /// Switching away from the clean-up and back to it works as for any version, with no request.
    @Test func itCanBeSwitchedToAndFrom() throws {
        let h = H.make(keyStatus: .valid(KeyInfo()))
        let entry = try entries()[0]
        h.history.upsert(entry)
        h.controller.transcribeOverride = { _, _ in
            Issue.record("switching makes nothing")
            return TranscriptResult(text: "x", engine: .parakeet, processingTime: 0)
        }
        h.controller.showVersion(.transcription(.parakeet), of: entry.id)
        #expect(h.history.entry(id: entry.id)?.currentKind == .transcription(.parakeet))
        #expect(h.history.entry(id: entry.id)?.text == "um hello hello there")
        h.controller.showVersion(luna, of: entry.id)
        #expect(h.history.entry(id: entry.id)?.currentKind == luna)
        #expect(h.history.entry(id: entry.id)?.text == "Hello there.")
        #expect(h.history.entry(id: entry.id)?.versions.count == 2)
        // Asking for a clean-up anyway (nothing offers it) makes nothing.
        h.controller.makeVersion(luna, of: try #require(h.history.entry(id: entry.id)))
        h.controller.makeVersion(.cleanup(of: .parakeet, by: .geminiFlashLite), of: try #require(h.history.entry(id: entry.id)))
        #expect(h.controller.runningVersions.isEmpty && h.controller.homeFailures.isEmpty)
        #expect(h.history.entry(id: entry.id)?.versions.count == 2)
    }

    /// Pasted again (Paste Last, a card), an old clean-up follows GigaAM's Pasting rules: it was Parakeet's text, and
    /// GigaAM took Parakeet's place.
    @Test func itPastesByGigaAMsRules() throws {
        #expect(try entries()[0].currentKind?.dictationModel == .gigaam)
    }
}
