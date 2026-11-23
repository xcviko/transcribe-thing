import Foundation
import Observation

/// The recorded calls: calls.json, and a folder per call under Calls/ with its tracks (`mic.m4a`, `remote.m4a`, and
/// `mic-raw.m4a`, the mic before it was cleaned of noise and the other side's voices: 16 kHz, what transcription and
/// the waveform work on) and its tracks for listening (`mic-48k.m4a`, `remote-48k.m4a`: `CallListening`, what the
/// player plays). Apart from History: calls are neither dictations nor counted in Home's stats. A call and its folder
/// go together: deleted, or auto-deleted after History's Auto-delete period (`AppSettings.autoDeleteHistoryDays`).
///
/// A call comes here from its journal (`CallJournal`) once it ends (`adopt`); one an earlier run left in the journal
/// comes back at launch (`recoverJournals`): kept ones as `.interrupted`, unanswered ones as `.unconfirmed`, ones
/// never confirmed as calls are deleted. A kept call that starts in the same app within `continuationWindow` of where
/// an interrupted one stopped (the app was quit or reinstalled mid-call) is that call going on: once it ends, it's
/// joined onto the interrupted record (`interruptedCall(continuedBy:)`), its tracks after a silence as long as the
/// gap, so there's one call, not two halves.
@MainActor @Observable
final class CallStore {
    /// What an interrupted call says in place of an error.
    nonisolated static let interruptedMessage = "The app quit while it recorded this call"
    /// What a call the app quit transcribing says.
    nonisolated static let quitTranscribingMessage = "The app quit while it transcribed this call"
    /// What a remote track of digital silence says: what a tap gives without the permission.
    nonisolated static let silentTapMessage = "No sound came from the call app. Allow transcribe-thing in System Settings → "
        + "Privacy & Security → Screen & System Audio Recording, under System Audio Recording Only."

    /// Newest first.
    private(set) var calls: [CallRecord] = []
    /// True once calls.json has been read (or there was none).
    private(set) var isLoaded = false
    /// Calls whose summary is being written on its own (`CallTranscriber.summarize`): never saved, a summary the app
    /// quit writing is simply not there.
    var summarizing: Set<UUID> = []
    /// Calls whose speakers are being named from their video (`CallTranscriber.nameFromVideo`): never saved, a step
    /// the app quit during simply didn't happen.
    var namingSpeakers: Set<UUID> = []
    /// How a names step that renamed no one ended, for the call page: "Couldn’t tell who’s who from the video." Never
    /// saved; dropped by the next rename, Transcribe Again or another step.
    var namingResult: [UUID: NamingResult] = [:]

    struct NamingResult: Equatable, Sendable {
        /// One line for the transcript's header.
        var message: String
        /// More on hover: why it failed.
        var detail: String?
    }

    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let settings: AppSettings
    /// Preview stores never touch the disk.
    @ObservationIgnored private let persists: Bool
    /// Where calls are kept while they're recorded; nil for a preview store.
    @ObservationIgnored let journal: CallJournal?
    @ObservationIgnored private let io = DispatchQueue(label: "dev.transcribe-thing.calls.store", qos: .utility)
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    /// Calls just removed, by id: deleted or auto-deleted.
    @ObservationIgnored var onRemove: (([UUID]) -> Void)?
    /// Where events go; a test's own log in tests.
    @ObservationIgnored var log: DiagnosticLog = .shared

    /// How soon after an interrupted call stopped a new call of the same app still continues it: a relaunch, a
    /// reinstall.
    nonisolated static let continuationWindow: TimeInterval = 120

    init(paths: AppPaths, settings: AppSettings) {
        self.paths = paths
        self.settings = settings
        persists = true
        journal = CallJournal(directory: paths.callJournals)
    }

    private init(previewCalls: [CallRecord], settings: AppSettings) {
        paths = .temporary()
        self.settings = settings
        persists = false
        journal = nil
        calls = previewCalls.sorted { $0.startedAt > $1.startedAt }
        isLoaded = true
    }

    static func preview(calls: [CallRecord], settings: AppSettings? = nil) -> CallStore {
        CallStore(previewCalls: calls, settings: settings ?? .inMemory())
    }

    func call(id: UUID) -> CallRecord? {
        calls.first { $0.id == id }
    }

