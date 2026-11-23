import AppKit
import Observation

/// The browser extension that tells the app about calls in web pages: which tab holds one, whether its mic is muted,
/// when it ends. Without it a browser's calls are still noticed (the HAL and the tab strip, `BrowserTabs`), just
/// less surely. Chromium browsers (Chrome, Arc, Edge, Brave, Yandex, Vivaldi) take it unpacked, with no store: the
/// app keeps the folder and tells each browser how to reach it (a native messaging host). An extension lives in one
/// browser profile, so each profile that has calls needs it; every profile that has it is one `Connection`.
///
/// `prepare` copies the extension the app carries (BrowserExtension/chromium, in the app's Resources) to
/// `AppPaths.browserExtension`, a place that doesn't move when the app does, and writes the browser's native
/// messaging host manifest, which names this app's executable (`NativeHostCLI`) and lets in the extension's pinned id
/// only. At launch `reprepare` does it again for every browser that has the manifest, so an updated or moved app is
/// what the browsers reach. The browser loads the folder once ("Load unpacked"); it has the same id wherever it is.
@MainActor
@Observable
final class BrowserExtension {
    enum Family: String, Codable, Sendable {
        case chromium, firefox, safari
    }

    /// A browser on this Mac.
    struct Browser: Identifiable, Equatable, Sendable {
        /// Its bundle id: "com.google.Chrome".
        var id: String
        /// "Google Chrome".
        var name: String
        var family: Family
        var appURL: URL
    }

    /// One browser profile whose extension is talking to the app.
    struct Connection: Identifiable, Equatable, Sendable {
        /// The extension's own id for its profile, made once when it's installed there.
        var id: String
        /// The browser's bundle id.
        var browserID: String
        /// The extension's version.
        var version: String
        var lastSeen: Date
    }

    /// Why a browser can't take the extension.
    enum PrepareError: LocalizedError, Equatable {
        /// Firefox and Safari: not built for them yet.
        case notYet(String)
        /// A Chromium browser whose folders this app doesn't know.
        case unknownBrowser(String)
        /// The app doesn't carry the extension (a broken build).
        case missingExtension

        var errorDescription: String? {
            switch self {
            case .notYet(let name):
                "The extension isn't available for \(name) yet. It works in Chrome, Arc, Edge, Brave, Vivaldi, "
                    + "Yandex Browser and Chromium."
            case .unknownBrowser(let name):
                "transcribe-thing doesn't know where \(name) keeps its settings, so it can't connect the extension there."
            case .missingExtension:
                "This copy of transcribe-thing doesn't include the browser extension. Reinstall the app and try again."
            }
        }
    }

    /// Where the extension and the browsers' manifests go, and how a browser and a folder are shown: the real ones
    /// in the app, temporary folders and nothing shown in tests and previews.
    struct Places {
        /// The app's copy of the extension: `AppPaths.browserExtension`.
        var folder: URL
        /// Where the browsers keep their settings: ~/Library/Application Support.
        var browserSupport: URL
        /// The extension the app carries.
        var source: () -> URL?
        /// The executable the browsers start as the host.
        var executable: () -> URL?
        /// Opens a URL in a browser.
        var open: (_ url: URL, _ app: URL) -> Void
        /// Shows a folder in Finder.
        var reveal: (URL) -> Void

