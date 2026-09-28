import Foundation
import Testing
@testable import TranscribeThing

// How a recording of any length goes to OpenRouter: WAV or AAC for Gemini, pause-cut segments for Parakeet.

private let rate = 16_000

/// One second of 220 Hz: a whole number of cycles, so repeats join without a click.
private let toneSecond: [Float] = (0..<rate).map { 0.2 * Float(sin(2 * .pi * 220 * Double($0) / Double(rate))) }

/// `seconds` of the tone, a copy of `toneSecond` per second: synthetic minutes stay cheap to build.
private func tone(_ seconds: Double) -> [Float] {
    let count = Int(seconds * Double(rate))
    var out: [Float] = []
    out.reserveCapacity(count)
    while out.count < count { out.append(contentsOf: toneSecond.prefix(count - out.count)) }
    return out
}

@Suite struct CloudAudioTests {
    /// Gemini's inline budget holds about 7.4 minutes of WAV; past that, the best AAC rate that fits.
    @Test func aacBitRateThresholds() {
        let budget = OpenRouterClient.maxBase64Bytes
        #expect(CloudAudio.aacBitRate(seconds: 60, budget: budget) == nil, "a dictation goes as WAV, as always")
        #expect(CloudAudio.aacBitRate(seconds: 7 * 60, budget: budget) == nil)
        #expect(CloudAudio.aacBitRate(seconds: 8 * 60, budget: budget) == 32_000)
        #expect(CloudAudio.aacBitRate(seconds: 50 * 60, budget: budget) == 32_000)
        #expect(CloudAudio.aacBitRate(seconds: 60 * 60, budget: budget) == 24_000)
        #expect(CloudAudio.aacBitRate(seconds: 90 * 60, budget: budget) == 16_000)
        #expect(CloudAudio.aacBitRate(seconds: 3 * 3600, budget: budget) == 16_000, "never refused up front")
        #expect(CloudAudio.aacBitRate(seconds: 1, budget: 1_000) == 16_000, "nothing fits: the smallest")
    }

    @Test func aDictationGoesAsWAV() throws {
        let samples = tone(60)
        let encoded = try CloudAudio.forChat(samples)
        #expect(encoded.format == "wav")
        #expect(encoded.data == WAVEncoder.pcm16(samples))
    }

    @Test func pastTheBudgetItGoesAsAACInAnM4A() throws {
        let samples = tone(10)
        let encoded = try CloudAudio.forChat(samples, budget: 1_000)
        #expect(encoded.format == "m4a")
        #expect(encoded.data.count > 8)
        #expect(String(decoding: encoded.data[4..<8], as: UTF8.self) == "ftyp", "an MPEG-4 file")
        #expect(encoded.data.count < WAVEncoder.pcm16(samples).count / 4)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try encoded.data.write(to: url)
        let decoded = try AudioFileLoader.load16kMono(url)
        #expect(abs(Double(decoded.count - samples.count) / Double(rate)) <= 0.1)
    }

    @Test func aRecordingUpToFiveMinutesIsOneSegment() {
        #expect(CloudAudio.speechSegments(tone(3)) == [0..<(3 * rate)])
        let five = [Float](repeating: 0.1, count: 300 * rate)
        #expect(CloudAudio.speechSegments(five) == [0..<five.count])
        #expect(CloudAudio.speechSegments([]) == [0..<0])
    }

    /// Twelve minutes with a pause shortly before each 5-minute mark: each cut lands in the pause.
    @Test func cutsLandInPauses() {
        let gaps: [ClosedRange<Double>] = [290...291, 585...586]
        let samples = tone(290) + [Float](repeating: 0, count: rate) + tone(294) + [Float](repeating: 0, count: rate)
            + tone(134)
        #expect(samples.count == 720 * rate)
        let ranges = CloudAudio.speechSegments(samples)
        #expect(ranges.count == 3)
        for (cut, gap) in zip(ranges.dropLast().map(\.upperBound), gaps) {
            #expect(gap.contains(Double(cut) / Double(rate)), "cut at \(Double(cut) / Double(rate)) s")
        }
        Self.expectContiguousAndShort(ranges, count: samples.count)
    }

    /// Without a pause, the cuts still keep every segment within 5 minutes.
    @Test func withoutAPauseSegmentsStillFit() {
        let samples = tone(11 * 60)
        let ranges = CloudAudio.speechSegments(samples)
        #expect(ranges.count == 3)
        Self.expectContiguousAndShort(ranges, count: samples.count)
    }

    private static func expectContiguousAndShort(_ ranges: [Range<Int>], count: Int) {
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == count, "every sample")
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound }, "no gap, no overlap")
        #expect(ranges.allSatisfy { !$0.isEmpty && $0.count <= 300 * rate })
    }
}