    /// The call's folder: Calls/<id>.
    func folder(for id: UUID) -> URL {
        paths.calls.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Calls/<id>/answers: each transcription request's answer as it came (`CallTranscriber`), "1-mix.txt", then
    /// "1-mix-rest-1.txt" and on for what the chunk's answer left out (a call transcribed before the tracks were mixed
    /// has "1-remote.txt" and "1-mic.txt").
    func answersFolder(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent("answers", isDirectory: true)
    }

    /// A track's .m4a, when the call has one.
    func audioURL(of call: CallRecord, track: CallJournal.Track) -> URL? {
        let name = track == .mic ? call.micFile : call.remoteFile
        return name.map { folder(for: call.id).appendingPathComponent($0, isDirectory: false) }
    }

    /// What the player plays: the tracks kept for listening (`CallListening`: 48 kHz, at one loudness) when the call
    /// has them and they're all there, else its 16 kHz tracks.
    func playbackURLs(of call: CallRecord) -> [URL] {
        let folder = folder(for: call.id)
        let listening = [call.listeningMicFile, call.listeningRemoteFile].compactMap { $0 }
            .map { folder.appendingPathComponent($0, isDirectory: false) }
        if !listening.isEmpty, listening.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
            return listening
        }
        return [CallJournal.Track.mic, .remote].compactMap { audioURL(of: call, track: $0) }
    }

    // MARK: Loading and saving

    /// The calls in a calls.json, read leniently (a call this build can't read is skipped), and only read: for
    /// `--calls-status`.
    nonisolated static func readRecords(from data: Data) throws -> [CallRecord] {
        try decoder().decode(FileFormat.self, from: data).calls.compactMap(\.value)
    }

    /// Reads calls.json, settles what an earlier run left mid-way (a call being transcribed fails, so Retry works),
    /// auto-deletes, then brings back the calls left in the journal.
    func load() {
        guard persists, !isLoaded else { return }
        if let data = try? Data(contentsOf: paths.callsFile) {
            do {
                calls = try Self.readRecords(from: data).sorted { $0.startedAt > $1.startedAt }
            } catch {
                let aside = paths.root.appendingPathComponent("calls-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: paths.callsFile, to: aside)
                Log.app.error("Calls file unreadable, kept a copy aside: \(error.localizedDescription, privacy: .public)")
            }
        }
        var changed = false
        for index in calls.indices where calls[index].status == .transcribing {
            calls[index].status = .failed
            calls[index].error = Self.quitTranscribingMessage
            changed = true
        }
        isLoaded = true
        if changed { save() }
        deleteExpired()
        recoveryTask = Task { [weak self] in await self?.recoverJournals() }
    }

    /// Returns once the launch's `recoverJournals` is done: tests.
    func waitForRecovery() async {
        await recoveryTask?.value
    }

    /// Writes calls.json now, and returns once it's on disk.
    func flush() async {
        guard persists else { return }
        saveTask?.cancel()
        saveTask = nil
        let calls = calls, url = paths.callsFile
        await withCheckedContinuation { continuation in
            io.async {
                Self.write(calls, to: url)
                continuation.resume()
            }
        }
    }

    // MARK: Changes

    func upsert(_ call: CallRecord) {
        if let index = calls.firstIndex(where: { $0.id == call.id }) {
            calls[index] = call
        } else {
            calls.append(call)
            calls.sort { $0.startedAt > $1.startedAt }
        }
        save()
    }

    /// Changes one call in place; nothing when it's gone.
    func update(_ id: UUID, _ change: (inout CallRecord) -> Void) {
        guard let index = calls.firstIndex(where: { $0.id == id }) else { return }
        var call = calls[index]
        change(&call)
        guard call != calls[index] else { return }
        calls[index] = call
        save()
    }

    /// Deletes the call and its audio.
    func delete(_ id: UUID) {
        guard calls.contains(where: { $0.id == id }) else { return }
        calls.removeAll { $0.id == id }
        removeFolder(of: id)
        save()
        onRemove?([id])
    }

    /// Shows `speaker` as `name` from now on; an empty name, or the model's own, undoes it. The name is the
    /// person's from then on, even over one the video gave.
    func rename(speaker: String, to name: String, in id: UUID) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        namingResult[id] = nil
        update(id) { call in
            call.speakerNames[speaker] = name.isEmpty || name == speaker ? nil : name
            call.videoNamedSpeakers.remove(speaker)
        }
    }

    /// The names step's renames (`CallTranscriber.nameFromVideo`), speaker → name, noted as the video's.
    func nameFromVideo(_ names: [String: String], in id: UUID) {
        guard !names.isEmpty else { return }
        update(id) { call in
            for (speaker, name) in names {
                call.speakerNames[speaker] = name
                call.videoNamedSpeakers.insert(speaker)
            }
        }
    }

