import Darwin
import Foundation
import Testing
@testable import TranscribeThing

// The one-time import from calls-thing (`CallsThingImport`). Only on temporary folders and throwaway
// `UserDefaults(suiteName:)` domains: never either app's own data or settings.

/// A calls-thing folder and settings as it leaves them, and this app's empty ones.
@MainActor
private final class Fixture {
    let source = AppPaths.temporary()
    let destination = AppPaths.temporary()
    let sourceSuite = NSTemporaryDirectory() + "transcribe-thing-tests-calls-thing-\(UUID().uuidString)"
    let destinationSuite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
    let sourceDefaults: UserDefaults
    let defaults: UserDefaults
    /// Short enough for a socket's path; nobody listens there unless a test does.
    let socketPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("ct-\(UUID().uuidString.prefix(8)).sock").path

    let done = CallRecord(id: UUID(), startedAt: Date().addingTimeInterval(-3600), appName: "Zoom", status: .done)
    let transcribing = CallRecord(id: UUID(), startedAt: Date().addingTimeInterval(-1800), appName: "FaceTime",
                                  status: .transcribing)
    let keptJournal = UUID()
    let askedJournal = UUID()
    let exclusion = CallExclusion.app(bundleID: "com.apple.FaceTime", name: "FaceTime")

    init() throws {
        sourceDefaults = try #require(UserDefaults(suiteName: sourceSuite))
        defaults = try #require(UserDefaults(suiteName: destinationSuite))
    }

    func cleanUp() {
        sourceDefaults.removePersistentDomain(forName: sourceSuite)
        defaults.removePersistentDomain(forName: destinationSuite)
        for root in [source.root, destination.root] { try? FileManager.default.removeItem(at: root) }
        unlink(socketPath)
    }

    var importer: CallsThingImport {
        CallsThingImport(source: .init(root: source.root, defaults: sourceDefaults, socketPaths: [socketPath]),
                         destination: destination, defaults: defaults)
    }

