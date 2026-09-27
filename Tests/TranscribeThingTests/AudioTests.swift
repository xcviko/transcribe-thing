import AVFAudio
import Foundation
import Testing
@testable import TranscribeThing

// No test here opens a microphone: capture is exercised with synthetic buffers fed straight into the
// same state machine the tap uses.

// MARK: - Signal helpers

private enum Signal {
    static func sine(_ frequency: Double, seconds: Double, rate: Double, amplitude: Float, phase: Double = 0) -> [Float] {
        let count = Int(seconds * rate)
        return (0..<count).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate + phase)) }
    }

    /// Deterministic white-ish noise (xorshift) with the given RMS.
    static func noise(seconds: Double, rate: Double = 16_000, rms: Float, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> [Float] {
        var state = seed
        let count = Int(seconds * rate)
        let scale = rms * 3.0.squareRoot().float   // uniform in [-a, a] has RMS a/sqrt(3)
        return (0..<count).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let unit = Float(Double(state % 2_000_001) / 1_000_000 - 1)
            return unit * scale
        }
    }

    static func dbToAmplitude(_ db: Float) -> Float { pow(10, db / 20) }

    static func rmsDB(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return -160 }
        let meanSquare = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        return meanSquare > 0 ? 10 * log10(meanSquare) : -160
    }

    static func buffer(channels: [[Float]], rate: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: AVAudioChannelCount(channels.count), interleaved: false)!
        let frames = channels[0].count
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer { source in
                buffer.floatChannelData![index].update(from: source.baseAddress!, count: frames)
            }
        }
        return buffer
    }

    static func chunks(of channels: [[Float]], rate: Double, sizes: [Int]) -> [AVAudioPCMBuffer] {
        var result: [AVAudioPCMBuffer] = []
        var start = 0
        var k = 0
        let total = channels[0].count
        while start < total {
            let size = min(sizes[k % sizes.count], total - start)
            result.append(buffer(channels: channels.map { Array($0[start..<start + size]) }, rate: rate))
            start += size
            k += 1
        }
        return result
    }

    /// Crossings of zero per second, halved: a robust frequency estimate for a clean tone.
    static func estimatedFrequency(_ samples: ArraySlice<Float>, rate: Double) -> Double {
        var crossings = 0
        var previous = samples.first ?? 0
        for value in samples.dropFirst() {
            if (previous < 0) != (value < 0) { crossings += 1 }
            previous = value
        }
        return Double(crossings) / 2 / (Double(samples.count) / rate)
    }
}

private extension Double {
    var float: Float { Float(self) }
}

// MARK: - Resampler

@Suite struct StreamingResamplerTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var rate: Double
        var channels: Int
        var testDescription: String { "\(Int(rate)) Hz × \(channels)" }
    }

    static let cases = [Case(rate: 48_000, channels: 1), Case(rate: 44_100, channels: 1),
                        Case(rate: 48_000, channels: 2), Case(rate: 44_100, channels: 2),
                        Case(rate: 24_000, channels: 1), Case(rate: 16_000, channels: 1)]

    private func signal(_ testCase: Case, seconds: Double = 1.5) -> [[Float]] {
        (0..<testCase.channels).map { channel in
            let a = Signal.sine(440, seconds: seconds, rate: testCase.rate, amplitude: 0.3, phase: Double(channel))
            let b = Signal.sine(1_250, seconds: seconds, rate: testCase.rate, amplitude: 0.2)
            return zip(a, b).map(+)
        }
    }

    private func convert(_ buffers: [AVAudioPCMBuffer], flush: Bool = true) throws -> [Float] {
        let resampler = StreamingResampler()
        var output: [Float] = []
        for buffer in buffers { try resampler.process(buffer, into: &output) }
        if flush { try resampler.flush(into: &output) }
        return output
    }

    @Test(arguments: cases)
    func chunkedConversionMatchesOneShot(_ testCase: Case) throws {
        let channels = signal(testCase)
        let oneShot = try convert([Signal.buffer(channels: channels, rate: testCase.rate)])
        let chunked = try convert(Signal.chunks(of: channels, rate: testCase.rate, sizes: [4_800, 1_024, 37, 4_801, 512, 1]))

        #expect(chunked.count == oneShot.count)
        let worst = zip(chunked, oneShot).map { abs($0 - $1) }.max() ?? 0
        #expect(worst < 1e-5)
    }

    @Test(arguments: cases)
    func outputLengthAndPitchArePreserved(_ testCase: Case) throws {
        let seconds = 1.5
        let tone = (0..<testCase.channels).map { _ in Signal.sine(1_000, seconds: seconds, rate: testCase.rate, amplitude: 0.5) }
        let output = try convert(Signal.chunks(of: tone, rate: testCase.rate, sizes: [4_800]))

        let expected = seconds * Recording.sampleRate
        #expect(abs(Double(output.count) - expected) <= 32)
        let middle = output[1_600..<(output.count - 1_600)]
        #expect(abs(Signal.estimatedFrequency(middle, rate: Recording.sampleRate) - 1_000) < 5)
        #expect(abs(Signal.rmsDB(middle) - Signal.rmsDB(tone[0][...])) < 0.5)
    }

    @Test(arguments: [(48_000.0, 4_800), (44_100.0, 4_410), (48_000.0, 1_024), (24_000.0, 2_400)])
    func streamingLatencyStaysSmall(_ rate: Double, _ chunk: Int) throws {
        // The converter must not park input: the meter and the stop tail rely on output keeping up.
        let resampler = StreamingResampler()
        var output: [Float] = []
        var consumed = 0
        let tone = Signal.sine(440, seconds: 3, rate: rate, amplitude: 0.4)
        for buffer in Signal.chunks(of: [tone], rate: rate, sizes: [chunk]) {
            try resampler.process(buffer, into: &output)
            consumed += Int(buffer.frameLength)
            let behind = Double(consumed) * Recording.sampleRate / rate - Double(output.count)
            #expect(behind < 48, "\(behind) frames behind after \(consumed) input frames")
        }
    }

    @Test func flushRecoversTheConverterTail() throws {
        let tone = [Signal.sine(300, seconds: 0.5, rate: 48_000, amplitude: 0.5)]
        let buffers = Signal.chunks(of: tone, rate: 48_000, sizes: [4_800])
        let withoutFlush = try convert(buffers, flush: false)
        let withFlush = try convert(buffers)
        #expect(withFlush.count > withoutFlush.count)
        #expect(abs(Double(withFlush.count) - 8_000) <= 16)
    }

    @Test func stereoDownmixKeepsTheRightChannel() throws {
        let silent = [Float](repeating: 0, count: 48_000)
        let right = Signal.sine(500, seconds: 1, rate: 48_000, amplitude: 0.5)
        let output = try convert([Signal.buffer(channels: [silent, right], rate: 48_000)])
        let level = Signal.rmsDB(output[1_600..<14_400])
        // Averaging with a silent left channel halves the amplitude (−6 dB), but it must not be silence.
        #expect(level > Signal.rmsDB(right[...]) - 7)
        #expect(level < Signal.rmsDB(right[...]) - 5)
    }

    @Test func formatChangeMidStreamDrainsAndContinues() throws {
        let resampler = StreamingResampler()
        var output: [Float] = []
        try resampler.process(Signal.buffer(channels: [Signal.sine(440, seconds: 0.5, rate: 48_000, amplitude: 0.4)], rate: 48_000), into: &output)
        try resampler.process(Signal.buffer(channels: [Signal.sine(440, seconds: 0.5, rate: 44_100, amplitude: 0.4)], rate: 44_100), into: &output)
        try resampler.flush(into: &output)
        #expect(abs(Double(output.count) - 16_000) <= 48)
    }

    @Test func wholeSignalResampleHelper() {
        let tone = Signal.sine(800, seconds: 1, rate: 44_100, amplitude: 0.5)
        let output = StreamingResampler.resample(tone, from: 44_100)
        #expect(abs(Double(output.count) - 16_000) <= 32)
        #expect(abs(Signal.estimatedFrequency(output[800..<15_200], rate: 16_000) - 800) < 5)
        #expect(StreamingResampler.resample(tone, from: 16_000) == tone)
    }
}

