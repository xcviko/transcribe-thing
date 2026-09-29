import Foundation
import Testing
@testable import TranscribeThing

// MARK: - Auto-delete: an entry and its audio go together

@MainActor
@Suite struct AutoDeleteTests {
    private func entry(_ status: TranscriptStatus, hoursAgo: Double, file: String, now: Date) -> TranscriptEntry {
        TranscriptEntry(createdAt: now.addingTimeInterval(-hoursAgo * 3600), text: status == .success ? "hi" : "",
                        engine: .parakeet, status: status, audioDuration: 3, voicedSeconds: 2, audioFileName: file)
    }

    @Test func neverIsTheDefaultAndKeepsEveryRecording() {
        let settings = AppSettings.inMemory()
        #expect(settings.autoDeleteHistoryDays == 0)
        let now = Date()
        let store = HistoryStore.preview(entries: [
            entry(.success, hoursAgo: 2, file: "recent.wav", now: now),
            entry(.success, hoursAgo: 24 * 400, file: "old.wav", now: now),
            entry(.failed, hoursAgo: 24 * 400, file: "failed.wav", now: now),
        ], settings: settings)
        store.deleteExpired(now: now)
        #expect(store.entries.map(\.audioFileName) == ["recent.wav", "old.wav", "failed.wav"])
    }

    @Test func sevenDaysDeletesOlderEntriesWhateverTheyAre() {
        let settings = AppSettings.inMemory()
        settings.autoDeleteHistoryDays = 7
        let now = Date()
        let six = entry(.success, hoursAgo: 24 * 6, file: "six.wav", now: now)
        let eight = entry(.success, hoursAgo: 24 * 8, file: "eight.wav", now: now)
        let failed = entry(.failed, hoursAgo: 24 * 9, file: "failed.wav", now: now)
        let store = HistoryStore.preview(entries: [six, eight, failed], settings: settings)
        var removed: [UUID] = []
        store.onRemove = { removed += $0 }
        store.deleteExpired(now: now)
        #expect(store.entries.map(\.id) == [six.id])
        #expect(Set(removed) == [eight.id, failed.id], "Home work for them is canceled too")
        store.deleteExpired(now: now)
        #expect(removed.count == 2, "nothing more to delete")
    }

    @Test func theChoicesAreNeverOrADayToThreeMonths() {
        #expect(AutoDeleteChoice.days.map(AutoDeleteChoice.label)
                == ["Never", "After 1 day", "After 7 days", "After 30 days", "After 90 days"])
    }
}

// MARK: - Entries: versions, decoding, migration

