import Foundation
import Observation

// STUB (FOUNDATION): ENGINES replaces this with the real download/prepare pipeline.
enum LocalModelState: Equatable, Sendable {
    case notInstalled
    case downloading(DownloadProgress)
    /// On disk, not loaded.
    case installed
    /// Loading / CoreML specialization ("Optimizing for your Mac").
    case preparing(since: Date)
    case ready
    /// Last download or load error message.
    case failed(String)
}

@MainActor @Observable
final class ModelStore {
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let settings: AppSettings

    private(set) var states: [EngineID: LocalModelState] = [.parakeet: .notInstalled, .whisper: .notInstalled]
    private(set) var diskUsageBytes: Int64 = 0
    @ObservationIgnored var onDownloadFinished: ((EngineID) -> Void)?

    init(paths: AppPaths, settings: AppSettings) {
        self.paths = paths
        self.settings = settings
    }

    static func preview(states: [EngineID: LocalModelState]) -> ModelStore {
        let store = ModelStore(paths: .temporary(), settings: .inMemory())
        for (id, state) in states where id.isLocal { store.states[id] = state }
        store.diskUsageBytes = store.states.reduce(Int64(0)) { total, entry in
            switch entry.value {
            case .ready, .installed, .preparing: total + (entry.key.approxDownloadBytes ?? 0)
            default: total
            }
        }
        return store
    }

    func state(of id: EngineID) -> LocalModelState {
        states[id] ?? .notInstalled
    }

    /// Scans the disk, then prepares the selected engine if it is local and installed.
    func start() {}

    func download(_ id: EngineID) {}

    func cancelDownload(_ id: EngineID) {}

    func delete(_ id: EngineID) async {}

    func select(_ id: EngineID) {
        settings.selectedEngine = id
    }

    func prepare(_ id: EngineID) {}

    /// Throws `MurmurError`.
    func transcribeLocal(_ id: EngineID, samples: [Float]) async throws -> String {
        throw MurmurError.modelNotDownloaded(id)
    }
}