// MARK: - WAV

@Suite struct WAVEncoderTests {
    @Test func roundTripIsLosslessToSixteenBits() throws {
        let samples = Signal.noise(seconds: 0.75, rms: 0.3) + Signal.sine(440, seconds: 0.5, rate: 16_000, amplitude: 0.9)
        let decoded = try #require(WAVEncoder.decode(WAVEncoder.pcm16(samples)))
        #expect(decoded.count == samples.count)
        let worst = zip(decoded, samples).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-4)
    }

    @Test func headerIsCanonical() {
        let data = WAVEncoder.pcm16([0, 0.5, -0.5], sampleRate: 16_000)
        #expect(data.count == 44 + 6)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")
        let rate = data[24..<28].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        #expect(rate == 16_000)
        let riffSize = data[4..<8].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        #expect(riffSize == 36 + 6)
    }

    @Test func clipsOutOfRangeSamples() throws {
        let decoded = try #require(WAVEncoder.decode(WAVEncoder.pcm16([1.7, -2.5, 1, -1])))
        #expect(abs(decoded[0] - 1) < 1e-4)
        #expect(abs(decoded[1] + 1) < 1e-4)
    }

    @Test func emptyRecordingRoundTrips() throws {
        let decoded = try #require(WAVEncoder.decode(WAVEncoder.pcm16([])))
        #expect(decoded.isEmpty)
    }

    @Test func rejectsNonWAVData() {
        #expect(WAVEncoder.decode(Data()) == nil)
        #expect(WAVEncoder.decode(Data("definitely not audio".utf8)) == nil)
        var truncated = WAVEncoder.pcm16([0.1, 0.2])
        truncated.removeSubrange(20..<36)
        #expect(WAVEncoder.decode(truncated) == nil)
    }

    @Test func decodesStereoFloatAtOtherRates() throws {
        let left = Signal.sine(600, seconds: 1, rate: 48_000, amplitude: 0.4)
        let right = left.map { -$0 * 0.5 }
        var body = Data()
        for (l, r) in zip(left, right) {
            withUnsafeBytes(of: l.bitPattern.littleEndian) { body.append(contentsOf: $0) }
            withUnsafeBytes(of: r.bitPattern.littleEndian) { body.append(contentsOf: $0) }
        }
        let data = Self.wav(format: 3, channels: 2, rate: 48_000, bits: 32, body: body, extraChunk: true)

        let (format, raw) = try #require(WAVEncoder.decodeRaw(data))
        #expect(format == WAVEncoder.Format(sampleRate: 48_000, channels: 2, bitsPerSample: 32, isFloat: true))
        #expect(raw.count == left.count)
        #expect(abs(raw[1_000] - (left[1_000] + right[1_000]) / 2) < 1e-6)

        let resampled = try #require(WAVEncoder.decode(data))
        #expect(abs(Double(resampled.count) - 16_000) <= 32)
    }

    @Test func decodesExtensibleTwentyFourBit() throws {
        let values: [Int32] = [0, 4_194_304, -4_194_304, 8_388_607]
        var body = Data()
        for value in values {
            body.append(UInt8(truncatingIfNeeded: value))
            body.append(UInt8(truncatingIfNeeded: value >> 8))
            body.append(UInt8(truncatingIfNeeded: value >> 16))
        }
        let data = Self.wav(format: 0xFFFE, channels: 1, rate: 16_000, bits: 24, body: body, subFormat: 1)
        let decoded = try #require(WAVEncoder.decode(data))
        #expect(decoded.count == 4)
        #expect(abs(decoded[1] - 0.5) < 1e-6)
        #expect(abs(decoded[2] + 0.5) < 1e-6)
    }

    private static func wav(format: UInt16, channels: UInt16, rate: UInt32, bits: UInt16, body: Data,
                            extraChunk: Bool = false, subFormat: UInt16? = nil) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let fmtSize: UInt32 = subFormat == nil ? 16 : 40
        data.append(contentsOf: Array("RIFF".utf8)); u32(0)
        data.append(contentsOf: Array("WAVE".utf8))
        if extraChunk {
            data.append(contentsOf: Array("LIST".utf8)); u32(3); data.append(contentsOf: [1, 2, 3, 0])   // odd size + pad byte
        }
        data.append(contentsOf: Array("fmt ".utf8)); u32(fmtSize)
        u16(format); u16(channels); u32(rate)
        u32(rate * UInt32(channels) * UInt32(bits / 8)); u16(channels * bits / 8); u16(bits)
        if let subFormat {
            u16(22); u16(bits); u32(0); u16(subFormat)
            data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        }
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(body.count))
        data.append(body)
        return data
    }
}

// MARK: - Speech analysis

@Suite struct SpeechAnalyzerTests {
    @Test func emptyIsSilent() {
        #expect(SpeechAnalyzer.stats(for: []) == .empty)
    }

    @Test func digitalSilenceIsFlagged() {
        let stats = SpeechAnalyzer.stats(for: [Float](repeating: 0, count: 32_000))
        #expect(stats.isSilent)
        #expect(stats.voicedSeconds == 0)
        #expect(stats.peakDBFS == -160)
    }

    @Test func stuckDCIsFlagged() {
        let stats = SpeechAnalyzer.stats(for: [Float](repeating: 0.2, count: 16_000))
        #expect(stats.isSilent)
    }

    @Test func steadyNoiseIsNotSpeech() {
        for db: Float in [-70, -45, -25] {
            let stats = SpeechAnalyzer.stats(for: Signal.noise(seconds: 3, rms: Signal.dbToAmplitude(db)))
            #expect(!stats.isSilent)
            #expect(stats.voicedSeconds < 0.1, "noise at \(db) dBFS counted \(stats.voicedSeconds) s")
        }
    }

    @Test func steadyToneAloneIsNotSpeech() {
        let stats = SpeechAnalyzer.stats(for: Signal.sine(220, seconds: 2, rate: 16_000, amplitude: 0.3))
        #expect(stats.voicedSeconds < 0.1)
        #expect(abs(stats.peakDBFS - 20 * log10(0.3)) < 0.1)
    }

    @Test func toneAfterRoomNoiseCounts() {
        let room = Signal.noise(seconds: 1, rms: Signal.dbToAmplitude(-62))
        let tone = Signal.sine(220, seconds: 1.5, rate: 16_000, amplitude: 0.1)
        let stats = SpeechAnalyzer.stats(for: room + zip(tone, Signal.noise(seconds: 1.5, rms: Signal.dbToAmplitude(-62), seed: 7)).map(+))
        #expect(stats.voicedSeconds > 1.4 && stats.voicedSeconds < 1.6, "voiced \(stats.voicedSeconds)")
    }