@MainActor
@Suite struct TranscriptVersionTests {
    private func decode(_ json: String) throws -> TranscriptEntry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptEntry.self, from: Data(json.utf8))
    }

    private func roundTrip(_ entry: TranscriptEntry) throws -> TranscriptEntry {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptEntry.self, from: encoder.encode(entry))
    }

    private let gemini = TranscriptVersion(
        kind: .transcription(.geminiFlash), text: "gemini text",
        metadata: TranscriptMetadata(createdAt: Date(timeIntervalSince1970: 1_790_000_100), modelID: "google/gemini-3.8-flash",
                                     provider: "Google AI Studio", generationID: "gen-1", reasoningEffort: .low,
                                     usage: TokenUsage(promptTokens: 1925, audioTokens: 1800, cachedTokens: 0,
                                                       completionTokens: 17_900, reasoningTokens: 17_700, totalTokens: 19_825),
                                     costUSD: 0.07, processingTime: 76, generationTime: 74.5, usedSystemPrompt: false,
                                     finishReason: "stop"))

    @Test func aNewEntryHasOneCurrentVersion() {
        let entry = TranscriptEntry(text: "hello", engine: .parakeetCloud, audioDuration: 3, voicedSeconds: 2,
                                    processingTime: 0.4, costUSD: 0.0001, provider: "Together")
        #expect(entry.versions.count == 1)
        #expect(entry.currentKind == .transcription(.parakeetCloud))
        #expect(entry.text == "hello" && entry.engine == .parakeetCloud && entry.provider == "Together")
        #expect(entry.costUSD == 0.0001 && entry.processingTime == 0.4)
        let failed = TranscriptEntry(text: "", engine: .geminiPro, status: .failed, audioDuration: 3, voicedSeconds: 2)
        #expect(failed.versions.isEmpty && failed.currentKind == nil)
        #expect(failed.engine == .geminiPro && failed.text.isEmpty)
    }

    @Test func switchingVersionsChangesWhatTheRowShows() {
        var entry = TranscriptEntry(text: "parakeet text", engine: .parakeet, audioDuration: 3, voicedSeconds: 2,
                                    audioFileName: "a.wav")
        let added = entry.addVersion(gemini)
        #expect(added)
        #expect(entry.text == "gemini text" && entry.engine == .geminiFlash && entry.costUSD == 0.07)
        #expect(entry.versions.map(\.kind) == [.transcription(.parakeet), .transcription(.geminiFlash)])
        let store = HistoryStore.preview(entries: [entry])
        store.selectVersion(.transcription(.parakeet), of: entry.id)
        let switched = try! #require(store.entry(id: entry.id))
        #expect(switched.text == "parakeet text" && switched.engine == .parakeet && switched.costUSD == nil)
        #expect(switched.provider == nil)
        #expect(switched.createdAt == entry.createdAt && switched.audioFileName == "a.wav")
        #expect(switched.versions.count == 2, "switching keeps every version")
        store.selectVersion(.cleanup(of: .parakeet, by: .geminiFlashLite), of: entry.id)
        #expect(store.entry(id: entry.id)?.currentKind == .transcription(.parakeet), "a version it doesn't have")
    }

    @Test func aVersionOfTheSameKindReplacesTheOldOneInPlace() {
        var entry = TranscriptEntry(text: "parakeet text", engine: .parakeet, audioDuration: 3, voicedSeconds: 2)
        entry.addVersion(gemini)
        entry.addVersion(TranscriptVersion(text: "parakeet again", engine: .parakeet), makeCurrent: false)
        #expect(entry.versions.map(\.text) == ["parakeet again", "gemini text"])
        #expect(entry.currentKind == .transcription(.geminiFlash))
        var failed = TranscriptEntry(text: "", engine: .parakeet, status: .failed, audioDuration: 3, voicedSeconds: 2)
        let addedToFailed = failed.addVersion(gemini)
        #expect(!addedToFailed, "a failed row has no versions")
    }

    @Test func metadataRoundTripsWithEveryField() throws {
        var entry = TranscriptEntry(text: "parakeet text", engine: .parakeet, audioDuration: 3, voicedSeconds: 2,
                                    processingTime: 0.3)
        entry.addVersion(gemini)
        entry.addVersion(TranscriptVersion(kind: .cleanup(of: .parakeet, by: .geminiFlashLite), text: "Parakeet text.",
                                           metadata: TranscriptMetadata(modelID: CleanupModel.geminiFlashLite.openRouterModelID,
                                                                        reasoningEffort: .minimal, usedSystemPrompt: true)),
                         makeCurrent: false)
        let decoded = try roundTrip(entry)
        #expect(decoded.versions.count == 3)
        #expect(decoded.version(.transcription(.geminiFlash))?.metadata == gemini.metadata)
        #expect(decoded.version(.cleanup(of: .parakeet, by: .geminiFlashLite))?.metadata.reasoningEffort == .minimal)
        #expect(decoded.currentKind == .transcription(.geminiFlash))
        #expect(decoded.text == "gemini text")
    }

    /// A streamed version keeps how much of its thinking it showed and when it started writing; files from before
    /// streaming, or with a value this build can't read, still load.
    @Test func reasoningCharactersAreKeptInHistory() throws {
        var metadata = gemini.metadata
        metadata.reasoningCharacters = 2_345
        metadata.timeToFirstToken = 61.25
        var entry = TranscriptEntry(text: "parakeet text", engine: .parakeet, audioDuration: 3, voicedSeconds: 2)
        entry.addVersion(TranscriptVersion(kind: .transcription(.geminiFlash), text: "gemini text", metadata: metadata))
        let decoded = try roundTrip(entry)
        #expect(decoded.version(.transcription(.geminiFlash))?.metadata == metadata)
        #expect(decoded.currentVersion?.metadata.reasoningCharacters == 2_345)
        #expect(decoded.currentVersion?.metadata.timeToFirstToken == 61.25)

        let id = UUID().uuidString
        let old = try decode("""
        {"audioDuration":4.5,"createdAt":"2026-09-20T10:00:00Z","engine":"geminiFlash","id":"\(id)","status":"success",
         "voicedSeconds":3,"currentVersion":"geminiFlash",
         "versions":[{"kind":"geminiFlash","text":"hi","metadata":{"createdAt":"2026-09-20T10:00:00Z","costUSD":0.01}}]}
        """)
        #expect(old.currentVersion?.metadata.reasoningCharacters == nil)
        #expect(old.currentVersion?.metadata.costUSD == 0.01)
        let odd = try decode("""
        {"audioDuration":4.5,"createdAt":"2026-09-20T10:00:00Z","engine":"geminiFlash","id":"\(id)","status":"success",
         "voicedSeconds":3,"currentVersion":"geminiFlash",
         "versions":[{"kind":"geminiFlash","text":"hi","metadata":{"createdAt":"2026-09-20T10:00:00Z","reasoningCharacters":"lots","costUSD":0.01}}]}
        """)
        #expect(odd.currentVersion?.text == "hi" && odd.currentVersion?.metadata.reasoningCharacters == nil)
        #expect(odd.currentVersion?.metadata.costUSD == 0.01, "only the field it can't read is dropped")
    }

    @Test func theFlatFieldsStayReadableForOlderBuilds() throws {
        var entry = TranscriptEntry(text: "raw", engine: .parakeet, audioDuration: 3, voicedSeconds: 2)
        entry.addVersion(TranscriptVersion(kind: .cleanup(of: .parakeet, by: .geminiFlashLite), text: "Clean.",
                                           metadata: TranscriptMetadata(provider: "Google AI Studio", costUSD: 0.0002)))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        #expect(object["text"] as? String == "Clean.")
        #expect(object["engine"] as? String == "parakeet")
        #expect(object["costUSD"] as? Double == 0.0002)
        #expect(object["currentVersion"] as? String == "cleanup:parakeet")
        #expect(object["previous"] == nil)
    }

    @Test func oldHistoryWithoutVersionsBecomesOneVersion() throws {
        let entry = try decode("""
        {"audioDuration":4.5,"createdAt":"2026-09-20T10:00:00Z","engine":"parakeetCloud","id":"\(UUID().uuidString)",
         "status":"success","text":"hello","voicedSeconds":3,"costUSD":0.0001,"provider":"Together","processingTime":1.1}
        """)
        #expect(entry.versions.count == 1)
        let version = try #require(entry.currentVersion)
        #expect(version.kind == .transcription(.parakeetCloud) && version.text == "hello")
        #expect(version.metadata.provider == "Together" && version.metadata.costUSD == 0.0001)
        #expect(version.metadata.processingTime == 1.1)
        #expect(version.metadata.createdAt == entry.createdAt)
        #expect(entry.audioFileName == nil)
    }

    @Test func aPreviousTextBecomesTheOlderVersion() throws {
        let entry = try decode("""
        {"audioDuration":4.5,"createdAt":"2026-09-20T10:00:00Z","engine":"geminiPro","id":"\(UUID().uuidString)",
         "status":"success","text":"new","voicedSeconds":3,"costUSD":0.01,
         "previous":{"text":"old","engine":"parakeetCloud","provider":"Together","costUSD":0.0001,"processingTime":1.25}}
        """)
        #expect(entry.versions.map(\.kind) == [.transcription(.parakeetCloud), .transcription(.geminiPro)])
        #expect(entry.currentKind == .transcription(.geminiPro) && entry.text == "new")
        let old = try #require(entry.version(.transcription(.parakeetCloud)))
        #expect(old.text == "old" && old.metadata.provider == "Together" && old.metadata.costUSD == 0.0001)
        #expect(old.metadata.processingTime == 1.25 && old.metadata.createdAt == entry.createdAt)
    }

    @Test func aPreviousTextFromARetiredEngineReadsAsItsSuccessor() throws {
        let entry = try decode("""
        {"audioDuration":4.5,"createdAt":"2026-09-20T10:00:00Z","engine":"geminiPro","id":"\(UUID().uuidString)",
         "status":"success","text":"new","voicedSeconds":3,"previous":{"text":"old","engine":"whisper"}}
        """)
        #expect(entry.version(.transcription(.parakeet))?.text == "old")
    }

    @Test func aPreviousTextOfTheSameEngineAsTheCurrentOneIsDropped() throws {
        let entry = try decode("""
        {"audioDuration":4.5,"createdAt":"2026-09-20T10:00:00Z","engine":"parakeet","id":"\(UUID().uuidString)",
         "status":"success","text":"new","voicedSeconds":3,"previous":{"text":"old","engine":"parakeet"}}
        """)
        #expect(entry.versions.map(\.text) == ["new"])
    }

    @Test func anUnreadablePreviousTextOrVersionDoesntCostTheEntry() throws {
        let previous = try decode("""
        {"audioDuration":4.5,"createdAt":"2026-09-20T10:00:00Z","engine":"geminiPro","id":"\(UUID().uuidString)",
         "status":"success","text":"new","voicedSeconds":3,"previous":{"text":"old","engine":"futureModel"}}
        """)
        #expect(previous.text == "new" && previous.versions.count == 1)
        let versions = try decode("""
        {"audioDuration":4.5,"createdAt":"2026-09-20T10:00:00Z","engine":"parakeet","id":"\(UUID().uuidString)",
         "status":"success","text":"Clean.","voicedSeconds":3,"currentVersion":"cleanup:parakeet",
         "versions":[{"kind":"futureModel","text":"x","metadata":{"createdAt":"2026-09-20T10:00:00Z"}},
                     {"kind":"parakeet","text":"raw","metadata":{"createdAt":"2026-09-20T10:00:00Z","reasoningEffort":"extreme"}},
                     {"kind":"cleanup:parakeet","text":"Clean.","metadata":{"createdAt":"2026-09-20T10:00:01Z","costUSD":0.0002}}]}
        """)
        #expect(versions.versions.map(\.kind) == [.transcription(.parakeet), .cleanup(of: .parakeet, by: .geminiFlashLite)])
        #expect(versions.version(.transcription(.parakeet))?.metadata.reasoningEffort == nil, "an unknown level is dropped")
        #expect(versions.currentKind == .cleanup(of: .parakeet, by: .geminiFlashLite) && versions.text == "Clean.")
    }

    @Test func aCurrentVersionThatDidntDecodeFallsBackToTheFlatText() throws {
        let entry = try decode("""
        {"audioDuration":4.5,"createdAt":"2026-09-20T10:00:00Z","engine":"parakeet","id":"\(UUID().uuidString)",
         "status":"success","text":"shown","voicedSeconds":3,"currentVersion":"cleanup:futureModel",
         "versions":[{"kind":"parakeet","text":"raw","metadata":{"createdAt":"2026-09-20T10:00:00Z"}}]}
        """)
        #expect(entry.text == "shown" && entry.currentKind == .transcription(.parakeet))
        #expect(entry.versions.count == 1, "the flat transcript takes the place of its kind")
    }

    @Test func versionsPersist() async throws {
        let paths = AppPaths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let settings = AppSettings.inMemory()
        let store = HistoryStore(paths: paths, settings: settings)
        store.load()
        try await waitUntil { store.isLoaded }
        var entry = TranscriptEntry(createdAt: Date(timeIntervalSince1970: 1_790_000_000.5), text: "old", engine: .parakeetCloud,
                                    audioDuration: 4, voicedSeconds: 3, processingTime: 1.25, costUSD: 0.0001,
                                    provider: "Together")
        entry.addVersion(gemini)
        store.upsert(entry)
        store.flush()
        let reloaded = HistoryStore(paths: paths, settings: settings)
        reloaded.load()
        try await waitUntil { reloaded.isLoaded }
        let loaded = try #require(reloaded.entries.first)
        #expect(loaded.versions.map(\.metadata) == entry.versions.map(\.metadata))
        #expect(loaded.versions.map(\.kind) == entry.versions.map(\.kind))
        #expect(loaded.createdAt == entry.createdAt)
        #expect(loaded == entry)
    }

    @Test func kindsHaveStableRawValues() {
        #expect(TranscriptVersionKind.transcription(.geminiPro).rawValue == "geminiPro")
        #expect(TranscriptVersionKind.cleanup(of: .parakeetCloud, by: .geminiFlashLite).rawValue == "cleanup:parakeetCloud")
        #expect(TranscriptVersionKind(rawValue: "cleanup:whisper") == .cleanup(of: .parakeet, by: .geminiFlashLite))
        #expect(TranscriptVersionKind(rawValue: "cleanup:nope") == nil)
        #expect(TranscriptVersionKind.cleanup(of: .parakeet, by: .geminiFlashLite).displayName == "Parakeet v3 + Clean-up by Flash Lite")
        // A clean-up by another model carries it; Flash Lite's keeps the shape older builds wrote and read.
        let luna = TranscriptVersionKind.cleanup(of: .parakeet, by: .gpt6Luna)
        #expect(luna.rawValue == "cleanup:parakeet:gpt6Luna")
        #expect(TranscriptVersionKind(rawValue: "cleanup:parakeet:gpt6Luna") == luna)
        #expect(TranscriptVersionKind(rawValue: "cleanup:parakeetCloud:geminiFlashLite") == .cleanup(of: .parakeetCloud, by: .geminiFlashLite))
        #expect(TranscriptVersionKind.cleanup(of: .parakeet, by: .geminiFlashLite).rawValue == "cleanup:parakeet",
                "Flash Lite's clean-ups keep the form older builds read, retired or not")
        #expect(TranscriptVersionKind(rawValue: "cleanup:parakeet") == .cleanup(of: .parakeet, by: .geminiFlashLite))
        #expect(TranscriptVersionKind(rawValue: "cleanup:parakeet:gpt9") == nil, "a model from a newer build")
        #expect(TranscriptVersionKind(rawValue: "cleanup:whisper:gpt6Luna") == luna, "a retired engine reads as its successor")
        #expect(luna.displayName == "Parakeet v3 + Clean-up by GPT-6 Luna" && luna.cleanupModel == .gpt6Luna)
        #expect(luna.progressTitle == "Cleaning up with GPT-6 Luna…")
        #expect(TranscriptVersionKind.transcription(.parakeet).cleanupModel == nil)
    }

    @Test func versionsRoundTripWithTheirCleanUpModel() throws {
        var entry = TranscriptEntry(text: "raw", engine: .parakeet, audioDuration: 5, voicedSeconds: 4)
        entry.addVersion(TranscriptVersion(kind: .cleanup(of: .parakeet, by: .geminiFlashLite), text: "Flash.", metadata: TranscriptMetadata()))
        entry.addVersion(TranscriptVersion(kind: .cleanup(of: .parakeet, by: .gpt6Luna), text: "Luna.",
                                           metadata: TranscriptMetadata(modelID: "openai/gpt-6-luna",
                                                                        reasoningEffort: .off)))
        let data = try JSONEncoder().encode(entry)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""cleanup:parakeet""#) && json.contains(#""cleanup:parakeet:gpt6Luna""#))
        #expect(json.contains(#""reasoningEffort":"none""#))
        let decoded = try JSONDecoder().decode(TranscriptEntry.self, from: data)
        #expect(decoded.versions.map(\.kind) == [.transcription(.parakeet), .cleanup(of: .parakeet, by: .geminiFlashLite),
                                                 .cleanup(of: .parakeet, by: .gpt6Luna)])
        #expect(decoded.currentKind == .cleanup(of: .parakeet, by: .gpt6Luna) && decoded.text == "Luna.")
        #expect(decoded.version(.cleanup(of: .parakeet, by: .gpt6Luna))?.metadata.reasoningEffort == .off)
    }

    @Test func anOlderBuildKeepsTheTranscriptionACleanUpItCantReadTidied() throws {
        var entry = TranscriptEntry(text: "raw", engine: .parakeet, audioDuration: 5, voicedSeconds: 4,
                                    processingTime: 0.4)
        entry.addVersion(TranscriptVersion(kind: .cleanup(of: .parakeet, by: .geminiFlashLite), text: "Flash.",
                                           metadata: TranscriptMetadata(costUSD: 0.0002)), makeCurrent: false)
        entry.addVersion(TranscriptVersion(kind: .cleanup(of: .parakeet, by: .gpt6Luna), text: "Luna.",
                                           metadata: TranscriptMetadata(provider: "OpenAI", costUSD: 0.0001,
                                                                        processingTime: 1.1)))
        let data = try JSONEncoder().encode(entry)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["text"] as? String == "raw" && object["engine"] as? String == "parakeet")
        #expect(object["provider"] == nil && object["costUSD"] == nil && object["processingTime"] as? Double == 0.4)
        #expect(try JSONDecoder().decode(TranscriptEntry.self, from: data) == entry, "this build reads Luna's as current")

        // A build that can't read the model (as older builds can't read "gpt6Luna") drops only that version.
        let older = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "gpt6Luna", with: "futureModel")
        let decoded = try JSONDecoder().decode(TranscriptEntry.self, from: Data(older.utf8))
        #expect(decoded.versions.map(\.kind) == [.cleanup(of: .parakeet, by: .geminiFlashLite), .transcription(.parakeet)])
        #expect(decoded.version(.transcription(.parakeet))?.text == "raw")
        #expect(decoded.currentKind == .transcription(.parakeet) && decoded.text == "raw")

        // Flash Lite's is read by older builds, so its text stays flat.
        entry.selectVersion(.cleanup(of: .parakeet, by: .geminiFlashLite))
        let flash = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        #expect(flash["text"] as? String == "Flash." && flash["costUSD"] as? Double == 0.0002)
    }

    @Test func metadataSummaryIsCompact() {
        #expect(gemini.metadata.summary == "76 s · $0.07 · 17.7k thinking")
        #expect(TranscriptMetadata(processingTime: 0.42).summary == "0.4 s")
        #expect(TranscriptMetadata().summary.isEmpty)
        #expect(Fmt.tokens(820) == "820" && Fmt.tokens(17_700) == "17.7k" && Fmt.tokens(120_400) == "120k")
    }
}

