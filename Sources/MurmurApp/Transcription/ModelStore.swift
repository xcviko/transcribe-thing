import Foundation
import Observation

enum LocalModelState: Equatable, Sendable {
    case notInstalled
    case downloading(DownloadProgress)
    /// On disk, not loaded.
    case installed
    /// Loading / Core ML specialization ("Optimizing for your Mac").
    case preparing(since: Date)
    case ready
    /// Last download or load error message.
    case failed(String)
}

extension LocalModelState {
    var downloadProgress: DownloadProgress? {
        if case .downloading(let progress) = self { progress } else { nil }
    }

    var isDownloading: Bool { downloadProgress != nil }

    var isPreparing: Bool {
        if case .preparing = self { true } else { false }
    }

    var isReady: Bool { self == .ready }
}

/// Owns the two local models: install state, downloads, loading and local inference.
/// State is main-actor observable; file scans, downloads, loads and inference run off the main thread.
/// Only one local model is loaded at a time, and every load and inference goes through `InferenceGate`.
@MainActor @Observable
final class ModelStore {
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let engines: [EngineID: any LocalEngine]
    @ObservationIgnored private let gate: InferenceGate
    @ObservationIgnored private let freeDiskBytes: @Sendable () -> Int64
    @ObservationIgnored private var isPreview = false
    @ObservationIgnored private var hasStarted = false

    private(set) var states: [EngineID: LocalModelState] = [.parakeet: .notInstalled, .whisper: .notInstalled]
    private(set) var diskUsageBytes: Int64 = 0
    /// The most recent download or load failure per engine; cleared when that engine recovers.
    private(set) var lastErrors: [EngineID: MurmurError] = [:]
    /// Wall time of the last successful load per engine (Core ML specialization makes the first one long).
    private(set) var lastLoadDurations: [EngineID: TimeInterval] = [:]
    /// A model picked before it finished downloading. It becomes the selected engine once it lands, even if
    /// the window that asked for it has closed meanwhile.
    private(set) var pendingSelection: EngineID?

    @ObservationIgnored var onDownloadFinished: ((EngineID) -> Void)?
    /// A download or load failed (never called for a cancellation).
    @ObservationIgnored var onFailure: ((EngineID, MurmurError) -> Void)?

    @ObservationIgnored private var downloadTasks: [EngineID: Task<Void, Never>] = [:]
    @ObservationIgnored private var downloadTokens: [EngineID: UUID] = [:]
    @ObservationIgnored private var prepareTasks: [EngineID: Task<Void, Never>] = [:]
    /// Loads run one after another so their completions land in order (the last requested model wins).
    @ObservationIgnored private var loadChain: Task<Void, Never>?

    static let diskHeadroom = 1.25

    convenience init(paths: AppPaths, settings: AppSettings) {
        self.init(paths: paths, settings: settings, engines: Self.makeEngines(paths: paths), gate: .shared,
                  freeDiskBytes: { paths.freeDiskBytes() })
    }

    init(paths: AppPaths, settings: AppSettings, engines: [EngineID: any LocalEngine], gate: InferenceGate,
         freeDiskBytes: @escaping @Sendable () -> Int64) {
        self.paths = paths
        self.settings = settings
        self.engines = engines
        self.gate = gate
        self.freeDiskBytes = freeDiskBytes
    }

    nonisolated static func makeEngines(paths: AppPaths) -> [EngineID: any LocalEngine] {
        [.parakeet: ParakeetEngine(modelsRoot: paths.models), .whisper: WhisperEngine(baseDir: paths.whisperBase)]
    }

