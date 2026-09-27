import Foundation
import Testing
@testable import TranscribeThing

// MARK: - Versions

@Suite struct AppVersionTests {
    @Test func parsesTagsAndShortVersions() throws {
        #expect(AppVersion("0.3.0") == AppVersion(major: 0, minor: 3, patch: 0))
        #expect(AppVersion("v1.2.3") == AppVersion(major: 1, minor: 2, patch: 3))
        #expect(AppVersion(" V2 ") == AppVersion(major: 2))
        #expect(AppVersion("1.2") == AppVersion("1.2.0"))
        #expect(AppVersion("1.0.0+42") == AppVersion("1.0.0"), "build metadata is ignored")
        let beta = try #require(AppVersion("v2.0.0-beta.1"))
        #expect(beta.prerelease == ["beta", "1"])
        #expect(beta.isPrerelease)
        #expect(beta.description == "2.0.0-beta.1")
        #expect(AppVersion("0.3")?.description == "0.3.0")
    }

    @Test(arguments: ["", "v", "1.2.3.4", "1..2", "a.b.c", "1.2.x", "-1.0.0", "1.0.0-", "1.0.0-beta..1", "１.２.３"])
    func rejectsNonVersions(_ text: String) {
        #expect(AppVersion(text) == nil)
    }

    @Test func comparesBySemver() throws {
        func v(_ s: String) throws -> AppVersion { try #require(AppVersion(s)) }
        #expect(try v("0.2.0") < v("0.3.0"))
        #expect(try v("0.9.9") < v("0.10.0"), "numeric, not lexical")
        #expect(try v("1.0") < v("1.0.1"))
        #expect(try !(v("1.0") < v("1.0.0")) && !(v("1.0.0") < v("1.0")))
        #expect(try v("1.0.0-beta") < v("1.0.0"), "a prerelease comes before its release")
        #expect(try v("1.0.0-alpha") < v("1.0.0-beta"))
        #expect(try v("1.0.0-beta") < v("1.0.0-beta.1"))
        #expect(try v("1.0.0-beta.2") < v("1.0.0-beta.11"))
        #expect(try v("1.0.0-1") < v("1.0.0-alpha"), "numeric identifiers sort first")
        #expect(try [v("0.1.0"), v("1.0.0"), v("0.10.1")].sorted() == [v("0.1.0"), v("0.10.1"), v("1.0.0")])
    }

    @Test func codableAsAString() throws {
        let data = try JSONEncoder().encode([AppVersion(major: 0, minor: 3)])
        #expect(String(decoding: data, as: UTF8.self) == #"["0.3.0"]"#)
        #expect(try JSONDecoder().decode([AppVersion].self, from: data) == [AppVersion(major: 0, minor: 3)])
    }
}

// MARK: - Feed

enum FeedFixtures {
    static func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, name: String? = nil,
                        body: String = "Notes", assets: [String] = [], size: Int = 1234,
                        date: String = "2026-09-20T10:00:00Z") -> [String: Any] {
        var item: [String: Any] = [
            "tag_name": tag, "draft": draft, "prerelease": prerelease, "body": body, "published_at": date,
            "html_url": "https://github.com/xcviko/transcribe-thing/releases/tag/\(tag)",
            "assets": assets.map { name in
                ["name": name, "size": size,
                 "browser_download_url": "https://github.com/xcviko/transcribe-thing/releases/download/\(tag)/\(name)"] as [String: Any]
            },
        ]
        if let name { item["name"] = name }
        return item
    }

    static func json(_ items: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: items)
    }
}

@Suite struct GitHubReleasesTests {
    @Test func skipsDraftsPrereleasesAndOtherTagsNewestFirst() throws {
        let data = FeedFixtures.json([
            FeedFixtures.release("v0.2.0"),
            FeedFixtures.release("v0.4.0", draft: true),
            FeedFixtures.release("v0.5.0-beta.1"),
            FeedFixtures.release("v0.4.1", prerelease: true),
            FeedFixtures.release("nightly"),
            FeedFixtures.release("0.10.0"),
            FeedFixtures.release("v0.3.0"),
        ])
        let releases = try GitHubReleases.decode(data)
        #expect(releases.map(\.version.description) == ["0.10.0", "0.3.0", "0.2.0"])
        #expect(releases[0].tag == "0.10.0", "tags without a v work too")
        #expect(releases[1].pageURL.absoluteString == "https://github.com/xcviko/transcribe-thing/releases/tag/v0.3.0")
        #expect(releases[1].publishedAt == Date(timeIntervalSince1970: 1_789_898_400))
    }

    @Test func emptyFeedHasNoReleases() throws {
        #expect(try GitHubReleases.decode(Data("[]".utf8)).isEmpty)
    }

