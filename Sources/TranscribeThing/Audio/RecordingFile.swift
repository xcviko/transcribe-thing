import Accelerate
import Foundation

/// A recording as History keeps it (`HistoryStore`): AAC-LC at 32 kbps, 16 kHz mono, in an .m4a (about 16 MB an hour,
/// from `CloudAudio`'s encoder), or a 16-bit PCM WAV (about 115 MB an hour), as older builds kept every recording and
/// as one is kept when the encoder fails. Either reads back as 16 kHz mono samples. File work only, off the main
/// thread.
enum RecordingFile {
    /// Writes samples into a new .m4a file at the URL.
    typealias Encoder = @Sendable (_ samples: [Float], _ url: URL) throws -> Void

    static let bitRate = 32_000
    static let aac: Encoder = { samples, url in try CloudAudio.writeM4A(samples, bitRate: bitRate, to: url) }
    /// How far a compressed recording's length may read back from its source's and still pass for it.
    static let lengthTolerance: TimeInterval = 0.1
    /// Ends the name of a file still being written. It takes its real name only once complete, so a recording's name
    /// never holds half a file; one left behind was cut off (`removePartials`).
    static let partialSuffix = ".partial.m4a"

    /// "<id>.m4a": a recording saved now.
    static func name(for id: UUID) -> String { "\(id.uuidString).m4a" }

    /// The same recording's name in the other format: "<id>.m4a" for "<id>.wav", and the other way round.
    static func otherFormat(of name: String) -> String {
        (name as NSString).deletingPathExtension + (isWAV(name) ? ".m4a" : ".wav")
    }

    static func isAAC(_ name: String) -> Bool { name.lowercased().hasSuffix(".m4a") && !isPartial(name) }
    static func isWAV(_ name: String) -> Bool { name.lowercased().hasSuffix(".wav") }
    static func isPartial(_ name: String) -> Bool { name.hasSuffix(partialSuffix) }
    /// A recording in either format, not a partial file.
    static func isRecording(_ name: String) -> Bool { isAAC(name) || isWAV(name) }

    // MARK: Saving and reading

    /// Saves `samples` as the .m4a `url`, or, when `encode` fails, as a WAV of the same name beside it, and removes
    /// the recording's file in the other format, so a recording has one file. The file written; nil when neither
    /// could be.
    static func save(_ samples: [Float], as url: URL, encode: Encoder = aac) -> URL? {
        let fm = FileManager.default
        let wav = url.deletingPathExtension().appendingPathExtension("wav")
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                let partial = partialURL(beside: url)
                defer { try? fm.removeItem(at: partial) }
                try encode(samples, partial)
                _ = try fm.replaceItemAt(url, withItemAt: partial)
                try? fm.removeItem(at: wav)
                return url
            } catch {
                let reason = error.localizedDescription
                Log.app.error("Couldn't compress a recording, kept it as WAV: \(reason, privacy: .public)")
                try WAVEncoder.pcm16(samples, sampleRate: Int(Recording.sampleRate)).write(to: wav, options: .atomic)
                try? fm.removeItem(at: url)
                return wav
            }
        } catch {
            Log.app.error("Couldn't save recording: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 16 kHz mono samples of a recording in either format; nil when it can't be read.
    static func read(_ url: URL) -> [Float]? {
        if isWAV(url.lastPathComponent) { return (try? Data(contentsOf: url)).flatMap(WAVEncoder.decode) }
        return try? AudioFileLoader.load16kMono(url)
    }

    // MARK: Compressing

    /// What `compress` read back: the source's and the output's length in samples, and their RMS levels.
    struct Check: Equatable, Sendable {
        var sourceSamples: Int
        var outputSamples: Int
        var sourceRMS: Float
        var outputRMS: Float
    }

    enum CompressError: Error, LocalizedError {
        case unreadableSource
        case unreadableOutput
        case lengthMismatch(source: Int, output: Int)

        var errorDescription: String? {
            switch self {
            case .unreadableSource: "The recording can’t be read."
            case .unreadableOutput: "The compressed recording can’t be read back."
            case .lengthMismatch(let source, let output):
                "The compressed recording reads back \(output) samples long, not \(source)."
            }
        }
    }

    /// Encodes the recording at `source` (either format) into the .m4a `output` with `encode` and reads that back: it
    /// has to be as long as the source, give or take `lengthTolerance`. On any failure `output` is removed, and this
    /// throws. The source's samples are let go before the output's are read, so an hour's recording is never held
    /// twice.
    static func compress(_ source: URL, into output: URL, encode: Encoder = aac) throws -> Check {
        do {
            let (count, level) = try autoreleasepool { () throws -> (Int, Float) in
                guard let samples = read(source), !samples.isEmpty else { throw CompressError.unreadableSource }
                try encode(samples, output)
                return (samples.count, rms(samples))
            }
            guard let decoded = autoreleasepool(invoking: { read(output) }) else {
                throw CompressError.unreadableOutput
            }
            guard abs(decoded.count - count) <= Int(lengthTolerance * Recording.sampleRate) else {
                throw CompressError.lengthMismatch(source: count, output: decoded.count)
            }
            return Check(sourceSamples: count, outputSamples: decoded.count, sourceRMS: level, outputRMS: rms(decoded))
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// A file's size and modification date: whether it is still the file something was made from.
    struct Stamp: Equatable, Sendable {
        var size: Int
        var modified: Date

        init?(_ url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            self.size = size
            self.modified = modified
        }
    }

    /// An older build's WAV `compress`ed into a partial file beside it, with the WAV's stamp from before it was read;
    /// nil, and no partial file, when that fails.
    static func compressLegacy(_ wav: URL, encode: Encoder = aac) -> (partial: URL, stamp: Stamp)? {
        guard let stamp = Stamp(wav) else { return nil }
        let partial = partialURL(beside: wav)
        do {
            _ = try compress(wav, into: partial, encode: encode)
            return (partial, stamp)
        } catch {
            let file = wav.lastPathComponent, reason = error.localizedDescription
            Log.app.error("Couldn't compress \(file, privacy: .public): \(reason, privacy: .public)")
            return nil
        }
    }

    /// Moves a partial file `compressLegacy` made to `url` when the WAV it came from still has `stamp`, and returns
    /// the moved file's stamp (`remove(_:ifStill:)`); nil, and the partial file removed, otherwise.
    static func place(_ partial: URL, at url: URL, madeFrom wav: URL, stamp: Stamp) -> Stamp? {
        defer { try? FileManager.default.removeItem(at: partial) }
        guard Stamp(wav) == stamp else { return nil }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
            return Stamp(url)
        } catch {
            let reason = error.localizedDescription
            Log.app.error("Couldn't move a compressed recording into place: \(reason, privacy: .public)")
            return nil
        }
    }

    /// Removes the file at `url` if it is still the one `stamp` was taken of: not one saved over it since.
    static func remove(_ url: URL, ifStill stamp: Stamp) {
        guard Stamp(url) == stamp else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes the partial files an interrupted save or conversion left in `directory`.
    static func removePartials(in directory: URL) {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where isPartial(url.lastPathComponent) {
            try? fm.removeItem(at: url)
        }
    }

    private static func partialURL(beside url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + partialSuffix, isDirectory: false)
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(samples, 1, &value, vDSP_Length(samples.count))
        return value
    }
}
