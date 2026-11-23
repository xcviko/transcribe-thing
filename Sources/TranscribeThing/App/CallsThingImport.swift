import AppKit
import Foundation

/// The one-time import from calls-thing, the app calls lived in for a while, at the first launch of a build with calls
/// back: its calls (calls.json, Calls/), the calls it was recording (Calls in Progress/, which come back through the
/// store's own recovery as interrupted or unconfirmed), its call settings, and its keys where this app has none. Calls
/// that were being transcribed come back as failed (`CallStore.load`): nothing is sent.
///
/// - Copies with `FileManager.copyItem`, so the files are APFS clones and take next to no disk. Each item goes to a
///   hidden name beside its place, then is renamed into it: it is there whole or not at all.
/// - Never overwrites what this app already has, file or setting, and never writes to calls-thing: its folder and
///   settings are only read. Deleting calls-thing is the user's, once they've seen their calls here.
/// - Refuses while calls-thing runs (its browser socket takes a connection): it records calls too, and could add one
///   mid-copy. Nothing is written then; the user can quit it from the question, or the next launch asks again.
/// - Runs once: the marker (`markerName`) is written last, after the copied calls.json reads back.
///
/// It runs before `AppSettings` is built: `load()` writes values back.
struct CallsThingImport {
    /// What is copied from, only ever read.
    struct Source {
        /// ~/Library/Application Support/calls-thing
        var root: URL
        /// Its settings (`dev.calls-thing.app`); nil when there's none.
        var defaults: UserDefaults?
        /// Where a running calls-thing listens for its browser extension.
        var socketPaths: [String]

        static let name = "calls-thing"
        static let bundleIdentifier = "dev.calls-thing.app"

        static func live() -> Source {
            let support = AppPaths.live().root.deletingLastPathComponent()
            let root = support.appendingPathComponent(name, isDirectory: true)
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-browser.sock").path
            return Source(root: root, defaults: UserDefaults(suiteName: bundleIdentifier),
                          socketPaths: [root.appendingPathComponent("browser.sock").path, fallback])
        }
    }

    enum Outcome: Equatable, Sendable {
        /// A headless run, a preview or a test: nothing was looked at.
        case notRun
        /// An earlier launch imported (or found nothing to import).
        case alreadyDone
        /// calls-thing is running and wasn't quit: nothing was written.
        case callsThingRunning
        case imported(Report)
        /// Something couldn't be copied, or the copied calls.json doesn't read: no marker, the next launch tries
        /// again (what's copied stays, and is skipped then). `reason` is a code for the log.
        case failed(reason: String, Report)
    }

    /// What one import copied. Counts only: never a key, a name or a path.
    struct Report: Codable, Equatable, Sendable {
        /// Calls in this app's calls.json once copied.
        var calls = 0
        /// Call folders (Calls/<id>) copied.
        var callFolders = 0
        /// Calls left recording, from their journal files.
        var journals = 0
        /// What the copied files hold (as clones they take next to none of it).
        var bytes: Int64 = 0
        /// Settings copied (`copiedSettings`).
        var settings = 0
        var openRouterKey = false
        var endpointKey = false
        /// This app already had a calls.json, which was kept.
        var keptOwnCallsFile = false
        /// calls-thing had no data folder.
        var noSourceFolder = false

        /// Anything worth a notice: a call.
        var broughtSomething: Bool { calls > 0 || journals > 0 }
    }

    /// The settings copied, calls-thing's key and this app's, each only when this app doesn't have it yet. calls-thing
    /// kept this app's names (`tt.`), so most are the same; its levels for calls were its only levels. Not its mic (a
    /// call records on the mic dictation picks), its name and Dictionary (it read this app's), its provider, endpoint
    /// and Auto-delete (this app's own govern calls too), nor the extension note.
    static let copiedSettings: [(from: String, to: SettingsKey)] = [
        ("tt.callRecording", .callRecording), ("tt.callExclusions", .callExclusions),
        ("tt.showsCallNotices", .showsCallNotices), ("tt.callModel", .callModel),
        ("tt.geminiReasoningEfforts", .callReasoningEfforts),
    ]
    /// In this app's folder once the import is done: when, and what it copied.
    static let markerName = "imported-from-calls-thing.json"
    /// What a copy is called until it's whole.
    static let partialPrefix = ".importing-"

    var source: Source
    var destination: AppPaths
    /// This app's settings.
    var defaults: UserDefaults

    private var fm: FileManager { .default }
    private var sourcePaths: AppPaths { AppPaths(root: source.root) }

    // MARK: At launch

