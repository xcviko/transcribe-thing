import Foundation
import os

/// Per-utterance knobs for a local engine.
struct LocalTranscriptionOptions: Sendable, Equatable {
    /// ISO 639-1 code for Whisper; nil = auto-detect. Parakeet ignores it (v3 detects the language itself).
    var language: String?

    static let `default` = LocalTranscriptionOptions(language: nil)
}

enum LocalEngineError: Error, Equatable, Sendable, LocalizedError {
    case notInstalled
    case notLoaded
    case incompleteDownload([String])
    case listingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "The model isn’t downloaded."
        case .notLoaded: "The model isn’t loaded."
        case .incompleteDownload(let missing):
            "The download is incomplete (\(missing.count) file\(missing.count == 1 ? "" : "s") missing)."
        case .listingFailed(let detail): "Couldn’t list the model files: \(detail)"
        }
    }
}

/// A downloadable on-device model. ParakeetEngine and WhisperEngine implement it in separate files because
/// FluidAudio and WhisperKit can't be imported into the same file (`WordTiming` clash). ModelStore only
/// talks to this protocol, so it never imports either framework.
protocol LocalEngine: Actor {
    nonisolated var engineID: EngineID { get }
    /// Everything this engine writes to disk: measured for disk usage, removed by `deleteFiles()`.
    nonisolated var storageURLs: [URL] { get }
    /// Complete and verified on disk. Stat-only; safe from any thread.
    nonisolated func isInstalled() -> Bool
    /// Bytes the full download takes, from the Hugging Face tree API when reachable (cached per process).
    func remoteDownloadBytes() async -> Int64
    /// Downloads or resumes. `progress` receives byte-weighted 0...1 values, throttled, from any thread.
    /// Cancel by cancelling the calling task; partial files stay on disk and resume next time.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws
    var isLoaded: Bool { get }
    /// Loads (and warms up) the model. The first load after install can take minutes (Core ML specialization).
    func load() async throws
    func unload() async
    /// 16 kHz mono Float32 in [-1, 1]. Returns "" when the engine hears no speech.
    func transcribe(_ samples: [Float], options: LocalTranscriptionOptions) async throws -> String
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

/// Hugging Face "tree" API: the file list (with byte sizes) of a model repo, used for byte-weighted progress.
enum HuggingFaceTree {
    struct File: Sendable, Equatable, Decodable {
        let path: String
        let size: Int64
    }

    static func list(repo: String, folder: String? = nil, recursive: Bool = true,
                     session: URLSession = .shared) async throws -> [File] {
        var components = URLComponents(string: "https://huggingface.co")!
        components.path = "/api/models/\(repo)/tree/main" + (folder.map { "/\($0)" } ?? "")
        if recursive { components.queryItems = [URLQueryItem(name: "recursive", value: "1")] }
        guard var next = components.url else { throw LocalEngineError.listingFailed("bad URL") }

        var files: [File] = []
        for _ in 0..<20 {
            var request = URLRequest(url: next)
            request.timeoutInterval = 20
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LocalEngineError.listingFailed("no response") }
            guard http.statusCode == 200 else { throw LocalEngineError.listingFailed("HTTP \(http.statusCode)") }
            files += try parse(data)
            guard let link = http.value(forHTTPHeaderField: "Link"), let url = nextPage(fromLinkHeader: link) else { break }
            next = url
        }
        return files
    }

    static func parse(_ data: Data) throws -> [File] {
        struct Entry: Decodable {
            struct LFS: Decodable { let size: Int64? }
            let type: String
            let path: String
            let size: Int64?
            let lfs: LFS?
        }
        return try JSONDecoder().decode([Entry].self, from: data)
            .filter { $0.type == "file" }
            .map { File(path: $0.path, size: $0.lfs?.size ?? $0.size ?? 0) }
    }

    /// `<https://…?cursor=abc>; rel="next"`
    static func nextPage(fromLinkHeader header: String) -> URL? {
        for part in header.split(separator: ",") where part.contains("rel=\"next\"") {
            guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end else { continue }
            return URL(string: String(part[part.index(after: start)..<end]))
        }
        return nil
    }
}
