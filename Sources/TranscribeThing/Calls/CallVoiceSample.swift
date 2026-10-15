import Foundation

/// A short sample of the person's own voice, from their mic in the same call, sent ahead of the call's audio so Gemini
/// can tell them from the other participants in the mix (`CallPrompts.call`), when the local model can't say when they
/// spoke (`CallMicHint`): it isn't downloaded, or it failed. A wrong sample is worse than none: a call on laptop
/// speakers puts the other side's voice in the mic, and a sample of that names a colleague after the person. So a
/// stretch is taken only where it can't be the other side:
/// - never where they were muted (their mic is zeroed there);
/// - the other side's track quiet all through it and for `guardSeconds` before and after (their echo and the room's
///   tail after they stop); speech that runs on into that margin is left out whole, not cut to fit;
/// - at least `minStretch` long, with `minVoicedShare` of its frames voiced;
/// - its voice at least `echoMarginDB` louder than what the mic typically hears while the other side speaks
///   (`echoBaseline`): the person's own voice is close to the mic, a participant through the speakers isn't. With
///   too little of the other side to tell (`minEchoSeconds`), this check is skipped.
/// Without the other side's track (none recorded, or silent all through), any stretch they spoke in will do. The
/// stretches with the most speech first, from anywhere in the call, put in call order with `pause` of silence between,
/// `maxSeconds` in all. Less than `minSpeech` of clean speech: no sample, and the request goes as it did before. Pure
/// arithmetic on 16 kHz samples, safe anywhere.
enum CallVoiceSample {
    /// The person's voice, ready to send.
    struct Sample: Sendable, Equatable {
        /// The stretches, joined, as an .m4a.
        var data: Data
        /// Its length, pauses included.
        var seconds: TimeInterval
        /// Where its stretches come from, on the call's clock, in order.
        var spans: [CallInterval]
    }

    /// The level analysis's frame: `SpeechAnalyzer`'s.
    static let frameSeconds = SpeechAnalyzer.Parameters().frameSeconds
    /// The shortest stretch worth a place in the sample: shorter bits of speech in a quiet moment of the call are as
    /// likely a reply's first word or a tail of the room as a sentence of the person's.
    static let minStretch: TimeInterval = 2
    /// The whole sample at most, pauses included.
    static let maxSeconds: TimeInterval = 15
    /// Less clean speech than this, and no sample is sent: a couple of short stretches are too easy to get wrong.
    static let minSpeech: TimeInterval = 6
    /// Silence between two stretches.
    static let pause: TimeInterval = 0.3
    /// A gap in the person's speech this long or shorter stays inside a stretch: a breath, the space between words.
    static let maxGap: TimeInterval = 0.5
    /// Kept before a stretch's first voiced frame and after its last, so words aren't clipped.
    static let padding: TimeInterval = 0.15
    /// How long the other side must be quiet before a stretch starts and after it ends: on speakers their last words
    /// ring on in the room and come back through the mic for a while after they stop.
    static let guardSeconds: TimeInterval = 0.8
    /// The other side is quiet in a frame below this level and not voiced (`SpeechAnalyzer`) there.
    static let remoteSilenceDBFS: Float = -45
    /// The share of a stretch's frames that must be voiced: speech, not a cough or a tail before a long pause.
    static let minVoicedShare = 0.6
    /// How much louder than `echoBaseline` a stretch's voiced frames must be (their median level): the person's own
    /// voice, not the other side coming back through the speakers.
    static let echoMarginDB: Float = 6
    /// The least of the other side's voiced time (outside the mutes) that tells what the mic hears of them. Less, and
    /// stretches aren't held to `echoMarginDB`.
    static let minEchoSeconds: TimeInterval = 5
    /// A track is read this many samples at a time (a whole number of frames).
    static let blockSamples = 60 * 16_000

    private static var frameLength: Int { Int((Recording.sampleRate * frameSeconds).rounded()) }