    @Test func speechLikeBurstsAreMeasured() {
        let rate = 16_000.0
        var samples = Signal.noise(seconds: 0.6, rms: Signal.dbToAmplitude(-58))
        var expected = 0.0
        for (index, length) in [0.18, 0.24, 0.12, 0.3, 0.2, 0.15, 0.26, 0.22].enumerated() {
            // Voiced syllable: a harmonic stack with a raised-cosine envelope, over room noise.
            let count = Int(length * rate)
            let f0 = 140.0 + Double(index * 9)
            let syllable = (0..<count).map { i -> Float in
                let t = Double(i) / rate
                let envelope = Float(0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(count)))
                let voice = sin(2 * .pi * f0 * t) + 0.5 * sin(4 * .pi * f0 * t) + 0.25 * sin(6 * .pi * f0 * t)
                return 0.15 * envelope * Float(voice)
            }
            let gap = Signal.noise(seconds: 0.17, rms: Signal.dbToAmplitude(-58), seed: UInt64(index + 11))
            samples += zip(syllable, Signal.noise(seconds: length, rms: Signal.dbToAmplitude(-58), seed: UInt64(index + 31))).map(+)
            samples += gap
            expected += length
        }
        samples += Signal.noise(seconds: 0.5, rms: Signal.dbToAmplitude(-58), seed: 99)

        let stats = SpeechAnalyzer.stats(for: samples)
        #expect(!stats.isSilent)
        // Raised-cosine edges spend part of each syllable below the +10 dB threshold.
        #expect(stats.voicedSeconds > expected * 0.7 && stats.voicedSeconds <= expected, "voiced \(stats.voicedSeconds) of \(expected)")
        #expect(stats.voicedSeconds >= 0.25)
    }

    @Test func keyClicksAreIgnored() {
        var samples = Signal.noise(seconds: 2, rms: Signal.dbToAmplitude(-60))
        for start in [4_000, 12_000, 24_000] {
            for i in 0..<320 { samples[start + i] += 0.4 * Float(exp(-Double(i) / 60)) * (i % 2 == 0 ? 1 : -1) }
        }
        #expect(SpeechAnalyzer.stats(for: samples).voicedSeconds < 0.05)
    }

    @Test func duckedGapsDoNotLowerTheFloor() {
        // A zeroed (ducked) stretch next to steady noise must not turn the noise into "speech".
        let noise = Signal.noise(seconds: 2, rms: Signal.dbToAmplitude(-50))
        let stats = SpeechAnalyzer.stats(for: [Float](repeating: 0, count: 8_000) + noise)
        #expect(stats.voicedSeconds < 0.1)
    }

    @Test func longRecordingsAnalyzeQuickly() {
        let samples = Signal.noise(seconds: 300, rms: 0.01)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = SpeechAnalyzer.stats(for: samples) }
        #expect(elapsed < .seconds(3))
    }
}

// MARK: - Level meter

/// Manually advanced clock for deterministic meter tests.
private final class MeterTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval
    init(_ start: TimeInterval = 1_000) { value = start }
    var now: TimeInterval {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@Suite struct LevelMeterTests {
    @Test func perceptualMapping() {
        #expect(LevelMeter.perceptual(db: -50, floor: -50, ceiling: -12) == 0)
        #expect(LevelMeter.perceptual(db: -80, floor: -50, ceiling: -12) == 0)
        #expect(LevelMeter.perceptual(db: -12, floor: -50, ceiling: -12) == 1)
        #expect(LevelMeter.perceptual(db: 0, floor: -50, ceiling: -12) == 1)
        let mid = LevelMeter.perceptual(db: -31, floor: -50, ceiling: -12)
        #expect(abs(mid - pow(0.5, 0.7)) < 1e-5)
        #expect(LevelMeter.perceptual(db: -40, floor: -50) < LevelMeter.perceptual(db: -30, floor: -50))
    }

    private func feed(_ meter: LevelMeter, clock: MeterTestClock, db: Float, seconds: Double) {
        let steps = Int((seconds * 100).rounded())
        for _ in 0..<steps {
            clock.now += 0.01
            meter.ingest(rmsDBFS: db, at: clock.now)
        }
    }

    @Test func adaptiveFloorIsClamped() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        feed(meter, clock: clock, db: -90, seconds: 1)
        #expect(meter.noiseFloorDBFS == -60)
        feed(meter, clock: clock, db: -52, seconds: 2)
        #expect(abs(meter.noiseFloorDBFS - -46) < 0.01)
        feed(meter, clock: clock, db: -30, seconds: 2)
        #expect(meter.noiseFloorDBFS == -40)
    }

    @Test func attackAndReleaseFollowTheSpec() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        feed(meter, clock: clock, db: -75, seconds: 1.5)
        #expect(meter.level(at: clock.now) < 0.01)

        let target = LevelMeter.perceptual(db: -20, floor: meter.noiseFloorDBFS)
        feed(meter, clock: clock, db: -20, seconds: 0.04)
        let afterAttack = meter.level(at: clock.now)
        #expect(abs(afterAttack / target - 0.63) < 0.08, "one attack time constant ≈ 63 %, got \(afterAttack / target)")
        feed(meter, clock: clock, db: -20, seconds: 0.26)
        let settled = meter.level(at: clock.now)
        #expect(abs(settled - target) < 0.02)

        feed(meter, clock: clock, db: -75, seconds: 0.14)
        let afterRelease = meter.level(at: clock.now)
        #expect(abs(afterRelease / settled - 0.37) < 0.08, "one release time constant ≈ 37 %, got \(afterRelease / settled)")
    }

    @Test func readsBehindTheNewestAudio() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        feed(meter, clock: clock, db: -75, seconds: 1)
        feed(meter, clock: clock, db: -15, seconds: 0.08)
        // The loud part is younger than the 120 ms read-behind: the UI still shows the quiet past.
        #expect(meter.level < 0.05)
        #expect(meter.level == meter.level(at: clock.now - meter.tuning.readBehind))
        clock.now += 0.12
        #expect(meter.level > 0.3)
    }

    @Test func interpolatesBetweenWindows() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        feed(meter, clock: clock, db: -75, seconds: 0.5)
        feed(meter, clock: clock, db: -20, seconds: 0.2)
        let a = meter.level(at: clock.now - 0.05)
        let b = meter.level(at: clock.now - 0.045)
        let c = meter.level(at: clock.now - 0.04)
        #expect(a <= b && b <= c)
    }

    @Test func stalledInputDecaysInsteadOfFreezing() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        feed(meter, clock: clock, db: -75, seconds: 1)
        feed(meter, clock: clock, db: -18, seconds: 0.5)
        let live = meter.level(at: clock.now)
        #expect(meter.level(at: clock.now + 0.05) == live)
        #expect(meter.level(at: clock.now + 0.6) < live * 0.1)
    }

    @Test func tracksAudioAndVoice() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        #expect(!meter.hasReceivedAudio)
        #expect(meter.secondsSinceVoice == 0)
        #expect(meter.level == 0)

        feed(meter, clock: clock, db: -70, seconds: 1)
        #expect(meter.hasReceivedAudio)
        #expect(meter.secondsSinceVoice > 0.8)            // nobody spoke yet: time since audio started

        feed(meter, clock: clock, db: -22, seconds: 0.3)
        feed(meter, clock: clock, db: -70, seconds: 1.5)
        clock.now += 0.12
        #expect(abs(meter.secondsSinceVoice - 1.5) < 0.05)

        meter.reset()
        #expect(!meter.hasReceivedAudio)
        #expect(meter.level == 0)
    }

    @Test func previewMovesAroundTheRequestedLevel() {
        let meter = LevelMeter.preview(level: 0.6)
        #expect(meter.hasReceivedAudio)
        #expect(meter.secondsSinceVoice == 0)
        let values = stride(from: 0.0, to: 3.0, by: 0.05).map { meter.level(at: $0) }
        #expect(values.allSatisfy { $0 >= 0.6 * 0.79 && $0 <= 0.6 })
        #expect(Set(values.map { ($0 * 100).rounded() }).count > 5)
        #expect(LevelMeter.preview(level: 0).level == 0)
        #expect(LevelMeter.preview(level: 0.5, animated: false).level == 0.5)
        #expect(!LevelMeter.preview(level: 0, animated: false, hasReceivedAudio: false).hasReceivedAudio)

        meter.ingest(rmsDBFS: -10, at: 5)
        meter.reset()
        #expect(meter.hasReceivedAudio)
    }

    @Test func previewSpeaksInBurstsWithPauses() {
        let meter = LevelMeter.preview(level: 0.6)
        let columns = stride(from: 0.0, to: 6.8, by: 0.087).map { meter.voiceAmplitude(from: $0, to: $0 + 0.087) }
        #expect(columns.contains(0))                      // pauses between phrases
        #expect(columns.filter { $0 >= 0.5 }.count > 20)  // and plenty of voice
        #expect(Set(columns.map { ($0 * 20).rounded() }).count > 6)
        #expect(columns == stride(from: 0.0, to: 6.8, by: 0.087).map { meter.voiceAmplitude(from: $0, to: $0 + 0.087) })
        #expect(LevelMeter.preview(level: 0).voiceAmplitude(from: 1, to: 2) == 0)
        #expect(LevelMeter.preview(level: 0.5, animated: false).voiceAmplitude(from: 1, to: 2) == 0.5)
    }
}

