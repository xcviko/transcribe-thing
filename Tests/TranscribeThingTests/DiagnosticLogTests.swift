import AppKit
import Foundation
import Testing
@testable import TranscribeThing

/// A clock the tests move by hand.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    var now: Date { lock.withLock { date } }

    func advance(days: Int) {
        lock.withLock { date = date.addingTimeInterval(TimeInterval(days) * 86_400) }
    }
}

private enum Fixture {
    /// +04:00, the time zone of every line in these tests.
    static let zone = TimeZone(secondsFromGMT: 4 * 3600)!

    /// 2026-10-02 14:03:22.481 at +04:00.
    static let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: 2026, month: 10, day: 2, hour: 14, minute: 3, second: 22)
        let second = calendar.date(from: components)!
        return second.addingTimeInterval(0.481)
    }()

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tt-diagnostics-\(UUID().uuidString)",
                                                                       isDirectory: true)
    }

    static func log(clock: ManualClock = ManualClock(now), home: String = "/Users/tester",
                    limits: DiagnosticLog.Limits = .init()) -> DiagnosticLog {
        DiagnosticLog(clock: { clock.now }, timeZone: zone, homeDirectory: home, limits: limits)
    }

    /// The day files in `directory`, by name.
    static func files(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    static func write(_ size: Int, bytesTo name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: UInt8(ascii: "x"), count: size).write(to: directory.appendingPathComponent(name))
    }
}

@Suite struct DiagnosticLogTests {
    @Test func aLineHasItsTimeCategoryNameAndFieldsInOrder() throws {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = Fixture.log()
        log.start(directory: directory)
        log.event(.dictation, "job.finished", ["engine": EngineID.geminiFlash, "outcome": "success", "seconds": 4.2])
        let line = "2026-10-02T14:03:22.481+04:00 [dictation] job.finished "
            + "engine=geminiFlash outcome=success seconds=4.2"
        #expect(log.retainedText() == line + "\n")
        #expect(Fixture.files(in: directory) == ["2026-10-02.log"])
    }

    @Test func valuesReadAsCodesOnOneLine() {
        let fields: [DiagnosticField] = [
            DiagnosticField("server", "cloudflare proxy"), DiagnosticField("said", "error 503: \"busy\"\nretry"),
            DiagnosticField("empty", ""), DiagnosticField("eq", "a=b"),
        ]
        #expect(DiagnosticLog.message(.net, "openrouter.http", fields)
            == #"[net] openrouter.http server="cloudflare proxy" said="error 503: \"busy\" retry" empty="" eq="a=b""#)
        #expect(4.2.diagnosticText == "4.2")
        #expect(12.0.diagnosticText == "12")
        #expect(0.354.diagnosticText == "0.35")
        #expect(true.diagnosticText == "yes" && false.diagnosticText == "no")
        #expect(DiagnosticLog.quoted(String(repeating: "a", count: 5000)).count == DiagnosticLog.maxValueLength)
    }

    @Test func aMissingValueLeavesItsFieldOut() {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = Fixture.log()
        log.start(directory: directory)
        let mic: AudioInputDevice.Transport? = nil
        log.event(.dictation, "dictation.started", ["mode": DictationMachine.Mode.handsFree, "mic": mic,
                                                     "code": AppError.offline])
        #expect(log.retainedText().hasSuffix("[dictation] dictation.started mode=handsFree code=offline\n"))
    }

