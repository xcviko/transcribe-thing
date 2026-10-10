import Foundation
import Observation

enum TranscriptStatus: String, Codable, Sendable { case success, failed, cancelled }

struct TranscriptEntry: Codable, Identifiable, Equatable, Sendable {
    /// Same as `Recording.id`.
    let id: UUID
    var createdAt: Date
    var status: TranscriptStatus
    var audioDuration: TimeInterval
    var voicedSeconds: TimeInterval
    var errorMessage: String?
    /// Held or hands-free: a Retry or Paste Last pastes it by General → Pasting's rules for that. Push to talk for an
    /// entry from before it was kept.
    var mode: DictationMachine.Mode
    /// The recording, for Retry and Transcribe With, kept as long as the entry (it goes with a delete, Auto-delete and
    /// the oldest entries past `HistoryStore.maxEntries`). nil only where an older build pruned it or none was saved.
    var audioFileName: String?
    /// The name of the audio file this entry was made from (dropped on Home, or picked with Transcribe File…); nil for
    /// a dictation. Its row shows it, and the stats (words, speed, time saved) leave it out: it isn't the user talking.
    var importedFrom: String?
    /// Every transcript of the recording, oldest first, at most one of each kind (one per model). Empty for failed
    /// and canceled entries. Change them through `addVersion`, `selectVersion` and `updateMetadata`.
    private(set) var versions: [TranscriptVersion]
    /// The version the row shows, copies, searches and pastes. nil exactly when `versions` is empty.
    private(set) var currentKind: TranscriptVersionKind?
    /// The engine of a failed or canceled dictation (what Retry uses again); kept equal to the current version's
    /// otherwise, so entries that read the same compare equal.
    private var attemptedEngine: EngineID

    /// `text`, `provider`, `costUSD` and `processingTime` describe a successful entry's first version. Failed and
    /// canceled entries have no version: no text and nothing else, just the engine they were dictated with.
    init(id: UUID = UUID(), createdAt: Date = Date(), text: String, engine: EngineID,
         status: TranscriptStatus = .success, audioDuration: TimeInterval, voicedSeconds: TimeInterval,
         processingTime: TimeInterval? = nil, costUSD: Double? = nil, errorMessage: String? = nil,
         mode: DictationMachine.Mode = .pushToTalk, audioFileName: String? = nil, importedFrom: String? = nil,
         provider: String? = nil) {
        let version = TranscriptVersion(text: text, engine: engine, provider: provider, costUSD: costUSD,
                                        processingTime: processingTime, createdAt: createdAt)
        self.init(id: id, createdAt: createdAt, engine: engine, status: status, audioDuration: audioDuration,
                  voicedSeconds: voicedSeconds, errorMessage: errorMessage, mode: mode, audioFileName: audioFileName,
                  importedFrom: importedFrom, versions: status == .success ? [version] : [])
    }

    /// An entry with these versions (success only; ignored otherwise). `current`: the one it shows, by default the
    /// last. Versions of a kind already listed are dropped.
    init(id: UUID = UUID(), createdAt: Date = Date(), engine: EngineID, status: TranscriptStatus = .success,
         audioDuration: TimeInterval, voicedSeconds: TimeInterval, errorMessage: String? = nil,
         mode: DictationMachine.Mode = .pushToTalk, audioFileName: String? = nil, importedFrom: String? = nil,
         versions: [TranscriptVersion], current: TranscriptVersionKind? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.status = status
        self.audioDuration = audioDuration
        self.voicedSeconds = voicedSeconds
        self.errorMessage = errorMessage
        self.mode = mode
        self.audioFileName = audioFileName
        self.importedFrom = importedFrom
        self.attemptedEngine = engine
        var unique: [TranscriptVersion] = []
        for version in versions where !unique.contains(where: { $0.kind == version.kind }) { unique.append(version) }
        self.versions = status == .success ? unique : []
        let chosen = current.flatMap { kind in self.versions.contains { $0.kind == kind } ? kind : nil }
        self.currentKind = chosen ?? self.versions.last?.kind
        syncEngine()
    }

    private mutating func syncEngine() {
        if let engine = currentVersion?.engine { attemptedEngine = engine }
    }

    // MARK: The current version

    var currentVersion: TranscriptVersion? {
        currentKind.flatMap { kind in versions.first { $0.kind == kind } }
    }

    private var currentIndex: Int? {
        currentKind.flatMap { kind in versions.firstIndex { $0.kind == kind } }
    }

