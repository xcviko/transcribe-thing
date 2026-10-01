import Foundation
import Testing
@testable import TranscribeThing

/// What the History row shows of its versions: the menu item text, the clean-up names when there are two to
/// choose from, and the engine badge's tooltip (`VersionDetails`).
@Suite struct VersionsMenuItemTests {
    private func menu(_ entry: TranscriptEntry, running: TranscriptVersionKind? = nil) -> VersionsMenu {
        VersionsMenu.make(for: entry, running: running, readiness: {
            EngineReadiness.of($0, localState: .ready, keyStatus: .valid(KeyInfo(label: "k")))
        })
    }

    private func transcript(_ engine: EngineID = .parakeet) -> TranscriptEntry {
        TranscriptEntry(text: "hello", engine: engine, audioDuration: 20, voicedSeconds: 10, processingTime: 0.4,
                        audioFileName: "a.wav")
    }

    @Test func versionItemsCarryTheirSummaryAfterTheName() {
        var entry = transcript()
        entry.addVersion(TranscriptVersion(kind: .transcription(.geminiFlash), text: "g", metadata: TranscriptMetadata(
            usage: TokenUsage(completionTokens: 18_000, reasoningTokens: 17_700), costUSD: 0.07, processingTime: 76)))
        let items = menu(entry).versions.map(\.itemTitle)
        #expect(items == ["Parakeet v3\u{2003}0.4 s", "Gemini 3.8 Flash\u{2003}76 s · $0.07 · 17.7k thinking"])
        let bare = VersionsMenu.Version(kind: .cleanup(of: .parakeet, by: .gpt6Luna), summary: "", isCurrent: false)
        #expect(bare.itemTitle == "Parakeet v3 + Clean-up by GPT-6 Luna")
    }