        static func live(paths: AppPaths) -> Places {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            return Places(
                folder: paths.browserExtension, browserSupport: support,
                source: { BrowserExtension.bundledSource },
                executable: { Bundle.main.executableURL?.resolvingSymlinksInPath() },
                open: { url, app in
                    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                },
                reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) })
        }

        /// Everything under a fresh temporary folder, nothing opened or shown.
        static func temporary() -> Places {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("transcribe-thing-extension-\(UUID().uuidString)", isDirectory: true)
            return Places(folder: root.appendingPathComponent("Browser Extension", isDirectory: true),
                          browserSupport: root.appendingPathComponent("Application Support", isDirectory: true),
                          source: { BrowserExtension.bundledSource }, executable: { Bundle.main.executableURL },
                          open: { _, _ in }, reveal: { _ in })
        }
    }

    /// The browsers on this Mac the extension can go into: Chromium ones, then Firefox and Safari.
    private(set) var browsers: [Browser] = []
    /// The profiles whose extension has spoken since the app started.
    private(set) var connections: [Connection] = []
    /// Why the last Install of a browser didn't go through, by its bundle id; cleared by the next one that does.
    private(set) var installErrors: [String: String] = [:]

    @ObservationIgnored private let places: Places
    @ObservationIgnored private let bridge: BrowserBridge?

    /// `places`: nil keeps everything in a temporary folder (previews, tests); the app passes `.live`. `bridge`: the
    /// socket the profiles' hosts reach, whose connections become `connections`.
    init(browsers: [Browser]? = nil, connections: [Connection] = [], places: Places? = nil,
         bridge: BrowserBridge? = nil) {
        self.browsers = browsers ?? Self.installedBrowsers()
        self.connections = connections
        self.places = places ?? .temporary()
        self.bridge = bridge
        bridge?.onConnectionsChanged = { [weak self] in self?.connections = $0 }
    }

    /// For snapshots and previews.
    static func preview(browsers: [Browser], connections: [Connection] = []) -> BrowserExtension {
        BrowserExtension(browsers: browsers, connections: connections)
    }

    /// The profiles of `browser` that have the extension.
    func connections(of browser: Browser) -> [Connection] {
        connections.filter { $0.browserID == browser.id }
    }

    /// Looks for browsers again (one may have been installed since).
    func refresh() {
        browsers = Self.installedBrowsers()
    }

    /// Puts the unpacked extension where the browser can load it and tells the browser how to reach the app. Returns
    /// the folder to load.
    func prepare(_ browser: Browser) throws -> URL {
        guard browser.family == .chromium else { throw PrepareError.notYet(browser.name) }
        guard let data = Self.chromiumDataFolders[browser.id] else { throw PrepareError.unknownBrowser(browser.name) }
        let folder = try installExtension()
        try writeHostManifest(into: places.browserSupport.appendingPathComponent(data, isDirectory: true)
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true))
        return folder
    }

    /// Prepares the extension, opens the browser's extensions page and shows the folder in Finder, to drag in.
    func openInstall(_ browser: Browser) {
        let folder: URL
        do {
            folder = try prepare(browser)
        } catch {
            Log.app.error("Browser extension for \(browser.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            installErrors[browser.id] = error.localizedDescription
            return
        }
        installErrors[browser.id] = nil
        if let page = Self.extensionsPage(browser.id) { places.open(page, browser.appURL) }
        places.reveal(folder)
    }

    /// At launch: every browser prepared before is prepared again, so the app it reaches is this one, wherever it is
    /// now, and the folder it loads is this version's extension. Browsers never prepared are left alone.
    func reprepare() {
        for (id, data) in Self.chromiumDataFolders {
            let manifest = places.browserSupport.appendingPathComponent(data, isDirectory: true)
                .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
                .appendingPathComponent(Self.manifestName)
            guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
            let name = Self.knownChromium.first { $0.id == id }?.name ?? id
            let app = browsers.first { $0.id == id }?.appURL ?? URL(fileURLWithPath: "/Applications")
            do {
                _ = try prepare(Browser(id: id, name: name, family: .chromium, appURL: app))
            } catch {
                Log.app.error("Browser extension for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Files

    /// The app's copy of the Chromium extension.
    var chromiumFolder: URL { places.folder.appendingPathComponent("Chromium", isDirectory: true) }

    static let manifestName = "\(BrowserProtocol.hostName).json"

    /// Copies the extension the app carries to `chromiumFolder`, unless it's there already as it is. The copy is
    /// made beside it and swapped in, so a browser never loads half a folder.
    private func installExtension() throws -> URL {
        guard let source = places.source() else { throw PrepareError.missingExtension }
        let fm = FileManager.default
        let target = chromiumFolder
        if Self.sameFiles(source, target) { return target }
        try fm.createDirectory(at: places.folder, withIntermediateDirectories: true)
        let fresh = places.folder.appendingPathComponent(".Chromium-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: source, to: fresh)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: fresh)
        } else {
            try fm.moveItem(at: fresh, to: target)
        }
        return target
    }

    /// Writes the native messaging host's manifest into a browser's NativeMessagingHosts folder: this app's
    /// executable, reached over stdio, by the extension's id only.
    private func writeHostManifest(into folder: URL) throws {
        guard let executable = places.executable() else { throw PrepareError.missingExtension }
        let manifest: [String: Any] = [
            "name": BrowserProtocol.hostName,
            "description": "transcribe-thing: calls in web pages",
            "path": executable.path,
            "type": "stdio",
            "allowed_origins": [BrowserProtocol.origin],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Self.manifestName)
        if (try? Data(contentsOf: url)) == data { return }
        try data.write(to: url, options: .atomic)
    }

    /// Whether two folders hold the same files with the same bytes.
    private static func sameFiles(_ a: URL, _ b: URL) -> Bool {
        func files(_ root: URL) -> [String: Data]? {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
            else { return nil }
            var found: [String: Data] = [:]
            let base = root.resolvingSymlinksInPath().path
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      let data = try? Data(contentsOf: url) else { continue }
                let path = url.resolvingSymlinksInPath().path
                found[String(path.dropFirst(base.count))] = data
            }
            return found
        }
        guard FileManager.default.fileExists(atPath: b.path), let left = files(a), let right = files(b) else { return false }
        return left == right
    }

    // MARK: Browsers

    /// The extension as the app carries it: in the app's Resources (scripts/build-app.sh puts it there), else, for a
    /// `swift build` run, in the repository.
    nonisolated static var bundledSource: URL? {
        let fm = FileManager.default
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension/chromium", isDirectory: true),
           fm.fileExists(atPath: resources.appendingPathComponent("manifest.json").path) {
            return resources
        }
        return repositorySource
    }

    /// BrowserExtension/chromium in the repository this file was built from.
    nonisolated static var repositorySource: URL? {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        url.appendPathComponent("BrowserExtension/chromium", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) ? url : nil
    }

    /// Each Chromium browser's settings folder under ~/Library/Application Support, whose NativeMessagingHosts it
    /// reads host manifests from.
    static let chromiumDataFolders: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.google.Chrome.dev": "Google/Chrome Dev",
        "com.google.Chrome.canary": "Google/Chrome Canary",
        "org.chromium.Chromium": "Chromium",
        "company.thebrowser.Browser": "Arc/User Data",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.microsoft.edgemac.Beta": "Microsoft Edge Beta",
        "com.microsoft.edgemac.Dev": "Microsoft Edge Dev",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "ru.yandex.desktop.yandex-browser": "Yandex/YandexBrowser",
    ]

    /// The browser's own extensions page, where Developer mode and Load unpacked are.
    static func extensionsPage(_ browserID: String) -> URL? {
        let scheme = switch browserID {
        case "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev": "edge"
        case "com.brave.Browser": "brave"
        case "com.vivaldi.Vivaldi": "vivaldi"
        case "company.thebrowser.Browser": "arc"
        case "ru.yandex.desktop.yandex-browser": "browser"
        default: "chrome"
        }
        return URL(string: "\(scheme)://extensions/")
    }

    /// Chromium browsers this app knows, in the order they're offered.
    static let knownChromium: [(id: String, name: String)] = [
        ("com.google.Chrome", "Google Chrome"), ("company.thebrowser.Browser", "Arc"),
        ("com.microsoft.edgemac", "Microsoft Edge"), ("com.brave.Browser", "Brave"),
        ("ru.yandex.desktop.yandex-browser", "Yandex Browser"), ("com.vivaldi.Vivaldi", "Vivaldi"),
        ("org.chromium.Chromium", "Chromium"),
    ]

    static let knownOthers: [(id: String, name: String, family: Family)] = [
        ("org.mozilla.firefox", "Firefox", .firefox), ("com.apple.Safari", "Safari", .safari),
    ]

    private static func installedBrowsers() -> [Browser] {
        let all = knownChromium.map { ($0.id, $0.name, Family.chromium) } + knownOthers.map { ($0.id, $0.name, $0.family) }
        return all.compactMap { id, name, family in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { Browser(id: id, name: name, family: family, appURL: $0) }
        }
    }
}
