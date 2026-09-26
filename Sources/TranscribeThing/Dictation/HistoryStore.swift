import Foundation
import Observation

enum TranscriptStatus: String, Codable, Sendable { case success, failed, cancelled }

struct TranscriptEntry: Codable, Identifiable, Equatable, Sendable {
    /// Same as `Recording.id`.
    let id: UUID
    var createdAt: Date
    /// Empty for failed/canceled entries.
    var text: String
    var engine: EngineID
    var status: TranscriptStatus
    var audioDuration: TimeInterval
    var voicedSeconds: TimeInterval
    var processingTime: TimeInterval?
    var costUSD: Double?
    var errorMessage: String?
    /// Present only for failed/canceled entries; pruned after `keepFailedRecordingsDays`.
    var audioFileName: String?
    /// OpenRouter provider that served a cloud transcript ("Groq", "Together"). Filled in shortly after
    /// delivery; absent from older history files.
    var provider: String?

    init(id: UUID = UUID(), createdAt: Date = Date(), text: String, engine: EngineID,
         status: TranscriptStatus = .success, audioDuration: TimeInterval, voicedSeconds: TimeInterval,
         processingTime: TimeInterval? = nil, costUSD: Double? = nil, errorMessage: String? = nil,
         audioFileName: String? = nil, provider: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.engine = engine
        self.status = status
        self.audioDuration = audioDuration
        self.voicedSeconds = voicedSeconds
        self.processingTime = processingTime
        self.costUSD = costUSD
        self.errorMessage = errorMessage
        self.audioFileName = audioFileName
        self.provider = provider
    }

    var wordCount: Int { Self.countWords(text) }

    /// Whitespace-separated tokens; tokens made only of punctuation (a lone "—" or "…") don't count.
    static func countWords(_ text: String) -> Int {
        var count = 0
        for token in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        where token.contains(where: { $0.isLetter || $0.isNumber }) {
            count += 1
        }
        return count
    }
}

struct HistoryStats: Equatable, Sendable {
    var wordsThisWeek: Int
    /// Last 7 days, oldest first.
    var dailyWords: [Int]
    var averageWPM: Int?
    /// words / 40 wpm − speaking time, never negative.
    var timeSavedSeconds: TimeInterval
    var totalDictations: Int

    static let empty = HistoryStats(wordsThisWeek: 0, dailyWords: Array(repeating: 0, count: 7),
                                    averageWPM: nil, timeSavedSeconds: 0, totalDictations: 0)

    /// Typing speed the "time saved" tile compares against.
    static let typingWPM: Double = 40

    /// Pure stats math over any set of entries (only successful ones count).
    static func compute(_ entries: [TranscriptEntry], now: Date, calendar: Calendar) -> HistoryStats {
        let today = calendar.startOfDay(for: now)
        var daily = Array(repeating: 0, count: 7)
        var words = 0
        var speaking: TimeInterval = 0
        var voiced: TimeInterval = 0
        var count = 0
        for entry in entries where entry.status == .success {
            let n = entry.wordCount
            count += 1
            words += n
            speaking += max(0, entry.audioDuration)
            voiced += max(0, entry.voicedSeconds)
            let day = calendar.startOfDay(for: entry.createdAt)
            if let ago = calendar.dateComponents([.day], from: day, to: today).day, (0..<7).contains(ago) {
                daily[6 - ago] += n
            }
        }
        // Speed is words per minute of actual speech; below a few seconds of speech the number is noise.
        let wpm: Int? = voiced >= 3 && words > 0 ? Int((Double(words) / (voiced / 60)).rounded()) : nil
        let saved = max(0, Double(words) / typingWPM * 60 - speaking)
        return HistoryStats(wordsThisWeek: daily.reduce(0, +), dailyWords: daily, averageWPM: wpm,
                            timeSavedSeconds: saved, totalDictations: count)
    }
}

/// Transcript history: JSON on disk (read and written off the main thread), plus WAV files for failed or
/// canceled dictations so they can be retried.
@MainActor @Observable
final class HistoryStore {
    static let maxEntries = 2000

    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let settings: AppSettings
    /// Preview stores never touch the disk.
    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private let io = HistoryIO()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var didLoad = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var statsCache: (revision: Int, day: Date, stats: HistoryStats)?
    /// Audio of deleted entries lingers briefly so the Hub's "Undo" can bring the row back intact.
    @ObservationIgnored private var pendingFileRemovals: [String: Task<Void, Never>] = [:]
    static let deletedAudioGrace: Duration = .seconds(15)

    /// Newest first, at most `maxEntries`.
    private(set) var entries: [TranscriptEntry] = []
    /// True once the on-disk history has been read (or there was none).
    private(set) var isLoaded = false