    @Test func theHomeFolderIsWrittenAsATilde() {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = Fixture.log(home: "/Users/tester/")
        log.start(directory: directory)
        log.event(.models, "load.failed", ["detail": "No file at /Users/tester/Library/Models/x.bin",
                                           "other": "/Users/testerX/file", "home": "/Users/tester"])
        let text = log.retainedText()
        #expect(text.contains(#"detail="No file at ~/Library/Models/x.bin""#))
        #expect(text.contains("other=/Users/testerX/file"), "another folder that starts the same stays")
        #expect(text.contains("home=~\n"))
        let sentence = "/Users/tester.bak, /Users/tester_2 and /Users/tester."
        #expect(DiagnosticLog.scrubbingHome(sentence, home: "/Users/tester")
            == "/Users/tester.bak, /Users/tester_2 and ~.")
    }

    @Test func nothingIsWrittenUntilTheLogStartsOrAfterItStops() {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = Fixture.log()
        log.event(.app, "before")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        log.start(directory: directory)
        log.event(.app, "during")
        log.stop()
        log.event(.app, "after")
        log.flush()
        let text = (try? String(contentsOf: directory.appendingPathComponent("2026-10-02.log"), encoding: .utf8)) ?? ""
        #expect(text.contains("[app] during") && !text.contains("before") && !text.contains("after"))
        #expect(log.retainedText().isEmpty, "a stopped log has nothing to export")
    }

    @Test func eachDayHasItsOwnFileAndTheExportReadsThemOldestFirst() {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = ManualClock(Fixture.now)
        let log = Fixture.log(clock: clock)
        log.start(directory: directory)
        log.event(.app, "first")
        clock.advance(days: 1)
        log.event(.app, "second")
        clock.advance(days: 1)
        log.event(.app, "third")
        let lines = log.retainedText().split(separator: "\n")
        #expect(lines.map { $0.split(separator: " ").last.map(String.init) } == ["first", "second", "third"])
        #expect(lines.first?.hasPrefix("2026-10-02T") == true && lines.last?.hasPrefix("2026-10-04T") == true)
        #expect(Fixture.files(in: directory) == ["2026-10-02.log", "2026-10-03.log", "2026-10-04.log"])
    }

    @Test func daysOlderThanAWeekAreDeletedWhenTheLogStarts() throws {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for day in 20...30 { try Fixture.write(10, bytesTo: "2026-09-\(day).log", in: directory) }
        try Fixture.write(10, bytesTo: "2026-10-01.log", in: directory)
        let log = Fixture.log()
        log.start(directory: directory)
        log.flush()
        #expect(Fixture.files(in: directory)
            == ["2026-09-26.log", "2026-09-27.log", "2026-09-28.log", "2026-09-29.log", "2026-09-30.log",
                "2026-10-01.log"], "today and the six days before it")
    }

    @Test func aNewDayDeletesTheDayThatIsNowTooOld() throws {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixture.write(10, bytesTo: "2026-09-26.log", in: directory)
        let clock = ManualClock(Fixture.now)
        let log = Fixture.log(clock: clock)
        log.start(directory: directory)
        log.event(.app, "today")
        log.flush()
        #expect(Fixture.files(in: directory).contains("2026-09-26.log"))
        clock.advance(days: 1)
        log.event(.app, "tomorrow")
        log.flush()
        #expect(Fixture.files(in: directory) == ["2026-10-02.log", "2026-10-03.log"])
    }

    /// Earlier days keep what today may still need free: with a 1000-byte limit, today grows to 500, so earlier days
    /// keep at most 500.
    @Test func theOldestDaysGoWhileAllTogetherTakeMoreThanTheLimit() throws {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["2026-09-28.log", "2026-09-29.log", "2026-09-30.log", "2026-10-01.log", "2026-10-02.log"] {
            try Fixture.write(200, bytesTo: name, in: directory)
        }
        let log = Fixture.log(limits: .init(days: 7, totalBytes: 1000))
        log.start(directory: directory)
        log.flush()
        #expect(Fixture.files(in: directory) == ["2026-09-30.log", "2026-10-01.log", "2026-10-02.log"])
    }

    /// A runaway day stops at its own share, so the next morning it's still there to explain itself.
    @Test func aDayThatHitItsShareSurvivesTheNextDay() throws {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixture.write(500, bytesTo: "2026-10-01.log", in: directory)
        try Fixture.write(100, bytesTo: "2026-09-30.log", in: directory)
        let log = Fixture.log(limits: .init(days: 7, totalBytes: 1000))
        log.start(directory: directory)
        log.event(.app, "next.morning")
        log.flush()
        #expect(Fixture.files(in: directory) == ["2026-10-01.log", "2026-10-02.log"])
    }

    @Test func todaysFileStaysAndStopsGrowingAtTheLimit() throws {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixture.write(2000, bytesTo: "2026-10-02.log", in: directory)
        let log = Fixture.log(limits: .init(days: 7, totalBytes: 1000))
        log.start(directory: directory)
        log.event(.app, "past.the.limit")
        log.flush()
        let today = directory.appendingPathComponent("2026-10-02.log")
        let size = try FileManager.default.attributesOfItem(atPath: today.path)[.size]
        #expect(Fixture.files(in: directory) == ["2026-10-02.log"])
        #expect((size as? Int) == 2000, "nothing more is written to a day that is already over the limit")

        let busy = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: busy) }
        let runaway = Fixture.log(limits: .init(days: 7, totalBytes: 1000))
        runaway.start(directory: busy)
        for index in 0..<100 { runaway.event(.dictation, "job.finished", ["index": index]) }
        let written = runaway.retainedText().utf8.count
        #expect(written <= 500 && written > 400, "stops a line short of a day's share, half the limit")
    }

    @Test func filesThatArentDaysAreLeftAlone() throws {
        let directory = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Fixture.write(10, bytesTo: "notes.txt", in: directory)
        try Fixture.write(10, bytesTo: "2020-01-01.txt", in: directory)
        try Fixture.write(10, bytesTo: "2020-01-01.log", in: directory)
        let log = Fixture.log()
        log.start(directory: directory)
        log.event(.app, "x")
        #expect(!log.retainedText().contains("xxxxxxxxxx"))
        #expect(Fixture.files(in: directory) == ["2020-01-01.txt", "2026-10-02.log", "notes.txt"])
        #expect(DiagnosticLog.day(ofFileNamed: "2026-10-02.log") == "2026-10-02")
        #expect(DiagnosticLog.day(ofFileNamed: "2026-1a-02.log") == nil)
    }

    @Test func aFolderThatCantBeWrittenIsIgnoredQuietly() throws {
        let file = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not a folder".utf8).write(to: file)
        let log = Fixture.log()
        log.start(directory: file)
        log.event(.app, "lost")
        #expect(log.retainedText().isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "not a folder")
    }

    @Test func theExportIsNamedForItsMinute() {
        #expect(DiagnosticExport.fileName(at: Fixture.now, timeZone: Fixture.zone)
            == "transcribe-thing-logs-2026-10-02-1403.txt")
    }
}

