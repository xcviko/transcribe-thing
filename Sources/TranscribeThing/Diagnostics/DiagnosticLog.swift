import Foundation
import os

/// What an event is about: the word in brackets on its line.
enum DiagnosticCategory: String, Sendable {
    case app, settings, dictation, engine, net, models, updates, mic, permissions, hotkeys
}

/// The log a friend can send when something breaks: what the app did over the last few days, one line per event, in
/// plain text files under `AppPaths.logs`, one per day ("2026-10-02.log"). macOS's own log isn't enough for that: it
/// doesn't keep info lines, and keeps the app's other lines for hours only.
///
/// A line reads `2026-10-02T14:03:22.481+04:00 [dictation] job.finished engine=geminiFlash outcome=success`. Its
/// values are codes, numbers, ids and enums (`DiagnosticValue`), never what the user said or typed, and the home
/// folder is written as "~". Each line also goes to macOS's log, at info level.
///
/// Nothing is written until `start(directory:)`: the app starts `shared` at launch, while tests, previews and the
/// command-line tools leave it off. Writing happens on a serial queue of its own, so an event never waits for the
/// disk, and a write that fails is dropped without a word: the log must never get in a dictation's way. The files
/// keep the last `Limits.days` days and at most `Limits.totalBytes` in all, checked at the start and whenever a new
/// day's file starts.
final class DiagnosticLog: @unchecked Sendable {
    // @unchecked: `enabled` is behind its lock, and every other mutable property is touched on `queue` only.

    /// The app's log, off until the app starts it.
    static let shared = DiagnosticLog()

    struct Limits: Sendable, Equatable {
        /// Days of files kept, today's included.
        var days = 7
        /// What all the files may take together; also the most one day's file grows to.
        var totalBytes: Int64 = 10 * 1024 * 1024
    }

    /// The longest a value is written, in characters (an OpenRouter error quoting a provider can run long).
    static let maxValueLength = 1500

    let limits: Limits
    private let clock: @Sendable () -> Date
    private let format: DiagnosticTimeFormat
    private let homePath: String
    private let enabled = OSAllocatedUnfairLock(initialState: false)
    private let queue = DispatchQueue(label: "dev.transcribe-thing.diagnostics", qos: .utility)

    // On `queue` only.
    private var directory: URL?
    private var handle: FileHandle?
    /// The day `handle` writes, nil while no file is open.
    private var openDay: String?
    /// What today's file holds, so a runaway day stops at `limits.totalBytes`.
    private var dayBytes: Int64 = 0
    /// The day the files were last checked against the limits.
    private var prunedDay: String?

    /// `clock` dates each line; `timeZone` its time and the day file it goes to; `homeDirectory` is written as "~".
    init(clock: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current,
         homeDirectory: String = NSHomeDirectory(), limits: Limits = Limits()) {
        self.clock = clock
        self.format = DiagnosticTimeFormat(timeZone: timeZone)
        var home = homeDirectory
        while home.count > 1, home.hasSuffix("/") { home.removeLast() }
        self.homePath = home
        self.limits = limits
    }

    // MARK: Starting and stopping

    /// Writes into `directory` (created when needed) from now on, after deleting what the limits no longer keep.
    func start(directory: URL) {
        let now = clock()
        enabled.withLock { $0 = true }
        queue.async { [self] in
            closeFile()
            self.directory = directory
            prune(in: directory, now: now)
            prunedDay = format.day(now)
        }
    }

    /// Writes nothing from now on (events already queued are written first).
    func stop() {
        enabled.withLock { $0 = false }
        queue.async { [self] in
            closeFile()
            directory = nil
            prunedDay = nil
        }
    }

    var isStarted: Bool { enabled.withLock { $0 } }

    /// Returns once every event logged before the call is written. Blocks: never on the main thread while it matters.
    func flush() {
        queue.sync {}
    }

    // MARK: Events

    /// One event: `name` says what happened ("job.finished"), `fields` the details, in order. A nil value leaves its
    /// field out. Values are codes, numbers, ids and enums: never transcripts, prompts, the clipboard, window titles,
    /// the apps text is pasted into, device names, the user's name or the key.
    func event(_ category: DiagnosticCategory, _ name: String,
               _ fields: KeyValuePairs<String, (any DiagnosticValue)?> = [:]) {
        guard isStarted else { return }
        let pairs = fields.compactMap { key, value in value.map { DiagnosticField(key, $0.diagnosticText) } }
        record(category, name, pairs)
    }

    /// The same, for fields put together elsewhere (the settings summary, the Mac's details).
    func event(_ category: DiagnosticCategory, _ name: String, fields: [DiagnosticField]) {
        guard isStarted else { return }
        record(category, name, fields)
    }

    private func record(_ category: DiagnosticCategory, _ name: String, _ fields: [DiagnosticField]) {
        let now = clock()
        let message = scrubbed(Self.message(category, name, fields))
        Log.diagnostics.info("\(message, privacy: .public)")
        let line = "\(format.timestamp(now)) \(message)"
        let day = format.day(now)
        queue.async { [self] in append(line, day: day, now: now) }
    }

    // MARK: Line format

    /// "[dictation] job.finished engine=geminiFlash seconds=4.2": a line without its time.
    static func message(_ category: DiagnosticCategory, _ name: String, _ fields: [DiagnosticField]) -> String {
        var message = "[\(category.rawValue)] \(name)"
        for field in fields {
            message += " \(field.key)=\(quoted(field.value))"
        }
        return message
    }

