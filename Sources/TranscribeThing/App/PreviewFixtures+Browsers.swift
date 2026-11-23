import AppKit

/// Browsers and extension connections for snapshots of General → Browser Extension, onboarding's calls step and the
/// Calls tab. Icons come from the apps where they're installed, a globe where they aren't.
@MainActor
extension PreviewFixtures {
    static func browser(_ id: String) -> BrowserExtension.Browser {
        let known = BrowserExtension.knownChromium.map { ($0.id, $0.name, BrowserExtension.Family.chromium) }
            + BrowserExtension.knownOthers.map { ($0.id, $0.name, $0.family) }
        let (_, name, family) = known.first { $0.0 == id } ?? (id, id, .chromium)
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            ?? URL(fileURLWithPath: "/Applications/\(name).app")
        return BrowserExtension.Browser(id: id, name: name, family: family, appURL: appURL)
    }

    static let chrome = browser("com.google.Chrome")
    static let arc = browser("company.thebrowser.Browser")
    static let firefox = browser("org.mozilla.firefox")
    static let safari = browser("com.apple.Safari")

    /// `profiles` profiles of `browser` with the extension, seen a minute ago.
    static func connections(_ browser: BrowserExtension.Browser, profiles: Int) -> [BrowserExtension.Connection] {
        (0..<profiles).map { index in
            BrowserExtension.Connection(id: "\(browser.id).profile\(index + 1)", browserID: browser.id, version: "0.1.0",
                                        lastSeen: Date().addingTimeInterval(-60))
        }
    }
}