// MARK: - The Versions menu

@Suite struct VersionsMenuTests {
    private func menu(_ entry: TranscriptEntry, key: KeyStatus = .valid(KeyInfo()), local: LocalModelState = .ready,
                      running: TranscriptVersionKind? = nil) -> VersionsMenu {
        VersionsMenu.make(for: entry, running: running, readiness: {
            EngineReadiness.of($0, localState: local, keyStatus: key)
        })
    }

    private func transcript(_ engine: EngineID = .parakeet, duration: TimeInterval = 90, audio: Bool = true) -> TranscriptEntry {
        TranscriptEntry(text: "hello", engine: engine, audioDuration: duration, voicedSeconds: duration / 2,
                        processingTime: 0.4, audioFileName: audio ? "a.wav" : nil)
    }

    private func action(_ m: VersionsMenu, _ kind: TranscriptVersionKind) -> VersionsMenu.Action? {
        m.actions.first { $0.kind == kind }
    }

    @Test func aTranscriptListsItsVersionAndOffersEveryOtherEngineAndCleanUp() {
        let m = menu(transcript(.parakeet))
        #expect(m.title == "Versions" && !m.isRetry && m.runningTitle == nil)
        #expect(m.versions == [VersionsMenu.Version(kind: .transcription(.parakeet), summary: "0.4 s", isCurrent: true)])
        #expect(m.actions.map(\.kind) == [.transcription(.parakeetCloud), .transcription(.geminiFlash),
                                          .cleanup(of: .parakeet, by: .gpt6Luna)])
        #expect(m.actions.allSatisfy { $0.isEnabled })
        #expect(m.actions.map(\.title) == ["Parakeet v3 · Cloud", "Gemini 3.8 Flash", "Clean Up with GPT-6 Luna"])
    }

    @Test func aModelAlreadyUsedIsAVersionNotAnAction() {
        var entry = transcript(.parakeet)
        entry.addVersion(TranscriptVersion(text: "g", engine: .geminiFlash, costUSD: 0.002, processingTime: 3))
        let flashLite = TranscriptVersionKind.cleanup(of: .parakeet, by: .geminiFlashLite)
        entry.addVersion(TranscriptVersion(kind: flashLite, text: "c", metadata: TranscriptMetadata()), makeCurrent: false)
        let m = menu(entry)
        #expect(m.versions.map(\.kind) == [.transcription(.parakeet), .transcription(.geminiFlash), flashLite])
        #expect(m.versions.map(\.isCurrent) == [false, true, false])
        #expect(m.versions[1].summary == "3.0 s · $0.002")
        #expect(m.actions.map(\.kind) == [.transcription(.parakeetCloud), .cleanup(of: .parakeet, by: .gpt6Luna)],
                "Flash Lite already cleaned it up; Luna still can")
    }

    @Test func eachCleanUpModelTidiesTheSameTextOnce() {
        var entry = transcript(.parakeet)
        entry.addVersion(TranscriptVersion(kind: .cleanup(of: .parakeet, by: .gpt6Luna), text: "l",
                                           metadata: TranscriptMetadata(processingTime: 1.1)))
        var m = menu(entry)
        #expect(!m.actions.contains { $0.kind.isCleanup }, "Luna has tidied it")
        #expect(m.versions.last?.itemTitle == "Parakeet v3 + Clean-up by GPT-6 Luna\u{2003}1.1 s")
        entry.addVersion(TranscriptVersion(kind: .cleanup(of: .parakeet, by: .geminiFlashLite), text: "f",
                                           metadata: TranscriptMetadata()))
        m = menu(entry)
        #expect(!m.actions.contains { $0.kind.isCleanup })
        #expect(m.versions.map(\.kind) == [.transcription(.parakeet), .cleanup(of: .parakeet, by: .gpt6Luna),
                                           .cleanup(of: .parakeet, by: .geminiFlashLite)])
    }

    @Test func geminiTranscriptsAreNeverCleanedUp() {
        #expect(!menu(transcript(.geminiFlash)).actions.contains { $0.kind.isCleanup })
        #expect(menu(transcript(.parakeetCloud)).actions.last?.kind == .cleanup(of: .parakeetCloud, by: .gpt6Luna))
    }

    @Test func withoutAKeyCloudActionsSaySo() {
        let m = menu(transcript(.parakeet), key: .missing)
        #expect(m.actions.map(\.title) == ["Parakeet v3 · Cloud · Needs key", "Gemini 3.8 Flash · Needs key",
                                           "Clean Up with GPT-6 Luna · Needs key"])
        #expect(action(menu(transcript(.parakeetCloud), key: .invalid("401")), .transcription(.geminiFlash))?.title
                == "Gemini 3.8 Flash · Key rejected")
        #expect(action(menu(transcript(.parakeetCloud), key: .missing), .transcription(.parakeet))?.isEnabled == true)
    }

    @Test func geminiTakesARecordingOfAnyLength() {
        #expect(menu(transcript(.parakeet, duration: 60 * 60)).actions.allSatisfy { $0.isEnabled })
    }

    @Test func withoutAudioVersionsStaySwitchableAndCleanUpStillWorks() {
        var entry = transcript(.parakeet, audio: false)
        entry.addVersion(TranscriptVersion(text: "g", engine: .geminiFlash))
        let m = menu(entry)
        #expect(m.versions.count == 2)
        #expect(action(m, .transcription(.parakeetCloud))?.blocker == .recordingGone)
        #expect(action(m, .transcription(.parakeetCloud))?.title == "Parakeet v3 · Cloud · Recording no longer kept")
        #expect(action(m, .cleanup(of: .parakeet, by: .gpt6Luna))?.isEnabled == true)
    }

    @Test func somethingRunningBlocksEveryActionButNotSwitching() {
        let m = menu(transcript(), running: .transcription(.geminiFlash))
        #expect(m.runningTitle == "Transcribing with Gemini Flash…")
        #expect(m.actions.allSatisfy { $0.blocker == .running(.transcription(.geminiFlash)) })
        #expect(m.versions.count == 1)
        #expect(menu(transcript(), running: .cleanup(of: .parakeet, by: .gpt6Luna)).runningTitle
                == "Cleaning up with GPT-6 Luna…")
    }

    @Test func aFailedDictationRetriesWithAnyEngineItsOwnIncluded() {
        let failed = TranscriptEntry(text: "", engine: .geminiFlash, status: .failed, audioDuration: 20, voicedSeconds: 15,
                                     audioFileName: "f.wav")
        let m = menu(failed)
        #expect(m.title == "Retry With" && m.isRetry && m.versions.isEmpty)
        #expect(m.actions.map(\.kind) == EngineID.offered.map { .transcription($0) })
        var gone = failed
        gone.audioFileName = nil
        #expect(menu(gone).actions.allSatisfy { $0.blocker == .recordingGone })
    }
}

