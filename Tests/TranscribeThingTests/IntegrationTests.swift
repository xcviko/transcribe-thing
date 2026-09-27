import Foundation
import Testing
@testable import TranscribeThing

/// Cross-module behavior added while wiring the app together.
@MainActor
@Suite struct PendingModelSelectionTests {
    /// Gemini in use, Parakeet on this Mac not downloaded (or already on disk).
    private func makeStore(parakeetInstalled: Bool = false) -> (ModelStore, FakeEngine, AppSettings) {
        let settings = AppSettings.inMemory()
        settings.selectedEngine = .geminiFlash
        let parakeet = FakeEngine(.parakeet, installed: parakeetInstalled)
        let store = ModelStore(paths: .temporary(), settings: settings, engines: [.parakeet: parakeet],
                               gate: InferenceGate(), freeDiskBytes: { 50_000_000_000 })
        return (store, parakeet, settings)
    }

    @Test func pickingAMissingModelKeepsTheCurrentOneUntilTheDownloadLands() async throws {
        let (store, parakeet, settings) = makeStore()
        await store.refreshFromDisk()
        var selectedWhenFinished: EngineID?
        store.onDownloadFinished = { _ in selectedWhenFinished = settings.selectedEngine }
        store.selectWhenInstalled(.parakeet)
        #expect(store.pendingSelection == .parakeet)
        #expect(store.state(of: .parakeet).isDownloading)
        #expect(settings.selectedEngine == .geminiFlash, "dictation keeps using the working engine meanwhile")
        try await waitUntil { store.state(of: .parakeet) == .ready }
        #expect(settings.selectedEngine == .parakeet)
        #expect(selectedWhenFinished == .parakeet, "the ready toast already sees the new selection")
        #expect(store.pendingSelection == nil)
        #expect(await parakeet.isLoaded)
    }

    @Test func cancellingTheDownloadDropsThePendingSwitch() async throws {
        let (store, parakeet, settings) = makeStore()
        await parakeet.configure(downloadStepDelay: .milliseconds(200))
        await store.refreshFromDisk()
        store.selectWhenInstalled(.parakeet)
        try await Task.sleep(for: .milliseconds(30))
        store.cancelDownload(.parakeet)
        #expect(store.pendingSelection == nil)
        try await Task.sleep(for: .milliseconds(700))
        #expect(settings.selectedEngine == .geminiFlash)
    }

    @Test func aFailedDownloadDropsThePendingSwitch() async throws {
        let (store, parakeet, settings) = makeStore()
        await parakeet.configure(downloadError: URLError(.notConnectedToInternet))
        await store.refreshFromDisk()
        store.selectWhenInstalled(.parakeet)
        try await waitUntil { if case .failed = store.state(of: .parakeet) { true } else { false } }
        #expect(store.pendingSelection == nil)
        #expect(settings.selectedEngine == .geminiFlash)
    }

    @Test func choosingSomethingElseWhileDownloadingWins() async throws {
        let (store, parakeet, settings) = makeStore()
        await parakeet.configure(downloadStepDelay: .milliseconds(40))
        await store.refreshFromDisk()
        store.selectWhenInstalled(.parakeet)
        store.select(.geminiPro)
        #expect(store.pendingSelection == nil)
        try await waitUntil { store.state(of: .parakeet) == .installed }
        #expect(settings.selectedEngine == .geminiPro)
    }

    @Test func aModelOnDiskIsSelectedRightAway() async throws {
        let (store, _, settings) = makeStore(parakeetInstalled: true)
        await store.refreshFromDisk()
        store.selectWhenInstalled(.parakeet)
        #expect(settings.selectedEngine == .parakeet)
        #expect(store.pendingSelection == nil)
        try await waitUntil { store.state(of: .parakeet) == .ready }
    }

    @Test func cloudEnginesAreSelectedRightAway() {
        let (store, _, settings) = makeStore()
        store.selectWhenInstalled(.geminiPro)
        #expect(settings.selectedEngine == .geminiPro)
        #expect(store.pendingSelection == nil)
    }
}