    static func preview(states: [EngineID: LocalModelState]) -> ModelStore {
        let store = ModelStore(paths: .temporary(), settings: .inMemory())
        store.isPreview = true
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

    // MARK: Start

    /// Scans the disk, then prepares the selected engine if it is local and installed.
    func start() {
        guard !isPreview, !hasStarted else { return }
        hasStarted = true
        ParakeetEngine.quietLibraryLogging()
        Task { [weak self] in
            guard let self else { return }
            await self.refreshFromDisk()
            let selected = self.settings.selectedEngine
            if selected.isLocal, self.state(of: selected) == .installed {
                self.prepare(selected)
            }
        }
    }

    /// Re-reads install state and disk usage. Engines that are busy (downloading, preparing) keep their state.
    func refreshFromDisk() async {
        let engines = self.engines
        let scan = await Task.detached(priority: .utility) { () -> ([EngineID: Bool], Int64) in
            var installed: [EngineID: Bool] = [:]
            var usage: Int64 = 0
            for (id, engine) in engines {
                installed[id] = engine.isInstalled()
                usage += engine.bytesOnDisk()
            }
            return (installed, usage)
        }.value
        for (id, isInstalled) in scan.0 {
            switch state(of: id) {
            case .downloading, .preparing, .failed:
                continue
            case .ready:
                if !isInstalled { states[id] = .notInstalled }
            case .notInstalled, .installed:
                states[id] = isInstalled ? .installed : .notInstalled
            }
        }
        diskUsageBytes = scan.1
    }

    private func refreshDiskUsage() async {
        let engines = Array(self.engines.values)
        diskUsageBytes = await Task.detached(priority: .utility) {
            engines.reduce(Int64(0)) { $0 + $1.bytesOnDisk() }
        }.value
    }

    // MARK: Download

    /// Checks free space, downloads (resuming any partial files), then prepares the model if it is selected.
    func download(_ id: EngineID) {
        guard !isPreview, id.isLocal, let engine = engines[id] else { return }
        switch state(of: id) {
        case .downloading, .preparing, .ready, .installed:
            return
        case .failed where engine.isInstalled():
            // The files are complete, so the failure was a load: "Retry" means load again.
            prepare(id)
            return
        case .notInstalled, .failed:
            break
        }
        let previous = downloadTasks[id]
        let token = UUID()
        downloadTokens[id] = token
        lastErrors[id] = nil
        states[id] = .downloading(DownloadProgress(fraction: 0, totalBytes: id.approxDownloadBytes ?? 0))
        downloadTasks[id] = Task { [weak self] in
            // A just-cancelled download must fully unwind before the next one touches the same files.
            await previous?.value
            await self?.runDownload(id, engine: engine, token: token)
        }
    }

    func cancelDownload(_ id: EngineID) {
        if pendingSelection == id { pendingSelection = nil }
        guard let task = downloadTasks[id] else { return }
        task.cancel()
        if state(of: id).isDownloading { states[id] = .notInstalled }
    }

    private func runDownload(_ id: EngineID, engine: any LocalEngine, token: UUID) async {
        defer {
            if downloadTokens[id] == token {
                downloadTasks[id] = nil
                downloadTokens[id] = nil
            }
        }
        /// False once this download was cancelled or superseded: its outcome must not touch the state any more.
        func isCurrent() -> Bool { !Task.isCancelled && downloadTokens[id] == token }
        guard isCurrent() else { return settleCancelledDownload(id, engine: engine, token: token) }

        let expected = id.approxDownloadBytes ?? 0
        let alreadyOnDisk = await Task.detached(priority: .utility) { engine.bytesOnDisk() }.value
        let needed = Int64((Double(max(0, expected - alreadyOnDisk)) * Self.diskHeadroom).rounded(.up))
        let available = freeDiskBytes()
        guard isCurrent() else { return settleCancelledDownload(id, engine: engine, token: token) }
        if available < needed {
            let error = MurmurError.notEnoughDisk(needed: needed, available: available)
            fail(id, error, message: "Not enough space. \(id.shortName) needs \(Fmt.bytes(needed)); \(Fmt.bytes(available)) is free.")
            return
        }

        let total = await engine.remoteDownloadBytes()
        var estimator = DownloadRateEstimator(totalBytes: total > 0 ? total : expected)
        let (stream, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        async let outcome = Self.performDownload(engine, continuation)
        for await fraction in stream where isCurrent() {
            states[id] = .downloading(estimator.progress(fraction: fraction, at: ProcessInfo.processInfo.systemUptime))
        }
        let result = await outcome

        switch result {
        case .success where downloadTokens[id] == token:
            states[id] = .installed
            lastErrors[id] = nil
            await refreshDiskUsage()
            Log.engine.info("Downloaded \(id.rawValue, privacy: .public)")
            if pendingSelection == id {
                pendingSelection = nil
                settings.selectedEngine = id
            }
            onDownloadFinished?(id)
            if settings.selectedEngine == id { prepare(id) }
        case .success:
            await refreshDiskUsage()
        case .failure(let error):
            if !isCurrent() || error is CancellationError {
                settleCancelledDownload(id, engine: engine, token: token)
            } else {
                let detail = Self.describeDownloadFailure(error)
                Log.engine.error("Download of \(id.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                fail(id, .downloadFailed(id, detail), message: "Download didn’t finish. \(detail)")
            }
            await refreshDiskUsage()
        }
    }

    private nonisolated static func performDownload(_ engine: any LocalEngine,
                                                    _ continuation: AsyncStream<Double>.Continuation) async -> Result<Void, Error> {
        defer { continuation.finish() }
        do {
            try await engine.download(progress: { continuation.yield($0) })
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func settleCancelledDownload(_ id: EngineID, engine: any LocalEngine, token: UUID) {
        // A newer download of the same model owns the state now.
        guard downloadTokens[id] == token else { return }
        if pendingSelection == id { pendingSelection = nil }
        guard state(of: id).isDownloading || state(of: id) == .notInstalled else { return }
        states[id] = engine.isInstalled() ? .installed : .notInstalled
    }

    private func fail(_ id: EngineID, _ error: MurmurError, message: String) {
        if pendingSelection == id { pendingSelection = nil }
        states[id] = .failed(message)
        lastErrors[id] = error
        onFailure?(id, error)
    }

    // MARK: Delete

    func delete(_ id: EngineID) async {
        guard !isPreview, let engine = engines[id] else { return }
        if let task = downloadTasks[id] {
            task.cancel()
            await task.value
        }
        if let task = prepareTasks[id] { await task.value }
        do {
            try await gate.run { try await engine.deleteFiles() }
            states[id] = .notInstalled
            lastErrors[id] = nil
        } catch {
            Log.engine.error("Delete of \(id.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            states[id] = .failed("Couldn’t remove all model files. \(Self.oneLine(error))")
        }
        await refreshDiskUsage()
    }

    // MARK: Select and prepare

    /// Sets the selected engine; a local one starts loading (which unloads the other local model).
    func select(_ id: EngineID) {
        pendingSelection = nil
        settings.selectedEngine = id
        guard id.isLocal else { return }
        switch state(of: id) {
        case .installed, .failed: prepare(id)
        case .notInstalled, .downloading, .preparing, .ready: break
        }
    }

    /// Selects `id` now if it can run, otherwise downloads it (when needed) and selects it once it is installed.
    /// The current engine stays in use meanwhile.
    func selectWhenInstalled(_ id: EngineID) {
        guard id.isLocal else { return select(id) }
        switch state(of: id) {
        case .installed, .ready, .preparing:
            select(id)
        case .downloading:
            pendingSelection = id
        case .notInstalled, .failed:
            pendingSelection = id
            download(id)
            // The download may have been refused synchronously (preview, or a load-only retry).
            if !state(of: id).isDownloading, pendingSelection == id {
                if state(of: id).isPreparing { select(id) } else if !isPreview { pendingSelection = nil }
            }
        }
    }

    /// Loads the model in the background: `.preparing` → `.ready` (or `.failed`).
    func prepare(_ id: EngineID) {
        guard !isPreview, id.isLocal, let engine = engines[id] else { return }
        switch state(of: id) {
        case .ready, .preparing, .downloading: return
        case .notInstalled, .installed, .failed: break
        }
        guard engine.isInstalled() else {
            if state(of: id) == .installed { states[id] = .notInstalled }
            return
        }
        states[id] = .preparing(since: Date())
        let others = engines.filter { $0.key != id }
        let gate = self.gate
        let previous = loadChain
        let task = Task { [weak self] in
            await previous?.value
            let started = ProcessInfo.processInfo.systemUptime
            let result: Result<Void, Error>
            do {
                try await gate.run {
                    for other in others.values { await other.unload() }
                    try await engine.load()
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }
            self?.finishPrepare(id, unloaded: Array(others.keys), result: result,
                                duration: ProcessInfo.processInfo.systemUptime - started)
        }
        loadChain = task
        prepareTasks[id] = task
    }

    private func finishPrepare(_ id: EngineID, unloaded: [EngineID], result: Result<Void, Error>, duration: TimeInterval) {
        prepareTasks[id] = nil
        for other in unloaded where state(of: other) == .ready {
            states[other] = .installed
        }
        switch result {
        case .success:
            states[id] = .ready
            lastErrors[id] = nil
            lastLoadDurations[id] = duration
            Log.engine.info("Loaded \(id.rawValue, privacy: .public) in \(duration, format: .fixed(precision: 2), privacy: .public) s")
        case .failure(let error):
            Log.engine.error("Load of \(id.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            let detail = Self.oneLine(error)
            // Model libraries skip files that already exist, so Retry can't repair a damaged install.
            fail(id, .modelLoadFailed(id, detail),
                 message: "Couldn’t load the model. If Retry doesn’t help, delete it and download it again.")
        }
    }

    // MARK: Transcribe

    /// Waits while the model downloads or loads, then transcribes. Throws `MurmurError`, or `CancellationError`
    /// when the calling task is cancelled.
    func transcribeLocal(_ id: EngineID, samples: [Float]) async throws -> String {
        guard id.isLocal, let engine = engines[id] else {
            throw MurmurError.engineFailed(id, "\(id.displayName) doesn’t run on this Mac.")
        }
        let options = LocalTranscriptionOptions(language: id == .whisper ? settings.whisperLanguage : nil)
        let gate = self.gate
        var attempts = 0
        while true {
            attempts += 1
            try await waitUntilReady(id, engine: engine)
            do {
                return try await gate.run { try await engine.transcribe(samples, options: options) }
            } catch LocalEngineError.notLoaded where attempts < 3 {
                // Another engine's load unloaded this one after it reported ready: load it again.
                if state(of: id) == .ready { states[id] = .installed }
            } catch let error as MurmurError {
                throw error
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                Log.engine.error("\(id.rawValue, privacy: .public) inference failed: \(String(describing: error), privacy: .public)")
                throw MurmurError.engineFailed(id, Self.oneLine(error))
            }
        }
    }

    private func waitUntilReady(_ id: EngineID, engine: any LocalEngine) async throws {
        var prepareAttempts = 0
        while true {
            try Task.checkCancellation()
            switch state(of: id) {
            case .ready:
                return
            case .preparing, .downloading:
                try await Task.sleep(for: .milliseconds(100))
            case .installed:
                guard prepareAttempts < 2 else {
                    throw MurmurError.modelLoadFailed(id, "The model was unloaded while loading.")
                }
                prepareAttempts += 1
                prepare(id)
            case .failed(let message):
                let installed = engine.isInstalled()
                if !installed {
                    switch lastErrors[id] {
                    case .downloadFailed(let engine, let detail)?: throw MurmurError.downloadFailed(engine, detail)
                    case .notEnoughDisk(let needed, let available)?:
                        throw MurmurError.notEnoughDisk(needed: needed, available: available)
                    default: throw MurmurError.modelNotDownloaded(id)
                    }
                }
                guard prepareAttempts == 0 else { throw lastErrors[id] ?? MurmurError.modelLoadFailed(id, message) }
                prepareAttempts += 1
                prepare(id)
            case .notInstalled:
                throw MurmurError.modelNotDownloaded(id)
            }
        }
    }

    // MARK: Messages

    static func describeDownloadFailure(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "No internet connection."
            case .timedOut:
                return "The connection timed out."
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
                return "Couldn’t reach Hugging Face."
            default:
                break
            }
        }
        let ns = error as NSError
        if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
            || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) {
            return "Your disk is full."
        }
        return oneLine(error)
    }

    static func oneLine(_ error: Error, limit: Int = 160) -> String {
        let text = ((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            .split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}
