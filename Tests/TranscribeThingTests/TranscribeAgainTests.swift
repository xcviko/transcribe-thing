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

// MARK: - Entries: previous text, decoding

@MainActor
@Suite struct TranscriptVersionTests {
    @Test func restorePreviousTextSwapsBackAndForth() {
        let entry = TranscriptEntry(text: "gemini text", engine: .geminiFlash, audioDuration: 3, voicedSeconds: 2,
                                    costUSD: 0.002, audioFileName: "a.wav", provider: "Google AI Studio",
                                    previous: TranscriptVersion(text: "parakeet text", engine: .parakeet, processingTime: 0.3))
        let store = HistoryStore.preview(entries: [entry])
        store.restorePreviousText(entry.id)
        var restored = try! #require(store.entry(id: entry.id))
        #expect(restored.text == "parakeet text")
        #expect(restored.engine == .parakeet)
        #expect(restored.costUSD == nil && restored.provider == nil)
        #expect(restored.createdAt == entry.createdAt && restored.audioFileName == "a.wav")
        #expect(restored.previous == TranscriptVersion(text: "gemini text", engine: .geminiFlash, provider: "Google AI Studio",
                                                       costUSD: 0.002))
        store.restorePreviousText(entry.id)
        restored = try! #require(store.entry(id: entry.id))
        #expect(restored.text == "gemini text" && restored.engine == .geminiFlash)
    }

    @Test func oldHistoryWithoutTheNewFieldsDecodes() throws {
        let json = """
        {"audioDuration":4.5,"createdAt":"2026-09-20T10:00:00Z","engine":"parakeet","id":"\(UUID().uuidString)",
         "status":"success","text":"hello","voicedSeconds":3}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(TranscriptEntry.self, from: Data(json.utf8))
        #expect(entry.text == "hello")
        #expect(entry.previous == nil && entry.audioFileName == nil)
    }

    @Test func aPreviousTextFromARetiredEngineReadsAsItsSuccessor() throws {
        let json = """
        {"audioDuration":4.5,"createdAt":"2026-09-20T10:00:00Z","engine":"geminiPro","id":"\(UUID().uuidString)",
         "status":"success","text":"new","voicedSeconds":3,"previous":{"text":"old","engine":"whisper"}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(TranscriptEntry.self, from: Data(json.utf8))
        #expect(entry.previous == TranscriptVersion(text: "old", engine: .parakeet))
    }

    @Test func anUnreadablePreviousTextDoesntCostTheEntry() throws {
        let json = """
        {"audioDuration":4.5,"createdAt":"2026-09-20T10:00:00Z","engine":"geminiPro","id":"\(UUID().uuidString)",
         "status":"success","text":"new","voicedSeconds":3,"previous":{"text":"old","engine":"futureModel"}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(TranscriptEntry.self, from: Data(json.utf8))
        #expect(entry.text == "new" && entry.previous == nil)
    }

    @Test func previousTextPersists() async throws {
        let paths = AppPaths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let settings = AppSettings.inMemory()
        let store = HistoryStore(paths: paths, settings: settings)
        store.load()
        try await waitUntil { store.isLoaded }
        let entry = TranscriptEntry(createdAt: Date(timeIntervalSince1970: 1_790_000_000.5), text: "new", engine: .geminiPro,
                                    audioDuration: 4, voicedSeconds: 3, audioFileName: "x.wav",
                                    previous: TranscriptVersion(text: "old", engine: .parakeetCloud, provider: "Together",
                                                                costUSD: 0.0001, processingTime: 1.25))
        store.upsert(entry)
        store.flush()
        let reloaded = HistoryStore(paths: paths, settings: settings)
        reloaded.load()
        try await waitUntil { reloaded.isLoaded }
        #expect(reloaded.entries.first?.previous == entry.previous)
    }
}

// MARK: - The row menu

@Suite struct TranscribeAgainMenuTests {
    private func menu(_ entry: TranscriptEntry, key: KeyStatus = .valid(KeyInfo()),
                      local: LocalModelState = .ready, transcribingWith: EngineID? = nil) -> TranscribeAgainMenu {
        TranscribeAgainMenu.make(for: entry, transcribingWith: transcribingWith) {
            EngineReadiness.of($0, localState: local, keyStatus: key)
        }
    }

    private func transcript(_ engine: EngineID = .parakeet, duration: TimeInterval = 90, audio: Bool = true) -> TranscriptEntry {
        TranscriptEntry(text: "hello", engine: engine, audioDuration: duration, voicedSeconds: duration / 2,
                        audioFileName: audio ? "a.wav" : nil)
    }

    @Test func aTranscriptOffersEveryOtherEngine() {
        let m = menu(transcript(.parakeet))
        #expect(m.title == "Transcribe Again With")
        #expect(m.unavailableTitle == nil)
        #expect(m.items.map(\.engine) == [.parakeetCloud, .geminiFlash, .geminiPro])
        #expect(m.items.allSatisfy { $0.isEnabled })
        #expect(m.items.map(\.title) == ["Parakeet v3 · Cloud", "Gemini 3.8 Flash", "Gemini 3.1 Pro"])
        #expect(menu(transcript(.geminiFlash)).items.map(\.engine) == [.parakeet, .parakeetCloud, .geminiPro])
    }

    @Test func withoutAKeyCloudEnginesSaySo() {
        let m = menu(transcript(.parakeet), key: .missing)
        #expect(m.items.map(\.title) == ["Parakeet v3 · Cloud · Needs key", "Gemini 3.8 Flash · Needs key",
                                         "Gemini 3.1 Pro · Needs key"])
        #expect(!m.items.contains { $0.isEnabled })
        #expect(menu(transcript(.parakeetCloud), key: .invalid("401")).items.first { $0.engine == .geminiPro }?.title
                == "Gemini 3.1 Pro · Key rejected")
        #expect(menu(transcript(.parakeetCloud), key: .missing).items.first { $0.engine == .parakeet }?.isEnabled == true)
    }

    @Test func geminiCantTakeMoreThanOneRequest() {
        let long = menu(transcript(.parakeet, duration: 8 * 60))
        #expect(long.items.first { $0.engine == .geminiFlash }?.title == "Gemini 3.8 Flash · Too long for Gemini")
        #expect(long.items.first { $0.engine == .geminiPro }?.isEnabled == false)
        #expect(long.items.first { $0.engine == .parakeetCloud }?.isEnabled == true)
        // A Gemini dictation stopped at its 7-minute limit, plus the tail, still fits.
        #expect(menu(transcript(.parakeet, duration: 7 * 60 + 1)).items.allSatisfy { $0.isEnabled })
    }

    @Test func noAudioOrATranscriptionUnderWayDisablesTheWholeMenu() {
        #expect(menu(transcript(audio: false)).unavailableTitle == "Transcribe Again · Recording no longer kept")
        #expect(menu(transcript(), transcribingWith: .geminiFlash).unavailableTitle == "Transcribing with Gemini Flash…")
    }

    @Test func aFailedDictationRetriesWithAnyEngineItsOwnIncluded() {
        let failed = TranscriptEntry(text: "", engine: .geminiPro, status: .failed, audioDuration: 20, voicedSeconds: 15,
                                     audioFileName: "f.wav")
        let m = menu(failed)
        #expect(m.title == "Retry With")
        #expect(m.items.map(\.engine) == EngineID.allCases)
        var gone = failed
        gone.audioFileName = nil
        #expect(menu(gone).unavailableTitle == "Retry · Recording no longer kept")
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
        #expect(updated.previous?.text == "parakeet text" && updated.previous?.engine == .parakeet)
        #expect(pasted == ["parakeet text"], "Transcribe Again never pastes by itself")

        let card = try #require(h.toasts.notices.first { $0.transcript == "gemini text" })
        #expect(card.title == "Transcribed with Gemini Flash")
        #expect(card.actions.map(\.kind) == [.pasteText("gemini text"), .copyText("gemini text")])

        h.history.restorePreviousText(id)
        #expect(h.history.entry(id: id)?.text == "parakeet text")
        #expect(h.history.entry(id: id)?.previous?.text == "gemini text")
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
        #expect(h.history.entry(id: id)?.previous?.text == "parakeet text")
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

        // Clicked all the same (it was on its way out): back into the row, never pasted, the row keeps a previous text.
        h.controller.perform(retry, from: failure)
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(pasted == ["parakeet text"])
        let entry = try #require(h.history.entry(id: id))
        #expect(entry.status == .success && entry.previous != nil)
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
        #expect(h.history.entry(id: id)?.previous?.text == "parakeet text")
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
        #expect(kept.previous == nil)
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
