import AudioToolbox
import Foundation

/// A call's tracks as files: the journal's WAV turned into the store's .m4a a piece at a time, and a stretch of an
/// .m4a read back for transcription, so an hour-long call is never in memory whole. Pure file work, off the main
/// thread.
enum CallAudio {
    /// Samples read or written at a time: about 1 MB of floats.
    static let block = 262_144

    /// What encoding a track found.
    struct Encoded: Equatable, Sendable {
        var samples: Int
        /// The loudest sample, 0 for a track of digital silence (a tap macOS gave nothing).
        var peak: Float

        var seconds: TimeInterval { Double(samples) / Recording.sampleRate }
    }

    /// The journal's 16-bit WAV at `wav` as AAC at History's 32 kbps (`RecordingFile.bitRate`) in `m4a`, silent in
    /// `silencing` (the mic's mutes, seconds on the call's clock). Throws when the WAV can't be read or the encoder
    /// fails.
    static func encode(journal wav: URL, to m4a: URL, silencing: [CallInterval] = [],
                       limit: Int? = nil) throws -> Encoded {
        try join(nil, then: wav, at: 0, to: m4a, silencing: silencing, limit: limit)
    }

    /// One track of a call the app quit recording and its continuation as one .m4a: the first `offset` samples of
    /// `earlier` (an .m4a; silence where it has fewer, none for nil), then the journal's WAV at `wav`. The two parts
    /// stay on the call's clock: the continuation starts at sample `offset` whatever the earlier part had. Silent in
    /// `silencing`, seconds on the joined call's clock.
    /// `limit`: the joined call's length in samples, when it ended before its recording did; nothing past it is written.
    static func join(_ earlier: URL?, then wav: URL, at offset: Int, to m4a: URL,
                     silencing: [CallInterval] = [], limit: Int? = nil) throws -> Encoded {
        let handle = try FileHandle(forReadingFrom: wav)
        defer { try? handle.close() }
        let total = RecordingJournal.sampleCount(of: wav) ?? 0
        try handle.seek(toOffset: UInt64(RecordingJournal.headerSize))
        let kept = try earlier.map { min(try sampleCount(of: $0), offset) } ?? 0
        var written = 0
        var peak: Float = 0
        try FileManager.default.createDirectory(at: m4a.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CloudAudio.writeM4A(bitRate: RecordingFile.bitRate,
                                reservingSeconds: Double(offset + total) / Recording.sampleRate, to: m4a) { append in
            if let earlier {
                while written < kept {
                    var piece = try read(earlier, range: written..<min(kept, written + block))
                    if piece.isEmpty { break }
                    CallMix.silence(&piece, first: written, mutes: silencing)
                    peak = piece.reduce(peak) { max($0, abs($1)) }
                    try append(piece)
                    written += piece.count
                }
            }
            while written < offset {
                let count = min(block, offset - written)
                try append([Float](repeating: 0, count: count))
                written += count
            }
            while written < (limit ?? .max), let data = try handle.read(upToCount: min(block, (limit ?? .max) - written) * 2),
                  data.count >= 2 {
                let count = data.count / 2
                var ints = [Int16](repeating: 0, count: count)
                _ = ints.withUnsafeMutableBytes { data.copyBytes(to: $0, count: count * 2) }
                var samples = ints.map { Float($0) / 32_768 }
                CallMix.silence(&samples, first: written, mutes: silencing)
                peak = samples.reduce(peak) { max($0, abs($1)) }
                try append(samples)
                written += samples.count
            }
        }
        return Encoded(samples: written, peak: peak)
    }

    /// Samples `range` of an .m4a (16 kHz mono), as many of them as it has.
    static func read(_ url: URL, range: Range<Int>) throws -> [Float] {
        let file = try open(url)
        defer { ExtAudioFileDispose(file) }
        try check(ExtAudioFileSeek(file, Int64(range.lowerBound)))
        var out = [Float](repeating: 0, count: range.count)
        var filled = 0
        while filled < range.count {
            var frames = UInt32(min(block, range.count - filled))
            let status = out.withUnsafeMutableBufferPointer { pointer -> OSStatus in
                var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: frames * 4, mData: pointer.baseAddress! + filled))
                return ExtAudioFileRead(file, &frames, &buffers)
            }
            try check(status)
            if frames == 0 { break }
            filled += Int(frames)
        }
        return Array(out.prefix(filled))
    }

    /// How many samples an .m4a holds at 16 kHz.
    static func sampleCount(of url: URL) throws -> Int {
        let file = try open(url)
        defer { ExtAudioFileDispose(file) }
        var frames: Int64 = 0
        var size = UInt32(MemoryLayout<Int64>.size)
        try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames))
        return Int(frames)
    }

    /// The file opened for reading as 16 kHz mono floats.
    private static func open(_ url: URL) throws -> ExtAudioFileRef {
        var opened: ExtAudioFileRef?
        try check(ExtAudioFileOpenURL(url as CFURL, &opened))
        guard let file = opened else { throw CocoaError(.fileReadUnknown) }
        var float = AudioStreamBasicDescription(mSampleRate: Recording.sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        let status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                             UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &float)
        guard status == noErr else {
            ExtAudioFileDispose(file)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return file
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