    /// The sample for the call `plan` describes, or nil when there's too little clean speech (or no mic).
    static func make(_ plan: CallTranscriber.Plan,
                     read: @Sendable (URL, Range<Int>) throws -> [Float]) throws -> (samples: [Float], spans: [CallInterval])? {
        guard let micURL = plan.mic, plan.micSamples > 0 else { return nil }
        let mic = try levels(micURL, samples: plan.micSamples, mutes: plan.mutes, read: read)
        let remote = try plan.remote.flatMap { url in
            plan.remoteSamples > 0 ? try levels(url, samples: plan.remoteSamples, mutes: nil, read: read) : nil
        }
        let chosen = spans(mic: mic, remote: remote, mutes: plan.mutes)
        guard !chosen.isEmpty else { return nil }
        var samples: [Float] = []
        for (index, span) in chosen.enumerated() {
            if index > 0 { samples += [Float](repeating: 0, count: Int((pause * Recording.sampleRate).rounded())) }
            let from = Int((span.start * Recording.sampleRate).rounded())
            let to = min(plan.micSamples, Int((span.end * Recording.sampleRate).rounded()))
            guard to > from else { continue }
            var stretch = try read(micURL, from..<to)
            CallMix.silence(&stretch, first: from, mutes: plan.mutes)
            samples += stretch
        }
        return (samples, chosen)
    }

    /// Each frame's level (dBFS, `SpeechAnalyzer.frameLevels`) of the first `samples` of a track, read a block at a
    /// time, one level per `frameSeconds` on the call's clock; zeroed in `mutes` first. A file shorter than it says
    /// reads as digital silence after its end.
    static func levels(_ url: URL, samples: Int, mutes: [CallInterval]?,
                       read: @Sendable (URL, Range<Int>) throws -> [Float]) throws -> [Float] {
        let frame = frameLength
        var levels: [Float] = []
        levels.reserveCapacity(samples / frame)
        var start = 0
        while start + frame <= samples {
            let range = start..<min(samples, start + blockSamples)
            let frames = range.count / frame
            var block = try read(url, range)
            if let mutes { CallMix.silence(&block, first: start, mutes: mutes) }
            let full = min(frames, block.count / frame) * frame
            if full > 0 { levels += SpeechAnalyzer.frameLevels(Array(block.prefix(full)), frameLength: frame) }
            levels += [Float](repeating: -160, count: frames - full / frame)
            start = range.upperBound
        }
        return levels
    }