    /// The source: two calls (one was being transcribed), two calls left recording (one kept, one asked about), both
    /// keys, the call settings and some that aren't copied.
    func fill() async throws {
        let fm = FileManager.default
        let store = CallStore(paths: source, settings: .inMemory())
        store.load()
        await store.waitForRecovery()
        for call in [done, transcribing] {
            store.upsert(call)
            try fm.createDirectory(at: store.folder(for: call.id), withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: store.folder(for: call.id).appendingPathComponent("mic.m4a"))
        }
        await store.flush()
        let journal = CallJournal(directory: source.callJournals)
        for (id, consent) in [(keptJournal, CallJournal.Consent.kept), (askedJournal, .asking)] {
            let info = CallJournal.Info(id: id, startedAt: Date().addingTimeInterval(-600), appName: "Telegram",
                                        bundleID: "ru.keepcoder.Telegram", consent: consent)
            let mic = FakeSource()
            journal.begin(info, origin: 0, sources: [.mic: mic, .remote: FakeSource()])
            mic.push([Float](repeating: 0.1, count: Int(Recording.sampleRate * 2)), at: 0)
            _ = await journal.end(id)
        }
        try Data("openrouter-test-key".utf8).write(to: source.keyFile)
        try Data("endpoint-test-key".utf8).write(to: source.vertexProxyKeyFile)
        // What isn't copied: the browser extension's files, a model.
        try fm.createDirectory(at: source.root.appendingPathComponent("Browser Extension"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.models.appendingPathComponent("parakeet-tdt-0.6b-v3"),
                               withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        sourceDefaults.set(CallRecordingMode.automatic.rawValue, forKey: "tt.callRecording")
        sourceDefaults.set(try encoder.encode([exclusion]), forKey: "tt.callExclusions")
        sourceDefaults.set(false, forKey: "tt.showsCallNotices")
        sourceDefaults.set("geminiFlash", forKey: "tt.callModel")
        sourceDefaults.set(#"{"geminiFlash":"high","geminiNeon":"xhigh"}"#.data(using: .utf8), forKey: "tt.geminiReasoningEfforts")
        sourceDefaults.set("calls-mic-uid", forKey: "tt.microphoneUID")
        sourceDefaults.set("https://endpoint.example/api/v1", forKey: "tt.vertexProxyURL")
        sourceDefaults.set("Sam", forKey: "tt.userName")
        sourceDefaults.set(true, forKey: "tt.browserExtensionHintDismissed")
        sourceDefaults.set(30, forKey: "tt.autoDeleteHistoryDays")
    }
}

/// Every file and folder under `root`: its path, contents, permissions and modification date.
private func treeHash(_ root: URL) -> [String: String] {
    var result: [String: String] = [:]
    let fm = FileManager.default
    guard let walker = fm.enumerator(atPath: root.path) else { return [:] }
    for case let relative as String in walker {
        let path = root.appendingPathComponent(relative).path
        let attributes = (try? fm.attributesOfItem(atPath: path)) ?? [:]
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let contents = fm.contents(atPath: path).map { "\($0.hashValue)-\($0.count)" } ?? "folder"
        result[relative] = "\(mode)|\(date)|\(contents)"
    }
    return result
}

private func mode(_ url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}

private final class SentCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@MainActor @Suite(.serialized) struct CallsThingImportTests {
    /// The installed app's bundle id, as `atLaunch` would see it there.
    let app = SingleInstance.bundleIdentifier

    @Test func copiesTheCallsAndTheirSettings() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try await f.fill()
        let outcome = f.importer.run()
        guard case .imported(let report) = outcome else {
            Issue.record("expected an import, got \(outcome)")
            return
        }
        #expect(report.calls == 2 && report.callFolders == 2 && report.journals == 2)
        #expect(report.openRouterKey && report.endpointKey && !report.keptOwnCallsFile && report.bytes > 0)
        #expect(report.settings == 5)

        let fm = FileManager.default
        let d = f.destination
        for call in [f.done, f.transcribing] {
            #expect(fm.contents(atPath: d.calls.appendingPathComponent("\(call.id.uuidString)/mic.m4a").path)
                == Data([1, 2, 3]))
        }
        #expect(fm.contents(atPath: d.keyFile.path) == Data("openrouter-test-key".utf8))
        #expect(mode(d.keyFile) == 0o600 && mode(d.vertexProxyKeyFile) == 0o600)
        let journals = try fm.contentsOfDirectory(atPath: d.callJournals.path)
        #expect(journals.contains("\(f.keptJournal.uuidString).json"))
        #expect(journals.contains("\(f.askedJournal.uuidString)-mic.wav"))
        for name in ["Browser Extension", "Models"] {
            #expect(!fm.fileExists(atPath: d.root.appendingPathComponent(name).path), "\(name)")
        }
        #expect(!(try fm.contentsOfDirectory(atPath: d.root.path)).contains { $0.hasPrefix(CallsThingImport.partialPrefix) })
        #expect(mode(d.root) == 0o700)

        // The call settings only: calls-thing's levels become calls' levels here.
        #expect(f.defaults.string(forKey: "tt.callRecording") == "automatic")
        #expect(f.defaults.object(forKey: "tt.showsCallNotices") as? Bool == false)
        #expect(f.defaults.string(forKey: "tt.callModel") == "geminiFlash")
        #expect(f.defaults.object(forKey: "tt.callReasoningEfforts") != nil)
        for key in ["tt.geminiReasoningEfforts", "tt.microphoneUID", "tt.vertexProxyURL", "tt.userName",
                    "tt.browserExtensionHintDismissed", "tt.autoDeleteHistoryDays"] {
            #expect(f.defaults.object(forKey: key) == nil, "\(key)")
        }
    }

    /// Settings built afterwards have calls-thing's call model at its level, and dictation's levels untouched.
    @Test func settingsBuiltAfterwardsSeeTheCopy() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try await f.fill()
        _ = f.importer.run()
        let settings = AppSettings(defaults: f.defaults)
        #expect(settings.callRecording == .automatic)
        #expect(settings.callExclusions == [f.exclusion])
        #expect(!settings.showsCallNotices)
        #expect(settings.callModel == CallModel(engine: .geminiFlash, effort: .high))
        #expect(settings.callReasoningEfforts[.geminiNeon] == .xhigh)
        #expect(settings.reasoningEffort(for: .geminiFlash) == .medium && settings.reasoningEffort(for: .geminiNeon) == .low)
        #expect(settings.userName.isEmpty && settings.vertexProxyURL != "https://endpoint.example/api/v1")
    }