// MARK: - Running it

@MainActor
@Suite(.serialized) struct TranscribeAgainControllerTests {
    private typealias H = DictationControllerTests

    /// A dictation transcribed by Parakeet and pasted, its audio kept on disk.
    private func dictate(_ h: H.Harness, _ recording: Recording? = nil, text: String = "parakeet text",
                         pasted: @escaping (String) -> Void) async throws -> UUID {
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: text, engine: engine, processingTime: 0.1) }
        h.controller.insertOverride = { text, _ in pasted(text); return .pasted }
        let r = recording ?? H.recording()
        h.controller.enqueue(r, engine: .parakeet, targetPID: nil)
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id) != nil }
        return r.id
    }

    @Test func aSuccessfulDictationKeepsItsAudioAsLongAsItsEntry() async throws {
        let h = H.make(persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        let id = try await dictate(h) { _ in }
        let entry = try #require(h.history.entry(id: id))
        #expect(entry.audioFileName == "\(id.uuidString).wav")
        #expect(h.history.loadRecording(for: entry) != nil)
        h.history.deleteExpired(now: Date().addingTimeInterval(400 * 86_400))
        #expect(h.history.entry(id: id)?.audioFileName == entry.audioFileName, "Never: kept for good")

        h.settings.autoDeleteHistoryDays = 1
        h.history.deleteExpired(now: Date().addingTimeInterval(2 * 86_400))
        #expect(h.history.entry(id: id) == nil, "the entry goes, and its recording with it")
        let file = try #require(h.paths).recordingURL(fileName: "\(id.uuidString).wav")
        try await waitUntil { !FileManager.default.fileExists(atPath: file.path) }
    }

    @Test func transcribingAgainReplacesTheTextInPlaceAndNeverPastes() async throws {
        let h = H.make(persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        var pasted: [String] = []
        let id = try await dictate(h) { pasted.append($0) }
        let original = try #require(h.history.entry(id: id))
        h.controller.transcribeOverride = { _, engine in
            try await Task.sleep(for: .milliseconds(80))
            return TranscriptResult(text: "  gemini text ", engine: engine, processingTime: 2, costUSD: 0.003)
        }
        h.controller.retry(original, with: .geminiFlash)
        #expect(h.controller.runningVersions[id] == .transcription(.geminiFlash))
        // One at a time: a second request while it runs is ignored.
        h.controller.retry(original, with: .parakeetCloud)
        #expect(h.controller.homeWork == [id: .transcription(.geminiFlash)])
        try await waitUntil { h.history.entry(id: id)?.engine == .geminiFlash }
        #expect(h.controller.runningVersions.isEmpty && h.controller.homeWork.isEmpty)

        let updated = try #require(h.history.entry(id: id))
        #expect(h.history.entries.count == 1)
        #expect(updated.text == "gemini text")
        #expect(updated.status == .success)
        #expect(updated.createdAt == original.createdAt)
        #expect(updated.costUSD == 0.003)
        #expect(updated.audioFileName == original.audioFileName)
        #expect(updated.versions.map(\.kind) == [.transcription(.parakeet), .transcription(.geminiFlash)])
        #expect(updated.currentKind == .transcription(.geminiFlash))
        #expect(pasted == ["parakeet text"], "Transcribe Again never pastes by itself")
        #expect(h.toasts.notices.isEmpty, "the row shows the new text: no card")

        h.controller.showVersion(.transcription(.parakeet), of: id)
        #expect(h.history.entry(id: id)?.text == "parakeet text")
        #expect(h.history.entry(id: id)?.version(.transcription(.geminiFlash))?.text == "gemini text")
    }

    /// A failed Transcribe Again leaves the row as it was and says why in it; its Retry runs the same model again,
    /// and the reason goes as that starts.
    @Test func aFailedTranscribeAgainKeepsTheTextAndSaysWhyInTheRow() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        let id = try await dictate(h) { _ in }
        let original = try #require(h.history.entry(id: id))
        var engines: [EngineID] = []
        var fail = true
        h.controller.transcribeOverride = { _, engine in
            engines.append(engine)
            if fail { throw AppError.timeout(engine) }
            try await Task.sleep(for: .milliseconds(50))
            return TranscriptResult(text: "second try", engine: engine, processingTime: 1)
        }
        h.controller.makeVersion(.transcription(.geminiFlash), of: original)
        try await waitUntil { h.controller.homeFailures[id] != nil }
        let failure = try #require(h.controller.homeFailures[id])
        #expect(failure == HomeFailure(kind: .transcription(.geminiFlash), reason: "It took too long."))
        #expect(h.history.entry(id: id) == original, "the row keeps its text, engine and audio")
        #expect(h.controller.runningVersions.isEmpty)
        #expect(h.toasts.notices.isEmpty)

        fail = false
        h.controller.makeVersion(failure.kind, of: try #require(h.history.entry(id: id)))
        #expect(h.controller.homeFailures[id] == nil, "new work clears the reason")
        try await waitUntil { h.history.entry(id: id)?.text == "second try" }
        #expect(engines == [.geminiFlash, .geminiFlash])
        #expect(h.history.entry(id: id)?.version(.transcription(.parakeet))?.text == "parakeet text")
        #expect(h.controller.homeFailures.isEmpty && h.toasts.notices.isEmpty)
    }

    /// Cancel in the row stops Transcribe Again: nothing lands, and the row stays as it was (not a canceled row,
    /// though the recording is long enough for one), with nothing to undo.
    @Test func cancelingTranscribeAgainLeavesTheRowAsItWas() async throws {
        let h = H.make(persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        let long = Recording(samples: Array(repeating: 0.1, count: 16_000 * 25),
                             speech: SpeechStats(voicedSeconds: 20, peakDBFS: -10, isSilent: false))
        var pasted: [String] = []
        let id = try await dictate(h, long) { pasted.append($0) }
        let original = try #require(h.history.entry(id: id))
        var finished = false
        h.controller.transcribeOverride = { _, engine in
            try await Task.sleep(for: .milliseconds(150))
            finished = true
            return TranscriptResult(text: "too late", engine: engine, processingTime: 1)
        }
        h.controller.retry(original, with: .geminiFlash)
        #expect(h.controller.homeWork[id] == .transcription(.geminiFlash))
        h.controller.cancelHomeWork(for: id)
        #expect(h.controller.runningVersions.isEmpty && h.controller.homeWork.isEmpty)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!finished, "the transcription itself stopped")
        #expect(h.history.entry(id: id) == original)
        #expect(h.controller.homeFailures.isEmpty)
        #expect(h.toasts.notices.isEmpty)
        #expect(pasted == ["parakeet text"])
    }

    /// A dictation fails, then Home's Retry transcribes it: the failure notice goes, and its Retry, clicked all the
    /// same (it was on its way out), never pastes the text or runs a model again.
    @Test func aRetryFromHomeClearsTheFailureNoticeWhoseRetryThenDoesNothing() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        var runs: [EngineID] = []
        var pasted: [String] = []
        h.controller.transcribeOverride = { _, engine in
            runs.append(engine)
            if engine == .parakeetCloud { throw AppError.timeout(engine) }
            return TranscriptResult(text: "text by \(engine.rawValue)", engine: engine, processingTime: 1)
        }
        h.controller.insertOverride = { text, _ in pasted.append(text); return .pasted }
        let r = H.recording()
        h.controller.enqueue(r, engine: .parakeetCloud, targetPID: nil)
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.toasts.notices.contains { $0.recordingID == r.id } }
        let failure = try #require(h.toasts.notices.first { $0.recordingID == r.id })
        let retry = try #require(failure.actions.first { $0.kind == .retry })

        h.controller.retry(try #require(h.history.entry(id: r.id)), with: .geminiFlash)
        try await waitUntil { h.history.entry(id: r.id)?.status == .success }
        #expect(!h.toasts.notices.contains { $0.recordingID == r.id }, "the failure notice goes once the row has text")

        h.controller.perform(retry, from: failure)
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.controller.machine.activeJobs == 0 && h.controller.runningVersions.isEmpty)
        #expect(runs == [.parakeetCloud, .geminiFlash])
        #expect(pasted.isEmpty)
        let entry = try #require(h.history.entry(id: r.id))
        #expect(entry.versions.map(\.kind) == [.transcription(.geminiFlash)])
        #expect(h.history.entries.count == 1)
    }

    /// A long dictation canceled (its row kept, Undo offered), then transcribed from Home: the Undo goes, and
    /// clicked all the same it never opens the mic.
    @Test func transcribingACanceledDictationFromHomeClearsItsUndoWhichNeverOpensTheMic() async throws {
        let h = H.make(persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        let long = Recording(samples: Array(repeating: 0.1, count: 16_000 * 25),
                             speech: SpeechStats(voicedSeconds: 20, peakDBFS: -10, isSilent: false))
        h.recorder.next = long
        h.controller.send(.handsFreeToggle)
        h.controller.handle(.cancel)
        let toast = try #require(h.toasts.notices.first { $0.dedupeKey == "dictation.canceled" })
        let undo = try #require(toast.actions.first { $0.kind == .undoCancel })
        let canceled = try #require(h.history.entry(id: long.id))
        #expect(canceled.status == .cancelled)

        h.controller.transcribeOverride = { _, engine in
            TranscriptResult(text: "text by \(engine.rawValue)", engine: engine, processingTime: 1)
        }
        h.controller.retry(canceled, with: .parakeet)
        try await waitUntil { h.history.entry(id: long.id)?.status == .success }
        #expect(!h.toasts.notices.contains { $0.recordingID == long.id }, "the Undo toast goes once the row has text")

        h.controller.perform(undo, from: toast)
        #expect(!h.controller.machine.isRecording, "Undo never opens the mic for a transcribed recording")
        #expect(h.recorder.starts == 1)
        #expect(h.controller.machine.activeJobs == 0)
        #expect(h.history.entry(id: long.id)?.text == "text by parakeet")
    }

    /// No text from the model: the row keeps its text, and says there was no speech.
    @Test func silenceOnTranscribeAgainKeepsTheTextAndSaysSo() async throws {
        let h = H.make(persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        let id = try await dictate(h) { _ in }
        let original = try #require(h.history.entry(id: id))
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: " \n ", engine: engine, processingTime: 1) }
        h.controller.retry(original, with: .geminiFlash)
        try await waitUntil { h.controller.homeFailures[id] != nil }
        #expect(h.controller.homeFailures[id] == HomeFailure(kind: .transcription(.geminiFlash), reason: "No speech detected"))
        let kept = try #require(h.history.entry(id: id))
        #expect(kept.text == original.text && kept.engine == original.engine)
        #expect(kept.versions.count == 1)
        #expect(kept.audioFileName == original.audioFileName)
        #expect(h.history.loadRecording(for: kept) != nil)
        #expect(h.pill.errorMessage == nil && h.toasts.notices.isEmpty)
    }

    @Test func aTranscriptWhoseAudioIsGoneSaysSoInItsRow() {
        let h = H.make()
        let entry = TranscriptEntry(text: "hi", engine: .parakeet, audioDuration: 3, voicedSeconds: 2)
        h.history.upsert(entry)
        h.controller.retry(entry, with: .geminiFlash)
        #expect(h.controller.runningVersions.isEmpty)
        let failure = h.controller.homeFailures[entry.id]
        #expect(failure == .recordingGone(.transcription(.geminiFlash)))
        #expect(failure?.isRecordingGone == true && failure?.reason == "Recording no longer kept")
        #expect(h.toasts.notices.isEmpty)
        #expect(h.history.entry(id: entry.id) == entry)
    }

    /// Deleted while Home transcribes it, a transcript or a failed dictation isn't brought back.
    @Test func aDeletedRowIsntBroughtBack() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        let id = try await dictate(h) { _ in }
        h.controller.transcribeOverride = { _, engine in throw AppError.timeout(engine) }
        let failed = H.recording()
        h.controller.enqueue(failed, engine: .geminiFlash, targetPID: nil)
        try await waitUntil { h.history.entry(id: failed.id)?.status == .failed && h.controller.machine.activeJobs == 0 }

        h.controller.transcribeOverride = { _, engine in
            try await Task.sleep(for: .milliseconds(60))
            return TranscriptResult(text: "late", engine: engine, processingTime: 1)
        }
        for entryID in [id, failed.id] {
            h.controller.retry(try #require(h.history.entry(id: entryID)), with: .parakeetCloud)
            h.history.delete(entryID)
        }
        try await waitUntil { h.controller.runningVersions.isEmpty }
        #expect(h.history.entries.isEmpty)
        #expect(h.controller.homeFailures.isEmpty)
    }
}
