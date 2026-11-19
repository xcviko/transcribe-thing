import Foundation
import os

enum LocalEngineError: Error, Equatable, Sendable, LocalizedError {
    case notInstalled
    case notLoaded
    case incompleteDownload([String])
    /// There's nowhere to get it from yet: `file` isn't in the Downloads folder, and its release asset isn't published
    /// (`ModelStore` says so as `AppError.modelNotPublished`).
    case notPublished(file: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "The model isn’t downloaded."
        case .notLoaded: "The model isn’t loaded."
        case .incompleteDownload(let missing):
            "The download is incomplete (\(missing.count) file\(missing.count == 1 ? "" : "s") missing)."
        case .notPublished(let file): "The model isn’t published yet. Put \(file) in your Downloads folder."
        }
    }
}

/// The model on this Mac that downloads, loads and is deleted on its own: GigaAM v3, in its own folder. ModelStore keeps
/// its state; an `EngineID` stands for it (`init(engine:)`). Parakeet and GigaAM's other two versions are retired: what
/// they left on this Mac is a `RetiredLocalModel`.
enum LocalModel: Hashable, Sendable, Identifiable {
    case gigaam(GigaAMEngine.Variant)

    /// What the app runs on this Mac: GigaAM v3.
    static var all: [LocalModel] { GigaAMEngine.Variant.offered.map(LocalModel.gigaam) }

    /// What `engine` runs on this Mac: GigaAM v3 for GigaAM. nil for a cloud model, and for the retired Parakeet.
    init?(engine: EngineID) {
        guard engine == .gigaam else { return nil }
        self = .gigaam(.default)
    }

    /// The version's raw value: "gigaam-v3-ctc".
    var id: String { variant.rawValue }

    var engine: EngineID { .gigaam }

    var variant: GigaAMEngine.Variant {
        switch self {
        case .gigaam(let variant): variant
        }
    }

    /// "GigaAM v3".
    var displayName: String { variant.displayName }

    /// What its download takes: its zip.
    var approxDownloadBytes: Int64 { variant.downloadBytes }

    /// What it takes on this Mac once installed: its zip unpacked.
    var approxInstalledBytes: Int64 { variant.installedBytes }

    /// What installing it takes on disk at most: the zip and its unpacked folder are both there for a moment.
    var approxInstallPeakBytes: Int64 { variant.downloadBytes + variant.installedBytes }

    /// Where its download comes from, as a failure to reach it says: "Couldn’t reach GitHub."
    var downloadHost: String { "GitHub" }

    /// What a transcript's metadata records as the model that wrote it (`TranscriptMetadata.modelID`): the version's
    /// raw value ("gigaam-v3-ctc").
    var modelID: String { variant.rawValue }
}

/// A model this build no longer runs whose files may still be on this Mac: Parakeet v3 (in the folder FluidAudio
/// downloaded it to), GigaAM v3 e2e and GigaAM Multilingual. Models → On this Mac lists the ones still there, each
/// with what it takes on disk and Delete (`ModelStore.leftovers`); nothing deletes them by itself. Never the folder of
/// a model the app runs.
enum RetiredLocalModel: String, CaseIterable, Identifiable, Sendable {
    case parakeet
    case gigaamV3e2e
    case gigaamMultilingual

    var id: String { rawValue }

    /// The retired GigaAM version; nil for Parakeet.
    var variant: GigaAMEngine.Variant? {
        switch self {
        case .parakeet: nil
        case .gigaamV3e2e: .v3e2e
        case .gigaamMultilingual: .multilingual
        }
    }

    /// The engine that wrote with it: its symbol and color.
    var engine: EngineID { variant == nil ? .parakeet : .gigaam }

    /// "Parakeet v3", "GigaAM v3 e2e", "GigaAM Multilingual".
    var displayName: String { variant?.displayName ?? EngineID.parakeet.displayName }

    /// Its folders in the models folder: Parakeet's as FluidAudio named it ("parakeet-tdt-0.6b-v3"), a GigaAM version's
    /// and the one an unfinished download of it left beside it.
    func folders(in modelsRoot: URL) -> [URL] {
        guard let variant else {
            return [modelsRoot.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)]
        }
        return [modelsRoot.appendingPathComponent(variant.rawValue, isDirectory: true),
                modelsRoot.appendingPathComponent(variant.rawValue + ".partial", isDirectory: true)]
    }

    /// What its folders in `modelsRoot` take on disk; 0 when none is there.
    func bytesOnDisk(in modelsRoot: URL) -> Int64 {
        folders(in: modelsRoot).reduce(Int64(0)) { $0 + AppPaths.allocatedSize(of: $1) }
    }

    /// Some folder of it is there, empty or not.
    func isOnDisk(in modelsRoot: URL) -> Bool {
        folders(in: modelsRoot).contains { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// A downloadable on-device model. GigaAMEngine implements it; ModelStore only talks to this protocol, so tests
/// substitute fakes.
protocol LocalEngine: Actor {
    nonisolated var engineID: EngineID { get }
    /// Everything this engine writes to disk: measured for disk usage, removed by `deleteFiles()`.
    nonisolated var storageURLs: [URL] { get }
    /// Complete and verified on disk. Stat-only; safe from any thread.
    nonisolated func isInstalled() -> Bool
    /// Bytes the full download takes.
    func remoteDownloadBytes() async -> Int64
    /// Downloads or resumes. `progress` receives byte-weighted 0...1 values, throttled, from any thread.
    /// Cancel by cancelling the calling task; partial files stay on disk and resume next time.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws
    var isLoaded: Bool { get }
    /// Loads (and warms up) the model. The first load after install takes longer (Core ML specialization).
    func load() async throws
    func unload() async
    /// 16 kHz mono Float32 in [-1, 1]. Returns "" when the engine hears no speech.
    func transcribe(_ samples: [Float]) async throws -> String
    /// Unloads, then removes every file in `storageURLs`.
    func deleteFiles() async throws
}

extension LocalEngine {
    nonisolated func bytesOnDisk() -> Int64 {
        storageURLs.reduce(Int64(0)) { $0 + AppPaths.allocatedSize(of: $1) }
    }
}

/// Forwards download progress at most every `interval` seconds (libraries call back per network chunk,
/// thousands of times), never backwards, and always forwards completion.
final class ProgressThrottle: Sendable {
    private struct State { var lastValue = -1.0; var lastSent: TimeInterval = 0 }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let interval: TimeInterval
    private let send: @Sendable (Double) -> Void

    init(interval: TimeInterval = 0.15, send: @escaping @Sendable (Double) -> Void) {
        self.interval = interval
        self.send = send
    }

    func offer(_ raw: Double) {
        let value = min(max(raw, 0), 1)
        let now = ProcessInfo.processInfo.systemUptime
        let forward = state.withLock { s -> Bool in
            guard value > s.lastValue else { return false }
            guard value >= 1 || now - s.lastSent >= interval else { return false }
            s.lastValue = value
            s.lastSent = now
            return true
        }
        if forward { send(value) }
    }
}
