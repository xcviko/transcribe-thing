import Foundation

/// Transcribes a recorded call with Gemini 3.8 Flash, side by side. Gemini merges a stereo file's channels into one,
/// so the two tracks never go as one file: the other side's track goes first, alone (who said what among the
/// participants), then the mic's, with that transcript in its prompt so the other side heard through the speakers
/// (echo) is left out, and the person's mutes, so what they said muted is still transcribed but marked. Each answer is
/// JSON segments; they're merged here by time (`CallTranscriptMerge`).
///
/// A call longer than `maxChunkSeconds` goes in chunks, each track cut at the same places, the speakers named so far
/// carried into the next chunk's prompt. A chunk of a track with no speech in it (`SpeechAnalyzer`) isn't sent: it
/// would cost money for nothing. Runs once a kept call ends, and again on Retry (`retranscribe`).
@MainActor
final class CallTranscriber {
    /// One request: the chunk's audio as an .m4a, the system prompt, the chunk's length. Throws `AppError`.
    typealias Send = @Sendable (_ audio: Data, _ prompt: String, _ seconds: TimeInterval) async throws -> CloudResult

    /// Longest chunk in one request: well under the ~1 h 47 min a request's budget takes at 16 kbps, so the answer's
    /// tokens (JSON for every phrase, `OpenRouterClient.transcriptionMaxTokens`) are never the limit.
    nonisolated static let maxChunkSeconds: TimeInterval = 45 * 60
    /// Speech a chunk of a track needs to be worth a request.
    nonisolated static let minimumVoicedSeconds: TimeInterval = 0.5

    private let store: CallStore
    private let send: Send
    /// The person's first name, which the mic's speaker gets; "Me" without one.
    var userName: @MainActor () -> String? = { nil }
    /// Reads a stretch of a track's file; replaceable in tests.
    var read: @Sendable (_ url: URL, _ range: Range<Int>) throws -> [Float] = { try CallAudio.read($0, range: $1) }
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(store: CallStore, send: @escaping Send) {
        self.store = store
        self.send = send
    }

    /// The live request: Gemini 3.8 Flash through OpenRouter at its own reasoning level, with the account's key.
    static func openRouter(client: OpenRouterClient, account: OpenRouterAccount) -> Send {
        let engine = EngineID.geminiFlash
        let model = engine.openRouterModelID ?? "google/gemini-3.8-flash"
        let effort = engine.reasoningEffort ?? .medium
        return { audio, prompt, seconds in
            let key = await MainActor.run { account.apiKey() }
            guard let key else { throw AppError.openRouterMissingKey }
            return try await client.transcribe(audio: audio, format: UploadFormat.m4a.rawValue, model: model,
                                               systemPrompt: prompt, effort: effort,
                                               maxTokens: OpenRouterClient.transcriptionMaxTokens(audioSeconds: seconds),
                                               apiKey: key, timeout: engine.cloudTimeout)
        }
    }

    func isTranscribing(_ id: UUID) -> Bool { tasks[id] != nil }