// MARK: - Voice gate (pill equalizer)

@Suite struct VoiceGateTests {
    /// Seeded LCG so "random" fluctuation is the same on every run.
    private struct Noise {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        /// Uniform in `center ± spread`.
        mutating func db(_ center: Float, _ spread: Float) -> Float {
            center + spread * Float(2 * next() - 1)
        }
        /// Normal around `center`: deep dips as well as peaks, like a rumble's 10 ms windows.
        mutating func gaussian(_ center: Float, sd: Float) -> Float {
            let u = max(1e-12, next()), v = next()
            return center + sd * Float((-2 * log(u)).squareRoot() * cos(2 * .pi * v))
        }
    }

    /// Two levels played at once.
    private static func mix(_ a: Float, _ b: Float) -> Float {
        10 * log10(pow(10, a / 10) + pow(10, b / 10))
    }

    /// Feeds 10 ms windows and returns each window's gated amplitude as the UI reads it, 100 ms later (so the
    /// gate's onset back-fill counts, as it does behind the read-behind).
    @discardableResult
    private func feed(_ meter: LevelMeter, clock: MeterTestClock, seconds: Double,
                      db: (_ elapsed: Double) -> Float) -> [(elapsed: Double, amplitude: Float)] {
        var pending: [(elapsed: Double, time: Double)] = []
        var read: [(elapsed: Double, amplitude: Float)] = []
        func readOldest() {
            let window = pending.removeFirst()
            read.append((window.elapsed, meter.voiceAmplitude(from: window.time - 0.005, to: window.time + 0.005)))
        }
        for step in 0..<Int((seconds * 100).rounded()) {
            clock.now += 0.01
            meter.ingest(rmsDBFS: db(Double(step) * 0.01), at: clock.now)
            pending.append((Double(step) * 0.01, clock.now))
            if pending.count > 10 { readOldest() }
        }
        while !pending.isEmpty { readOldest() }
        return read
    }

    /// Syllables of 120-250 ms at `loud` dBFS with 60-120 ms gaps of `quiet` noise.
    private struct Speech {
        struct Syllable { var start: Double; var end: Double; var db: Float }
        var syllables: [Syllable] = []
        var gaps: [(start: Double, end: Double)] = []
        let length: Double

        init(seconds: Double, loud: ClosedRange<Float>, noise: inout Noise) {
            var cursor = 0.0
            while cursor < seconds {
                let length = 0.12 + 0.13 * noise.next()
                let db = loud.lowerBound + (loud.upperBound - loud.lowerBound) * Float(noise.next())
                syllables.append(Syllable(start: cursor, end: min(seconds, cursor + length), db: db))
                cursor += length
                let gap = 0.06 + 0.06 * noise.next()
                if cursor < seconds { gaps.append((cursor, min(seconds, cursor + gap))) }
                cursor += gap
            }
            self.length = seconds
        }

        func db(at t: Double) -> Float? {
            syllables.first { t >= $0.start && t < $0.end }?.db
        }
    }

