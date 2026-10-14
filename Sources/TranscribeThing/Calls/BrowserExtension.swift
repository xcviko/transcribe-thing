import AppKit
import Observation

/// The browser extension that tells the app about calls in web pages: which tab holds one, whether its mic is muted,
/// when it ends. Without it a browser's calls are still noticed (the HAL and the tab strip, `BrowserTabs`), just
/// less surely. Chromium browsers (Chrome, Arc, Edge, Brave, Yandex, Vivaldi) take it unpacked, with no store: the
/// app keeps the folder and tells each browser how to reach it (a native messaging host). An extension lives in one
/// browser profile, so each profile that has calls needs it; every profile that has it is one `Connection`.
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

    /// The browsers on this Mac the extension can go into: Chromium ones, then Firefox and Safari.
    private(set) var browsers: [Browser] = []
    /// The profiles whose extension has spoken since the app started.
    private(set) var connections: [Connection] = []

    init(browsers: [Browser]? = nil, connections: [Connection] = []) {
        self.browsers = browsers ?? Self.installedBrowsers()
        self.connections = connections
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
        throw CocoaError(.featureUnsupported)
    }

    /// Prepares the extension, opens the browser's extensions page and shows the folder in Finder, to drag in.
    func openInstall(_ browser: Browser) {}

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