    @Test func keepsOnlyTitlesThatSayMore() throws {
        let releases = try GitHubReleases.decode(FeedFixtures.json([
            FeedFixtures.release("v0.3.0", name: "Pause-tolerant hands-free"),
            FeedFixtures.release("v0.2.0", name: "v0.2.0"),
            FeedFixtures.release("v0.1.0", name: "transcribe-thing 0.1.0"),
        ]))
        #expect(releases.map(\.title) == ["Pause-tolerant hands-free", nil, nil])
    }

    @Test func picksTheNamedZipThenTheOnlyZip() throws {
        let releases = try GitHubReleases.decode(FeedFixtures.json([
            FeedFixtures.release("v0.4.0", assets: ["checksums.txt", "transcribe-thing-0.4.0.zip", "other.zip"]),
            FeedFixtures.release("v0.3.0", assets: ["notes.pdf", "TranscribeThing.zip"]),
            FeedFixtures.release("v0.2.0", assets: ["a.zip", "b.zip"]),
            FeedFixtures.release("v0.1.0", assets: []),
        ]))
        #expect(releases.map { $0.installableAsset?.name } == ["transcribe-thing-0.4.0.zip", "TranscribeThing.zip", nil, nil])
        #expect(releases[0].installableAsset?.size == 1234)
    }
}