    @Test func steadyRoomNoiseNeverOpensTheGate() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        var noise = Noise(state: 1)
        let windows = feed(meter, clock: clock, seconds: 5) { _ in noise.db(-50, 4) }
        #expect(windows.allSatisfy { $0.amplitude == 0 })
        #expect(meter.voiceAmplitude(from: clock.now - 1.3, to: clock.now) == 0)
    }

    @Test func fanNoiseNeverOpensTheGate() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        var noise = Noise(state: 2)
        let windows = feed(meter, clock: clock, seconds: 5) { _ in noise.db(-42, 3) }
        #expect(windows.allSatisfy { $0.amplitude == 0 })
    }

    @Test func keyboardClicksDontOpenTheGate() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        var noise = Noise(state: 3)
        feed(meter, clock: clock, seconds: 1) { _ in noise.db(-50, 2) }
        // A 10 or 20 ms click every 170-330 ms, like typing.
        var clicks: [(start: Double, end: Double)] = []
        var cursor = 0.05
        while cursor < 4 {
            clicks.append((cursor, cursor + (noise.next() < 0.5 ? 0.01 : 0.02) - 0.001))
            cursor += 0.17 + 0.16 * noise.next()
        }
        let windows = feed(meter, clock: clock, seconds: 4) { t in
            clicks.contains { t >= $0.start && t < $0.end } ? -25 : noise.db(-50, 2)
        }
        #expect(windows.allSatisfy { $0.amplitude == 0 })
    }

    @Test func ringingKeyClicksDontOpenTheGate() {
        for (peak, decay) in [(Float(-20), Float(6)), (-30, 5)] {
            let clock = MeterTestClock()
            let meter = LevelMeter(clock: { clock.now })
            var noise = Noise(state: 8)
            feed(meter, clock: clock, seconds: 1) { _ in noise.db(-50, 2) }
            // Clicks that ring for 30-50 ms above the room, every 170-330 ms.
            var clicks: [Double] = []
            var cursor = 0.05
            while cursor < 4 {
                clicks.append(cursor)
                cursor += 0.17 + 0.16 * noise.next()
            }
            let windows = feed(meter, clock: clock, seconds: 4) { t in
                var db = noise.db(-50, 2)
                for click in clicks where t >= click && t < click + 0.2 {
                    db = Self.mix(db, peak - decay * Float(((t - click) / 0.01).rounded(.down)))
                }
                return db
            }
            #expect(windows.allSatisfy { $0.amplitude == 0 }, "clicks at \(peak) dBFS ringing \(decay) dB per 10 ms")
        }
    }

    @Test func aFanSwitchingOnSettlesWithinTwoSeconds() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        var noise = Noise(state: 9)
        feed(meter, clock: clock, seconds: 2) { _ in noise.gaussian(-60, sd: 1.5) }
        let windows = feed(meter, clock: clock, seconds: 6) { _ in noise.gaussian(-45, sd: 1.5) }
        let settled = windows.filter { $0.elapsed >= 2 }
        #expect(settled.allSatisfy { $0.amplitude == 0 }, "still moving \(settled.filter { $0.amplitude > 0 }.count) windows later")
    }

    @Test(arguments: [UInt64(10), 11, 12, 13])
    func rumbleWithDeepDipsNeitherOpensNorLatchesTheGate(seed: UInt64) {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        var noise = Noise(state: seed)
        let idle = feed(meter, clock: clock, seconds: 10) { _ in noise.gaussian(-48, sd: 3.5) }
        #expect(idle.allSatisfy { $0.amplitude == 0 })
        let speech = Speech(seconds: 2, loud: -28 ... -18, noise: &noise)
        feed(meter, clock: clock, seconds: 2) { t in speech.db(at: t) ?? noise.gaussian(-48, sd: 3.5) }
        let after = feed(meter, clock: clock, seconds: 5) { _ in noise.gaussian(-48, sd: 3.5) }
        #expect(after.filter { $0.elapsed >= 0.5 }.allSatisfy { $0.amplitude == 0 }, "the gate closes once the speech ends")
    }

    @Test func speechOpensTheGateAndHoldsThroughSyllableGaps() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        var noise = Noise(state: 4)
        feed(meter, clock: clock, seconds: 1) { _ in noise.db(-50, 2) }
        let speech = Speech(seconds: 3, loud: -28 ... -18, noise: &noise)
        let windows = feed(meter, clock: clock, seconds: 3) { t in speech.db(at: t) ?? noise.db(-50, 2) }
        for window in windows {
            let t = window.elapsed
            if speech.db(at: t) != nil {
                #expect(window.amplitude >= 0.4, "syllable at \(t) s drew \(window.amplitude)")
            } else {
                #expect(window.amplitude > 0, "the gate closed in a syllable gap at \(t) s")
            }
        }
        // After the speech, the hangover runs out and the bars fall back to dots.
        let tail = feed(meter, clock: clock, seconds: 1) { _ in noise.db(-50, 2) }
        #expect(tail.suffix(70).allSatisfy { $0.amplitude == 0 })
    }

    @Test func longSpeechNeverClosesTheGate() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        var noise = Noise(state: 5)
        feed(meter, clock: clock, seconds: 1) { _ in noise.db(-50, 2) }
        let speech = Speech(seconds: 20, loud: -28 ... -18, noise: &noise)
        let windows = feed(meter, clock: clock, seconds: 20) { t in speech.db(at: t) ?? noise.db(-50, 2) }
        #expect(windows.allSatisfy { $0.amplitude > 0 })
    }

    @Test func quietSpeechOverAQuietRoomIsVisible() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        var noise = Noise(state: 6)
        feed(meter, clock: clock, seconds: 1) { _ in noise.db(-60, 2) }
        let speech = Speech(seconds: 3, loud: -40 ... -40, noise: &noise)
        let windows = feed(meter, clock: clock, seconds: 3) { t in speech.db(at: t) ?? noise.db(-60, 2) }
        for window in windows where speech.db(at: window.elapsed) != nil {
            #expect(window.amplitude >= 0.25)
        }
    }

    @Test func typicalSpeechLandsInTheUpperHalf() {
        #expect(abs(LevelMeter.eqAmplitude(rms: pow(10, -35 / 20)) - 0.43) < 0.02)
        #expect(LevelMeter.eqAmplitude(rms: pow(10, -15 / 20)) == 1)
        #expect(LevelMeter.eqAmplitude(rms: 0) == 0)
        // debilgpt's original curve.
        #expect(abs(LevelMeter.eqAmplitude(rms: 0.05, gain: 9) - pow(0.45, 0.55)) < 1e-6)
    }

    @Test func digitalSilenceAtStartDoesNotPinTheFloor() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        var noise = Noise(state: 7)
        // A device that opens on zeros, then settles into ordinary room noise.
        feed(meter, clock: clock, seconds: 0.3) { _ in -160 }
        let windows = feed(meter, clock: clock, seconds: 3) { _ in noise.db(-48, 3) }
        #expect(windows.allSatisfy { $0.amplitude == 0 })
    }

    @Test func shortSyllablesAfterABreathReopenTheGate() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        var noise = Noise(state: 14)
        feed(meter, clock: clock, seconds: 1) { _ in noise.db(-50, 2) }
        feed(meter, clock: clock, seconds: 0.8) { _ in noise.db(-30, 3) }
        // A breath long enough to close the gate ...
        let breath = feed(meter, clock: clock, seconds: 0.3) { _ in noise.db(-50, 2) }
        #expect(breath.suffix(3).allSatisfy { $0.amplitude == 0 })
        // ... then fast syllables only 50 ms loud each, too short for a cold onset.
        let syllables = feed(meter, clock: clock, seconds: 0.64) { t in
            t.truncatingRemainder(dividingBy: 0.08) < 0.05 ? noise.db(-30, 2) : noise.db(-50, 2)
        }
        #expect(syllables.allSatisfy { $0.amplitude > 0 }, "\(syllables.filter { $0.amplitude == 0 }.count) windows dropped")
    }

    @Test func aClickNeverArmsTheQuickReopen() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        var noise = Noise(state: 15)
        feed(meter, clock: clock, seconds: 1) { _ in noise.db(-50, 2) }
        // A thud that rings just long enough to open the gate, then closes it again ...
        feed(meter, clock: clock, seconds: 0.06) { _ in -25 }
        feed(meter, clock: clock, seconds: 0.3) { _ in noise.db(-50, 2) }
        // ... must not let 40 ms taps right after it through.
        let taps = feed(meter, clock: clock, seconds: 0.5) { t in
            t.truncatingRemainder(dividingBy: 0.1) < 0.04 ? -25 : noise.db(-50, 2)
        }
        #expect(taps.allSatisfy { $0.amplitude == 0 })
    }

    @Test func aKeyThatRingsAsLongAsASyllableNeverArmsTheQuickReopen() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        var noise = Noise(state: 18)
        feed(meter, clock: clock, seconds: 1) { _ in noise.db(-50, 2) }
        // A struck key rings down 2 dB every 10 ms: it opens the gate and stays 6 dB over the floor for 120 ms,
        // as long as a syllable, but never holds its level the way a vowel does ...
        let ring = feed(meter, clock: clock, seconds: 0.14) { t in Self.mix(noise.db(-50, 2), -20 - 200 * Float(t)) }
        #expect(ring.contains { $0.amplitude > 0 })
        feed(meter, clock: clock, seconds: 0.3) { _ in noise.db(-50, 2) }
        // ... so 40 ms taps right after it stay out.
        let taps = feed(meter, clock: clock, seconds: 0.5) { t in
            t.truncatingRemainder(dividingBy: 0.1) < 0.04 ? -25 : noise.db(-50, 2)
        }
        #expect(taps.allSatisfy { $0.amplitude == 0 }, "\(taps.filter { $0.amplitude > 0 }.count) windows drawn")
    }

    @Test func oneShortSteadyVowelArmsTheQuickReopen() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        var noise = Noise(state: 19)
        feed(meter, clock: clock, seconds: 1) { _ in noise.db(-60, 2) }
        // A quiet speaker's one-syllable word: 80 ms, holding its level within a couple of dB ...
        feed(meter, clock: clock, seconds: 0.08) { _ in noise.db(-40, 1) }
        // ... a breath that closes the gate ...
        let breath = feed(meter, clock: clock, seconds: 0.3) { _ in noise.db(-60, 2) }
        #expect(breath.suffix(3).allSatisfy { $0.amplitude == 0 })
        // ... then syllables only 50 ms loud each, too short for a cold onset.
        let syllables = feed(meter, clock: clock, seconds: 0.64) { t in
            t.truncatingRemainder(dividingBy: 0.08) < 0.05 ? noise.db(-40, 1) : noise.db(-60, 2)
        }
        #expect(syllables.allSatisfy { $0.amplitude > 0 }, "\(syllables.filter { $0.amplitude == 0 }.count) windows dropped")
    }

    @Test func typingThatHeldTheGateOpenNeverArmsTheQuickReopen() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        var noise = Noise(state: 17)
        feed(meter, clock: clock, seconds: 1) { _ in noise.db(-50, 2) }
        // A ringing key fools the gate, and the clicks after it hold it open for half a second ...
        feed(meter, clock: clock, seconds: 0.06) { _ in -25 }
        feed(meter, clock: clock, seconds: 0.48) { t in t.truncatingRemainder(dividingBy: 0.12) >= 0.08 ? -25 : noise.db(-50, 2) }
        // ... then a pause closes it: the next burst of 40 ms clicks must not reopen it.
        feed(meter, clock: clock, seconds: 0.3) { _ in noise.db(-50, 2) }
        let clicks = feed(meter, clock: clock, seconds: 0.5) { t in
            t.truncatingRemainder(dividingBy: 0.1) < 0.04 ? -25 : noise.db(-50, 2)
        }
        #expect(clicks.allSatisfy { $0.amplitude == 0 }, "\(clicks.filter { $0.amplitude > 0 }.count) windows drawn")
    }

    @Test func aCueDuckedOverSpeechKeepsTheBars() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        let plain = LevelMeter(clock: { clock.now })
        var noise = Noise(state: 16)
        func both(seconds: Double, ducked: Bool = false, db: () -> Float) {
            for _ in 0..<Int((seconds * 100).rounded()) {
                clock.now += 0.01
                let level = db()
                meter.ingest(rmsDBFS: level, at: clock.now, ducked: ducked)
                plain.ingest(rmsDBFS: level, at: clock.now)
            }
        }
        both(seconds: 1) { noise.db(-50, 2) }
        both(seconds: 0.5) { noise.db(-25, 2) }
        // The hands-free lock ping plays mid-word: the capture path pulls the voice 30 dB down for 250 ms.
        let duck = clock.now
        both(seconds: 0.25, ducked: true) { noise.db(-55, 2) }
        both(seconds: 0.2) { noise.db(-25, 2) }
        for step in stride(from: 0.0, to: 0.25, by: 0.05) {
            #expect(meter.voiceAmplitude(from: duck + step, to: duck + step + 0.05) > 0.5, "dropped at +\(step) s")
        }
        // The ping only bypasses the gate: the level, the floor and silence detection see the audio as it is.
        #expect(meter.level(at: duck + 0.2) == plain.level(at: duck + 0.2))
        #expect(meter.noiseFloorDBFS == plain.noiseFloorDBFS)
        #expect(meter.secondsSinceVoice == plain.secondsSinceVoice)
    }

    @Test func settledTimeTrailsTheOnsetProof() throws {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        #expect(meter.settledTime == nil)
        feed(meter, clock: clock, seconds: 1) { _ in -50 }
        // The next window can still mark the 5 before it as an onset.
        let settled = try #require(meter.settledTime)
        #expect(abs(settled - (clock.now - 0.04)) < 1e-9)
        #expect(LevelMeter.preview(level: 0.5).settledTime == .infinity)
    }

    @Test func resetForgetsTheGate() {
        let clock = MeterTestClock()
        let meter = LevelMeter(clock: { clock.now })
        feed(meter, clock: clock, seconds: 0.5) { _ in -55 }
        feed(meter, clock: clock, seconds: 0.5) { _ in -20 }
        #expect(meter.voiceAmplitude(from: clock.now - 0.3, to: clock.now + 0.01) > 0.5)
        meter.reset()
        #expect(meter.voiceAmplitude(from: clock.now - 0.3, to: clock.now + 0.01) == 0)
    }
}

