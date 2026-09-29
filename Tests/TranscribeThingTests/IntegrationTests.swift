import Foundation
import Testing
@testable import TranscribeThing

/// Cross-module behavior added while wiring the app together.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct PendingModelSelectionTests {
    /// Cloud Parakeet in use, Parakeet on this Mac not downloaded (or already on disk).
    private func makeStore(parakeetInstalled: Bool = false) -> (ModelStore, FakeEngine, AppSettings) {
        let settings = AppSettings.inMemory()
        settings.parakeetEngine = .parakeetCloud
        let parakeet = FakeEngine(.parakeet, installed: parakeetInstalled)
        let store = ModelStore(paths: .temporary(), settings: settings, engines: [.parakeet: parakeet],
                               gate: InferenceGate(), freeDiskBytes: { 50_000_000_000 })
        return (store, parakeet, settings)
    }

    @Test func pickingAMissingModelKeepsTheCurrentOneUntilTheDownloadLands() async throws {
        let (store, parakeet, settings) = makeStore()
        await store.refreshFromDisk()
        var selectedWhenFinished: EngineID?
        store.onDownloadFinished = { _ in selectedWhenFinished = settings.parakeetEngine }
        store.selectWhenInstalled(.parakeet)
        #expect(store.pendingSelection == .parakeet)
        #expect(store.state(of: .parakeet).isDownloading)
        #expect(settings.parakeetEngine == .parakeetCloud, "dictation keeps using the working engine meanwhile")
        await waitForObserved { store.state(of: .parakeet) == .ready }
        #expect(settings.parakeetEngine == .parakeet)
        #expect(selectedWhenFinished == .parakeet, "the ready toast already sees the new selection")
        #expect(store.pendingSelection == nil)
        #expect(await parakeet.isLoaded)
    }

    @Test func cancellingTheDownloadDropsThePendingSwitch() async throws {
        let (store, parakeet, settings) = makeStore()
        let gate = await parakeet.gateDownloads()
        await store.refreshFromDisk()
        store.selectWhenInstalled(.parakeet)
        await gate.arrival(1)
        // The engine's download is under way, held before its first step.
        store.cancelDownload(.parakeet)
        #expect(store.pendingSelection == nil)
        await store.waitForDownloadToSettle(.parakeet)
        #expect(gate.cancellations == 1)
        #expect(store.state(of: .parakeet) == .notInstalled)
        #expect(settings.parakeetEngine == .parakeetCloud)
    }

    @Test func aFailedDownloadDropsThePendingSwitch() async throws {
        let (store, parakeet, settings) = makeStore()
        await parakeet.configure(downloadError: URLError(.notConnectedToInternet))
        await store.refreshFromDisk()
        store.selectWhenInstalled(.parakeet)
        await waitForObserved { if case .failed = store.state(of: .parakeet) { true } else { false } }
        #expect(store.pendingSelection == nil)
        #expect(settings.parakeetEngine == .parakeetCloud)
    }

    @Test func choosingSomethingElseWhileDownloadingWins() async throws {
        let (store, parakeet, settings) = makeStore()
        let gate = await parakeet.gateDownloads()
        await store.refreshFromDisk()
        store.selectWhenInstalled(.parakeet)
        store.select(.parakeetCloud)
        gate.openForGood()
        #expect(store.pendingSelection == nil)
        await waitForObserved { store.state(of: .parakeet) == .installed }
        #expect(settings.parakeetEngine == .parakeetCloud)
    }

    @Test func aModelOnDiskIsSelectedRightAway() async throws {
        let (store, _, settings) = makeStore(parakeetInstalled: true)
        await store.refreshFromDisk()
        store.selectWhenInstalled(.parakeet)
        #expect(settings.parakeetEngine == .parakeet)
        #expect(store.pendingSelection == nil)
        await waitForObserved { store.state(of: .parakeet) == .ready }
    }

    @Test func cloudEnginesAreSelectedRightAway() {
        let (store, _, settings) = makeStore()
        settings.parakeetEngine = .parakeet
        store.selectWhenInstalled(.parakeetCloud)
        #expect(settings.parakeetEngine == .parakeetCloud)
        #expect(store.pendingSelection == nil)
        store.selectWhenInstalled(.geminiFlash)
        #expect(settings.parakeetEngine == .parakeetCloud, "Gemini isn’t a place Parakeet runs")
    }
}