    /// Which stretches go into the sample, on the call's clock, in order: from `mic`'s and `remote`'s frame levels
    /// (`levels`). Empty when they hold less than `minSpeech`.
    static func spans(mic: [Float], remote: [Float]?, mutes: [CallInterval]) -> [CallInterval] {
        let count = mic.count
        guard count > 0 else { return [] }
        func frames(_ seconds: TimeInterval) -> Int { Int((seconds / frameSeconds).rounded()) }
        let voiced = SpeechAnalyzer.voicedFrames(mic)
        var blocked = [Bool](repeating: false, count: count)
        for mute in mutes {
            let from = max(0, Int((mute.start / frameSeconds).rounded(.down)))
            let to = min(count, Int((mute.end / frameSeconds).rounded(.up)))
            if to > from { for index in from..<to { blocked[index] = true } }
        }
        var baseline: Float?
        if let remote, !remote.isEmpty {
            let remoteVoiced = SpeechAnalyzer.voicedFrames(remote)
            baseline = echoBaseline(mic: mic, remoteVoiced: remoteVoiced, muted: blocked)
            func loud(_ index: Int) -> Bool {
                index < remote.count && (remoteVoiced[index] || remote[index] >= remoteSilenceDBFS)
            }
            let margin = frames(guardSeconds)
            var last = Int.min / 2
            for index in 0..<count {
                if loud(index) { last = index }
                if index - last <= margin { blocked[index] = true }
            }
            var next = Int.max / 2
            for index in stride(from: count - 1, through: 0, by: -1) {
                if loud(index) { next = index }
                if next - index <= margin { blocked[index] = true }
            }
        }

        // Stretches of speech, each within a run of frames nothing blocks, louder than the other side through the mic.
        var found: [(start: Int, end: Int, voiced: Int)] = []
        let gap = frames(maxGap), pad = frames(padding), shortest = frames(minStretch)
        var index = 0
        while index < count {
            guard !blocked[index] else {
                index += 1
                continue
            }
            let regionStart = index
            while index < count, !blocked[index] { index += 1 }
            let regionEnd = index
            var current: (first: Int, last: Int, voiced: Int)?
            func close() {
                guard let run = current else { return }
                defer { current = nil }
                // Speech that goes on into the frames around the region (near the other side) is cut, not clear of
                // them: left out whole. Mutes don't count here: the mic is zeroed in them.
                let reach = max(0, run.first - gap - 1), beyond = min(count, run.last + gap + 2)
                let before = min(reach, regionStart)..<regionStart, after = regionEnd..<max(regionEnd, beyond)
                guard !before.contains(where: { voiced[$0] }), !after.contains(where: { voiced[$0] }) else { return }
                let start = max(regionStart, run.first - pad), end = min(regionEnd, run.last + 1 + pad)
                if end - start >= shortest, Double(run.voiced) >= minVoicedShare * Double(end - start),
                   clearOf(baseline, mic: mic, voiced: voiced, start..<end) {
                    found.append((start, end, run.voiced))
                }
            }
            for frame in regionStart..<regionEnd where voiced[frame] {
                if let run = current, frame - run.last - 1 <= gap {
                    current = (run.first, frame, run.voiced + 1)
                } else {
                    close()
                    current = (frame, frame, 1)
                }
            }
            close()
        }

        // The most speech first, up to `maxSeconds` with the pauses.
        let ranked = found.sorted { $0.voiced != $1.voiced ? $0.voiced > $1.voiced : $0.start < $1.start }
        let budget = frames(maxSeconds), between = frames(pause)
        var chosen: [(start: Int, end: Int)] = []
        var used = 0
        for stretch in ranked {
            let room = budget - used - (chosen.isEmpty ? 0 : between)
            guard room >= shortest else { break }
            let length = min(stretch.end - stretch.start, room)
            used += length + (chosen.isEmpty ? 0 : between)
            chosen.append((stretch.start, stretch.start + length))
        }
        let speech = chosen.reduce(0) { $0 + $1.end - $1.start }
        guard speech >= frames(minSpeech) else { return [] }
        return chosen.sorted { $0.start < $1.start }.map {
            CallInterval(start: Double($0.start) * frameSeconds, end: Double($0.end) * frameSeconds)
        }
    }

    /// What the mic typically hears while the other side speaks: the median level (dBFS) of its frames where the
    /// other side's track is voiced, outside the mutes (`muted`). On speakers that's their voice coming back; on
    /// headphones, the room's quiet. Nil with less than `minEchoSeconds` of such frames. Talking over the other side
    /// raises it too: a person who does that most of the time may get no sample, never a wrong one.
    static func echoBaseline(mic: [Float], remoteVoiced: [Bool], muted: [Bool]) -> Float? {
        var levels: [Float] = []
        for index in mic.indices where index < remoteVoiced.count && remoteVoiced[index] && !muted[index] {
            levels.append(mic[index])
        }
        guard Double(levels.count) * frameSeconds >= minEchoSeconds else { return nil }
        return median(levels)
    }

    /// Whether the voiced frames of `range` are, at their median, at least `echoMarginDB` above `baseline`. Always,
    /// without a baseline.
    private static func clearOf(_ baseline: Float?, mic: [Float], voiced: [Bool], _ range: Range<Int>) -> Bool {
        guard let baseline else { return true }
        let levels = range.filter { voiced[$0] }.map { mic[$0] }
        guard !levels.isEmpty else { return false }
        return median(levels) >= baseline + echoMarginDB
    }

    /// The middle value of `values` (the mean of the two middle ones for an even count); `values` not empty.
    static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