    /// A value as a line holds it: on one line, cut at `maxValueLength`, and in quotes when it has spaces, quotes,
    /// "=" or backslashes in it (or nothing at all): `server="cloudflare proxy"`.
    static func quoted(_ value: String) -> String {
        let isBreak = { (c: Character) in c.isNewline || c == "\t" || c.asciiValue.map { $0 < 0x20 } == true }
        var text = String(value.map { isBreak($0) ? " " : $0 })
        if text.count > maxValueLength { text = String(text.prefix(maxValueLength - 1)) + "…" }
        guard text.isEmpty || text.contains(where: { $0 == " " || $0 == "\"" || $0 == "=" || $0 == "\\" }) else {
            return text
        }
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// `text` with the home folder written as "~": "/Users/sam/Library/…" reads "~/Library/…", and so does the end
    /// of a sentence, "… in /Users/sam.". Only the whole folder: "/Users/samuel" and "/Users/sam.old" stay as they are.
    static func scrubbingHome(_ text: String, home: String) -> String {
        guard home.count > 1, text.contains(home) else { return text }
        func isNameCharacter(_ c: Character?) -> Bool {
            c.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } ?? false
        }
        var result = ""
        var rest = text[...]
        while let range = rest.range(of: home) {
            result += rest[..<range.lowerBound]
            let after = rest[range.upperBound...]
            let next = after.first
            let continuesName = isNameCharacter(next) || (next == "." && isNameCharacter(after.dropFirst().first))
            result += continuesName ? String(rest[range]) : "~"
            rest = after
        }
        return result + rest
    }

    private func scrubbed(_ text: String) -> String {
        Self.scrubbingHome(text, home: homePath)
    }

    // MARK: Files

    /// "2026-10-02" for "2026-10-02.log"; nil for any other file, which the log never touches.
    static func day(ofFileNamed name: String) -> String? {
        guard name.hasSuffix(".log") else { return nil }
        let day = String(name.dropLast(4))
        let digits = day.enumerated().allSatisfy { index, character in
            index == 4 || index == 7 ? character == "-" : character.isASCII && character.isNumber
        }
        return day.count == 10 && digits ? day : nil
    }

    /// The day files in `directory`, oldest first.
    private static func dayFiles(in directory: URL) -> [(url: URL, day: String)] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.compactMap { url in day(ofFileNamed: url.lastPathComponent).map { (url, $0) } }
            .sorted { $0.day < $1.day }
    }

    /// Every line the files keep, oldest first, once the events logged before the call are written. Empty while
    /// the log is off. Blocks: call it off the main thread.
    func retainedText() -> String {
        queue.sync {
            guard let directory else { return "" }
            var text = ""
            for file in Self.dayFiles(in: directory) {
                guard let data = try? Data(contentsOf: file.url), !data.isEmpty else { continue }
                text += String(decoding: data, as: UTF8.self)
                if !text.hasSuffix("\n") { text += "\n" }
            }
            return text
        }
    }

    private func append(_ line: String, day: String, now: Date) {
        guard let directory else { return }
        if day != openDay { openFile(day: day, in: directory, now: now) }
        guard let handle, dayBytes < limits.totalBytes else { return }
        let data = Data((line + "\n").utf8)
        do {
            try handle.write(contentsOf: data)
            dayBytes += Int64(data.count)
        } catch {
            // The next event opens the file again.
            closeFile()
        }
    }

    /// Opens (or creates) `day`'s file for appending. The first file of a day checks the limits first.
    private func openFile(day: String, in directory: URL, now: Date) {
        closeFile()
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if prunedDay != day {
            prune(in: directory, now: now)
            prunedDay = day
        }
        let url = directory.appendingPathComponent("\(day).log", isDirectory: false)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url),
              let size = try? handle.seekToEnd() else { return }
        self.handle = handle
        dayBytes = Int64(size)
        openDay = day
    }

    private func closeFile() {
        try? handle?.close()
        handle = nil
        openDay = nil
    }

    /// Deletes the day files older than `limits.days` days, then the oldest ones while all of them together take
    /// more than `limits.totalBytes`. Today's file stays whatever its size (`append` stops it growing).
    private func prune(in directory: URL, now: Date) {
        let fm = FileManager.default
        let today = format.day(now)
        let cutoff = format.day(format.calendar.date(byAdding: .day, value: -(limits.days - 1), to: now) ?? now)
        var kept: [(url: URL, day: String, size: Int64)] = []
        for file in Self.dayFiles(in: directory) {
            if file.day < cutoff {
                try? fm.removeItem(at: file.url)
            } else {
                let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                kept.append((file.url, file.day, Int64(size)))
            }
        }
        var total = kept.reduce(Int64(0)) { $0 + $1.size }
        for file in kept {
            guard total > limits.totalBytes else { break }
            guard file.day != today else { continue }
            try? fm.removeItem(at: file.url)
            total -= file.size
        }
    }
}

/// A field of an event, as its line shows it: `key=value`.
struct DiagnosticField: Equatable, Sendable {
    var key: String
    var value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}

/// A line's time, "2026-10-02T14:03:22.481+04:00", and its day, "2026-10-02", in one time zone. The same on every
/// Mac, whatever its language or calendar.
struct DiagnosticTimeFormat: Sendable {
    let calendar: Calendar

    init(timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        self.calendar = calendar
    }

    func timestamp(_ date: Date) -> String {
        // Whole milliseconds first, so .481 never reads .480 through floating point.
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        let second = Date(timeIntervalSince1970: (milliseconds / 1000).rounded(.down))
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: second)
        let millis = Int(milliseconds - second.timeIntervalSince1970 * 1000)
        let offset = calendar.timeZone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03d%@%02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, millis,
                      sign, abs(offset) / 3600, abs(offset) % 3600 / 60)
    }

    func day(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "2026-10-02-1403", for the exported file's name.
    func minute(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d-%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0,
                      c.minute ?? 0)
    }
}
