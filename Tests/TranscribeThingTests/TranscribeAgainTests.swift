import Foundation
import Testing
@testable import TranscribeThing

// MARK: - Keeping the audio of successful dictations

@MainActor
@Suite struct TranscribeAgainRetentionTests {
    private func entry(_ status: TranscriptStatus, hoursAgo: Double, file: String, now: Date) -> TranscriptEntry {
        TranscriptEntry(createdAt: now.addingTimeInterval(-hoursAgo * 3600), text: status == .success ? "hi" : "",
                        engine: .parakeet, status: status, audioDuration: 3, voicedSeconds: 2, audioFileName: file)
    }

    @Test func successfulAudioIsKeptForADayByDefault() {
        let settings = AppSettings.inMemory()
        #expect(settings.keepSuccessfulRecordingsDays == 1)
        let now = Date()
        let store = HistoryStore.preview(entries: [
            entry(.success, hoursAgo: 2, file: "recent.wav", now: now),
            entry(.success, hoursAgo: 30, file: "old.wav", now: now),
            entry(.failed, hoursAgo: 30, file: "failed.wav", now: now),
            entry(.cancelled, hoursAgo: 31, file: "canceled.wav", now: now),
        ], settings: settings)
        store.pruneOldRecordings(now: now)
        #expect(store.entries.map(\.audioFileName) == ["recent.wav", nil, "failed.wav", "canceled.wav"])
        #expect(store.entries.count == 4, "a row whose audio is pruned stays")
    }

    @Test func offKeepsNoSuccessfulAudioAndLeavesFailedRowsAlone() {
        let settings = AppSettings.inMemory()
        settings.keepSuccessfulRecordingsDays = 0
        let now = Date()
        let store = HistoryStore.preview(entries: [
            entry(.success, hoursAgo: 0.1, file: "recent.wav", now: now),
            entry(.failed, hoursAgo: 2, file: "failed.wav", now: now),
        ], settings: settings)
        store.pruneOldRecordings(now: now)
        #expect(store.entries.map(\.audioFileName) == [nil, "failed.wav"])
    }

    @Test func sevenDaysKeepsAWeek() {
        let settings = AppSettings.inMemory()
        settings.keepSuccessfulRecordingsDays = 7
        let now = Date()
        let store = HistoryStore.preview(entries: [
            entry(.success, hoursAgo: 24 * 6, file: "six.wav", now: now),
            entry(.success, hoursAgo: 24 * 8, file: "eight.wav", now: now),
        ], settings: settings)
        store.pruneOldRecordings(now: now)
        #expect(store.entries.map(\.audioFileName) == ["six.wav", nil])
    }

    @Test func theChoicesAreOffADayOrAWeek() {
        #expect(AppSettings.inMemory().keepSuccessfulRecordingsDays == 1)
        #expect(RetentionChoice.transcribeAgainDays.map(RetentionChoice.transcribeAgainLabel) == ["Off", "1 day", "7 days"])
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
        store.selectVersion(.cleanup(of: .parakeet), of: entry.id)
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
        entry.addVersion(TranscriptVersion(kind: .cleanup(of: .parakeet), text: "Parakeet text.",
                                           metadata: TranscriptMetadata(modelID: CleanupModel.openRouterModelID,
                                                                        reasoningEffort: .minimal, usedSystemPrompt: true)),
                         makeCurrent: false)
        let decoded = try roundTrip(entry)
        #expect(decoded.versions.count == 3)
        #expect(decoded.version(.transcription(.geminiFlash))?.metadata == gemini.metadata)
        #expect(decoded.version(.cleanup(of: .parakeet))?.metadata.reasoningEffort == .minimal)
        #expect(decoded.currentKind == .transcription(.geminiFlash))
        #expect(decoded.text == "gemini text")
    }

