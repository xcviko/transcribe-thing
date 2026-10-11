import Foundation

/// Transcribes a recorded call with Gemini 3.8 Flash, one request per chunk. The two tracks, the mic's and the other
/// side's, are mixed into one mono track (`CallMix`), the mic silent while the person was muted; the tracks stay apart on
/// disk, for the player. The prompt (`CallPrompts.call`) names the person ("Sam", or "Me"), says when they were muted,
/// and asks for every voice: theirs, the other participants', anyone in the room with them ("Nearby 1"). The answer is a
/// line per phrase, "[MM:SS-MM:SS] Speaker: text" (`CallPrompts.format`, read by `CallTranscriptParser`, which still
/// takes the JSON array earlier builds asked for). A phrase is this Mac's side when its speaker is the person or someone
/// nearby, else the other side's (`CallSides`).
///
/// A call longer than `maxChunkSeconds` goes in chunks, both tracks cut at the same places, the speakers named so far
/// carried into the next chunk's prompt. Each chunk goes whole, its silences too; only a chunk with no speech in it at
/// all (`SpeechAnalyzer`) isn't sent: it would cost money for nothing. Every answer is kept as it came, in the call's
/// folder (`CallStore.answersFolder`), so a transcript that went wrong can be looked at. An answer cut off by its token
/// limit is read as far as it goes and the call says where (`CallRecord.cutOffAt`). Runs once a kept call ends, and
/// again on Retry (`retranscribe`). What happens goes to the diagnostic log, never what was said.
@MainActor
final class CallTranscriber {
    /// One request: the chunk's audio as an .m4a, the system prompt, the chunk's length. Throws `AppError`; an answer
    /// cut off by its token limit as `AppError.openRouterTruncated` with what came of it.
    typealias Send = @Sendable (_ audio: Data, _ prompt: String, _ seconds: TimeInterval) async throws -> CloudResult

    /// Longest chunk in one request: well under the ~1 h 47 min a request's budget takes at 16 kbps, so the answer's
    /// tokens (a line for every phrase, `OpenRouterClient.transcriptionMaxTokens`) are never the limit.
    nonisolated static let maxChunkSeconds: TimeInterval = 45 * 60
    /// Speech a chunk of a track needs to be worth a request.
    nonisolated static let minimumVoicedSeconds: TimeInterval = 0.5

    private let store: CallStore
    private let send: Send
    /// The person's first name, which the mic's speaker gets; "Me" without one.
    var userName: @MainActor () -> String? = { nil }
    /// Reads a stretch of a track's file; replaceable in tests.
    var read: @Sendable (_ url: URL, _ range: Range<Int>) throws -> [Float] = { try CallAudio.read($0, range: $1) }
    /// Where events go; a test's own log in tests.
    var log: DiagnosticLog = .shared
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(store: CallStore, send: @escaping Send) {
        self.store = store
        self.send = send
    }

    /// The live request: Gemini 3.8 Flash at its own reasoning level, through the Vertex proxy while it routes Gemini
    /// (`VertexProxyAccount.routesGemini`, decided for each request), else through OpenRouter with the account's key.
    /// A proxy that's set up never hands a request to OpenRouter. The answer comes back as the model wrote it (no
    /// `<transcript>` tags are asked for or taken off).
    static func openRouter(client: OpenRouterClient, account: OpenRouterAccount,
                           proxy: VertexProxyAccount? = nil) -> Send {
        let engine = EngineID.geminiFlash
        let model = engine.openRouterModelID ?? "google/gemini-3.8-flash"
        let effort = engine.reasoningEffort ?? .medium
        return { audio, prompt, seconds in
            let route = await MainActor.run { () -> Result<(OpenRouterClient, String), AppError> in
                if let proxy, proxy.routesGemini {
                    guard let key = proxy.apiKey(), let proxyClient = proxy.client() else {
                        return .failure(.vertexProxy(.keyUnreadable))
                    }
                    return .success((proxyClient, key))
                }
                guard let key = account.apiKey() else { return .failure(.openRouterMissingKey) }
                return .success((client, key))
            }
            let (target, key) = try route.get()
            do {
                let result = try await target.transcribe(
                    audio: audio, format: UploadFormat.m4a.rawValue, model: model, systemPrompt: prompt, effort: effort,
                    maxTokens: OpenRouterClient.transcriptionMaxTokens(audioSeconds: seconds), apiKey: key,
                    timeout: engine.cloudTimeout, extractsTags: false)
                if target.service == .vertexProxy, let proxy { await MainActor.run { proxy.noteCloudSuccess() } }
                return result
            } catch let error as AppError {
                if target.service == .vertexProxy, let proxy { await MainActor.run { proxy.noteCloudFailure(error) } }
                throw error
            }
        }
    }