    init(paths: AppPaths, settings: AppSettings) {
        self.paths = paths
        self.settings = settings
        self.persists = true
    }

    private init(previewEntries: [TranscriptEntry]) {
        self.paths = .temporary()
        self.settings = .inMemory()
        self.persists = false
        self.entries = Self.normalized(previewEntries)
        self.isLoaded = true
        self.didLoad = true
    }

    static func preview(entries: [TranscriptEntry]) -> HistoryStore {
        HistoryStore(previewEntries: entries)
    }

    // MARK: - Derived

    /// Cached per revision and day: SwiftUI reads this on every render of Home.
    var stats: HistoryStats {
        let current = entries
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        if let cache = statsCache, cache.revision == revision, cache.day == day { return cache.stats }
        let computed = HistoryStats.compute(current, now: now, calendar: .current)
        statsCache = (revision, day, computed)
        return computed
    }

    func stats(now: Date, calendar: Calendar) -> HistoryStats {
        HistoryStats.compute(entries, now: now, calendar: calendar)
    }

    var lastSuccessfulText: String? {
        entries.first { $0.status == .success && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.text
    }

    func entry(id: UUID) -> TranscriptEntry? {
        entries.first { $0.id == id }
    }

    // MARK: - Loading and saving

    /// Reads history.json off the main thread. Entries added before the read finishes are kept.
    func load() {
        guard persists, !didLoad else { return }
        didLoad = true
        let file = paths.historyFile
        let io = io
        Task { [weak self] in
            let result = await io.read(file)
            self?.finishLoading(result)
        }
    }

    private func finishLoading(_ result: HistoryIO.ReadResult) {
        switch result {
        case .missing:
            break
        case .loaded(let loaded):
            let pending = entries
            let pendingIDs = Set(pending.map(\.id))
            entries = Self.normalized(pending + loaded.filter { !pendingIDs.contains($0.id) })
            changed(save: !pending.isEmpty)
        case .unreadable(let message):
            Log.app.error("History file unreadable, kept a copy aside: \(message, privacy: .public)")
            changed(save: !entries.isEmpty)
        }
        isLoaded = true
        pruneOldRecordings()
    }

    /// Writes immediately (used at quit).
    func flush() {
        guard persists else { return }
        saveTask?.cancel()
        saveTask = nil
        io.writeSync(entries, to: paths.historyFile)
    }

    private func changed(save: Bool = true) {
        revision &+= 1
        guard save, persists else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            // Coalesce bursts (upsert + prune) into one write.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.io.write(self.entries, to: self.paths.historyFile)
        }
    }

    // MARK: - Mutations