/// Records requests and answers from a script.
final class StubTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var answers: [Result<(Data, Int, [String: String]), URLError>]

    init(_ answers: [Result<(Data, Int, [String: String]), URLError>]) {
        self.answers = answers
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func callAsFunction(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let answer = lock.withLock { () -> Result<(Data, Int, [String: String]), URLError> in
            _requests.append(request)
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
        let (data, status, headers) = try answer.get()
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }

    func client() -> UpdateFeedClient {
        UpdateFeedClient(feedURL: Brand.releasesFeed, userAgent: "transcribe-thing/0.2.0") { try await self($0) }
    }
}

@Suite struct UpdateFeedClientTests {
    @Test func sendsGitHubHeadersAndRevalidatesWithTheETag() async throws {
        let feed = FeedFixtures.json([FeedFixtures.release("v0.3.0")])
        let stub = StubTransport([.success((feed, 200, ["ETag": #"W/"abc""#])), .success((Data(), 304, [:]))])
        let client = stub.client()

        let first = try await client.fetch(etag: nil)
        guard case .releases(let releases, let etag) = first else { Issue.record("expected releases"); return }
        #expect(releases.map(\.version.description) == ["0.3.0"])
        #expect(etag == #"W/"abc""#)

        #expect(try await client.fetch(etag: etag) == .notModified)

        let requests = stub.requests
        #expect(requests[0].url == Brand.releasesFeed)
        #expect(requests[0].value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(requests[0].value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(requests[0].value(forHTTPHeaderField: "User-Agent") == "transcribe-thing/0.2.0")
        #expect(requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == #"W/"abc""#)
        #expect(requests[0].timeoutInterval == 15)
        #expect(Brand.releasesFeed.absoluteString == "https://api.github.com/repos/xcviko/transcribe-thing/releases?per_page=30")
    }

    @Test func mapsFailures() async {
        func failure(_ answer: Result<(Data, Int, [String: String]), URLError>) async -> UpdateCheckError? {
            do {
                _ = try await StubTransport([answer]).client().fetch(etag: nil)
                return nil
            } catch {
                return error
            }
        }
        #expect(await failure(.failure(URLError(.notConnectedToInternet))) == .offline)
        #expect(await failure(.success((Data(), 404, [:]))) == .notFound)
        #expect(await failure(.success((Data(), 403, ["X-RateLimit-Remaining": "0"]))) == .rateLimited)
        #expect(await failure(.success((Data(), 403, [:]))) == .http(403))
        #expect(await failure(.success((Data(), 500, [:]))) == .http(500))
        if case .unreadable? = await failure(.success((Data("{".utf8), 200, [:]))) {} else {
            Issue.record("garbage should be unreadable")
        }
    }

    @Test func readsFileFeeds() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tt-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("releases.json")
        try FeedFixtures.json([FeedFixtures.release("v9.9.9")]).write(to: file)
        let result = try await UpdateFeedClient(feedURL: file, userAgent: "test").fetch(etag: nil)
        guard case .releases(let releases, _) = result else { Issue.record("expected releases"); return }
        #expect(releases.first?.version == AppVersion("9.9.9"))
    }

    @Test func cacheRoundTrips() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tt-cache-\(UUID().uuidString)/updates.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let cache = UpdateFeedCache(feedURL: Brand.releasesFeed, releases: PreviewFixtures.releases(now: Date(timeIntervalSince1970: 1_790_000_000)),
                                    etag: "\"x\"", lastChecked: Date(timeIntervalSince1970: 1_790_000_000))
        try cache.save(to: file)
        #expect(UpdateFeedCache.load(from: file) == cache)
    }
}

// MARK: - Policy

@Suite struct UpdatePolicyTests {
    let latest = PreviewFixtures.releases()[0]
    let installed = PreviewFixtures.installedVersion

    private func policy(auto: Bool = true, current: AppVersion? = PreviewFixtures.installedVersion,
                        latest: Release? = PreviewFixtures.releases()[0], announced: String? = nil) -> UpdatePolicy {
        UpdatePolicy(checksAutomatically: auto, current: current, latest: latest, announcedVersion: announced)
    }

    @Test func anUpdateIsStrictlyNewer() {
        #expect(policy().available?.version == AppVersion("0.3.0"))
        #expect(policy(current: AppVersion("0.3.0")).available == nil, "the same version isn't an update")
        #expect(policy(current: AppVersion("0.4.0")).available == nil, "a dev build ahead of the releases")
        #expect(policy(latest: nil).available == nil, "no releases yet")
        #expect(policy(current: nil).available == nil, "the bare binary has nothing to update")
    }

    @Test func announcesEachVersionOnce() {
        #expect(policy().shouldAnnounce)
        #expect(!policy(announced: "0.3.0").shouldAnnounce, "already shown (closed, timed out or acted on)")
        #expect(policy(announced: "0.2.5").shouldAnnounce, "a newer version announces again")
        #expect(!policy(announced: "0.4.0").shouldAnnounce)
        #expect(!policy(auto: false).shouldAnnounce, "updates ignored: never")
        #expect(!policy(current: AppVersion("0.3.0")).shouldAnnounce)
    }

    @Test func badgesUntilInstalledUnlessIgnored() {
        #expect(policy().showsBadge)
        #expect(policy(announced: "0.3.0").showsBadge, "skipping the toast keeps the badge")
        #expect(!policy(auto: false).showsBadge)
        #expect(!policy(current: AppVersion("0.3.0")).showsBadge)
    }

    @Test func schedulesChecks() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(UpdatePolicy.isDue(lastCheck: nil, now: now, maxAge: 60))
        #expect(!UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-59), now: now, maxAge: 60))
        #expect(UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(-60), now: now, maxAge: 60))
        #expect(UpdatePolicy.isDue(lastCheck: now.addingTimeInterval(3600), now: now, maxAge: 60), "clock went back")
        #expect(UpdatePolicy.delayUntilNextCheck(lastCheck: nil, now: now) == 6 * 3600)
        #expect(UpdatePolicy.delayUntilNextCheck(lastCheck: now.addingTimeInterval(-3600), now: now) == 5 * 3600)
        #expect(UpdatePolicy.delayUntilNextCheck(lastCheck: now.addingTimeInterval(-7 * 3600), now: now) == 60)
    }

    @Test func notesTheFirstLaunchAfterAnUpdate() {
        let current = AppVersion(major: 0, minor: 3)
        #expect(UpdatePolicy.isFirstLaunchAfterUpdate(lastLaunched: "0.2.0", current: current))
        #expect(!UpdatePolicy.isFirstLaunchAfterUpdate(lastLaunched: nil, current: current), "fresh install")
        #expect(!UpdatePolicy.isFirstLaunchAfterUpdate(lastLaunched: "0.3.0", current: current))
        #expect(!UpdatePolicy.isFirstLaunchAfterUpdate(lastLaunched: "0.4.0", current: current), "a downgrade")
    }
}

@Suite struct UpdateFormatTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func downloadProgress() {
        #expect(UpdateFormat.progress(received: 4_200_000, total: 12_400_000) == "4.2 of 12.4 MB")
        #expect(UpdateFormat.progress(received: 820_000, total: 12_400_000) == "820 KB of 12.4 MB")
        #expect(UpdateFormat.progress(received: 4_200_000, total: nil) == "4.2 MB")
    }

    @Test func checkedAgo() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 15))!
        #expect(UpdateFormat.checkedAgo(now.addingTimeInterval(-20), now: now, calendar: calendar) == "checked just now")
        #expect(UpdateFormat.checkedAgo(now.addingTimeInterval(-5 * 60), now: now, calendar: calendar) == "checked 5 min ago")
        #expect(UpdateFormat.checkedAgo(now.addingTimeInterval(-3 * 3600), now: now, calendar: calendar) == "checked 3 h ago")
        #expect(UpdateFormat.checkedAgo(now.addingTimeInterval(-20 * 3600), now: now, calendar: calendar) == "checked yesterday")
        #expect(UpdateFormat.checkedAgo(now.addingTimeInterval(-20 * 86_400), now: now, calendar: calendar) == "checked Sep 5")
    }
}

// MARK: - Update center

@MainActor
@Suite(.serialized) struct UpdateCenterTests {
    struct Harness {
        let center: UpdateCenter
        let settings: AppSettings
        let toasts: ToastCenter
        let stub: StubTransport
        let cache: URL
    }