    func isTranscribing(_ id: UUID) -> Bool { tasks[id] != nil }

    /// Transcribes the call (again): `.transcribing`, then `.done` with the transcript and what it cost, or `.failed`
    /// with why. A transcription of it already running goes on.
    func transcribe(_ id: UUID) {
        guard tasks[id] == nil, let call = store.call(id: id) else { return }
        guard call.micFile != nil || call.remoteFile != nil else {
            log.event(.calls, "transcription.failed", ["call": Self.shortID(id), "error": "noAudio"])
            store.update(id) {
                $0.status = .failed
                $0.error = "The call has no audio"
            }
            return
        }
        store.update(id) {
            $0.status = .transcribing
            $0.error = nil
        }
        let plan = Plan(remote: store.audioURL(of: call, track: .remote), mic: store.audioURL(of: call, track: .mic),
                        remoteSamples: Int(call.remoteSeconds * Recording.sampleRate),
                        micSamples: Int(call.micSeconds * Recording.sampleRate),
                        mutes: call.muteIntervals, userName: userName(), service: call.service?.name,
                        answers: store.answersFolder(for: id), callID: id)
        let send = send, read = read, log = log
        tasks[id] = Task { [weak self] in
            let outcome: Result<Outcome, any Error>
            do {
                outcome = .success(try await Self.run(plan, send: send, read: read, log: log))
            } catch {
                outcome = .failure(error)
            }
            self?.finish(id, outcome)
        }
    }

    /// Retry: the same as `transcribe`, from scratch.
    func retranscribe(_ id: UUID) {
        transcribe(id)
    }

    /// Stops a transcription (the call was deleted).
    func cancel(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
    }

    /// Returns once no transcription runs: tests.
    func waitUntilIdle() async {
        while let task = tasks.values.first { await task.value }
    }

    private func finish(_ id: UUID, _ outcome: Result<Outcome, any Error>) {
        tasks[id] = nil
        switch outcome {
        case .success(let outcome):
            log.event(.calls, "transcription.finished", [
                "call": Self.shortID(id), "phrases": outcome.transcript.segments.count,
                "requests": outcome.requests, "skippedSilent": outcome.skippedSilent,
                "cutOff": outcome.cutOffAt.map(CallPrompts.clock), "cost": outcome.costUSD,
            ])
            store.update(id) {
                $0.status = .done
                $0.transcript = outcome.transcript
                $0.costUSD = outcome.costUSD
                $0.cutOffAt = outcome.cutOffAt
                $0.error = nil
            }
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            Log.engine.error("Call transcription failed: \(String(describing: error), privacy: .public)")
            log.event(.calls, "transcription.failed", ["call": Self.shortID(id), "error": Self.code(of: error)])
            store.update(id) {
                $0.status = .failed
                $0.error = error.localizedDescription
            }
        }
    }

    /// An error as the log names it: `AppError.code`, the transcriber's own, or its type.
    nonisolated static func code(of error: any Error) -> String {
        if let error = error as? AppError { return error.code }
        if let error = error as? Failure { return error.code }
        return String(describing: type(of: error))
    }

    /// The first part of a call's id: enough to tell calls apart in the log.
    nonisolated static func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    // MARK: Work

    /// What one call's transcription needs, read on the main actor.
    struct Plan: Sendable {
        var remote: URL?
        var mic: URL?
        var remoteSamples: Int
        var micSamples: Int
        /// When the person was muted: their mic is silenced there before it's mixed, and the prompt says so.
        var mutes: [CallInterval]
        var userName: String?
        var service: String?
        /// Where each answer is kept as it came (`<chunk>-mix.txt`); nil keeps none.
        var answers: URL?
        /// For the log.
        var callID: UUID?

