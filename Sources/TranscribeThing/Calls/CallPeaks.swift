import Accelerate
import Foundation

/// How loud a call is along its length, for the call page's waveform: the loudest sample of every 50 ms of both tracks
/// (the mic's and the other side's, whichever is louder), independent of how wide the waveform is drawn. Read once
/// from the .m4a files a block at a time (an hour is never in memory), then kept next to them as `peaks.bin`, which
/// says which files it was made from: a track rewritten (joined onto, cleaned again) makes it stale, and it's read
/// again. It goes with the call's folder.
struct CallPeaks: Equatable, Sendable {
    /// Samples per bucket: 50 ms at the tracks' 16 kHz.
    static let samplesPerBucket = 800
    static var bucketSeconds: TimeInterval { Double(samplesPerBucket) / Recording.sampleRate }
    /// The cache's name in the call's folder.
    static let fileName = "peaks.bin"

    /// Each bucket's loudest sample, 0...1, as recorded (not normalized).
    var values: [Float]

    var seconds: TimeInterval { Double(values.count) * Self.bucketSeconds }

    // MARK: Drawing

    /// `count` bars' heights over the whole call, 0.05...1: each bar the mean of the buckets it covers (so a bar of
    /// half speech, half pause is half as tall as one of speech), normalized by the 97th-percentile bar, not the
    /// loudest one, so one click doesn't flatten the rest. `duration`: the call's length, when it's longer than the
    /// tracks read (the bars past them are silent).
    func bars(_ count: Int, duration: TimeInterval? = nil) -> [Float] {
        let total = max(duration ?? 0, seconds)
        guard count > 0 else { return [] }
        guard total > 0, !values.isEmpty else { return Self.normalized([Float](repeating: 0, count: count)) }
        // The buckets padded out to the call's length.
        let length = max(values.count, Int((total / Self.bucketSeconds).rounded()))
        let padded = values.count < length ? values + [Float](repeating: 0, count: length - values.count) : values
        return Self.normalized(Self.resample(padded, to: count))
    }

    /// `values` as `count` values: each the mean of the values its stretch covers, or the one value it falls in
    /// when there are fewer values than `count`.
    static func resample(_ values: [Float], to count: Int) -> [Float] {
        guard count > 0, !values.isEmpty else { return [] }
        let step = Double(values.count) / Double(count)
        return (0..<count).map { index in
            let from = min(values.count - 1, Int(Double(index) * step))
            let to = min(values.count, max(from + 1, Int((Double(index + 1) * step).rounded())))
            var sum: Float = 0
            for i in from..<to { sum += values[i] }
            return sum / Float(to - from)
        }
    }