    static func make(feed: [[String: Any]] = [FeedFixtures.release("v0.3.0", body: "Faster startup. And more.",
                                                                   assets: ["transcribe-thing-0.3.0.zip"], size: 3),
                                             FeedFixtures.release("v0.2.0")],
                     installer: UpdateInstaller? = nil, runsInBackground: Bool = false,
                     failsAfterFirstCheck: Bool = false) -> Harness {
        let settings = AppSettings.inMemory()
        let toasts = ToastCenter(clock: { Date() }, schedulesExpiry: false)
        let stub = StubTransport([.success((FeedFixtures.json(feed), 200, ["ETag": "\"e1\""])),
                                  failsAfterFirstCheck ? .failure(URLError(.notConnectedToInternet)) : .success((Data(), 304, [:]))])
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("tt-updates-\(UUID().uuidString)/updates.json")
        var makeInstaller: (@MainActor () -> UpdateInstaller?)?
        if let installer { makeInstaller = { installer } }
        let center = UpdateCenter(settings: settings, toasts: toasts, currentVersion: AppVersion("0.2.0"),
                                  client: stub.client(), cacheFile: cache,
                                  makeInstaller: makeInstaller, runsInBackground: runsInBackground)
        // Never the real browser, relaunch or quit.
        center.openURL = { _ in }
        center.relaunch = { _ in }
        center.terminate = {}
        return Harness(center: center, settings: settings, toasts: toasts, stub: stub, cache: cache)
    }

    @Test func checkKeepsTheFeedAndRevalidatesIt() async throws {
        let h = Self.make()
        defer { try? FileManager.default.removeItem(at: h.cache.deletingLastPathComponent()) }
        await h.center.check()
        #expect(h.center.availableUpdate?.version == AppVersion("0.3.0"))
        #expect(h.center.lastChecked != nil && h.center.checkError == nil)
        let saved = try #require(UpdateFeedCache.load(from: h.cache))
        #expect(saved.etag == "\"e1\"" && saved.releases.count == 2)

        await h.center.check()
        #expect(h.stub.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"e1\"")
        #expect(h.center.releases.count == 2, "304 keeps what was cached")
    }

    @Test func noReleasesIsUpToDate() async {
        let h = Self.make(feed: [])
        defer { try? FileManager.default.removeItem(at: h.cache.deletingLastPathComponent()) }
        await h.center.check()
        #expect(h.center.checkError == nil)
        #expect(h.center.availableUpdate == nil && !h.center.showsBadge)
        #expect(UpdateFormat.summary(h.center, now: Date()).hasPrefix("Up to date"))
    }

    @Test func announcesOncePerVersion() async {
        let h = Self.make()
        defer { try? FileManager.default.removeItem(at: h.cache.deletingLastPathComponent()) }
        await h.center.check()
        h.center.announceIfDue()
        let notice = h.toasts.notices.first { $0.dedupeKey == UpdateCenter.availableKey }
        #expect(notice?.title == "\(Brand.name) 0.3.0 is available")
        #expect(notice?.body == "Faster startup.")
        #expect(notice?.actions.map(\.kind) == [.installUpdate, .openHub(.softwareUpdate)])
        #expect(notice?.lifetime == .seconds(15) && notice?.sound == nil)
        #expect(h.settings.announcedUpdateVersion == "0.3.0")

        h.toasts.dismissAll()
        h.center.announceIfDue()
        #expect(h.toasts.notices.isEmpty, "closed = skipped for this version")
        #expect(h.center.showsBadge, "the badge stays until it's installed")
    }

    @Test func waitsForAQuietMomentAndRespectsTheSetting() async {
        let h = Self.make()
        defer { try? FileManager.default.removeItem(at: h.cache.deletingLastPathComponent()) }
        await h.center.check()
        h.center.isDictationActive = { true }
        h.center.announceIfDue()
        #expect(h.toasts.notices.isEmpty && h.settings.announcedUpdateVersion == nil)

        h.center.isDictationActive = { false }
        h.settings.checkForUpdatesAutomatically = false
        h.center.announceIfDue()
        #expect(h.toasts.notices.isEmpty, "ignored updates are never announced")
        #expect(!h.center.showsBadge)
    }

    @Test func aFailedDictationCancelsThePendingAnnouncement() async throws {
        // Only an .app announces; start() isn't called, so nothing else runs in the background.
        let h = Self.make(runsInBackground: true)
        defer { try? FileManager.default.removeItem(at: h.cache.deletingLastPathComponent()) }
        await h.center.check()
        h.center.dictationDelivered()
        h.center.dictationFailed()
        try await Task.sleep(for: .seconds(UpdatePolicy.announceDelay + 0.3))
        #expect(h.toasts.notices.isEmpty && h.settings.announcedUpdateVersion == nil, "the error toast has the pill")

        h.center.dictationDelivered()
        try await waitUntil { !h.toasts.notices.isEmpty }
        #expect(h.settings.announcedUpdateVersion == "0.3.0", "the next paste announces it")
    }

