import Foundation

/// When the person spoke in a call, from their own mic, for Gemini to tell their voice from the others in the mix
/// (`CallPrompts.micHintParagraph`). The local model (Parakeet, `CallTranscriber.MicListener`) hears the mic track as
/// the mix has it: after echo removal, silent while they were muted. Its words, grouped into phrases (`phrases`), go in
/// each request's prompt with their times; Gemini is told a voice at those times is the person's and a voice at other
/// times is someone else's. The words are often wrong; the times are what counts.
///
/// A phrase the other side was as loud as or louder than at the same moment (`isOwnVoice`) is left out: on speakers,
/// their voice comes back through the mic, and naming it after the person is worse than no hint.
///
/// Only the stretches of the mic with speech in them are heard (`pieces`), at most `maxPieceSeconds` each: a call
/// listened to on mute costs no time, and a dictation waits at most one piece for the model. Arithmetic on 16 kHz
/// samples, apart from the model `make` is given.
enum CallMicHint {
    /// Words the mic heard close together, and when, in seconds.
    struct Phrase: Sendable, Equatable {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    /// A call's mic phrases, on the call's clock, in order.
    struct Hint: Sendable, Equatable {
        var phrases: [Phrase]
        /// How far the mic track goes: past it nothing is known of when the person spoke.
        var micSeconds: TimeInterval

        /// The phrases for a request of `seconds` of the call from `start`, times from `start`; a phrase across its
        /// edge is cut to it. nil when the mic track stops before the request's audio does (it's shorter than the
        /// other side's): there, no voice can be said not to be the person's.
        func phrases(from start: TimeInterval, seconds: TimeInterval) -> [Phrase]? {
            guard start + seconds <= micSeconds + CallMicHint.coverSlack else { return nil }
            let end = start + seconds
            return phrases.compactMap { phrase in
                guard phrase.end > start, phrase.start < end else { return nil }
                return Phrase(start: max(0, phrase.start - start), end: min(seconds, phrase.end - start),
                              text: phrase.text)
            }
        }
    }

    /// What making a hint came to, for the log: counts and seconds, never the words.
    struct Report: Sendable, Equatable {
        /// Words the model heard, and the phrases kept and left out as the other side's voice.
        var words: Int
        var phrases: Int
        var droppedAsEcho: Int
        /// Stretches of the mic the model heard, and their length in all.
        var pieces: Int
        var heardSeconds: TimeInterval
    }

    /// A pause longer than this starts a new phrase.
    static let maxPause: TimeInterval = 0.8
    /// A phrase that has run longer than this ends at its next word.
    static let maxPhrase: TimeInterval = 15
    /// A phrase is the person's when, over its voiced mic frames, the mic is typically louder than the other side's
    /// track by more than this (the median of the difference). Their own voice is close to the mic; the other side
    /// through the speakers comes back quieter than it went out.
    static let echoMarginDB: Float = 0
    /// The longest stretch of the mic the model hears at once.
    static let maxPieceSeconds: TimeInterval = 120
    /// Speech this close to the speech before it is heard in the same piece.
    static let joinSeconds: TimeInterval = 2
    /// What Parakeet hears in one pass, at the same cost however much of it is speech: bits of speech further apart
    /// than `joinSeconds` still go in one piece while it stays this short.
    static let modelWindowSeconds: TimeInterval = 15
    /// Kept before a piece's first voiced frame and after its last, so its words aren't clipped.
    static let padding: TimeInterval = 0.5
    /// A piece too long is cut in the longest pause of its last this-many seconds.
    static let cutSearchSeconds: TimeInterval = 10
    /// A request's audio may run this far past the mic track's end and still get the hint: the two tracks rarely end
    /// on the same sample.
    static let coverSlack: TimeInterval = 5

    /// The level analysis's frame: `CallVoiceSample`'s.
    static var frameSeconds: TimeInterval { CallVoiceSample.frameSeconds }

