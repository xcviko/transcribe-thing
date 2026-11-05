import Foundation

/// What's left of the browser extension calls had, now that calls are an app of their own (calls-thing, with its own
/// extension and host). Builds with calls wrote a native messaging host manifest into each Chromium browser that
/// got the extension, naming this app's executable; a copy of the old extension still loaded in a profile keeps
/// asking the browser to start that host, every few seconds.
///
/// - `isBrowserLaunch`: this executable started by a browser for that extension (its argument is the extension's
///   origin). The app exits at once, before anything of its own.
/// - `removeOldManifests`: at launch, this app's own manifest goes from every Chromium browser that has it, so the
///   browsers stop starting the app. Only one that names a transcribe-thing.app, or this repository's `.build`: a
///   manifest pointing anywhere else isn't this app's to delete.
///
/// Both can go in a release or two, once old extensions are gone; the exit costs nothing to keep.
enum LegacyBrowserHost {
    /// The manifest builds with calls wrote, named for their host: dev.transcribe_thing.bridge.
    static let manifestName = "dev.transcribe_thing.bridge.json"

    /// Each Chromium browser's settings folder under ~/Library/Application Support, whose NativeMessagingHosts the
    /// old extension's manifest went into.
    static let chromiumDataFolders = [
        "Google/Chrome", "Google/Chrome Beta", "Google/Chrome Dev", "Google/Chrome Canary", "Chromium",
        "Arc/User Data", "Microsoft Edge", "Microsoft Edge Beta", "Microsoft Edge Dev",
        "BraveSoftware/Brave-Browser", "Vivaldi", "Yandex/YandexBrowser",
    ]

    /// Whether a browser started this executable as the old extension's host: an argument is an extension's origin,
    /// "chrome-extension://<id>/".
    static func isBrowserLaunch<Arguments: Sequence<String>>(_ arguments: Arguments) -> Bool {
        arguments.contains { $0.hasPrefix("chrome-extension://") }
    }

    /// ~/Library/Application Support, where the browsers keep their settings.
    static var liveBrowserSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    /// This repository's `.build`, where a `swift build` copy that wrote a manifest ran from.
    static var repositoryBuild: URL {
        var url = URL(fileURLWithPath: #filePath)
        // <repo>/Sources/TranscribeThing/App/LegacyBrowserHost.swift → <repo>
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.appendingPathComponent(".build", isDirectory: true)
    }

    /// Deletes this app's old manifest from each browser under `browserSupport` that has it, when it names this app
    /// (`isOurs`). Anything else is left as it is. Returns the manifests deleted.
    @discardableResult
    static func removeOldManifests(browserSupport: URL, repositoryBuild: URL = repositoryBuild) -> [URL] {
        let fm = FileManager.default
        var removed: [URL] = []
        for data in chromiumDataFolders {
            let manifest = browserSupport.appendingPathComponent(data, isDirectory: true)
                .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
                .appendingPathComponent(manifestName, isDirectory: false)
            guard let contents = try? Data(contentsOf: manifest),
                  let object = try? JSONSerialization.jsonObject(with: contents) as? [String: Any],
                  let path = object["path"] as? String,
                  isOurs(path: path, repositoryBuild: repositoryBuild) else { continue }
            do {
                try fm.removeItem(at: manifest)
                removed.append(manifest)
                Log.app.info("Removed the old browser extension host from \(data, privacy: .public)")
            } catch {
                Log.app.error("Couldn't remove the old browser extension host from \(data, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return removed
    }

    /// Whether a manifest's executable is this app's: inside a transcribe-thing.app, wherever it is, or under this
    /// repository's `.build`.
    static func isOurs(path: String, repositoryBuild: URL) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if url.pathComponents.contains("transcribe-thing.app") { return true }
        let build = repositoryBuild.standardizedFileURL.pathComponents
        let parts = url.pathComponents
        return parts.count > build.count && Array(parts.prefix(build.count)) == build
    }
}