        init(remote: URL?, mic: URL?, remoteSamples: Int, micSamples: Int, mutes: [CallInterval], userName: String?,
             service: String?, answers: URL? = nil, callID: UUID? = nil) {
            self.remote = remote
            self.mic = mic
            self.remoteSamples = remoteSamples
            self.micSamples = micSamples
            self.mutes = mutes
            self.userName = userName
            self.service = service
            self.answers = answers
            self.callID = callID
        }
    }

    struct Outcome: Sendable {
        var transcript: CallTranscript
        var costUSD: Double?
        /// Where the transcript may stop short, on the call's clock: the end of what a cut-off answer had.
        var cutOffAt: TimeInterval?
        /// Requests sent (one per chunk), and chunks left out as silent.
        var requests = 0
        var skippedSilent = 0
    }

    enum Failure: Error, LocalizedError, Equatable {
        /// An answer with something in it and nothing readable as a transcript: `lines` lines, none of them a phrase.
        case unreadableAnswer(chunk: Int, chunks: Int, lines: Int)

        var errorDescription: String? {
            switch self {
            case .unreadableAnswer(let chunk, let chunks, let lines):
                let part = chunks > 1 ? " for part \(chunk) of \(chunks)" : ""
                let none = lines == 1 ? "its one line" : "any of its \(lines) lines"
                return "Gemini’s answer\(part) wasn’t a transcript: \(Brand.name) couldn’t read \(none). "
                    + "The answer is kept with the call: Show in Finder, then the answers folder."
            }
        }

        var code: String {
            switch self {
            case .unreadableAnswer: "unreadableAnswer"
            }
        }
    }

    /// Every chunk of at most `maxChunkSeconds`, both tracks mixed, one request at a time.
    nonisolated static func run(_ plan: Plan, maxChunkSeconds: TimeInterval = maxChunkSeconds, send: Send,
                                read: @Sendable (URL, Range<Int>) throws -> [Float],
                                log: DiagnosticLog = .shared) async throws -> Outcome {
        let total = max(plan.remote == nil ? 0 : plan.remoteSamples, plan.mic == nil ? 0 : plan.micSamples)
        let me = CallPrompts.speakerName(for: plan.userName)
        let ranges = chunks(totalSamples: total, maxSeconds: maxChunkSeconds)
        let call = plan.callID.map(shortID)
        log.event(.calls, "transcription.started", [
            "call": call, "chunks": ranges.count,
            "remote": plan.remote == nil ? nil : Double(plan.remoteSamples) / Recording.sampleRate,
            "mic": plan.mic == nil ? nil : Double(plan.micSamples) / Recording.sampleRate,
            "mutes": plan.mutes.count,
        ])
        if let answers = plan.answers {
            // A Retry's answers replace the last try's.
            try? FileManager.default.removeItem(at: answers)
            try? FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        }
        var segments: [CallTranscript.Segment] = []
        var costs: [Double] = []
        var roster: [String] = []
        var sides = CallSides(me: me)
        var outcome = Outcome(transcript: CallTranscript(segments: []))

        for (index, range) in ranges.enumerated() {
            try Task.checkCancellation()
            let chunk = index + 1
            let offset = Double(range.lowerBound) / Recording.sampleRate
            guard let audio = try await chunkAudio(plan, range, read: read) else {
                outcome.skippedSilent += 1
                log.event(.calls, "transcription.skipped", ["call": call, "chunk": chunk])
                continue
            }
            let mutes = plan.mutes.compactMap { mute -> CallInterval? in
                guard mute.overlap(offset, offset + audio.seconds) > 0 else { return nil }
                return CallInterval(start: max(0, mute.start - offset), end: min(audio.seconds, mute.end - offset))
            }
            let prompt = CallPrompts.call(me: me, service: plan.service, roster: roster, local: sides.speakers,
                                          mutes: mutes)
            let started = ContinuousClock.now
            var text: String
            var result: CloudResult?
            do {
                let answered = try await send(audio.data, prompt, audio.seconds)
                result = answered
                text = answered.text
            } catch AppError.openRouterTruncated(let partial) {
                text = partial
            }
            let elapsed = started.duration(to: .now)
            outcome.requests += 1
            if let answers = plan.answers {
                let file = answers.appendingPathComponent("\(chunk)-mix.txt", isDirectory: false)
                do {
                    try Data(text.utf8).write(to: file, options: .atomic)
                } catch {
                    Log.engine.error("Couldn't keep a call's answer: \(error.localizedDescription, privacy: .public)")
                }
            }
            let parsed = CallTranscriptParser.parse(text, side: .remote, duration: audio.seconds,
                                                    speakers: [me] + roster)
            let truncated = result == nil
            costs += [result?.costUSD].compactMap { $0 }
            log.event(.calls, "transcription.request", [
                "call": call, "chunk": chunk, "chunks": ranges.count, "audio": audio.seconds,
                "chars": text.count, "format": parsed.format.rawValue, "phrases": parsed.segments.count,
                "skipped": parsed.skipped, "finish": truncated ? "length" : result?.finishReason,
                "cost": result?.costUSD, "seconds": Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18,
            ])
            if parsed.format == .unreadable, !truncated {
                throw Failure.unreadableAnswer(chunk: chunk, chunks: ranges.count, lines: parsed.skipped)
            }
            if truncated {
                let reached = offset + (parsed.segments.map(\.end).max() ?? 0)
                outcome.cutOffAt = min(outcome.cutOffAt ?? reached, reached)
                Log.engine.error("A call's answer was cut off at \(CallPrompts.clock(reached), privacy: .public)")
            }
            let said = parsed.segments.map { segment -> CallTranscript.Segment in
                var segment = segment
                segment.side = sides.side(of: segment.speaker)
                return segment
            }
            roster = Self.roster(roster, adding: said)
            segments += said.map { $0.shifted(by: offset) }
        }
        outcome.transcript = CallTranscriptMerge.merge(segments, mutes: plan.mutes)
        outcome.costUSD = costs.isEmpty ? nil : costs.reduce(0, +)
        return outcome
    }

