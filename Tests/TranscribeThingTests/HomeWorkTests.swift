import Foundation
import Testing
@testable import TranscribeThing

// MARK: - Home work stays in Home

/// Transcribe With, Clean Up and a failed row's Retry, started from Home: they show only in their row, never in
/// the pill, a notice, a cue, the menu bar or Esc, and never hold a dictation back.
@MainActor
@Suite(.serialized) struct HomeWorkTests {
    private typealias H = DictationControllerTests

    /// Everything outside Home that could show Home work: the pill, cues, the menu bar and the failed-dictation hook
    /// (notices are read from the toast center).
    @MainActor private final class Outside {
        var phases: [PillPhase] = []
        var cues: [SoundEffect] = []
        var activities: [DictationActivity] = []
        var failedDictations = 0

        init(_ h: H.Harness) {
            h.pill.onVisiblePhaseChange = { [weak self] in self?.phases.append(h.pill.visiblePhase) }
            h.controller.playCueOverride = { [weak self] in self?.cues.append($0) }
            h.controller.onActivityChanged = { [weak self] in self?.activities.append($0) }
            h.controller.onDictationFailed = { [weak self] in self?.failedDictations += 1 }
        }

        var sawNothing: Bool { phases.isEmpty && cues.isEmpty && activities.isEmpty && failedDictations == 0 }
    }

    /// Started as the app starts it: a notice's sound, a model's failure and a deleted row reach the controller.
    private func harness(_ keyStatus: KeyStatus = .valid(KeyInfo()), store: ModelStore? = nil) -> H.Harness {
        let h = H.make(store: store, keyStatus: keyStatus, persistsHistory: true)
        h.controller.start()
        return h
    }

    /// A real model store whose Parakeet is `FakeEngine`, installed; `gate` is its inference gate.
    private func localStore(_ engine: FakeEngine, gate: InferenceGate = InferenceGate()) -> ModelStore {
        ModelStore(paths: .temporary(), settings: .inMemory(), engines: [.parakeet: engine], gate: gate,
                   freeDiskBytes: { 50_000_000_000 })
    }

    private func removeFiles(_ h: H.Harness) {
        h.paths.map { try? FileManager.default.removeItem(at: $0.root) }
    }

