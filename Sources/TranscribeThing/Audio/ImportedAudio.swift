import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// An audio or video file read for Home to transcribe as if it had been dictated: its sound as 16 kHz mono samples,
/// like a recording's (`Recording`), with its file's name for the row.
struct ImportedAudio: Sendable, Identifiable {
    let id = UUID()
    var fileName: String
    var samples: [Float]
    var speech: SpeechStats

    var duration: TimeInterval { Double(samples.count) / Recording.sampleRate }

    /// What Home takes: any audio, and a video's sound.
    static let contentTypes: [UTType] = [.audio, .movie]
    /// Longer than this isn't read: three hours is about 700 MB of samples in memory, and more than one request can
    /// take.
    static let maxDuration: TimeInterval = 3 * 60 * 60

    enum ReadError: Error, Equatable {
        /// Neither AVFoundation's asset reader nor the audio file reader it falls back to (`AudioFileLoader`) can
        /// decode it (a document), or both failed on it. An Ogg Opus voice note isn't this: the asset reader takes
        /// it on macOS 26, and the fallback does too.
        case unreadable
        /// A video with no sound, or a file with nothing in it.
        case noAudio
        /// Sound, but flat or silent all the way: nothing to transcribe.
        case silent
        case tooLong

        /// Why the file can't be transcribed, after its name ("Can't transcribe “x”").
        var message: String {
            switch self {
            case .unreadable: "It isn’t audio this Mac can read. Try an MP3, M4A, WAV or a video."
            case .noAudio: "It has no sound."
            case .silent: "There’s no speech in it."
            case .tooLong: "It’s longer than \(Int(maxDuration / 3600)) hours."
            }
        }
    }

    /// Reads `url` off the main thread: through AVFoundation's asset reader, which takes audio and video alike and
    /// converts to 16 kHz mono itself, else through the audio file reader recordings use. Longer than `limit`
    /// (`maxDuration`; tests pass less) is `.tooLong`.
    nonisolated static func read(_ url: URL, limit: TimeInterval = maxDuration) async throws(ReadError) -> ImportedAudio {
        let samples: [Float]
        do {
            samples = try await readAsset(url, limit: limit)
        } catch .unreadable {
            guard let read = try? AudioFileLoader.load16kMono(url) else { throw .unreadable }
            guard Double(read.count) / Recording.sampleRate <= limit else { throw .tooLong }
            samples = read
        }
        guard !samples.isEmpty else { throw .noAudio }
        let speech = SpeechAnalyzer.stats(for: samples)
        guard !speech.isSilent, speech.voicedSeconds > 0 else { throw .silent }
        return ImportedAudio(fileName: url.lastPathComponent, samples: samples, speech: speech)
    }

    private nonisolated static func readAsset(_ url: URL, limit: TimeInterval) async throws(ReadError) -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        let duration: CMTime
        do {
            guard try await asset.load(.isReadable) else { throw ReadError.unreadable }
            tracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
        } catch {
            throw .unreadable
        }
        // A video without sound is readable, with nothing to hear; anything else without tracks isn't media at all.
        guard !tracks.isEmpty else {
            throw (try? await asset.loadTracks(withMediaType: .video).isEmpty) == false ? .noAudio : .unreadable
        }
        if duration.isNumeric, duration.seconds > limit { throw .tooLong }
        guard let reader = try? AVAssetReader(asset: asset) else { throw .unreadable }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Recording.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        guard reader.canAdd(output) else { throw .unreadable }
        reader.add(output)
        guard reader.startReading() else { throw .unreadable }
        var samples: [Float] = []
        if duration.isNumeric { samples.reserveCapacity(Int(duration.seconds * Recording.sampleRate) + 1_024) }
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            let status = samples.withUnsafeMutableBufferPointer { pointer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: pointer.baseAddress! + start)
            }
            guard status == kCMBlockBufferNoErr else { throw .unreadable }
        }
        guard reader.status == .completed else { throw .unreadable }
        return samples
    }
}
