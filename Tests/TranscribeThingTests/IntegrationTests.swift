import Foundation
import Testing
@testable import TranscribeThing

/// Cross-module behavior added while wiring the app together.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ParakeetDownloadTests {
    /// Parakeet on this Mac not downloaded (or already on disk).
    private func makeStore(parakeetInstalled: Bool = false) -> (ModelStore, FakeEngine, AppSettings) {
        let settings = AppSettings.inMemory()
        let parakeet = FakeEngine(.parakeet, installed: parakeetInstalled)
        let store = ModelStore(paths: .temporary(), settings: settings, engines: [.parakeet: parakeet],
                               gate: InferenceGate(), freeDiskBytes: { 50_000_000_000 })
        return (store, parakeet, settings)
    }

    /// Switch model reaches Parakeet: once it lands it loads, so the next dictation doesn't wait.
    @Test func aDownloadThatLandsLoadsWhenTheLineupUsesIt() async throws {
        let (store, parakeet, settings) = makeStore()
        #expect(settings.usesLocalParakeet)
        await store.refreshFromDisk()
        var finished: EngineID?
        store.onDownloadFinished = { finished = $0 }
        store.download(.parakeet)
        #expect(store.state(of: .parakeet).isDownloading)
        await waitForObserved { store.state(of: .parakeet) == .ready }
        #expect(finished == .parakeet)
        #expect(await parakeet.isLoaded)
    }

    /// Gemini is the main model and Parakeet is switched off: it downloads, and waits on disk.
    @Test func aDownloadNothingUsesStaysOnDisk() async throws {
        let (store, _, settings) = makeStore()
        settings.lineup.main = .gemini
        settings.lineup.setSwitchable(.parakeet, false)
        #expect(!settings.usesLocalParakeet)
        await store.refreshFromDisk()
        store.download(.parakeet)
        await waitForObserved { store.state(of: .parakeet) == .installed }
        #expect(store.state(of: .parakeet) == .installed)
    }

    @Test func aFailedDownloadSaysSo() async throws {
        let (store, parakeet, _) = makeStore()
        await parakeet.configure(downloadError: URLError(.notConnectedToInternet))
        await store.refreshFromDisk()
        store.download(.parakeet)
        await waitForObserved { if case .failed = store.state(of: .parakeet) { true } else { false } }
        #expect(store.lastErrors[.parakeet] != nil)
    }

    @Test func cancellingTheDownloadLeavesItNotInstalled() async throws {
        let (store, parakeet, _) = makeStore()
        let gate = await parakeet.gateDownloads()
        await store.refreshFromDisk()
        store.download(.parakeet)
        await gate.arrival(1)
        store.cancelDownload(.parakeet)
        await store.waitForDownloadToSettle(.parakeet)
        #expect(gate.cancellations == 1)
        #expect(store.state(of: .parakeet) == .notInstalled)
    }
}
