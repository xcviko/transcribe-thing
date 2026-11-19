import Foundation
import Testing
@testable import TranscribeThing

/// Cross-module behavior added while wiring the app together.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct LocalModelDownloadTests {
    /// GigaAM v3 on this Mac not downloaded (or already on disk).
    private func makeStore(installed: Bool = false) -> (ModelStore, FakeEngine, AppSettings) {
        let settings = AppSettings.inMemory()
        let gigaam = FakeEngine(.gigaam, installed: installed)
        let store = ModelStore(paths: .temporary(), settings: settings, engines: [.gigaam(.v3): gigaam],
                               gate: InferenceGate(), freeDiskBytes: { 50_000_000_000 })
        return (store, gigaam, settings)
    }

    /// Switch model reaches GigaAM: once it lands it loads, so the next dictation doesn't wait.
    @Test func aDownloadThatLandsLoadsWhenTheLineupUsesIt() async throws {
        let (store, gigaam, settings) = makeStore()
        #expect(settings.usesLocalModel(.gigaam))
        await store.refreshFromDisk()
        var finished: LocalModel?
        store.onDownloadFinished = { finished = $0 }
        store.download(.gigaam)
        #expect(store.state(of: .gigaam).isDownloading)
        await waitForObserved { store.state(of: .gigaam) == .ready }
        #expect(finished == .gigaam(.v3))
        #expect(await gigaam.isLoaded)
    }

    /// Gemini is the main model and GigaAM is switched off: it downloads, and waits on disk.
    @Test func aDownloadNothingUsesStaysOnDisk() async throws {
        let (store, _, settings) = makeStore()
        settings.lineup.main = .gemini
        settings.lineup.setSwitchable(.gigaam, false)
        #expect(!settings.usesLocalModel(.gigaam))
        await store.refreshFromDisk()
        store.download(.gigaam)
        await waitForObserved { store.state(of: .gigaam) == .installed }
        #expect(store.state(of: .gigaam) == .installed)
    }

    @Test func aFailedDownloadSaysSo() async throws {
        let (store, gigaam, _) = makeStore()
        await gigaam.configure(downloadError: URLError(.notConnectedToInternet))
        await store.refreshFromDisk()
        store.download(.gigaam)
        await waitForObserved { if case .failed = store.state(of: .gigaam) { true } else { false } }
        #expect(store.lastErrors[.gigaam] != nil)
    }

    @Test func cancellingTheDownloadLeavesItNotInstalled() async throws {
        let (store, gigaam, _) = makeStore()
        let gate = await gigaam.gateDownloads()
        await store.refreshFromDisk()
        store.download(.gigaam)
        await gate.arrival(1)
        store.cancelDownload(.gigaam)
        await store.waitForDownloadToSettle(.gigaam)
        #expect(gate.cancellations == 1)
        #expect(store.state(of: .gigaam) == .notInstalled)
    }
}
