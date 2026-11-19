import Foundation
import Observation

enum LocalModelState: Equatable, Sendable {
    case notInstalled
    case downloading(DownloadProgress)
    /// On disk, not loaded.
    case installed
    /// Loading / Core ML specialization ("Loading model").
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

/// Owns the model on this Mac, GigaAM v3 (`LocalModel`): install state, download, loading and local inference. An
/// `EngineID` stands for it (`LocalModel.init(engine:)`): `state(of: .gigaam)` is GigaAM v3's. It also keeps what the
/// retired models left on this Mac (`leftovers`), to delete when the user says so.
/// State is main-actor observable; file scans, downloads, loads and inference run off the main thread,
/// and every load and inference goes through `InferenceGate`.
@MainActor @Observable
final class ModelStore {
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let engines: [LocalModel: any LocalEngine]
    @ObservationIgnored private let gate: InferenceGate
    @ObservationIgnored private let freeDiskBytes: @Sendable () -> Int64
    @ObservationIgnored private var isPreview = false
    @ObservationIgnored private var hasStarted = false

    /// Each model's state; one missing is not installed.
    private(set) var modelStates: [LocalModel: LocalModelState] = [:]
    private(set) var diskUsageBytes: Int64 = 0
    /// The first disk scan has landed. Until then every model reads as not installed, which only means
    /// "not known yet".
    private(set) var hasScannedDisk = false
    /// The most recent download or load failure per model; cleared when that model recovers.
    private(set) var modelErrors: [LocalModel: AppError] = [:]
    /// Wall time of the last successful load per model.
    private(set) var lastLoadDurations: [LocalModel: TimeInterval] = [:]
    /// What each retired model still has on this Mac, in bytes: only those with a folder there (`RetiredLocalModel`).
    /// Nothing deletes them but `deleteLeftover(_:)`.
    private(set) var leftovers: [RetiredLocalModel: Int64] = [:]
    /// The leftovers being deleted right now.
    private(set) var deletingLeftovers: Set<RetiredLocalModel> = []

    @ObservationIgnored var onDownloadFinished: ((LocalModel) -> Void)?
    /// A download or load failed (never called for a cancellation).
    @ObservationIgnored var onFailure: ((EngineID, AppError) -> Void)?

    @ObservationIgnored private var downloadTasks: [LocalModel: Task<Void, Never>] = [:]
    @ObservationIgnored private var downloadTokens: [LocalModel: UUID] = [:]
    @ObservationIgnored private var prepareTasks: [LocalModel: Task<Void, Never>] = [:]

    nonisolated static let diskHeadroom = 1.25

    convenience init(paths: AppPaths, settings: AppSettings) {
        self.init(paths: paths, settings: settings, engines: Self.makeEngines(paths: paths), gate: .shared,
                  freeDiskBytes: { paths.freeDiskBytes() })
    }

    init(paths: AppPaths, settings: AppSettings, engines: [LocalModel: any LocalEngine], gate: InferenceGate,
         freeDiskBytes: @escaping @Sendable () -> Int64) {
        self.paths = paths
        self.settings = settings
        self.engines = engines
        self.gate = gate
        self.freeDiskBytes = freeDiskBytes
    }

    nonisolated static func makeEngines(paths: AppPaths) -> [LocalModel: any LocalEngine] {
        var engines: [LocalModel: any LocalEngine] = [:]
        for model in LocalModel.all {
            engines[model] = GigaAMEngine(variant: model.variant, modelsRoot: paths.models)
        }
        return engines
    }

    /// `states` and `lastErrors` are each engine's model's (GigaAM v3's); `leftovers`, what retired models left on
    /// this Mac. `settings`: the ones the views read.
    static func preview(states: [EngineID: LocalModelState], lastErrors: [EngineID: AppError] = [:],
                        leftovers: [RetiredLocalModel: Int64] = [:], settings: AppSettings? = nil) -> ModelStore {
        let store = ModelStore(paths: .temporary(), settings: settings ?? .inMemory())
        store.isPreview = true
        store.hasScannedDisk = true
        for (id, state) in states { if let model = LocalModel(engine: id) { store.modelStates[model] = state } }
        for (id, error) in lastErrors { if let model = LocalModel(engine: id) { store.modelErrors[model] = error } }
        store.leftovers = leftovers
        store.diskUsageBytes = store.modelStates.reduce(Int64(0)) { total, entry in
            switch entry.value {
            case .ready, .installed, .preparing: total + entry.key.approxInstalledBytes
            default: total
            }
        } + leftovers.values.reduce(0, +)
        return store
    }