    /// The chunk as one request's .m4a, or nil when it has no speech worth sending.
    private nonisolated static func chunkAudio(
        _ plan: Plan, _ range: Range<Int>, read: @Sendable (URL, Range<Int>) throws -> [Float]
    ) async throws -> (data: Data, seconds: TimeInterval)? {
        guard !range.isEmpty else { return nil }
        let samples = try mixed(plan, range, read: read)
        let speech = SpeechAnalyzer.stats(for: samples)
        guard !speech.isSilent, speech.voicedSeconds >= minimumVoicedSeconds else { return nil }
        let data = try await Task.detached(priority: .userInitiated) { try CloudAudio.forChat(samples) }.value
        return (data, Double(samples.count) / Recording.sampleRate)
    }

    /// Samples `range` of the call as one track: each track's stretch read (a track over before it, or silent all
    /// through it, left out), the mic zeroed in the mutes (again: a call recorded before the journal did, or a mute
    /// noted late), both mixed (`CallMix.mix`).
    nonisolated static func mixed(_ plan: Plan, _ range: Range<Int>,
                                  read: @Sendable (URL, Range<Int>) throws -> [Float]) throws -> [Float] {
        func track(_ url: URL?, samples: Int) throws -> [Float]? {
            guard let url, range.lowerBound < samples else { return nil }
            let stretch = try read(url, range.clamped(to: 0..<samples))
            return stretch.contains { $0 != 0 } ? stretch : nil
        }
        let remote = try track(plan.remote, samples: plan.remoteSamples)
        var mic = try track(plan.mic, samples: plan.micSamples)
        if var samples = mic {
            CallMix.silence(&samples, first: range.lowerBound, mutes: plan.mutes)
            mic = samples.contains { $0 != 0 } ? samples : nil
        }
        return CallMix.mix(mic: mic, remote: remote, length: range.count)
    }

    /// Where a call of `totalSamples` is cut into requests: as few chunks as keep each within `maxSeconds`, all the
    /// same length, both tracks cut at the same places.
    nonisolated static func chunks(totalSamples: Int, maxSeconds: TimeInterval) -> [Range<Int>] {
        guard totalSamples > 0 else { return [] }
        let maxLength = max(1, Int(maxSeconds * Recording.sampleRate))
        let count = (totalSamples + maxLength - 1) / maxLength
        let length = (totalSamples + count - 1) / count
        return stride(from: 0, to: totalSamples, by: length).map { $0..<min(totalSamples, $0 + length) }
    }

    /// `roster` with the speakers of `segments` it doesn't have yet, in the order they speak.
    nonisolated static func roster(_ roster: [String], adding segments: [CallTranscript.Segment]) -> [String] {
        var names = roster
        for segment in segments where !names.contains(segment.speaker) { names.append(segment.speaker) }
        return names
    }
}