    @Test func neverChangesCallsThing() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try await f.fill()
        let tree = treeHash(f.source.root)
        let settings = f.sourceDefaults.persistentDomain(forName: f.sourceSuite) as NSDictionary?
        #expect(!tree.isEmpty && settings != nil)
        _ = f.importer.run()
        // What this app does with its copies changes nothing there either.
        let appSettings = AppSettings(defaults: f.defaults)
        appSettings.callRecording = .off
        let store = CallStore(paths: f.destination, settings: appSettings)
        store.load()
        await store.waitForRecovery()
        await store.flush()
        await store.journal?.settle()
        #expect(treeHash(f.source.root) == tree)
        #expect(f.sourceDefaults.persistentDomain(forName: f.sourceSuite) as NSDictionary? == settings)
    }

    @Test func runsOnce() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try await f.fill()
        guard case .imported = f.importer.run() else {
            Issue.record("expected an import")
            return
        }
        #expect(FileManager.default.fileExists(
            atPath: f.destination.root.appendingPathComponent(CallsThingImport.markerName).path))
        // A call deleted here since, and a setting changed, stay that way.
        try FileManager.default.removeItem(at: f.destination.calls.appendingPathComponent(f.done.id.uuidString))
        f.defaults.removeObject(forKey: "tt.callRecording")
        #expect(f.importer.run() == .alreadyDone)
        #expect(!FileManager.default.fileExists(atPath: f.destination.calls.appendingPathComponent(f.done.id.uuidString).path))
        #expect(f.defaults.object(forKey: "tt.callRecording") == nil)
    }

    @Test func waitsWhileCallsThingRuns() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try await f.fill()
        let listening = try UnixSocket.listen(at: f.socketPath)
        #expect(f.importer.callsThingIsRunning)
        #expect(f.importer.run() == .callsThingRunning)
        // Nothing written: no folder, no setting.
        #expect(!FileManager.default.fileExists(atPath: f.destination.root.path))
        #expect(f.defaults.persistentDomain(forName: f.destinationSuite)?.isEmpty ?? true)

        // At launch: asked while it runs; once it's quit, the import goes ahead.
        var asked = 0
        let outcome = CallsThingImport.atLaunch(arguments: [], environment: [:], processName: "transcribe-thing",
                                                bundleIdentifier: app, source: f.importer.source,
                                                destination: f.destination, defaults: f.defaults) {
            asked += 1
            if asked == 2 { close(listening) }
            return true
        }
        #expect(asked == 2)
        guard case .imported(let report) = outcome else {
            Issue.record("expected an import, got \(outcome)")
            return
        }
        #expect(report.calls == 2)
    }

    /// Not Now goes on without the import, writing nothing, and says where the calls are.
    @Test func notNowWritesNothing() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try await f.fill()
        let listening = try UnixSocket.listen(at: f.socketPath)
        defer { close(listening) }
        let outcome = CallsThingImport.atLaunch(arguments: [], environment: [:], processName: "transcribe-thing",
                                                bundleIdentifier: app, source: f.importer.source,
                                                destination: f.destination, defaults: f.defaults) { false }
        #expect(outcome == .callsThingRunning)
        #expect(!FileManager.default.fileExists(atPath: f.destination.root.path))
        #expect(CallsThingImport.notice(for: outcome)?.title == "Your calls are still in calls-thing")
        // A socket file nobody listens at (calls-thing quit without removing it) doesn't count.
        close(listening)
        #expect(!f.importer.callsThingIsRunning)
    }

    @Test func neverOverwrites() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try await f.fill()
        let fm = FileManager.default
        let d = f.destination
        try fm.createDirectory(at: d.calls.appendingPathComponent(f.done.id.uuidString), withIntermediateDirectories: true)
        try Data([9]).write(to: d.calls.appendingPathComponent("\(f.done.id.uuidString)/mic.m4a"))
        try fm.createDirectory(at: d.root, withIntermediateDirectories: true)
        try Data("own-key".utf8).write(to: d.keyFile)
        let ownStore = CallStore(paths: d, settings: .inMemory())
        ownStore.load()
        await ownStore.waitForRecovery()
        let own = CallRecord(id: UUID(), startedAt: Date(), appName: "Slack", status: .done)
        ownStore.upsert(own)
        await ownStore.flush()
        f.defaults.set(CallRecordingMode.off.rawValue, forKey: "tt.callRecording")
        f.defaults.set(#"{"geminiNeon":"low"}"#.data(using: .utf8), forKey: "tt.callReasoningEfforts")

        guard case .imported(let report) = f.importer.run() else {
            Issue.record("expected an import")
            return
        }
        #expect(report.keptOwnCallsFile && report.calls == 1 && !report.openRouterKey && report.endpointKey)
        #expect(report.callFolders == 1)
        #expect(fm.contents(atPath: d.calls.appendingPathComponent("\(f.done.id.uuidString)/mic.m4a").path) == Data([9]))
        #expect(fm.contents(atPath: d.keyFile.path) == Data("own-key".utf8))
        #expect(try CallStore.readRecords(from: Data(contentsOf: d.callsFile)).map(\.id) == [own.id])
        #expect(f.defaults.string(forKey: "tt.callRecording") == "off")
        #expect(AppSettings(defaults: f.defaults).callReasoningEfforts[.geminiNeon] == .low)
    }

    @Test func aCopyThatDoesntReadIsTakenBackAndTriedAgain() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try FileManager.default.createDirectory(at: f.source.root, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: f.source.callsFile)
        guard case .failed(let reason, _) = f.importer.run() else {
            Issue.record("expected a failure")
            return
        }
        #expect(reason == "callsUnreadable")
        #expect(!FileManager.default.fileExists(atPath: f.destination.callsFile.path))
        #expect(!f.importer.isDone)
        #expect(CallsThingImport.notice(for: .failed(reason: reason, .init()))?.lifetime == .sticky)
    }

    /// No calls-thing on this Mac: done at once, without a word, even with something listening at its socket's path.
    @Test func nothingThereIsDoneToo() throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        guard case .imported(let report) = f.importer.run() else {
            Issue.record("expected an import")
            return
        }
        #expect(report.noSourceFolder && report.calls == 0 && !report.broughtSomething)
        #expect(f.importer.isDone)
        #expect(CallsThingImport.notice(for: .imported(report)) == nil)
    }

    @Test func callsComeBackInterruptedUnconfirmedOrFailedAndNothingIsSent() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try await f.fill()
        _ = f.importer.run()
        let settings = AppSettings(defaults: f.defaults)
        let store = CallStore(paths: f.destination, settings: settings)
        let sent = SentCount()
        let transcriber = CallTranscriber(store: store, send: { _, _, _, _ in
            sent.add()
            return CloudResult(text: "[]")
        }, sendText: { _, _ in
            sent.add()
            return CloudResult(text: "")
        })
        store.load()
        await store.waitForRecovery()
        #expect(store.call(id: f.done.id)?.status == .done)
        #expect(store.call(id: f.transcribing.id)?.status == .failed)
        #expect(store.call(id: f.keptJournal)?.status == .interrupted)
        #expect(store.call(id: f.askedJournal)?.status == .unconfirmed)
        try await Task.sleep(for: .milliseconds(300))
        #expect(sent.value == 0)
        #expect([f.done.id, f.transcribing.id, f.keptJournal, f.askedJournal].allSatisfy { !transcriber.isTranscribing($0) })
    }

    @Test func neverRunsHeadlessInPreviewsOrTests() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try await f.fill()
        let headless = [["--snapshots", "/tmp/x"], ["--model-status"], ["--check-updates"], ["--transcribe", "x"],
                        ["chrome-extension://abc/"]]
        for arguments in headless {
            #expect(!CallsThingImport.isAllowed(arguments: arguments, environment: [:],
                                                processName: "transcribe-thing", bundleIdentifier: app))
            let outcome = CallsThingImport.atLaunch(arguments: arguments, environment: [:],
                                                    processName: "transcribe-thing", bundleIdentifier: app,
                                                    source: f.importer.source, destination: f.destination,
                                                    defaults: f.defaults) { true }
            #expect(outcome == .notRun)
        }
        #expect(!CallsThingImport.isAllowed(arguments: [], environment: ["XCODE_RUNNING_FOR_PREVIEWS": "1"],
                                            processName: "transcribe-thing", bundleIdentifier: app))
        // The bare binary from .build: no bundle id.
        #expect(!CallsThingImport.isAllowed(arguments: [], environment: [:], processName: "transcribe-thing",
                                            bundleIdentifier: nil))
        // This very test run, as the app would see it.
        #expect(!CallsThingImport.isAllowed(arguments: Array(CommandLine.arguments.dropFirst()),
                                            environment: ProcessInfo.processInfo.environment,
                                            processName: ProcessInfo.processInfo.processName, bundleIdentifier: app))
        #expect(CallsThingImport.isAllowed(arguments: [], environment: [:], processName: "transcribe-thing",
                                           bundleIdentifier: app))
        #expect(!FileManager.default.fileExists(atPath: f.destination.root.path))
        #expect(f.defaults.persistentDomain(forName: f.destinationSuite)?.isEmpty ?? true)
    }

    @Test func theLogLineHasCountsOnly() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString)")
        let log = DiagnosticLog(homeDirectory: home.path)
        log.start(directory: home)
        defer {
            log.stop()
            try? FileManager.default.removeItem(at: home)
        }
        var report = CallsThingImport.Report()
        report.calls = 88
        report.bytes = 1234
        report.openRouterKey = true
        CallsThingImport.logEvent(.imported(report), to: log)
        log.flush()
        let text = log.retainedText()
        #expect(text.contains("[app] callsImport.finished calls=88"))
        #expect(text.contains("bytes=1234") && text.contains("openRouterKey=yes") && text.contains("endpointKey=no"))
        #expect(!text.contains("/"))
    }
}