    /// What `engine` runs on this Mac: GigaAM v3 for GigaAM. nil for a cloud model and for the retired Parakeet.
    func model(for engine: EngineID) -> LocalModel? {
        LocalModel(engine: engine)
    }

    /// The retired models with files still on this Mac, Parakeet first.
    var leftoverModels: [RetiredLocalModel] {
        RetiredLocalModel.allCases.filter { leftovers[$0] != nil }
    }

    /// The state of `id`'s model.
    func state(of id: EngineID) -> LocalModelState {
        model(for: id).map { state(model: $0) } ?? .notInstalled
    }

    func state(model: LocalModel) -> LocalModelState {
        modelStates[model] ?? .notInstalled
    }

    /// The most recent download or load failure of each engine's model.
    var lastErrors: [EngineID: AppError] {
        var errors: [EngineID: AppError] = [:]
        for id in EngineID.localEngines {
            if let model = model(for: id), let error = modelErrors[model] { errors[id] = error }
        }
        return errors
    }

    // MARK: Start

    /// Scans the disk, then prepares each model on this Mac that's installed and that a model Switch model reaches
    /// (hands-free's too) runs on: GigaAM v3, the one there is.
    func start() {
        guard !isPreview, !hasStarted else { return }
        hasStarted = true
        Task { [weak self] in
            guard let self else { return }
            await self.refreshFromDisk()
            var previous: Task<Void, Never>?
            for id in self.settings.localModelsInUse {
                guard let model = self.model(for: id), self.state(model: model) == .installed else { continue }
                self.prepare(model: model, after: previous)
                previous = self.prepareTasks[model]
            }
        }
    }

    /// Re-reads install state, what the retired models left and disk usage. Models that are busy (downloading,
    /// preparing) keep their state.
    func refreshFromDisk() async {
        let engines = self.engines
        let root = paths.models
        let scan = await Task.detached(priority: .utility) {
            () -> ([LocalModel: Bool], Int64, [RetiredLocalModel: Int64]) in
            var installed: [LocalModel: Bool] = [:]
            var usage: Int64 = 0
            for (model, engine) in engines {
                installed[model] = engine.isInstalled()
                usage += engine.bytesOnDisk()
            }
            let leftovers = Self.scanLeftovers(in: root)
            return (installed, usage + leftovers.values.reduce(0, +), leftovers)
        }.value
        for (model, isInstalled) in scan.0 {
            switch state(model: model) {
            case .downloading, .preparing, .failed:
                continue
            case .ready:
                if !isInstalled { modelStates[model] = .notInstalled }
            case .notInstalled, .installed:
                modelStates[model] = isInstalled ? .installed : .notInstalled
            }
        }
        diskUsageBytes = scan.1
        leftovers = scan.2
        if !hasScannedDisk { hasScannedDisk = true }
    }

    private func refreshDiskUsage() async {
        let engines = Array(self.engines.values)
        let root = paths.models
        let scan = await Task.detached(priority: .utility) { () -> (Int64, [RetiredLocalModel: Int64]) in
            let leftovers = Self.scanLeftovers(in: root)
            return (engines.reduce(Int64(0)) { $0 + $1.bytesOnDisk() } + leftovers.values.reduce(0, +), leftovers)
        }.value
        diskUsageBytes = scan.0
        leftovers = scan.1
    }

    /// Each retired model with a folder in `root`, and what its folders take. Stat-only.
    nonisolated static func scanLeftovers(in root: URL) -> [RetiredLocalModel: Int64] {
        var found: [RetiredLocalModel: Int64] = [:]
        for model in RetiredLocalModel.allCases where model.isOnDisk(in: root) {
            found[model] = model.bytesOnDisk(in: root)
        }
        return found
    }

    // MARK: Leftovers

    /// Deletes what `model`, retired, left on this Mac: its folders, and nothing else. Nothing runs it, so nothing has
    /// it loaded. A folder that can't go stays listed.
    func deleteLeftover(_ model: RetiredLocalModel) async {
        guard !isPreview, leftovers[model] != nil, !deletingLeftovers.contains(model) else { return }
        deletingLeftovers.insert(model)
        defer { deletingLeftovers.remove(model) }
        let folders = model.folders(in: paths.models)
        let failure = await Task.detached(priority: .utility) { () -> String? in
            let fm = FileManager.default
            do {
                for folder in folders where fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
                return nil
            } catch {
                return String(describing: error)
            }
        }.value
        if let failure {
            Log.engine.error("Delete of \(model.id, privacy: .public) failed: \(failure, privacy: .public)")
        }
        DiagnosticLog.shared.event(.models, "leftover.deleted", ["model": model, "failed": failure != nil ? true : nil])
        await refreshDiskUsage()
    }