    /// Transcribes the call (again): `.transcribing`, then `.done` with the transcript and what it cost, or `.failed`
    /// with why. A transcription of it already running goes on.
    func transcribe(_ id: UUID) {
        guard tasks[id] == nil, let call = store.call(id: id) else { return }
        guard call.micFile != nil || call.remoteFile != nil else {
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
                        mutes: call.muteIntervals, userName: userName(), service: call.service?.name)
        let send = send, read = read
        tasks[id] = Task { [weak self] in
            let outcome: Result<Outcome, any Error>
            do {
                outcome = .success(try await Self.run(plan, send: send, read: read))
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
            store.update(id) {
                $0.status = .done
                $0.transcript = outcome.transcript
                $0.costUSD = outcome.costUSD
                $0.error = nil
            }
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            Log.engine.error("Call transcription failed: \(String(describing: error), privacy: .public)")
            store.update(id) {
                $0.status = .failed
                $0.error = error.localizedDescription
            }
        }
    }

    // MARK: Work

    /// What one call's transcription needs, read on the main actor.
    struct Plan: Sendable {
        var remote: URL?
        var mic: URL?
        var remoteSamples: Int
        var micSamples: Int
        var mutes: [CallInterval]
        var userName: String?
        var service: String?
    }

    struct Outcome: Sendable {
        var transcript: CallTranscript
        var costUSD: Double?
    }

    enum Failure: Error, LocalizedError, Equatable {
        /// An answer that isn't the JSON asked for.
        case unreadableAnswer

        var errorDescription: String? {
            switch self {
            case .unreadableAnswer: "Gemini’s answer wasn’t a transcript"
            }
        }
    }

    /// Every chunk of at most `maxChunkSeconds`, the other side's track then the mic's, one request at a time.
    nonisolated static func run(_ plan: Plan, maxChunkSeconds: TimeInterval = maxChunkSeconds, send: Send,
                                read: @Sendable (URL, Range<Int>) throws -> [Float]) async throws -> Outcome {
        let total = max(plan.remote == nil ? 0 : plan.remoteSamples, plan.mic == nil ? 0 : plan.micSamples)
        let me = CallPrompts.speakerName(for: plan.userName)
        var segments: [CallTranscript.Segment] = []
        var costs: [Double] = []
        var remoteRoster: [String] = []
        var localRoster: [String] = []
        for range in chunks(totalSamples: total, maxSeconds: maxChunkSeconds) {
            try Task.checkCancellation()
            let offset = Double(range.lowerBound) / Recording.sampleRate
            let length = Double(range.count) / Recording.sampleRate
            var heard: [CallTranscript.Segment] = []
            if let remote = plan.remote, range.lowerBound < plan.remoteSamples,
               let audio = try await chunkAudio(remote, range.clamped(to: 0..<plan.remoteSamples), read: read) {
                let prompt = CallPrompts.remote(roster: remoteRoster, service: plan.service)
                let result = try await send(audio.data, prompt, audio.seconds)
                costs += [result.costUSD].compactMap { $0 }
                heard = try CallTranscriptParser.segments(from: result.text, side: .remote, duration: audio.seconds)
                remoteRoster = roster(remoteRoster, adding: heard)
            }
            if let mic = plan.mic, range.lowerBound < plan.micSamples,
               let audio = try await chunkAudio(mic, range.clamped(to: 0..<plan.micSamples), read: read) {
                let mutes = plan.mutes.compactMap { mute -> CallInterval? in
                    guard mute.overlap(offset, offset + length) > 0 else { return nil }
                    return CallInterval(start: max(0, mute.start - offset), end: min(length, mute.end - offset))
                }
                let prompt = CallPrompts.local(me: me, roster: localRoster, echo: heard, mutes: mutes)
                let result = try await send(audio.data, prompt, audio.seconds)
                costs += [result.costUSD].compactMap { $0 }
                let said = try CallTranscriptParser.segments(from: result.text, side: .local, duration: audio.seconds,
                                                              defaultSpeaker: me)
                localRoster = roster(localRoster, adding: said)
                segments += said.map { $0.shifted(by: offset) }
            }
            segments += heard.map { $0.shifted(by: offset) }
        }
        let transcript = CallTranscriptMerge.merge(segments, mutes: plan.mutes)
        return Outcome(transcript: transcript, costUSD: costs.isEmpty ? nil : costs.reduce(0, +))
    }

    /// The chunk of a track as one request's .m4a, or nil when it has no speech worth sending.
    private nonisolated static func chunkAudio(
        _ url: URL, _ range: Range<Int>, read: @Sendable (URL, Range<Int>) throws -> [Float]
    ) async throws -> (data: Data, seconds: TimeInterval)? {
        guard !range.isEmpty else { return nil }
        let samples = try read(url, range)
        let speech = SpeechAnalyzer.stats(for: samples)
        guard !speech.isSilent, speech.voicedSeconds >= minimumVoicedSeconds else { return nil }
        let data = try await Task.detached(priority: .userInitiated) { try CloudAudio.forChat(samples) }.value
        return (data, Double(samples.count) / Recording.sampleRate)
    }

    /// Where a call of `totalSamples` is cut into requests: as few chunks as keep each within `maxSeconds`, all the
    /// same length. Both tracks are cut at the same places, so a chunk's echo is the other side's same chunk.
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

// MARK: - Prompts

/// The system prompts of a call's requests. English instructions; the transcript stays in the language spoken.
enum CallPrompts {
    /// What the mic's main voice is called: the person's first name, else "Me".
    static func speakerName(for userName: String?) -> String {
        let name = userName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Me" : name
    }

    static let format = """
        Answer with only a JSON array, no other text: one object per phrase, in order, \
        {"start": "MM:SS", "end": "MM:SS", "speaker": "…", "text": "…"}. Times are from the start of this audio. \
        Start a new object when the speaker changes, and split a long turn at a sentence end about every 30 seconds. \
        Write what is said in the language it's said in, never translated, with punctuation; leave out stutters, \
        false starts and filler sounds. Leave out anything that isn't speech. With no speech at all, answer [].
        """

    /// The other side's track, alone: who said what among the participants.
    static func remote(roster: [String], service: String?) -> String {
        var lines = [
            "This audio is one side of a call\(service.map { " on \($0)" } ?? ""): the other participants, as the call app played them. "
                + "There may be several people.",
            "Tell the voices apart. Name a speaker by their name when the call makes it clear: they introduce themselves, or "
                + "someone addresses them by name and they answer (\"Аня, ты как?\" then Аня speaks). Otherwise call them "
                + "\"Participant 1\", \"Participant 2\" and so on, in the order they first speak. One person keeps one name "
                + "all through.",
        ]
        if !roster.isEmpty {
            lines.append("Earlier in this call these speakers were heard: \(roster.joined(separator: ", ")). "
                         + "Use the same names for the same voices; number new ones after them.")
        }
        lines.append(format)
        return lines.joined(separator: "\n\n")
    }

    /// The mic's track: the person recording and anyone in the room, with the other side's transcript to leave out.
    static func local(me: String, roster: [String], echo: [CallTranscript.Segment],
                      mutes: [CallInterval]) -> String {
        var lines = [
            "This audio is the microphone of \(me == "Me" ? "the person" : me) who recorded a call. Their voice, the "
                + "nearest one, is \"\(me)\". Anyone else speaking in the same room is \"Nearby 1\", \"Nearby 2\" and so "
                + "on, unless the conversation names them.",
        ]
        if !roster.isEmpty {
            lines.append("Earlier in this call these speakers were heard here: \(roster.joined(separator: ", ")). "
                         + "Use the same names for the same voices.")
        }
        if !echo.isEmpty {
            let said = echo.map { "[\(clock($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
            lines.append("The other side of the call can be heard faintly through the speakers. This is what they said "
                         + "(times from the start of this audio). When you hear these phrases, leave them out: they are "
                         + "echo, not said here.\n" + said)
        }
        if !mutes.isEmpty {
            let spans = mutes.map { "\(clock($0.start)) to \(clock($0.end))" }.joined(separator: ", ")
            lines.append("\(me == "Me" ? "The person" : me) was muted in the call during \(spans): the other side didn't hear "
                         + "this. Still transcribe what's said then, as usual.")
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

/// Reads Gemini's answer into segments, forgiving what models do: a code fence or words around the JSON, a missing
/// `end`, times as numbers or "H:MM:SS", times past the audio's end.
enum CallTranscriptParser {
    static func segments(from answer: String, side: CallSide, duration: TimeInterval,
                         defaultSpeaker: String? = nil) throws -> [CallTranscript.Segment] {
        guard let open = answer.firstIndex(of: "["), let close = answer.lastIndex(of: "]"), open < close else {
            // No array, but no words either (an empty answer, an empty code fence): no speech.
            let stripped = answer.replacingOccurrences(of: "json", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "`")))
            if stripped.isEmpty { return [] }
            throw CallTranscriber.Failure.unreadableAnswer
        }
        let json = Data(answer[open...close].utf8)
        guard let items = (try? JSONSerialization.jsonObject(with: json)) as? [Any] else {
            throw CallTranscriber.Failure.unreadableAnswer
        }
        let fallback = defaultSpeaker ?? (side == .remote ? "Participant 1" : "Me")
        var parsed: [(start: TimeInterval, end: TimeInterval?, speaker: String, text: String)] = []
        for case let item as [String: Any] in items {
            let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }
            let start = seconds(item["start"]) ?? parsed.last.map { $0.end ?? $0.start } ?? 0
            let speaker = (item["speaker"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            parsed.append((start, seconds(item["end"]), speaker.flatMap { $0.isEmpty ? nil : $0 } ?? fallback, text))
        }
        let limit = max(0, duration)
        return parsed.enumerated().map { index, item in
            let start = min(max(0, item.start), limit)
            let next = parsed.dropFirst(index + 1).first.map { min(max(0, $0.start), limit) }
            let end = min(max(start, item.end ?? next ?? min(limit, start + 5)), limit)
            return CallTranscript.Segment(start: start, end: max(start, end), side: side, speaker: item.speaker,
                                          text: item.text)
        }
    }

    /// "MM:SS", "H:MM:SS", "SS", with or without a fraction, or a number of seconds.
    static func seconds(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
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
