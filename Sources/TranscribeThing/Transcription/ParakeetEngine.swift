import CoreML
import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT 0.6B v3 through FluidAudio.
actor ParakeetEngine: LocalEngine {
    static let version: AsrModelVersion = .v3
    static let repo: Repo = .parakeetV3
    /// `Encoder_v2.mlmodelc`: int8 linear encoder that avoids the token flips of FluidAudio issue #760.
    static let precision: ParakeetEncoderPrecision = .int8V2
    /// FluidAudio stops decoding a 15 s window after this many tokens (library default 150 can truncate
    /// fast Russian speech).
    static let maxTokensPerWindow = 400

    nonisolated let engineID: EngineID = .parakeet
    /// e.g. ~/Library/Application Support/transcribe-thing/Models (FluidAudio appends the repo folder itself).
    nonisolated let modelsRoot: URL
    /// modelsRoot/parakeet-tdt-0.6b-v3
    nonisolated let repoDirectory: URL

    private var manager: AsrManager?
    private var cachedRemoteBytes: Int64?

    init(modelsRoot: URL) {
        self.modelsRoot = modelsRoot
        // Every FluidAudio API resolves `<parent>/<Repo.folderName>`; using that name makes all of them agree.
        self.repoDirectory = modelsRoot.appendingPathComponent(Self.repo.folderName, isDirectory: true)
    }

    nonisolated var storageURLs: [URL] { [repoDirectory] }

    /// FluidAudio's debug lines can contain recognized words; keep them out of the console and below warning.
    nonisolated static func quietLibraryLogging() {
        AppLogger.minimumLevel = .warning
        AppLogger.mirrorsToConsole = false
    }

    // MARK: Install state

    /// Stronger than `AsrModels.modelsExist` (which only checks that folders exist, true mid-download):
    /// every bundle needs its compiled files and no `*.partial` may be left anywhere.
    nonisolated func isInstalled() -> Bool {
        let fm = FileManager.default
        guard AsrModels.modelsExist(at: repoDirectory, version: Self.version, encoderPrecision: Self.precision) else {
            return false
        }
        for bundle in ModelNames.ASR.requiredModelsV3(precision: Self.precision) {
            let dir = repoDirectory.appendingPathComponent(bundle, isDirectory: true)
            for inner in ["coremldata.bin", "model.mil", "weights/weight.bin"]
            where !fm.fileExists(atPath: dir.appendingPathComponent(inner).path) {
                return false
            }
        }
        if let walker = fm.enumerator(at: repoDirectory, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "partial" {
                return false
            }
        }
        return true
    }

    // MARK: Download

    func remoteDownloadBytes() async -> Int64 {
        if let cachedRemoteBytes { return cachedRemoteBytes }
        let fallback = engineID.approxDownloadBytes ?? 0
        guard let files = try? await HuggingFaceTree.list(repo: Self.repo.remotePath) else { return fallback }
        // Same selection as ModelHub.download: the required bundles plus every root-level .json/.txt.
        let bundles = ModelNames.ASR.requiredModelsV3(precision: Self.precision).map { $0 + "/" }
        let total = files.reduce(Int64(0)) { sum, file in
            let inBundle = bundles.contains { file.path.hasPrefix($0) }
            let rootMeta = !file.path.contains("/") && (file.path.hasSuffix(".json") || file.path.hasSuffix(".txt"))
            return inBundle || rootMeta ? sum + file.size : sum
        }
        let result = total > 0 ? total : fallback
        cachedRemoteBytes = result
        return result
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        Self.quietLibraryLogging()
        try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        let throttle = ProgressThrottle(send: progress)
        // Resumable (HTTP Range into `*.partial`), retries transient errors, cancels with the task.
        try await ModelHub.download(Self.repo, to: modelsRoot, variant: Self.precision.rawValue) { update in
            guard case .downloading = update.phase else { return }
            // ModelHub maps the download phase to 0...0.5 (the rest is reserved for compiling, which it skips).
            throttle.offer(update.fractionCompleted / 0.5)
        }
        try Task.checkCancellation()
        guard isInstalled() else { throw LocalEngineError.incompleteDownload(Self.missingParts(in: repoDirectory)) }
        progress(1)
    }

    private nonisolated static func missingParts(in directory: URL) -> [String] {
        let fm = FileManager.default
        var missing = ModelNames.ASR.requiredModelsV3(precision: precision)
            .filter { !fm.fileExists(atPath: directory.appendingPathComponent($0).path) }
            .sorted()
        if !fm.fileExists(atPath: directory.appendingPathComponent(ModelNames.ASR.vocabularyFile).path) {
            missing.append(ModelNames.ASR.vocabularyFile)
        }
        return missing
    }

    // MARK: Load

    var isLoaded: Bool { manager != nil }

    func load() async throws {
        if manager != nil { return }
        guard isInstalled() else { throw LocalEngineError.notInstalled }
        Self.quietLibraryLogging()
        let directory = repoDirectory
        // loadLocal is synchronous and compiles for the Neural Engine on first run (seconds): keep it off
        // the cooperative pool. It never touches the network and never deletes the folder on failure.
        let models: AsrModels = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try AsrModels.loadLocal(
                        from: directory, version: Self.version, encoderPrecision: Self.precision))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        let asr = AsrManager(
            config: ASRConfig(tdtConfig: TdtConfig(maxTokensPerChunk: Self.maxTokensPerWindow)),
            models: models)
        // The first prediction instantiates the ANE programs; pay that now, not on the first dictation.
        var warmState = TdtDecoderState.make(decoderLayers: Self.version.decoderLayers)
        _ = try? await asr.transcribe([Float](repeating: 0, count: 16_000), decoderState: &warmState, language: nil)
        manager = asr
    }

    func unload() async {
        guard let manager else { return }
        await manager.cleanup()
        self.manager = nil
    }

    // MARK: Transcribe

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw LocalEngineError.notLoaded }
        var input = samples
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate)
        if input.count < minimum {
            // FluidAudio rejects anything under 0.3 s.
            input.append(contentsOf: [Float](repeating: 0, count: minimum - input.count))
        }
        // A fresh decoder state per utterance: the state carries LSTM context and the last token, which
        // would otherwise leak the previous dictation into this one. `language: nil` keeps mixed
        // Russian/English dictation possible (a language is only a script filter here).
        var state = TdtDecoderState.make(decoderLayers: Self.version.decoderLayers)
        let result = try await manager.transcribe(input, decoderState: &state, language: nil)
        try Task.checkCancellation()
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Delete

    func deleteFiles() async throws {
        await unload()
        let fm = FileManager.default
        if fm.fileExists(atPath: repoDirectory.path) {
            try fm.removeItem(at: repoDirectory)
        }
    }
}
