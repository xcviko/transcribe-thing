import AppKit
import Observation

/// Pure update decisions: what counts as an update, when the pill announces it, when badges show, when to check.
struct UpdatePolicy: Equatable, Sendable {
    /// The first background check waits for launch to settle.
    static let launchDelay: TimeInterval = 18
    static let interval: TimeInterval = 6 * 3600
    /// Opening Software Update checks again when the last check is older than this.
    static let pageRefreshAge: TimeInterval = 60
    /// After the paste's own feedback (sound, check mark) has played.
    static let announceDelay: TimeInterval = 0.9
    /// Lets the network come back after a wake before checking.
    static let wakeDelay: TimeInterval = 10
    static let announceLifetime: TimeInterval = 15

    var checksAutomatically: Bool
    var current: AppVersion?
    /// The newest published release, if any.
    var latest: Release?
    /// `AppSettings.announcedUpdateVersion`.
    var announcedVersion: String?

    /// The latest release when it is strictly newer than the running version (never for the bare binary).
    var available: Release? {
        guard let latest, let current, latest.version > current else { return nil }
        return latest
    }

    /// Red "1" on General, the Software Update row and the menu item, until it's installed. Turning automatic
    /// checks off means ignoring updates: no badges anywhere.
    var showsBadge: Bool { checksAutomatically && available != nil }

    /// Once per version: closing the toast, or letting it time out, skips that version; a newer one announces again.
    var shouldAnnounce: Bool {
        guard checksAutomatically, let available else { return false }
        guard let announced = announcedVersion.flatMap(AppVersion.init) else { return true }
        return announced < available.version
    }

    static func isDue(lastCheck: Date?, now: Date, maxAge: TimeInterval) -> Bool {
        guard let lastCheck else { return true }
        // A clock set backwards counts as due too.
        return now.timeIntervalSince(lastCheck) >= maxAge || now < lastCheck
    }

    /// How long the background loop sleeps before the next scheduled check.
    static func delayUntilNextCheck(lastCheck: Date?, now: Date) -> TimeInterval {
        guard let lastCheck, now >= lastCheck else { return interval }
        return min(interval, max(60, lastCheck.addingTimeInterval(interval).timeIntervalSince(now)))
    }

    /// The first launch of a newer version than last time ("Updated to …"); never on a fresh install.
    static func isFirstLaunchAfterUpdate(lastLaunched: String?, current: AppVersion) -> Bool {
        guard let previous = lastLaunched.flatMap(AppVersion.init) else { return false }
        return previous < current
    }
}

/// Checks GitHub Releases for new versions, announces them once in the pill, feeds the badges and the Software
/// Update page, and installs them in place.
@MainActor @Observable
final class UpdateCenter {
    enum InstallPhase: Equatable, Sendable {
        case idle
        case downloading(AppVersion, received: Int64, total: Int64?)
        case verifying(AppVersion)
        /// Ready to install; waits while a dictation is recording or being transcribed.
        case waitingForDictation(AppVersion)
        case installing(AppVersion)
        case restarting(AppVersion)
        /// Installed, but the relaunch didn't start: quitting and reopening finishes it. Installing again would
        /// only replace the app a second time.
        case needsRestart(AppVersion)
        case failed(AppVersion, UpdateInstallError)

        /// Downloading through needing a restart: another install can't start.
        var isBusy: Bool {
            switch self {
            case .idle, .failed: false
            case .downloading, .verifying, .waitingForDictation, .installing, .restarting, .needsRestart: true
            }
        }

        var version: AppVersion? {
            switch self {
            case .idle: nil
            case .downloading(let v, _, _), .verifying(let v), .waitingForDictation(let v), .installing(let v),
                 .restarting(let v), .needsRestart(let v), .failed(let v, _):
                v
            }
        }
    }

    nonisolated static let availableKey = "update.available"
    nonisolated static let installedKey = "update.installed"