    @Test func theGeneralRowAgreesWithThePageAfterAFailedCheck() async {
        let h = Self.make(feed: [], failsAfterFirstCheck: true)
        defer { try? FileManager.default.removeItem(at: h.cache.deletingLastPathComponent()) }
        await h.center.check()
        #expect(UpdateFormat.summary(h.center, now: Date()).hasPrefix("Up to date"))
        await h.center.check()
        #expect(h.center.checkError != nil && h.center.lastChecked != nil)
        #expect(UpdateFormat.summary(h.center, now: Date()) == "Couldn’t check for updates")
    }

    @Test func installsThenRelaunches() async throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanUp() }
        let h = Self.make(installer: fixture.installer())
        defer { try? FileManager.default.removeItem(at: h.cache.deletingLastPathComponent()) }
        await h.center.check()
        var relaunched: URL?
        var terminated = false
        var busy = true
        h.center.relaunch = { relaunched = $0 }
        h.center.terminate = { terminated = true }
        h.center.isDictationActive = { busy }
        h.center.installUpdate()
        try await waitUntil { h.center.install == .waitingForDictation(AppVersion(major: 0, minor: 3)) }
        #expect(fixture.installedVersion == "0.2.0", "nothing replaced while dictating")
        busy = false
        try await waitUntil { terminated }
        #expect(relaunched == fixture.target)
        #expect(h.center.install == .restarting(AppVersion(major: 0, minor: 3)))
        #expect(fixture.installedVersion == "0.3.0")
    }

    @Test func aFailedRelaunchAsksForARestartInsteadOfReinstalling() async throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanUp() }
        let h = Self.make(installer: fixture.installer())
        defer { try? FileManager.default.removeItem(at: h.cache.deletingLastPathComponent()) }
        await h.center.check()
        var terminated = false
        h.center.relaunch = { _ in throw CocoaError(.executableNotLoadable) }
        h.center.terminate = { terminated = true }
        h.center.installUpdate()
        let version = AppVersion(major: 0, minor: 3)
        try await waitUntil { h.center.install == .needsRestart(version) }
        #expect(fixture.installedVersion == "0.3.0" && !terminated)
        #expect(h.center.install.isBusy, "Update Now can't install it a second time")
        #expect(UpdateFormat.summary(h.center, now: Date()) == "Reopen \(Brand.name) to finish updating to 0.3.0")
        h.center.quitToFinishUpdate()
        #expect(terminated)
    }

    @Test func failureOffersTheReleasePage() async throws {
        let fixture = try InstallerFixture(signatureOK: false)
        defer { fixture.cleanUp() }
        let h = Self.make(installer: fixture.installer())
        defer { try? FileManager.default.removeItem(at: h.cache.deletingLastPathComponent()) }
        await h.center.check()
        h.center.installUpdate()
        try await waitUntil { if case .failed = h.center.install { true } else { false } }
        guard case .failed(_, let error) = h.center.install else { return }
        #expect(error == .signatureMismatch("fake mismatch"))
        #expect(!error.isRetryable)
        #expect(fixture.installedVersion == "0.2.0")
    }

    @Test func aReleaseWithoutAZipOpensItsPage() async throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanUp() }
        let h = Self.make(feed: [FeedFixtures.release("v0.3.0", assets: ["notes.pdf"])], installer: fixture.installer())
        defer { try? FileManager.default.removeItem(at: h.cache.deletingLastPathComponent()) }
        var opened: [URL] = []
        h.center.openURL = { opened.append($0) }
        await h.center.check()
        h.center.installUpdate()
        try await waitUntil { if case .failed = h.center.install { true } else { false } }
        #expect(h.center.install == .failed(AppVersion(major: 0, minor: 3), .noInstallableAsset))
        #expect(opened.map(\.absoluteString) == ["https://github.com/xcviko/transcribe-thing/releases/tag/v0.3.0"])
    }

    @Test func noInstallerMeansThisCopyCantUpdateItself() async {
        let h = Self.make()
        defer { try? FileManager.default.removeItem(at: h.cache.deletingLastPathComponent()) }
        await h.center.check()
        h.center.installUpdate()
        #expect(h.center.install == .failed(AppVersion(major: 0, minor: 3), .adHocSigned))
        #expect(UpdateInstallError.adHocSigned.message == "This copy can’t update itself. Download the new version from GitHub.")
    }
}

// MARK: - Installer

/// A temporary "installed" app and fakes for every side effect.
struct InstallerFixture {
    let root: URL
    let target: URL
    var bundleID = "dev.transcribe-thing.app"
    var zipBundleID = "dev.transcribe-thing.app"
    var zipVersion = "0.3.0"
    var appsInZip = 1
    /// The zip's transcribe-thing.app is a relative symlink to a real one two folders down.
    var appIsSymlink = false
    var signatureOK = true
    var adHoc = false
    var writable = true

