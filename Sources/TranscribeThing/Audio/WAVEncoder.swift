import Accelerate
import Foundation

/// In-memory RIFF/WAVE: 16-bit PCM encoding for storage and upload, tolerant decoding for anything a
/// WAV writer is likely to produce (PCM 8/16/24/32-bit, Float32/64, WAVE_FORMAT_EXTENSIBLE, any rate
/// and channel count). Decoded audio is always returned as 16 kHz mono Float32.
enum WAVEncoder {
    struct Format: Equatable, Sendable {
        var sampleRate: Int
        var channels: Int
        var bitsPerSample: Int
        var isFloat: Bool
    }

    /// Canonical 44-byte-header 16-bit PCM mono WAV (32 KB per second at 16 kHz).
    static func pcm16(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        let dataBytes = samples.count * 2
        var data = Data(capacity: 44 + dataBytes)
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(clamping: 36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2))
        u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(clamping: dataBytes))
        guard !samples.isEmpty else { return data }

        var scaled = [Float](repeating: 0, count: samples.count)
        var low: Float = -1, high: Float = 1, scale: Float = 32_767
        vDSP_vclip(samples, 1, &low, &high, &scaled, 1, vDSP_Length(samples.count))
        vDSP_vsmul(scaled, 1, &scale, &scaled, 1, vDSP_Length(samples.count))
        var pcm = [Int16](repeating: 0, count: samples.count)
        vDSP_vfixr16(scaled, 1, &pcm, 1, vDSP_Length(samples.count))
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }     // every Mac is little-endian, like RIFF
        return data
    }

    /// Mono samples at `Recording.sampleRate` (resampled and downmixed as needed), or nil if the data
    /// isn't a WAV file this decoder understands.
    static func decode(_ data: Data) -> [Float]? {
        guard let (format, samples) = decodeRaw(data) else { return nil }
        if format.sampleRate == Int(Recording.sampleRate) { return samples }
        return StreamingResampler.resample(samples, from: Double(format.sampleRate))
    }

    /// Mono samples at the file's own rate, plus its format.
    static func decodeRaw(_ data: Data) -> (Format, [Float])? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (Format, [Float])? in
            guard raw.count >= 12, tag(raw, 0) == "RIFF", tag(raw, 8) == "WAVE" else { return nil }
            var format: Format?
            var dataRange: Range<Int>?
            var offset = 12
            while offset + 8 <= raw.count {
                let id = tag(raw, offset)
                let declared = Int(u32(raw, offset + 4))
                let bodyStart = offset + 8
                let bodyEnd = min(raw.count, bodyStart + declared)
                if id == "fmt " {
                    format = parseFormat(raw, bodyStart..<bodyEnd)
                } else if id == "data" {
                    // Streaming writers leave the size at 0 or 0xFFFFFFFF: take whatever is there.
                    let end = (declared == 0 || declared == 0xFFFF_FFFF) ? raw.count : bodyEnd
                    dataRange = bodyStart..<end
                    if format != nil { break }
                }
                guard declared != 0xFFFF_FFFF else { break }
                offset = bodyStart + declared + (declared & 1)
            }
            guard let format, let dataRange, format.channels > 0, format.sampleRate > 0 else { return nil }
            guard let samples = readSamples(raw, dataRange, format) else { return nil }
            return (format, samples)
        }
    }

    // MARK: Parsing

    private static func parseFormat(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>) -> Format? {
        guard range.count >= 16 else { return nil }
        let base = range.lowerBound
        var formatTag = Int(u16(raw, base))
        let channels = Int(u16(raw, base + 2))
        let sampleRate = Int(u32(raw, base + 4))
        let bits = Int(u16(raw, base + 14))
        if formatTag == 0xFFFE, range.count >= 26 {
            formatTag = Int(u16(raw, base + 24))            // first two bytes of the SubFormat GUID
        }
        switch (formatTag, bits) {
        case (1, 8), (1, 16), (1, 24), (1, 32):
            return Format(sampleRate: sampleRate, channels: channels, bitsPerSample: bits, isFloat: false)
        case (3, 32), (3, 64):
            return Format(sampleRate: sampleRate, channels: channels, bitsPerSample: bits, isFloat: true)
        default:
            return nil
        }
    }

    private static func readSamples(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ format: Format) -> [Float]? {
        let bytesPerSample = format.bitsPerSample / 8
        let frameBytes = bytesPerSample * format.channels
        guard frameBytes > 0 else { return nil }
        let frames = range.count / frameBytes
        if format.channels == 1, format.bitsPerSample == 16, !format.isFloat {
            var mono = [Float](repeating: 0, count: frames)
            let source = raw.baseAddress!.advanced(by: range.lowerBound)
            var pcm = [Int16](repeating: 0, count: frames)
            pcm.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: source, count: frames * 2)) }
            vDSP_vflt16(pcm, 1, &mono, 1, vDSP_Length(frames))
            var scale: Float = 1 / 32_768
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(frames))
            return mono
        }
        var mono = [Float](repeating: 0, count: frames)
        let channelScale = 1 / Float(format.channels)
        var offset = range.lowerBound
        for frame in 0..<frames {
            var sum: Float = 0
            for _ in 0..<format.channels {
                sum += sample(raw, offset, format)
                offset += bytesPerSample
            }
            mono[frame] = sum * channelScale
        }
        return mono
    }

    private static func sample(_ raw: UnsafeRawBufferPointer, _ offset: Int, _ format: Format) -> Float {
        switch (format.bitsPerSample, format.isFloat) {
        case (8, false):
            return (Float(raw[offset]) - 128) / 128
        case (16, false):
            return Float(Int16(bitPattern: u16(raw, offset))) / 32_768
        case (24, false):
            let value = Int32(raw[offset]) | Int32(raw[offset + 1]) << 8 | Int32(Int8(bitPattern: raw[offset + 2])) << 16
            return Float(value) / 8_388_608
        case (32, false):
            return Float(Int32(bitPattern: u32(raw, offset))) / 2_147_483_648
        case (32, true):
            return Float(bitPattern: u32(raw, offset))
        case (64, true):
            return Float(Double(bitPattern: u64(raw, offset)))
        default:
            return 0
        }
    }

    private static func tag(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> String {
        guard offset + 4 <= raw.count else { return "" }
        return String(decoding: raw[offset..<offset + 4], as: UTF8.self)
    }

    private static func u16(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
        UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8
    }

    private static func u32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(raw[offset]) | UInt32(raw[offset + 1]) << 8 | UInt32(raw[offset + 2]) << 16 | UInt32(raw[offset + 3]) << 24
    }

    private static func u64(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt64 {
        UInt64(u32(raw, offset)) | UInt64(u32(raw, offset + 4)) << 32
    }
}