    /// Drops the names the video gave (a new transcript's speakers may be other people); the person's stay.
    func clearVideoNames(in id: UUID) {
        guard let call = call(id: id), !call.videoNamedSpeakers.isEmpty else { return }
        update(id) { call in
            for speaker in call.videoNamedSpeakers { call.speakerNames[speaker] = nil }
            call.videoNamedSpeakers = []
        }
    }

    /// Ticks a task of the call's summary off, or back on; saved at once.
    func setTask(_ taskID: UUID, done: Bool, in id: UUID) {
        update(id) { call in
            guard let index = call.summary?.tasks.firstIndex(where: { $0.id == taskID }) else { return }
            call.summary?.tasks[index].done = done
        }
    }

    /// Auto-delete, as History's: with `autoDeleteHistoryDays` set, calls older than that go with their audio. A call
    /// made from a file counts from when it came in (`CallRecord.keptSince`).
    func deleteExpired(now: Date = Date()) {
        let days = settings.autoDeleteHistoryDays
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let expired = calls.filter { $0.keptSince < cutoff && $0.status != .recording }.map(\.id)
        guard !expired.isEmpty else { return }
        let ids = Set(expired)
        calls.removeAll { ids.contains($0.id) }
        for id in expired { removeFolder(of: id) }
        save()
        onRemove?(expired)
    }

    // MARK: From a file

    /// The one track of a call made from a file.
    nonisolated static let importedAudioFile = "audio.m4a"