    /// The current version's text; empty for failed/canceled entries. Setting it edits the current version.
    var text: String {
        get { currentVersion?.text ?? "" }
        set { if let i = currentIndex { versions[i].text = newValue } }
    }

    /// The engine that heard the audio: the current version's, or the one a failed or canceled dictation used.
    var engine: EngineID { currentVersion?.engine ?? attemptedEngine }

    /// OpenRouter provider that served the current version ("Together", "Google AI Studio"). Filled in shortly
    /// after delivery when the response didn't say.
    var provider: String? {
        get { currentVersion?.metadata.provider }
        set { if let i = currentIndex { versions[i].metadata.provider = newValue } }
    }

    var costUSD: Double? { currentVersion?.metadata.costUSD }
    var processingTime: TimeInterval? { currentVersion?.metadata.processingTime }

    // MARK: Versions

    func version(_ kind: TranscriptVersionKind) -> TranscriptVersion? {
        versions.first { $0.kind == kind }
    }

    func hasVersion(_ kind: TranscriptVersionKind) -> Bool {
        versions.contains { $0.kind == kind }
    }

    /// Adds `version` (replacing one of the same kind, which keeps its place) and, by default, makes it current.
    /// Only a successful entry has versions: false otherwise.
    @discardableResult
    mutating func addVersion(_ version: TranscriptVersion, makeCurrent: Bool = true) -> Bool {
        guard status == .success else { return false }
        if let i = versions.firstIndex(where: { $0.kind == version.kind }) {
            versions[i] = version
        } else {
            versions.append(version)
        }
        if makeCurrent || currentKind == nil { currentKind = version.kind }
        syncEngine()
        return true
    }

    /// Shows the version of `kind`; false when there is none.
    @discardableResult
    mutating func selectVersion(_ kind: TranscriptVersionKind) -> Bool {
        guard hasVersion(kind) else { return false }
        currentKind = kind
        syncEngine()
        return true
    }

    /// Edits the metadata of the version of `kind`; false when there is none.
    @discardableResult
    mutating func updateMetadata(of kind: TranscriptVersionKind, _ update: (inout TranscriptMetadata) -> Void) -> Bool {
        guard let i = versions.firstIndex(where: { $0.kind == kind }) else { return false }
        update(&versions[i].metadata)
        return true
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, status, audioDuration, voicedSeconds, errorMessage, mode, audioFileName, importedFrom
        case versions
        case currentKind = "currentVersion"
        /// The current version, flat, as older builds read it; and what an entry from before versions holds.
        case text, engine, provider, costUSD, processingTime
        /// The transcript a Transcribe Again replaced, from the builds between the two formats.
        case previous
    }