    @Test func theFlatFieldsStayReadableForOlderBuilds() throws {
        var entry = TranscriptEntry(text: "raw", engine: .parakeet, audioDuration: 3, voicedSeconds: 2)
        entry.addVersion(TranscriptVersion(kind: .cleanup(of: .parakeet), text: "Clean.",
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
        #expect(versions.versions.map(\.kind) == [.transcription(.parakeet), .cleanup(of: .parakeet)])
        #expect(versions.version(.transcription(.parakeet))?.metadata.reasoningEffort == nil, "an unknown level is dropped")
        #expect(versions.currentKind == .cleanup(of: .parakeet) && versions.text == "Clean.")
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
        #expect(TranscriptVersionKind.cleanup(of: .parakeetCloud).rawValue == "cleanup:parakeetCloud")
        #expect(TranscriptVersionKind(rawValue: "cleanup:whisper") == .cleanup(of: .parakeet))
        #expect(TranscriptVersionKind(rawValue: "cleanup:nope") == nil)
        #expect(TranscriptVersionKind.cleanup(of: .parakeet).displayName == "Parakeet v3 + Clean-up")
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
                      running: TranscriptVersionKind? = nil, prompt: Bool = true) -> VersionsMenu {
        VersionsMenu.make(for: entry, running: running, readiness: {
            EngineReadiness.of($0, localState: local, keyStatus: key)
        }, hasCleanupPrompt: prompt)
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
                                          .transcription(.geminiPro), .cleanup(of: .parakeet)])
        #expect(m.actions.allSatisfy { $0.isEnabled })
        #expect(m.actions.map(\.title) == ["Parakeet v3 · Cloud", "Gemini 3.8 Flash", "Gemini 3.1 Pro", "Clean Up"])
    }

    @Test func aModelAlreadyUsedIsAVersionNotAnAction() {
        var entry = transcript(.parakeet)
        entry.addVersion(TranscriptVersion(text: "g", engine: .geminiFlash, costUSD: 0.002, processingTime: 3))
        entry.addVersion(TranscriptVersion(kind: .cleanup(of: .parakeet), text: "c", metadata: TranscriptMetadata()),
                         makeCurrent: false)
        let m = menu(entry)
        #expect(m.versions.map(\.kind) == [.transcription(.parakeet), .transcription(.geminiFlash), .cleanup(of: .parakeet)])
        #expect(m.versions.map(\.isCurrent) == [false, true, false])
        #expect(m.versions[1].summary == "3.0 s · $0.002")
        #expect(m.actions.map(\.kind) == [.transcription(.parakeetCloud), .transcription(.geminiPro)])
    }

    @Test func geminiTranscriptsAreNeverCleanedUp() {
        #expect(!menu(transcript(.geminiPro)).actions.contains { $0.kind.isCleanup })
        #expect(menu(transcript(.parakeetCloud)).actions.last?.kind == .cleanup(of: .parakeetCloud))
    }