    /// A dictation Parakeet transcribed and pasted, its audio kept.
    private func transcript(_ h: H.Harness) async throws -> UUID {
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "parakeet text", engine: engine, processingTime: 0.1) }
        h.controller.insertOverride = { _, _ in .pasted }
        let r = H.recording()
        h.controller.enqueue(r, engine: .parakeet, targetPID: nil)
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id) != nil }
        return r.id
    }

    /// A dictation Gemini Flash failed: a failed row with its audio. Its notice is dismissed, and its shake over.
    private func failedDictation(_ h: H.Harness) async throws -> UUID {
        h.pill.timing.errorHold = 0.01
        h.controller.transcribeOverride = { _, engine in throw AppError.timeout(engine) }
        let r = H.recording()
        h.controller.enqueue(r, engine: .geminiFlash, targetPID: nil)
        try await waitUntil { h.controller.machine.activeJobs == 0 && h.history.entry(id: r.id)?.status == .failed }
        h.toasts.dismissAll()
        try await waitUntil { h.pill.visiblePhase == .rest }
        return r.id
    }

    @Test func homeWorkNeverShowsOutsideHome() async throws {
        let h = harness()
        defer { removeFiles(h) }
        let transcribed = try await transcript(h), tidied = try await transcript(h)
        let failed = try await failedDictation(h)
        let outside = Outside(h)
        let shakes = h.pill.shakeCount
        // Slower than a dictation's wait notice would wait.
        h.controller.waitNoticeDelayOverride = 0.01
        var fails = true
        h.controller.transcribeOverride = { _, engine in
            try await Task.sleep(for: .milliseconds(80))
            if fails { throw AppError.timeout(engine) }
            return TranscriptResult(text: "by \(engine.rawValue)", engine: engine, processingTime: 1)
        }
        h.controller.cleanupOverride = { _, source in
            try await Task.sleep(for: .milliseconds(80))
            if fails { throw AppError.openRouterServer("HTTP 500") }
            return TranscriptResult(text: "Clean.", engine: source, processingTime: 1)
        }
        h.controller.insertOverride = { _, _ in Issue.record("Home work is never pasted"); return .pasted }

        for failing in [true, false] {
            fails = failing
            h.controller.makeVersion(.transcription(.geminiFlash), of: try #require(h.history.entry(id: transcribed)))
            h.controller.makeVersion(.cleanup(of: .parakeet, by: .gpt6Luna), of: try #require(h.history.entry(id: tidied)))
            h.controller.makeVersion(.transcription(.parakeetCloud), of: try #require(h.history.entry(id: failed)))
            #expect(h.controller.homeWork.count == 3)
            #expect(h.controller.pendingJobCount == 0 && h.controller.machine.activeJobs == 0)
            #expect(!h.controller.machine.isBusy && !h.hotkeys.isBusy)
            #expect(h.controller.activity == .idle)
            #expect(h.pill.phase == .rest)
            try await waitUntil { h.controller.homeWork.isEmpty }
            #expect(h.toasts.notices.isEmpty)
            if failing {
                #expect(Set(h.controller.homeFailures.keys) == [transcribed, tidied], "why, in each transcript's row")
                #expect(h.history.entry(id: failed)?.errorMessage == "\(EngineID.parakeetCloud.shortName) took too long",
                        "and in the failed row itself")
            }
        }
        #expect(h.history.entry(id: transcribed)?.currentKind == .transcription(.geminiFlash))
        #expect(h.history.entry(id: tidied)?.currentKind == .cleanup(of: .parakeet, by: .gpt6Luna))
        #expect(h.history.entry(id: failed)?.status == .success)
        #expect(h.controller.homeFailures.isEmpty, "each success cleared its row's failure")
        #expect(outside.sawNothing)
        #expect(h.pill.shakeCount == shakes && h.pill.errorMessage == nil)
        #expect(h.toasts.notices.isEmpty)
    }

    /// Home work isn't busy: Esc stays with the app in front, and pressed all the same, cancels nothing.
    @Test func escDuringHomeWorkIsntBusyAndCancelsNothing() async throws {
        let h = harness()
        defer { removeFiles(h) }
        let id = try await transcript(h)
        let outside = Outside(h)
        var release = false
        h.controller.transcribeOverride = { _, engine in
            while !release { try await Task.sleep(for: .milliseconds(5)) }
            return TranscriptResult(text: "gemini text", engine: engine, processingTime: 1)
        }
        h.controller.retry(try #require(h.history.entry(id: id)), with: .geminiFlash)
        #expect(h.controller.homeWork[id] == .transcription(.geminiFlash))
        #expect(!h.controller.machine.isBusy && !h.hotkeys.isBusy, "Esc isn't taken from the app in front")
        h.controller.handle(.cancel)
        #expect(outside.cues.isEmpty, "no cancel cue: nothing was canceled")
        #expect(h.toasts.notices.isEmpty)
        #expect(h.controller.homeWork[id] == .transcription(.geminiFlash))
        release = true
        try await waitUntil { h.controller.homeWork.isEmpty }
        #expect(h.history.entry(id: id)?.text == "gemini text")
        #expect(outside.sawNothing)
    }

    /// A dictation recorded after slow Home work started is pasted as soon as it's transcribed.
    @Test func aDictationDoesntWaitForSlowHomeWork() async throws {
        let h = harness()
        defer { removeFiles(h) }
        let id = try await transcript(h)
        var release = false
        var pasted: [String] = []
        h.controller.insertOverride = { text, _ in pasted.append(text); return .pasted }
        h.controller.transcribeOverride = { recording, engine in
            guard recording.id == id else { return TranscriptResult(text: "dictated", engine: engine, processingTime: 0.1) }
            while !release { try await Task.sleep(for: .milliseconds(5)) }
            return TranscriptResult(text: "gemini text", engine: engine, processingTime: 1)
        }
        h.controller.retry(try #require(h.history.entry(id: id)), with: .geminiFlash)
        h.controller.send(.handsFreeToggle)
        h.controller.send(.pillStop)
        #expect(h.pill.phase == .processing)
        try await waitUntil { pasted == ["dictated"] && h.controller.machine.activeJobs == 0 }
        #expect(h.controller.homeWork[id] != nil, "still running")
        #expect(h.pill.phase == .rest && h.controller.activity == .idle)
        release = true
        try await waitUntil { h.controller.homeWork.isEmpty }
        #expect(h.history.entry(id: id)?.text == "gemini text")
        #expect(pasted == ["dictated"])
    }

    /// Cancel in a row stops that recording's work only: nothing of it lands and the entry stays as it was, while
    /// a dictation in flight goes on.
    @Test func cancelInARowStopsOnlyThatRecordingsWork() async throws {
        let h = harness()
        defer { removeFiles(h) }
        let id = try await transcript(h)
        let failed = try await failedDictation(h)
        let before = [h.history.entry(id: id), h.history.entry(id: failed)]
        var landed: [String] = []
        var pasted: [String] = []
        h.controller.insertOverride = { text, _ in pasted.append(text); return .pasted }
        h.controller.cleanupOverride = { _, source in
            try await Task.sleep(for: .milliseconds(150))
            landed.append("clean-up")
            return TranscriptResult(text: "Clean.", engine: source, processingTime: 1)
        }
        h.controller.transcribeOverride = { recording, engine in
            try await Task.sleep(for: .milliseconds(150))
            if recording.id == failed { landed.append("retry") }
            return TranscriptResult(text: "dictated", engine: engine, processingTime: 1)
        }
        h.controller.makeVersion(.cleanup(of: .parakeet, by: .gpt6Luna), of: try #require(h.history.entry(id: id)))
        h.controller.retry(try #require(h.history.entry(id: failed)), with: .parakeet)
        h.controller.enqueue(H.recording(), engine: .parakeet, targetPID: nil)
        #expect(h.controller.homeWork.count == 2)
        h.controller.cancelHomeWork(for: id)
        h.controller.cancelHomeWork(for: failed)
        #expect(h.controller.homeWork.isEmpty)
        #expect(h.controller.runningVersions.count == 1, "the dictation")
        try await waitUntil { pasted == ["dictated"] }
        try await Task.sleep(for: .milliseconds(250))
        #expect(landed.isEmpty)
        #expect([h.history.entry(id: id), h.history.entry(id: failed)] == before)
        #expect(h.controller.homeFailures.isEmpty)
        #expect(h.toasts.notices.isEmpty)
    }

    /// Why Home work failed stays in its row until it's dismissed or something else is made for the recording.
    @Test func aFailureStaysInItsRowUntilDismissedOrNewWork() async throws {
        let h = harness()
        defer { removeFiles(h) }
        let id = try await transcript(h)
        let cleanUp = TranscriptVersionKind.cleanup(of: .parakeet, by: .gpt6Luna)
        h.controller.cleanupOverride = { _, _ in throw AppError.openRouterServer("HTTP 500") }
        h.controller.makeVersion(cleanUp, of: try #require(h.history.entry(id: id)))
        try await waitUntil { h.controller.homeFailures[id] != nil }
        #expect(h.controller.homeFailures[id] == HomeFailure(kind: cleanUp, reason: "OpenRouter ran into a problem."))
        h.controller.dismissHomeFailure(for: id)
        #expect(h.controller.homeFailures.isEmpty)

        h.controller.makeVersion(cleanUp, of: try #require(h.history.entry(id: id)))
        try await waitUntil { h.controller.homeFailures[id] != nil }
        var release = false
        h.controller.transcribeOverride = { _, engine in
            while !release { try await Task.sleep(for: .milliseconds(5)) }
            return TranscriptResult(text: "gemini text", engine: engine, processingTime: 1)
        }
        h.controller.makeVersion(.transcription(.geminiFlash), of: try #require(h.history.entry(id: id)))
        #expect(h.controller.homeFailures[id] == nil, "gone as soon as the new work starts")
        #expect(h.controller.runningVersions[id] == .transcription(.geminiFlash))
        release = true
        try await waitUntil { h.controller.homeWork.isEmpty }
        #expect(h.controller.homeFailures.isEmpty)
        #expect(h.toasts.notices.isEmpty)
    }

    /// A key that can't work is a reason in the row like any other, and costs no request.
    @Test func aKeyProblemReadsAsTheRowsReason() async throws {
        let h = harness(.missing)
        defer { removeFiles(h) }
        let id = try await transcript(h)
        h.controller.cleanupOverride = { _, source in
            Issue.record("no request with a key that can't work")
            return TranscriptResult(text: "x", engine: source, processingTime: 1)
        }
        h.controller.makeVersion(.cleanup(of: .parakeet, by: .gpt6Luna), of: try #require(h.history.entry(id: id)))
        try await waitUntil { h.controller.homeFailures[id] != nil }
        #expect(h.controller.homeFailures[id]?.reason == "Add your OpenRouter key in Models.")

        h.controller.transcribeOverride = { _, _ in throw AppError.openRouterMissingKey }
        h.controller.makeVersion(.transcription(.geminiFlash), of: try #require(h.history.entry(id: id)))
        try await waitUntil { h.controller.homeFailures[id]?.kind == .transcription(.geminiFlash) }
        #expect(h.controller.homeFailures[id]?.reason == "Add your OpenRouter key in Models.", "the same words")
        #expect(h.toasts.notices.isEmpty)
    }

    /// The row's title names the model ("Couldn't transcribe with Gemini Flash"), so the reason after it says "It";
    /// a key, credit or connection problem reads the same for a transcription and a clean-up.
    @Test func reasonsDontNameTheModelTwice() {
        let reason = DictationController.homeFailureReason(_:making:)
        let flash = TranscriptVersionKind.transcription(.geminiFlash)
        let luna = TranscriptVersionKind.cleanup(of: .parakeet, by: .gpt6Luna)
        #expect(flash.failureTitle == "Couldn’t transcribe with Gemini Flash")
        #expect(luna.failureTitle == "Couldn’t clean up with GPT-6 Luna")
        #expect(reason(.timeout(.geminiFlash), flash) == "It took too long.")
        #expect(reason(.timeout(.parakeet), luna) == "It took too long.")
        #expect(reason(.engineFailed(.parakeet, "CoreML"), .transcription(.parakeet)) == "It ran into a problem.")
        #expect(reason(.modelLoadFailed(.parakeet, "corrupt"), .transcription(.parakeet)) == "It couldn’t be loaded.")
        #expect(reason(nil, luna) == "It returned no text.")
        #expect(reason(.openRouterBadRequest(""), flash) == "It couldn’t process this recording.")
        #expect(reason(.openRouterBadRequest(""), luna) == "It couldn’t process the text.")
        #expect(reason(.openRouterProviderUnavailable(""), luna) == "OpenAI is unavailable.")
        #expect(reason(.openRouterProviderUnavailable(""), flash) == "Google AI Studio is unavailable")
        #expect(reason(.openRouterProviderUnavailable(""), .transcription(.parakeetCloud))
                == "OpenRouter couldn’t reach its provider.")
        #expect(reason(.noSpeech, flash) == "No speech detected")
        for error: AppError in [.openRouterMissingKey, .openRouterInvalidKey(""), .openRouterNoCredits(""), .offline,
                                .openRouterRateLimited(retryAfter: nil), .openRouterServer("")] {
            #expect(reason(error, flash) == reason(error, luna))
            #expect(reason(error, flash) == DictationController.cleanupFailureReason(error, model: .gpt6Luna))
        }
    }

    /// The local model takes one recording at a time, and Home's wait behind a dictation's, even one recorded after
    /// them: the retry already running finishes, then the dictation is transcribed and pasted while the other Home
    /// retry still waits.
    @Test func aDictationGetsTheLocalModelBeforeHomeWorkWaitingForIt() async throws {
        let engine = FakeEngine(.parakeet, installed: true)
        let gate = InferenceGate()
        let store = localStore(engine, gate: gate)
        store.start()
        try await waitUntil { store.state(of: .parakeet) == .ready }
        let h = harness(store: store)
        defer { removeFiles(h) }
        let first = try await failedDictation(h), second = try await failedDictation(h)
        h.controller.transcribeOverride = nil
        var pasted: [String] = []
        h.controller.insertOverride = { text, _ in pasted.append(text); return .pasted }
        func waitForQueue(_ count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while await gate.queueLength < count {
                guard ContinuousClock.now < deadline else {
                    Issue.record("never \(count) waiting")
                    return
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let steps = await engine.gateTranscriptions()
        h.controller.retry(try #require(h.history.entry(id: first)), with: .parakeet)
        await steps.arrival(1)
        h.controller.retry(try #require(h.history.entry(id: second)), with: .parakeet)
        try await waitForQueue(1)
        h.controller.enqueue(H.recording(), engine: .parakeet, targetPID: nil)
        try await waitForQueue(2)

        steps.open()
        await steps.arrival(2)
        steps.open()
        try await waitUntil { pasted == ["hello from the fake"] }
        #expect(h.history.entry(id: first)?.status == .success)
        #expect(h.controller.homeWork[second] == .transcription(.parakeet), "still waiting for the model")
        steps.openForGood()
        try await waitUntil { h.controller.homeWork.isEmpty }
        #expect(h.history.entry(id: second)?.status == .success)
        #expect(pasted == ["hello from the fake"])
    }

    /// A model load only Home work was waiting for fails in the row, never in a notice.
    @Test func aModelThatWontLoadForHomeWorkSaysSoInTheRow() async throws {
        let engine = FakeEngine(.parakeet, installed: true)
        await engine.configure(loadError: FakeFailure(message: "corrupt weights"))
        let store = localStore(engine)
        await store.refreshFromDisk()
        #expect(store.state(of: .parakeet) == .installed)
        let h = harness(store: store)
        defer { removeFiles(h) }
        let failed = try await failedDictation(h)
        h.controller.transcribeOverride = nil
        let outside = Outside(h)
        h.controller.retry(try #require(h.history.entry(id: failed)), with: .parakeet)
        try await waitUntil { h.controller.homeWork.isEmpty }
        #expect(await engine.loadCount == 2, "loaded, and tried once more")
        #expect(h.history.entry(id: failed)?.errorMessage == "Couldn’t load Parakeet v3")
        #expect(h.toasts.notices.isEmpty)
        #expect(outside.cues.isEmpty && outside.failedDictations == 0)
    }

    /// Deleting a row takes its Home work along: the request stops, and nothing is left of it. Clear All clears
    /// the rows' reasons too.
    @Test func deletingARowCancelsItsHomeWork() async throws {
        let h = harness()
        defer { removeFiles(h) }
        let transcribed = try await transcript(h), tidied = try await transcript(h)
        var stopped = 0
        h.controller.transcribeOverride = { _, engine in
            do { try await Task.sleep(for: .seconds(5)) } catch { stopped += 1; throw error }
            return TranscriptResult(text: "late", engine: engine, processingTime: 1)
        }
        h.controller.cleanupOverride = { _, _ in throw AppError.openRouterServer("HTTP 500") }
        h.controller.makeVersion(.cleanup(of: .parakeet, by: .gpt6Luna), of: try #require(h.history.entry(id: tidied)))
        try await waitUntil { h.controller.homeFailures[tidied] != nil }
        h.controller.retry(try #require(h.history.entry(id: transcribed)), with: .geminiFlash)
        #expect(h.controller.homeWork[transcribed] != nil)

        h.history.delete(transcribed)
        #expect(h.controller.homeWork.isEmpty && h.controller.runningVersions.isEmpty)
        try await waitUntil { stopped == 1 }
        h.history.clearAll()
        #expect(h.controller.homeFailures.isEmpty)
        #expect(h.toasts.notices.isEmpty)
    }

    /// A transcript with no text (a legacy "No speech detected" row) has nothing to clean up.
    @Test func anEmptyTranscriptIsntCleanedUp() {
        let h = H.make(keyStatus: .valid(KeyInfo()))
        let entry = TranscriptEntry(text: "", engine: .parakeet, audioDuration: 4, voicedSeconds: 0)
        h.history.upsert(entry)
        h.controller.cleanupOverride = { _, source in
            Issue.record("no request for no text")
            return TranscriptResult(text: "x", engine: source, processingTime: 1)
        }
        h.controller.makeVersion(.cleanup(of: .parakeet, by: .gpt6Luna), of: entry)
        #expect(h.controller.homeWork.isEmpty && h.controller.homeFailures.isEmpty)
        let menu = VersionsMenu.make(for: entry, running: nil, readiness: { _ in .ready })
        #expect(!menu.actions.contains { $0.kind.isCleanup })
        #expect(menu.actions.contains { $0.kind == .transcription(.geminiFlash) })
    }

    /// While Home works, dictations are exactly as before: a failure's notice and shake, Esc canceling the
    /// dictation (with its cue and Undo), never the Home work.
    @Test func dictationsKeepTheirNoticesAndEscWhileHomeWorks() async throws {
        let h = harness()
        defer { removeFiles(h) }
        let id = try await transcript(h)
        var cues: [SoundEffect] = []
        h.controller.playCueOverride = { cues.append($0) }
        var failedDictations = 0
        h.controller.onDictationFailed = { failedDictations += 1 }
        var release = false
        h.controller.transcribeOverride = { recording, engine in
            guard recording.id == id else { throw AppError.timeout(engine) }
            while !release { try await Task.sleep(for: .milliseconds(5)) }
            return TranscriptResult(text: "gemini text", engine: engine, processingTime: 1)
        }
        h.controller.retry(try #require(h.history.entry(id: id)), with: .geminiFlash)

        let shakes = h.pill.shakeCount
        let r = H.recording()
        h.controller.enqueue(r, engine: .geminiFlash, targetPID: nil)
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(h.toasts.notices.contains { $0.dedupeKey == "error.timeout.geminiFlash" && $0.recordingID == r.id })
        #expect(h.pill.shakeCount == shakes + 1 && failedDictations == 1)

        h.controller.send(.handsFreeToggle)
        #expect(h.hotkeys.isBusy)
        h.controller.handle(.cancel)
        #expect(h.toasts.notices.contains { $0.title == "Dictation canceled" })
        #expect(cues.contains(.cancel))
        #expect(h.controller.homeWork[id] == .transcription(.geminiFlash), "Esc left the Home work alone")
        release = true
        try await waitUntil { h.controller.homeWork.isEmpty }
        #expect(h.history.entry(id: id)?.text == "gemini text")
    }
}
