import CoreML
import FluidAudio
import Foundation

/// Headless engine checks, dispatched by TranscribeThingMain before the app starts:
///
///     transcribe-thing --transcribe <audio file>
///            --engine parakeet|parakeetCloud|geminiFlash|geminiPro
///            [--download] [--prompt <text>] [--repeat <n>] [--effort minimal|low|medium|high]
///            [--clean-up [--clean-up-prompt <text>] [--clean-up-effort minimal|low|medium|high]]
///     transcribe-thing --model-status
///
/// Hidden diagnostic (not in the usage text): `--parakeet-compute ane|gpu` loads the local model on other Core ML
/// compute units. Core ML specializes and caches the model per compute unit, so the first run with a new choice
/// is a cold load, and it can evict the default Neural Engine build (the next default load is cold again).
///
/// Uses the real model folder (~/Library/Application Support/transcribe-thing) and the real pipeline
/// (ModelStore → InferenceGate → engine, or OpenRouterClient). Cloud engines read the key from
/// OPENROUTER_API_KEY, else from the Keychain; cloud Parakeet also prints the provider that served the request.
/// `--prompt` and `--effort` apply to Gemini only (the effort moves to the nearest level the model supports).
/// `--clean-up` sends the last transcript to Gemini 3.5 Flash Lite with the clean-up prompt (by default
/// `CleanupModel.examplePrompt`) and prints the cleaned text. Settings are in-memory: the CLI never changes the app's.
/// An engine that answers with no text heard no speech: that prints `NO SPEECH` instead of `TEXT:` and exits 0,
/// like any other answer. Only real failures print `ERROR:` and exit non-zero.
enum EngineCLI {
    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains("--transcribe") || arguments.contains("--model-status")
    }

    /// Runs the CLI mode and exits the process.
    @MainActor
    static func run(_ arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            exit(await main(arguments))
        }
        // Parks the main thread while servicing the main queue, which is where main-actor tasks run.
        dispatchMain()
    }

    private enum ExitCode {
        static let ok: Int32 = 0
        static let failed: Int32 = 1
        static let usage: Int32 = 2
        static let notDownloaded: Int32 = 3
    }

    @MainActor
    private static func main(_ arguments: [String]) async -> Int32 {
        if arguments.contains("--model-status") {
            await printModelStatus()
            return ExitCode.ok
        }
        guard let options = Options(arguments) else {
            printError(Options.usage)
            return ExitCode.usage
        }
        do {
            return try await transcribe(options)
        } catch let error as AppError {
            let notice = error.notice(recordingID: nil, fallbackEngine: nil, engine: options.engine)
            let message = [notice.title, notice.body].compactMap { $0 }.joined(separator: ". ")
            printError("ERROR: \(error.code): \(message)")
            if let detail = error.detail { printError("DETAIL: \(detail)") }
            if case .modelNotDownloaded = error { return ExitCode.notDownloaded }
            return ExitCode.failed
        } catch {
            printError("ERROR: \(error.localizedDescription)")
            return ExitCode.failed
        }
    }

    // MARK: Transcribe

    private struct Options {
        static let usage = """
        usage: transcribe-thing --transcribe <audio file> \
        --engine parakeet|parakeetCloud|geminiFlash|geminiPro \
        [--download] [--prompt <text>] [--repeat <n>] [--effort minimal|low|medium|high] \
        [--clean-up [--clean-up-prompt <text>] [--clean-up-effort minimal|low|medium|high]]
               transcribe-thing --model-status
        """

        var file: URL
        var engine: EngineID
        var download: Bool
        var prompt: String?
        var repeatCount: Int
        var parakeetCompute: ParakeetCompute?
        var effort: ReasoningEffort?
        var cleanUp: Bool
        var cleanupPrompt: String?
        var cleanupEffort: ReasoningEffort?

        init?(_ arguments: [String]) {
            func value(_ flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
                let value = arguments[index + 1]
                return value.hasPrefix("--") ? nil : value
            }
            guard let path = value("--transcribe"), let engineName = value("--engine"),
                  let engine = Self.engine(named: engineName)
            else { return nil }
            file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            self.engine = engine
            download = arguments.contains("--download")
            prompt = value("--prompt")
            repeatCount = max(1, min(20, value("--repeat").flatMap(Int.init) ?? 1))
            if arguments.contains("--effort") {
                guard let level = value("--effort").flatMap(ReasoningEffort.init(rawValue:)) else { return nil }
                effort = level
            }
            cleanUp = arguments.contains("--clean-up")
            cleanupPrompt = value("--clean-up-prompt")
            if arguments.contains("--clean-up-effort") {
                guard let level = value("--clean-up-effort").flatMap(ReasoningEffort.init(rawValue:)) else { return nil }
                cleanupEffort = level
            }
            if arguments.contains("--parakeet-compute") {
                guard let preset = value("--parakeet-compute").flatMap(ParakeetCompute.init(rawValue:)) else { return nil }
                parakeetCompute = preset
            }
        }

        static func engine(named name: String) -> EngineID? {
            if let id = EngineID(rawValue: name) { return id }
            switch name.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "") {
            case "parakeet": return .parakeet
            case "parakeetcloud", "cloudparakeet": return .parakeetCloud
            case "geminiflash", "flash": return .geminiFlash
            case "geminipro", "pro": return .geminiPro
            default: return nil
            }
        }
    }

    @MainActor
    private static func transcribe(_ options: Options) async throws -> Int32 {
        guard FileManager.default.fileExists(atPath: options.file.path) else {
            printError("ERROR: no such file: \(options.file.path)")
            return ExitCode.usage
        }
        let url = options.file
        let decodeStart = ContinuousClock.now
        let samples: [Float]
        do {
            samples = try await Task.detached(priority: .userInitiated) { try AudioFileLoader.load16kMono(url) }.value
        } catch {
            printError("ERROR: couldn’t read \(url.lastPathComponent): \(error.localizedDescription)")
            return ExitCode.failed
        }
        let audioSeconds = Double(samples.count) / Recording.sampleRate
        print("AUDIO: \(url.lastPathComponent) · \(format(audioSeconds)) s · 16 kHz mono · decoded in \(format(seconds(since: decodeStart))) s")
        print("ENGINE: \(options.engine.displayName) (\(options.engine.rawValue))")
        if options.engine.isLocal {
            let preset = options.parakeetCompute ?? .ane
            print("COMPUTE: \(preset.rawValue) · \(preset.summary)")
        }

        let paths = AppPaths.live()
        let settings = AppSettings.inMemory()
        settings.selectedEngine = options.engine
        settings.geminiSystemPrompt = options.prompt ?? ""
        if let effort = options.effort { settings.setReasoningEffort(effort, for: options.engine) }
        settings.cleanupSystemPrompt = options.cleanupPrompt ?? CleanupModel.examplePrompt
        if let effort = options.cleanupEffort { settings.cleanupReasoningEffort = effort }
        if let effort = settings.reasoningEffort(for: options.engine) { print("EFFORT: \(effort.rawValue)") }
        var engines = ModelStore.makeEngines(paths: paths)
        if options.parakeetCompute == .gpu {
            engines[.parakeet] = ParakeetEncoderOnGPU(modelsRoot: paths.models)
        }
        let store = ModelStore(paths: paths, settings: settings, engines: engines, gate: .shared,
                               freeDiskBytes: { paths.freeDiskBytes() })
        let client = OpenRouterClient()
        let account = OpenRouterAccount(keychain: .inMemory(), client: client)
        let service = TranscriptionService(models: store, account: account, client: client, settings: settings)

        if options.engine.isLocal {
            try paths.ensureDirectories()
            ParakeetEngine.quietLibraryLogging()
            let code = try await prepareLocal(options, store: store)
            guard code == ExitCode.ok else { return code }
        }
        if options.engine.isCloud || options.cleanUp {
            guard let key = cloudKey() else { throw AppError.openRouterMissingKey }
            await account.setKey(key)
            print("KEY: \(account.maskedKey ?? "?") · \(describe(account.status))")
        }

        let recording = Recording(samples: samples)
        var last: TranscriptResult?
        var runTimes: [TimeInterval] = []
        for run in 1...options.repeatCount {
            let result = try await service.transcribe(recording, engine: options.engine)
            runTimes.append(result.processingTime)
            let speed = result.processingTime > 0 ? audioSeconds / result.processingTime : 0
            var line = "RUN \(run): \(format(result.processingTime, digits: 3)) s · \(format(speed, digits: 1))x real time"
            if let cost = result.costUSD { line += " · $\(String(format: "%.5f", cost))" }
            if let reasoning = result.usage?.reasoningTokens { line += " · \(reasoning) reasoning tokens" }
            print(line)
            last = result
        }
        if let last {
            if options.engine.cloudAPI == .transcriptions {
                var provider = last.provider
                if provider == nil, let generationID = last.generationID {
                    provider = await service.servedProvider(generationID: generationID)
                }
                let expected = options.engine.provider.map { " · expected \($0)" } ?? ""
                print("PROVIDER: \(provider ?? "unknown")\(expected)")
            }
            print(last.text.isEmpty ? "NO SPEECH" : "TEXT: \(last.text)")
            if let best = runTimes.min() { print("TRANSCRIBE: first \(format(runTimes[0], digits: 3)) s · best \(format(best, digits: 3)) s") }
            if options.cleanUp, !last.text.isEmpty {
                let cleaned = try await service.cleanUp(last.text, of: last.engine)
                var line = "CLEAN-UP: \(settings.cleanupReasoningEffort.rawValue) · \(format(cleaned.processingTime, digits: 3)) s"
                if let cost = cleaned.costUSD { line += " · $\(String(format: "%.5f", cost))" }
                if let reasoning = cleaned.usage?.reasoningTokens { line += " · \(reasoning) reasoning tokens" }
                print(line)
                print(cleaned.text.isEmpty ? "CLEANED: (empty)" : "CLEANED: \(cleaned.text)")
            }
        }
        return ExitCode.ok
    }

    @MainActor
    private static func prepareLocal(_ options: Options, store: ModelStore) async throws -> Int32 {
        let id = options.engine
        await store.refreshFromDisk()
        print("MODEL: \(stateLine(store.state(of: id), id)) · \(Fmt.bytes(store.diskUsageBytes)) of models on disk")

        if store.state(of: id) == .notInstalled {
            guard options.download else {
                printError("\(id.displayName) isn’t downloaded. Add --download to fetch it (about \(Fmt.bytes(id.approxDownloadBytes ?? 0))).")
                throw AppError.modelNotDownloaded(id)
            }
            let started = ContinuousClock.now
            store.download(id)
            try await waitForDownload(store, id)
            if let error = store.lastErrors[id] { throw error }
            if case .failed(let message) = store.state(of: id) { throw AppError.downloadFailed(id, message) }
            let elapsed = seconds(since: started)
            let size = Fmt.bytes(id.approxDownloadBytes ?? 0)
            print("DOWNLOAD: done · \(size) in \(format(elapsed)) s")
        }

        switch store.state(of: id) {
        case .installed, .failed: store.prepare(id)
        case .notInstalled, .downloading, .preparing, .ready: break
        }
        if store.state(of: id).isPreparing {
            print("PREPARE: loading \(id.shortName)… (after a download, a macOS update or a Core ML cache eviction, optimizing it for this Mac takes about 30 s)")
        }
        let loadStarted = ContinuousClock.now
        var lastNote = ContinuousClock.now
        while store.state(of: id).isPreparing {
            try await Task.sleep(for: .milliseconds(200))
            if lastNote.duration(to: .now) >= .seconds(15) {
                lastNote = .now
                print("PREPARE: still optimizing… \(format(seconds(since: loadStarted), digits: 0)) s")
            }
        }
        switch store.state(of: id) {
        case .ready:
            let load = store.lastLoadDurations[id] ?? seconds(since: loadStarted)
            print("LOAD: \(format(load, digits: 2)) s")
        case .failed(let message):
            throw store.lastErrors[id] ?? AppError.modelLoadFailed(id, message)
        case .notInstalled:
            throw AppError.modelNotDownloaded(id)
        default:
            throw AppError.modelLoadFailed(id, "Unexpected state: \(stateLine(store.state(of: id), id))")
        }
        return ExitCode.ok
    }

    @MainActor
    private static func waitForDownload(_ store: ModelStore, _ id: EngineID) async throws {
        var lastPercent = -100
        var lastLine = ContinuousClock.now
        while case .downloading(let progress) = store.state(of: id) {
            if progress.percent >= lastPercent + 5 || lastLine.duration(to: .now) >= .seconds(10) {
                lastPercent = progress.percent
                lastLine = .now
                var line = "DOWNLOAD: \(progress.percent)% · \(Fmt.bytes(progress.bytesReceived)) of \(Fmt.bytes(progress.totalBytes))"
                if let rate = progress.bytesPerSecond { line += " · \(Fmt.bytes(Int64(rate)))/s" }
                if let eta = progress.secondsRemaining { line += " · \(Fmt.eta(eta))" }
                print(line)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func cloudKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        return KeychainStore().read(KeychainStore.openRouterAccount)
    }

    // MARK: Parakeet compute diagnostics

    enum ParakeetCompute: String, Sendable {
        /// ParakeetEngine as shipped: preprocessor on the CPU, everything else on the Neural Engine.
        case ane
        /// The conformer encoder on the GPU instead; decoder and joint stay on the Neural Engine.
        case gpu

        var summary: String {
            switch self {
            case .ane: "preprocessor CPU · encoder ANE · decoder ANE · joint ANE"
            case .gpu: "preprocessor CPU · encoder GPU · decoder ANE · joint ANE"
            }
        }
    }

    /// `--parakeet-compute gpu`: ParakeetEngine's load and transcribe with the encoder on `.cpuAndGPU`.
    /// Install state, download and delete are ParakeetEngine's own.
    private actor ParakeetEncoderOnGPU: LocalEngine {
        nonisolated let engineID: EngineID = .parakeet
        private nonisolated let base: ParakeetEngine
        private var manager: AsrManager?

        init(modelsRoot: URL) {
            base = ParakeetEngine(modelsRoot: modelsRoot)
        }

        nonisolated var storageURLs: [URL] { base.storageURLs }
        nonisolated func isInstalled() -> Bool { base.isInstalled() }
        func remoteDownloadBytes() async -> Int64 { await base.remoteDownloadBytes() }
        func download(progress: @escaping @Sendable (Double) -> Void) async throws {
            try await base.download(progress: progress)
        }

        var isLoaded: Bool { manager != nil }

        func load() async throws {
            if manager != nil { return }
            guard isInstalled() else { throw LocalEngineError.notInstalled }
            let directory = base.repoDirectory
            let models: AsrModels = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try AsrModels.loadLocal(
                            from: directory, version: ParakeetEngine.version,
                            encoderPrecision: ParakeetEngine.precision, encoderComputeUnits: .cpuAndGPU))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            let asr = AsrManager(
                config: ASRConfig(tdtConfig: TdtConfig(maxTokensPerChunk: ParakeetEngine.maxTokensPerWindow)),
                models: models)
            var warmState = TdtDecoderState.make(decoderLayers: ParakeetEngine.version.decoderLayers)
            _ = try? await asr.transcribe([Float](repeating: 0, count: 16_000), decoderState: &warmState, language: nil)
            manager = asr
        }

        func unload() async {
            guard let manager else { return }
            await manager.cleanup()
            self.manager = nil
        }

        func transcribe(_ samples: [Float]) async throws -> String {
            guard let manager else { throw LocalEngineError.notLoaded }
            var input = samples
            let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate)
            if input.count < minimum { input.append(contentsOf: [Float](repeating: 0, count: minimum - input.count)) }
            var state = TdtDecoderState.make(decoderLayers: ParakeetEngine.version.decoderLayers)
            let result = try await manager.transcribe(input, decoderState: &state, language: nil)
            try Task.checkCancellation()
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func deleteFiles() async throws {
            await unload()
            try await base.deleteFiles()
        }
    }

    // MARK: Model status

    @MainActor
    private static func printModelStatus() async {
        let paths = AppPaths.live()
        print("transcribe-thing models · \(paths.root.path)")
        print("Free disk: \(Fmt.bytes(paths.freeDiskBytes()))")
        let engines = ModelStore.makeEngines(paths: paths)
        for id in EngineID.localEngines {
            guard let engine = engines[id] else { continue }
            let report = await Task.detached(priority: .utility) {
                (installed: engine.isInstalled(), bytes: engine.bytesOnDisk())
            }.value
            let status = report.installed ? "installed" : (report.bytes > 0 ? "incomplete (resumable)" : "not installed")
            let name = id.displayName.padding(toLength: 24, withPad: " ", startingAt: 0)
            let state = status.padding(toLength: 24, withPad: " ", startingAt: 0)
            print("\(id.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))\(name)\(state)\(Fmt.bytes(report.bytes)) on disk · \(engine.storageURLs[0].path)")
        }
        let envKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"].map { !$0.isEmpty } ?? false
        print("OpenRouter key: \(envKey ? "OPENROUTER_API_KEY is set" : "not in the environment (the app keeps it in the Keychain)")")
    }

    // MARK: Formatting

    private static func stateLine(_ state: LocalModelState, _ id: EngineID) -> String {
        switch state {
        case .notInstalled: "not installed"
        case .downloading(let p): "downloading \(p.percent)%"
        case .installed: "installed"
        case .preparing: "loading"
        case .ready: "ready"
        case .failed(let message): "failed: \(message)"
        }
    }

    private static func describe(_ status: KeyStatus) -> String {
        switch status {
        case .missing: "missing"
        case .checking: "checking"
        case .valid(let info): "valid" + (info.limitRemaining.map { " · $\(String(format: "%.2f", $0)) left" } ?? "")
        case .invalid(let message): "rejected (\(message))"
        case .noCredit: "no credit"
        case .offline: "offline"
        case .failed(let message): "check failed (\(message))"
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        TranscriptionService.seconds(start.duration(to: .now))
    }

    private static func format(_ value: Double, digits: Int = 2) -> String {
        String(format: "%.\(digits)f", value)
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
