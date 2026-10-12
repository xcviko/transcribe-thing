import AudioToolbox
import Foundation

/// A call's tracks as files: the journal's WAV turned into the store's .m4a a piece at a time, the mic cleaned of the
/// other side's voices on the way (`cancelEcho`), and a stretch of an .m4a read back for transcription, so an
/// hour-long call is never in memory whole. Pure file work, off the main thread.
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
        try write(TrackStream(earlier: earlier, then: wav, at: offset, limit: limit), to: m4a, silencing: silencing)
    }

    /// `track` as AAC in `m4a`, silent in `silencing`.
    static func write(_ track: TrackStream, to m4a: URL, silencing: [CallInterval] = []) throws -> Encoded {
        var written = 0
        var peak: Float = 0
        try FileManager.default.createDirectory(at: m4a.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CloudAudio.writeM4A(bitRate: RecordingFile.bitRate,
                                reservingSeconds: Double(track.length) / Recording.sampleRate, to: m4a) { append in
            while true {
                var samples = try track.next(block)
                if samples.isEmpty { break }
                CallMix.silence(&samples, first: written, mutes: silencing)
                peak = samples.reduce(peak) { max($0, abs($1)) }
                try append(samples)
                written += samples.count
            }
        }
        return Encoded(samples: written, peak: peak)
    }

    /// What `cancelEcho` did: the mic as recorded, how long the cleaning took, what `EchoMeter` measured.
    struct EchoCancelled: Sendable {
        var encoded: Encoded
        var seconds: TimeInterval
        var stats: EchoStats
    }

    /// The mic with the other side taken out of it (`EchoCanceller`), a block at a time: `mic` goes to `raw` as
    /// recorded, and to `m4a` cleaned against `reference` (the other side's track on the same clock; silence where it's
    /// shorter). Both are silent in `silencing`: a mute stays digital silence after cleaning too.
    static func cancelEcho(_ mic: TrackStream, reference: TrackStream, to m4a: URL, raw: URL,
                           silencing: [CallInterval] = [],
                           settings: EchoCanceller.Settings = .standard) throws -> EchoCancelled {
        let began = Date()
        let canceller = EchoCanceller(settings: settings)
        var meter = EchoMeter()
        var taken = 0, given = 0
        var peak: Float = 0
        let seconds = Double(mic.length) / Recording.sampleRate
        try FileManager.default.createDirectory(at: m4a.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CloudAudio.writeM4A(bitRate: RecordingFile.bitRate, reservingSeconds: seconds, to: raw) { appendRaw in
            try CloudAudio.writeM4A(bitRate: RecordingFile.bitRate, reservingSeconds: seconds, to: m4a) { appendClean in
                func give(_ cleaned: [Float]) throws {
                    guard !cleaned.isEmpty else { return }
                    var cleaned = cleaned
                    CallMix.silence(&cleaned, first: given, mutes: silencing)
                    meter.add(cleaned: cleaned)
                    try appendClean(cleaned)
                    given += cleaned.count
                }
                while true {
                    var samples = try mic.next(block)
                    if samples.isEmpty { break }
                    CallMix.silence(&samples, first: taken, mutes: silencing)
                    let far = try reference.next(samples.count)
                    peak = samples.reduce(peak) { max($0, abs($1)) }
                    meter.add(raw: samples, remote: far)
                    try appendRaw(samples)
                    taken += samples.count
                    try give(canceller.process(mic: samples, reference: far))
                }
                try give(canceller.finish())
            }
        }
        return EchoCancelled(encoded: Encoded(samples: taken, peak: peak), seconds: Date().timeIntervalSince(began),
                             stats: meter.result())
    }

    /// The loudest sample of `track`, read through: 0 when it's digital silence.
    static func peak(of track: TrackStream) throws -> Float {
        var peak: Float = 0
        while true {
            let samples = try track.next(block)
            if samples.isEmpty { return peak }
            peak = samples.reduce(peak) { max($0, abs($1)) }
        }
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
        return try sampleCount(of: file)
    }

    fileprivate static func sampleCount(of file: ExtAudioFileRef) throws -> Int {
        var frames: Int64 = 0
        var size = UInt32(MemoryLayout<Int64>.size)
        try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames))
        return Int(frames)
    }

    /// The file opened for reading as 16 kHz mono floats.
    fileprivate static func open(_ url: URL) throws -> ExtAudioFileRef {
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

    fileprivate static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

/// A track on the call's clock, read a block at a time so an hour of it is never in memory: the first `offset`
/// samples of an earlier part (an .m4a; silence where it has fewer, none for nil), then a journal's 16-bit WAV from
/// sample `offset` (none for nil), nothing past `limit`. Not thread-safe: read from one thread.
final class TrackStream {
    /// How many samples it gives in all.
    let length: Int
    private let earlier: ExtAudioFileRef?
    private let kept: Int
    private let offset: Int
    private let wav: FileHandle?
    private var position = 0

    init(earlier: URL?, then wav: URL?, at offset: Int, limit: Int? = nil) throws {
        var kept = 0
        if let earlier {
            let file = try CallAudio.open(earlier)
            self.earlier = file
            kept = min((try? CallAudio.sampleCount(of: file)) ?? 0, offset)
        } else {
            self.earlier = nil
        }
        self.kept = kept
        self.offset = offset
        let total = wav.flatMap { RecordingJournal.sampleCount(of: $0) } ?? 0
        if let wav, total > 0 {
            let handle = try FileHandle(forReadingFrom: wav)
            try handle.seek(toOffset: UInt64(RecordingJournal.headerSize))
            self.wav = handle
        } else {
            self.wav = nil
        }
        let natural = total > 0 ? offset + total : (earlier == nil ? 0 : offset)
        length = max(0, min(natural, limit ?? .max))
    }

    /// A whole .m4a as it is.
    convenience init(m4a: URL) throws {
        try self.init(earlier: m4a, then: nil, at: CallAudio.sampleCount(of: m4a))
    }

    deinit {
        if let earlier { ExtAudioFileDispose(earlier) }
        try? wav?.close()
    }

    /// The next up to `count` samples; empty at the end.
    func next(_ count: Int) throws -> [Float] {
        let count = min(count, length - position)
        guard count > 0 else { return [] }
        var out: [Float]
        if position < kept, let earlier {
            out = [Float](repeating: 0, count: min(count, kept - position))
            var frames = UInt32(out.count)
            let status = out.withUnsafeMutableBufferPointer { pointer -> OSStatus in
                var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: frames * 4, mData: pointer.baseAddress))
                return ExtAudioFileRead(earlier, &frames, &buffers)
            }
            try CallAudio.check(status)
            if frames == 0 {
                // The earlier part ran out before its header said: silence for the rest of it.
                out = [Float](repeating: 0, count: min(count, offset - position))
            } else {
                out.removeLast(out.count - Int(frames))
            }
        } else if position < offset {
            out = [Float](repeating: 0, count: min(count, offset - position))
        } else if let wav, let data = try wav.read(upToCount: count * 2), data.count >= 2 {
            let samples = data.count / 2
            var ints = [Int16](repeating: 0, count: samples)
            _ = ints.withUnsafeMutableBytes { data.copyBytes(to: $0, count: samples * 2) }
            out = ints.map { Float($0) / 32_768 }
        } else {
            return []
        }
        position += out.count
        return out
    }
}
