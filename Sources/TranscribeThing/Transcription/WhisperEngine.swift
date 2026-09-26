import CoreML
import Foundation
import WhisperKit

/// OpenAI Whisper Large V3 Turbo through WhisperKit. Never import FluidAudio in this file.
///
/// WhisperKit is a non-Sendable class whose async methods run on the caller's executor
/// (the package is built with NonisolatedNonsendingByDefault), so every call goes through this actor:
/// from the main actor they would run token sampling and KV-cache copies on the main thread.
actor WhisperEngine: LocalEngine {
    /// OpenAI large-v3-turbo (2024-09-30), mixed 4/6-bit palettized, 627 MB. Argmax's default for M1-family
    /// Macs; the `_turbo` variants are disabled there because Core ML specialization is prohibitively slow.
    static let variant = "openai_whisper-large-v3-v20240930_626MB"
    static let modelRepo = "argmaxinc/whisperkit-coreml"
    /// The tokenizer isn't in the model folder; WhisperKit looks for it under `<tokenizerFolder>/models/<repo>`.
    static let tokenizerRepo = "openai/whisper-large-v3"
    static let tokenizerFiles = ["config.json", "tokenizer.json", "tokenizer_config.json"]
    private static let requiredTokenizerFiles = ["tokenizer.json", "tokenizer_config.json"]
    private static let separateSnapshotBytes: Int64 = 10_000_000

    nonisolated let engineID: EngineID = .whisper
    /// ~/Library/Application Support/transcribe-thing/WhisperKit: WhisperKit's downloadBase AND tokenizerFolder.
    /// Leaving either nil makes the Hub client write to ~/Documents/huggingface.
    nonisolated let baseDir: URL

    /// Which Core ML compute units each Whisper model runs on. Core ML specializes and caches every model
    /// per compute unit, so each preset pays its own first load, and loading another preset can evict the
    /// cached Neural Engine build (the next `.ane` load is cold again).
    ///
    /// Measured on M1 Max (macOS 26, release build, 8 s / 38 s clips): `.ane` first load ~236 s, cached ~2.5 s,
    /// 1.42 s / 3.48 s per clip. `.gpu` first load ~25-31 s, cached ~3.4-4.4 s, but 1.7-3.3 s / 4.6-6.3 s per clip
    /// (the GPU is shared with WindowServer), a 2.4 GB cache, and one MPSGraph assertion crash in 8 runs.
    /// `.gpuAll`: 9.6-10.9 s on the long clip. Transcripts were identical. Hence `.ane` stays the default.
    enum ComputePreset: String, CaseIterable, Sendable {
        /// WhisperKit's default: mel on the GPU, encoder and decoder on the Neural Engine.
        case ane
        /// Encoder on the GPU, decoder on the Neural Engine.
        case gpu
        /// Encoder and decoder on the GPU.
        case gpuAll = "gpu-all"

        static let `default`: ComputePreset = .ane

        var options: ModelComputeOptions {
            switch self {
            case .ane:
                ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndNeuralEngine,
                                    textDecoderCompute: .cpuAndNeuralEngine)
            case .gpu:
                ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndGPU,
                                    textDecoderCompute: .cpuAndNeuralEngine)
            case .gpuAll:
                ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndGPU,
                                    textDecoderCompute: .cpuAndGPU)
            }
        }

        /// e.g. "mel GPU · encoder ANE · decoder ANE"
        var summary: String {
            let o = options
            func name(_ units: MLComputeUnits) -> String {
                switch units {
                case .cpuOnly: "CPU"
                case .cpuAndGPU: "GPU"
                case .cpuAndNeuralEngine: "ANE"
                case .all: "all"
                @unknown default: "?"
                }
            }
            return "mel \(name(o.melCompute)) · encoder \(name(o.audioEncoderCompute)) · decoder \(name(o.textDecoderCompute))"
        }
    }

    /// Fixed for the engine's lifetime; `--whisper-compute` in EngineCLI picks another one for diagnostics.
    nonisolated let compute: ComputePreset

    private var kit: WhisperKit?
    private var remoteFiles: [HuggingFaceTree.File]?
    private var tokenizerRemoteFiles: [HuggingFaceTree.File]?

    init(baseDir: URL, compute: ComputePreset = .default) {
        self.baseDir = baseDir
        self.compute = compute
    }

    // MARK: Layout (mirrors the Hub client: <downloadBase>/models/<repo id>)

    private nonisolated var hubRoot: URL { baseDir.appendingPathComponent("models", isDirectory: true) }
    private nonisolated var modelRepoRoot: URL { hubRoot.appendingPathComponent(Self.modelRepo, isDirectory: true) }
    nonisolated var modelFolder: URL { modelRepoRoot.appendingPathComponent(Self.variant, isDirectory: true) }
    nonisolated var tokenizerFolder: URL { hubRoot.appendingPathComponent(Self.tokenizerRepo, isDirectory: true) }
    /// Written only after every file was verified; its absence means "not installed" whatever is on disk.
    nonisolated var markerURL: URL { baseDir.appendingPathComponent("\(Self.variant).installed.json") }

    nonisolated var storageURLs: [URL] { [hubRoot, markerURL] }

    struct InstallMarker: Codable, Equatable {
        struct File: Codable, Equatable { let path: String; let size: Int64 }
        let variant: String
        let files: [File]
        let installedAt: Date
    }

    // MARK: Install state

    nonisolated func isInstalled() -> Bool {
        Self.isInstalled(baseDir: baseDir)
    }

    /// Marker present, every listed file at its recorded size, tokenizer present. Stat-only.
    nonisolated static func isInstalled(baseDir: URL) -> Bool {
        let markerURL = baseDir.appendingPathComponent("\(variant).installed.json")
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(InstallMarker.self, from: data),
              marker.variant == variant, !marker.files.isEmpty
        else { return false }
        let fm = FileManager.default
        let repoRoot = baseDir.appendingPathComponent("models/\(modelRepo)", isDirectory: true)
        for file in marker.files {
            let url = repoRoot.appendingPathComponent(file.path)
            guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
                  size.int64Value == file.size
            else { return false }
        }
        let tokenizer = baseDir.appendingPathComponent("models/\(tokenizerRepo)", isDirectory: true)
        return requiredTokenizerFiles.allSatisfy { fm.fileExists(atPath: tokenizer.appendingPathComponent($0).path) }
    }

    // MARK: Download

    func remoteDownloadBytes() async -> Int64 {
        do {
            let (model, tokenizer) = try await listRemote()
            return (model + tokenizer).reduce(Int64(0)) { $0 + $1.size }
        } catch {
            return engineID.approxDownloadBytes ?? 0
        }
    }

    private func listRemote() async throws -> (model: [HuggingFaceTree.File], tokenizer: [HuggingFaceTree.File]) {
        if let remoteFiles, let tokenizerRemoteFiles { return (remoteFiles, tokenizerRemoteFiles) }
        let model = try await HuggingFaceTree.list(repo: Self.modelRepo, folder: Self.variant)
        guard !model.isEmpty else { throw LocalEngineError.listingFailed("no files in \(Self.variant)") }
        let tokenizer = try await HuggingFaceTree.list(repo: Self.tokenizerRepo, recursive: false)
            .filter { Self.tokenizerFiles.contains($0.path) }
        remoteFiles = model
        tokenizerRemoteFiles = tokenizer
        return (model, tokenizer)
    }

    /// Byte-weighted progress: WhisperKit's own download weights all 17 files equally, so the two weight files
    /// (99 % of the bytes) each get their own Hub snapshot, whose fraction is then that file's own fraction.
    /// The small files share one snapshot: every snapshot re-lists the whole (large) model repo first.
    /// Big files go first so the bar and the speed estimate move right away.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let (files, tokenizerFiles) = try await listRemote()
        let total = Double(max(1, (files + tokenizerFiles).reduce(Int64(0)) { $0 + $1.size }))
        let throttle = ProgressThrottle(send: progress)
        let hub = HubApiWrapper(downloadBase: baseDir)
        let modelRepo = HubApiWrapper.Repo(id: Self.modelRepo)

        let big = files.filter { $0.size >= Self.separateSnapshotBytes }.sorted { $0.size > $1.size }
        let small = files.filter { $0.size < Self.separateSnapshotBytes }
        var batches: [(repo: HubApiWrapper.Repo, globs: [String], bytes: Int64)] = big.map {
            (modelRepo, [$0.path], $0.size)
        }
        if !small.isEmpty {
            batches.append((modelRepo, small.map(\.path), small.reduce(0) { $0 + $1.size }))
        }
        batches.append((HubApiWrapper.Repo(id: Self.tokenizerRepo), Self.tokenizerFiles,
                        tokenizerFiles.reduce(0) { $0 + $1.size }))

        var doneBytes: Int64 = 0
        for batch in batches {
            try Task.checkCancellation()
            let before = Double(doneBytes)
            let size = Double(batch.bytes)
            _ = try await snapshot(hub, batch.repo, matching: batch.globs) { fraction in
                throttle.offer((before + fraction * size) / total)
            }
            doneBytes += batch.bytes
            throttle.offer(Double(doneBytes) / total)
        }

        var missing: [String] = []
        for file in files {
            let url = modelRepoRoot.appendingPathComponent(file.path)
            let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
            if size?.int64Value != file.size { missing.append(file.path) }
        }
        for name in Self.requiredTokenizerFiles where !fm.fileExists(atPath: tokenizerFolder.appendingPathComponent(name).path) {
            missing.append("\(Self.tokenizerRepo)/\(name)")
        }
        guard missing.isEmpty else { throw LocalEngineError.incompleteDownload(missing) }

        let marker = InstallMarker(variant: Self.variant,
                                   files: files.map { .init(path: $0.path, size: $0.size) },
                                   installedAt: Date())
        try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
        progress(1)
    }

    /// The Hub client can RETURN normally when cancelled mid-file, and throws three different error types when
    /// cancelled elsewhere; normalize all of that to `CancellationError`.
    private func snapshot(_ hub: HubApiWrapper, _ repo: HubApiWrapper.Repo, matching globs: [String],
                          fraction: @escaping @Sendable (Double) -> Void) async throws -> URL {
        do {
            let url = try await hub.snapshot(from: repo, matching: globs) { progress in
                fraction(progress.fractionCompleted)
            }
            try Task.checkCancellation()
            return url
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    // MARK: Load

    var isLoaded: Bool { kit != nil }

    /// The first load after install, after a macOS update, or after Core ML evicted its cache specializes the
    /// models for this chip: about 4 minutes on M1 Max, about 2.5 s afterwards. A new app binary doesn't
    /// invalidate that cache (measured).
    func load() async throws {
        if kit != nil { return }
        guard isInstalled() else { throw LocalEngineError.notInstalled }
        let config = WhisperKitConfig(
            downloadBase: baseDir,
            modelRepo: Self.modelRepo,
            modelFolder: modelFolder.path,      // non-nil: no network I/O during setup
            tokenizerFolder: baseDir,
            computeOptions: compute.options,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        let kit = try await WhisperKit(config)
        _ = try? await kit.transcribe(
            audioArray: [Float](repeating: 0, count: WhisperKit.sampleRate),
            decodeOptions: DecodingOptions(temperatureFallbackCount: 0, withoutTimestamps: true, windowClipTime: 0))
        self.kit = kit
    }

    func unload() async {
        guard let kit else { return }
        await kit.unloadModels()
        self.kit = nil
    }

    // MARK: Transcribe

    static func decodingOptions(language: String?) -> DecodingOptions {
        let language = language.flatMap { Constants.languageCodes.contains($0) ? $0 : nil }
        return DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 2,          // default 5 means up to 6 decodes per window
            sampleLength: Constants.maxTokenContext,
            usePrefillPrompt: true,
            detectLanguage: language == nil,      // the default prefill silently forces English
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            windowClipTime: 0,                    // the default 1.0 drops clips of 1 s or less entirely
            suppressBlank: false,                 // true forbids an immediate end-of-text, inviting hallucinations
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.6,
            concurrentWorkerCount: 4,
            chunkingStrategy: .vad                // only used above 30 s; splits at silences instead of mid-word
        )
    }

    func transcribe(_ samples: [Float], options: LocalTranscriptionOptions) async throws -> String {
        guard let kit else { throw LocalEngineError.notLoaded }
        let voiced = SilenceGuard.voicedSeconds(samples)
        guard voiced >= SilenceGuard.minimumVoicedSeconds else { return "" }

        let results = try await kit.transcribe(audioArray: Self.paddedForChunking(samples),
                                               decodeOptions: Self.decodingOptions(language: options.language))
        // With VAD chunking, per-chunk errors (including cancellation) are swallowed rather than thrown.
        try Task.checkCancellation()
        let text = Self.clean(results.map(\.text))
        return SilenceGuard.isLikelyHallucination(text, voicedSeconds: voiced) ? "" : text
    }

    /// WhisperKit's VAD chunker (audio over one 30 s window) stops a fixed 1 s (`windowPadding`, not settable
    /// through DecodingOptions) before the end, so a chunk boundary inside the last second silently drops the
    /// words after it. A second of trailing silence means only the padding can be left out.
    static func paddedForChunking(_ samples: [Float]) -> [Float] {
        guard samples.count > Constants.defaultWindowSamples else { return samples }
        return samples + [Float](repeating: 0, count: chunkerWindowPadding)
    }

    /// VADAudioChunker's default `windowPadding`.
    static let chunkerWindowPadding = WhisperKit.sampleRate

    static func clean(_ chunks: [String]) -> String {
        chunks.joined(separator: " ")
            .replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Delete

    func deleteFiles() async throws {
        await unload()
        remoteFiles = nil
        tokenizerRemoteFiles = nil
        let fm = FileManager.default
        // Marker first: a half-deleted install must never look installed.
        for url in [markerURL, hubRoot] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }
}