    // MARK: Download

    /// Downloads `id`'s picked model (`download(model:)`).
    func download(_ id: EngineID) {
        guard let model = model(for: id) else { return }
        download(model: model)
    }

    /// Checks free space, downloads, then prepares the model if it is in use.
    func download(model: LocalModel) {
        guard !isPreview, let engine = engines[model] else { return }
        switch state(model: model) {
        case .downloading, .preparing, .ready, .installed:
            return
        case .failed where engine.isInstalled():
            // The files are complete, so the failure was a load: "Retry" means load again.
            prepare(model: model)
            return
        case .notInstalled, .failed:
            break
        }
        let previous = downloadTasks[model]
        let token = UUID()
        downloadTokens[model] = token
        modelErrors[model] = nil
        modelStates[model] = .downloading(DownloadProgress(fraction: 0, totalBytes: model.approxDownloadBytes))
        DiagnosticLog.shared.event(.models, "download.started", ["model": model])
        downloadTasks[model] = Task { [weak self] in
            // A just-cancelled download must fully unwind before the next one touches the same files.
            await previous?.value
            await self?.runDownload(model, engine: engine, token: token)
        }
    }

    func cancelDownload(_ id: EngineID) {
        guard let model = model(for: id) else { return }
        cancelDownload(model: model)
    }

    func cancelDownload(model: LocalModel) {
        guard let task = downloadTasks[model] else { return }
        task.cancel()
        if state(model: model).isDownloading { modelStates[model] = .notInstalled }
    }

    func waitForDownloadToSettle(_ id: EngineID) async {
        guard let model = model(for: id) else { return }
        await waitForDownloadToSettle(model: model)
    }

    /// Returns once `model` has no download task left, including a cancelled one that is still unwinding (the
    /// state reads `.notInstalled` as soon as `cancelDownload` returns, before the task has finished).
    func waitForDownloadToSettle(model: LocalModel) async {
        while let task = downloadTasks[model] {
            await task.value
            // Only a newer download (a restart) replaces the entry; a finished one clears its own.
            if downloadTasks[model] == task { return }
        }
    }

