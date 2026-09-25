import Foundation
import Testing
@testable import MurmurApp

/// Cross-module behavior added while wiring the app together.
@MainActor
@Suite struct PendingModelSelectionTests {
    private func makeStore(whisperInstalled: Bool = false) -> (ModelStore, FakeEngine, AppSettings) {
        let settings = AppSettings.inMemory()
        settings.selectedEngine = .parakeet
        let parakeet = FakeEngine(.parakeet, installed: true)
        let whisper = FakeEngine(.whisper, installed: whisperInstalled)
        let store = ModelStore(paths: .temporary(), settings: settings,
                               engines: [.parakeet: parakeet, .whisper: whisper],
                               gate: InferenceGate(), freeDiskBytes: { 50_000_000_000 })
        return (store, whisper, settings)
    }

    @Test func pickingAMissingModelKeepsTheCurrentOneUntilTheDownloadLands() async throws {
        let (store, whisper, settings) = makeStore()
        await store.refreshFromDisk()
        var selectedWhenFinished: EngineID?
        store.onDownloadFinished = { _ in selectedWhenFinished = settings.selectedEngine }
        store.selectWhenInstalled(.whisper)
        #expect(store.pendingSelection == .whisper)
        #expect(store.state(of: .whisper).isDownloading)
        #expect(settings.selectedEngine == .parakeet, "dictation keeps using the ready model meanwhile")
        try await waitUntil { store.state(of: .whisper) == .ready }
        #expect(settings.selectedEngine == .whisper)
        #expect(selectedWhenFinished == .whisper, "the ready toast already sees the new selection")
        #expect(store.pendingSelection == nil)
        #expect(await whisper.isLoaded)
    }

    @Test func cancellingTheDownloadDropsThePendingSwitch() async throws {
        let (store, whisper, settings) = makeStore()
        await whisper.configure(downloadStepDelay: .milliseconds(200))
        await store.refreshFromDisk()
        store.selectWhenInstalled(.whisper)
        try await Task.sleep(for: .milliseconds(30))
        store.cancelDownload(.whisper)
        #expect(store.pendingSelection == nil)
        try await Task.sleep(for: .milliseconds(700))
        #expect(settings.selectedEngine == .parakeet)
    }

    @Test func aFailedDownloadDropsThePendingSwitch() async throws {
        let (store, whisper, settings) = makeStore()
        await whisper.configure(downloadError: URLError(.notConnectedToInternet))
        await store.refreshFromDisk()
        store.selectWhenInstalled(.whisper)
        try await waitUntil { if case .failed = store.state(of: .whisper) { true } else { false } }
        #expect(store.pendingSelection == nil)
        #expect(settings.selectedEngine == .parakeet)
    }

    @Test func choosingSomethingElseWhileDownloadingWins() async throws {
        let (store, whisper, settings) = makeStore()
        await whisper.configure(downloadStepDelay: .milliseconds(40))
        await store.refreshFromDisk()
        store.selectWhenInstalled(.whisper)
        store.select(.geminiFlash)
        #expect(store.pendingSelection == nil)
        try await waitUntil { store.state(of: .whisper) == .installed }
        #expect(settings.selectedEngine == .geminiFlash)
    }

    @Test func aModelOnDiskIsSelectedRightAway() async throws {
        let (store, _, settings) = makeStore(whisperInstalled: true)
        await store.refreshFromDisk()
        store.selectWhenInstalled(.whisper)
        #expect(settings.selectedEngine == .whisper)
        #expect(store.pendingSelection == nil)
        try await waitUntil { store.state(of: .whisper) == .ready }
    }

    @Test func cloudEnginesAreSelectedRightAway() {
        let (store, _, settings) = makeStore()
        store.selectWhenInstalled(.geminiPro)
        #expect(settings.selectedEngine == .geminiPro)
        #expect(store.pendingSelection == nil)
    }
}

@MainActor
@Suite(.serialized) struct QuietDeliveryTests {
    @Test func keyPracticeDictationsGoToHistoryWithoutPasting() async throws {
        let h = DictationControllerTests.make()
        h.controller.deliversQuietly = { true }
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "practice", engine: engine, processingTime: 0.1) }
        h.controller.insertOverride = { _, _ in Issue.record("nothing should be pasted"); return .pasted }
        var now: TimeInterval = 50
        h.controller.clock = { now }
        h.controller.handle(.pttDown)
        h.controller.send(.timer(.arming))
        now = 52
        h.controller.handle(.pttUp)
        try await waitUntil { h.controller.machine.activeJobs == 0 }
        #expect(h.history.entries.first?.text == "practice")
        #expect(h.toasts.notices.isEmpty, "no transcript card, no notice")
        #expect(h.pill.visiblePhase == .success)
    }

    @Test func normalDeliveryStillPastes() async throws {
        let h = DictationControllerTests.make()
        h.controller.deliversQuietly = { false }
        var pasted: [String] = []
        h.controller.transcribeOverride = { _, engine in TranscriptResult(text: "hello", engine: engine, processingTime: 0.1) }
        h.controller.insertOverride = { text, _ in pasted.append(text); return .pasted }
        h.controller.send(.handsFreeToggle)
        h.controller.send(.pillStop)
        try await waitUntil { pasted == ["hello"] }
    }
}