@MainActor
@Suite struct DiagnosticsCenterTests {
    private static func center(log: DiagnosticLog, settings: AppSettings? = nil,
                               keyStore: KeyFileStore = .inMemory()) -> DiagnosticsCenter {
        DiagnosticsCenter(log: log, settings: settings ?? .inMemory(), keyStore: keyStore,
                          account: .preview(status: .missing),
                          permissions: .preview(mic: .granted, ax: .denied), devices: .preview())
    }

    @Test func theExportHasAHeaderThenTheLinesOldestFirst() async throws {
        let logs = Fixture.temporaryDirectory(), desktop = Fixture.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: logs)
            try? FileManager.default.removeItem(at: desktop)
        }
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let clock = ManualClock(Fixture.now)
        let log = Fixture.log(clock: clock)
        log.start(directory: logs)
        log.event(.app, "older")
        clock.advance(days: 1)
        log.event(.app, "newer")
        let center = Self.center(log: log)
        center.clock = { clock.now }
        center.timeZone = Fixture.zone

        let url = try await center.exportLogs(to: desktop)
        #expect(url.deletingLastPathComponent().standardizedFileURL == desktop.standardizedFileURL)
        #expect(url.lastPathComponent.hasPrefix("transcribe-thing-logs-2026-10-03-"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let header = text.components(separatedBy: "\n\n").first ?? ""
        for line in ["transcribe-thing logs", "Exported: 2026-10-03T14:03:22.481+04:00", "App: ", "macOS: ", "Mac: ",
                     "OpenRouter key saved: no",
                     "Settings: main=parakeet steps=gemini parakeet=local handsFreeModel=main "
                         + #"shortcut.pushToTalk=fn shortcut.handsFree="fn Space""#,
                     "pill=whileDictating sounds=on doublePress=off dictionaryWords=0 keySaved=no"] {
            #expect(header.contains(line), "header has \(line)")
        }
        let older = try #require(text.range(of: "[app] older")), newer = try #require(text.range(of: "[app] newer"))
        #expect(older.lowerBound < newer.lowerBound)
        #expect(try #require(text.range(of: "\n\n")).upperBound <= older.lowerBound, "the lines come after the header")
    }

    @Test func theExportSaysAKeyIsSavedButNeverHoldsIt() async throws {
        let logs = Fixture.temporaryDirectory(), desktop = Fixture.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: logs)
            try? FileManager.default.removeItem(at: desktop)
        }
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let log = Fixture.log()
        log.start(directory: logs)
        let center = Self.center(log: log, keyStore: .inMemory("sk-or-v1-0123456789abcdef0123456789abcdef"))
        center.start()
        let text = try String(contentsOf: try await center.exportLogs(to: desktop), encoding: .utf8)
        #expect(text.contains("OpenRouter key saved: yes"))
        #expect(text.contains("keySaved=yes"))
        #expect(!text.contains("sk-or") && !text.contains("0123456789abcdef"))
        #expect(text.contains("[permissions] permissions microphone=granted accessibility=denied"))
        #expect(text.contains("[mic] mic.devices inputs=builtIn,bluetooth,usb default=builtIn picked=automatic"))
        #expect(!text.contains("AirPods") && !text.contains("MacBook Pro Microphone"), "never a microphone's name")
    }

    @Test func aBurstOfSettingsChangesIsOneLine() async throws {
        let logs = Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: logs) }
        let log = Fixture.log()
        log.start(directory: logs)
        let settings = AppSettings.inMemory()
        let center = Self.center(log: log, settings: settings)
        center.settingsDebounce = .milliseconds(100)
        center.start()
        settings.pillMode = .always
        settings.soundsEnabled = false
        settings.shortcuts[.polish] = nil
        try await waitUntil(timeout: .seconds(5)) { log.retainedText().contains("settings.changed") }
        try await Task.sleep(for: .milliseconds(300))
        let changes = log.retainedText().split(separator: "\n").filter { $0.contains("[settings] settings.changed") }
        #expect(changes.count == 1)
        #expect(changes.first?.contains("shortcut.polish=none") == true)
        #expect(changes.first?.contains("pill=always sounds=off") == true)
    }
}