// MARK: - Capture pipeline (synthetic buffers)

@Suite struct CaptureStateTests {
    private static let device = AudioInputDevice(id: "test", name: "Test Mic", transport: .builtIn, isAvailable: true)

    /// Feeds `seconds` of a 48 kHz stereo tone in 100 ms chunks stamped from `start`.
    private func feed(_ state: inout CaptureState, seconds: Double, start: TimeInterval,
                      amplitude: Float = 0.5) -> [(time: TimeInterval, db: Float, ducked: Bool)] {
        let tone = Signal.sine(700, seconds: seconds, rate: 48_000, amplitude: amplitude)
        var levels: [(time: TimeInterval, db: Float, ducked: Bool)] = []
        for (index, chunk) in Signal.chunks(of: [tone, tone], rate: 48_000, sizes: [4_800]).enumerated() {
            let outcome = state.ingest(chunk, chunkStart: start + Double(index) * 0.1, arrival: start + Double(index + 1) * 0.1)
            levels += outcome.levels
        }
        return levels
    }

    @Test func convertsAndMetersEveryTenMilliseconds() {
        var state = CaptureState(device: Self.device, keepsSamples: true)
        let levels = feed(&state, seconds: 1, start: 100)
        #expect(state.firstArrival == 100.1)
        #expect(levels.count >= 98 && levels.count <= 100, "\(levels.count) level points")
        let steps = zip(levels.dropFirst(), levels).map { $0.time - $1.time }
        #expect(steps.allSatisfy { abs($0 - 0.01) < 1e-6 })
        #expect(levels.dropFirst(2).allSatisfy { abs($0.db - 20 * log10(0.5 / 2.0.squareRoot().float)) < 0.5 })

        let samples = state.finalize(discard: false)
        #expect(abs(samples.count - 16_000) <= 16)
        #expect(state.phase == .finished)
        #expect(state.finalize(discard: false).isEmpty)
    }

    @Test func monitoringKeepsNothing() {
        var state = CaptureState(device: Self.device, keepsSamples: false)
        let levels = feed(&state, seconds: 0.5, start: 0)
        #expect(!levels.isEmpty)
        #expect(state.finalize(discard: false).isEmpty)
    }

    @Test func ducksUpcomingAndPastWindows() {
        var state = CaptureState(device: Self.device, keepsSamples: true)
        let gain = pow(10, AudioRecorder.duckAttenuationDB / 20)
        state.addDuck(DuckWindow(start: 10.30, end: 10.50, gain: gain))       // before the audio arrives
        _ = feed(&state, seconds: 1, start: 10)
        state.addDuck(DuckWindow(start: 10.70, end: 10.80, gain: gain))       // after it was captured
        let samples = state.finalize(discard: false)

        let open = Signal.rmsDB(samples[1_600..<4_000])
        let ducked = Signal.rmsDB(samples[5_000..<7_800])
        let late = Signal.rmsDB(samples[11_400..<12_600])
        #expect(abs((open - ducked) - 30) < 1.5)
        #expect(abs((open - late) - 30) < 1.5)
        #expect(abs(open - Signal.rmsDB(samples[13_500..<15_000])) < 0.5)
    }

    @Test func tagsTheMeterWindowsADuckTouches() {
        var state = CaptureState(device: Self.device, keepsSamples: false)
        let gain = pow(10, AudioRecorder.duckAttenuationDB / 20)
        state.addDuck(DuckWindow(start: 10.30, end: 10.50, gain: gain))
        let levels = feed(&state, seconds: 1, start: 10)
        let ducked = levels.filter { $0.ducked }
        #expect(ducked.count >= 20 && ducked.count <= 22)
        #expect(ducked.allSatisfy { $0.time > 10.295 && $0.time < 10.515 })
        let covered = levels.filter { $0.time > 10.31 && $0.time <= 10.50 }
        #expect(covered.allSatisfy { $0.ducked })
    }

    @Test func duckWindowRamps() {
        let window = DuckWindow(start: 1, end: 2, gain: 0.03)
        #expect(window.gain(at: 0.9) == 1)
        #expect(window.gain(at: 1.5) == 0.03)
        #expect(abs(window.gain(at: 1 - DuckWindow.ramp / 2) - (0.03 + 0.97 / 2)) < 1e-4)
        #expect(window.gain(at: 2.1) == 1)
    }