    private func runDownload(_ model: LocalModel, engine: any LocalEngine, token: UUID) async {
        defer {
            if downloadTokens[model] == token {
                downloadTasks[model] = nil
                downloadTokens[model] = nil
            }
        }
        /// False once this download was cancelled or superseded: its outcome must not touch the state any more.
        func isCurrent() -> Bool { !Task.isCancelled && downloadTokens[model] == token }
        guard isCurrent() else { return settleCancelledDownload(model, engine: engine, token: token) }

        // What the install takes on disk at its peak: a GigaAM zip and its unpacked folder are both there for a moment.
        let expected = model.approxInstallPeakBytes
        let alreadyOnDisk = await Task.detached(priority: .utility) { engine.bytesOnDisk() }.value
        let needed = Int64((Double(max(0, expected - alreadyOnDisk)) * Self.diskHeadroom).rounded(.up))
        let available = freeDiskBytes()
        guard isCurrent() else { return settleCancelledDownload(model, engine: engine, token: token) }
        if available < needed {
            DiagnosticLog.shared.event(.models, "download.failed", [
                "model": model, "code": "notEnoughDisk", "needed": Int(needed), "free": Int(available)])
            let error = AppError.notEnoughDisk(needed: needed, available: available)
            fail(model, error, message: "Not enough space. \(model.displayName) needs \(Fmt.bytes(needed)); \(Fmt.bytes(available)) is free.")
            return
        }

        let total = await engine.remoteDownloadBytes()
        var estimator = DownloadRateEstimator(totalBytes: total > 0 ? total : model.approxDownloadBytes)
        let (stream, continuation) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        async let outcome = Self.performDownload(engine, continuation)
        for await fraction in stream where isCurrent() {
            modelStates[model] = .downloading(estimator.progress(fraction: fraction,
                                                                 at: ProcessInfo.processInfo.systemUptime))
        }
        let result = await outcome

        switch result {
        case .success where downloadTokens[model] == token:
            modelStates[model] = .installed
            modelErrors[model] = nil
            await refreshDiskUsage()
            Log.engine.info("Downloaded \(model.id, privacy: .public)")
            DiagnosticLog.shared.event(.models, "download.finished", ["model": model, "bytes": Int(total)])
            onDownloadFinished?(model)
            // Loaded when it's what its engine runs now and Switch model reaches it.
            if self.model(for: model.engine) == model, settings.usesLocalModel(model.engine) { prepare(model: model) }
        case .success:
            await refreshDiskUsage()
        case .failure(let error):
            if !isCurrent() || error is CancellationError {
                settleCancelledDownload(model, engine: engine, token: token)
            } else if case LocalEngineError.notPublished(let file) = error {
                Log.engine.error("Download of \(model.id, privacy: .public) has no source: \(file, privacy: .public)")
                DiagnosticLog.shared.event(.models, "download.failed", ["model": model, "code": "notPublished"])
                fail(model, .modelNotPublished(model.engine, file: file),
                     message: "Not published yet. Put \(file) in your Downloads folder, then Retry.")
            } else {
                let detail = Self.describeDownloadFailure(error, host: model.downloadHost)
                Log.engine.error("Download of \(model.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                DiagnosticLog.shared.event(.models, "download.failed",
                                           ["model": model, "error": DiagnosticErrorCode(error)])
                fail(model, .downloadFailed(model.engine, detail), message: "Download didn’t finish. \(detail)")
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

    private func settleCancelledDownload(_ model: LocalModel, engine: any LocalEngine, token: UUID) {
        // A newer download of the same model owns the state now.
        guard downloadTokens[model] == token else { return }
        guard state(model: model).isDownloading || state(model: model) == .notInstalled else { return }
        modelStates[model] = engine.isInstalled() ? .installed : .notInstalled
    }

    private func fail(_ model: LocalModel, _ error: AppError, message: String) {
        modelStates[model] = .failed(message)
        modelErrors[model] = error
        onFailure?(model.engine, error)
    }

    // MARK: Delete

    /// Deletes `id`'s model (`delete(model:)`).
    func delete(_ id: EngineID) async {
        guard let model = model(for: id) else { return }
        await delete(model: model)
    }

    func delete(model: LocalModel) async {
        guard !isPreview, let engine = engines[model] else { return }
        if let task = downloadTasks[model] {
            task.cancel()
            await task.value
        }
        if let task = prepareTasks[model] { await task.value }
        do {
            try await gate.run { try await engine.deleteFiles() }
            modelStates[model] = .notInstalled
            modelErrors[model] = nil
        } catch {
            Log.engine.error("Delete of \(model.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            modelStates[model] = .failed("Couldn’t remove all model files. \(Self.oneLine(error))")
        }
        await refreshDiskUsage()
    }

    func reinstall(_ id: EngineID) async {
        guard let model = model(for: id) else { return }
        await reinstall(model: model)
    }

    /// Deletes the files and downloads the model again: the fix for an install that downloaded but won't load
    /// (model libraries skip files that already exist, so a plain retry can't repair it). A model in use
    /// loads once the download lands.
    func reinstall(model: LocalModel) async {
        guard !isPreview else { return }
        await delete(model: model)
        guard state(model: model) == .notInstalled else { return }
        download(model: model)
    }

    // MARK: Select and prepare

    /// Loads `id`'s model in the background (`prepare(model:)`).
    func prepare(_ id: EngineID) {
        guard let model = model(for: id) else { return }
        prepare(model: model)
    }

    /// Loads the model in the background: `.preparing` → `.ready` (or `.failed`).
    func prepare(model: LocalModel) {
        prepare(model: model, after: nil)
    }

    /// `previous`: another model's prepare to let finish first (launch loads them one after another).
    private func prepare(model: LocalModel, after previous: Task<Void, Never>?) {
        guard !isPreview, let engine = engines[model] else { return }
        switch state(model: model) {
        case .ready, .preparing, .downloading: return
        case .notInstalled, .installed, .failed: break
        }
        guard engine.isInstalled() else {
            if state(model: model) == .installed { modelStates[model] = .notInstalled }
            return
        }
        modelStates[model] = .preparing(since: Date())
        let gate = self.gate
        prepareTasks[model] = Task { [weak self] in
            await previous?.value
            let started = ProcessInfo.processInfo.systemUptime
            let result: Result<Void, Error>
            do {
                try await gate.run { try await engine.load() }
                result = .success(())
            } catch {
                result = .failure(error)
            }
            self?.finishPrepare(model, result: result, duration: ProcessInfo.processInfo.systemUptime - started)
        }
    }

    private func finishPrepare(_ model: LocalModel, result: Result<Void, Error>, duration: TimeInterval) {
        prepareTasks[model] = nil
        switch result {
        case .success:
            modelStates[model] = .ready
            modelErrors[model] = nil
            lastLoadDurations[model] = duration
            Log.engine.info("Loaded \(model.id, privacy: .public) in \(duration, format: .fixed(precision: 2), privacy: .public) s")
            DiagnosticLog.shared.event(.models, "load.finished", ["model": model, "seconds": duration])
        case .failure(let error):
            Log.engine.error("Load of \(model.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            let detail = Self.oneLine(error)
            DiagnosticLog.shared.event(.models, "load.failed", [
                "model": model, "seconds": duration, "error": DiagnosticErrorCode(error), "detail": detail])
            // Model libraries skip files that already exist, so Retry can't repair a damaged install.
            fail(model, .modelLoadFailed(model.engine, detail),
                 message: "Couldn’t load the model. Retry, or download it again.")
        }
    }

    // MARK: Transcribe

    /// Waits while the model downloads or loads, then transcribes with `id`'s model. Throws `AppError`, or
    /// `CancellationError` when the calling task is cancelled. `background`: Home's work, which lets dictations have
    /// the model first (`InferenceGate`).
    func transcribeLocal(_ id: EngineID, samples: [Float], background: Bool = false) async throws -> String {
        try await transcribeLocalWithModel(id, samples: samples, background: background).text
    }

    /// `transcribeLocal`, with the model that wrote it.
    func transcribeLocalWithModel(_ id: EngineID, samples: [Float],
                                  background: Bool = false) async throws -> (text: String, model: LocalModel) {
        guard let model = model(for: id) else {
            throw AppError.engineFailed(id, "\(id.displayName) doesn’t run on this Mac.")
        }
        let text = try await runLocal(model, background: background) { try await $0.transcribe(samples) }
        return (text, model)
    }

    private func runLocal<T: Sendable>(_ model: LocalModel, background: Bool,
                                       _ operation: @escaping @Sendable (any LocalEngine) async throws -> T)
        async throws -> T {
        let id = model.engine
        guard let engine = engines[model] else {
            throw AppError.engineFailed(id, "\(id.displayName) doesn’t run on this Mac.")
        }
        let gate = self.gate
        var attempts = 0
        while true {
            attempts += 1
            try await waitUntilReady(model, engine: engine)
            do {
                return try await gate.run(background: background) { try await operation(engine) }
            } catch LocalEngineError.notLoaded where attempts < 3 {
                // Unloaded after it reported ready (a delete queued ahead of this): look at its state again.
                if state(model: model) == .ready { modelStates[model] = .installed }
            } catch let error as AppError {
                throw error
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                Log.engine.error("\(model.id, privacy: .public) inference failed: \(String(describing: error), privacy: .public)")
                throw AppError.engineFailed(id, Self.oneLine(error))
            }
        }
    }

    private func waitUntilReady(_ model: LocalModel, engine: any LocalEngine) async throws {
        let id = model.engine
        var prepareAttempts = 0
        while true {
            try Task.checkCancellation()
            switch state(model: model) {
            case .ready:
                return
            case .preparing, .downloading:
                try await Task.sleep(for: .milliseconds(100))
            case .installed:
                guard prepareAttempts < 2 else {
                    throw AppError.modelLoadFailed(id, "The model was unloaded while loading.")
                }
                prepareAttempts += 1
                prepare(model: model)
            case .failed(let message):
                let installed = engine.isInstalled()
                if !installed {
                    switch modelErrors[model] {
                    case .downloadFailed(let engine, let detail)?: throw AppError.downloadFailed(engine, detail)
                    case .modelNotPublished(let engine, let file)?: throw AppError.modelNotPublished(engine, file: file)
                    case .notEnoughDisk(let needed, let available)?:
                        throw AppError.notEnoughDisk(needed: needed, available: available)
                    default: throw AppError.modelNotDownloaded(id)
                    }
                }
                guard prepareAttempts == 0 else { throw modelErrors[model] ?? AppError.modelLoadFailed(id, message) }
                prepareAttempts += 1
                prepare(model: model)
            case .notInstalled:
                throw AppError.modelNotDownloaded(id)
            }
        }
    }

    // MARK: Messages

    /// `host`: where the download comes from (`LocalModel.downloadHost`), named when it can't be reached.
    static func describeDownloadFailure(_ error: Error, host: String? = nil) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "No internet connection."
            case .timedOut:
                return "The connection timed out."
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
                return "Couldn’t reach \(host ?? "the server")."
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
