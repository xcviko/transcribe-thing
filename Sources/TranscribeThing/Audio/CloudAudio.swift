import Accelerate
import AVFoundation
import Foundation

/// How a recording of any length goes to OpenRouter (pure, off the main thread). Gemini hears it in one chat request
/// whose inline audio has a budget: WAV while it fits, AAC beyond. Parakeet's speech-to-text endpoint takes it in
/// segments of at most 5 minutes, cut in pauses.
enum CloudAudio {
    /// The recording for one Gemini request. While the base64 of its 16 kHz WAV fits `budget` (about 7.4 minutes),
    /// the WAV, as every dictation has always sent; beyond that AAC-LC in an .m4a at `aacBitRate`, without ever
    /// building the big WAV. Throws when the encoder fails.
    static func forChat(_ samples: [Float], budget: Int = OpenRouterClient.maxBase64Bytes) throws
        -> (data: Data, format: String) {
        let seconds = Double(samples.count) / Recording.sampleRate
        guard let bitRate = aacBitRate(seconds: seconds, budget: budget) else {
            return (WAVEncoder.pcm16(samples), "wav")
        }
        return (try m4a(samples, bitRate: bitRate), "m4a")
    }

    /// The AAC bit rate for `seconds` of audio, or nil while its WAV fits `budget`: the highest of 32, 24 and
    /// 16 kbps whose estimated file (`bitRate / 8 × seconds × 1.1 + 4,096` bytes) fits as base64. Past what 16 kbps
    /// fits (over an hour and a half) it is 16 kbps anyway: nothing is refused up front, and a request OpenRouter
    /// finds too large comes back as `recordingTooLarge`.
    static func aacBitRate(seconds: TimeInterval, budget: Int) -> Int? {
        let samples = Int((max(0, seconds) * Recording.sampleRate).rounded(.up))
        guard OpenRouterClient.base64Length(ofByteCount: 44 + samples * 2) > budget else { return nil }
        for bitRate in [32_000, 24_000, 16_000] {
            let estimate = Int((Double(bitRate) / 8 * max(0, seconds) * 1.1).rounded(.up)) + 4_096
            if OpenRouterClient.base64Length(ofByteCount: estimate) <= budget { return bitRate }
        }
        return 16_000
    }

    /// 16 kHz mono AAC-LC in an MPEG-4 container (.m4a) at `bitRate`: about 15.8, 12.2 and 8.8 MB an hour at 32, 24
    /// and 16 kbps. Written through a temporary file, removed before this returns.
    static func m4a(_ samples: [Float], bitRate: Int) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-thing-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Recording.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let frames = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        try samples.withUnsafeBufferPointer { source in
            var offset = 0
            while offset < source.count {
                let count = min(frames, source.count - offset)
                channel.update(from: source.baseAddress! + offset, count: count)
                buffer.frameLength = AVAudioFrameCount(count)
                try file.write(from: buffer)
                offset += count
            }
        }
        file.close()
        return try Data(contentsOf: url)
    }

    /// Where Parakeet's requests split a recording: one range up to `maxSeconds`, otherwise a cut before each
    /// `maxSeconds` boundary, in the middle of the quietest 50 ms (by RMS) of the `searchSeconds` before it, so a
    /// word is rarely cut in two. The ranges are contiguous, cover every sample, and none is longer than `maxSeconds`.
    static func speechSegments(_ samples: [Float], maxSeconds: TimeInterval = 300,
                               searchSeconds: TimeInterval = 20) -> [Range<Int>] {
        let maxLength = Int(maxSeconds * Recording.sampleRate)
        guard maxLength > 0, samples.count > maxLength else { return [0..<samples.count] }
        let window = 800
        let searchLength = Int(searchSeconds * Recording.sampleRate)
        var ranges: [Range<Int>] = []
        var start = 0
        samples.withUnsafeBufferPointer { buffer in
            while buffer.count - start > maxLength {
                let boundary = start + maxLength
                var cut = boundary
                var quietest = Float.infinity
                // Half-overlapping windows that end by the boundary: the cut, a window's middle, stays inside it.
                var position = max(start, boundary - searchLength)
                while position + window <= boundary {
                    var energy: Float = 0
                    vDSP_svesq(buffer.baseAddress! + position, 1, &energy, vDSP_Length(window))
                    if energy < quietest {
                        quietest = energy
                        cut = position + window / 2
                    }
                    position += window / 2
                }
                ranges.append(start..<cut)
                start = cut
            }
        }
        ranges.append(start..<samples.count)
        return ranges
    }
}