// MARK: - Sides

/// Which side of the call a speaker in the mixed answer is on: the person recording ("Sam", or "Me") and anyone in
/// the room with them ("Nearby 1") are this Mac's side, everyone else the other side. Kept per call, by the names the
/// model gave, which a rename on the call's page never changes, so a renamed speaker keeps their side.
struct CallSides: Sendable {
    let me: String
    /// This Mac's side's speakers so far, the person first.
    private(set) var speakers: [String]

    init(me: String) {
        self.me = me
        speakers = [me]
    }

    /// The person ("Me" too, whatever their name), or "Nearby" with a number.
    func isLocal(_ speaker: String) -> Bool {
        let name = speaker.trimmingCharacters(in: .whitespacesAndNewlines)
        if speakers.contains(name) { return true }
        if name.caseInsensitiveCompare(me) == .orderedSame || name.caseInsensitiveCompare("Me") == .orderedSame {
            return true
        }
        return name.range(of: #"^nearby(\s*\d+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `speaker`'s side, remembered for the chunks after.
    mutating func side(of speaker: String) -> CallSide {
        guard isLocal(speaker) else { return .remote }
        if !speakers.contains(speaker) { speakers.append(speaker) }
        return .local
    }
}

// MARK: - Prompts

/// The system prompt of a call's requests. English instructions; the transcript stays in the language spoken.
enum CallPrompts {
    /// What the person recording is called: their first name, else "Me".
    static func speakerName(for userName: String?) -> String {
        let name = userName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Me" : name
    }

    /// What an answer with no speech in it says.
    static let noSpeech = "NO SPEECH"

    static let format = """
        Answer with only the transcript, nothing before or after it: one line per phrase, in order, each line \
        [start-end] Speaker: what they said
        for example: [01:05-01:12] Participant 1: Да, слышу тебя хорошо.
        Times are MM:SS from the start of this audio (H:MM:SS from an hour on). Keep each phrase on its own single \
        line. Start a new line when the speaker changes, and split a long turn at a sentence end about every 30 \
        seconds. Write what is said in the language it's said in, never translated, with punctuation; leave out \
        stutters, false starts and filler sounds. Leave out anything that isn't speech. With no speech at all, answer \
        \(noSpeech).
        """

    /// One chunk of the call, both sides mixed. `me` is the person recording; `roster`, the speakers of the chunks
    /// before, `local` the ones on this Mac's side; `mutes`, when the person was muted, from the chunk's start.
    static func call(me: String, service: String?, roster: [String], local: [String] = [],
                     mutes: [CallInterval]) -> String {
        let named = me != "Me"
        var lines = [
            "This audio is a recording of a call\(service.map { " on \($0)" } ?? ""), both sides mixed into one track: "
                + "the person who recorded it, on their own microphone, and the other participants, one or several, as "
                + "the call app played them, maybe with its codec's sound. People in the same room as the person who "
                + "recorded it may be heard too.",
            (named ? "The person who recorded it is \(me): call them \"\(me)\"." : "Call the person who recorded it \"Me\".")
                + " Theirs is usually the nearest, clearest voice. Call anyone else in the room with them \"Nearby 1\", "
                + "\"Nearby 2\" and so on.",
            "Tell the other participants apart. Name one by their name when the call makes it clear: they introduce "
                + "themselves, or someone addresses them by name and they answer (\"Аня, ты как?\" then Аня speaks). "
                + "Otherwise call them \"Participant 1\", \"Participant 2\" and so on, in the order they first speak. "
                + "One person keeps one name all through.",
            "If \(named ? me : "the person who recorded it") used speakers rather than headphones, the other "
                + "participants may be heard twice, a moment apart: write each phrase once.",
        ]
        if !mutes.isEmpty {
            let spans = mutes.map { "\(clock($0.start)) to \(clock($0.end))" }.joined(separator: ", ")
            lines.append("\(named ? me : "The person who recorded it") was muted in the call during \(spans). Their "
                         + "microphone is silent then: any voice heard then is one of the other participants, never "
                         + "\"\(me)\".")
        }
        if !roster.isEmpty {
            let names = roster.map { name in
                guard local.contains(name) else { return name }
                return name == me ? "\(name) (who recorded the call)" : "\(name) (in the room with \(named ? me : "them"))"
            }
            lines.append("Earlier in this call these speakers were heard: \(names.joined(separator: ", ")). "
                         + "Use the same names for the same voices; number new ones after them.")
        }
        lines.append(format)
        return lines.joined(separator: "\n\n")
    }

    /// "MM:SS" ("H:MM:SS" from an hour on).
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Answers

/// Reads Gemini's answer into segments. The answer is a line per phrase, "[MM:SS-MM:SS] Speaker: text", read a line at
/// a time: a line that isn't one (a remark before or after, a code fence) is skipped and counted, never the whole
/// answer lost for it. It forgives what models do: "H:MM:SS", a fraction, plain seconds in brackets, no end time, a
/// dash of any kind, list markers and bold around the time or the name, a speaker named with a colon in it (known
/// from the speakers so far). The JSON array earlier builds asked for is still read, and a malformed one (a quote not
/// escaped, an answer cut off) gives up only the objects that are broken.
enum CallTranscriptParser {
    /// How the answer was read.
    enum Format: String, Sendable {
        /// A line per phrase.
        case lines
        /// The JSON array.
        case json
        /// A JSON array that didn't parse whole: its objects one by one.
        case salvaged
        /// Nothing said: an empty answer, "[]", "NO SPEECH".
        case empty
        /// Something, and nothing readable in it.
        case unreadable
    }

    struct Parsed: Sendable {
        var segments: [CallTranscript.Segment]
        var format: Format
        /// Lines (or JSON objects) that held something and couldn't be read.
        var skipped: Int
    }

    /// The answer's phrases; throws `CallTranscriber.Failure.unreadableAnswer` for an answer with nothing readable.
    static func segments(from answer: String, side: CallSide, duration: TimeInterval, defaultSpeaker: String? = nil,
                         speakers: [String] = []) throws -> [CallTranscript.Segment] {
        let parsed = parse(answer, side: side, duration: duration, defaultSpeaker: defaultSpeaker, speakers: speakers)
        if parsed.format == .unreadable {
            throw CallTranscriber.Failure.unreadableAnswer(chunk: 1, chunks: 1, lines: parsed.skipped)
        }
        return parsed.segments
    }

    /// The answer read as well as it can be. `speakers` are names already known, matched first: one with a colon in
    /// it is still one name.
    static func parse(_ answer: String, side: CallSide, duration: TimeInterval, defaultSpeaker: String? = nil,
                      speakers: [String] = []) -> Parsed {
        let fallback = defaultSpeaker ?? (side == .remote ? "Participant 1" : "Me")
        let known = (speakers + [defaultSpeaker].compactMap { $0 }).filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        let byLine = lines(answer, known: known)
        if !byLine.items.isEmpty {
            return Parsed(segments: finish(byLine.items, side: side, duration: duration, fallback: fallback),
                          format: .lines, skipped: byLine.skipped)
        }
        if answer.contains("{"), let json = json(answer), !json.items.isEmpty {
            return Parsed(segments: finish(json.items, side: side, duration: duration, fallback: fallback),
                          format: json.format, skipped: json.skipped)
        }
        if saysNothing(answer) { return Parsed(segments: [], format: .empty, skipped: 0) }
        return Parsed(segments: [], format: .unreadable, skipped: max(1, byLine.skipped))
    }

    /// One phrase as read, before its times are settled.
    struct Item: Equatable {
        var start: TimeInterval?
        var end: TimeInterval?
        /// nil: the line named nobody (the speaker before, else the side's default).
        var speaker: String?
        var text: String
    }

    // MARK: Lines

    private static let time = #"\d{1,2}(?::\d{1,2}){1,2}(?:[.,]\d+)?|\d+(?:[.,]\d+)?s?"#
    /// An optional list marker and bold, the time in brackets (or bare when it has a colon), then the rest.
    private static let linePattern = try! NSRegularExpression(pattern:
        #"^(?:[-*•>]\s+|\d{1,3}[.)]\s+)?(?:\*\*|__)?\s*([\[(])?\s*("# + time + #")(?:\s*(?:-|–|—|~|→|to|\.\.)\s*("#
        + time + #"))?\s*([\])])?(?:\*\*|__)?\s*(.*)$"#)

    static func lines(_ answer: String, known: [String]) -> (items: [Item], skipped: Int) {
        var items: [Item] = []
        var skipped = 0
        for raw in answer.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("```") || isNoSpeech(line) { continue }
            guard var phrase = item(line, known: known) else {
                skipped += 1
                continue
            }
            // A line with a time and nothing said: nothing to keep, nothing wrong.
            guard !phrase.text.isEmpty else { continue }
            if phrase.speaker == nil { phrase.speaker = items.last?.speaker }
            items.append(phrase)
        }
        return (items, skipped)
    }

    /// "[01:05-01:12] Аня: Да." as a phrase; nil for a line that isn't one.
    static func item(_ line: String, known: [String]) -> Item? {
        let ns = line as NSString
        guard let match = linePattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
        let opened = group(1) != nil, closed = group(4) != nil
        guard let startText = group(2), opened == closed else { return nil }
        // A bare number is a time only in brackets: "2. Item" or "2024 was..." isn't.
        guard opened || startText.contains(":") else { return nil }
        guard let start = seconds(startText) else { return nil }
        let end = group(3).flatMap { seconds($0) }
        let (speaker, text) = speakerAndText(group(5) ?? "", known: known)
        return Item(start: start, end: end, speaker: speaker, text: text)
    }

    /// "Аня: Да, слышу" → ("Аня", "Да, слышу"); a known name first, so "HR: Аня: Привет" with "HR: Аня" known is
    /// her. Without a name before a colon, all of it is the text.
    static func speakerAndText(_ rest: String, known: [String]) -> (String?, String) {
        var rest = rest.trimmingCharacters(in: .whitespaces)
        // "[00:01-00:03] - Аня: …", "[00:01-00:03]: Аня: …".
        for mark in ["- ", "– ", "— ", ": "] where rest.hasPrefix(mark) {
            rest = String(rest.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
        }
        let unbolded = rest.drop { $0 == "*" || $0 == "_" }
        for name in known where unbolded.hasPrefix(name) {
            let after = unbolded.dropFirst(name.count).drop { $0 == "*" || $0 == "_" || $0 == " " }
            if after.first == ":" { return (name, cleanText(after.dropFirst())) }
        }
        guard let colon = rest.firstIndex(of: ":") else { return (nil, cleanText(Substring(rest))) }
        let name = rest[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "*_ \t"))
        let words = name.split(separator: " ").count
        let opensLikeText = name.first.map { "[(«\"“'".contains($0) } ?? true
        guard !name.isEmpty, name.count <= 60, words <= 6, !opensLikeText else {
            return (nil, cleanText(Substring(rest)))
        }
        return (name, cleanText(rest[rest.index(after: colon)...]))
    }

    private static func cleanText(_ text: Substring) -> String {
        var text = text.trimmingCharacters(in: .whitespaces)
        // Bold the model closed after the name: "**Аня:** Привет".
        while text.hasPrefix("**") || text.hasPrefix("__") { text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        return text
    }

    private static func isNoSpeech(_ line: String) -> Bool {
        let bare = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]().*_ "))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return bare == "no speech" || bare.isEmpty
    }

    /// An answer that says nothing was said: empty, an empty fence, "[]", "NO SPEECH".
    private static func saysNothing(_ answer: String) -> Bool {
        answer.split(whereSeparator: \.isNewline).allSatisfy { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            return line.isEmpty || line.hasPrefix("```") || line == "[]" || isNoSpeech(line)
        }
    }

    // MARK: JSON

    private static let objectPattern = try! NSRegularExpression(pattern: #"\{[^{}]*\}"#)

    /// The JSON array, whole, else its objects one at a time.
    private static func json(_ answer: String) -> (items: [Item], format: Format, skipped: Int)? {
        if let open = answer.firstIndex(of: "["), let close = answer.lastIndex(of: "]"), open < close,
           let array = (try? JSONSerialization.jsonObject(with: Data(answer[open...close].utf8))) as? [Any] {
            let objects = array.compactMap { $0 as? [String: Any] }
            return (objects.compactMap(item), .json, array.count - objects.count)
        }
        let ns = answer as NSString
        var items: [Item] = []
        var skipped = 0
        for match in objectPattern.matches(in: answer, range: NSRange(location: 0, length: ns.length)) {
            let text = ns.substring(with: match.range)
            if let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
                if let item = item(object) { items.append(item) }
            } else if let item = looseItem(text) {
                items.append(item)
            } else {
                skipped += 1
            }
        }
        return (items, .salvaged, skipped)
    }

    private static func item(_ object: [String: Any]) -> Item? {
        let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return nil }
        let speaker = (object["speaker"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Item(start: seconds(object["start"]), end: seconds(object["end"]),
                    speaker: speaker.flatMap { $0.isEmpty ? nil : $0 }, text: text)
    }

    private static let loosePattern = try! NSRegularExpression(pattern:
        #""(start|end|speaker|text)"\s*:\s*(?:"((?:[^\\]|\\.)*?)"\s*(?=,\s*"(?:start|end|speaker|text)"\s*:|\s*\})|(-?\d+(?:\.\d+)?))"#)

    /// An object JSON can't read for a quote the model didn't escape: `{"text": "Он сказал "да"", …}`. Each field is
    /// taken up to where the next field (or the object's end) starts.
    private static func looseItem(_ object: String) -> Item? {
        let ns = object as NSString
        var fields: [String: Any] = [:]
        for match in loosePattern.matches(in: object, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1))
            if match.range(at: 2).location != NSNotFound {
                let raw = ns.substring(with: match.range(at: 2))
                fields[key] = raw.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\n"#, with: " ")
            } else if match.range(at: 3).location != NSNotFound {
                fields[key] = Double(ns.substring(with: match.range(at: 3))).map { NSNumber(value: $0) }
            }
        }
        return item(fields)
    }

    // MARK: Times

    /// Items as segments: an item without a start follows the one before, one without an end lasts until the next
    /// (at most 5 s), every time within the audio.
    private static func finish(_ items: [Item], side: CallSide, duration: TimeInterval,
                               fallback: String) -> [CallTranscript.Segment] {
        var placed: [(start: TimeInterval, end: TimeInterval?, speaker: String, text: String)] = []
        for item in items {
            let start = item.start ?? placed.last.map { $0.end ?? $0.start } ?? 0
            placed.append((start, item.end, item.speaker ?? fallback, item.text))
        }
        let limit = max(0, duration)
        return placed.enumerated().map { index, item in
            let start = min(max(0, item.start), limit)
            let next = placed.dropFirst(index + 1).first.map { min(max(0, $0.start), limit) }
            let end = min(max(start, item.end ?? next ?? min(limit, start + 5)), limit)
            return CallTranscript.Segment(start: start, end: max(start, end), side: side, speaker: item.speaker,
                                          text: item.text)
        }
    }

    /// "MM:SS", "H:MM:SS", "SS", with or without a fraction ("." or ","), an "s" after plain seconds, or a number.
    static func seconds(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        guard var text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: ",", with: ".")
        if text.hasSuffix("s"), !text.contains(":") { text.removeLast() }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }
}

/// Both sides' segments as one transcript.
enum CallTranscriptMerge {
    /// By start time (the other side first at the same moment: the mic's answer follows what it answers), each of the
    /// mic's segments marked when at least half of it, or its start for one with no length, fell in a mute.
    static func merge(_ segments: [CallTranscript.Segment], mutes: [CallInterval]) -> CallTranscript {
        let marked = segments.map { segment -> CallTranscript.Segment in
            var segment = segment
            guard segment.side == .local else { return segment }
            let length = segment.end - segment.start
            if length <= 0 {
                segment.duringMute = mutes.contains { $0.contains(segment.start) }
            } else {
                let muted = mutes.reduce(0) { $0 + $1.overlap(segment.start, segment.end) }
                segment.duringMute = muted >= length / 2
            }
            return segment
        }
        let ordered = marked.enumerated().sorted { lhs, rhs in
            if lhs.element.start != rhs.element.start { return lhs.element.start < rhs.element.start }
            if lhs.element.side != rhs.element.side { return lhs.element.side == .remote }
            return lhs.offset < rhs.offset
        }
        return CallTranscript(segments: ordered.map(\.element))
    }
}

extension CallTranscript.Segment {
    /// The segment moved `seconds` later: a chunk's times on the call's clock.
    func shifted(by seconds: TimeInterval) -> Self {
        var segment = self
        segment.start += seconds
        segment.end += seconds
        return segment
    }
}
