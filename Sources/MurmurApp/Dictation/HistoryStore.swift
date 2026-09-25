import Foundation
import Observation

// STUB (FOUNDATION): SHELL replaces persistence; the in-memory behavior here is enough for previews.
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

    init(id: UUID = UUID(), createdAt: Date = Date(), text: String, engine: EngineID,
         status: TranscriptStatus = .success, audioDuration: TimeInterval, voicedSeconds: TimeInterval,
         processingTime: TimeInterval? = nil, costUSD: Double? = nil, errorMessage: String? = nil,
         audioFileName: String? = nil) {
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
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
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
}

@MainActor @Observable
final class HistoryStore {
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let settings: AppSettings

    /// Newest first.
    private(set) var entries: [TranscriptEntry] = []

    init(paths: AppPaths, settings: AppSettings) {
        self.paths = paths
        self.settings = settings
    }

    static func preview(entries: [TranscriptEntry]) -> HistoryStore {
        let store = HistoryStore(paths: .temporary(), settings: .inMemory())
        store.entries = entries.sorted { $0.createdAt > $1.createdAt }
        return store
    }

    var stats: HistoryStats {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let successes = entries.filter { $0.status == .success }
        var daily = Array(repeating: 0, count: 7)
        for entry in successes {
            let day = calendar.startOfDay(for: entry.createdAt)
            guard let ago = calendar.dateComponents([.day], from: day, to: today).day, (0..<7).contains(ago) else { continue }
            daily[6 - ago] += entry.wordCount
        }
        let words = successes.reduce(0) { $0 + $1.wordCount }
        let speaking = successes.reduce(0) { $0 + $1.audioDuration }
        let voiced = successes.reduce(0) { $0 + $1.voicedSeconds }
        let wpm = voiced > 1 ? Int((Double(words) / (voiced / 60)).rounded()) : nil
        return HistoryStats(wordsThisWeek: daily.reduce(0, +), dailyWords: daily, averageWPM: wpm,
                            timeSavedSeconds: max(0, Double(words) / 40 * 60 - speaking),
                            totalDictations: successes.count)
    }

    var lastSuccessfulText: String? {
        entries.first { $0.status == .success && !$0.text.isEmpty }?.text
    }

    func load() {}

    func upsert(_ entry: TranscriptEntry) {
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[i] = entry
        } else {
            entries.insert(entry, at: 0)
        }
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    func clearAll() {
        entries.removeAll()
    }

    /// Writes a WAV to `paths.recordings`; returns the file name.
    func saveAudio(_ recording: Recording) -> String? { nil }

    func loadRecording(for entry: TranscriptEntry) -> Recording? { nil }

    func pruneOldRecordings() {}
}
