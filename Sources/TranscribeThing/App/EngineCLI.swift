import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// Headless engine checks, dispatched by TranscribeThingMain before the app starts:
///
///     transcribe-thing --transcribe <audio file>
///            --engine parakeet|parakeetCloud|geminiFlash
///            [--download] [--prompt <text>] [--repeat <n>] [--effort low|medium|high]
///            [--upload wav|m4a|flac]
///            [--clean-up [--clean-up-model gpt6Luna] [--clean-up-prompt <text>]
///                        [--clean-up-effort none|minimal|low|medium|high]]
///     transcribe-thing --model-status
///
/// Hidden diagnostic (not in the usage text): `--parakeet-compute ane|gpu` loads the local model on other Core ML
/// compute units. Core ML specializes and caches the model per compute unit, so the first run with a new choice
/// is a cold load, and it can evict the default Neural Engine build (the next default load is cold again).
///
/// Uses the real model folder (~/Library/Application Support/transcribe-thing) and the real pipeline
/// (ModelStore → InferenceGate → engine, or OpenRouterClient). Cloud engines read the key from
/// OPENROUTER_API_KEY, else from the app's key file (`keyStore`), never the Keychain; cloud Parakeet also prints the
/// provider that served the request.
/// `--prompt` and `--effort` apply to Gemini only: `--effort` replaces Gemini 3.8 Flash's fixed medium and is sent as
/// given. Without `--prompt` Gemini gets the app's fixed prompt (`EngineID.geminiSystemPrompt`); `--prompt ""` sends
/// only the audio.
/// The audio file may be anything AVFoundation reads (.wav, .m4a…). A cloud model gets it as the app sends a
/// recording: Gemini as AAC in an .m4a (an .m4a that is AAC at 32 kbps, 16 kHz mono, as History keeps a recording,
/// goes as it is, like History's own file), cloud Parakeet as FLAC. `--upload` (cloud models only) sends that format
/// instead, for comparing them: WAV (16-bit), .m4a (AAC at 32 kbps) or FLAC (the WAV's samples, losslessly), all
/// 16 kHz mono; a refusal of it fails the run instead of going again as WAV. Each run prints, after its `RUN` line,
/// what went up (`UPLOAD:` format and bytes, per segment for Parakeet) and what the app records of it (`USAGE:`
/// tokens, billed seconds, cost, provider, generation id, time to first token, generation and total time), asking
/// OpenRouter's generation record (every segment's, for Parakeet) for what the response left out.
/// `--clean-up` sends the last transcript to the clean-up model (GPT-6 Luna; `--clean-up-effort` replaces its fixed
/// none) with the app's clean-up prompt (`CleanupModel.systemPrompt`, unless `--clean-up-prompt` replaces it) and
/// prints the cleaned text. Only the models the app offers are accepted. Settings are in-memory: the CLI never
/// changes the app's.
/// An engine that answers with no text heard no speech: that prints `NO SPEECH` instead of `TEXT:` and exits 0,
/// like any other answer. Only real failures print `ERROR:` and exit non-zero.
///
/// Hidden benchmark (not in the usage text), for comparing clean-up models on real dictations:
///
///     transcribe-thing --cleanup-bench --history <history.json> --model <openrouter slug> --effort <level>
///            [--count <n> | --entry <id>] [--provider <slug>] [--out <report.json>]
///
/// See `CleanupBench`. It reads the history file only, never the app's settings, and pays for `--count` requests.
///
/// Hidden check (not in the usage text) of how History keeps a recording, free, with no model and no key:
///
///     transcribe-thing --recompress <in.wav | in.m4a> <out.m4a>
///
/// Does to `<in>` what converting an older build's WAV does (`RecordingFile.compress`): reads it as History reads a
/// recording, encodes it as History saves one (AAC-LC, 32 kbps, 16 kHz mono) into `<out.m4a>`, and reads that back.
/// Prints both lengths, sizes and levels and the output's format; exits 1, with `<out.m4a>` removed, when the lengths
/// differ by more than `RecordingFile.lengthTolerance`. Writes nothing but `<out.m4a>` (replaced if it's there), and
/// never reads the app's settings, history or recordings.
enum EngineCLI {
    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains("--transcribe") || arguments.contains("--model-status")
            || arguments.contains(CleanupBench.flag) || arguments.contains(Recompress.flag)
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
        if arguments.contains(CleanupBench.flag) {
            return await runCleanupBench(arguments)
        }
        if arguments.contains(Recompress.flag) {
            return await recompress(arguments)
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

    struct Options: Equatable {
        static let usage = """
        usage: transcribe-thing --transcribe <audio file> \
        --engine parakeet|parakeetCloud|geminiFlash \
        [--download] [--prompt <text>] [--repeat <n>] [--effort low|medium|high] [--upload wav|m4a|flac] \
        [--clean-up [--clean-up-model gpt6Luna] [--clean-up-prompt <text>] \
        [--clean-up-effort none|minimal|low|medium|high]]
               transcribe-thing --model-status
        """

        var file: URL
        var engine: EngineID
        var download: Bool
        var prompt: String?
        var repeatCount: Int
        var parakeetCompute: ParakeetCompute?
        var effort: ReasoningEffort?
        /// The format a cloud model gets the audio in instead of its own.
        var upload: UploadFormat?
        var cleanUp: Bool
        var cleanupPrompt: String?
        var cleanupEffort: ReasoningEffort?
        var cleanupModel: CleanupModel?

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
            if arguments.contains("--upload") {
                guard engine.isCloud, let format = value("--upload").flatMap(UploadFormat.init(rawValue:)) else {
                    return nil
                }
                upload = format
            }
            cleanUp = arguments.contains("--clean-up")
            cleanupPrompt = value("--clean-up-prompt")
            if arguments.contains("--clean-up-effort") {
                guard let level = value("--clean-up-effort").flatMap(ReasoningEffort.init(rawValue:)) else { return nil }
                cleanupEffort = level
            }
            if arguments.contains("--clean-up-model") {
                guard let name = value("--clean-up-model"),
                      let model = CleanupModel.offered.first(where: { $0.rawValue == name }) else { return nil }
                cleanupModel = model
            }
            if arguments.contains("--parakeet-compute") {
                guard let preset = value("--parakeet-compute").flatMap(ParakeetCompute.init(rawValue:)) else { return nil }
                parakeetCompute = preset
            }
        }

        /// An engine the app offers, by raw value or a loose spelling of it; nil for a retired one.
        static func engine(named name: String) -> EngineID? {
            if let id = EngineID.offered.first(where: { $0.rawValue == name }) { return id }
            switch name.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "") {
            case "parakeet": return .parakeet
            case "parakeetcloud", "cloudparakeet": return .parakeetCloud
            case "geminiflash", "flash": return .geminiFlash
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
        if options.engine.isParakeet { settings.parakeetEngine = options.engine }
        // Gemini's own level unless --effort replaces it; nothing for a model that doesn't reason.
        let effort = options.engine.reasoningEffort.map { options.effort ?? $0 }
        if let effort { print("EFFORT: \(effort.rawValue)") }
        var engines = ModelStore.makeEngines(paths: paths)
        if options.parakeetCompute == .gpu {
            engines[.parakeet] = ParakeetEncoderOnGPU(modelsRoot: paths.models)
        }
        let store = ModelStore(paths: paths, settings: settings, engines: engines, gate: .shared,
                               freeDiskBytes: { paths.freeDiskBytes() })
        let client = OpenRouterClient()
        // A copy of the key in memory: nothing the run does changes the app's key file.
        let account = OpenRouterAccount(keyStore: .inMemory(), client: client)
        let service = TranscriptionService(models: store, account: account, client: client)

        if options.engine.isLocal {
            try paths.ensureDirectories()
            ParakeetEngine.quietLibraryLogging()
            let code = try await prepareLocal(options, store: store)
            guard code == ExitCode.ok else { return code }
        }
        if options.engine.isCloud || options.cleanUp {
            let key: String?
            do {
                key = try keyStore(paths: paths).lookup()
            } catch {
                throw AppError.openRouterKeyUnreadable
            }
            guard let key else { throw AppError.openRouterMissingKey }
            await account.setKey(key)
            print("KEY: \(account.maskedKey ?? "?") · \(describe(account.status))")
        }

        var recording = Recording(samples: samples)
        if options.engine.isCloud, isKeptLikeHistory(url) { recording.aacFile = url }
        var last: TranscriptResult?
        var runTimes: [TimeInterval] = []
        for run in 1...options.repeatCount {
            var result = try await service.transcribe(recording, engine: options.engine, effort: effort,
                                                      prompt: options.prompt, upload: options.upload)
            runTimes.append(result.processingTime)
            let speed = result.processingTime > 0 ? audioSeconds / result.processingTime : 0
            var line = "RUN \(run): \(format(result.processingTime, digits: 3)) s · \(format(speed, digits: 1))x real time"
            if let cost = result.costUSD { line += " · $\(String(format: "%.5f", cost))" }
            if let reasoning = result.usage?.reasoningTokens { line += " · \(reasoning) reasoning tokens" }
            print(line)
            if options.engine.isCloud {
                await fillFromGenerationRecord(&result, service: service)
                if let upload = uploadLine(result.uploads, input: recording.aacFile) { print(upload) }
                print(usageLine(result))
            }
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
            if let tags = last.answerTags { print("TAGS: \(tags.rawValue)") }
            if let best = runTimes.min() { print("TRANSCRIBE: first \(format(runTimes[0], digits: 3)) s · best \(format(best, digits: 3)) s") }
            if options.cleanUp, !last.text.isEmpty {
                let model = options.cleanupModel ?? .default
                let route = options.cleanupEffort.map(model.route(effort:))
                let cleaned = try await service.cleanUp(last.text, of: last.engine, by: model, route: route,
                                                        prompt: options.cleanupPrompt)
                let level = cleaned.reasoningEffort?.rawValue ?? "?"
                var line = "CLEAN-UP: \(model.modelName) · \(level) · \(format(cleaned.processingTime, digits: 3)) s"
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

    /// Where a run reads the key: OPENROUTER_API_KEY when it's set (in memory only), else the app's key file. Never the
    /// Keychain, so no run waits on a password prompt.
    static func keyStore(environment: [String: String] = ProcessInfo.processInfo.environment,
                         paths: AppPaths = .live()) -> KeyFileStore {
        if let env = environment["OPENROUTER_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return .inMemory(env)
        }
        return KeyFileStore(url: paths.keyFile)
    }

    /// An .m4a holding AAC at 32 kbps, 16 kHz mono, as History keeps a recording (`RecordingFile`): Gemini gets it as
    /// it is, as it gets History's own file (`Recording.aacFile`). One at another rate is encoded like any other file.
    static func isKeptLikeHistory(_ url: URL) -> Bool {
        guard RecordingFile.isAAC(url.lastPathComponent), let file = try? AVAudioFile(forReading: url) else {
            return false
        }
        let format = file.fileFormat
        return format.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC
            && format.sampleRate == Recording.sampleRate && format.channelCount == 1
            && encodedBitRate(of: url) == RecordingFile.bitRate
    }

    /// The bit rate an .m4a's AAC was encoded at (`averageBitRate(esDescriptor:)` of its magic cookie). The rate
    /// measured over the file can't tell 24 from 32 kbps in a short one. nil when the file has no such cookie.
    static func encodedBitRate(of url: URL) -> Int? {
        var opened: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &opened) == noErr, let file = opened else { return nil }
        defer { AudioFileClose(file) }
        var size: UInt32 = 0
        guard AudioFileGetPropertyInfo(file, kAudioFilePropertyMagicCookieData, &size, nil) == noErr, size > 0 else {
            return nil
        }
        var cookie = [UInt8](repeating: 0, count: Int(size))
        guard AudioFileGetProperty(file, kAudioFilePropertyMagicCookieData, &size, &cookie) == noErr else { return nil }
        return averageBitRate(esDescriptor: Array(cookie.prefix(Int(size))))
    }

    /// The `avgBitrate` of an MPEG-4 ES_Descriptor's decoder configuration (ISO/IEC 14496-1), the cookie an .m4a
    /// keeps its AAC's setup in: the encoder writes its target bit rate there. nil for anything else.
    static func averageBitRate(esDescriptor bytes: [UInt8]) -> Int? {
        var at = 0
        /// The next `count` bytes as a big-endian number, or nil past the end.
        func read(_ count: Int) -> Int? {
            guard at + count <= bytes.count else { return nil }
            defer { at += count }
            return bytes[at..<at + count].reduce(0) { $0 << 8 | Int($1) }
        }
        /// A descriptor's tag, leaving `at` at its contents: its size takes 1 to 4 bytes of 7 bits each.
        func tag() -> Int? {
            guard let tag = read(1) else { return nil }
            for _ in 0..<4 {
                guard let byte = read(1) else { return nil }
                if byte & 0x80 == 0 { break }
            }
            return tag
        }
        // ES_Descriptor: ES_ID, flags, and the fields its flags announce (dependsOn_ES_ID, URL, OCR_ES_Id).
        guard tag() == 0x03, read(2) != nil, let flags = read(1),
              flags & 0x80 == 0 || read(2) != nil,
              flags & 0x40 == 0 || read(1).flatMap(read) != nil,
              flags & 0x20 == 0 || read(2) != nil else { return nil }
        // DecoderConfigDescriptor: object type, stream type, buffer size and maxBitrate, then avgBitrate.
        guard tag() == 0x04, read(1) != nil, read(1) != nil, read(3) != nil, read(4) != nil else { return nil }
        return read(4)
    }

    /// Asks OpenRouter's generation record, as the app does (`DictationController`), for what the response left out:
    /// the provider, the cost, the generation time (which a speech-to-text answer never carries, so Parakeet's is
    /// always asked). A recording Parakeet heard in segments asks each segment's generation, and adds up their costs
    /// and times only when every segment's record came with its own.
    @MainActor
    static func fillFromGenerationRecord(_ result: inout TranscriptResult, service: TranscriptionService) async {
        guard result.provider == nil || result.costUSD == nil || result.generationTime == nil else { return }
        let ids = result.uploads.count > 1 ? result.uploads.map(\.generationID) : [result.generationID]
        var records: [GenerationDetails] = []
        for id in ids {
            guard let id, let details = await service.generationDetails(generationID: id) else { break }
            records.append(details)
        }
        guard let first = records.first else { return }
        /// The sum of every segment's value, or nil when one of them is missing.
        func total(_ values: [Double?]) -> Double? {
            guard records.count == ids.count, !values.contains(nil) else { return nil }
            return values.reduce(0) { $0 + ($1 ?? 0) }
        }
        result.provider = result.provider ?? records.lazy.compactMap(\.provider).first
        result.costUSD = result.costUSD ?? total(records.map(\.costUSD))
        result.generationTime = result.generationTime ?? total(records.map(\.generationTime))
        if let reasoning = first.reasoningTokens, result.usage?.reasoningTokens == nil {
            var usage = result.usage ?? TokenUsage()
            usage.reasoningTokens = reasoning
            result.usage = usage
        }
    }

    /// "UPLOAD: m4a · 123456 bytes", or per segment for Parakeet ("UPLOAD: 3 segments · flac 4801234 + … · 9876543
    /// bytes in all"); nil when nothing went up. `input` is the audio file, when it went as it is.
    static func uploadLine(_ uploads: [AudioUpload], input: URL?) -> String? {
        guard let first = uploads.first else { return nil }
        guard uploads.count > 1 else {
            let asIs = input.flatMap { RecordingFile.Stamp($0)?.size } == first.bytes && first.format == .m4a
            return "UPLOAD: \(first.format.rawValue) · \(first.bytes) bytes" + (asIs ? " · the input file as is" : "")
        }
        let files = uploads.map { "\($0.format.rawValue) \($0.bytes)" }.joined(separator: " + ")
        return "UPLOAD: \(uploads.count) segments · \(files) · \(uploads.reduce(0) { $0 + $1.bytes }) bytes in all"
    }

    /// "USAGE: …": what History keeps of a cloud result. Tokens and the time to the first token for a chat answer,
    /// billed seconds for speech-to-text; "?" for what OpenRouter didn't say.
    static func usageLine(_ result: TranscriptResult) -> String {
        func known<T>(_ value: T?, _ describe: (T) -> String = { "\($0)" }) -> String { value.map(describe) ?? "?" }
        var parts: [String] = []
        if result.engine.cloudAPI == .chatCompletions {
            let usage = result.usage
            parts.append("tokens audio \(known(usage?.audioTokens)) · prompt \(known(usage?.promptTokens)) · "
                         + "completion \(known(usage?.completionTokens)) · reasoning \(known(usage?.reasoningTokens))")
        } else {
            parts.append("audio \(known(result.audioSeconds) { format($0) }) s billed")
        }
        parts.append("cost \(known(result.costUSD) { "$" + String(format: "%.6f", $0) })")
        parts.append("provider \(known(result.provider))")
        parts.append("generation \(known(result.generationID))")
        if result.engine.cloudAPI == .chatCompletions {
            parts.append("first token \(known(result.timeToFirstToken) { format($0, digits: 3) }) s")
        }
        parts.append("generated in \(known(result.generationTime) { format($0, digits: 3) }) s")
        parts.append("total \(format(result.processingTime, digits: 3)) s")
        return "USAGE: " + parts.joined(separator: " · ")
    }

    // MARK: Clean-up bench

    @MainActor
    private static func runCleanupBench(_ arguments: [String]) async -> Int32 {
        guard let options = CleanupBench.Options(arguments) else {
            printError(CleanupBench.Options.usage)
            return ExitCode.usage
        }
        let entries: [TranscriptEntry]
        do {
            entries = try HistoryStore.readEntries(from: Data(contentsOf: options.history))
        } catch {
            printError("ERROR: couldn’t read \(options.history.path): \(error.localizedDescription)")
            return ExitCode.failed
        }
        let items = CleanupBench.select(options.entry.map { id in entries.filter { $0.id == id } } ?? entries,
                                        count: options.count)
        guard !items.isEmpty else {
            printError("ERROR: no entry in \(options.history.path) has a Parakeet transcript")
            return ExitCode.failed
        }

        // The key as the app reads it: OpenRouterAccount over its key file (OPENROUTER_API_KEY wins when set).
        // Nothing about the key is printed.
        let client = OpenRouterClient()
        let keyStore = keyStore()
        let account = OpenRouterAccount(keyStore: keyStore, client: client)
        guard account.apiKey() != nil else {
            if account.isKeyUnreadable {
                printError("ERROR: key file: \(OpenRouterAccount.keyUnreadableMessage)")
            } else {
                printError("ERROR: no OpenRouter key: set OPENROUTER_API_KEY or add the key in the app")
            }
            return ExitCode.failed
        }
        print("KEY: read from \(keyStore.isInMemory ? "OPENROUTER_API_KEY" : "the key file")")

        let store = ModelStore(paths: .temporary(), settings: .inMemory(), engines: [:], gate: .shared,
                               freeDiskBytes: { 0 })
        let service = TranscriptionService(models: store, account: account, client: client)
        let route = options.route
        print("BENCH: \(route.model) · effort \(route.effort) · provider \(route.provider.only.joined(separator: ",")) · \(items.count) dictations")

        let startedAt = Date()
        let rows = await CleanupBench.run(items, route: route, service: service) { index, row in
            var line = "[\(index + 1)/\(items.count)] \(row.wallMs) ms"
            if let generation = row.generationMs { line += " · gen \(generation) ms" }
            if let cost = row.costUSD { line += " · $\(String(format: "%.6f", cost))" }
            if let tokens = row.completionTokens { line += " · \(tokens) out" }
            if let reasoning = row.reasoningTokens, reasoning > 0 { line += " · \(reasoning) reasoning" }
            if let provider = row.provider { line += " · \(provider)" }
            if let tier = row.serviceTier { line += " · \(tier)" }
            if let error = row.error { line += " · ERROR \(error)" } else if row.identical == true { line += " · unchanged" }
            print(line)
        }
        let report = CleanupBench.Report(model: route.model, provider: route.provider.only, effort: route.effort,
                                         maxTokensSizedFor: route.budget.rawValue, prompt: "CleanupModel.systemPrompt",
                                         history: options.history.path, startedAt: startedAt, items: rows,
                                         summary: CleanupBench.summarize(rows))
        let summary = report.summary
        print("SUMMARY: \(summary.succeeded)/\(summary.count) ok · median \(summary.medianWallMs.map(String.init) ?? "-") ms · p90 \(summary.p90WallMs.map(String.init) ?? "-") ms · $\(String(format: "%.6f", summary.totalCostUSD)) total · \(summary.identicalToInput) unchanged")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            if let out = options.out {
                try data.write(to: out, options: .atomic)
                print("REPORT: \(out.path)")
            } else {
                print(String(decoding: data, as: UTF8.self))
            }
        } catch {
            printError("ERROR: couldn’t write the report: \(error.localizedDescription)")
            return ExitCode.failed
        }
        return summary.succeeded > 0 ? ExitCode.ok : ExitCode.failed
    }

    /// `--cleanup-bench`: the most recent Parakeet transcripts of a history file, each cleaned up once by another
    /// model through the app's own clean-up request (`TranscriptionService.cleanUp` with a `CleanupRoute`: the
    /// app's clean-up prompt as the system message, the transcript in `<transcript>` tags, reasoning excluded,
    /// `max_tokens` sized like the app's, the provider pinned without fallbacks), one after another. The report
    /// keeps each input and output with its timing, tokens and cost, next to the entry's Gemini 3.8 Flash
    /// transcript and its existing Flash Lite clean-up, when it has them.
    enum CleanupBench {
        static let flag = "--cleanup-bench"

        struct Options: Equatable {
            static let usage = """
            usage: transcribe-thing --cleanup-bench --history <history.json> --model <openrouter slug> \
            --effort none|minimal|low|medium|high|xhigh|max [--count <n> | --entry <id>] [--provider <slug>] \
            [--out <report.json>]
            """
            static let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
            static let defaultCount = 20
            static let maxCount = 200

            var history: URL
            var count: Int
            /// Just this entry, whatever its age.
            var entry: UUID?
            var route: CleanupRoute
            var out: URL?

            init?(_ arguments: [String]) {
                func value(_ flag: String) -> String? {
                    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
                    let value = arguments[index + 1]
                    return value.hasPrefix("--") ? nil : value
                }
                guard arguments.contains(CleanupBench.flag), let path = value("--history"),
                      let model = value("--model")?.trimmingCharacters(in: .whitespaces), model.contains("/"),
                      let effort = value("--effort")?.lowercased(), Self.efforts.contains(effort)
                else { return nil }
                history = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                if arguments.contains("--entry") {
                    guard let id = value("--entry").flatMap(UUID.init(uuidString:)) else { return nil }
                    entry = id
                }
                if arguments.contains("--count") {
                    guard let count = value("--count").flatMap(Int.init), (1...Self.maxCount).contains(count) else {
                        return nil
                    }
                    self.count = count
                } else {
                    count = Self.defaultCount
                }
                let provider: String
                if arguments.contains("--provider") {
                    guard let name = value("--provider"), !name.isEmpty else { return nil }
                    provider = name
                } else {
                    guard let name = Self.provider(forModel: model) else { return nil }
                    provider = name
                }
                route = CleanupRoute(model: model,
                                     provider: .init(only: [provider], allowFallbacks: false),
                                     effort: effort, budget: Self.budget(for: effort))
                out = value("--out").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            }

            /// The first-party provider each model is pinned to, like the app pins Gemini to Google AI Studio.
            static func provider(forModel model: String) -> String? {
                if model.hasPrefix("google/") { return "google-ai-studio" }
                if model.hasPrefix("openai/") { return "openai" }
                return nil
            }

            /// The `ReasoningEffort` that sizes `max_tokens`: "none" gets the least room (as much as minimal),
            /// levels above high the most.
            static func budget(for effort: String) -> ReasoningEffort {
                ReasoningEffort(rawValue: effort) ?? .high
            }
        }

        struct Item: Equatable, Sendable {
            var id: UUID
            var createdAt: Date
            var parakeet: String
            /// The entry's Gemini 3.8 Flash transcript, as a reference.
            var geminiFlash: String?
            /// The entry's existing Flash Lite clean-up of the Parakeet text, and the level it thought at.
            var flashLite: String?
            var flashLiteEffort: String?
        }

        /// The `count` most recent entries with a non-empty Parakeet (on this Mac) transcript, newest first.
        static func select(_ entries: [TranscriptEntry], count: Int) -> [Item] {
            let items = entries.sorted { $0.createdAt > $1.createdAt }.compactMap { entry -> Item? in
                guard entry.status == .success, let parakeet = entry.version(.transcription(.parakeet)) else {
                    return nil
                }
                let text = parakeet.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let cleanup = entry.version(.cleanup(of: .parakeet, by: .geminiFlashLite))
                return Item(id: entry.id, createdAt: entry.createdAt, parakeet: text,
                            geminiFlash: entry.version(.transcription(.geminiFlash))?.text,
                            flashLite: cleanup?.text, flashLiteEffort: cleanup?.metadata.reasoningEffort?.rawValue)
            }
            return Array(items.prefix(max(0, count)))
        }

        struct Row: Codable, Equatable, Sendable {
            var entryID: UUID
            var createdAt: Date
            var input: String
            var inputCharacters: Int
            var output: String?
            /// The output is the input unchanged (nil after a failure).
            var identical: Bool?
            /// Wall clock on this Mac around the whole request, retry included.
            var wallMs: Int
            /// OpenRouter's `openrouter_metadata.generation_time`.
            var generationMs: Int?
            var promptTokens: Int?
            var completionTokens: Int?
            var reasoningTokens: Int?
            var costUSD: Double?
            var finishReason: String?
            var provider: String?
            var serviceTier: String?
            var model: String?
            var generationID: String?
            var error: String?
            var referenceGeminiFlash: String?
            var existingFlashLite: String?
            var existingFlashLiteEffort: String?
        }

        struct Summary: Codable, Equatable, Sendable {
            var count: Int
            var succeeded: Int
            var failures: Int
            var identicalToInput: Int
            var medianWallMs: Int?
            var p90WallMs: Int?
            var meanWallMs: Int?
            var medianGenerationMs: Int?
            var meanPromptTokens: Double?
            var meanCompletionTokens: Double?
            var meanReasoningTokens: Double?
            var totalCostUSD: Double
            /// Total cost over the dictations that succeeded.
            var costPerDictationUSD: Double?
            var providers: [String]
            var serviceTiers: [String]
        }

        struct Report: Codable, Sendable {
            var model: String
            var provider: [String]
            var effort: String
            var maxTokensSizedFor: String
            var prompt: String
            var history: String
            var startedAt: Date
            var items: [Row]
            var summary: Summary
        }

        /// Cleans up every item in turn; a failure becomes a row with `error`, and the run goes on.
        @MainActor
        static func run(_ items: [Item], route: CleanupRoute, service: TranscriptionService,
                        progress: (Int, Row) -> Void = { _, _ in }) async -> [Row] {
            var rows: [Row] = []
            for (index, item) in items.enumerated() {
                var row = Row(entryID: item.id, createdAt: item.createdAt, input: item.parakeet,
                              inputCharacters: item.parakeet.count, wallMs: 0, referenceGeminiFlash: item.geminiFlash,
                              existingFlashLite: item.flashLite, existingFlashLiteEffort: item.flashLiteEffort)
                let started = ContinuousClock.now
                do {
                    let result = try await service.cleanUp(item.parakeet, of: .parakeet, route: route)
                    row.wallMs = milliseconds(started.duration(to: .now))
                    row.output = result.text
                    row.identical = result.text == item.parakeet
                    row.generationMs = result.generationTime.map { Int(($0 * 1000).rounded()) }
                    row.promptTokens = result.usage?.promptTokens
                    row.completionTokens = result.usage?.completionTokens
                    row.reasoningTokens = result.usage?.reasoningTokens
                    row.costUSD = result.costUSD
                    row.finishReason = result.finishReason
                    row.provider = result.provider
                    row.serviceTier = result.serviceTier
                    row.model = result.modelID
                    row.generationID = result.generationID
                } catch let error as AppError {
                    row.wallMs = milliseconds(started.duration(to: .now))
                    row.error = [error.code, error.detail].compactMap { $0 }.joined(separator: ": ")
                } catch {
                    row.wallMs = milliseconds(started.duration(to: .now))
                    row.error = String(describing: error)
                }
                progress(index, row)
                rows.append(row)
            }
            return rows
        }

        static func summarize(_ rows: [Row]) -> Summary {
            let ok = rows.filter { $0.error == nil }
            let walls = ok.map(\.wallMs).sorted()
            let generations = ok.compactMap(\.generationMs).sorted()
            func mean(_ values: [Int]) -> Double? {
                values.isEmpty ? nil : Double(values.reduce(0, +)) / Double(values.count)
            }
            let total = rows.compactMap(\.costUSD).reduce(0, +)
            return Summary(
                count: rows.count, succeeded: ok.count, failures: rows.count - ok.count,
                identicalToInput: ok.filter { $0.identical == true }.count,
                medianWallMs: median(walls), p90WallMs: percentile(walls, 0.9),
                meanWallMs: mean(walls).map { Int($0.rounded()) }, medianGenerationMs: median(generations),
                meanPromptTokens: mean(ok.compactMap(\.promptTokens)),
                meanCompletionTokens: mean(ok.compactMap(\.completionTokens)),
                meanReasoningTokens: mean(ok.compactMap(\.reasoningTokens)),
                totalCostUSD: total, costPerDictationUSD: ok.isEmpty ? nil : total / Double(ok.count),
                providers: Array(Set(ok.compactMap(\.provider))).sorted(),
                serviceTiers: Array(Set(ok.compactMap(\.serviceTier))).sorted())
        }

        /// The middle value of sorted `values` (the mean of the two middle ones for an even count).
        static func median(_ values: [Int]) -> Int? {
            guard !values.isEmpty else { return nil }
            let mid = values.count / 2
            return values.count.isMultiple(of: 2) ? Int((Double(values[mid - 1] + values[mid]) / 2).rounded()) : values[mid]
        }

        /// Nearest-rank percentile of sorted `values`.
        static func percentile(_ values: [Int], _ fraction: Double) -> Int? {
            guard !values.isEmpty else { return nil }
            let rank = Int((fraction * Double(values.count)).rounded(.up))
            return values[min(values.count, max(1, rank)) - 1]
        }

        private static func milliseconds(_ duration: Duration) -> Int {
            Int((TranscriptionService.seconds(duration) * 1000).rounded())
        }
    }

    // MARK: Recompress

    /// `--recompress <in> <out.m4a>`: see the type's comment.
    enum Recompress {
        static let flag = "--recompress"
        static let usage = "usage: transcribe-thing --recompress <in.wav | in.m4a> <out.m4a>"

        /// The input and the output named after the flag; nil unless the output is another file, an .m4a.
        static func files(_ arguments: [String]) -> (input: URL, output: URL)? {
            guard let index = arguments.firstIndex(of: flag), index + 2 < arguments.count else { return nil }
            let paths = arguments[(index + 1)...(index + 2)]
            guard !paths.contains(where: { $0.hasPrefix("--") }) else { return nil }
            let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
            guard urls[1].pathExtension.lowercased() == "m4a", urls[0] != urls[1] else { return nil }
            return (urls[0], urls[1])
        }
    }

    private static func recompress(_ arguments: [String]) async -> Int32 {
        guard let (input, output) = Recompress.files(arguments) else {
            printError(Recompress.usage)
            return ExitCode.usage
        }
        guard FileManager.default.fileExists(atPath: input.path) else {
            printError("ERROR: no such file: \(input.path)")
            return ExitCode.usage
        }
        let started = ContinuousClock.now
        let check: RecordingFile.Check
        do {
            check = try await Task.detached(priority: .userInitiated) {
                try RecordingFile.compress(input, into: output)
            }.value
        } catch {
            printError("ERROR: \(error.localizedDescription)")
            return ExitCode.failed
        }
        let elapsed = seconds(since: started)
        func bytes(_ url: URL) -> Int64 {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        func line(_ url: URL, samples: Int, rms: Float) -> String {
            let dbfs = rms > 0 ? 20 * log10(rms) : -160
            return "\(url.lastPathComponent) · \(format(Double(samples) / Recording.sampleRate, digits: 3)) s · "
                + "\(samples) samples · \(Fmt.bytes(bytes(url))) · RMS \(format(Double(dbfs), digits: 1)) dBFS"
        }
        print("IN: \(line(input, samples: check.sourceSamples, rms: check.sourceRMS))")
        print("OUT: \(line(output, samples: check.outputSamples, rms: check.outputRMS))")
        if let file = try? AVAudioFile(forReading: output) {
            let fileFormat = file.fileFormat
            let codec = fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC ? "AAC" : "not AAC"
            let seconds = Double(check.outputSamples) / Recording.sampleRate
            let kbps = seconds > 0 ? Double(bytes(output)) * 8 / seconds / 1000 : 0
            print("FORMAT: \(codec) · \(Int(fileFormat.sampleRate)) Hz · \(fileFormat.channelCount) channel(s) · "
                  + "\(format(kbps, digits: 1)) kbps with the container")
        }
        let tolerance = Int(RecordingFile.lengthTolerance * Recording.sampleRate)
        print("CHECK: lengths differ by \(abs(check.outputSamples - check.sourceSamples)) samples (at most "
              + "\(tolerance)) · encoded and read back in \(format(elapsed)) s")
        return ExitCode.ok
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
        print("OpenRouter key: \(envKey ? "OPENROUTER_API_KEY is set" : "not in the environment (the app keeps it in \(paths.keyFile.path))")")
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
