import CoreML
import CryptoKit
import Foundation

/// Sber's GigaAM CTC speech models on this Mac: GigaAM v3 (Russian), GigaAM v3 e2e (Russian, with punctuation and
/// capitals) and GigaAM Multilingual 600M (Russian, English, Kazakh, Kyrgyz, Uzbek), MIT license.
/// `scripts/convert-gigaam.py` makes the Core ML bundle: `Frontend.mlmodelc` (audio to log-mel, float32),
/// `Encoder.mlmodelc` (Conformer and CTC head, float16) and `vocabulary.json` (the alphabet, the blank, the window
/// lengths both models take).
///
/// The app runs all three as one model, GigaAM (`EngineID.gigaam`), in the version picked in Models
/// (`AppSettings.gigaamVariant`): each installs on its own from its own zip (`GigaAMSource`) into
/// `<Models>/<variant raw value>` (`init(variant:modelsRoot:source:)`), and runs on the GPU (float16 builds: a load takes
/// 2-5 s). The hidden comparison (`EngineBatchCLI`) reads any of them from a folder of its own.
///
/// A recording goes in stretches of at most the longest window (25 s, GigaAM's own limit), cut at the quietest
/// moment between 15 and 25 s (`GigaAMChunker`), each padded to the next window with its real length passed along,
/// so the padding changes nothing. CTC greedy decoding. v3 and Multilingual write lowercase letters without
/// punctuation and numbers as words; e2e writes SentencePiece pieces ("▁" for a space) with punctuation, capitals and
/// digits.
actor GigaAMEngine: LocalEngine {
    /// A version of GigaAM. Raw values are its folder, its zip's name without ".zip", the transcript metadata's
    /// `modelID`, and the stored pick (`AppSettings.gigaamVariant`): never rename them. Declaration order is the
    /// Version menu's.
    enum Variant: String, CaseIterable, Identifiable, Sendable {
        case v3 = "gigaam-v3-ctc"
        case v3e2e = "gigaam-v3-e2e-ctc"
        case multilingual = "gigaam-multilingual-600m-ctc"

        /// The one a fresh install picks: plain fast text, for agents and searches.
        static let `default`: Variant = .v3

        var id: String { rawValue }

        /// The Version menu's word for it: "v3", "v3 e2e", "Multilingual".
        var versionName: String {
            switch self {
            case .v3: "v3"
            case .v3e2e: "v3 e2e"
            case .multilingual: "Multilingual"
            }
        }

        /// "GigaAM v3", "GigaAM v3 e2e", "GigaAM Multilingual": its row, the pill's chip, History.
        var displayName: String { "GigaAM \(versionName)" }

        /// What it's good for: "Russian · no punctuation".
        var facts: String {
            switch self {
            case .v3: "Russian · no punctuation"
            case .v3e2e: "Russian · punctuation"
            case .multilingual: "Russian, English and more · no punctuation"
            }
        }

        /// The Version menu's item: "v3 · Russian, no punctuation".
        var menuTitle: String {
            switch self {
            case .v3: "v3 · Russian, no punctuation"
            case .v3e2e: "v3 e2e · Russian with punctuation, capitals and digits"
            case .multilingual: "Multilingual · Russian, English, Kazakh, Kyrgyz, Uzbek"
            }
        }

        /// Its install file, as `scripts/convert-gigaam.py package` makes it: one folder named as the zip without
        /// ".zip".
        var zipName: String { "\(rawValue).zip" }
        /// The zip's bytes.
        var downloadBytes: Int64 {
            switch self {
            case .v3: 409_369_862
            case .v3e2e: 409_641_058
            case .multilingual: 1_082_718_871
            }
        }
        /// The zip's SHA-256, lowercase hex.
        var sha256: String {
            switch self {
            case .v3: "c2d31e7dba58b5a5aed45abeb60ccc617c6a4ccb5531f30887d2a26e05e34f17"
            case .v3e2e: "eb2c35f78382e7c12dd5ff0a1eec9367c28a349d2f9ac48c744510c17ec3b658"
            case .multilingual: "4384fe127886f666e419b6b0c00599b8b767dfefb3abddae32c87e7a699dab3a"
            }
        }
        /// What it takes on this Mac, unpacked.
        var installedBytes: Int64 {
            switch self {
            case .v3: 443_353_203
            case .v3e2e: 443_698_324
            case .multilingual: 1_173_144_132
            }
        }
    }

    struct Vocabulary: Decodable, Sendable {
        let model: String
        let vocabulary: [String]
        /// The vocabulary is SentencePiece pieces, not characters.
        let pieces: Bool
        let blank: Int
        let windowSamples: [Int]
        let hop: Int
        let win: Int

        enum CodingKeys: String, CodingKey {
            case model, vocabulary, pieces, blank, hop, win
            case windowSamples = "window_samples"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = try c.decode(String.self, forKey: .model)
            vocabulary = try c.decode([String].self, forKey: .vocabulary)
            pieces = try c.decodeIfPresent(Bool.self, forKey: .pieces) ?? false
            blank = try c.decode(Int.self, forKey: .blank)
            windowSamples = try c.decode([Int].self, forKey: .windowSamples)
            hop = try c.decode(Int.self, forKey: .hop)
            win = try c.decode(Int.self, forKey: .win)
        }
    }

    enum EngineError: Error, LocalizedError {
        case missingFile(String)
        case badOutput(String)

        var errorDescription: String? {
            switch self {
            case .missingFile(let name): "GigaAM model file missing: \(name)"
            case .badOutput(let detail): "GigaAM returned something unexpected: \(detail)"
            }
        }
    }

    nonisolated let engineID: EngineID = .gigaam
    nonisolated let variant: Variant
    /// The folder with Frontend.mlmodelc, Encoder.mlmodelc and vocabulary.json.
    nonisolated let directory: URL
    nonisolated let computeUnits: MLComputeUnits
    /// Where `download` gets the model; nil for a folder read as it is (the comparison), which never downloads.
    nonisolated let source: GigaAMSource?

    private var frontend: MLModel?
    private var encoder: MLModel?
    private var vocabulary: Vocabulary?

    init(variant: Variant, directory: URL, computeUnits: MLComputeUnits = .all, source: GigaAMSource? = nil) {
        self.variant = variant
        self.directory = directory
        self.computeUnits = computeUnits
        self.source = source
    }

    /// The app's GigaAM in `variant`: `<modelsRoot>/<variant raw value>`, its encoder on the GPU (the zips are float16
    /// builds for it), installed from `source`.
    init(variant: Variant, modelsRoot: URL, source: GigaAMSource? = nil) {
        self.init(variant: variant, directory: modelsRoot.appendingPathComponent(variant.rawValue, isDirectory: true),
                  computeUnits: .cpuAndGPU, source: source ?? .live(variant))
    }

    nonisolated static let requiredFiles = ["Frontend.mlmodelc", "Encoder.mlmodelc", "vocabulary.json"]
    /// What an install needs: each bundle's files Core ML reads, and the vocabulary.
    nonisolated static let requiredParts = ["Frontend.mlmodelc", "Encoder.mlmodelc"].flatMap { bundle in
        ["coremldata.bin", "model.mil", "weights/weight.bin"].map { "\(bundle)/\($0)" }
    } + ["vocabulary.json"]

    /// Where a download unpacks before the folder moves into place, beside it: `gigaam-v3-ctc.partial`.
    nonisolated var stagingDirectory: URL {
        directory.deletingLastPathComponent()
            .appendingPathComponent(directory.lastPathComponent + ".partial", isDirectory: true)
    }

    /// The model's folder, and an unfinished download's.
    nonisolated var storageURLs: [URL] { [directory, stagingDirectory] }

    /// Every part Core ML needs, and nothing an unfinished install left: no download folder beside it, no `*.partial`
    /// inside. Stat-only.
    nonisolated func isInstalled() -> Bool {
        let fm = FileManager.default
        guard Self.missingParts(in: directory).isEmpty, !fm.fileExists(atPath: stagingDirectory.path) else {
            return false
        }
        if let walker = fm.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "partial" {
                return false
            }
        }
        return true
    }

    nonisolated static func missingParts(in folder: URL) -> [String] {
        requiredParts.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    var isLoaded: Bool { encoder != nil }

    // MARK: Download

    func remoteDownloadBytes() async -> Int64 {
        source?.expectedBytes ?? engineID.approxDownloadBytes ?? 0
    }

    /// Gets the zip (`GigaAMSource.fetch`: from Downloads or the release) into the download folder with byte progress,
    /// checks its size and checksum, unpacks it there, and moves the model's folder into place in one step. The
    /// download folder goes in the end, whatever happened; a cancel stops it at the next chunk.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let source else { throw LocalEngineError.notInstalled }
        let fm = FileManager.default
        let staging = stagingDirectory
        try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        // What an unfinished download left goes first. One cut off after its move has the model in place already.
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        if isInstalled() {
            progress(1)
            return
        }
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let zip = staging.appendingPathComponent(source.fileName, isDirectory: false)
        let throttle = ProgressThrottle(send: progress)
        let total = Double(max(source.expectedBytes, 1))
        // Bytes up to 0.99: checking and unpacking are the rest.
        try await source.fetch(to: zip) { bytes in throttle.offer(min(Double(bytes) / total, 0.99)) }
        try Task.checkCancellation()
        try source.verify(zip)
        try Task.checkCancellation()
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        do {
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try Ditto.extract(zip, to: unpacked)
        } catch {
            throw GigaAMSource.Failure.badArchive(source.fileName)
        }
        try Task.checkCancellation()
        let folder = unpacked.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
        guard Self.missingParts(in: folder).isEmpty else { throw GigaAMSource.Failure.notTheModel(source.fileName) }
        // A folder left from before (a delete cut short) makes way.
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try fm.moveItem(at: folder, to: directory)
        try fm.removeItem(at: staging)
        guard isInstalled() else { throw LocalEngineError.incompleteDownload(Self.missingParts(in: directory)) }
        progress(1)
    }

    /// Unloads, then removes the model's folder and any unfinished download.
    func deleteFiles() async throws {
        unload()
        let fm = FileManager.default
        for url in storageURLs where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    // MARK: Load

    /// Loads both models and the vocabulary, then runs each window size once. On the GPU a load takes 2-5 s. (On the
    /// Neural Engine, int8 builds took about 3 minutes in `MLModel.load` alone, cold again after a rebuild of the app.)
    func load() async throws {
        guard encoder == nil else { return }
        for name in Self.requiredFiles where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            throw EngineError.missingFile(name)
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("vocabulary.json"))
        let vocabulary = try JSONDecoder().decode(Vocabulary.self, from: data)
        // The frontend is small and float32: the CPU runs it exactly, with nothing to specialize.
        let frontendConfig = MLModelConfiguration()
        frontendConfig.computeUnits = .cpuOnly
        let encoderConfig = MLModelConfiguration()
        encoderConfig.computeUnits = computeUnits
        let frontend = try await MLModel.load(contentsOf: directory.appendingPathComponent("Frontend.mlmodelc"),
                                              configuration: frontendConfig)
        let encoder = try await MLModel.load(contentsOf: directory.appendingPathComponent("Encoder.mlmodelc"),
                                             configuration: encoderConfig)
        self.frontend = frontend
        self.encoder = encoder
        self.vocabulary = vocabulary
        // Warm-up: the first prediction of each window size pays for its specialization.
        for window in vocabulary.windowSamples {
            _ = try run(Array(repeating: 0, count: window / 2), window: window)
        }
    }

    func unload() {
        frontend = nil
        encoder = nil
        vocabulary = nil
    }

    // MARK: Transcribe

    /// 16 kHz mono Float32 in [-1, 1]. "" when it hears no speech.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard encoder != nil, let vocabulary else { throw LocalEngineError.notLoaded }
        let longest = vocabulary.windowSamples.max() ?? 0
        var parts: [String] = []
        for range in GigaAMChunker.split(samples, maxLength: longest) {
            guard range.count >= vocabulary.win else { continue }
            let window = vocabulary.windowSamples.first { $0 >= range.count } ?? longest
            let text = try run(Array(samples[range]), window: window)
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: " ")
    }

    /// One stretch of at most `window` samples, padded to it.
    private func run(_ samples: [Float], window: Int) throws -> String {
        guard let frontend, let encoder, let vocabulary else { return "" }
        let audio = try MLMultiArray(shape: [1, NSNumber(value: window)], dataType: .float32)
        audio.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            buffer.initialize(repeating: 0)
            _ = buffer.update(fromContentsOf: samples.prefix(window))
        }
        let features = try frontend.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": audio]))
        guard let mel = features.featureValue(for: "mel")?.multiArrayValue else { throw EngineError.badOutput("no mel") }
        let frames = (min(samples.count, window) - vocabulary.win) / vocabulary.hop + 1
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: frames)
        let output = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mel": mel, "length": length]))
        guard let logProbs = output.featureValue(for: "log_probs")?.multiArrayValue,
              let steps = output.featureValue(for: "steps")?.multiArrayValue
        else { throw EngineError.badOutput("no log_probs") }
        let ids = Self.argmax(logProbs, steps: steps[0].intValue)
        return Self.decode(ids, vocabulary: vocabulary.vocabulary, blank: vocabulary.blank, pieces: vocabulary.pieces)
    }

    /// The best class per step, for the first `steps` steps of [1, T, V] log-probs (float16 or float32).
    static func argmax(_ array: MLMultiArray, steps: Int) -> [Int] {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard shape.count == 3 else { return [] }
        let count = min(steps, shape[1])
        let classes = shape[2]
        var ids: [Int] = []
        ids.reserveCapacity(count)
        func scan<T>(_ pointer: UnsafePointer<T>, _ value: (T) -> Float) {
            for t in 0..<count {
                var best = 0
                var bestValue = -Float.infinity
                for v in 0..<classes {
                    let x = value(pointer[t * strides[1] + v * strides[2]])
                    if x > bestValue { bestValue = x; best = v }
                }
                ids.append(best)
            }
        }
        switch array.dataType {
        case .float16:
            array.withUnsafeBufferPointer(ofType: Float16.self) { scan($0.baseAddress!) { Float($0) } }
        case .float32:
            array.withUnsafeBufferPointer(ofType: Float.self) { scan($0.baseAddress!) { $0 } }
        default:
            for t in 0..<count {
                var best = 0
                var bestValue = -Float.infinity
                for v in 0..<classes {
                    let x = array[[0, NSNumber(value: t), NSNumber(value: v)]].floatValue
                    if x > bestValue { bestValue = x; best = v }
                }
                ids.append(best)
            }
        }
        return ids
    }

    /// CTC greedy: repeats collapse, blanks go, then the characters (or pieces, "▁" a space, "<unk>" dropped) join;
    /// spaces trimmed and never doubled.
    static func decode(_ ids: [Int], vocabulary: [String], blank: Int, pieces: Bool = false) -> String {
        var text = ""
        var previous: Int?
        for id in ids {
            if id != previous, id != blank, vocabulary.indices.contains(id), !(pieces && vocabulary[id] == "<unk>") {
                text += vocabulary[id]
            }
            previous = id
        }
        if pieces { text = text.replacingOccurrences(of: "▁", with: " ") }
        return text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}

