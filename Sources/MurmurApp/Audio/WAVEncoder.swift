import Foundation

// STUB (FOUNDATION): AUDIO replaces this.
enum WAVEncoder {
    /// 16-bit PCM mono WAV.
    static func pcm16(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + payload)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(payload)
        for s in samples { append(Int16((min(max(s, -1), 1) * Float(Int16.max)).rounded())) }
        return data
    }

    static func decode(_ data: Data) -> [Float]? { nil }
}
