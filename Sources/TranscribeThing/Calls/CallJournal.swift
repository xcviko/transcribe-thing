import CoreAudio
import Foundation

/// A stretch of one track's audio: 16 kHz mono samples and the `AudioClock` time its first one was captured; nil
/// when it goes straight on from the stretch before.
struct TimedAudio: Equatable, Sendable {
    var samples: [Float]
    var start: TimeInterval?
}

/// Where one track of a call gets its audio: the mic (`MicTrackSource`), or the call app's sound (`ProcessTapSource`).
/// Safe from any thread.
protocol CallTrackSource: AnyObject, Sendable {
    /// Starts capturing. A source that can't capture says why in `problem` and gives no audio.
    func start()
    /// Audio captured since the last drain, oldest first.
    func drain() -> [TimedAudio]
    /// Stops capturing: a drain afterwards hands over the rest.
    func stop()
    /// Why the track has no audio or lost it, once known.
    var problem: String? { get }
    /// The call app's processes changed: a tap of them takes in the new set. Only `ProcessTapSource` cares.
    func retarget(_ processes: [AudioObjectID])
}

extension CallTrackSource {
    func retarget(_ processes: [AudioObjectID]) {}
}

/// Puts one track's stretches on the call's clock, where sample `n` is `origin + n / 16 kHz`: a stretch that starts
/// later than the track has reached is preceded by silence (a tap rebuilt for a new process, a mic that reopened), one
/// that starts earlier loses what overlaps. Within `tolerance` it just follows on, so the two clocks' jitter and the
/// resampler's latency never add a click.
struct TrackAligner: Equatable, Sendable {
    static let tolerance: TimeInterval = 0.05

    /// `AudioClock` time of sample 0.
    let origin: TimeInterval
    /// Samples placed so far.
    private(set) var written = 0

    init(origin: TimeInterval) {
        self.origin = origin
    }

    /// `audio` as it goes into the track, after the silence it needs or without what it repeats.
    mutating func place(_ audio: TimedAudio) -> [Float] {
        var out = audio.samples
        if let start = audio.start {
            let target = Int(((start - origin) * Recording.sampleRate).rounded())
            let gap = target - written
            let slack = Int(Self.tolerance * Recording.sampleRate)
            if gap > slack {
                out = [Float](repeating: 0, count: gap) + out
            } else if gap < -slack {
                out = Array(out.dropFirst(min(out.count, -gap)))
            }
        }
        written += out.count
        return out
    }
}

/// A call on disk from the moment it starts recording until it's in the Calls store (or thrown away), so a crash, a
/// kill or a power cut doesn't lose it. In `Calls in Progress`: `<id>-mic.wav` and `<id>-remote.wav`, 16 kHz mono
/// 16-bit PCM with open sizes like `RecordingJournal`'s, both on one clock (`TrackAligner`), and `<id>.json`, what's
/// known about the call (`Info`), rewritten as that changes (mutes, the answer to "Transcribe your call?").
///
/// All file work runs on one serial queue. Every `RecordingJournal.flushInterval` each track's source is drained and
/// appended; every `syncInterval` the files go to the disk itself. One still here at launch is a call an earlier run
/// never finished: `CallStore.recoverJournals` brings it back.
final class CallJournal: @unchecked Sendable {
    enum Track: String, CaseIterable, Codable, Sendable {
        /// This Mac's mic: the person recording, and whoever is in the room.
        case mic
        /// The call app's sound: the other participants.
        case remote
    }

    /// Whether the person has said to keep the call.
    enum Consent: String, Codable, Sendable {
        /// Recording while the call isn't confirmed yet: nothing asked. Left behind, it's deleted.
        case suspected
        /// Asked "Transcribe your call?", no answer yet. Left behind, it waits for the answer (`.unconfirmed`).
        case asking
        /// Yes, the automatic setting, or a manual recording. Left behind, it's `.interrupted`.
        case kept
    }

    struct Info: Codable, Equatable, Sendable {
        var id: UUID
        var startedAt: Date
        var appName: String
        var bundleID: String?
        var service: CallService?
        var pageTitle: String?
        var manual: Bool = false
        var consent: Consent
        var mutes: [CallInterval] = []
        var muteKnown: Bool = false
        var otherBrowserAudio: [CallInterval] = []
        var micProblem: String?
        var remoteProblem: String?

        init(id: UUID = UUID(), startedAt: Date, appName: String, bundleID: String? = nil, service: CallService? = nil,
             pageTitle: String? = nil, manual: Bool = false, consent: Consent) {
            self.id = id
            self.startedAt = startedAt
            self.appName = appName
            self.bundleID = bundleID
            self.service = service
            self.pageTitle = pageTitle
            self.manual = manual
            self.consent = consent
        }