/// Where a long recording is cut for GigaAM: each stretch is at most `maxLength` samples, and past the first
/// `minLength` it ends in the middle of the quietest 200 ms it can, so a cut lands in a pause, not in a word.
enum GigaAMChunker {
    static let sampleRate = 16_000

    static func split(_ samples: [Float], maxLength: Int, minLength: Int? = nil) -> [Range<Int>] {
        let count = samples.count
        guard count > maxLength, maxLength > 0 else { return count > 0 ? [0..<count] : [] }
        let minLength = minLength ?? maxLength * 3 / 5
        let frame = sampleRate / 100  // 10 ms
        let span = 20  // 200 ms of frames
        var ranges: [Range<Int>] = []
        var start = 0
        while count - start > maxLength {
            let searchStart = start + minLength
            let searchEnd = start + maxLength
            let frames = (searchEnd - searchStart) / frame
            var energy = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                let from = searchStart + i * frame
                var sum: Float = 0
                for j in from..<min(from + frame, count) { sum += samples[j] * samples[j] }
                energy[i] = sum
            }
            var cut = searchEnd
            if frames >= span {
                var window = energy[0..<span].reduce(0, +)
                var best = window
                var bestAt = 0
                for i in span..<frames {
                    window += energy[i] - energy[i - span]
                    if window < best { best = window; bestAt = i - span + 1 }
                }
                cut = searchStart + (bestAt + span / 2) * frame
            }
            ranges.append(start..<cut)
            start = cut
        }
        ranges.append(start..<count)
        return ranges
    }
}