    /// Newest first; drafts and prereleases never get here.
    private(set) var releases: [Release] = []
    /// The last successful check (also restored from disk).
    private(set) var lastChecked: Date?
    private(set) var isChecking = false
    /// Why the last check failed; cleared by the next success.
    private(set) var checkError: UpdateCheckError?
    private(set) var install: InstallPhase = .idle
    /// The running version; nil for the bare binary.
    let currentVersion: AppVersion?

    // Wiring the composition root adds after init.
    /// A dictation is recording or being transcribed: the announcement and the restart wait for it.
    @ObservationIgnored var isDictationActive: @MainActor () -> Bool = { false }
    @ObservationIgnored var openURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    @ObservationIgnored var relaunch: @MainActor (URL) throws -> Void = { try Relauncher.spawn(opening: $0) }
    @ObservationIgnored var terminate: @MainActor () -> Void = { NSApp.terminate(nil) }
    @ObservationIgnored var clock: @MainActor () -> Date = { Date() }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private let client: UpdateFeedClient?
    @ObservationIgnored private let cacheFile: URL?
    @ObservationIgnored private let makeInstaller: (@MainActor () -> UpdateInstaller?)?
    /// A real .app bundle: background checks, announcements and the post-update notice run only then.
    @ObservationIgnored private let runsInBackground: Bool
    @ObservationIgnored private var etag: String?
    /// The last check attempt, successful or not: it paces background checks.
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored private var announceTask: Task<Void, Never>?
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: MainNotificationObserver?

    init(settings: AppSettings, toasts: ToastCenter, currentVersion: AppVersion?, client: UpdateFeedClient?,
         cacheFile: URL?, makeInstaller: (@MainActor () -> UpdateInstaller?)?, runsInBackground: Bool) {
        self.settings = settings
        self.toasts = toasts
        self.currentVersion = currentVersion
        self.client = client
        self.cacheFile = cacheFile
        self.makeInstaller = makeInstaller
        self.runsInBackground = runsInBackground
    }

    /// GitHub for real. Background checks only when running as an .app (not `swift run`, the CLI or tests).
    static func live(settings: AppSettings, toasts: ToastCenter, paths: AppPaths) -> UpdateCenter {
        let version = AppVersion.running
        let bundle = Bundle.main.bundleURL
        let isAppBundle = bundle.pathExtension == "app"
        let identifier = Bundle.main.bundleIdentifier ?? Log.subsystem
        var makeInstaller: (@MainActor () -> UpdateInstaller?)?
        if isAppBundle {
            makeInstaller = { UpdateInstaller.live(target: bundle, bundleIdentifier: identifier, requirement: .runningApp) }
        }
        return UpdateCenter(
            settings: settings, toasts: toasts, currentVersion: version, client: .live(version: version),
            cacheFile: paths.updateFeedFile, makeInstaller: makeInstaller, runsInBackground: isAppBundle)
    }

    /// Frozen state for snapshots and tests: never checks, downloads or installs.
    static func preview(settings: AppSettings, toasts: ToastCenter? = nil,
                        current: AppVersion? = PreviewFixtures.installedVersion,
                        releases: [Release] = PreviewFixtures.releases(upTo: PreviewFixtures.installedVersion),
                        lastChecked: Date? = Date().addingTimeInterval(-5 * 60), isChecking: Bool = false,
                        checkError: UpdateCheckError? = nil, install: InstallPhase = .idle) -> UpdateCenter {
        let center = UpdateCenter(settings: settings, toasts: toasts ?? .preview([]), currentVersion: current, client: nil,
                                  cacheFile: nil, makeInstaller: nil, runsInBackground: false)
        center.releases = releases
        center.lastChecked = lastChecked
        center.isChecking = isChecking
        center.checkError = checkError
        center.install = install
        return center
    }

    // MARK: State

    var policy: UpdatePolicy {
        UpdatePolicy(checksAutomatically: settings.checkForUpdatesAutomatically, current: currentVersion,
                     latest: releases.first, announcedVersion: settings.announcedUpdateVersion)
    }