        /// The record this call becomes, its audio not yet in the store.
        func record(status: CallStatus) -> CallRecord {
            var record = CallRecord(id: id, startedAt: startedAt, appName: appName, bundleID: bundleID,
                                    service: service, pageTitle: pageTitle, manual: manual, status: status)
            record.muteIntervals = mutes
            record.muteKnown = muteKnown
            record.otherBrowserAudio = otherBrowserAudio
            record.micProblem = micProblem
            record.remoteProblem = remoteProblem
            return record
        }
    }

    /// A call an earlier run left behind.
    struct Leftover: Sendable {
        var id: UUID
        /// nil when its sidecar is missing or unreadable.
        var info: Info?
        /// The tracks that have a file.
        var audio: [Track: URL]
        /// When the first file was made: the start time when the sidecar doesn't say.
        var created: Date?
    }

    let directory: URL
    private let queue = DispatchQueue(label: "dev.transcribe-thing.calls.journal", qos: .utility)
    // Queue state.
    private var writers: [UUID: Writer] = [:]
    /// Journals this run began: none of them is a leftover.
    private var begun: Set<UUID> = []

    private final class Writer {
        var info: Info
        var tracks: [Track: TrackWriter] = [:]
        var timer: DispatchSourceTimer?
        var lastSync: TimeInterval

        init(info: Info) {
            self.info = info
            lastSync = AudioClock.now()
        }
    }

    private final class TrackWriter {
        let source: any CallTrackSource
        let handle: FileHandle?
        var aligner: TrackAligner

        init(source: any CallTrackSource, handle: FileHandle?, origin: TimeInterval) {
            self.source = source
            self.handle = handle
            aligner = TrackAligner(origin: origin)
        }
    }

    init(directory: URL) {
        self.directory = directory
    }

    func audioURL(for id: UUID, track: Track) -> URL {
        directory.appendingPathComponent("\(id.uuidString)-\(track.rawValue).wav", isDirectory: false)
    }