    init(signatureOK: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tt-install-\(UUID().uuidString)", isDirectory: true)
        target = root.appendingPathComponent("Applications/transcribe-thing.app", isDirectory: true)
        self.signatureOK = signatureOK
        try Self.makeApp(at: target, id: bundleID, version: "0.2.0")
    }

    static func makeApp(at url: URL, id: String, version: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    var installedVersion: String? {
        (NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    func installer(target: URL? = nil) -> UpdateInstaller {
        let fixture = self
        return UpdateInstaller(target: target ?? self.target, bundleIdentifier: bundleID, operations: .init(
            download: { _, destination, progress in
                try Data("zip".utf8).write(to: destination)
                progress(3, 3)
            },
            unzip: { _, destination in
                if fixture.appIsSymlink {
                    try InstallerFixture.makeApp(at: destination.appendingPathComponent("a/b/transcribe-thing.app"),
                                                 id: fixture.zipBundleID, version: fixture.zipVersion)
                    try FileManager.default.createSymbolicLink(atPath: destination.appendingPathComponent("transcribe-thing.app").path,
                                                               withDestinationPath: "a/b/transcribe-thing.app")
                    return
                }
                for index in 0..<fixture.appsInZip {
                    let folder = index == 0 ? destination : destination.appendingPathComponent("copy\(index)")
                    try InstallerFixture.makeApp(at: folder.appendingPathComponent("transcribe-thing.app"),
                                                 id: fixture.zipBundleID, version: fixture.zipVersion)
                }
            },
            requirementSourceIsAdHoc: { fixture.adHoc },
            verifySignature: { _ in
                if !fixture.signatureOK { throw UpdateInstallError.signatureMismatch("fake mismatch") }
            },
            stripQuarantine: { _ in },
            isWritable: { _ in fixture.writable },
            replace: { target, newApp in try AtomicReplace.replace(target, with: newApp) }),
            workRoot: root.appendingPathComponent("work", isDirectory: true))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    static func release(_ version: String = "0.3.0", assets: [String]? = nil) -> Release {
        let names = assets ?? ["transcribe-thing-\(version).zip"]
        return Release(version: AppVersion(version)!, tag: "v\(version)", title: nil, notes: "", publishedAt: nil,
                       pageURL: Brand.releasesPage,
                       assets: names.map { ReleaseAsset(name: $0, url: URL(string: "https://example.com/\($0)")!, size: 3) })
    }
}

final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _steps: [UpdateInstaller.Step] = []
    var steps: [UpdateInstaller.Step] { lock.withLock { _steps } }
    func append(_ step: UpdateInstaller.Step) { lock.withLock { _steps.append(step) } }
}

@Suite(.serialized) struct UpdateInstallerTests {
    private func failure(_ fixture: InstallerFixture, release: Release = InstallerFixture.release(),
                         target: URL? = nil) async -> UpdateInstallError? {
        do {
            let installer = fixture.installer(target: target)
            let prepared = try await installer.prepare(release) { _ in }
            try installer.install(prepared)
            return nil
        } catch {
            return error as? UpdateInstallError
        }
    }

    @Test func installsAVerifiedCopyInPlace() async throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanUp() }
        let installer = fixture.installer()
        let log = StepLog()
        let prepared = try await installer.prepare(InstallerFixture.release()) { log.append($0) }
        #expect(fixture.installedVersion == "0.2.0", "prepare never touches the installed app")
        try installer.install(prepared)
        #expect(fixture.installedVersion == "0.3.0")
        #expect(!FileManager.default.fileExists(atPath: prepared.workDirectory.path), "the work folder is cleaned up")
        #expect(log.steps.contains(.unpacking) && log.steps.contains(.verifying))
    }

    @Test func refusesTheWrongApp() async throws {
        var fixture = try InstallerFixture()
        defer { fixture.cleanUp() }
        fixture.zipBundleID = "com.example.other"
        #expect(await failure(fixture) == .wrongBundle("com.example.other"))
        #expect(fixture.installedVersion == "0.2.0")
    }

    @Test func refusesTheWrongVersion() async throws {
        var fixture = try InstallerFixture()
        defer { fixture.cleanUp() }
        fixture.zipVersion = "0.2.9"
        #expect(await failure(fixture) == .wrongVersion(expected: "0.3.0", found: "0.2.9"))
        fixture.zipVersion = "0.3"
        #expect(await failure(fixture) == nil, "0.3 is 0.3.0")
    }

    @Test func refusesAnotherSigner() async throws {
        let fixture = try InstallerFixture(signatureOK: false)
        defer { fixture.cleanUp() }
        #expect(await failure(fixture) == .signatureMismatch("fake mismatch"))
        #expect(fixture.installedVersion == "0.2.0")
    }

    @Test func anAdHocCopyCantUpdateItself() async throws {
        var fixture = try InstallerFixture()
        defer { fixture.cleanUp() }
        fixture.adHoc = true
        #expect(await failure(fixture) == .adHocSigned)
    }

    @Test func refusesTranslocatedAndReadOnlyCopies() async throws {
        var fixture = try InstallerFixture()
        defer { fixture.cleanUp() }
        let translocated = URL(fileURLWithPath: "/private/var/folders/xy/T/AppTranslocation/1A2B/d/transcribe-thing.app")
        #expect(await failure(fixture, target: translocated) == .translocated)
        fixture.writable = false
        #expect(await failure(fixture) == .notWritable(fixture.target.deletingLastPathComponent().path))
    }

    @Test func needsAZipAndExactlyOneApp() async throws {
        var fixture = try InstallerFixture()
        defer { fixture.cleanUp() }
        #expect(await failure(fixture, release: InstallerFixture.release(assets: ["notes.txt"])) == .noInstallableAsset)
        fixture.appsInZip = 2
        if case .badArchive? = await failure(fixture) {} else { Issue.record("two apps must be refused") }
        fixture.appsInZip = 0
        if case .badArchive? = await failure(fixture) {} else { Issue.record("no app must be refused") }
    }

    @Test func theAssetNameNeverBecomesAPath() async throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanUp() }
        let hostile = InstallerFixture.release(assets: ["../../escaped.zip"])
        let installer = fixture.installer()
        let prepared = try await installer.prepare(hostile) { _ in }
        defer { installer.discard(prepared) }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("escaped.zip").path))
        let archive = prepared.workDirectory.appendingPathComponent(UpdateInstaller.archiveName)
        #expect(FileManager.default.fileExists(atPath: archive.path))
    }

    @Test func refusesASymlinkedApp() async throws {
        var fixture = try InstallerFixture()
        defer { fixture.cleanUp() }
        fixture.appIsSymlink = true
        if case .badArchive? = await failure(fixture) {} else { Issue.record("a symlinked app must be refused") }
        #expect(fixture.installedVersion == "0.2.0")
    }

    @Test func realReplaceSwapsTheBundle() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanUp() }
        let staged = fixture.root.appendingPathComponent("new/transcribe-thing.app")
        try InstallerFixture.makeApp(at: staged, id: fixture.bundleID, version: "9.9.9")
        try AtomicReplace.replace(fixture.target, with: staged)
        #expect(fixture.installedVersion == "9.9.9")
    }

    @Test func relaunchScriptTakesItsInputsAsArguments() {
        #expect(!Relauncher.script.contains("/Applications"))
        #expect(Relauncher.script.contains(#"kill -0 "$1""#))
        #expect(Relauncher.script.contains(#"/usr/bin/open "$2""#))
    }
}