    @Test func tailStopsAtTheRequestedInstant() {
        var state = CaptureState(device: Self.device, keepsSamples: true)
        _ = feed(&state, seconds: 0.5, start: 50)
        state.phase = .tail(until: 50.65)
        let tone = Signal.sine(700, seconds: 0.4, rate: 48_000, amplitude: 0.5)
        var final: [Float]?
        for (index, chunk) in Signal.chunks(of: [tone], rate: 48_000, sizes: [4_800]).enumerated() {
            let outcome = state.ingest(chunk, chunkStart: 50.5 + Double(index) * 0.1, arrival: 0)
            if !outcome.finalSamples.isEmpty {
                final = outcome.finalSamples
                break
            }
        }
        #expect(abs((final?.count ?? 0) - Int(0.65 * 16_000)) <= 16)
        #expect(state.phase == .finished)
    }

    @Test func tapBufferPrefixCopiesFrames() throws {
        let left = (0..<100).map { Float($0) }
        let source = Signal.buffer(channels: [left, left.map { -$0 }], rate: 48_000)
        let prefix = try #require(CaptureState.prefix(of: source, frames: 10))
        #expect(prefix.frameLength == 10)
        #expect(prefix.floatChannelData![0][9] == 9)
        #expect(prefix.floatChannelData![1][9] == -9)
        #expect(source.frameLength == 100)
    }
}

// MARK: - Capture session (tap path driven with synthetic buffers; the engine is never started)

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var results: [[Float]] = []

    func record(_ event: CaptureSessionEvent) {
        let name = switch event {
        case .firstBuffer: "firstBuffer"
        case .switchedDevice: "switchedDevice"
        case .deviceLost: "deviceLost"
        case .startFailed: "startFailed"
        case .noAudio: "noAudio"
        }
        lock.withLock { events.append(name) }
    }

    func complete(_ samples: [Float]) { lock.withLock { results.append(samples) } }
    var names: [String] { lock.withLock { events } }
    var completions: [[Float]] { lock.withLock { results } }
}

@Suite struct CaptureSessionTests {
    private func makeSession(log: EventLog, meter: LevelMeter? = nil, timeout: TimeInterval = 2) -> CaptureSession {
        let device = AudioInputDevice(id: "synthetic", name: "Synthetic Mic", transport: .usb, isAvailable: true)
        var options = CaptureSession.Options(preferredUID: nil)
        options.firstBufferTimeout = timeout
        return CaptureSession(device: CoreAudioHAL.InputRecord(device: device, audioID: 0), options: options,
                              meter: meter, onEvent: { log.record($0) })
    }

    private func chunk(_ seconds: Double = 0.1) -> AVAudioPCMBuffer {
        let tone = Signal.sine(300, seconds: seconds, rate: 48_000, amplitude: 0.3)
        return Signal.buffer(channels: [tone], rate: 48_000)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func tailKeepsListeningPastTheStopRequest() async throws {
        let log = EventLog()
        let meter = LevelMeter()
        let session = makeSession(log: log, meter: meter)
        let t0 = AudioClock.now() - 1.0
        for k in 0..<10 { session.receive(chunk(), chunkStart: t0 + Double(k) * 0.1, arrival: t0 + Double(k + 1) * 0.1) }
        #expect(log.names == ["firstBuffer"])
        #expect(meter.hasReceivedAudio)

        let stopRequested = AudioClock.now()
        session.finish(tail: AudioRecorder.stopTail) { log.complete($0) }
        session.receive(chunk(), chunkStart: t0 + 1.0, arrival: AudioClock.now())
        #expect(log.completions.isEmpty)
        session.receive(chunk(), chunkStart: t0 + 1.1, arrival: AudioClock.now())
        session.receive(chunk(), chunkStart: t0 + 1.2, arrival: AudioClock.now())

        #expect(log.completions.count == 1)
        let expected = (stopRequested + AudioRecorder.stopTail - t0) * Recording.sampleRate
        let count = Double(log.completions.first?.count ?? 0)
        #expect(abs(count - expected) < 0.03 * Recording.sampleRate, "\(count) vs \(expected)")
        #expect(session.finishNow(discard: false).isEmpty)
        #expect(log.completions.count == 1)
    }

    @Test func tailTimesOutWhenAudioStops() async throws {
        let log = EventLog()
        let session = makeSession(log: log)
        let t0 = AudioClock.now() - 0.5
        for k in 0..<5 { session.receive(chunk(), chunkStart: t0 + Double(k) * 0.1, arrival: t0) }
        session.finish(tail: 0.1) { log.complete($0) }
        try await waitUntil { !log.completions.isEmpty }
        #expect(log.completions.count == 1)
        #expect(abs((log.completions.first?.count ?? 0) - 8_000) <= 16)
    }

    @Test func noBufferWithinTheTimeoutReportsNoAudio() async throws {
        let log = EventLog()
        let session = makeSession(log: log, timeout: 0.1)
        session.armStartTimeout()
        try await waitUntil { log.names.contains("noAudio") }
        #expect(log.names == ["noAudio"])
        #expect(session.finishNow(discard: false).isEmpty)
    }

    /// Released before a slow (Bluetooth) mic delivered anything: the start timeout ends the session and
    /// must still answer the stop that is waiting for its tail, or `AudioRecorder.finish` never returns.
    @Test func startTimeoutAnswersAStopWaitingForItsTail() async throws {
        let log = EventLog()
        let session = makeSession(log: log, timeout: 0.1)
        session.armStartTimeout()
        session.finish(tail: 5) { log.complete($0) }
        try await waitUntil { !log.completions.isEmpty }
        #expect(log.completions == [[]])
        #expect(log.names == ["noAudio"])
    }

    @Test func finalizeHandsOverAPendingStop() {
        var state = CaptureState(device: AudioInputDevice(id: "x", name: "X", transport: .usb, isAvailable: true),
                                 keepsSamples: true)
        state.phase = .tail(until: 1)
        state.tailCompletion = { _ in }
        let (samples, completion) = state.finalizeTakingCompletion(discard: true)
        #expect(samples.isEmpty)
        #expect(completion != nil)
        #expect(state.tailCompletion == nil)
        #expect(state.phase == .finished)
        #expect(state.finalizeTakingCompletion(discard: false).completion == nil)
    }

    @Test func audioBeforeTheTimeoutKeepsTheSession() async throws {
        let log = EventLog()
        let session = makeSession(log: log, timeout: 0.1)
        session.armStartTimeout()
        session.receive(chunk(), chunkStart: AudioClock.now(), arrival: AudioClock.now())
        try await Task.sleep(for: .milliseconds(250))
        #expect(log.names == ["firstBuffer"])
        #expect(abs(session.finishNow(discard: false).count - 1_600) <= 16)
    }

    @Test func cancelDiscardsAndStopsListening() {
        let log = EventLog()
        let session = makeSession(log: log)
        session.receive(chunk(), chunkStart: 5, arrival: 5)
        #expect(session.finishNow(discard: true).isEmpty)
        session.receive(chunk(), chunkStart: 5.1, arrival: 5.1)
        #expect(session.capturedDuration == 0)
    }
}

// MARK: - Devices

@Suite struct InputDevicePolicyTests {
    private let builtIn = AudioInputDevice(id: "builtin", name: "MacBook Pro Microphone", transport: .builtIn, isAvailable: true)
    private let airPods = AudioInputDevice(id: "airpods", name: "AirPods Pro", transport: .bluetooth, isAvailable: true)
    private let usb = AudioInputDevice(id: "usb", name: "Shure MV7+", transport: .usb, isAvailable: true)
    private let blackHole = AudioInputDevice(id: "blackhole", name: "BlackHole 2ch", transport: .virtual, isAvailable: true)