    /// Reads every format: with versions; from before versions (the transcript flat, maybe a `previous` one, which
    /// becomes the older version); retired engines mapped to their successors (`retiredEngines`), so the entry keeps
    /// its text, cost and provider, and Retry and the history glyph go on working. A version this build can't read
    /// (an engine from a newer build) is dropped, not the entry.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        status = try c.decode(TranscriptStatus.self, forKey: .status)
        audioDuration = try c.decode(TimeInterval.self, forKey: .audioDuration)
        voicedSeconds = try c.decode(TimeInterval.self, forKey: .voicedSeconds)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        // A mode from a newer build reads as push to talk, not as an unreadable entry.
        mode = (try? c.decodeIfPresent(DictationMachine.Mode.self, forKey: .mode)).flatMap { $0 } ?? .pushToTalk
        audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName)
        importedFrom = try c.decodeIfPresent(String.self, forKey: .importedFrom)
        attemptedEngine = try Self.decodeEngine(from: c, forKey: .engine)

        var decoded = ((try? c.decodeIfPresent([LossyVersion].self, forKey: .versions)) ?? []).compactMap(\.value)
        var current = (try? c.decodeIfPresent(String.self, forKey: .currentKind)).flatMap { $0 }
            .flatMap(TranscriptVersionKind.init(rawValue:))
        if status == .success, current.map({ kind in !decoded.contains { $0.kind == kind } }) ?? true {
            // No versions yet (an older file), or the current one is unreadable: the flat transcript is current.
            let flat = TranscriptVersion(
                text: try c.decode(String.self, forKey: .text), engine: attemptedEngine,
                provider: try c.decodeIfPresent(String.self, forKey: .provider),
                costUSD: try c.decodeIfPresent(Double.self, forKey: .costUSD),
                processingTime: try c.decodeIfPresent(TimeInterval.self, forKey: .processingTime), createdAt: createdAt)
            decoded.removeAll { $0.kind == flat.kind }
            decoded.append(flat)
            current = flat.kind
        }
        if var previous = try? c.decodeIfPresent(TranscriptVersion.self, forKey: .previous),
           !decoded.contains(where: { $0.kind == previous.kind }) {
            if previous.metadata.createdAt == TranscriptVersion.legacyDate { previous.metadata.createdAt = createdAt }
            decoded.insert(previous, at: 0)
        }
        versions = status == .success ? decoded : []
        currentKind = status == .success ? current : nil
        syncEngine()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(status, forKey: .status)
        try c.encode(audioDuration, forKey: .audioDuration)
        try c.encode(voicedSeconds, forKey: .voicedSeconds)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(audioFileName, forKey: .audioFileName)
        try c.encodeIfPresent(importedFrom, forKey: .importedFrom)
        // An older build that can't read the current kind takes the flat fields for the current version, as a
        // transcription by `engine`, in place of that transcription. For a clean-up it can't read, they hold the
        // transcription the clean-up tidied, so an older build keeps that text rather than the clean-up's under its
        // name.
        let flat = currentKind.flatMap { kind in
            kind.isReadableByOlderBuilds ? nil : version(.transcription(kind.engine))
        } ?? currentVersion
        try c.encode(flat?.text ?? "", forKey: .text)
        try c.encode(engine, forKey: .engine)
        try c.encodeIfPresent(flat?.metadata.provider, forKey: .provider)
        try c.encodeIfPresent(flat?.metadata.costUSD, forKey: .costUSD)
        try c.encodeIfPresent(flat?.metadata.processingTime, forKey: .processingTime)
        if !versions.isEmpty {
            try c.encode(versions, forKey: .versions)
            try c.encodeIfPresent(currentKind?.rawValue, forKey: .currentKind)
        }
    }

    /// One element of `versions`, nil when this build can't read it.
    private struct LossyVersion: Decodable {
        var value: TranscriptVersion?
        init(from decoder: Decoder) throws { value = try? TranscriptVersion(from: decoder) }
    }

    static func decodeEngine<Key: CodingKey>(from c: KeyedDecodingContainer<Key>, forKey key: Key) throws -> EngineID {
        let rawEngine = try c.decode(String.self, forKey: key)
        guard let engine = EngineID(rawValue: rawEngine) ?? retiredEngines[rawEngine] else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Unknown engine \(rawEngine)")
        }
        return engine
    }

    /// Removed engines by raw value → the engine their entries read as now: Whisper Large V3 Turbo on this Mac
    /// and through OpenRouter each map to Parakeet v3 on the same side.
    static let retiredEngines: [String: EngineID] = ["whisper": .parakeet, "whisperCloud": .parakeetCloud]

    var wordCount: Int { Self.countWords(text) }

    /// A selection's polish (Polish Selection): no recording, nothing dictated, so it stays out of the dictation stats.
    var isSelection: Bool { currentKind?.isSelection == true }

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

    /// Typing speed the "time saved" tile compares against: a practiced typist's.
    static let typingWPM: Double = 80

    /// Pure stats math over any set of entries (only successful ones count).
    static func compute(_ entries: [TranscriptEntry], now: Date, calendar: Calendar) -> HistoryStats {
        let today = calendar.startOfDay(for: now)
        var daily = Array(repeating: 0, count: 7)
        var words = 0
        var speaking: TimeInterval = 0
        var voiced: TimeInterval = 0
        var count = 0
        for entry in entries where entry.status == .success && !entry.isSelection && entry.importedFrom == nil {
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

/// Transcript history: JSON on disk (read and written off the main thread), plus each entry's recording as a file
/// (`RecordingFile`: AAC, or WAV from older builds until `compressLegacyRecordings` converts it), so failed or
/// canceled dictations can be retried and any transcript transcribed again with another model. An entry and its
/// recording go together: deleted, cleared, auto-deleted (`AppSettings.autoDeleteHistoryDays`) or past `maxEntries`.
/// A dictation is on disk before it gets here too (`RecordingJournal`): one an earlier run never finished comes back
/// at launch as a failed entry (`recoverJournals`).
@MainActor @Observable
final class HistoryStore {
    static let maxEntries = 2000
    /// What a dictation brought back from its journal says in place of an engine's error.
    static let interruptedMessage = "The app quit before it was transcribed"

    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let settings: AppSettings
    /// Preview stores never touch the disk.
    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private let io = HistoryIO()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var didLoad = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var statsCache: (revision: Int, day: Date, stats: HistoryStats)?
    @ObservationIgnored private var daysCache: (revision: Int, day: Date, query: String, days: [HistoryDay])?
    /// Audio of deleted entries lingers briefly so the Hub's "Undo" can bring the row back intact.
    @ObservationIgnored private var pendingFileRemovals: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var deletedAudioGrace: Duration = .seconds(15)
    /// The latest save of each recording still being written, by recording id (`saveAudio`).
    @ObservationIgnored private var latestSaves: [UUID: UUID] = [:]
    @ObservationIgnored private var isCompressing = false
    /// Entries just removed, by id: deleted, cleared, auto-deleted, or the oldest past `maxEntries`.
    @ObservationIgnored var onRemove: (([UUID]) -> Void)?
    /// Whether a dictation or Home is working on the recording right now (`DictationController.isInFlight`):
    /// `compressLegacyRecordings` leaves its file alone meanwhile.
    @ObservationIgnored var isInUse: (UUID) -> Bool = { _ in false }
    /// Replaces the AAC encoder (`RecordingFile.aac`) for saves and conversions: tests.
    @ObservationIgnored var encodeOverride: RecordingFile.Encoder?
    /// Where dictations are kept while they're recorded and transcribed (`AudioRecorder` writes them); nil for a
    /// preview store.
    @ObservationIgnored let journal: RecordingJournal?
    /// Recordings saved since history.json was last written, by id, with how many samples were saved: their journals
    /// go once it names them (`removeSavedJournals`).
    @ObservationIgnored private var savedJournals: [UUID: Int] = [:]
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?

    /// Newest first, at most `maxEntries`.
    private(set) var entries: [TranscriptEntry] = []
    /// True once the on-disk history has been read (or there was none).
    private(set) var isLoaded = false
    /// Recordings `compressLegacyRecordings` has converted so far (General's size line follows it).
    private(set) var compressedRecordings = 0

    init(paths: AppPaths, settings: AppSettings) {
        self.paths = paths
        self.settings = settings
        self.persists = true
        self.journal = RecordingJournal(directory: paths.journals)
    }

    private init(previewEntries: [TranscriptEntry], settings: AppSettings) {
        self.paths = .temporary()
        self.settings = settings
        self.persists = false
        self.journal = nil
        self.entries = Self.normalized(previewEntries)
        self.isLoaded = true
        self.didLoad = true
    }

    /// `settings`: whose Auto-delete `deleteExpired` follows.
    static func preview(entries: [TranscriptEntry], settings: AppSettings? = nil) -> HistoryStore {
        HistoryStore(previewEntries: entries, settings: settings ?? .inMemory())
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

    /// Home's list: the entries matching the search `query`, grouped by day (`HistoryGrouping`). Cached per revision,
    /// day and query like `stats`, so a render of Home doesn't filter, sort and count words over the whole history.
    func days(matching query: String, now: Date) -> [HistoryDay] {
        let current = entries
        let day = Calendar.current.startOfDay(for: now)
        if let cache = daysCache, cache.revision == revision, cache.day == day, cache.query == query { return cache.days }
        let days = HistoryGrouping.days(HistoryGrouping.filter(current, query: query), now: now)
        daysCache = (revision, day, query, days)
        return days
    }

    func stats(now: Date, calendar: Calendar) -> HistoryStats {
        HistoryStats.compute(entries, now: now, calendar: calendar)
    }

    /// The newest dictation with text: what Paste Last and Copy Last Transcript use. A polished selection isn't one
    /// (its card had its own Paste Here, and closing it said no), nor is a file's transcript (a whole podcast).
    var lastSuccessful: TranscriptEntry? {
        entries.first {
            $0.status == .success && !$0.isSelection && $0.importedFrom == nil
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func entry(id: UUID) -> TranscriptEntry? {
        entries.first { $0.id == id }
    }

    // MARK: - Loading and saving

    /// The entries of a history file, read as `load()` reads them (an entry this build can't read is skipped), but
    /// only read: nothing is written or moved aside, even when the file is unreadable. For `EngineCLI`.
    nonisolated static func readEntries(from data: Data) throws -> [TranscriptEntry] {
        try HistoryIO.decode(data)
    }

    /// Reads history.json off the main thread. Entries added before the read finishes are kept.
    func load() {
        guard persists, !didLoad else { return }
        didLoad = true
        let file = paths.historyFile
        let io = io
        loadTask = Task { [weak self] in
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
        deleteExpired()
        recoveryTask = Task { [weak self] in await self?.recoverJournals() }
    }

    /// Writes immediately (used at quit).
    func flush() {
        guard persists else { return }
        saveTask?.cancel()
        saveTask = nil
        io.writeSync(entries, to: paths.historyFile)
        removeSavedJournals()
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
            self.removeSavedJournals()
        }
    }

    // MARK: - Mutations

    func upsert(_ entry: TranscriptEntry) {
        if let file = entry.audioFileName { pendingFileRemovals.removeValue(forKey: file)?.cancel() }
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            let old = entries[i]
            // The same recording in the other format takes over from its own file: the save that wrote it removed
            // that (`RecordingFile.save`), or it is the WAV a failed encode kept.
            if let oldFile = old.audioFileName, oldFile != entry.audioFileName,
               entry.audioFileName != RecordingFile.otherFormat(of: oldFile) {
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

    /// Shows the entry's version of `kind` (the Versions menu); nothing happens when it has none.
    func selectVersion(_ kind: TranscriptVersionKind, of id: UUID) {
        guard var entry = entry(id: id), entry.currentKind != kind, entry.selectVersion(kind) else { return }
        upsert(entry)
    }

    func delete(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if let file = entries[i].audioFileName { removeAudioFileLater(file) }
        entries.remove(at: i)
        changed()
        onRemove?([id])
    }

    func clearAll() {
        pendingFileRemovals.values.forEach { $0.cancel() }
        pendingFileRemovals.removeAll()
        let removed = entries.map(\.id)
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
        onRemove?(removed)
    }

    private func trimToLimit() {
        guard entries.count > Self.maxEntries else { return }
        let dropped = entries[Self.maxEntries...]
        for entry in dropped {
            if let file = entry.audioFileName { removeAudioFile(file) }
        }
        let removed = dropped.map(\.id)
        entries.removeLast(entries.count - Self.maxEntries)
        onRemove?(removed)
    }

    // MARK: - Audio

    /// Writes the recording into `paths.recordings` (encoded off the main thread) and returns its file name,
    /// `<id>.m4a` (`RecordingFile`). Should the encoder fail it's kept as a WAV instead, which the entry then names
    /// (unless the recording was saved again meanwhile). A recording read back from its .m4a (`Recording.aacFile`)
    /// keeps that file rather than being encoded a second time.
    func saveAudio(_ recording: Recording) -> String? {
        guard persists, !recording.samples.isEmpty else { return nil }
        let id = recording.id
        if journal != nil { savedJournals[id] = max(savedJournals[id] ?? 0, recording.samples.count) }
        let name = RecordingFile.name(for: id)
        let url = paths.recordingURL(fileName: name)
        let samples = recording.samples
        let isStored = recording.aacFile == url
        let encode = encodeOverride ?? RecordingFile.aac
        let save = UUID()
        latestSaves[id] = save
        io.perform { [weak self] in
            let saved = isStored && FileManager.default.fileExists(atPath: url.path)
                ? url : RecordingFile.save(samples, as: url, encode: encode)
            Task { @MainActor in self?.finishSaving(save, of: id, as: saved?.lastPathComponent) }
        }
        return name
    }

    /// A save of the recording is written. When its encoder failed and no newer save of it is on the way, the entry
    /// names the WAV it was kept as.
    private func finishSaving(_ save: UUID, of id: UUID, as saved: String?) {
        guard latestSaves[id] == save else { return }
        latestSaves[id] = nil
        guard let saved, var entry = entry(id: id), let name = entry.audioFileName,
              saved == RecordingFile.otherFormat(of: name) else { return }
        entry.audioFileName = saved
        upsert(entry)
    }

    // MARK: - Journals

    /// A recording that ends without History keeping it (too short, silent, canceled for good): its journal goes, or
    /// the next launch would bring it back.
    func discardJournal(of id: UUID) {
        journal?.remove(id)
    }

    /// Once history.json names them (this runs right after it's written, on the same queue), the journals of the
    /// recordings saved since go: where the recording's file is there, or its entry went meanwhile. One whose save
    /// failed stays for the next launch, which saves it again.
    private func removeSavedJournals() {
        guard let journal, !savedJournals.isEmpty else { return }
        let saved = savedJournals
        savedJournals = [:]
        let files = saved.keys.reduce(into: [UUID: [URL]]()) { files, id in
            if let entry = entry(id: id) { files[id] = recordingURLs(for: entry) ?? [] }
        }
        io.perform {
            for (id, samples) in saved {
                if let urls = files[id], !urls.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                    continue
                }
                journal.remove(id, ifAtMost: samples)
            }
        }
    }

    /// Returns once the launch's `recoverJournals` is done: tests.
    func waitForRecovery() async {
        await recoveryTask?.value
    }

    /// Brings back the dictations an earlier run was recording or transcribing when it ended (a crash, a kill, a power
    /// cut): each journal it left becomes a failed entry with its recording, so Retry and Transcribe With work on it
    /// from Home. Nothing is transcribed by itself: a cloud model costs money. A journal too short or without speech
    /// to be worth it, one older than Auto-delete keeps, or one History already has goes; a success whose recording
    /// went missing gets it back and keeps its text. One at a time, read off the main thread.
    private func recoverJournals() async {
        guard let journal else { return }
        let days = settings.autoDeleteHistoryDays
        let cutoff = days > 0 ? Date().addingTimeInterval(-Double(days) * 86_400) : nil
        for leftover in await journal.leftovers() {
            let id = leftover.id
            guard !isInUse(id) else { continue }
            let url = leftover.audio
            guard let (samples, speech) = await Task.detached(priority: .utility, operation: {
                RecordingJournal.read(url).map { ($0, SpeechAnalyzer.stats(for: $0)) }
            }).value else {
                Log.app.error("Removed a dictation kept on disk that can't be read: \(id.uuidString, privacy: .public)")
                journal.remove(id)
                continue
            }
            let duration = Double(samples.count) / Recording.sampleRate
            let startedAt = leftover.info?.startedAt ?? leftover.created ?? Date()
            let existing = entry(id: id)
            let isWorthIt = duration >= AudioRecorder.minimumUndoDuration && !speech.isSilent
                && speech.voicedSeconds >= Self.minimumRecoveredVoicedSeconds
            let isKept = existing.map { entry in
                hasRecordingFile(entry) && (entry.status == .success || entry.audioDuration >= duration - 0.5)
            } ?? false
            guard isWorthIt, !isKept, cutoff.map({ startedAt >= $0 }) ?? true else {
                journal.remove(id)
                continue
            }
            let recording = Recording(id: id, samples: samples, startedAt: startedAt, speech: speech,
                                      deviceName: leftover.info?.deviceName)
            let file = saveAudio(recording)
            if var entry = existing, entry.status == .success {
                entry.audioFileName = file
                upsert(entry)
            } else {
                let engine = existing?.engine
                    ?? leftover.info?.engine.flatMap { EngineID(rawValue: $0) ?? TranscriptEntry.retiredEngines[$0] }
                    ?? settings.mainEngine
                let mode = leftover.info?.mode.flatMap(DictationMachine.Mode.init(rawValue:)) ?? .pushToTalk
                upsert(TranscriptEntry(
                    id: id, createdAt: existing?.createdAt ?? startedAt, text: "", engine: engine, status: .failed,
                    audioDuration: duration, voicedSeconds: speech.voicedSeconds,
                    // A failure whose recording didn't make it to disk keeps saying why it failed.
                    errorMessage: existing?.status == .failed ? existing?.errorMessage : Self.interruptedMessage,
                    mode: existing?.mode ?? mode, audioFileName: file))
            }
            Log.app.info("Brought back a dictation the app quit before transcribing (\(duration, format: .fixed(precision: 1), privacy: .public) s)")
            DiagnosticLog.shared.event(.dictation, "dictation.recovered", ["seconds": duration, "had": existing?.status.rawValue])
        }
    }

    /// Speech a journal must hold to come back: what a dictation needs to be transcribed at all.
    private static let minimumRecoveredVoicedSeconds = 0.25

    private func hasRecordingFile(_ entry: TranscriptEntry) -> Bool {
        recordingURLs(for: entry)?.contains { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// The entry's recording read back, either format (`RecordingFile`); nil when it has none or it can't be read.
    /// When the file the entry names can't be read, the same recording in the other format is: the WAV a failed
    /// encode just kept, say, which the entry names only once `finishSaving` has run.
    func loadRecording(for entry: TranscriptEntry) -> Recording? {
        guard let urls = recordingURLs(for: entry) else { return nil }
        // Waits for a pending write of the same file to land first.
        return io.sync { Self.readRecording(at: urls, for: entry) }
    }

    /// `loadRecording`, read on the store's IO queue while the caller waits: an imported file hours long takes
    /// seconds to decode and measure, and the window doesn't stop for it.
    func loadRecordingInBackground(for entry: TranscriptEntry) async -> Recording? {
        guard let urls = recordingURLs(for: entry) else { return nil }
        return await io.value { Self.readRecording(at: urls, for: entry) }
    }

    /// The entry's recording in either format, the one it names first.
    private func recordingURLs(for entry: TranscriptEntry) -> [URL]? {
        guard let name = entry.audioFileName else { return nil }
        return [name, RecordingFile.otherFormat(of: name)].map { paths.recordingURL(fileName: $0) }
    }

    private nonisolated static func readRecording(at urls: [URL], for entry: TranscriptEntry) -> Recording? {
        guard let (url, samples) = urls.lazy.compactMap({ url in
            RecordingFile.read(url).flatMap { $0.isEmpty ? nil : (url, $0) }
        }).first else { return nil }
        var speech = SpeechAnalyzer.stats(for: samples)
        if speech.voicedSeconds == 0 && entry.voicedSeconds > 0 { speech.voicedSeconds = entry.voicedSeconds }
        var recording = Recording(id: entry.id, samples: samples, startedAt: entry.createdAt, speech: speech)
        if RecordingFile.isAAC(url.lastPathComponent) { recording.aacFile = url }
        return recording
    }

    /// Where a recording named `name` is kept (`saveAudio`'s name), whether or not it's written yet.
    func recordingURL(named name: String) -> URL {
        paths.recordingURL(fileName: name)
    }

    func audioURL(for entry: TranscriptEntry) -> URL? {
        guard let name = entry.audioFileName else { return nil }
        let url = paths.recordingURL(fileName: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// What the recordings take on disk, in bytes (read on the store's IO queue, after any pending writes), either
    /// format; a partial file being written doesn't count. 0 for a preview store.
    func recordingsByteCount() async -> Int64 {
        guard persists else { return 0 }
        let dir = paths.recordings
        return await io.value {
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return files.filter { RecordingFile.isRecording($0.lastPathComponent) }.reduce(Int64(0)) { total, url in
                total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
        }
    }

    /// The entries Auto-delete after `days` removes now (none for 0, Never): what General asks about before a
    /// shorter period takes effect.
    func expiredEntries(afterDays days: Int, now: Date = Date()) -> [TranscriptEntry] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return entries.filter { $0.createdAt < cutoff }
    }

    /// Auto-delete: with `autoDeleteHistoryDays` set, entries older than that many days go, their recordings at once
    /// (no Undo brings them back). Then recordings no entry refers to are swept up, but for one whose entry names it
    /// in the other format, missing: that entry names it again (`renameRecordings`).
    func deleteExpired(now: Date = Date()) {
        let expired = expiredEntries(afterDays: settings.autoDeleteHistoryDays, now: now)
        if !expired.isEmpty {
            let ids = Set(expired.map(\.id))
            entries.removeAll { ids.contains($0.id) }
            for file in expired.compactMap(\.audioFileName) {
                pendingFileRemovals.removeValue(forKey: file)?.cancel()
                removeAudioFile(file)
            }
            changed()
            onRemove?(expired.map(\.id))
        }

        guard persists, isLoaded else { return }
        let referenced = Set(entries.compactMap(\.audioFileName))
        let dir = paths.recordings
        io.perform { [weak self] in
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
            let present = Set(files.map(\.lastPathComponent))
            var found: [String: String] = [:]
            for url in files
            where RecordingFile.isRecording(url.lastPathComponent) && !referenced.contains(url.lastPathComponent) {
                // Its entry names it in the other format, which isn't there: the WAV a failed encode kept, the app
                // gone before the entry heard of it. Still that entry's recording.
                let named = RecordingFile.otherFormat(of: url.lastPathComponent)
                if referenced.contains(named) && !present.contains(named) {
                    found[named] = url.lastPathComponent
                    continue
                }
                // Grace period: a file written moments ago may belong to an entry that isn't upserted yet.
                let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                if modified < now.addingTimeInterval(-3600) { try? fm.removeItem(at: url) }
            }
            guard !found.isEmpty else { return }
            Task { @MainActor in self?.renameRecordings(found) }
        }
    }

    /// Entries that name a recording kept in the other format (`deleteExpired`: name → file) name the file, unless a
    /// save of the recording is still on its way.
    private func renameRecordings(_ found: [String: String]) {
        for (named, file) in found {
            guard var entry = entries.first(where: { $0.audioFileName == named }), latestSaves[entry.id] == nil
            else { continue }
            entry.audioFileName = file
            upsert(entry)
        }
    }

    private func removeAudioFileLater(_ name: String) {
        guard persists else { return }
        pendingFileRemovals[name]?.cancel()
        pendingFileRemovals[name] = Task { [weak self, deletedAudioGrace] in
            try? await Task.sleep(for: deletedAudioGrace)
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

    // MARK: - Compressing older recordings

    /// Converts the WAV recordings older builds kept to AAC (`RecordingFile`, about a seventh of the size), newest
    /// first, one at a time, off the main thread at background priority. Each is encoded into a partial file beside
    /// it and read back; only when that is as long as the WAV does it take the recording's name (`<id>.m4a`), then the
    /// entry names it, history.json is written, and only then the WAV goes. A failure leaves the WAV and its entry as
    /// they were, and the next one is tried. A recording a dictation or Home is working on (`isInUse`) is left alone,
    /// until the next launch. An interrupted run is safe to run again: the partial files it left are removed first,
    /// and a WAV no entry names any more is swept up by `deleteExpired`.
    func compressLegacyRecordings() async {
        guard persists, !isCompressing else { return }
        isCompressing = true
        defer { isCompressing = false }
        await loadTask?.value
        guard isLoaded else { return }
        let directory = paths.recordings
        await io.value { RecordingFile.removePartials(in: directory) }
        var tried: Set<UUID> = []
        while !Task.isCancelled, let entry = entries.first(where: { entry in
            !tried.contains(entry.id) && entry.audioFileName.map(RecordingFile.isWAV) == true && !isInUse(entry.id)
        }) {
            tried.insert(entry.id)
            if await compressRecording(of: entry) { compressedRecordings += 1 }
        }
    }

    /// One recording of `compressLegacyRecordings`; true once its entry names the new file.
    private func compressRecording(of entry: TranscriptEntry) async -> Bool {
        guard let name = entry.audioFileName else { return false }
        let id = entry.id
        let wav = paths.recordingURL(fileName: name)
        let aacName = RecordingFile.otherFormat(of: name)
        let aac = paths.recordingURL(fileName: aacName)
        let encode = encodeOverride ?? RecordingFile.aac
        guard let made = await Task.detached(priority: .background, operation: {
            RecordingFile.compressLegacy(wav, encode: encode)
        }).value else { return false }

        // Still the entry's recording and nobody's work: the new file takes its name, on the IO queue after any save
        // of the recording already on its way (a save that comes later writes over it).
        let isUnchanged = { self.entry(id: id)?.audioFileName == name && !self.isInUse(id) }
        guard isUnchanged() else {
            io.perform { try? FileManager.default.removeItem(at: made.partial) }
            return false
        }
        // The WAV changed or went meanwhile (another copy of the app converted it, say): whatever has the new
        // file's name isn't this pass's to remove.
        guard let placed = await io.value({
            RecordingFile.place(made.partial, at: aac, madeFrom: wav, stamp: made.stamp)
        }) else { return false }
        guard isUnchanged(), let index = entries.firstIndex(where: { $0.id == id }) else {
            // Deleted or taken up meanwhile: the WAV stays its recording, and the new file goes, unless something
            // took it up or saved over it since.
            if !entries.contains(where: { $0.audioFileName == aacName }) {
                io.perform { RecordingFile.remove(aac, ifStill: placed) }
            }
            return false
        }
        entries[index].audioFileName = aacName
        changed(save: false)
        // history.json names the new file before the WAV goes: a crash in between loses nothing.
        io.write(entries, to: paths.historyFile)
        removeAudioFile(name)
        return true
    }

    private static func normalized(_ list: [TranscriptEntry]) -> [TranscriptEntry] {
        var seen = Set<UUID>()
        let unique = list.filter { seen.insert($0.id).inserted }
        return Array(unique.sorted { $0.createdAt > $1.createdAt }.prefix(maxEntries))
    }
}

/// Serial file IO for the history: JSON reads/writes and recording files, in submission order.
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

    /// `work`'s result, computed on the queue after everything submitted before it.
    func value<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    func read(_ url: URL) async -> ReadResult {
        await value { Self.readNow(url) }
    }

    /// `work`'s result, computed on the queue after everything submitted before it, waiting for it.
    func sync<T>(_ work: () -> T) -> T {
        queue.sync(execute: work)
    }

    func write(_ entries: [TranscriptEntry], to url: URL) {
        queue.async { Self.writeNow(entries, to: url) }
    }

    func writeSync(_ entries: [TranscriptEntry], to url: URL) {
        queue.sync { Self.writeNow(entries, to: url) }
    }

    /// The entries of a history file; a malformed entry is skipped, a malformed file throws.
    static func decode(_ data: Data) throws -> [TranscriptEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(raw, strategy: Self.dateStyle) { return date }
            if let date = try? Date(raw, strategy: .iso8601) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(raw)"))
        }
        return try decoder.decode(FileFormat.self, from: data).entries.compactMap(\.value)
    }

    private static func readNow(_ url: URL) -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            return .loaded(try decode(Data(contentsOf: url)))
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