// MARK: - Release notes

@Suite struct ReleaseNotesParserTests {
    @Test func headingsParagraphsAndRules() {
        let blocks = ReleaseNotes.blocks("""
        # Title
        First line
        second line

        ### Fixes ###
        ---
        Setext
        ======
        """)
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("First line\nsecond line"),
            .heading(level: 3, text: "Fixes"),
            .rule,
            .heading(level: 1, text: "Setext"),
        ])
    }

    @Test func nestedAndOrderedLists() {
        let blocks = ReleaseNotes.blocks("""
        - One
          continued
        - Two
          - Two a
            1. deep
          - Two b
        * Three

        3. Third
        4) Fourth
        """)
        #expect(blocks == [
            .list(ReleaseNotesList(ordered: false, start: 1, items: [
                ReleaseNotesListItem(text: "One\ncontinued"),
                ReleaseNotesListItem(text: "Two", children: [
                    .list(ReleaseNotesList(ordered: false, start: 1, items: [
                        ReleaseNotesListItem(text: "Two a", children: [
                            .list(ReleaseNotesList(ordered: true, start: 1, items: [ReleaseNotesListItem(text: "deep")])),
                        ]),
                        ReleaseNotesListItem(text: "Two b"),
                    ])),
                ]),
                ReleaseNotesListItem(text: "Three"),
            ])),
            .list(ReleaseNotesList(ordered: true, start: 3, items: [
                ReleaseNotesListItem(text: "Third"), ReleaseNotesListItem(text: "Fourth"),
            ])),
        ])
    }

    @Test func aParagraphAfterABlankLineEndsTheList() {
        #expect(ReleaseNotes.blocks("- a\n\nAfter") == [
            .list(ReleaseNotesList(ordered: false, start: 1, items: [ReleaseNotesListItem(text: "a")])),
            .paragraph("After"),
        ])
    }

    @Test func codeFencesKeepTheirText() {
        let blocks = ReleaseNotes.blocks("""
        Run:
        ```sh
        xattr -dr com.apple.quarantine /Applications/transcribe-thing.app
        # not a heading
        ```
        """)
        #expect(blocks == [
            .paragraph("Run:"),
            .code("xattr -dr com.apple.quarantine /Applications/transcribe-thing.app\n# not a heading"),
        ])
    }

    @Test func aCodeFenceInsideAListItemStaysInIt() {
        let blocks = ReleaseNotes.blocks("- item\n  ```\n  code in item\n    indented\n  ```\n- next")
        #expect(blocks == [
            .list(ReleaseNotesList(ordered: false, start: 1, items: [
                ReleaseNotesListItem(text: "item", children: [.code("code in item\n  indented")]),
                ReleaseNotesListItem(text: "next"),
            ])),
        ])
        #expect(ReleaseNotes.blocks("- item\n```\ncode\n```") == [
            .list(ReleaseNotesList(ordered: false, start: 1, items: [ReleaseNotesListItem(text: "item")])),
            .code("code"),
        ], "an unindented fence ends the list")
    }

    @Test func boldIsNotABullet() {
        #expect(ReleaseNotes.blocks("**Bold** start") == [.paragraph("**Bold** start")])
    }

    @Test func inlineFormattingAndLinks() {
        let text = ReleaseNotes.inline("**Fix** in [#12](https://github.com/o/r/pull/12)\nnext")
        #expect(String(text.characters) == "Fix in #12\nnext")
        #expect(text.runs.contains { $0.link == URL(string: "https://github.com/o/r/pull/12") })
    }
}

