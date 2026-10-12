import Foundation

// A recorded call as the Calls store keeps it (`CallStore`, calls.json), and its transcript. Every time in here is
// seconds from the call's start: sample 0 of both its tracks, the mic's and the other side's.

/// A stretch of a call, in seconds from its start.
struct CallInterval: Codable, Equatable, Hashable, Sendable {
    var start: TimeInterval
    var end: TimeInterval

    init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = max(start, end)
    }

    var duration: TimeInterval { end - start }

    /// Seconds this and `start...end` have in common.
    func overlap(_ start: TimeInterval, _ end: TimeInterval) -> TimeInterval {
        max(0, min(self.end, end) - max(self.start, start))
    }

    func contains(_ time: TimeInterval) -> Bool { time >= start && time <= end }
}

/// Where a call stands.
enum CallStatus: String, Codable, Sendable {
    /// Still being recorded, kept: the live call is `CallMonitor.state`. One found at launch was cut off.
    case recording
    /// The call ended before the person answered "Transcribe your call?": its audio waits for Keep or Discard
    /// (`CallMonitor.keep(callID:)`, `discard(callID:)`), nothing is sent anywhere.
    case unconfirmed
    case transcribing
    case done
    case failed
    /// The app quit (a crash, a forced quit, the Mac shutting down) while it recorded: its audio is kept up to there,
    /// and it's transcribed only when asked (`CallTranscriber.retranscribe`), since that costs money.
    case interrupted
}

/// Which side of the call a phrase was said on: into this Mac's mic, or by the other participants.
enum CallSide: String, Codable, Sendable {
    case local, remote
}

/// What was said in a call, both sides merged by time.
struct CallTranscript: Codable, Equatable, Sendable {
    struct Segment: Codable, Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var side: CallSide
        /// As the model named them: someone's name heard in the call, "Participant 1", the person recording ("Sam",
        /// "Me"), "Nearby 1". `CallRecord.speakerNames` renames them for display.
        var speaker: String
        var text: String
        /// Said into the mic while the person was muted in the call app: the other side didn't hear it. Calls
        /// recorded since the mic is silenced while muted (`CallRecord.micSilencedWhenMuted`) rarely have one.
        var duringMute: Bool = false
    }

    var segments: [Segment]

    /// Every speaker, in the order they first speak.
    var speakers: [String] {
        var seen: Set<String> = []
        return segments.compactMap { seen.insert($0.speaker).inserted ? $0.speaker : nil }
    }
}