/// The dictation path writes what happened to a paste, never where it went, nor the text.
@MainActor
@Suite(.serialized) struct DiagnosticDictationTests {
    @Test func aPasteIsLoggedWithoutItsTargetAppOrItsText() async throws {
        let logs = Fixture.temporaryDirectory()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.transcribe-thing.tests.\(UUID().uuidString)"))
        // The shared log, as the controller writes to it, is pointed at a temporary folder for this test only.
        DiagnosticLog.shared.start(directory: logs)
        defer {
            DiagnosticLog.shared.stop()
            DiagnosticLog.shared.flush()
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: logs)
        }
        let target = FocusInfo(pid: 42, bundleID: "com.example.secret-notes", role: "AXTextArea",
                               editability: .editable)
        let inserter = TextInserter(pasteboard: pasteboard, system: .init(
            canPostEvents: { true }, modifiersHeld: { false },
            inspectFocus: { target }, pasteKeyCode: { 9 }, postPaste: { _ in true }))
        inserter.restoreDelay = .milliseconds(20)
        inserter.unreadTimeout = .milliseconds(200)
        let h = DictationControllerTests.make(inserter: inserter)
        h.controller.transcribeOverride = { _, engine in
            TranscriptResult(text: "meet me at the private place", engine: engine, processingTime: 0.4)
        }

        h.controller.send(.handsFreeToggle)
        h.controller.send(.pillStop)
        // Generous: the full test run is busy enough to slow the paste down.
        try await waitUntil(timeout: .seconds(10)) { h.controller.machine.activeJobs == 0 && !h.history.entries.isEmpty }
        let text = DiagnosticLog.shared.retainedText()
        #expect(text.contains("[dictation] dictation.started mode=handsFree model=parakeet engine=parakeet"))
        #expect(text.contains("[dictation] dictation.stopped seconds=2 voiced=1.5"))
        #expect(text.contains("[dictation] job.finished engine=parakeet outcome=success seconds=0.4 retry=no"))
        #expect(text.contains("[dictation] paste outcome=pasted dictation=yes"))
        #expect(!text.contains("com.example.secret-notes"), "never the app the text went to")
        #expect(!text.contains("private place"), "never the transcript")
    }
}