    /// `values` over the 97th-percentile value, at most 1, at least `floor`: a silent stretch still shows as a dot.
    /// When fewer than 3% of them are loud (a long call that spoke only at its start), the percentile is the room's
    /// hum, so the reference is never below a third of the loudest, nor below `quietest` (-30 dBFS): hum stays low.
    static func normalized(_ values: [Float], floor: Float = 0.05, quietest: Float = 0.03) -> [Float] {
        guard !values.isEmpty else { return [] }
        let sorted = values.sorted()
        let percentile = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.97))]
        let reference = max(percentile, (sorted.last ?? 0) / 3, quietest)
        return values.map { max(floor, min(1, $0 / reference)) }
    }

    // MARK: Reading the tracks

    /// Each bucket's loudest sample, fed a block at a time: `add` the samples of one track in order, `nextTrack`
    /// before another track's, which takes the louder of the two per bucket.
    struct Accumulator {
        private(set) var values: [Float] = []
        private var position = 0

        mutating func nextTrack() { position = 0 }

        mutating func add(_ samples: [Float]) {
            samples.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let bucket = position / CallPeaks.samplesPerBucket
                    let room = CallPeaks.samplesPerBucket - position % CallPeaks.samplesPerBucket
                    let length = min(room, buffer.count - offset)
                    var peak: Float = 0
                    vDSP_maxmgv(base + offset, 1, &peak, vDSP_Length(length))
                    if bucket >= values.count { values.append(contentsOf: repeatElement(0, count: bucket - values.count + 1)) }
                    values[bucket] = max(values[bucket], min(1, peak))
                    offset += length
                    position += length
                }
            }
        }
    }

    /// The peaks of `tracks` (.m4a files on the call's clock; ones that are missing are skipped), read through a
    /// block at a time; nil when none could be read.
    static func read(_ tracks: [URL]) -> CallPeaks? {
        var accumulator = Accumulator()
        var any = false
        for url in tracks {
            guard let stream = try? TrackStream(m4a: url) else { continue }
            accumulator.nextTrack()
            do {
                while true {
                    let samples = try stream.next(CallAudio.block)
                    if samples.isEmpty { break }
                    accumulator.add(samples)
                }
                any = true
            } catch {
                Log.audio.error("Couldn’t read a call’s track for its waveform: \(error.localizedDescription, privacy: .public)")
            }
        }
        return any ? CallPeaks(values: accumulator.values) : nil
    }

    // MARK: The cache

    /// What a cache was made from: each track's size and modification date, in order (nil: not there).
    struct Source: Equatable, Sendable {
        var size: Int64
        var modified: Double

        static func of(_ url: URL) -> Source? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value,
                  let date = attributes[.modificationDate] as? Date else { return nil }
            return Source(size: size, modified: date.timeIntervalSinceReferenceDate)
        }
    }

    private static let magic: UInt32 = 0x5454_504B // "TTPK"
    private static let version: UInt32 = 1

    /// The cache's bytes: a header with the bucket size and the sources, then each bucket as a 16-bit fraction.
    static func encode(_ peaks: CallPeaks, sources: [Source?]) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        put(magic)
        put(version)
        put(UInt32(samplesPerBucket))
        put(UInt32(sources.count))
        for source in sources {
            put(source?.size ?? -1)
            put((source?.modified ?? 0).bitPattern)
        }
        put(UInt32(peaks.values.count))
        for value in peaks.values { put(UInt16((max(0, min(1, value)) * 65_535).rounded())) }
        return data
    }

    /// A cache's peaks, when it was made from `sources` by this build's format; nil otherwise.
    static func decode(_ data: Data, sources: [Source?]) -> CallPeaks? {
        var offset = 0
        func take<T: FixedWidthInteger>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            var value: T = 0
            withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: data.startIndex + offset ..< data.startIndex + offset + size) }
            offset += size
            return T(littleEndian: value)
        }
        guard take(UInt32.self) == magic, take(UInt32.self) == version,
              take(UInt32.self) == UInt32(samplesPerBucket), take(UInt32.self) == UInt32(sources.count) else { return nil }
        for source in sources {
            guard let size = take(Int64.self), let modified = take(UInt64.self) else { return nil }
            guard size == (source?.size ?? -1), modified == (source?.modified ?? 0).bitPattern else { return nil }
        }
        guard let count = take(UInt32.self), data.count - offset == Int(count) * 2 else { return nil }
        var values = [Float]()
        values.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let raw = take(UInt16.self) else { return nil }
            values.append(Float(raw) / 65_535)
        }
        return CallPeaks(values: values)
    }

    /// The call's peaks: from its `peaks.bin` in `folder` when that was made from `tracks` as they are now, else read
    /// from them and kept there. nil when no track could be read (the waveform then shows only who spoke when).
    /// Blocking file work: call it off the main thread.
    static func load(tracks: [URL], folder: URL) -> CallPeaks? {
        let sources = tracks.map(Source.of)
        guard sources.contains(where: { $0 != nil }) else { return nil }
        let cache = folder.appendingPathComponent(fileName, isDirectory: false)
        if let data = try? Data(contentsOf: cache), let peaks = decode(data, sources: sources) { return peaks }
        guard let peaks = read(tracks) else { return nil }
        // A track changed while it was read (a join finishing): not kept, the next load reads it again.
        if tracks.map(Source.of) == sources {
            do {
                try encode(peaks, sources: sources).write(to: cache, options: .atomic)
            } catch {
                Log.audio.error("Couldn’t keep a call’s waveform: \(error.localizedDescription, privacy: .public)")
            }
        }
        return peaks
    }
}
