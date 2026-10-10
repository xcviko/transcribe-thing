import Foundation

/// A dictation on disk from the moment it's recorded until History has it, so a crash, a kill (a reinstall
/// mid-dictation) or a power cut doesn't lose it: `<id>.wav`, 16 kHz mono 16-bit PCM whose header leaves the sizes
/// open (`WAVEncoder.decode` reads to the end of the file, whatever was written), and `<id>.json`, whose dictation
/// it is (`Info`). `AudioRecorder` writes it. It goes once History has the recording (`HistoryStore.saveAudio`, after
/// history.json names it) or once the recording is thrown away (`remove`, `discard`). One still there at launch is a
/// dictation an earlier run never finished: `HistoryStore` brings it back as a failed entry.
///
/// All file work runs on one serial queue, never on the audio thread. Every `flushInterval` the audio captured since
/// is copied out of the capture (`CaptureSession.samples(from:keepingBack:)`) and appended, but for the last
/// `holdBack`: a cue's duck (`AudioRecorder.duckRecording`) usually lands on it first. Every `syncInterval` the file
/// goes to the disk itself. A crash or kill loses nothing written (the kernel has it); a power cut, at most the last
/// few seconds.
final class RecordingJournal: @unchecked Sendable {
    /// Whose dictation a journal is: what its History entry says if it comes back.
    struct Info: Codable, Equatable, Sendable {
        var id: UUID
        var startedAt: Date
        /// The `EngineID` raw value of the model the dictation goes to, as far as known.
        var engine: String?
        /// The `DictationMachine.Mode` raw value.
        var mode: String?
        var deviceName: String?
        /// It continues a canceled recording (Undo): that audio comes first in the file.
        var continues: Bool
    }

    /// A journal an earlier run left behind.
    struct Leftover: Sendable {
        var id: UUID
        var audio: URL
        /// nil when its sidecar is missing or unreadable.
        var info: Info?
        /// When the audio file was made: the start time when the sidecar doesn't say.
        var created: Date?
    }

    static let flushInterval: TimeInterval = 1
    static let syncInterval: TimeInterval = 5
    static let holdBack: TimeInterval = 0.5
    static var holdBackSamples: Int { Int(holdBack * Recording.sampleRate) }
    /// The canonical WAV header `WAVEncoder.pcm16` writes.
    static let headerSize = 44

    let directory: URL
    private let queue = DispatchQueue(label: "dev.transcribe-thing.journal", qos: .utility)
    // Queue state.
    private var writers: [UUID: Writer] = [:]
    /// Journals this run began: none of them is a leftover, written to still or not.
    private var begun: Set<UUID> = []

    private final class Writer {
        var info: Info
        let handle: FileHandle
        /// The capture's audio from a sample index on (`CaptureSession.samples(from:keepingBack:)`).
        let source: @Sendable (Int) -> [Float]
        var timer: DispatchSourceTimer?
        /// Samples of the capture written so far, not counting the prefix.
        var written = 0
        var lastSync: TimeInterval

        init(info: Info, handle: FileHandle, source: @escaping @Sendable (Int) -> [Float]) {
            self.info = info
            self.handle = handle
            self.source = source
            self.lastSync = AudioClock.now()
        }
    }

    init(directory: URL) {
        self.directory = directory
    }

