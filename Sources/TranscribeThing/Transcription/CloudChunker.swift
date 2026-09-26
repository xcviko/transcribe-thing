import Accelerate
import Foundation

/// Splits a recording for OpenRouter's speech-to-text endpoint, whose upstream providers give up after 60 s per
/// request, and sends the pieces one after another.
enum CloudChunker {
    static let maxChunkSeconds: Double = 50
    /// Each cut lands in the quietest `quietWindowSeconds` within the last `searchSeconds` of its chunk.
    static let searchSeconds: Double = 10
    static let quietWindowSeconds: Double = 0.3
    /// Cuts stay at least this far from the end, so the last chunk is never a sliver of a word.
    static let minimumTailSeconds: Double = 1
    /// A chunk of a longer recording with less voice than this is not sent (the recorder's own pre-flight bar).
    static let minimumVoicedSeconds: Double = 0.25
    private static let frameSeconds: Double = 0.01

    /// Consecutive sample ranges that cover `0..<samples.count` in order, each at most `maxSeconds` long.
    static func ranges(for samples: [Float], sampleRate: Double = Recording.sampleRate,
                       maxSeconds: Double = maxChunkSeconds) -> [Range<Int>] {
        let count = samples.count
        let maxLength = Int(maxSeconds * sampleRate)
        guard count > 0 else { return [] }
        guard maxLength > 0, count > maxLength else { return [0..<count] }

        let frame = max(1, Int(sampleRate * frameSeconds))
        let windowFrames = max(1, Int((quietWindowSeconds / frameSeconds).rounded()))
        let search = Int(searchSeconds * sampleRate)
        let tail = Int(minimumTailSeconds * sampleRate)

        var ranges: [Range<Int>] = []
        var start = 0
        while count - start > maxLength {
            let searchStart = max(start + 1, start + maxLength - search)
            let searchEnd = min(start + maxLength, count - tail)
            let cut = searchEnd > searchStart
                ? quietestCut(samples, in: searchStart..<searchEnd, frame: frame, windowFrames: windowFrames)
                : start + maxLength
            ranges.append(start..<cut)
            start = cut
        }
        ranges.append(start..<count)
        return ranges
    }

    /// The middle of the lowest-energy window of `windowFrames` frames inside `region` (the latest one on a tie).
    static func quietestCut(_ samples: [Float], in region: Range<Int>, frame: Int, windowFrames: Int) -> Int {
        let frameCount = region.count / frame
        guard frameCount >= windowFrames else { return region.lowerBound + region.count / 2 }
        var energy = [Double](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for index in 0..<frameCount {
                var sum: Float = 0
                vDSP_svesq(base + region.lowerBound + index * frame, 1, &sum, vDSP_Length(frame))
                energy[index] = Double(sum)
            }
        }
        var window = energy[0..<windowFrames].reduce(0, +)
        var best = window
        var bestStart = 0
        // `stride`, not `1...n`: a region exactly one window long has no other start, and `1...0` traps.
        for start in stride(from: 1, through: frameCount - windowFrames, by: 1) {
            window += energy[start + windowFrames - 1] - energy[start - 1]
            if window <= best {
                best = window
                bestStart = start
            }
        }
        return region.lowerBound + (bestStart * frame) + (windowFrames * frame) / 2
    }

    struct Transcript: Sendable, Equatable {
        /// Chunk texts in order, joined with single spaces.
        var text: String
        /// Sum over the chunks that reported a cost; nil when none did.
        var costUSD: Double?
        /// Providers the responses named, each once, in order of first appearance.
        var providers: [String]
        var generationIDs: [String]
        /// Chunks actually sent (silent ones are skipped).
        var requestCount: Int
    }

    /// Sends the chunks of `samples` one by one through `send` (a complete WAV file in, the chunk's result out),
    /// stopping as soon as the calling task is cancelled. With more than one chunk, chunks without voice are
    /// skipped, judged like the recorder's pre-flight (`SpeechAnalyzer`'s adaptive floor, so a quiet mic still
    /// counts). `dropsSilencePhrases` drops Whisper's stock phrases on nearly silent chunks.
    static func transcribe(_ samples: [Float], ranges: [Range<Int>], dropsSilencePhrases: Bool,
                           send: (Data) async throws -> CloudResult) async throws -> Transcript {
        var texts: [String] = []
        var cost: Double?
        var providers: [String] = []
        var generationIDs: [String] = []
        var requests = 0
        for range in ranges {
            try Task.checkCancellation()
            let skipsSilence = ranges.count > 1
            let prepared = await Task.detached(priority: .userInitiated) { () -> (wav: Data, voiced: Double)? in
                let chunk = Array(samples[range])
                if skipsSilence {
                    let speech = SpeechAnalyzer.stats(for: chunk)
                    guard !speech.isSilent, speech.voicedSeconds >= minimumVoicedSeconds else { return nil }
                }
                let voiced = dropsSilencePhrases ? SilenceGuard.voicedSeconds(chunk) : 0
                return (WAVEncoder.pcm16(chunk, sampleRate: Int(Recording.sampleRate)), voiced)
            }.value
            guard let prepared else { continue }
            try Task.checkCancellation()

            let result = try await send(prepared.wav)
            requests += 1
            if let value = result.costUSD { cost = (cost ?? 0) + value }
            if let provider = result.provider, !providers.contains(provider) { providers.append(provider) }
            if let id = result.generationID { generationIDs.append(id) }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if dropsSilencePhrases, SilenceGuard.isLikelyHallucination(text, voicedSeconds: prepared.voiced) { continue }
            texts.append(text)
        }
        return Transcript(text: texts.joined(separator: " "), costUSD: cost, providers: providers,
                          generationIDs: generationIDs, requestCount: requests)
    }
}