/// Where a GigaAM version's install file comes from, and what it has to be. The source is picked when a download
/// starts: the zip in the user's Downloads folder while it's there, else the release asset. Tests hand it a small zip
/// and its own size and checksum.
struct GigaAMSource: Sendable {
    /// The release every version's zip is published under, once it is.
    static let releaseTag = "gigaam-1"

    /// The zip's name, in Downloads and on the release: "gigaam-v3-ctc.zip".
    var fileName: String
    /// The zip as the user put it in Downloads.
    var localZip: URL?
    /// The published release asset.
    var remote: URL?
    var expectedBytes: Int64
    /// Lowercase hex.
    var sha256: String
    /// Fetches `remote` into a file with byte progress (`UpdateDownload`).
    var download: @Sendable (_ from: URL, _ to: URL,
                             _ progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> Void

    /// The release asset `variant`'s zip will be, once published.
    static func releaseURL(_ variant: GigaAMEngine.Variant) -> URL {
        URL(string: "https://github.com/\(Brand.repository)/releases/download/\(releaseTag)/\(variant.zipName)")!
    }

    /// `~/Downloads/<variant>.zip`, else the release. Only a download reads the folder (macOS asks the user the first
    /// time).
    static func live(_ variant: GigaAMEngine.Variant) -> GigaAMSource {
        GigaAMSource(
            fileName: variant.zipName,
            localZip: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?
                .appendingPathComponent(variant.zipName, isDirectory: false),
            remote: releaseURL(variant),
            expectedBytes: variant.downloadBytes,
            sha256: variant.sha256,
            download: { url, destination, progress in
                try await UpdateDownload.run(from: url, to: destination, progress: progress)
            })
    }

    /// Each names the zip it's about.
    enum Failure: Error, Equatable, LocalizedError {
        /// The zip isn't the one the app knows: another size or checksum.
        case wrongFile(String)
        case badArchive(String)
        /// Unpacked, it doesn't hold the model's folder.
        case notTheModel(String)
        /// The Downloads folder can't be read (Privacy & Security → Files and Folders).
        case downloadsNotReadable

        var errorDescription: String? {
            switch self {
            case .wrongFile(let file): "\(file) isn’t the right file: its size or checksum doesn’t match."
            case .badArchive(let file): "\(file) couldn’t be unpacked."
            case .notTheModel(let file): "\(file) doesn’t hold the model’s folder."
            case .downloadsNotReadable:
                "\(Brand.name) can’t read your Downloads folder. Allow it in Privacy & Security → Files and Folders."
            }
        }
    }

    /// Copies the zip from Downloads when it's there, else downloads the release. A release that isn't there (an HTTP
    /// 4xx) is `LocalEngineError.notPublished`; so is no release at all.
    func fetch(to file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        if let localZip {
            if fm.fileExists(atPath: localZip.path) {
                try Self.copy(localZip, to: file, progress: progress)
                return
            }
            // Not found may be not allowed: macOS hides what's inside Downloads from an app the user said no to.
            let folder = localZip.deletingLastPathComponent()
            if fm.fileExists(atPath: folder.path), (try? fm.contentsOfDirectory(atPath: folder.path)) == nil {
                throw Failure.downloadsNotReadable
            }
        }
        guard let remote else { throw LocalEngineError.notPublished(file: fileName) }
        do {
            try await download(remote, file) { received, _ in progress(received) }
        } catch let error as UpdateDownload.HTTPStatus where (400..<500).contains(error.status) {
            throw LocalEngineError.notPublished(file: fileName)
        }
    }

    /// The size first, then the checksum.
    func verify(_ zip: URL) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.int64Value
        guard size == expectedBytes, try Self.sha256(of: zip) == sha256.lowercased() else {
            throw Failure.wrongFile(fileName)
        }
    }

    private static let chunkBytes = 4 << 20

    /// A plain copy in chunks, with the bytes copied so far after each; stops at the next chunk once cancelled.
    static func copy(_ source: URL, to destination: URL, progress: (Int64) -> Void) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var copied: Int64 = 0
        while let chunk = try input.read(upToCount: chunkBytes), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
            copied += Int64(chunk.count)
            progress(copied)
        }
    }

    /// Lowercase hex SHA-256 of a file, read in chunks.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