    /// Whether this process is the app itself: the installed transcribe-thing.app (the bare binary from .build has no
    /// bundle id and would write its settings to another domain, then mark the import done), not a headless flag
    /// (every one starts with "--"), not the browser's native host, not a preview, not a test.
    static func isAllowed(arguments: [String], environment: [String: String], processName: String,
                          bundleIdentifier: String?) -> Bool {
        guard bundleIdentifier == SingleInstance.bundleIdentifier else { return false }
        if arguments.contains(where: { $0.hasPrefix("--") || $0.hasPrefix("chrome-extension://") }) { return false }
        if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return false }
        let testKeys = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
        if testKeys.contains(where: { environment[$0] != nil }) { return false }
        return !["xctest", "swiftpm-testing-helper"].contains(processName)
    }

    /// The import as the app runs it at launch. While calls-thing runs, `whileCallsThingRuns` is asked whether to look
    /// again (it was quit) or to go on without the import this time (`.callsThingRunning`).
    @MainActor
    static func atLaunch(arguments: [String] = Array(CommandLine.arguments.dropFirst()),
                         environment: [String: String] = ProcessInfo.processInfo.environment,
                         processName: String = ProcessInfo.processInfo.processName,
                         bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                         source: @autoclosure () -> Source = .live(), destination: AppPaths,
                         defaults: @autoclosure () -> UserDefaults = .standard,
                         whileCallsThingRuns: () -> Bool) -> Outcome {
        guard isAllowed(arguments: arguments, environment: environment, processName: processName,
                        bundleIdentifier: bundleIdentifier) else {
            return .notRun
        }
        let importer = CallsThingImport(source: source(), destination: destination, defaults: defaults())
        var outcome = importer.run()
        while outcome == .callsThingRunning, whileCallsThingRuns() {
            outcome = importer.run()
        }
        return outcome
    }

    // MARK: The import

    var isDone: Bool { fm.fileExists(atPath: markerURL.path) }

    /// Whether calls-thing is running: its browser socket takes a connection.
    var callsThingIsRunning: Bool {
        source.socketPaths.contains { path in
            guard let fd = UnixSocket.connect(to: path) else { return false }
            close(fd)
            return true
        }
    }

    func run() -> Outcome {
        if isDone { return .alreadyDone }
        var isFolder: ObjCBool = false
        let hasSource = fm.fileExists(atPath: source.root.path, isDirectory: &isFolder) && isFolder.boolValue
        // Nothing of calls-thing's here (it was never installed, or it's gone): nothing to wait for either.
        if hasSource, callsThingIsRunning { return .callsThingRunning }
        var report = Report()
        // Settings first: they can't fail, and are in place even when a copy below does.
        report.settings = copySettings()
        guard hasSource else {
            report.noSourceFolder = true
            return finish(report)
        }
        do {
            try fm.createDirectory(at: destination.root, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            removePartials()
            let from = sourcePaths
            if let bytes = try copy(from.keyFile, to: destination.keyFile, mode: 0o600) {
                report.openRouterKey = true
                report.bytes += bytes
            }
            if let bytes = try copy(from.vertexProxyKeyFile, to: destination.vertexProxyKeyFile, mode: 0o600) {
                report.endpointKey = true
                report.bytes += bytes
            }
            for folder in children(of: from.calls) {
                let place = destination.calls.appendingPathComponent(folder.lastPathComponent)
                guard let bytes = try copy(folder, to: place) else { continue }
                report.callFolders += 1
                report.bytes += bytes
            }
            var journals: Set<String> = []
            for file in children(of: from.callJournals) {
                let name = file.lastPathComponent
                guard let bytes = try copy(file, to: destination.callJournals.appendingPathComponent(name))
                else { continue }
                journals.insert(String(name.prefix(36)))
                report.bytes += bytes
            }
            report.journals = journals.count
            // calls.json last: the folders its calls point at are there before it is.
            let copiedCallsFile = try copy(from.callsFile, to: destination.callsFile)
            if let bytes = copiedCallsFile {
                report.bytes += bytes
            } else if fm.fileExists(atPath: destination.callsFile.path), fm.fileExists(atPath: from.callsFile.path) {
                report.keptOwnCallsFile = true
            }
            if fm.fileExists(atPath: destination.callsFile.path) {
                do {
                    report.calls = try CallStore.readRecords(from: Data(contentsOf: destination.callsFile)).count
                } catch {
                    // A copy that doesn't read is taken back, so the next launch copies it again.
                    if copiedCallsFile != nil { try? fm.removeItem(at: destination.callsFile) }
                    return .failed(reason: "callsUnreadable", report)
                }
            }
        } catch {
            return .failed(reason: "copyFailed", report)
        }
        return finish(report)
    }

    // MARK: Private

    private var markerURL: URL { destination.root.appendingPathComponent(Self.markerName, isDirectory: false) }

    private func finish(_ report: Report) -> Outcome {
        struct Marker: Encodable {
            var importedAt: Date
            var report: Report
        }
        do {
            try fm.createDirectory(at: destination.root, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Marker(importedAt: Date(), report: report)).write(to: markerURL, options: .atomic)
        } catch {
            return .failed(reason: "markerUnwritable", report)
        }
        return .imported(report)
    }

    /// Copies each listed setting this app has no value for; how many.
    private func copySettings() -> Int {
        guard let from = source.defaults else { return 0 }
        var copied = 0
        for (name, key) in Self.copiedSettings {
            guard defaults.object(forKey: key.defaultsKey) == nil, let value = from.object(forKey: name) else { continue }
            defaults.set(value, forKey: key.defaultsKey)
            copied += 1
        }
        return copied
    }

    /// What `folder` holds, hidden files (.DS_Store) left out; nothing when it's missing.
    private func children(of folder: URL) -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles])) ?? []
        return items.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Copies `from` (a file or a folder) to `to`, unless `to` is there already or `from` isn't: the bytes copied, or
    /// nil when skipped. `mode`: the copy's permissions (a key's 0600).
    private func copy(_ from: URL, to: URL, mode: Int? = nil) throws -> Int64? {
        guard fm.fileExists(atPath: from.path), !exists(to) else { return nil }
        let parent = to.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let partial = parent.appendingPathComponent(Self.partialPrefix + UUID().uuidString + "-" + to.lastPathComponent)
        do {
            try fm.copyItem(at: from, to: partial)
            if let mode { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: partial.path) }
            try fm.moveItem(at: partial, to: to)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return Self.size(of: to)
    }

    /// Whether anything is at `url`, a broken link included.
    private func exists(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    /// Copies an earlier launch left half done (the app quit mid-copy): only ever the importer's own.
    private func removePartials() {
        let d = destination
        for folder in [d.root, d.calls, d.callJournals] {
            let items = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in items where name.hasPrefix(Self.partialPrefix) {
                try? fm.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }

    /// What the files at `url` hold, a folder's summed up.
    private static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.fileSize ?? 0)
        }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

// MARK: - Telling the person

extension CallsThingImport {
    /// Asked at launch while calls-thing runs: true once it's quit (look again), false to go on without the import this
    /// time (the next launch asks again). Quit asks calls-thing to quit as its own Quit would, and waits for it.
    @MainActor
    static func askToQuitCallsThing() -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Bring your calls over from calls-thing?"
        alert.informativeText = "Calls are part of \(Brand.name) again. It copies your calls and call settings from "
            + "calls-thing, which has to quit first: it records calls too. Nothing in calls-thing is changed or "
            + "deleted."
        alert.addButton(withTitle: "Quit calls-thing")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Source.bundleIdentifier)
        running.forEach { $0.terminate() }
        // Up to 15 s for it to finish what it records and let its socket go.
        let deadline = Date().addingTimeInterval(15)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return true
    }

    /// The import's line in the diagnostic log: counts only. Nothing when there's nothing to say (`.notRun`,
    /// `.alreadyDone`).
    static func logEvent(_ outcome: Outcome, to log: DiagnosticLog) {
        func fields(_ r: Report) -> [DiagnosticField] {
            [DiagnosticField("calls", "\(r.calls)"), DiagnosticField("callFolders", "\(r.callFolders)"),
             DiagnosticField("journals", "\(r.journals)"), DiagnosticField("bytes", "\(r.bytes)"),
             DiagnosticField("settings", "\(r.settings)"),
             DiagnosticField("openRouterKey", r.openRouterKey ? "yes" : "no"),
             DiagnosticField("endpointKey", r.endpointKey ? "yes" : "no"),
             DiagnosticField("keptOwnCallsFile", r.keptOwnCallsFile ? "yes" : "no"),
             DiagnosticField("sourceFolder", r.noSourceFolder ? "no" : "yes")]
        }
        switch outcome {
        case .notRun, .alreadyDone: return
        case .callsThingRunning: log.event(.app, "callsImport.postponed", fields: [])
        case .imported(let report): log.event(.app, "callsImport.finished", fields: fields(report))
        case .failed(let reason, let report):
            log.event(.app, "callsImport.failed", fields: [DiagnosticField("reason", reason)] + fields(report))
        }
    }

    /// The notice the import leaves, if any: what came over, or that it'll try again.
    static func notice(for outcome: Outcome) -> Notice? {
        switch outcome {
        case .imported(let report) where report.broughtSomething:
            let title = switch report.calls {
            case 0: "Your call recording from calls-thing is here"
            case 1: "Your call from calls-thing is here"
            default: "Your \(report.calls) calls from calls-thing are here"
            }
            return Notice(dedupeKey: "callsImport", style: .success, symbol: "tray.and.arrow.down", title: title,
                          body: "Their settings came too. The originals stay in calls-thing until you delete it.",
                          actions: [NoticeAction(title: "Open Calls", kind: .openHub(.calls))],
                          lifetime: .seconds(16))
        case .callsThingRunning:
            return Notice(dedupeKey: "callsImport", style: .info, symbol: "tray.and.arrow.down",
                          title: "Your calls are still in calls-thing",
                          body: "Quit calls-thing, then open \(Brand.name) again to bring them over.",
                          lifetime: .seconds(16))
        case .failed:
            return Notice(dedupeKey: "callsImport", style: .warning, symbol: "exclamationmark.triangle",
                          title: "Couldn’t copy everything from calls-thing",
                          body: "\(Brand.name) tries again the next time it opens. Your calls are still in calls-thing.",
                          lifetime: .sticky)
        default:
            return nil
        }
    }
}
