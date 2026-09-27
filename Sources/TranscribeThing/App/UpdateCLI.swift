import Foundation

/// Headless update checks, dispatched by TranscribeThingMain before the app starts:
///
///     transcribe-thing --check-updates [--feed <url>] [--current <version>]
///     transcribe-thing --install-update --feed <url> --target <path/to/transcribe-thing.app>
///            [--requirement-from <path/to/transcribe-thing.app>]
///
/// `--check-updates` prints what the update checker sees: the feed (GitHub by default, or any file:// or https
/// URL in GitHub's format), the releases it keeps, and whether `--current` (default: this binary's version)
/// would be offered an update. `--install-update` runs the in-app installer on the newest release in the feed
/// against `--target` only: pick the zip, download, unpack, verify (bundle id, version, and a signature that
/// satisfies the designated requirement of `--requirement-from`, default the target itself), then replace the
/// target. It never relaunches anything. Neither mode reads or writes the app's settings or its feed cache.
enum UpdateCLI {
    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains("--check-updates") || arguments.contains("--install-update")
    }

    /// Runs the CLI mode and exits the process.
    @MainActor
    static func run(_ arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            exit(await main(arguments))
        }
        dispatchMain()
    }

    private enum ExitCode {
        static let ok: Int32 = 0
        static let failed: Int32 = 1
        static let usage: Int32 = 2
    }

    static let usage = """
    usage: transcribe-thing --check-updates [--feed <url>] [--current <version>]
           transcribe-thing --install-update --feed <url> --target <transcribe-thing.app> \
    [--requirement-from <transcribe-thing.app>]
    """

    @MainActor
    private static func main(_ arguments: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            let value = arguments[index + 1]
            return value.hasPrefix("--") ? nil : value
        }
        let feed: URL
        if let raw = value("--feed") {
            guard let url = feedURL(raw) else {
                printError("ERROR: not a URL: \(raw)")
                return ExitCode.usage
            }
            feed = url
        } else if arguments.contains("--install-update") {
            printError(usage)
            return ExitCode.usage
        } else {
            feed = UpdateFeedClient.feedOverride ?? Brand.releasesFeed
        }

        if arguments.contains("--install-update") {
            guard let target = value("--target").map(fileURL) else {
                printError(usage)
                return ExitCode.usage
            }
            return await install(feed: feed, target: target, requirementFrom: value("--requirement-from").map(fileURL))
        }
        var current = AppVersion.running
        if let raw = value("--current") {
            guard let version = AppVersion(raw) else {
                printError("ERROR: not a version: \(raw)")
                return ExitCode.usage
            }
            current = version
        }
        return await check(feed: feed, current: current)
    }

    // MARK: Check

    @MainActor
    private static func check(feed: URL, current: AppVersion?) async -> Int32 {
        print("FEED: \(feed.absoluteString)")
        print("CURRENT: \(current?.description ?? "unknown (pass --current)")")
        guard let releases = await fetch(feed, version: current) else { return ExitCode.failed }
        print("RELEASES: \(releases.count) (drafts and prereleases skipped)")
        for release in releases {
            let date = release.publishedAt.map { $0.formatted(.iso8601.year().month().day()) } ?? "undated"
            let asset = release.installableAsset.map { "\($0.name) · \(Fmt.bytes($0.size))" } ?? "no installable zip"
            let summary = ReleaseNotes.summary(release.notes).map { " · \($0)" } ?? ""
            print("  \(release.version.description.padding(toLength: 10, withPad: " ", startingAt: 0))\(release.tag) · \(date) · \(asset)\(summary)")
        }
        let policy = UpdatePolicy(checksAutomatically: true, current: current, latest: releases.first, announcedVersion: nil)
        if let available = policy.available {
            print("UPDATE: \(available.version) is available · \(available.pageURL.absoluteString)")
        } else if releases.isEmpty {
            print("UP TO DATE: no releases yet")
        } else if current == nil {
            print("LATEST: \(releases[0].version)")
        } else {
            print("UP TO DATE: latest is \(releases[0].version)")
        }
        return ExitCode.ok
    }

    @MainActor
    private static func fetch(_ feed: URL, version: AppVersion?) async -> [Release]? {
        let client = UpdateFeedClient(feedURL: feed, userAgent: "transcribe-thing/\(version?.description ?? "dev")")
        do {
            switch try await client.fetch(etag: nil) {
            case .releases(let releases, _): return releases
            case .notModified: return []
            }
        } catch {
            printError("ERROR: \(error.message)")
            if case .unreadable(let detail) = error { printError("DETAIL: \(detail)") }
            return nil
        }
    }

    // MARK: Install

    @MainActor
    private static func install(feed: URL, target: URL, requirementFrom: URL?) async -> Int32 {
        print("FEED: \(feed.absoluteString)")
        print("TARGET: \(target.path)")
        let source = requirementFrom ?? target
        print("REQUIREMENT FROM: \(source.path)")
        guard let releases = await fetch(feed, version: nil) else { return ExitCode.failed }
        guard let release = releases.first else {
            printError("ERROR: the feed has no releases")
            return ExitCode.failed
        }
        print("RELEASE: \(release.version) (\(release.tag))")
        let info = NSDictionary(contentsOf: source.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        guard let identifier = info?["CFBundleIdentifier"] as? String else {
            printError("ERROR: no bundle identifier in \(source.path)")
            return ExitCode.failed
        }
        if let installed = (NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String {
            print("INSTALLED: \(installed)")
        }
        let requirement = CodeSignature.Source.app(source)
        if let text = (try? CodeSignature.designatedRequirement(requirement)).flatMap(CodeSignature.text) {
            print("REQUIREMENT: \(text)")
        }
        let installer = UpdateInstaller.live(target: target, bundleIdentifier: identifier, requirement: requirement)
        do {
            let asset = try installer.preflight(release)
            print("ASSET: \(asset.name) · \(Fmt.bytes(asset.size)) · \(asset.url.absoluteString)")
            let reporter = StepPrinter()
            let prepared = try await installer.prepare(release) { step in reporter.report(step) }
            print("VERIFY: \(identifier) \(release.version) · signature valid and satisfies the requirement")
            print("QUARANTINE: \(Quarantine.isQuarantined(prepared.app) ? "still set" : "clear")")
            try installer.install(prepared)
            let now = (NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
            print("INSTALL: replaced \(target.path) · now \(now ?? "unknown")")
            print("DONE (not relaunched)")
            return ExitCode.ok
        } catch let error as UpdateInstallError {
            printError("ERROR: \(error.message)")
            if let detail = error.detail { printError("DETAIL: \(detail)") }
            return ExitCode.failed
        } catch {
            printError("ERROR: \(error.localizedDescription)")
            return ExitCode.failed
        }
    }

    /// Download progress every 10%, then each later step once.
    private final class StepPrinter: @unchecked Sendable {
        private let lock = NSLock()
        private var lastPercent = -10
        private var printed: Set<String> = []

        func report(_ step: UpdateInstaller.Step) {
            lock.withLock {
                switch step {
                case .downloading(let received, let total):
                    guard let total, total > 0, received > 0 else { return }
                    let percent = Int(Double(received) / Double(total) * 100)
                    guard percent >= lastPercent + 10 || (percent == 100 && lastPercent != 100) else { return }
                    lastPercent = percent
                    print("DOWNLOAD: \(percent)% · \(UpdateFormat.progress(received: received, total: total))")
                case .unpacking:
                    if printed.insert("unpack").inserted { print("UNPACK: ditto -x -k") }
                case .verifying:
                    if printed.insert("verify").inserted { print("VERIFY: checking bundle id, version and signature…") }
                }
            }
        }
    }

    private static func feedURL(_ raw: String) -> URL? {
        if raw.hasPrefix("/") || raw.hasPrefix("~") { return fileURL(raw) }
        guard let url = URL(string: raw), url.scheme != nil else { return nil }
        return url
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