    @Test func oneTextToCleanUpNamesOnlyTheModelTwoNameTheirText() {
        #expect(menu(transcript()).actions.filter(\.kind.isCleanup).map(\.name) == ["Clean Up with GPT-6 Luna"])
        var entry = transcript(.parakeet)
        entry.addVersion(TranscriptVersion(text: "cloud", engine: .parakeetCloud))
        let cleanups = menu(entry).actions.filter { $0.kind.isCleanup }
        #expect(cleanups.map(\.name) == ["Clean Up Parakeet v3 with GPT-6 Luna",
                                          "Clean Up Parakeet v3 · Cloud with GPT-6 Luna"])
        #expect(cleanups.map(\.title) == cleanups.map(\.name))
    }

    /// Gemini 3.1 Pro and Flash Lite's clean-ups stay in the menu as versions, but nothing offers to run them: not
    /// for a transcript they wrote, not for one they didn't, not for a failed dictation of theirs.
    @Test func noRetiredModelIsOffered() {
        let pro = TranscriptEntry(text: "pro", engine: .geminiPro, audioDuration: 20, voicedSeconds: 10,
                                  audioFileName: "a.wav")
        let proMenu = menu(pro)
        #expect(proMenu.versions.map(\.kind) == [.transcription(.geminiPro)])
        #expect(proMenu.versions.map(\.title) == ["Gemini 3.1 Pro"])
        #expect(proMenu.actions.map(\.kind) == [.transcription(.parakeet), .transcription(.parakeetCloud),
                                                .transcription(.geminiFlash), .polish(of: nil), .polish(of: .geminiPro)],
                "Pro's text isn't cleaned up either, only polished")

        var tidied = transcript()
        tidied.addVersion(TranscriptVersion(kind: .cleanup(of: .parakeet, by: .geminiFlashLite), text: "Hello.",
                                            metadata: TranscriptMetadata()))
        let tidiedMenu = menu(tidied)
        #expect(tidiedMenu.versions.map(\.title) == ["Parakeet v3", "Parakeet v3 + Clean-up by Flash Lite"])
        #expect(tidiedMenu.actions.map(\.kind) == [.transcription(.parakeetCloud), .transcription(.geminiFlash),
                                                   .cleanup(of: .parakeet, by: .gpt6Luna), .polish(of: nil),
                                                   .polish(of: .parakeet)])

        var failed = TranscriptEntry(text: "", engine: .geminiPro, status: .failed, audioDuration: 20, voicedSeconds: 10,
                                     audioFileName: "a.wav")
        #expect(menu(failed).actions.map(\.kind) == EngineID.offered.map(TranscriptVersionKind.transcription))
        failed.status = .cancelled
        #expect(!menu(failed).actions.contains { $0.kind.engine.isRetired || $0.kind.cleanupModel?.isRetired == true })
    }

    /// Rows name the submenu without making the menu (`VersionsMenu.title(for:)`).
    @Test func theTitleNeedsOnlyTheEntry() {
        var failed = transcript()
        failed.status = .failed
        #expect(VersionsMenu.title(for: transcript()) == "Versions")
        #expect(VersionsMenu.title(for: failed) == "Retry With")
        #expect(menu(failed).title == VersionsMenu.title(for: failed))
    }

    @Test func whileSomethingRunsEveryActionIsBusyButVersionsStaySwitchable() {
        var entry = transcript()
        entry.addVersion(TranscriptVersion(text: "g", engine: .geminiFlash))
        let m = menu(entry, running: .cleanup(of: .parakeet, by: .gpt6Luna))
        #expect(m.runningTitle == "Cleaning up with GPT-6 Luna…")
        #expect(m.actions.allSatisfy { !$0.isEnabled && $0.title.hasSuffix(" · Busy") })
        #expect(m.versions.count == 2)
        #expect(menu(entry, running: .transcription(.parakeetCloud)).runningTitle
                == "Transcribing with Parakeet v3 · Cloud…")
    }

    @Test func aGeminiVersionsTooltipHasEverythingKnown() {
        let version = TranscriptVersion(kind: .transcription(.geminiFlash), text: "t", metadata: TranscriptMetadata(
            modelID: "google/gemini-3.8-flash", provider: "Google AI Studio", generationID: "gen-1",
            reasoningEffort: .low,
            usage: TokenUsage(promptTokens: 330, audioTokens: 314, completionTokens: 612, reasoningTokens: 540),
            costUSD: 0.0021, processingTime: 2.6, timeToFirstToken: 1.2, generationTime: 2.2, latency: 0.9,
            usedSystemPrompt: false, finishReason: "stop"))
        #expect(VersionDetails.lines(for: version) == [
            "Gemini 3.8 Flash",
            "google/gemini-3.8-flash via Google AI Studio",
            "Thinking: Low",
            "Tokens: 330 in (314 audio) · 72 out · 540 thinking",
            "Cost: $0.0021",
            "Took 2.6 s · first word 1.2 s · model 2.2 s",
            "System prompt: none",
        ])
        #expect(!VersionDetails.tooltip(for: version).contains("0.9"), "OpenRouter's latency is left out")
    }

    @Test func aCleanUpSaysWhoCleanedItAndACutOffAnswerSaysSo() {
        let version = TranscriptVersion(kind: .cleanup(of: .parakeet, by: .geminiFlashLite), text: "t", metadata: TranscriptMetadata(
            modelID: CleanupModel.geminiFlashLite.openRouterModelID, reasoningEffort: .minimal, generationTime: 0.8,
            usedSystemPrompt: true, finishReason: "length"))
        #expect(VersionDetails.lines(for: version) == [
            "Parakeet v3 + Clean-up by Flash Lite",
            "google/gemini-3.5-flash-lite",
            "Thinking: Minimal",
            "Model 0.8 s",
            "System prompt: yes",
            "Finished: length",
        ])
        let luna = TranscriptVersion(kind: .cleanup(of: .parakeet, by: .gpt6Luna), text: "t", metadata: TranscriptMetadata(
            modelID: "openai/gpt-6-luna", provider: "OpenAI", reasoningEffort: .off, processingTime: 1.1))
        #expect(VersionDetails.lines(for: luna) == [
            "Parakeet v3 + Clean-up by GPT-6 Luna",
            "openai/gpt-6-luna via OpenAI",
            "Thinking: None",
            "Took 1.1 s",
        ])
    }

    @Test func theBadgeNamesTheCleanUpModelOnceWithoutDetails() {
        let luna = TranscriptVersion(kind: .cleanup(of: .parakeet, by: .gpt6Luna), text: "t",
                                     metadata: TranscriptMetadata(modelID: "openai/gpt-6-luna"))
        #expect(VersionDetails.lines(for: luna).filter { $0.contains("GPT-6 Luna") }.count == 1)
        #expect(EngineGlyph(engine: .parakeet, provider: "OpenAI", cleanupModel: .gpt6Luna).label
                == "Parakeet v3 + Clean-up by GPT-6 Luna · via OpenAI")
        #expect(EngineGlyph(engine: .parakeet, cleanupModel: .geminiFlashLite).label == "Parakeet v3 + Clean-up by Flash Lite")
        #expect(EngineGlyph(engine: .parakeet).label == "Parakeet v3")
    }

    /// A retired model's transcript reads as it always did: its name, its glyph and everything recorded about it.
    @Test func aRetiredModelsVersionKeepsItsNameGlyphAndDetails() {
        let version = TranscriptVersion(kind: .transcription(.geminiPro), text: "t", metadata: TranscriptMetadata(
            modelID: "google/gemini-3.1-pro-preview", provider: "Google AI Studio", reasoningEffort: .high,
            usage: TokenUsage(promptTokens: 900, completionTokens: 4_200, reasoningTokens: 4_000), costUSD: 0.0094,
            processingTime: 6.8))
        #expect(VersionDetails.lines(for: version) == [
            "Gemini 3.1 Pro",
            "google/gemini-3.1-pro-preview via Google AI Studio",
            "Thinking: High",
            "Tokens: 900 in · 200 out · 4k thinking",
            "Cost: $0.0094",
            "Took 6.8 s",
        ])
        #expect(EngineID.geminiPro.glyph == "Pro" && EngineID.geminiPro.shortName == "Gemini Pro")
        #expect(EngineGlyph(engine: .geminiPro, provider: "Google AI Studio").label
                == "Gemini 3.1 Pro · via Google AI Studio")
    }

    @Test func aLocalOrOldTranscriptSaysOnlyWhatItKnows() {
        #expect(VersionDetails.tooltip(for: TranscriptVersion(text: "t", engine: .parakeet, processingTime: 0.41))
                == "Parakeet v3\nTook 0.4 s")
        let cloud = TranscriptVersion(kind: .transcription(.parakeetCloud), text: "t", metadata: TranscriptMetadata(
            provider: "Together", costUSD: 0.00037, processingTime: 1.1, audioSeconds: 14.6))
        #expect(VersionDetails.lines(for: cloud) == [
            "Parakeet v3 · Cloud", "via Together", "Cost: $0.00037", "Took 1.1 s", "Audio billed: 15 s",
        ])
        #expect(VersionDetails.tokenLine(TokenUsage()) == nil)
    }
}