@Suite struct ReleaseNotesTidyTests {
    @Test func tidiesGitHubGeneratedNotes() {
        let generated = """
        <!-- Release notes generated using configuration in .github/release.yml at main -->

        ## What's Changed
        * Faster paste by @xcviko in https://github.com/xcviko/transcribe-thing/pull/12
        * Bump deps by @dependabot[bot] in https://github.com/xcviko/transcribe-thing/pull/13

        ## New Contributors
        * @someone made their first contribution in https://github.com/xcviko/transcribe-thing/pull/14

        **Full Changelog**: https://github.com/xcviko/transcribe-thing/compare/v0.1.0...v0.2.0
        """
        #expect(ReleaseNotes.tidy(generated) == """
        * Faster paste ([#12](https://github.com/xcviko/transcribe-thing/pull/12))
        * Bump deps ([#13](https://github.com/xcviko/transcribe-thing/pull/13))

        ## New Contributors
        * @someone made their first contribution ([#14](https://github.com/xcviko/transcribe-thing/pull/14))

        [Full changelog](https://github.com/xcviko/transcribe-thing/compare/v0.1.0...v0.2.0)
        """)
    }

    @Test func linksBareURLsButNotLinksOrCode() {
        #expect(ReleaseNotes.tidy("See https://example.com/a.") == "See <https://example.com/a>.")
        #expect(ReleaseNotes.tidy("[here](https://example.com)") == "[here](https://example.com)")
        #expect(ReleaseNotes.tidy("<https://example.com>") == "<https://example.com>")
        #expect(ReleaseNotes.tidy("```\nhttps://example.com\n```") == "```\nhttps://example.com\n```")
        #expect(ReleaseNotes.tidy("Add `https://example.com/x` support") == "Add `https://example.com/x` support")
        #expect(ReleaseNotes.tidy("Run `curl https://x.io/install.sh | sh` or https://x.io")
                == "Run `curl https://x.io/install.sh | sh` or <https://x.io>")
        #expect(ReleaseNotes.tidy("Unclosed ` https://x.io") == "Unclosed ` <https://x.io>")
    }

    @Test func layoutHTMLGoesAndItsTextStays() {
        let notes = "- shown\n<details><summary>More</summary>\n\n- hidden\n</details>\n<img src=\"https://x.com/a.png\">"
        #expect(ReleaseNotes.tidy(notes) == "- shown\n\n- hidden")
        #expect(ReleaseNotes.summary("<details><summary>More</summary>\n\n- hidden\n</details>") == "hidden")
        #expect(ReleaseNotes.summary("<table><tr><td>x</td></tr></table>\n\nReal news.") == "Real news.")
        #expect(ReleaseNotes.tidy("Keep `<br>` as code") == "Keep `<br>` as code")
    }

    @Test func summaryForTheToast() {
        #expect(ReleaseNotes.summary("## What's Changed\n* Faster paste by @x in https://github.com/o/r/pull/12") == "Faster paste")
        #expect(ReleaseNotes.summary("# 0.3.0\n\nHands-free keeps going. And more.") == "Hands-free keeps going.")
        #expect(ReleaseNotes.summary("**Full Changelog**: https://github.com/o/r/compare/v1...v2") == nil)
        #expect(ReleaseNotes.summary("") == nil)
        let long = String(repeating: "word ", count: 40)
        #expect(ReleaseNotes.summary(long) == String(repeating: "word ", count: 16) + "word…", "cut between words")
        #expect(ReleaseNotes.summary(String(repeating: "x", count: 120))?.count == 90)
    }
}