    var availableUpdate: Release? { policy.available }
    var showsBadge: Bool { policy.showsBadge }

    // MARK: Lifecycle

    /// Restores the cached feed, notes an update that just happened, and starts background checks.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        loadCache()
        guard runsInBackground else { return }
        noteLaunch()
        scheduleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(UpdatePolicy.launchDelay))
            var isFirst = true
            while !Task.isCancelled {
                guard let delay = await self?.scheduledCheck(force: isFirst) else { return }
                isFirst = false
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        wakeObserver = MainNotificationObserver(center: NSWorkspace.shared.notificationCenter,
                                                name: NSWorkspace.didWakeNotification) { [weak self] in
            self?.systemDidWake()
        }
    }

    func stop() {
        scheduleTask?.cancel()
        announceTask?.cancel()
        wakeObserver = nil
    }

    /// Checks when automatic checks are on and one is due (always right after launch); returns the next wait.
    private func scheduledCheck(force: Bool) async -> TimeInterval {
        if settings.checkForUpdatesAutomatically,
           force || UpdatePolicy.isDue(lastCheck: lastAttempt, now: clock(), maxAge: UpdatePolicy.interval) {
            await check()
        }
        return UpdatePolicy.delayUntilNextCheck(lastCheck: lastAttempt, now: clock())
    }

    private func systemDidWake() {
        guard settings.checkForUpdatesAutomatically,
              UpdatePolicy.isDue(lastCheck: lastAttempt, now: clock(), maxAge: UpdatePolicy.interval) else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(UpdatePolicy.wakeDelay))
            await self?.check()
        }
    }

    // MARK: Checking

    /// "Check Now": always checks, whatever the setting.
    func checkNow() {
        Task { await check() }
    }

    /// Software Update on screen: a check older than a minute is refreshed, whatever the setting.
    func refreshIfStale() {
        guard UpdatePolicy.isDue(lastCheck: lastAttempt ?? lastChecked, now: clock(), maxAge: UpdatePolicy.pageRefreshAge)
        else { return }
        checkNow()
    }

    /// Failures are logged and kept for the Software Update page; nothing else shows them.
    func check() async {
        guard let client, !isChecking else { return }
        isChecking = true
        lastAttempt = clock()
        defer { isChecking = false }
        do {
            // Only a feed this copy has seen can be revalidated (an empty one included).
            switch try await client.fetch(etag: lastChecked == nil ? nil : etag) {
            case .releases(let list, let tag):
                releases = list
                etag = tag
            case .notModified:
                break
            }
            lastChecked = clock()
            checkError = nil
            saveCache(feedURL: client.feedURL)
            Log.app.info("Update check: latest \(self.releases.first?.version.description ?? "none", privacy: .public), running \(self.currentVersion?.description ?? "unknown", privacy: .public)")
        } catch {
            checkError = error
            Log.app.error("Update check failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadCache() {
        guard let cacheFile, let cache = UpdateFeedCache.load(from: cacheFile) else { return }
        releases = GitHubReleases.sorted(cache.releases)
        lastChecked = cache.lastChecked
        lastAttempt = cache.lastChecked
        // An ETag belongs to the feed it came from (TT_UPDATE_FEED_URL can point elsewhere).
        etag = cache.feedURL == client?.feedURL ? cache.etag : nil
    }

    private func saveCache(feedURL: URL) {
        guard let cacheFile, let lastChecked else { return }
        do {
            try UpdateFeedCache(feedURL: feedURL, releases: releases, etag: etag, lastChecked: lastChecked).save(to: cacheFile)
        } catch {
            Log.app.error("Couldn't save the update feed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Announcing

    /// A dictation was just pasted: the moment to mention a new version, once per version.
    func dictationDelivered() {
        guard runsInBackground, policy.shouldAnnounce, !install.isBusy else { return }
        announceTask?.cancel()
        announceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(UpdatePolicy.announceDelay))
            guard !Task.isCancelled else { return }
            self?.announceIfDue()
        }
    }

    /// A queued dictation failed right after one was pasted: its error toast has the pill to itself, and the
    /// announcement waits for the next paste.
    func dictationFailed() {
        announceTask?.cancel()
        announceTask = nil
    }

    /// Posts the toast and marks the version announced at once: Update, What's New, the close button and a
    /// timeout all end it for this version. Waits for the next dictation if a new one already started.
    func announceIfDue() {
        guard policy.shouldAnnounce, !install.isBusy, let release = availableUpdate, !isDictationActive() else { return }
        settings.announcedUpdateVersion = release.version.description
        toasts.post(Self.availableNotice(release))
        Log.app.info("Announced update \(release.version.description, privacy: .public)")
    }

    nonisolated static func availableNotice(_ release: Release) -> Notice {
        Notice(dedupeKey: availableKey, style: .info, symbol: "arrow.down.circle",
               title: "\(Brand.name) \(release.version) is available",
               body: ReleaseNotes.summary(release.notes) ?? "See what’s new and update in one click.",
               actions: [NoticeAction(title: "Update", kind: .installUpdate, isPrimary: true),
                         NoticeAction(title: "What’s New", kind: .openHub(.softwareUpdate))],
               lifetime: .seconds(UpdatePolicy.announceLifetime))
    }

    /// `notes`: the new version's release notes, when the cached feed has them.
    nonisolated static func installedNotice(_ version: AppVersion, notes: String? = nil) -> Notice {
        Notice(dedupeKey: installedKey, style: .success, symbol: "checkmark.circle.fill",
               title: "Updated to \(Brand.name) \(version)",
               body: notes.flatMap { ReleaseNotes.summary($0) } ?? "See what’s changed in this version.",
               actions: [NoticeAction(title: "What’s New", kind: .openHub(.softwareUpdate), isPrimary: true)],
               lifetime: .seconds(10))
    }

    /// Records this launch's version; the first launch after an update says so in the pill.
    private func noteLaunch() {
        guard let current = currentVersion else { return }
        let updated = UpdatePolicy.isFirstLaunchAfterUpdate(lastLaunched: settings.lastLaunchedVersion, current: current)
        settings.lastLaunchedVersion = current.description
        guard updated else { return }
        Task { [weak self] in
            // Once the pill's panel is up.
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            let notes = self.releases.first { $0.version == current }?.notes
            self.toasts.post(Self.installedNotice(current, notes: notes))
        }
    }

    // MARK: Installing

    /// "Update Now", the toast's Update: download, verify, install, relaunch, with progress on the page.
    func installUpdate() {
        guard !install.isBusy, let release = availableUpdate else { return }
        toasts.dismiss(dedupeKey: Self.availableKey)
        guard let installer = makeInstaller?() else {
            install = .failed(release.version, .adHocSigned)
            return
        }
        installTask = Task { [weak self] in await self?.run(installer, release) }
    }

    /// Stops a download (or the wait for a dictation); nothing is installed.
    func cancelInstall() {
        installTask?.cancel()
    }

    /// "Quit" once the update is installed but the relaunch didn't start.
    func quitToFinishUpdate() {
        terminate()
    }

    func openReleasePage(_ release: Release? = nil) {
        openURL(release?.pageURL ?? Brand.releasesPage)
    }

    private func run(_ installer: UpdateInstaller, _ release: Release) async {
        let version = release.version
        install = .downloading(version, received: 0, total: release.installableAsset.map(\.size))
        var prepared: PreparedUpdate?
        do {
            let ready = try await installer.prepare(release) { [weak self] step in
                Task { @MainActor in self?.apply(step, version) }
            }
            prepared = ready
            if isDictationActive() {
                install = .waitingForDictation(version)
                while isDictationActive() {
                    try await Task.sleep(for: .milliseconds(300))
                }
            }
            try Task.checkCancellation()
            install = .installing(version)
            prepared = nil
            try installer.install(ready)
            install = .restarting(version)
            Log.app.notice("Installed \(version.description, privacy: .public); relaunching")
            do {
                try relaunch(installer.target)
            } catch {
                Log.app.error("Couldn't relaunch after the update: \(error.localizedDescription, privacy: .public)")
                install = .needsRestart(version)
                return
            }
            terminate()
        } catch {
            if let prepared { installer.discard(prepared) }
            let failure = (error as? UpdateInstallError)
                ?? (error is CancellationError ? .cancelled : .installFailed(error.localizedDescription))
            Log.app.error("Update to \(version.description, privacy: .public) failed: \(String(describing: failure), privacy: .public)")
            switch failure {
            case .cancelled:
                install = .idle
            case .noInstallableAsset:
                openReleasePage(release)
                install = .failed(version, failure)
            default:
                install = .failed(version, failure)
            }
        }
    }

    /// Progress hops here from the download's thread; a step that arrives after the flow moved on is dropped.
    private func apply(_ step: UpdateInstaller.Step, _ version: AppVersion) {
        switch (step, install) {
        case (.downloading(let received, let total), .downloading(let v, _, _)) where v == version:
            install = .downloading(version, received: received, total: total)
        case (.unpacking, .downloading(let v, _, _)) where v == version,
             (.verifying, .downloading(let v, _, _)) where v == version:
            install = .verifying(version)
        default:
            break
        }
    }
}

// MARK: - Formatting

/// Copy for the Software Update page and its General row.
enum UpdateFormat {
    private static let locale = Locale(identifier: "en_US")

    /// "Checked today at 14:05", "Checked yesterday at 9:12", "Checked on Monday at 9:12", "Checked on Sep 12 at 9:12".
    static func checkedLine(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let day = Fmt.relativeDay(date, now: now, calendar: calendar)
        let time = Fmt.time(date)
        switch day {
        case "Today": return "Checked today at \(time)"
        case "Yesterday": return "Checked yesterday at \(time)"
        default: return "Checked on \(day) at \(time)"
        }
    }

    /// "checked just now", "checked 5 min ago", "checked 3 h ago", "checked yesterday", "checked Sep 12".
    static func checkedAgo(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "checked just now" }
        if seconds < 3600 { return "checked \(Int(seconds / 60)) min ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "checked \(Int(seconds / 3600)) h ago" }
        let day = Fmt.relativeDay(date, now: now, calendar: calendar)
        return day == "Yesterday" ? "checked yesterday" : "checked \(day)"
    }

    /// "Sep 20", or "Sep 20, 2025" in another year.
    static func date(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "MMMdyyyy")
        return formatter.string(from: date)
    }

    /// "4.2 of 12.4 MB" (the count drops a unit it shares with the total), "820 KB of 12.4 MB", or just "4.2 MB".
    static func progress(received: Int64, total: Int64?) -> String {
        guard let total, total > 0 else { return Fmt.bytes(received) }
        let whole = Fmt.bytes(total)
        var part = Fmt.bytes(min(received, total))
        if let unit = whole.split(separator: " ").last, part.hasSuffix(" \(unit)") {
            part.removeLast(unit.count + 1)
        }
        return "\(part) of \(whole)"
    }

    /// The Software Update row's subtitle in General.
    /// Same precedence as the Software Update page's status row.
    @MainActor static func summary(_ center: UpdateCenter, now: Date) -> String {
        if case .needsRestart(let version) = center.install { return "Reopen \(Brand.name) to finish updating to \(version)" }
        if let version = center.install.version, center.install.isBusy {
            return "Updating to \(version)…"
        }
        if center.isChecking { return "Checking…" }
        if let available = center.availableUpdate { return "\(Brand.name) \(available.version) is available" }
        if center.checkError != nil { return "Couldn’t check for updates" }
        if let checked = center.lastChecked { return "Up to date · \(checkedAgo(checked, now: now))" }
        return center.currentVersion.map { "Version \($0)" } ?? "Check for new versions"
    }
}
