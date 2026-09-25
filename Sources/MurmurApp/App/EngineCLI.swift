import Foundation

/// Headless engine checks, dispatched by MurmurMain before the app starts:
///
///     Murmur --transcribe <audio file> --engine parakeet|whisper|geminiFlash|geminiPro
///            [--download] [--language <iso>] [--prompt <text>] [--repeat <n>]
///     Murmur --model-status
///
/// Uses the real model folder (~/Library/Application Support/Murmur) and the real pipeline
/// (ModelStore → InferenceGate → engine, or OpenRouterClient). Cloud engines read the key from
/// OPENROUTER_API_KEY, else from the Keychain. Settings are in-memory: the CLI never changes the app's.
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
        } catch let error as MurmurError {
            printError("ERROR: \(error.code): \(error.localizedDescription)")
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
        usage: Murmur --transcribe <audio file> --engine parakeet|whisper|geminiFlash|geminiPro \
        [--download] [--language <iso>] [--prompt <text>] [--repeat <n>]
               Murmur --model-status
        """

        var file: URL
        var engine: EngineID
        var download: Bool
        var language: String?
        var prompt: String?
        var repeatCount: Int

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
            language = value("--language")
            prompt = value("--prompt")
            repeatCount = max(1, min(20, value("--repeat").flatMap(Int.init) ?? 1))
        }

        static func engine(named name: String) -> EngineID? {
            if let id = EngineID(rawValue: name) { return id }
            switch name.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "") {
            case "parakeet": return .parakeet
            case "whisper": return .whisper
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

        let paths = AppPaths.live()
        let settings = AppSettings.inMemory()
        settings.selectedEngine = options.engine
        settings.whisperLanguage = options.language
        settings.geminiSystemPrompt = options.prompt ?? ""
        let store = ModelStore(paths: paths, settings: settings)
        let client = OpenRouterClient()
        let account = OpenRouterAccount(keychain: .inMemory(), client: client)
        let service = TranscriptionService(models: store, account: account, client: client, settings: settings)

        if options.engine.isLocal {
            try paths.ensureDirectories()
            ParakeetEngine.quietLibraryLogging()
            let code = try await prepareLocal(options, store: store)
            guard code == ExitCode.ok else { return code }
        } else {
            guard let key = cloudKey() else { throw MurmurError.openRouterMissingKey }
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
            print(line)
            last = result
        }
        if let last {
            print("TEXT: \(last.text)")
            if let best = runTimes.min() { print("TRANSCRIBE: first \(format(runTimes[0], digits: 3)) s · best \(format(best, digits: 3)) s") }
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
                throw MurmurError.modelNotDownloaded(id)
            }
            let started = ContinuousClock.now
            store.download(id)
            try await waitForDownload(store, id)
            if let error = store.lastErrors[id] { throw error }
            if case .failed(let message) = store.state(of: id) { throw MurmurError.downloadFailed(id, message) }
            let elapsed = seconds(since: started)
            let size = Fmt.bytes(id.approxDownloadBytes ?? 0)
            print("DOWNLOAD: done · \(size) in \(format(elapsed)) s")
        }

        switch store.state(of: id) {
        case .installed, .failed: store.prepare(id)
        case .notInstalled, .downloading, .preparing, .ready: break
        }
        if store.state(of: id).isPreparing {
            print("PREPARE: loading \(id.shortName)… (Core ML optimizes a new model or app build for this Mac once; that can take minutes)")
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
            throw store.lastErrors[id] ?? MurmurError.modelLoadFailed(id, message)
        case .notInstalled:
            throw MurmurError.modelNotDownloaded(id)
        default:
            throw MurmurError.modelLoadFailed(id, "Unexpected state: \(stateLine(store.state(of: id), id))")
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

    // MARK: Model status

    @MainActor
    private static func printModelStatus() async {
        let paths = AppPaths.live()
        print("Murmur models · \(paths.root.path)")
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