    /// Audio or video read from a file (`ImportedAudio`) as a call of its own, with `status`: its sound encoded into
    /// the call's folder off the main thread, as a recorded call's tracks are, so the player works the same. It's one
    /// track, both sides mixed, kept as the other side's (`remoteFile`): nothing in it is known to be the person's
    /// mic, so no sample of their voice is made from it. A video isn't copied, only its sound: its path is kept
    /// (`CallFileSource`). The call starts at the file's creation date (`now` without one), and is saved before this
    /// returns. nil, with nothing kept, when the sound couldn't be written.
    func addImported(_ audio: ImportedAudio, status: CallStatus = .transcribing,
                     now: Date = Date()) async -> CallRecord? {
        let id = UUID()
        let started = audio.url.flatMap(Self.creationDate(of:)) ?? now
        var record = CallRecord(id: id, startedAt: started, appName: audio.fileName, status: status)
        record.file = CallFileSource(name: audio.fileName, path: audio.url?.standardizedFileURL.path ?? "",
                                     isVideo: audio.isVideo, importedAt: now)
        record.remoteFile = Self.importedAudioFile
        record.remoteSeconds = audio.duration
        if persists {
            let file = folder(for: id).appendingPathComponent(Self.importedAudioFile, isDirectory: false)
            let samples = audio.samples
            let encoded = await Task.detached(priority: .userInitiated) { () -> CallAudio.Encoded? in
                do {
                    return try Self.writeStaged(samples, to: file)
                } catch {
                    Log.audio.error("Couldn't keep a file's sound as a call: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }.value
            guard let encoded else {
                removeFolder(of: id)
                return nil
            }
            record.remoteSeconds = encoded.seconds
        }
        record.endedAt = started.addingTimeInterval(record.duration)
        upsert(record)
        await flush()
        log.event(.calls, "call.imported", [
            "call": CallTranscriber.shortID(id), "seconds": (record.duration * 10).rounded() / 10,
            "video": audio.isVideo,
        ])
        return record
    }

    /// A file's sound encoded in a temporary folder on the same disk, then moved into the call's folder: an app quit
    /// halfway through leaves nothing in Calls/ that no record points to (macOS clears the temporary folder itself).
    nonisolated static func writeStaged(_ samples: [Float], to m4a: URL) throws -> CallAudio.Encoded {
        let files = FileManager.default
        let folder = m4a.deletingLastPathComponent()
        try files.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: folder.deletingLastPathComponent(), create: true)
        defer { try? files.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(m4a.lastPathComponent, isDirectory: false)
        let encoded = try CallAudio.write(samples, to: staged)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try? files.removeItem(at: m4a)
        try files.moveItem(at: staged, to: m4a)
        return encoded
    }

    /// When the file was made: when a recording of it started, for a call recorded by another app.
    nonisolated static func creationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    // MARK: From the journal

    /// The mic as recorded, kept next to the cleaned `mic.m4a` (`KeptTracks.echo`): nothing plays or transcribes it,
    /// it goes with the call.
    nonisolated static let rawMicFile = "mic-raw.m4a"

    /// A call whose journal is closed becomes a record with `status`: each track encoded into the call's folder off
    /// the main thread, the mic silent in the call's mutes (the journal already zeroed what it could; a mute noted
    /// too late for it, or one still going on when the app quit, is zeroed here) and cleaned of the other side's
    /// voices (`keepTracks`), then the record saved, and only then the journal removed. Returns the record. Its
    /// listening tracks are made after, from the journal's (`keepForListening`): its transcription doesn't wait.
    @discardableResult
    func adopt(_ info: CallJournal.Info, status: CallStatus, endedAt: Date? = nil) async -> CallRecord {
        var listeningJob: ListeningJob?
        if status == .transcribing || status == .interrupted,
           let earlier = interruptedCall(continuedBy: info.bundleID, service: info.service, pageTitle: info.pageTitle,
                                         manual: info.manual, startedAt: info.startedAt, besides: info.id),
           let joined = await join(info, onto: earlier, status: status, endedAt: endedAt) {
            return joined
        }
        var record = info.record(status: status)
        if let existing = call(id: info.id) {
            record.speakerNames = existing.speakerNames
            record.videoNamedSpeakers = existing.videoNamedSpeakers
        }
        if let journal {
            let id = info.id
            let folder = folder(for: id)
            let wavs = Dictionary(uniqueKeysWithValues: CallJournal.Track.allCases.map {
                ($0, journal.audioURL(for: id, track: $0))
            })
            let silencing = Self.silencing(info)
            let limit = info.endsAt.map { Int(($0 * Recording.sampleRate).rounded(.up)) }
            let kept = await Task.detached(priority: .utility) {
                Self.keepTracks(earlier: [:], then: wavs, at: 0, limit: limit, silencing: silencing, in: folder)
            }.value
            let encoded = kept.encoded
            logEcho(kept, call: id)
            let listening = (mic: journal.listeningURL(for: id, track: .mic),
                             remote: journal.listeningURL(for: id, track: .remote))
            // A journal from before the listening tracks, or one whose sources gave none, has nothing to make them of.
            if [listening.mic, listening.remote].contains(where: { (RecordingJournal.sampleCount(of: $0) ?? 0) > 0 }) {
                listeningJob = ListeningJob(mic: listening.mic, remote: listening.remote, limit: info.endsAt,
                                            silencing: silencing, cancelEcho: kept.echo?.tookEchoOut ?? false,
                                            folder: folder)
            }
            if let mic = encoded[.mic] {
                record.micFile = "mic.m4a"
                record.micSeconds = mic.seconds
                record.echoCancelled = kept.echo?.tookEchoOut ?? false
                record.echoReductionDB = kept.echoReductionDB
            }
            if let remote = encoded[.remote] {
                record.remoteFile = "remote.m4a"
                record.remoteSeconds = remote.seconds
                if remote.peak == 0, remote.seconds >= 10, record.remoteProblem == nil,
                   SystemAudioPermission.current() != .authorized {
                    record.remoteProblem = Self.silentTapMessage
                }
            }
            record.micSilencedWhenMuted = true
        }
        // A mute still going on when the recording stopped lasts to its end.
        if let since = info.mutedSince {
            record.muteIntervals = CallInterval.union(record.muteIntervals
                                                      + [CallInterval(start: since, end: max(since, record.duration))])
        }
        record.endedAt = endedAt ?? record.startedAt.addingTimeInterval(record.duration)
        upsert(record)
        await flush()
        if let listeningJob {
            // The 16 kHz files go now; the listening ones once their tracks are made, after this returns.
            journal?.remove(info.id, keepingListening: true)
            keepForListening(record, listeningJob)
        } else {
            journal?.remove(info.id)
        }
        return record
    }

    /// What making a call's listening tracks needs (`CallListening.make`).
    struct ListeningJob: Sendable {
        var mic: URL, remote: URL
        var limit: TimeInterval?
        var silencing: [CallInterval]
        var cancelEcho: Bool
        var folder: URL
    }

    /// Listening tracks being made, by call.
    @ObservationIgnored private var listeningTasks: [UUID: Task<Void, Never>] = [:]

    /// Makes `record`'s listening tracks in the background (`CallListening`), so its transcription doesn't wait for
    /// them (about 1.5 minutes an hour on speakers, 25 seconds on headphones), then notes them on the call, which plays
    /// them from then on, and lets the journal's listening files go. A call deleted meanwhile, or joined with its
    /// continuation (its tracks no longer what they were made from), keeps none. One whose app quit before they were
    /// made plays its 16 kHz tracks: the journal's listening files, alone, go at the next launch.
    private func keepForListening(_ record: CallRecord, _ job: ListeningJob) {
        let id = record.id
        let expected = (mic: record.micSeconds, remote: record.remoteSeconds)
        listeningTasks[id] = Task { [weak self] in
            let made = await Task.detached(priority: .utility) {
                CallListening.make(mic: job.mic, remote: job.remote, limit: job.limit, silencing: job.silencing,
                                   cancelEcho: job.cancelEcho, in: job.folder)
            }.value
            guard let self else { return }
            self.listeningTasks[id] = nil
            self.logListening(made, call: id)
            defer { self.journal?.removeListening(id) }
            let files = [made.mic?.file, made.remote?.file].compactMap { $0 }
            guard var call = self.call(id: id) else {
                // Deleted meanwhile: what was made would only bring its folder back.
                self.removeFolder(of: id)
                return
            }
            // Both of the tracks the call has, or neither: the player keeps to the 16 kHz pair then.
            guard call.micSeconds == expected.mic, call.remoteSeconds == expected.remote,
                  (call.micFile == nil) == (made.mic == nil), (call.remoteFile == nil) == (made.remote == nil),
                  !files.isEmpty else {
                for name in files { try? FileManager.default.removeItem(at: job.folder.appendingPathComponent(name)) }
                return
            }
            call.listeningMicFile = made.mic?.file
            call.listeningRemoteFile = made.remote?.file
            self.upsert(call)
            await self.flush()
        }
    }

    /// Waits until `id`'s listening tracks are made, or for every call's when nil.
    func listeningSettled(_ id: UUID? = nil) async {
        let tasks = id.map { listeningTasks[$0].map { [$0] } ?? [] } ?? Array(listeningTasks.values)
        for task in tasks { await task.value }
    }

    /// What `keepTracks` wrote.
    struct KeptTracks: Sendable {
        var encoded: [CallJournal.Track: CallAudio.Encoded] = [:]
        /// The mic was cleaned (its noise, and the other side's voices where it heard them; the mic as recorded kept as
        /// "mic-raw"): what that did.
        var echo: CallAudio.EchoCancelled?
        /// Why it wasn't, for the log: "noRemote", "silentRemote", "failed"; nil when it was, or the mic had nothing
        /// new.
        var echoSkipped: String?
        /// A track with audio couldn't be written.
        var failed = false

        /// `EchoStats.echoReductionDB` to a tenth of a dB; nil when there was no echo to take out.
        var echoReductionDB: Double? {
            guard let echo, echo.tookEchoOut else { return nil }
            return echo.stats.echoReductionDB.map { ($0 * 10).rounded() / 10 }
        }
    }

    /// Each track of a call as .m4a files in `folder`, named "<track><suffix>.m4a": the earlier part's file
    /// (`earlier`, up to `offset`), then the journal's WAV (`wavs`), nothing past `limit`; a track whose WAV has
    /// nothing is left alone. The remote goes first: when it has any sound, the mic is cleaned against it
    /// (`CallAudio.cancelEcho`: its noise, and the echo where there is some), and the mic as recorded kept as
    /// "mic-raw<suffix>.m4a"; otherwise (headphones, no tap) the mic is kept as it is. Either way it's silent in
    /// `silencing`. A mic that can't be cleaned is kept as it is too. Blocking file work: off the main thread.
    nonisolated static func keepTracks(earlier: [CallJournal.Track: URL], then wavs: [CallJournal.Track: URL],
                                       at offset: Int, limit: Int?, silencing: [CallInterval], in folder: URL,
                                       suffix: String = "") -> KeptTracks {
        let fm = FileManager.default
        func file(_ name: String) -> URL { folder.appendingPathComponent("\(name)\(suffix).m4a", isDirectory: false) }
        func hasAudio(_ track: CallJournal.Track) -> Bool {
            wavs[track].map { (RecordingJournal.sampleCount(of: $0) ?? 0) > 0 } ?? false
        }
        var kept = KeptTracks()
        if hasAudio(.remote), let wav = wavs[.remote] {
            do {
                kept.encoded[.remote] = try CallAudio.join(earlier[.remote], then: wav, at: offset,
                                                           to: file(CallJournal.Track.remote.rawValue), limit: limit)
            } catch {
                kept.failed = true
                Log.audio.error("Couldn't keep the call's remote: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard hasAudio(.mic), let micWAV = wavs[.mic] else { return kept }
        let remoteWAV = hasAudio(.remote) ? wavs[.remote] : nil
        let remoteHasSound: Bool
        if let remote = kept.encoded[.remote] {
            remoteHasSound = remote.peak > 0
        } else if remoteWAV == nil, let old = earlier[.remote] {
            let stream = try? TrackStream(earlier: old, then: nil, at: offset, limit: limit)
            remoteHasSound = (stream.flatMap { try? CallAudio.peak(of: $0) } ?? 0) > 0
        } else {
            remoteHasSound = false
        }
        let micFile = file(CallJournal.Track.mic.rawValue)
        let rawFile = file("mic-raw")
        if remoteHasSound {
            do {
                let mic = try TrackStream(earlier: earlier[.mic], then: micWAV, at: offset, limit: limit)
                let reference = try TrackStream(earlier: earlier[.remote], then: remoteWAV, at: offset, limit: limit)
                let echo = try CallAudio.cancelEcho(mic, reference: reference, to: micFile, raw: rawFile,
                                                    silencing: silencing)
                kept.encoded[.mic] = echo.encoded
                kept.echo = echo
            } catch {
                kept.echoSkipped = "failed"
                try? fm.removeItem(at: rawFile)
                Log.audio.error(
                    "Couldn't take the call out of the mic: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            kept.echoSkipped = kept.encoded[.remote] != nil || earlier[.remote] != nil ? "silentRemote" : "noRemote"
        }
        if kept.encoded[.mic] == nil {
            do {
                kept.encoded[.mic] = try CallAudio.join(earlier[.mic], then: micWAV, at: offset, to: micFile,
                                                        silencing: silencing, limit: limit)
            } catch {
                kept.failed = true
                Log.audio.error("Couldn't keep the call's mic: \(error.localizedDescription, privacy: .public)")
            }
        }
        return kept
    }

    /// What cleaning the mic did, in the diagnostics: how long it took and how much quieter the echo got, or why it
    /// didn't run. Numbers only.
    private func logEcho(_ kept: KeptTracks, call id: UUID) {
        if let echo = kept.echo {
            log.event(.calls, "call.echo", [
                "call": CallTranscriber.shortID(id), "audio": (echo.encoded.seconds * 10).rounded() / 10,
                "took": (echo.seconds * 100).rounded() / 100, "reduction": kept.echoReductionDB,
                "echoShare": (echo.summary.echoShare * 100).rounded() / 100,
            ])
        } else if let reason = kept.echoSkipped {
            log.event(.calls, "call.echo.skipped", ["call": CallTranscriber.shortID(id), "reason": reason])
        }
    }

    /// What making the listening tracks did, in the diagnostics: how long it took, each track's loudness and what it
    /// was turned up by, whether the mic was cleaned of the other side. Numbers only.
    private func logListening(_ made: CallListening.Made, call id: UUID) {
        func round(_ value: Double?) -> Double? { value.map { ($0 * 10).rounded() / 10 } }
        log.event(.calls, "call.listening", [
            "call": CallTranscriber.shortID(id), "took": round(made.seconds),
            "micLUFS": round(made.mic?.loudness), "micGain": round(made.mic?.gainDB),
            "remoteLUFS": round(made.remote?.loudness), "remoteGain": round(made.remote?.gainDB),
            "echo": made.cleanedEcho ? "cleaned" : nil, "failure": made.failure,
        ])
    }

    /// Where a journal's mic is silenced: its mutes, and a mute still going on from its start to the end.
    nonisolated static func silencing(_ info: CallJournal.Info) -> [CallInterval] {
        info.mutes + (info.mutedSince.map { [CallInterval(start: $0, end: .infinity)] } ?? [])
    }

    /// The interrupted call a call of `bundleID` starting at `startedAt` continues: the same app (in a browser, the
    /// same service, or page when no service is known), not a menu bar recording, with audio, that stopped at most
    /// `continuationWindow` before. The latest such one; nil when there's none.
    func interruptedCall(continuedBy bundleID: String?, service: CallService?, pageTitle: String?, manual: Bool,
                         startedAt: Date, besides id: UUID? = nil) -> CallRecord? {
        guard let bundleID, !manual else { return nil }
        let isBrowser = CallAppKind.of(bundleID) == .browser
        return calls.filter { call in
            guard call.id != id, call.status == .interrupted, !call.manual, call.bundleID == bundleID,
                  call.micFile != nil || call.remoteFile != nil else { return false }
            if isBrowser {
                guard call.service == service else { return false }
                if service == nil, call.pageTitle != pageTitle { return false }
            }
            let gap = startedAt.timeIntervalSince(Self.end(of: call))
            return gap >= -10 && gap <= Self.continuationWindow
        }.max { Self.end(of: $0) < Self.end(of: $1) }
    }

    /// When a call's recording stopped.
    nonisolated static func end(of call: CallRecord) -> Date {
        call.endedAt ?? call.startedAt.addingTimeInterval(call.duration)
    }

    /// `info`'s recording onto the end of `earlier`, which it continues: each track is `earlier`'s, silence up to
    /// where `info` started on `earlier`'s clock, then `info`'s, written over `earlier`'s files only once every track
    /// is encoded; mutes and other tabs' sound move by as much. The one record takes `status`, and the continuation's
    /// own record and journal go. nil, with nothing changed, when a track can't be joined: then it stays a call of its
    /// own.
    private func join(_ info: CallJournal.Info, onto earlier: CallRecord, status: CallStatus,
                      endedAt: Date?) async -> CallRecord? {
        guard let journal, persists else { return nil }
        let offset = max(0, info.startedAt.timeIntervalSince(earlier.startedAt))
        let offsetSamples = Int((offset * Recording.sampleRate).rounded())
        let folder = folder(for: earlier.id)
        let fm = FileManager.default
        // The earlier part as recorded: its mic before it was cleaned, so the whole call is cleaned in one pass.
        var earlierFiles: [CallJournal.Track: URL] = [:]
        for track in CallJournal.Track.allCases {
            var url = audioURL(of: earlier, track: track)
            if track == .mic {
                let raw = folder.appendingPathComponent(Self.rawMicFile, isDirectory: false)
                if fm.fileExists(atPath: raw.path) { url = raw }
            }
            earlierFiles[track] = url.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
        }
        let wavs = Dictionary(uniqueKeysWithValues: CallJournal.Track.allCases.map {
            ($0, journal.audioURL(for: info.id, track: $0))
        })
        let limit = info.endsAt.map { offsetSamples + Int(($0 * Recording.sampleRate).rounded(.up)) }
        // Both parts' mutes on the joined clock: the earlier part's mic is silenced too, if it wasn't yet.
        let silencing = earlier.muteIntervals + Self.silencing(info).map {
            CallInterval(start: $0.start + offset, end: $0.end + offset)
        }
        let joined = await Task.detached(priority: .utility) { () -> KeptTracks? in
            let fm = FileManager.default
            var kept = Self.keepTracks(earlier: earlierFiles, then: wavs, at: offsetSamples, limit: limit,
                                       silencing: silencing, in: folder, suffix: ".joining")
            func temporary(_ name: String) -> URL {
                folder.appendingPathComponent("\(name).joining.m4a", isDirectory: false)
            }
            let names = CallJournal.Track.allCases.map(\.rawValue) + ["mic-raw"]
            guard !kept.failed else {
                for name in names { try? fm.removeItem(at: temporary(name)) }
                return nil
            }
            // Nothing new on a track: the earlier part's file stays as it is.
            var moves = kept.encoded.keys.map { ($0.rawValue, "\($0.rawValue).m4a") }
            if kept.encoded[.mic] != nil {
                if kept.echo != nil {
                    moves.append(("mic-raw", Self.rawMicFile))
                } else {
                    // The joined mic is as recorded now: an earlier cleaning's raw file would only be stale.
                    try? fm.removeItem(at: folder.appendingPathComponent(Self.rawMicFile, isDirectory: false))
                }
            }
            for (name, finalName) in moves {
                let final = folder.appendingPathComponent(finalName, isDirectory: false)
                try? fm.removeItem(at: final)
                do {
                    try fm.moveItem(at: temporary(name), to: final)
                } catch {
                    Log.audio.error("Couldn't keep the joined call's \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    if let track = CallJournal.Track(rawValue: name) { kept.encoded[track] = nil }
                }
            }
            return kept
        }.value
        guard let joined else { return nil }
        let encoded = joined.encoded
        logEcho(joined, call: earlier.id)
        var record = earlier
        // The earlier part's listening tracks end where it did: the joined call plays its 16 kHz tracks.
        for name in [record.listeningMicFile, record.listeningRemoteFile].compactMap({ $0 }) {
            try? fm.removeItem(at: folder.appendingPathComponent(name, isDirectory: false))
        }
        record.listeningMicFile = nil
        record.listeningRemoteFile = nil
        record.status = status
        record.error = nil
        record.transcript = nil
        record.summary = nil
        record.summaryError = nil
        record.costUSD = nil
        record.cutOffAt = nil
        record.missedSpeech = []
        record.muteIntervals = earlier.muteIntervals + info.mutes.map {
            CallInterval(start: $0.start + offset, end: $0.end + offset)
        }
        record.muteKnown = earlier.muteKnown && info.muteKnown
        record.micSilencedWhenMuted = encoded[.mic] != nil || earlier.micSilencedWhenMuted
        record.otherBrowserAudio = earlier.otherBrowserAudio + info.otherBrowserAudio.map {
            CallInterval(start: $0.start + offset, end: $0.end + offset)
        }
        record.micProblem = earlier.micProblem ?? info.micProblem
        record.remoteProblem = earlier.remoteProblem == Self.silentTapMessage ? nil : earlier.remoteProblem
        record.remoteProblem = record.remoteProblem ?? info.remoteProblem
        if let mic = encoded[.mic] {
            record.micFile = "mic.m4a"
            record.micSeconds = mic.seconds
            record.echoCancelled = joined.echo?.tookEchoOut ?? false
            record.echoReductionDB = joined.echoReductionDB
        }
        if let remote = encoded[.remote] {
            record.remoteFile = "remote.m4a"
            record.remoteSeconds = remote.seconds
            if remote.peak == 0, remote.seconds >= 10, record.remoteProblem == nil,
                   SystemAudioPermission.current() != .authorized {
                record.remoteProblem = Self.silentTapMessage
            }
        }
        if let since = info.mutedSince {
            record.muteIntervals = CallInterval.union(record.muteIntervals + [
                CallInterval(start: since + offset, end: max(since + offset, record.duration)),
            ])
        }
        record.endedAt = endedAt ?? record.startedAt.addingTimeInterval(record.duration)
        // The continuation's own record (kept while it recorded) is now this one.
        calls.removeAll { $0.id == info.id }
        upsert(record)
        await flush()
        journal.remove(info.id)
        removeFolder(of: info.id)
        let gap = info.startedAt.timeIntervalSince(Self.end(of: earlier))
        log.event(.calls, "call.joined", [
            "call": CallTranscriber.shortID(earlier.id), "continuation": CallTranscriber.shortID(info.id),
            "gap": gap, "seconds": record.duration,
        ])
        Log.app.info("Joined a call the app quit recording with its continuation (gap \(gap, format: .fixed(precision: 0), privacy: .public) s)")
        return record
    }

    /// Brings back the calls an earlier run was recording when it ended (`CallJournal`): a kept one as
    /// `.interrupted`, with its audio up to there; one the person hadn't answered about as `.unconfirmed`; one never
    /// confirmed as a call goes. One older than Auto-delete keeps goes too. Nothing is transcribed by itself: that
    /// costs money. A call left as `.recording` with no journal lost its audio.
    private func recoverJournals() async {
        guard let journal else { return }
        let days = settings.autoDeleteHistoryDays
        let cutoff = days > 0 ? Date().addingTimeInterval(-Double(days) * 86_400) : nil
        var recovered: Set<UUID> = []
        for leftover in await journal.leftovers() {
            // Without its sidecar, nothing says it wasn't kept: keeping it is the safe side.
            let info = leftover.info ?? CallJournal.Info(id: leftover.id, startedAt: leftover.created ?? Date(),
                                                         appName: "Call", consent: .kept)
            let status: CallStatus
            switch info.consent {
            case .suspected:
                journal.remove(leftover.id)
                continue
            case .asking: status = .unconfirmed
            case .kept: status = .interrupted
            }
            guard cutoff.map({ info.startedAt >= $0 }) ?? true else {
                journal.remove(leftover.id)
                continue
            }
            var record = await adopt(info, status: status)
            record.error = Self.interruptedMessage
            upsert(record)
            recovered.insert(info.id)
            Log.app.info("Brought back a call the app quit recording (\(record.duration, format: .fixed(precision: 0), privacy: .public) s)")
        }
        for index in calls.indices where calls[index].status == .recording && !recovered.contains(calls[index].id) {
            calls[index].status = .interrupted
            calls[index].error = Self.interruptedMessage
        }
        save()
    }

    // MARK: Private

    private func removeFolder(of id: UUID) {
        guard persists else { return }
        let folder = folder(for: id)
        io.async { try? FileManager.default.removeItem(at: folder) }
    }

    /// Coalesces bursts into one write, off the main thread.
    private func save() {
        guard persists else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            let calls = self.calls, url = self.paths.callsFile
            self.io.async { Self.write(calls, to: url) }
        }
    }

    private struct FileFormat: Codable {
        var version: Int
        var calls: [LossyCall]
    }

    /// One malformed call must not cost the whole list.
    private struct LossyCall: Codable {
        var value: CallRecord?

        init(_ value: CallRecord) { self.value = value }

        init(from decoder: Decoder) throws {
            value = try? CallRecord(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            try value.encode(to: encoder)
        }
    }

    private nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private nonisolated static func write(_ calls: [CallRecord], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(FileFormat(version: 1, calls: calls.map(LossyCall.init)))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.app.error("Couldn't save calls: \(error.localizedDescription, privacy: .public)")
        }
    }
}
