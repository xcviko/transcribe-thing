import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// Headless engine checks, dispatched by TranscribeThingMain before the app starts:
///
///     transcribe-thing --transcribe <audio file>
///            --engine parakeet|geminiFlash|geminiArgon
///            [--download] [--prompt <text>] [--repeat <n>] [--effort low|medium|high]
///            [--upload wav|m4a]
///     transcribe-thing --model-status
///
/// Hidden comparison (not in the usage text): `--provider <slug>` sends Gemini to another endpoint than Google AI
/// Studio's ("google-ai-studio/priority"), pinned without fallbacks.
///
/// Hidden comparison (not in the usage text): `--hedge race|measure` sends a cloud engine's request twice at once, as
/// dictations do (`CloudHedge`); `measure` lets both run to their end and prints both times (`HEDGE:`).
///
/// Hidden diagnostic (not in the usage text): `--parakeet-compute ane|gpu` loads the local model on other Core ML
/// compute units. Core ML specializes and caches the model per compute unit, so the first run with a new choice
/// is a cold load, and it can evict the default Neural Engine build (the next default load is cold again).
///
/// Uses the real model folder (~/Library/Application Support/transcribe-thing) and the real pipeline
/// (ModelStore → InferenceGate → engine, or OpenRouterClient). Cloud engines read the key from
/// OPENROUTER_API_KEY, else from the app's key file (`keyStore`), never the Keychain.
/// `--prompt` and `--effort` apply to Gemini only: `--effort` replaces the model's default level (medium; the CLI
/// doesn't read the level picked in the app's Models) and is sent as given. Without `--prompt` Gemini gets the app's fixed prompt (`EngineID.geminiSystemPrompt`); `--prompt ""` sends
/// only the audio.
/// The audio file may be anything AVFoundation reads (.wav, .m4a…). A cloud model gets it as the app sends a
/// recording: Gemini as AAC in an .m4a (an .m4a that is AAC at 32 kbps, 16 kHz mono, as History keeps a recording,
/// goes as it is, like History's own file). `--upload` (cloud models only) sends that format instead, for comparing
/// them: WAV (16-bit) or .m4a (AAC at 32 kbps), both 16 kHz mono. Each run prints, after its `RUN` line, what went up
/// (`UPLOAD:` format and bytes) and what the app records of it (`USAGE:` tokens, cost, provider, generation id, time
/// to first token, generation and total time), asking OpenRouter's generation record for what the response left out.
/// Settings are in-memory: the CLI never changes the app's. Gemini goes where the app sends it: through the user's
/// OpenAI-compatible endpoint when the app has one set up and on (its base URL and switch read from the app's
/// settings, its key from its key file, read only), else through OpenRouter. `--model-status` says which, never the
/// key.
/// An engine that answers with no text heard no speech: that prints `NO SPEECH` instead of `TEXT:` and exits 0,
/// like any other answer. Only real failures print `ERROR:` and exit non-zero.
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
            || arguments.contains(Recompress.flag)
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
        --engine parakeet|geminiFlash|geminiArgon \
        [--download] [--prompt <text>] [--repeat <n>] [--effort low|medium|high] [--upload wav|m4a]
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
        /// The request twice at once (`--hedge`).
        var hedge: CloudHedge?
        /// Gemini's endpoint instead of Google AI Studio's (`--provider`).
        var provider: String?
        /// A dictionary to send as the app does, one word per line (`--vocabulary`, hidden): the CLI sends none by itself.
        var vocabulary: URL?

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
            if arguments.contains("--provider") {
                guard engine.isGemini, let slug = value("--provider"), !slug.isEmpty else {
                    return nil
                }
                provider = slug
            }
            if arguments.contains("--hedge") {
                switch value("--hedge") {
                case "race" where engine.isCloud: hedge = .race
                case "measure" where engine.isCloud: hedge = .measure
                default: return nil
                }
            }
            if arguments.contains("--parakeet-compute") {
                guard let preset = value("--parakeet-compute").flatMap(ParakeetCompute.init(rawValue:)) else { return nil }
                parakeetCompute = preset
            }
            if arguments.contains("--vocabulary") {
                guard engine.isCloud, let path = value("--vocabulary") else { return nil }
                vocabulary = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
        }

        /// An engine the app offers, by raw value or a loose spelling of it; nil for a retired one.
        static func engine(named name: String) -> EngineID? {
            if let id = EngineID.offered.first(where: { $0.rawValue == name }) { return id }
            switch name.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "") {
            case "parakeet": return .parakeet
            case "geminiflash", "flash": return .geminiFlash
            case "geminiargon", "argon", "gemini4argon": return .geminiArgon
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
        // The model's default level unless --effort replaces it; nothing for a model that doesn't reason.
        let effort = options.engine.defaultReasoningEffort.map { options.effort ?? $0 }
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
        let proxy = appVertexProxy(paths: paths)
        let service = TranscriptionService(models: store, account: account, client: client, proxy: proxy)
        if let url = options.vocabulary {
            let words = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            service.vocabulary = { words }
            print("VOCABULARY: \(words.count) words")
        }

        if options.engine.isLocal {
            try paths.ensureDirectories()
            ParakeetEngine.quietLibraryLogging()
            let code = try await prepareLocal(options, store: store)
            guard code == ExitCode.ok else { return code }
        }
        let viaProxy = service.provider(for: options.engine) == .vertexProxy
        if viaProxy, let proxy {
            print("ROUTE: \(VertexProxy.label) · \(proxy.baseURL.map(VertexProxy.displayHost) ?? "?") · key \(proxy.maskedKey ?? "unreadable")")
        }
        if options.engine.isCloud, !viaProxy {
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
        var measurements = 0
        service.hedgeMeasured = { m in
            let second = m.second.map { format($0, digits: 3) + " s" } ?? "failed"
            print("HEDGE: first \(format(m.first, digits: 3)) s · second \(second)")
            measurements += 1
        }
        var last: TranscriptResult?
        var runTimes: [TimeInterval] = []
        for run in 1...options.repeatCount {
            var result = try await service.transcribe(recording, engine: options.engine, effort: effort,
                                                      prompt: options.prompt, upload: options.upload,
                                                      hedge: options.hedge,
                                                      provider: options.provider.map {
                                                          .init(only: [$0], allowFallbacks: false)
                                                      })
            runTimes.append(result.processingTime)
            // Measuring: the other request finishes before the next run, so the two runs don't overlap.
            if options.hedge == .measure {
                let deadline = ContinuousClock.now + .seconds(120)
                while measurements < run, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            }
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
            print(last.text.isEmpty ? "NO SPEECH" : "TEXT: \(last.text)")
            if let tags = last.answerTags { print("TAGS: \(tags.rawValue)") }
            // What the model wrote when that came out empty, tags and all: why it heard nothing.
            if last.text.isEmpty, let answer = last.rawAnswer { print("ANSWER: \(answer.debugDescription)") }
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
    /// the provider, the cost, the generation time, the reasoning tokens.
    @MainActor
    static func fillFromGenerationRecord(_ result: inout TranscriptResult, service: TranscriptionService) async {
        guard result.provider == nil || result.costUSD == nil || result.generationTime == nil else { return }
        guard let id = result.generationID, let record = await service.generationDetails(generationID: id) else {
            return
        }
        result.provider = result.provider ?? record.provider
        result.costUSD = result.costUSD ?? record.costUSD
        result.generationTime = result.generationTime ?? record.generationTime
        if let reasoning = record.reasoningTokens, result.usage?.reasoningTokens == nil {
            var usage = result.usage ?? TokenUsage()
            usage.reasoningTokens = reasoning
            result.usage = usage
        }
    }

    /// "UPLOAD: m4a · 123456 bytes"; nil when nothing went up. `input` is the audio file, when it went as it is.
    static func uploadLine(_ uploads: [AudioUpload], input: URL?) -> String? {
        guard let first = uploads.first else { return nil }
        let asIs = input.flatMap { RecordingFile.Stamp($0)?.size } == first.bytes && first.format == .m4a
        return "UPLOAD: \(first.format.rawValue) · \(first.bytes) bytes" + (asIs ? " · the input file as is" : "")
    }

    /// "USAGE: …": what History keeps of a cloud result: tokens and the time to the first token among the rest; "?"
    /// for what OpenRouter didn't say.
    static func usageLine(_ result: TranscriptResult) -> String {
        func known<T>(_ value: T?, _ describe: (T) -> String = { "\($0)" }) -> String { value.map(describe) ?? "?" }
        var parts: [String] = []
        let usage = result.usage
        parts.append("tokens audio \(known(usage?.audioTokens)) · prompt \(known(usage?.promptTokens)) · "
                     + "completion \(known(usage?.completionTokens)) · reasoning \(known(usage?.reasoningTokens))")
        parts.append("cost \(known(result.costUSD) { "$" + String(format: "%.6f", $0) })")
        parts.append("provider \(known(result.provider))")
        parts.append("generation \(known(result.generationID))")
        parts.append("first token \(known(result.timeToFirstToken) { format($0, digits: 3) }) s")
        parts.append("generated in \(known(result.generationTime) { format($0, digits: 3) }) s")
        parts.append("total \(format(result.processingTime, digits: 3)) s")
        return "USAGE: " + parts.joined(separator: " · ")
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
        for line in cloudModelLines() { print(line) }
        print("Provider: \(geminiRouteLine(appVertexProxy(paths: paths)))")
    }

    /// The cloud models `--transcribe --engine` takes, one line each: "geminiArgon  Gemini 4 Argon  google/gemini-4-argon
    /// · effort low|medium|high (default medium)".
    static func cloudModelLines() -> [String] {
        EngineID.geminiEngines.map { id in
            let efforts = id.reasoningEfforts.map(\.rawValue).joined(separator: "|")
            let level = id.defaultReasoningEffort.map { " (default \($0.rawValue))" } ?? ""
            return id.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
                + id.displayName.padding(toLength: 18, withPad: " ", startingAt: 0)
                + (id.openRouterModelID ?? "") + " · effort \(efforts)\(level)"
        }
    }

    /// The provider every cloud request goes to, as `--model-status` says it: never the key, only whether one is
    /// saved. nil: OpenRouter with no endpoint saved.
    @MainActor
    static func geminiRouteLine(_ proxy: VertexProxyAccount?) -> String {
        guard let proxy else { return "OpenRouter (no custom endpoint saved)" }
        let host = proxy.baseURL.map(VertexProxy.displayHost)
        guard proxy.routesGemini else {
            return host.map { "OpenRouter (custom endpoint at \($0) saved, not in use)" }
                ?? "OpenRouter (no custom endpoint saved)"
        }
        guard let host else { return "Custom endpoint (not set up: no base URL)" }
        if proxy.isKeyUnreadable { return "Custom endpoint (\(host), key unreadable)" }
        return proxy.maskedKey != nil ? "Custom endpoint (\(host), key saved)"
            : "Custom endpoint (\(host), not set up: no key)"
    }

    /// The app's OpenAI-compatible endpoint, read only: its base URL and the provider from the app's settings
    /// (`dev.transcribe-thing.app`), its key from its key file, copied into memory so nothing the run does changes
    /// either. A build from before the choice of provider is read as the app reads it (`AppSettings.cloudProvider`).
    /// nil while OpenRouter is the provider and no base URL is saved.
    @MainActor
    static func appVertexProxy(paths: AppPaths) -> VertexProxyAccount? {
        // A suite named after this process's own bundle id comes back nil: the installed app's binary reads its own.
        let domain = "dev.transcribe-thing.app"
        let defaults = Bundle.main.bundleIdentifier == domain ? UserDefaults.standard : UserDefaults(suiteName: domain)
        let url = defaults?.string(forKey: SettingsKey.vertexProxyURL.defaultsKey).flatMap { $0.isEmpty ? nil : $0 }
        let stored = defaults?.string(forKey: SettingsKey.cloudProvider.defaultsKey).flatMap(CloudProvider.init(rawValue:))
        let useForGemini = defaults?.object(forKey: SettingsKey.vertexProxyEnabled.defaultsKey) as? Bool ?? true
        guard url != nil || stored == .vertexProxy else { return nil }
        let settings = AppSettings.inMemory()
        settings.vertexProxyURL = url
        if let stored {
            settings.cloudProvider = stored
        } else if !useForGemini {
            settings.cloudProvider = .openRouter
        }
        let keyStore: KeyFileStore
        do {
            keyStore = .inMemory(try KeyFileStore(url: paths.vertexProxyKeyFile).lookup())
        } catch {
            keyStore = .inMemory("unreadable")
            keyStore.simulateReadFailure(true)
        }
        return VertexProxyAccount(keyStore: keyStore, settings: settings)
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
