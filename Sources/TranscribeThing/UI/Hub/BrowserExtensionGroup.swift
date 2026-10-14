import AppKit
import SwiftUI

// MARK: - Copy and state (pure, unit-tested)

/// Where the browser extension stands in one browser, and how General and onboarding say it.
enum BrowserExtensionCopy {
    enum State: Equatable {
        /// Firefox and Safari: the extension can't go in yet (Mozilla's signature, an Apple developer certificate).
        case comingLater
        case notInstalled
        /// Talking to the app from this many profiles of the browser.
        case connected(profiles: Int)
    }

    static func state(of browser: BrowserExtension.Browser, profiles: Int) -> State {
        guard browser.family == .chromium else { return .comingLater }
        return profiles > 0 ? .connected(profiles: profiles) : .notInstalled
    }

    /// General's row: "Not installed", "Connected in 1 profile", "Connected in 2 profiles", "Coming later".
    static func status(_ state: State) -> String {
        switch state {
        case .comingLater: "Coming later"
        case .notInstalled: "Not installed"
        case .connected(let profiles): "Connected in \(profilesPhrase(profiles))"
        }
    }

    static func profilesPhrase(_ count: Int) -> String {
        count == 1 ? "1 profile" : "\(count) profiles"
    }

    /// What a browser call gains with it: the same in General's footer and onboarding.
    static let whatItDoes = "For calls in a browser: it tells \(Brand.name) which tab has the call, when you mute, "
        + "and when the call ends."

    /// After Install: the browser's extensions page and the folder in Finder are open.
    static let steps = [
        "Turn on Developer mode on the extensions page.",
        "Drag the folder from Finder onto the page.",
        "Repeat in each profile you have calls in.",
    ]

    /// General → Browser Extension's footer.
    static let settingsFooter = "\(whatItDoes) Without it, calls in a browser are still noticed, less surely. "
        + "It lives in one browser profile, so add it to each profile you have calls in, like a work profile with "
        + "Slack."

    /// No browser it can go into.
    static let noBrowsers = "It works with Google Chrome, Arc, Microsoft Edge, Brave, Yandex Browser and Vivaldi."

    /// The Calls tab, after a call in a browser: none of the Chromium browsers has it.
    static func callsHint(browser: String) -> String {
        "Calls in \(browser) are noticed more surely with the browser extension: the right tab, your mute, the end."
    }

    /// The browser of the newest call held in a Chromium browser with no profile connected, for the Calls tab's hint.
    static func hintBrowser(calls: [CallRecord], browsers: [BrowserExtension.Browser],
                            connections: [BrowserExtension.Connection]) -> BrowserExtension.Browser? {
        let chromium = browsers.filter { $0.family == .chromium }
        guard connections.isEmpty else { return nil }
        let newest = calls.filter { !$0.manual }.sorted { $0.startedAt > $1.startedAt }
        for call in newest {
            if let browser = chromium.first(where: { $0.id == call.bundleID }) { return browser }
        }
        return nil
    }
}

// MARK: - Pieces shared with onboarding

/// A browser's own icon, or a globe when the app isn't there (a preview).
struct BrowserIcon: View {
    var browser: BrowserExtension.Browser
    var size: CGFloat = 28

    var body: some View {
        if let image = BrowserIcons.image(for: browser.appURL) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            IconTile(symbol: "globe", tint: .inkSecondary, size: size)
        }
    }
}

@MainActor
enum BrowserIcons {
    private static var cache: [URL: NSImage?] = [:]

    static func image(for appURL: URL) -> NSImage? {
        if let cached = cache[appURL] { return cached }
        let image = FileManager.default.fileExists(atPath: appURL.path)
            ? NSWorkspace.shared.icon(forFile: appURL.path) : nil
        cache[appURL] = image
        return image
    }
}

/// The three things to do once the extensions page and the folder are open, numbered.
struct BrowserExtensionSteps: View {
    var fontSize: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(BrowserExtensionCopy.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("\(index + 1)")
                        .font(.system(size: fontSize - 2.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(.inkSecondary)
                        .frame(width: fontSize + 3, height: fontSize + 3)
                        .background(Color.inkSecondary.opacity(0.12), in: Circle())
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + fontSize * 0.36 }
                    Text(step)
                        .font(.system(size: fontSize))
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}


// MARK: - General → Browser Extension

/// A row per browser on this Mac: Install (Reinstall once a profile has it) for Chromium ones, Coming later for
/// Firefox and Safari. Install opens the browser's extensions page and the folder; the steps stay under the name
/// until a profile connects.
struct BrowserExtensionGroup: View {
    @Environment(HubContext.self) private var hub

    /// Browsers whose Install was clicked on this page.
    @State private var installing: Set<String> = []

    var body: some View {
        let ext = hub.browserExtension
        HubGroup("Browser Extension", footer: BrowserExtensionCopy.settingsFooter) {
            SettingsGroup {
                if ext.browsers.isEmpty {
                    SettingsRow(title: "No browser for the extension", subtitle: BrowserExtensionCopy.noBrowsers,
                                systemImage: "puzzlepiece.extension", iconTint: .inkSecondary)
                }
                ForEach(ext.browsers) { browser in
                    let state = BrowserExtensionCopy.state(of: browser, profiles: ext.connections(of: browser).count)
                    BrowserExtensionRow(browser: browser, state: state,
                                        isInstalling: installing.contains(browser.id)
                                            || hub.previewInstallingBrowser == browser.id) {
                        installing.insert(browser.id)
                        ext.openInstall(browser)
                    }
                }
            }
        }
        .onAppear {
            if !hub.isPreview { ext.refresh() }
        }
    }
}

private struct BrowserExtensionRow: View {
    var browser: BrowserExtension.Browser
    var state: BrowserExtensionCopy.State
    /// Install was clicked and no profile has connected yet: the steps show under the name.
    var isInstalling: Bool
    var onInstall: () -> Void
    @Environment(\.inNativeForm) private var inNativeForm

    private var showsSteps: Bool { isInstalling && state == .notInstalled }

    var body: some View {
        HStack(alignment: showsSteps ? .top : .center, spacing: Theme.Spacing.sm) {
            BrowserIcon(browser: browser)
            VStack(alignment: .leading, spacing: 2) {
                Text(browser.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                if case .connected = state {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(BrowserExtensionCopy.status(state))
                    }
                    .typeface(.callout)
                    .foregroundStyle(.success)
                } else {
                    Text(showsSteps ? "Waiting for it to connect…" : BrowserExtensionCopy.status(state))
                        .typeface(.callout)
                        .foregroundStyle(state == .comingLater ? Color.inkTertiary : Color.inkSecondary)
                }
                if showsSteps {
                    BrowserExtensionSteps()
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                }
            }
            Spacer(minLength: Theme.Spacing.md)
            switch state {
            case .comingLater:
                EmptyView()
            case .notInstalled:
                Button(showsSteps ? "Open Again" : "Install", action: onInstall)
                    .buttonStyle(SecondaryButtonStyle(size: .small))
            case .connected:
                Button("Reinstall", action: onInstall)
                    .buttonStyle(SecondaryButtonStyle(size: .small))
            }
        }
        .padding(.horizontal, inNativeForm ? 0 : Theme.Spacing.md)
        .padding(.vertical, inNativeForm ? 2 : Theme.Spacing.sm)
        .frame(minHeight: inNativeForm ? 0 : 48)
        .accessibilityElement(children: .contain)
    }
}