    /// The hint for the call `plan` describes, with what it took; nil without a mic track. `hear` is the model: the
    /// words of a stretch of the mic, times from its start. Throws what reading the tracks or the model throws.
    static func make(_ plan: CallTranscriber.Plan,
                     hear: @Sendable (_ samples: [Float]) async throws -> [TimedWord],
                     read: @Sendable (URL, Range<Int>) throws -> [Float])
        async throws -> (hint: Hint, report: Report)? {
        guard let micURL = plan.mic, plan.micSamples > 0 else { return nil }
        let mic = try CallVoiceSample.levels(micURL, samples: plan.micSamples, mutes: plan.mutes, read: read)
        let remote = try plan.remote.flatMap { url in
            plan.remoteSamples > 0
                ? try CallVoiceSample.levels(url, samples: plan.remoteSamples, mutes: nil, read: read) : nil
        }
        let voiced = SpeechAnalyzer.voicedFrames(mic)
        let frame = Int((Recording.sampleRate * frameSeconds).rounded())
        let pieces = pieces(voiced: voiced, levels: mic)
        var words: [TimedWord] = []
        var heard = 0
        for piece in pieces {
            try Task.checkCancellation()
            let lower = piece.lowerBound * frame, upper = min(plan.micSamples, piece.upperBound * frame)
            guard upper > lower else { continue }
            let range = lower..<upper
            var samples = try read(micURL, range)
            CallMix.silence(&samples, first: range.lowerBound, mutes: plan.mutes)
            heard += samples.count
            let offset = Double(range.lowerBound) / Recording.sampleRate
            words += try await hear(samples).map {
                TimedWord(text: $0.text, start: $0.start + offset, end: $0.end + offset)
            }
        }
        let all = phrases(words)
        let kept = all.filter { isOwnVoice($0, mic: mic, remote: remote, voiced: voiced) }
        return (Hint(phrases: kept, micSeconds: Double(plan.micSamples) / Recording.sampleRate),
                Report(words: words.count, phrases: kept.count, droppedAsEcho: all.count - kept.count,
                       pieces: pieces.count, heardSeconds: Double(heard) / Recording.sampleRate))
    }

    /// Words as phrases, in order: a new one after a pause over `maxPause`, or once one has run past `maxPhrase`.
    /// A word of punctuation alone goes on the word before it without a space.
    static func phrases(_ words: [TimedWord]) -> [Phrase] {
        var out: [Phrase] = []
        for word in words.sorted(by: { $0.start < $1.start }) {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var last = out.last, word.start - last.end <= maxPause, last.end - last.start <= maxPhrase {
                let punctuation = text.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
                last.text += punctuation ? text : " " + text
                last.end = max(last.end, word.end)
                out[out.count - 1] = last
            } else {
                out.append(Phrase(start: word.start, end: max(word.start, word.end), text: text))
            }
        }
        return out
    }

    /// Whether `phrase` is the person's own voice: over its voiced mic frames (`voiced`), the mic's level less the
    /// other side's (`remote`, frame levels on the same clock; none recorded is silence) is above `echoMarginDB` at
    /// the median. A phrase with no voiced mic frame isn't: the mic heard no voice there.
    static func isOwnVoice(_ phrase: Phrase, mic: [Float], remote: [Float]?, voiced: [Bool]) -> Bool {
        let from = max(0, Int((phrase.start / frameSeconds).rounded(.down)))
        let to = min(mic.count, voiced.count, Int((phrase.end / frameSeconds).rounded(.up)))
        guard to > from else { return false }
        var margins: [Float] = []
        for index in from..<to where voiced[index] {
            let other = remote.flatMap { index < $0.count ? $0[index] : nil } ?? -160
            margins.append(mic[index] - other)
        }
        guard !margins.isEmpty else { return false }
        return CallVoiceSample.median(margins) > echoMarginDB
    }

    /// The stretches of the mic the model hears, in frames, in order: each run of voiced frames with `padding` on
    /// either side, joined with the next when they're `joinSeconds` apart or less or both fit in `modelWindowSeconds`,
    /// and cut to `maxPieceSeconds`, in the middle of the longest pause near that length (the quietest frame when
    /// there's none).
    static func pieces(voiced: [Bool], levels: [Float]) -> [Range<Int>] {
        let count = min(voiced.count, levels.count)
        func frames(_ seconds: TimeInterval) -> Int { Int((seconds / frameSeconds).rounded()) }
        let join = frames(joinSeconds), pad = frames(padding), window = frames(modelWindowSeconds)
        let longest = max(2, frames(maxPieceSeconds)), search = max(1, frames(cutSearchSeconds))
        var spans: [Range<Int>] = []
        var index = 0
        while index < count {
            guard voiced[index] else {
                index += 1
                continue
            }
            let first = index
            while index < count, voiced[index] { index += 1 }
            let span = max(0, first - pad)..<min(count, index + pad)
            if let last = spans.last,
               span.lowerBound - last.upperBound <= join || span.upperBound - last.lowerBound <= window {
                spans[spans.count - 1] = last.lowerBound..<span.upperBound
            } else {
                spans.append(span)
            }
        }
        var pieces: [Range<Int>] = []
        for span in spans {
            var start = span.lowerBound
            while span.upperBound - start > longest {
                let window = max(start + 1, start + longest - search)..<(start + longest)
                var best: (start: Int, length: Int)?
                var run: Int?
                for frame in window {
                    if voiced[frame] {
                        run = nil
                        continue
                    }
                    let runStart = run ?? frame
                    run = runStart
                    if frame - runStart + 1 > best?.length ?? 0 { best = (runStart, frame - runStart + 1) }
                }
                let cut = best.map { $0.start + $0.length / 2 }
                    ?? window.min(by: { levels[$0] < levels[$1] }) ?? window.upperBound
                pieces.append(start..<cut)
                start = cut
            }
            pieces.append(start..<span.upperBound)
        }
        return pieces
    }
}