    func infoURL(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false) }

    // MARK: Writing (any thread; the work is queued in order)

    /// Starts the journal of `info.id`: each source is started and its audio written from `origin`, the `AudioClock`
    /// time of the call's sample 0.
    func begin(_ info: Info, origin: TimeInterval, sources: [Track: any CallTrackSource]) {
        for source in sources.values { source.start() }
        queue.async { self.beginOnQueue(info, origin: origin, sources: sources) }
    }

    /// Changes what the sidecar says (mutes, the answer, a track's problem); written at once.
    func update(_ id: UUID, _ change: @escaping @Sendable (inout Info) -> Void) {
        queue.async {
            guard let writer = self.writers[id] else { return }
            var info = writer.info
            change(&info)
            guard info != writer.info else { return }
            writer.info = info
            self.writeInfo(info)
        }
    }

    /// The call is over: the sources stop, what they still hold is written, the files go to the disk and close. Returns
    /// what the sidecar said last, with each source's problem; nil for a journal that isn't being written. The journal
    /// stays until the store has the call (`remove`).
    func end(_ id: UUID) async -> Info? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.endOnQueue(id)) }
        }
    }

    /// The call is thrown away: its sources stop and its files go.
    func discard(_ id: UUID) {
        queue.async {
            if let writer = self.writers[id] {
                for track in writer.tracks.values { track.source.stop() }
            }
            self.close(id, sync: false)
            self.deleteFiles(of: id)
        }
    }

    /// The store has the call (or it's thrown away): its files go. A journal still being written is left alone.
    func remove(_ id: UUID) {
        queue.async {
            guard self.writers[id] == nil else { return }
            self.deleteFiles(of: id)
        }
    }

    /// Returns once everything asked before is done.
    func settle() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    // MARK: Reading

    /// The calls an earlier run left: not begun by this one. A sidecar with no audio beside it is removed.
    func leftovers() async -> [Leftover] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.leftoversOnQueue()) }
        }
    }

    /// The id and track a journal file is for: "<uuid>-mic.wav".
    static func parse(fileName: String) -> (id: UUID, track: Track)? {
        guard fileName.hasSuffix(".wav") else { return nil }
        let stem = fileName.dropLast(4)
        guard let dash = stem.lastIndex(of: "-"), let track = Track(rawValue: String(stem[stem.index(after: dash)...])),
              let id = UUID(uuidString: String(stem[..<dash])) else { return nil }
        return (id, track)
    }

    // MARK: Private (queue)

    private func beginOnQueue(_ info: Info, origin: TimeInterval, sources: [Track: any CallTrackSource]) {
        close(info.id, sync: false)
        begun.insert(info.id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.audio.error("Couldn't start keeping the call on disk: \(error.localizedDescription, privacy: .public)")
        }
        let writer = Writer(info: info)
        writeInfo(info)
        for (track, source) in sources {
            let url = audioURL(for: info.id, track: track)
            var handle: FileHandle?
            do {
                try RecordingJournal.openHeader().write(to: url)
                handle = try FileHandle(forWritingTo: url)
                try handle?.seekToEnd()
            } catch {
                Log.audio.error("Couldn't keep the call's \(track.rawValue, privacy: .public) on disk: \(error.localizedDescription, privacy: .public)")
                handle = nil
            }
            writer.tracks[track] = TrackWriter(source: source, handle: handle, origin: origin)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = RecordingJournal.flushInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
        let id = info.id
        timer.setEventHandler { [weak self] in self?.pumpOnQueue(id) }
        timer.resume()
        writer.timer = timer
        writers[id] = writer
    }

    private func pumpOnQueue(_ id: UUID) {
        guard let writer = writers[id] else { return }
        for track in Track.allCases {
            guard let trackWriter = writer.tracks[track] else { continue }
            let audio = trackWriter.source.drain()
            for stretch in audio { append(trackWriter.aligner.place(stretch), to: trackWriter, track: track) }
            notice(trackWriter.source.problem, of: track, in: writer)
        }
        if AudioClock.now() - writer.lastSync >= RecordingJournal.syncInterval { sync(writer) }
    }

    /// A source's problem goes into the sidecar the first time it's seen (or changes).
    private func notice(_ problem: String?, of track: Track, in writer: Writer) {
        var info = writer.info
        switch track {
        case .mic: info.micProblem = problem ?? info.micProblem
        case .remote: info.remoteProblem = problem ?? info.remoteProblem
        }
        guard info != writer.info else { return }
        writer.info = info
        writeInfo(info)
    }

    private func endOnQueue(_ id: UUID) -> Info? {
        guard let writer = writers[id] else { return nil }
        writer.timer?.cancel()
        for track in writer.tracks.values { track.source.stop() }
        pumpOnQueue(id)
        let info = writer.info
        close(id, sync: true)
        return info
    }

    private func append(_ samples: [Float], to writer: TrackWriter, track: Track) {
        guard !samples.isEmpty, let handle = writer.handle else { return }
        do {
            try WAVEncoder.int16(samples).withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
        } catch {
            // A full disk: the journal keeps what it has.
            Log.audio.error("Couldn't keep the call's \(track.rawValue, privacy: .public) on disk: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// To the disk itself, not only its cache: F_FULLFSYNC survives a power cut, fsync may not.
    private func sync(_ writer: Writer) {
        for track in writer.tracks.values {
            guard let handle = track.handle else { continue }
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 { try? handle.synchronize() }
        }
        writer.lastSync = AudioClock.now()
    }

    private func close(_ id: UUID, sync shouldSync: Bool) {
        guard let writer = writers.removeValue(forKey: id) else { return }
        writer.timer?.cancel()
        if shouldSync { sync(writer) }
        for track in writer.tracks.values { try? track.handle?.close() }
    }

    private func deleteFiles(of id: UUID) {
        for track in Track.allCases { try? FileManager.default.removeItem(at: audioURL(for: id, track: track)) }
        try? FileManager.default.removeItem(at: infoURL(for: id))
    }

    private func writeInfo(_ info: Info) {
        do {
            try JSONEncoder().encode(info).write(to: infoURL(for: info.id), options: .atomic)
        } catch {
            Log.audio.error("Couldn't note whose call is kept on disk: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func readInfo(_ url: URL) -> Info? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Info.self, from: $0) }
    }

    private func leftoversOnQueue() -> [Leftover] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        var audio: [UUID: [Track: URL]] = [:]
        var created: [UUID: Date] = [:]
        for url in files {
            guard let (id, track) = Self.parse(fileName: url.lastPathComponent), !begun.contains(id),
                  writers[id] == nil else { continue }
            audio[id, default: [:]][track] = url
            if let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate {
                created[id] = min(created[id] ?? date, date)
            }
        }
        for url in files where url.pathExtension == "json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !begun.contains(id),
                  writers[id] == nil, audio[id] == nil else { continue }
            try? fm.removeItem(at: url)
        }
        return audio.map { id, tracks in
            Leftover(id: id, info: readInfo(infoURL(for: id)), audio: tracks, created: created[id])
        }.sorted { ($0.info?.startedAt ?? $0.created ?? .distantPast) < ($1.info?.startedAt ?? $1.created ?? .distantPast) }
    }
}