    func audioURL(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).wav", isDirectory: false) }
    func infoURL(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false) }

    // MARK: Writing (any thread; the work is queued in order)

    /// Starts the journal of `info.id`: `prefix` (the canceled recording an Undo continues) first, then the capture's
    /// audio as `source` hands it over. A journal of the same id already on disk is written over.
    func begin(_ info: Info, prefix: [Float] = [], source: @escaping @Sendable (_ from: Int) -> [Float]) {
        queue.async { self.beginOnQueue(info, prefix: prefix, source: source) }
    }

    /// Appends what the capture has now (the timer does every `flushInterval`).
    func pump(_ id: UUID) {
        queue.async { self.pumpOnQueue(id) }
    }

    /// Updates the model and mode the journal names, for a dictation switched to another model or to hands-free.
    func label(_ id: UUID, engine: String?, mode: String?) {
        queue.async {
            guard var info = self.writers[id]?.info ?? self.readInfo(self.infoURL(for: id)) else { return }
            guard info.engine != engine || info.mode != mode else { return }
            info.engine = engine
            info.mode = mode
            self.writers[id]?.info = info
            self.writeInfo(info)
        }
    }

    /// The capture is over: `samples` is all of it (without the prefix). What isn't written yet is, the file goes to
    /// the disk and is closed. The journal stays until History has the recording or it's thrown away.
    func end(_ id: UUID, samples: [Float]) {
        queue.async {
            guard let writer = self.writers[id] else { return }
            if samples.count > writer.written { self.append(Array(samples[writer.written...]), to: writer, id: id) }
            self.close(id, sync: true)
        }
    }

    /// The capture itself is thrown away: its journal goes, written to still or not.
    func discard(_ id: UUID) {
        queue.async {
            self.close(id, sync: false)
            self.deleteFiles(of: id)
        }
    }

    /// The recording is in History, or thrown away. A journal still being written is left alone (the same dictation
    /// recorded on after an Undo), and so is one longer than `samples`, when given: the audio History has.
    func remove(_ id: UUID, ifAtMost samples: Int? = nil) {
        queue.async {
            guard self.writers[id] == nil else { return }
            if let samples, let count = Self.sampleCount(of: self.audioURL(for: id)), count > samples { return }
            self.deleteFiles(of: id)
        }
    }

    /// Returns once everything asked before is done.
    func settle() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    // MARK: Reading

    /// The journals an earlier run left: not begun by this one. A sidecar without its audio is removed.
    func leftovers() async -> [Leftover] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.leftoversOnQueue()) }
        }
    }

    /// A journal's samples, as much as was written; nil when it isn't a journal at all.
    static func read(_ url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= headerSize else { return nil }
        return WAVEncoder.decode(data)
    }

    /// The samples a journal holds, from its length.
    static func sampleCount(of url: URL) -> Int? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
            return nil
        }
        return max(0, size.intValue - headerSize) / 2
    }

    // MARK: Private (queue)

    private func beginOnQueue(_ info: Info, prefix: [Float], source: @escaping @Sendable (Int) -> [Float]) {
        close(info.id, sync: false)
        begun.insert(info.id)
        let url = audioURL(for: info.id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            writeInfo(info)
            var data = WAVEncoder.pcm16(prefix)
            // Sizes left open: the file is as long as what was written.
            data.replaceSubrange(4..<8, with: [0xFF, 0xFF, 0xFF, 0xFF])
            data.replaceSubrange(40..<44, with: [0xFF, 0xFF, 0xFF, 0xFF])
            try data.write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            let writer = Writer(info: info, handle: handle, source: source)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval, leeway: .milliseconds(200))
            let id = info.id
            timer.setEventHandler { [weak self] in self?.pumpOnQueue(id) }
            timer.resume()
            writer.timer = timer
            writers[id] = writer
        } catch {
            Log.audio.error("Couldn't start keeping the recording on disk: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func pumpOnQueue(_ id: UUID) {
        guard let writer = writers[id] else { return }
        append(writer.source(writer.written), to: writer, id: id)
    }

    private func append(_ samples: [Float], to writer: Writer, id: UUID) {
        guard !samples.isEmpty else { return }
        do {
            try WAVEncoder.int16(samples).withUnsafeBytes { try writer.handle.write(contentsOf: Data($0)) }
            writer.written += samples.count
            if AudioClock.now() - writer.lastSync >= Self.syncInterval { sync(writer) }
        } catch {
            // A full disk: the journal keeps what it has, the recording itself goes on in memory.
            Log.audio.error("Couldn't keep the recording on disk: \(error.localizedDescription, privacy: .public)")
            close(id, sync: false)
        }
    }

    /// To the disk itself, not only its cache: F_FULLFSYNC survives a power cut, fsync may not.
    private func sync(_ writer: Writer) {
        if fcntl(writer.handle.fileDescriptor, F_FULLFSYNC) == -1 { try? writer.handle.synchronize() }
        writer.lastSync = AudioClock.now()
    }

    private func close(_ id: UUID, sync shouldSync: Bool) {
        guard let writer = writers.removeValue(forKey: id) else { return }
        writer.timer?.cancel()
        if shouldSync { sync(writer) }
        try? writer.handle.close()
    }

    private func deleteFiles(of id: UUID) {
        try? FileManager.default.removeItem(at: audioURL(for: id))
        try? FileManager.default.removeItem(at: infoURL(for: id))
    }

    private func writeInfo(_ info: Info) {
        do {
            try JSONEncoder().encode(info).write(to: infoURL(for: info.id), options: .atomic)
        } catch {
            Log.audio.error("Couldn't note whose recording is kept on disk: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func readInfo(_ url: URL) -> Info? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Info.self, from: $0) }
    }

    private func leftoversOnQueue() -> [Leftover] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let names = Set(files.map(\.lastPathComponent))
        var found: [Leftover] = []
        for url in files {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !begun.contains(id),
                  writers[id] == nil else { continue }
            switch url.pathExtension {
            case "wav":
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                found.append(Leftover(id: id, audio: url, info: readInfo(infoURL(for: id)), created: created))
            case "json" where !names.contains("\(id.uuidString).wav"):
                try? fm.removeItem(at: url)
            default:
                break
            }
        }
        return found.sorted { ($0.info?.startedAt ?? $0.created ?? .distantPast) < ($1.info?.startedAt ?? $1.created ?? .distantPast) }
    }
}