    func upsert(_ entry: TranscriptEntry) {
        if let file = entry.audioFileName { pendingFileRemovals.removeValue(forKey: file)?.cancel() }
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            let old = entries[i]
            if let oldFile = old.audioFileName, oldFile != entry.audioFileName {
                removeAudioFile(oldFile)
            }
            entries[i] = entry
            if old.createdAt != entry.createdAt { entries = Self.normalized(entries) }
        } else {
            let insertAt = entries.firstIndex { $0.createdAt < entry.createdAt } ?? entries.endIndex
            entries.insert(entry, at: insertAt)
            trimToLimit()
        }
        changed()
    }

    func delete(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if let file = entries[i].audioFileName { removeAudioFileLater(file) }
        entries.remove(at: i)
        changed()
    }

    func clearAll() {
        pendingFileRemovals.values.forEach { $0.cancel() }
        pendingFileRemovals.removeAll()
        entries.removeAll()
        if persists {
            let dir = paths.recordings
            io.perform {
                let fm = FileManager.default
                for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                    try? fm.removeItem(at: url)
                }
            }
        }
        changed()
    }

    private func trimToLimit() {
        guard entries.count > Self.maxEntries else { return }
        for dropped in entries[Self.maxEntries...] {
            if let file = dropped.audioFileName { removeAudioFile(file) }
        }
        entries.removeLast(entries.count - Self.maxEntries)
    }

    // MARK: - Audio

    /// Writes the recording as a 16 kHz WAV into `paths.recordings` (off the main thread) and returns its file name.
    func saveAudio(_ recording: Recording) -> String? {
        guard persists, !recording.samples.isEmpty else { return nil }
        let name = "\(recording.id.uuidString).wav"
        let url = paths.recordingURL(fileName: name)
        let dir = paths.recordings
        let samples = recording.samples
        io.perform {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try WAVEncoder.pcm16(samples, sampleRate: Int(Recording.sampleRate)).write(to: url, options: .atomic)
            } catch {
                Log.app.error("Couldn't save recording: \(error.localizedDescription, privacy: .public)")
            }
        }
        return name
    }

    func loadRecording(for entry: TranscriptEntry) -> Recording? {
        guard let name = entry.audioFileName else { return nil }
        let url = paths.recordingURL(fileName: name)
        // Waits for a pending write of the same file to land first.
        guard let data = io.readSync(url), let samples = WAVEncoder.decode(data), !samples.isEmpty else { return nil }
        var speech = SpeechAnalyzer.stats(for: samples)
        if speech.voicedSeconds == 0 && entry.voicedSeconds > 0 { speech.voicedSeconds = entry.voicedSeconds }
        return Recording(id: entry.id, samples: samples, startedAt: entry.createdAt, speech: speech)
    }

    func audioURL(for entry: TranscriptEntry) -> URL? {
        guard let name = entry.audioFileName else { return nil }
        let url = paths.recordingURL(fileName: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Drops audio of failed/canceled dictations older than `keepFailedRecordingsDays`, plus orphaned files.
    func pruneOldRecordings(now: Date = Date()) {
        let days = max(0, settings.keepFailedRecordingsDays)
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var didChange = false
        for i in entries.indices {
            guard let file = entries[i].audioFileName, entries[i].createdAt < cutoff else { continue }
            removeAudioFile(file)
            entries[i].audioFileName = nil
            didChange = true
        }
        if didChange { changed() }

        guard persists, isLoaded else { return }
        let referenced = Set(entries.compactMap(\.audioFileName))
        let dir = paths.recordings
        io.perform {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
            where url.pathExtension == "wav" && !referenced.contains(url.lastPathComponent) {
                // Grace period: a file written moments ago may belong to an entry that isn't upserted yet.
                let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                if modified < now.addingTimeInterval(-3600) { try? fm.removeItem(at: url) }
            }
        }
    }

    private func removeAudioFileLater(_ name: String) {
        guard persists else { return }
        pendingFileRemovals[name]?.cancel()
        pendingFileRemovals[name] = Task { [weak self] in
            try? await Task.sleep(for: Self.deletedAudioGrace)
            guard !Task.isCancelled, let self else { return }
            self.pendingFileRemovals[name] = nil
            if !self.entries.contains(where: { $0.audioFileName == name }) { self.removeAudioFile(name) }
        }
    }

    private func removeAudioFile(_ name: String) {
        guard persists else { return }
        let url = paths.recordingURL(fileName: name)
        io.perform { try? FileManager.default.removeItem(at: url) }
    }

    private static func normalized(_ list: [TranscriptEntry]) -> [TranscriptEntry] {
        var seen = Set<UUID>()
        let unique = list.filter { seen.insert($0.id).inserted }
        return Array(unique.sorted { $0.createdAt > $1.createdAt }.prefix(maxEntries))
    }
}

/// Serial file IO for the history: JSON reads/writes and WAV files, in submission order.
private final class HistoryIO: @unchecked Sendable {
    enum ReadResult: Sendable {
        case missing
        case loaded([TranscriptEntry])
        case unreadable(String)
    }

    private let queue = DispatchQueue(label: "dev.transcribe-thing.history", qos: .utility)
    /// ISO 8601 with milliseconds: readable, and ordering survives a reload.
    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private struct FileFormat: Codable {
        var version: Int
        var entries: [LossyEntry]
    }

    /// One malformed entry (say, an engine from a newer build) must not cost the whole history.
    private struct LossyEntry: Codable {
        var value: TranscriptEntry?

        init(_ value: TranscriptEntry) { self.value = value }

        init(from decoder: Decoder) throws {
            value = try? TranscriptEntry(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            try value.encode(to: encoder)
        }
    }

    func perform(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    func read(_ url: URL) async -> ReadResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.readNow(url))
            }
        }
    }

    func readSync(_ url: URL) -> Data? {
        queue.sync { try? Data(contentsOf: url) }
    }

    func write(_ entries: [TranscriptEntry], to url: URL) {
        queue.async { Self.writeNow(entries, to: url) }
    }

    func writeSync(_ entries: [TranscriptEntry], to url: URL) {
        queue.sync { Self.writeNow(entries, to: url) }
    }

    private static func readNow(_ url: URL) -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let raw = try decoder.singleValueContainer().decode(String.self)
                if let date = try? Date(raw, strategy: Self.dateStyle) { return date }
                if let date = try? Date(raw, strategy: .iso8601) { return date }
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(raw)"))
            }
            let file = try decoder.decode(FileFormat.self, from: data)
            return .loaded(file.entries.compactMap(\.value))
        } catch {
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("history-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: aside)
            return .unreadable(error.localizedDescription)
        }
    }

    private static func writeNow(_ entries: [TranscriptEntry], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Self.dateStyle))
        }
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(FileFormat(version: 1, entries: entries.map(LossyEntry.init)))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.app.error("Couldn't save history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