    private func choose(_ preferred: String?, _ def: String?, _ devices: [AudioInputDevice], preferBuiltIn: Bool = true) -> InputDeviceChoice? {
        InputDevicePolicy.choose(preferredUID: preferred, defaultUID: def, devices: devices, preferBuiltInOverBluetooth: preferBuiltIn)
    }

    @Test func savedDeviceWins() {
        #expect(choose("usb", "builtin", [builtIn, usb]) == InputDeviceChoice(device: usb, reason: .selected))
        #expect(choose("airpods", "builtin", [builtIn, airPods])?.device == airPods)
        #expect(choose("blackhole", "builtin", [builtIn, blackHole])?.device == blackHole)
    }

    @Test func missingSavedDeviceFallsBackToDefault() {
        #expect(choose("usb", "builtin", [builtIn]) == InputDeviceChoice(device: builtIn, reason: .fallback(unavailableUID: "usb")))
    }

    @Test func bluetoothDefaultPrefersBuiltIn() {
        #expect(choose(nil, "airpods", [builtIn, airPods]) == InputDeviceChoice(device: builtIn, reason: .builtInInsteadOfBluetooth))
        #expect(choose(nil, "airpods", [builtIn, airPods], preferBuiltIn: false)?.device == airPods)
        #expect(choose(nil, "airpods", [airPods])?.device == airPods)
    }

    @Test func virtualDevicesAreNeverAutoPicked() {
        #expect(choose(nil, "blackhole", [blackHole, builtIn])?.device == builtIn)
        #expect(choose(nil, "blackhole", [blackHole]) == nil)
    }

    @Test func unavailableDevicesAreSkipped() {
        var closedLid = builtIn
        closedLid.isAvailable = false
        closedLid.unavailableReason = "Lid is closed"
        #expect(choose(nil, "builtin", [closedLid, airPods])?.device == airPods)
        #expect(choose(nil, "builtin", [closedLid, airPods, usb])?.device == usb)
        #expect(choose("builtin", nil, [closedLid]) == nil)
    }

    @Test func systemDefaultIsUsedAsIs() {
        #expect(choose(nil, "usb", [builtIn, usb]) == InputDeviceChoice(device: usb, reason: .systemDefault))
        #expect(choose(nil, nil, [airPods, usb])?.device == usb)
    }

    @Test func symbolsFollowTheDevice() {
        #expect(builtIn.symbolName == "laptopcomputer")
        #expect(airPods.symbolName == "airpodspro")
        #expect(usb.symbolName == "mic")
    }
}

@Suite struct AudioDeviceEnumerationTests {
    @Test func enumeratesInputDevices() {
        let records = CoreAudioHAL.inputRecords()
        let uids = records.map(\.device.id)
        #expect(Set(uids).count == uids.count)
        #expect(records.allSatisfy { !$0.device.id.isEmpty && !$0.device.name.isEmpty && $0.audioID != 0 })
        for record in records where record.device.name == "MacBook Pro Microphone" {
            #expect(record.device.transport == .builtIn)
            #expect(CoreAudioHAL.deviceID(forUID: record.device.id) == record.audioID)
        }
        if let defaultUID = CoreAudioHAL.defaultInputUID() {
            #expect(uids.contains(defaultUID))
        }
        _ = CoreAudioHAL.isDefaultOutputBuiltInSpeaker()
    }

    @MainActor @Test func catalogRefreshMatchesTheHAL() {
        let catalog = AudioDeviceCatalog()
        var changes = 0
        catalog.onDevicesChanged = { changes += 1 }
        catalog.refresh()
        #expect(Set(catalog.devices.map(\.id)) == Set(CoreAudioHAL.inputRecords().map(\.device.id)))
        #expect(changes == (catalog.devices.isEmpty && catalog.defaultDeviceUID == nil ? 0 : 1))
        catalog.refresh()
        #expect(changes <= 1)
        if catalog.devices.contains(where: { $0.isAvailable && !$0.isVirtual }) {
            #expect(catalog.resolve(preferredUID: nil, preferBuiltInOverBluetooth: true) != nil)
        }
    }

    @MainActor @Test func backgroundRefreshPublishesOnMain() async throws {
        let catalog = AudioDeviceCatalog()
        let expected = Set(CoreAudioHAL.inputRecords().map(\.device.id))
        catalog.refreshInBackground()
        for _ in 0..<150 where Set(catalog.devices.map(\.id)) != expected {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Set(catalog.devices.map(\.id)) == expected)
    }

    @MainActor @Test func previewCatalogIsStatic() {
        let catalog = AudioDeviceCatalog.preview()
        catalog.start()
        catalog.refresh()
        #expect(catalog.devices.count == 3)
        #expect(catalog.defaultDevice?.name == "MacBook Pro Microphone")
        #expect(catalog.device(uid: "preview-airpods")?.isBluetooth == true)
        #expect(!catalog.isStarted)
    }
}

// MARK: - Recorder surface (never started: no microphone in tests)

@Suite @MainActor struct AudioRecorderSurfaceTests {
    @Test func idleRecorderIsInert() {
        let recorder = AudioRecorder(levelMeter: LevelMeter(), devices: .preview())
        #expect(!recorder.isCapturing)
        #expect(recorder.stop().samples.isEmpty)
        #expect(recorder.cancel() == nil)
        recorder.duckRecording(from: AudioClock.now(), duration: 0.2)
        #expect(recorder.currentDeviceName == nil)
    }

    @Test func aResumedCaptureComesAfterTheKeptRecording() {
        let kept = Recording(samples: [0.1, 0.2], startedAt: Date(timeIntervalSince1970: 100),
                             speech: SpeechStats(voicedSeconds: 0.5, peakDBFS: -30, isSilent: false), deviceName: "AirPods")
        let next = Recording(samples: [0.3], startedAt: Date(timeIntervalSince1970: 200),
                             speech: SpeechStats(voicedSeconds: 1.25, peakDBFS: -12, isSilent: false),
                             deviceName: "MacBook Pro Microphone")
        let whole = AudioRecorder.joined(kept, next)
        #expect(whole.id == kept.id, "the same dictation for history, Retry and Undo")
        #expect(whole.startedAt == kept.startedAt)
        #expect(whole.samples == [0.1, 0.2, 0.3])
        #expect(whole.speech == SpeechStats(voicedSeconds: 1.75, peakDBFS: -12, isSilent: false))
        #expect(whole.deviceName == "MacBook Pro Microphone")
        #expect(AudioRecorder.joined(nil, next) == next)
        let silentThenEmpty = AudioRecorder.joined(Recording(samples: [0, 0], speech: .empty), Recording(samples: []))
        #expect(silentThenEmpty.speech.isSilent)
        #expect(!AudioRecorder.joined(kept, Recording(samples: [])).speech.isSilent)
    }

    @Test func idleFinishReturnsEmptyRecording() async {
        let recorder = AudioRecorder(levelMeter: LevelMeter(), devices: .preview())
        let recording = await recorder.finish()
        #expect(recording.samples.isEmpty)
        #expect(recording.speech == .empty)
    }

    @Test func previewMonitorNeverCaptures() {
        let monitor = MicrophoneMonitor.preview(level: 0.4)
        monitor.start(deviceUID: nil)
        #expect(monitor.isRunning)
        #expect(monitor.meter.hasReceivedAudio)
        monitor.stop()
        #expect(monitor.isRunning)
    }

    @Test func clockMatchesSystemUptime() {
        #expect(abs(AudioClock.now() - ProcessInfo.processInfo.systemUptime) < 0.01)
        let host = mach_absolute_time()
        #expect(abs(AudioClock.seconds(hostTime: AudioClock.hostTime(seconds: AudioClock.seconds(hostTime: host)))
            - AudioClock.seconds(hostTime: host)) < 1e-6)
    }
}