/// One recorded call: its audio in `Calls/<id>/` (`CallStore.folder(for:)`), what's known about it, its transcript.
struct CallRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    /// The app's name as it showed then: "Telegram", "Google Chrome", "All sound" for a manual recording.
    var appName: String
    /// The app's main bundle id; nil for a manual recording, which takes every app's sound.
    var bundleID: String?
    var service: CallService?
    /// For a browser: the call tab's page title, without what the browser adds ("Meet – abc-defg-hij").
    var pageTitle: String?
    /// Started from the menu bar: the mic and everything the Mac played, mute not followed.
    var manual: Bool = false
    /// When the person was muted in the call app.
    var muteIntervals: [CallInterval] = []
    /// Whether mute could be followed at all: false when the app's Mute button couldn't be read, so
    /// `muteIntervals` being empty says nothing.
    var muteKnown: Bool = false
    /// The mic's track is silent in `muteIntervals`: zeroed as it was recorded and again when it was kept
    /// (`CallJournal`, `CallStore.adopt`). False for a call recorded before that, whose mic has what was said muted.
    var micSilencedWhenMuted: Bool = false
    /// The other side's voices were taken out of `micFile`, where it heard them (`EchoCanceller`, against the remote
    /// track). False when there was nothing to take out (no remote track, a silent one, or no echo of it in the mic:
    /// headphones), and for calls recorded before. Whenever the mic was cleaned at all (its noise too, with any
    /// remote sound), the mic as recorded is kept next to it as `CallStore.rawMicFile`.
    var echoCancelled: Bool = false
    /// How much quieter the echo got, in dB: the mic's level where only the other side talks, before less after
    /// (`EchoStats.echoReductionDB`); nil when not cancelled or nothing to measure it on.
    var echoReductionDB: Double?
    /// For a browser: when another tab played sound, which the other side's track has too.
    var otherBrowserAudio: [CallInterval] = []
    /// File names in the call's folder; nil when that track has no audio.
    var micFile: String?
    var remoteFile: String?
    var micSeconds: TimeInterval = 0
    var remoteSeconds: TimeInterval = 0
    /// Why a track has no audio or stopped: "No permission to record the sound of other apps".
    var micProblem: String?
    var remoteProblem: String?
    var status: CallStatus
    /// Why transcription failed, or what an interrupted call lost.
    var error: String?
    var transcript: CallTranscript?
    /// What the transcription requests cost, summed; nil before any answered.
    var costUSD: Double?
    /// Where the transcript may stop short, in seconds from the call's start: an answer ran out of room there.
    var cutOffAt: TimeInterval?
    /// Speakers renamed by the person: the model's name → theirs.
    var speakerNames: [String: String] = [:]
    /// What the call was about (`CallSummary`); nil before one was made: a call transcribed before summaries, or one
    /// whose summary failed.
    var summary: CallSummary?
    /// Why the last summary failed; Summarize tries again (`CallTranscriber.summarize`).
    var summaryError: String?

    init(id: UUID, startedAt: Date, endedAt: Date? = nil, appName: String, bundleID: String? = nil,
         service: CallService? = nil, pageTitle: String? = nil, manual: Bool = false, status: CallStatus) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.appName = appName
        self.bundleID = bundleID
        self.service = service
        self.pageTitle = pageTitle
        self.manual = manual
        self.status = status
    }

    /// The longer track's length: the call's.
    var duration: TimeInterval { max(micSeconds, remoteSeconds) }

    /// "Google Meet", "Telegram", "ChatGPT" (a site no service is known for, by its page), "FaceTime", "All sound":
    /// what the call is named by.
    var title: String { service?.name ?? pageTitle.flatMap { $0.isEmpty ? nil : $0 } ?? appName }

    /// `speaker` as the person renamed them.
    func name(of speaker: String) -> String { speakerNames[speaker] ?? speaker }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, appName, bundleID, service, pageTitle, manual, muteIntervals, muteKnown
        case micSilencedWhenMuted, echoCancelled, echoReductionDB
        case otherBrowserAudio, micFile, remoteFile, micSeconds, remoteSeconds, micProblem, remoteProblem, status
        case error, transcript, costUSD, cutOffAt, speakerNames, summary, summaryError
    }

    /// Lenient: anything but the id, the start, the app and the status may be missing (written by another build).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        appName = try c.decode(String.self, forKey: .appName)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        service = (try? c.decodeIfPresent(String.self, forKey: .service)).flatMap { $0.flatMap(CallService.init(rawValue:)) }
        pageTitle = try c.decodeIfPresent(String.self, forKey: .pageTitle)
        manual = try c.decodeIfPresent(Bool.self, forKey: .manual) ?? false
        muteIntervals = try c.decodeIfPresent([CallInterval].self, forKey: .muteIntervals) ?? []
        muteKnown = try c.decodeIfPresent(Bool.self, forKey: .muteKnown) ?? false
        micSilencedWhenMuted = try c.decodeIfPresent(Bool.self, forKey: .micSilencedWhenMuted) ?? false
        echoCancelled = try c.decodeIfPresent(Bool.self, forKey: .echoCancelled) ?? false
        echoReductionDB = try? c.decodeIfPresent(Double.self, forKey: .echoReductionDB)
        otherBrowserAudio = try c.decodeIfPresent([CallInterval].self, forKey: .otherBrowserAudio) ?? []
        micFile = try c.decodeIfPresent(String.self, forKey: .micFile)
        remoteFile = try c.decodeIfPresent(String.self, forKey: .remoteFile)
        micSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .micSeconds) ?? 0
        remoteSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .remoteSeconds) ?? 0
        micProblem = try c.decodeIfPresent(String.self, forKey: .micProblem)
        remoteProblem = try c.decodeIfPresent(String.self, forKey: .remoteProblem)
        // A status this build doesn't know (a newer one's) reads as failed: Retry still works on its audio.
        status = (try? c.decode(CallStatus.self, forKey: .status)) ?? .failed
        error = try c.decodeIfPresent(String.self, forKey: .error)
        transcript = try? c.decodeIfPresent(CallTranscript.self, forKey: .transcript)
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD)
        cutOffAt = try? c.decodeIfPresent(TimeInterval.self, forKey: .cutOffAt)
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        summary = try? c.decodeIfPresent(CallSummary.self, forKey: .summary)
        summaryError = try? c.decodeIfPresent(String.self, forKey: .summaryError)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encode(appName, forKey: .appName)
        try c.encodeIfPresent(bundleID, forKey: .bundleID)
        try c.encodeIfPresent(service?.rawValue, forKey: .service)
        try c.encodeIfPresent(pageTitle, forKey: .pageTitle)
        try c.encode(manual, forKey: .manual)
        try c.encode(muteIntervals, forKey: .muteIntervals)
        try c.encode(muteKnown, forKey: .muteKnown)
        if micSilencedWhenMuted { try c.encode(micSilencedWhenMuted, forKey: .micSilencedWhenMuted) }
        if echoCancelled { try c.encode(echoCancelled, forKey: .echoCancelled) }
        try c.encodeIfPresent(echoReductionDB, forKey: .echoReductionDB)
        try c.encode(otherBrowserAudio, forKey: .otherBrowserAudio)
        try c.encodeIfPresent(micFile, forKey: .micFile)
        try c.encodeIfPresent(remoteFile, forKey: .remoteFile)
        try c.encode(micSeconds, forKey: .micSeconds)
        try c.encode(remoteSeconds, forKey: .remoteSeconds)
        try c.encodeIfPresent(micProblem, forKey: .micProblem)
        try c.encodeIfPresent(remoteProblem, forKey: .remoteProblem)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(transcript, forKey: .transcript)
        try c.encodeIfPresent(costUSD, forKey: .costUSD)
        try c.encodeIfPresent(cutOffAt, forKey: .cutOffAt)
        if !speakerNames.isEmpty { try c.encode(speakerNames, forKey: .speakerNames) }
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(summaryError, forKey: .summaryError)
    }
}

/// How calls are recorded (General, later): not at all, asking each time, or always.
enum CallRecordingMode: String, Codable, CaseIterable, Sendable {
    /// Calls aren't noticed; the menu bar's Start Call Recording still records.
    case off
    /// A call starts recording as soon as it's suspected, and the app asks whether to transcribe it: No deletes it.
    case ask
    /// Every call noticed is recorded and transcribed.
    case automatic
}
