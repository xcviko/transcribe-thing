import Foundation

/// On-disk layout. Nothing is created until `ensureDirectories()`.
struct AppPaths: Sendable {
    /// ~/Library/Application Support/transcribe-thing
    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// root/Models (Parakeet lives in Models/parakeet-tdt-0.6b-v3).
    var models: URL { root.appendingPathComponent("Models", isDirectory: true) }
    /// root/Recordings: WAV files of failed or canceled dictations.
    var recordings: URL { root.appendingPathComponent("Recordings", isDirectory: true) }
    /// root/history.json
    var historyFile: URL { root.appendingPathComponent("history.json", isDirectory: false) }
    /// root/updates.json: the last release feed GitHub sent, its ETag and when it was checked.
    var updateFeedFile: URL { root.appendingPathComponent("updates.json", isDirectory: false) }

    func recordingURL(fileName: String) -> URL {
        recordings.appendingPathComponent(fileName, isDirectory: false)
    }

    static func live() -> AppPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return AppPaths(root: support.appendingPathComponent("transcribe-thing", isDirectory: true))
    }

    /// A fresh, unique folder under the temporary directory, for previews and tests.
    static func temporary() -> AppPaths {
        AppPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-thing-\(UUID().uuidString)", isDirectory: true))
    }

    func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [root, models, recordings] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Space available for user-initiated work on the volume that holds `root`.
    func freeDiskBytes() -> Int64 {
        var probe = root
        // Walk up to an existing ancestor: the volume query fails on paths that don't exist yet.
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                         .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    /// Total size of the files under `url` (0 if missing).
    static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let v = try? file.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Bundled resources (sounds, icon). Inside the .app they come from the bundle; when running the bare
/// binary from .build they come from `<repo>/Resources`, located via TRANSCRIBE_THING_RESOURCES or this file's path.
enum AppResources {
    static func url(_ name: String, ext: String, subdirectory: String? = nil) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
            return url
        }
        guard let base = developmentRoot else { return nil }
        var url = base
        if let subdirectory { url.appendPathComponent(subdirectory, isDirectory: true) }
        url.appendPathComponent("\(name).\(ext)", isDirectory: false)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var developmentRoot: URL? {
        if let env = ProcessInfo.processInfo.environment["TRANSCRIBE_THING_RESOURCES"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        // <repo>/Sources/TranscribeThing/Core/AppPaths.swift → <repo>/Resources
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let resources = repo.appendingPathComponent("Resources", isDirectory: true)
        return FileManager.default.fileExists(atPath: resources.path) ? resources : nil
    }
}