    @Test func withoutAKeyCloudActionsSaySo() {
        let m = menu(transcript(.parakeet), key: .missing)
        #expect(m.actions.map(\.title) == ["Parakeet v3 · Cloud · Needs key", "Gemini 3.8 Flash · Needs key",
                                           "Gemini 3.1 Pro · Needs key", "Clean Up · Needs key"])
        #expect(action(menu(transcript(.parakeetCloud), key: .invalid("401")), .transcription(.geminiPro))?.title
                == "Gemini 3.1 Pro · Key rejected")
        #expect(action(menu(transcript(.parakeetCloud), key: .missing), .transcription(.parakeet))?.isEnabled == true)
    }

    @Test func geminiCantTakeMoreThanOneRequest() {
        let long = menu(transcript(.parakeet, duration: 8 * 60))
        #expect(action(long, .transcription(.geminiFlash))?.title == "Gemini 3.8 Flash · Too long for Gemini")
        #expect(action(long, .transcription(.geminiPro))?.blocker == .tooLongForGemini)
        #expect(action(long, .transcription(.parakeetCloud))?.isEnabled == true)
        #expect(action(long, .cleanup(of: .parakeet))?.isEnabled == true, "a clean-up needs only the text")
        #expect(menu(transcript(.parakeet, duration: 7 * 60 + 1)).actions.allSatisfy { $0.isEnabled })
    }

    @Test func withoutAudioVersionsStaySwitchableAndCleanUpStillWorks() {
        var entry = transcript(.parakeet, audio: false)
        entry.addVersion(TranscriptVersion(text: "g", engine: .geminiFlash))
        let m = menu(entry)
        #expect(m.versions.count == 2)
        #expect(action(m, .transcription(.geminiPro))?.blocker == .recordingGone)
        #expect(action(m, .transcription(.geminiPro))?.title == "Gemini 3.1 Pro · Recording no longer kept")
        #expect(action(m, .cleanup(of: .parakeet))?.isEnabled == true)
    }

    @Test func cleanUpNeedsAPrompt() {
        let m = menu(transcript(.parakeet), prompt: false)
        #expect(action(m, .cleanup(of: .parakeet))?.blocker == .cleanupPromptEmpty)
        #expect(action(m, .cleanup(of: .parakeet))?.title == "Clean Up · Needs a clean-up prompt")
    }

    @Test func somethingRunningBlocksEveryActionButNotSwitching() {
        let m = menu(transcript(), running: .transcription(.geminiFlash))
        #expect(m.runningTitle == "Transcribing with Gemini Flash…")
        #expect(m.actions.allSatisfy { $0.blocker == .running(.transcription(.geminiFlash)) })
        #expect(m.versions.count == 1)
        #expect(menu(transcript(), running: .cleanup(of: .parakeet)).runningTitle == "Cleaning up…")
    }

    @Test func aFailedDictationRetriesWithAnyEngineItsOwnIncluded() {
        let failed = TranscriptEntry(text: "", engine: .geminiPro, status: .failed, audioDuration: 20, voicedSeconds: 15,
                                     audioFileName: "f.wav")
        let m = menu(failed)
        #expect(m.title == "Retry With" && m.isRetry && m.versions.isEmpty)
        #expect(m.actions.map(\.kind) == EngineID.allCases.map { .transcription($0) })
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
        h.controller.enqueue(r, engine: .parakeet, delivery: .paste(targetPID: nil))
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id) != nil }
        return r.id
    }

    @Test func aSuccessfulDictationKeepsItsAudioUntilItExpires() async throws {
        let h = H.make(persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        let id = try await dictate(h) { _ in }
        let entry = try #require(h.history.entry(id: id))
        #expect(entry.audioFileName == "\(id.uuidString).wav")
        #expect(h.history.loadRecording(for: entry) != nil)
        h.history.pruneOldRecordings(now: Date().addingTimeInterval(2 * 86_400))
        #expect(h.history.entry(id: id)?.audioFileName == nil)
        #expect(h.history.entry(id: id)?.text == "parakeet text")
    }

    @Test func withTheSettingOffNoAudioIsKept() async throws {
        let h = H.make(persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        h.settings.keepSuccessfulRecordingsDays = 0
        let id = try await dictate(h) { _ in }
        #expect(h.history.entry(id: id)?.audioFileName == nil)
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
        #expect(h.controller.transcribingEngines[id] == .geminiFlash)
        // One at a time: a second request while it runs is ignored.
        h.controller.retry(original, with: .geminiPro)
        #expect(h.controller.machine.activeJobs == 1)
        try await waitUntil { h.history.entry(id: id)?.engine == .geminiFlash }
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(h.controller.transcribingEngines.isEmpty)

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

        let card = try #require(h.toasts.notices.first { $0.transcript == "gemini text" })
        #expect(card.title == "Transcribed with Gemini Flash")
        #expect(card.actions.map(\.kind) == [.pasteText("gemini text"), .copyText("gemini text")])

        h.controller.showVersion(.transcription(.parakeet), of: id)
        #expect(h.history.entry(id: id)?.text == "parakeet text")
        #expect(h.history.entry(id: id)?.version(.transcription(.geminiFlash))?.text == "gemini text")
    }

    @Test func aFailedTranscribeAgainKeepsTheTextAndRetriesWithTheSameEngine() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        let id = try await dictate(h) { _ in }
        let original = try #require(h.history.entry(id: id))
        var engines: [EngineID] = []
        var fail = true
        h.controller.transcribeOverride = { _, engine in
            engines.append(engine)
            if fail { throw AppError.timeout(engine) }
            return TranscriptResult(text: "second try", engine: engine, processingTime: 1)
        }
        h.controller.retry(original, with: .geminiPro)
        try await waitUntil { h.controller.machine.activeJobs == 0 && !engines.isEmpty }
        let kept = try #require(h.history.entry(id: id))
        #expect(kept == original, "the row keeps its text, engine and audio")
        let notice = try #require(h.toasts.notices.first { $0.recordingID == id })
        #expect(!notice.actions.contains { $0.kind == .retryWith(.parakeet) },
                "never offers the engine that wrote the text")
        let retry = try #require(notice.actions.first { $0.kind == .retry })
        fail = false
        h.controller.perform(retry, from: notice)
        try await waitUntil { h.history.entry(id: id)?.text == "second try" }
        #expect(engines == [.geminiPro, .geminiPro])
        #expect(h.history.entry(id: id)?.version(.transcription(.parakeet))?.text == "parakeet text")
    }

    @Test func aCanceledTranscribeAgainLeavesTheRowAndUndoFinishesIt() async throws {
        let h = H.make(persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        // Long enough that a canceled dictation would get a row of its own.
        let long = Recording(samples: Array(repeating: 0.1, count: 16_000 * 25),
                             speech: SpeechStats(voicedSeconds: 20, peakDBFS: -10, isSilent: false))
        var pasted: [String] = []
        let id = try await dictate(h, long) { pasted.append($0) }
        let original = try #require(h.history.entry(id: id))
        h.controller.transcribeOverride = { _, engine in
            try await Task.sleep(for: .milliseconds(150))
            return TranscriptResult(text: "after undo", engine: engine, processingTime: 1)
        }
        h.controller.retry(original, with: .geminiFlash)
        h.controller.handle(.cancel)
        #expect(h.controller.machine.activeJobs == 0)
        #expect(h.history.entry(id: id) == original, "still the transcript, not a canceled row")
        let undo = try #require(h.toasts.notices.first { $0.dedupeKey == "dictation.canceled" })
        #expect(undo.title == "Transcription canceled")
        h.controller.perform(try #require(undo.actions.first { $0.kind == .undoCancel }), from: undo)
        try await waitUntil { h.history.entry(id: id)?.text == "after undo" }
        #expect(h.history.entry(id: id)?.engine == .geminiFlash)
        #expect(pasted == ["parakeet text"])
    }

    @Test func aTranscribeAgainThatSucceedsClearsTheOlderFailureAndItsRetryNeverPastes() async throws {
        let h = H.make(keyStatus: .valid(KeyInfo()), persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        var pasted: [String] = []
        let id = try await dictate(h) { pasted.append($0) }
        h.controller.transcribeOverride = { _, engine in
            if engine == .geminiPro { throw AppError.timeout(engine) }
            return TranscriptResult(text: "text by \(engine.rawValue)", engine: engine, processingTime: 1)
        }
        h.controller.retry(try #require(h.history.entry(id: id)), with: .geminiPro)
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.toasts.notices.contains { $0.recordingID == id } }
        let failure = try #require(h.toasts.notices.first { $0.recordingID == id })
        let retry = try #require(failure.actions.first { $0.kind == .retry })

        h.controller.retry(try #require(h.history.entry(id: id)), with: .geminiFlash)
        try await waitUntil { h.history.entry(id: id)?.engine == .geminiFlash && h.controller.machine.activeJobs == 0 }
        #expect(!h.toasts.notices.contains { $0.recordingID == id }, "the failure notice goes once the row has new text")

        // Clicked all the same (it was on its way out): never pasted, and never Gemini Flash a second time.
        h.controller.perform(retry, from: failure)
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(pasted == ["parakeet text"])
        let entry = try #require(h.history.entry(id: id))
        #expect(entry.status == .success && entry.versions.count == 2)
        #expect(entry.currentKind == .transcription(.geminiFlash))
        #expect(h.history.entries.count == 1)
    }

    @Test func aTranscribeAgainThatSucceedsClearsTheOlderUndoWhichNeverOpensTheMic() async throws {
        let h = H.make(persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        let long = Recording(samples: Array(repeating: 0.1, count: 16_000 * 25),
                             speech: SpeechStats(voicedSeconds: 20, peakDBFS: -10, isSilent: false))
        var pasted: [String] = []
        let id = try await dictate(h, long) { pasted.append($0) }
        h.controller.transcribeOverride = { _, engine in
            if engine == .geminiPro { try await Task.sleep(for: .milliseconds(150)) }
            return TranscriptResult(text: "text by \(engine.rawValue)", engine: engine, processingTime: 1)
        }
        h.controller.retry(try #require(h.history.entry(id: id)), with: .geminiPro)
        h.controller.handle(.cancel)
        let toast = try #require(h.toasts.notices.first { $0.dedupeKey == "dictation.canceled" })
        let undo = try #require(toast.actions.first { $0.kind == .undoCancel })

        h.controller.retry(try #require(h.history.entry(id: id)), with: .geminiFlash)
        try await waitUntil { h.history.entry(id: id)?.engine == .geminiFlash && h.controller.machine.activeJobs == 0 }
        #expect(!h.toasts.notices.contains { $0.recordingID == id }, "the Undo toast goes once the row has new text")

        h.controller.perform(undo, from: toast)
        #expect(!h.controller.machine.isRecording, "Undo never opens the mic for a transcribed recording")
        #expect(h.controller.machine.activeJobs == 0)
        #expect(h.history.entry(id: id)?.text == "text by geminiFlash")
        #expect(h.history.entry(id: id)?.version(.transcription(.parakeet))?.text == "parakeet text")
        #expect(pasted == ["parakeet text"])
    }

    @Test func silenceOnTranscribeAgainKeepsTheText() async throws {
        let h = H.make(persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        let id = try await dictate(h) { _ in }
        let original = try #require(h.history.entry(id: id))
        var asked = false
        h.controller.transcribeOverride = { _, engine in
            asked = true
            return TranscriptResult(text: " \n ", engine: engine, processingTime: 1)
        }
        h.controller.retry(original, with: .geminiFlash)
        try await waitUntil { asked && h.controller.machine.activeJobs == 0 }
        let kept = try #require(h.history.entry(id: id))
        #expect(kept.text == original.text && kept.engine == original.engine)
        #expect(kept.versions.count == 1)
        #expect(kept.audioFileName == original.audioFileName)
        #expect(h.history.loadRecording(for: kept) != nil)
    }

    @Test func aTranscriptWhoseAudioIsGoneSaysSo() {
        let h = H.make()
        let entry = TranscriptEntry(text: "hi", engine: .parakeet, audioDuration: 3, voicedSeconds: 2)
        h.history.upsert(entry)
        h.controller.retry(entry, with: .geminiFlash)
        #expect(h.controller.machine.activeJobs == 0)
        #expect(!h.toasts.notices.isEmpty)
        #expect(h.history.entry(id: entry.id) == entry)
    }

    @Test func aDeletedRowIsntBroughtBackButTheCardStillHasTheText() async throws {
        let h = H.make(persistsHistory: true)
        defer { h.paths.map { try? FileManager.default.removeItem(at: $0.root) } }
        let id = try await dictate(h) { _ in }
        let original = try #require(h.history.entry(id: id))
        h.controller.transcribeOverride = { _, engine in
            try await Task.sleep(for: .milliseconds(60))
            return TranscriptResult(text: "late", engine: engine, processingTime: 1)
        }
        h.controller.retry(original, with: .geminiFlash)
        h.history.delete(id)
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(h.history.entry(id: id) == nil)
        #expect(h.toasts.notices.contains { $0.transcript == "late" })
    }
}
