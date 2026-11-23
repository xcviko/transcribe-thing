import AVFoundation

/// A small, silent copy of the video a call was made from, for the one request that looks at its picture to tell who is
/// who (`CallVideoNames`): H.264, at most `maxWidth` wide, `framesPerSecond` frames a second (frames in between are
/// dropped, the ones kept keep their times, so the transcript's times still match), and no sound. The sound stays out
/// on purpose: the words come only from the audio, and a model that sees and hears the call starts writing words of
/// its own. Small, so the upload is quick: a call app's tiles and names read fine at this size. AVFoundation alone,
/// into a file the caller deletes.
enum CallVideoCopy {
    /// Wide enough to read the names on a call app's tiles.
    static let maxWidth: CGFloat = 960
    /// Enough to see whose tile lights up while they talk.
    static let framesPerSecond: Int32 = 5
    /// About 2 MB a minute: a screen at 5 frames a second is mostly still.
    static let bitRate = 300_000

    enum Failure: Error, LocalizedError, Equatable {
        /// The file isn't there, or AVFoundation can't open it.
        case unreadable
        /// It has no picture.
        case noPicture
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: "The video couldn’t be read."
            case .noPicture: "The file has no picture."
            case .failed(let why): "The video couldn’t be made smaller: \(why)"
            }
        }

        var code: String {
            switch self {
            case .unreadable: "unreadable"
            case .noPicture: "noPicture"
            case .failed: "failed"
            }
        }
    }

    /// The size of the copy of a picture `size` big (as shown, turned the way it plays): at most `maxWidth` wide,
    /// never larger than it was, both sides even (H.264 wants them so).
    static func outputSize(for size: CGSize, maxWidth: CGFloat = maxWidth) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(1, maxWidth / size.width)
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * scale / 2).rounded() * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    /// Writes the copy of `source` to `destination` (an .mp4, replaced if there). Blocking work in an async function:
    /// call it off the main actor. Throws `Failure`, or `CancellationError` (the copy so far is left for the caller to
    /// delete).
    static func make(from source: URL, to destination: URL) async throws {
        guard FileManager.default.isReadableFile(atPath: source.path) else { throw Failure.unreadable }
        let asset = AVURLAsset(url: source)
        let track: AVAssetTrack
        let duration: CMTime
        do {
            guard try await asset.load(.isReadable) else { throw Failure.unreadable }
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noPicture }
            track = video
            duration = try await asset.load(.duration)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unreadable
        }
        let natural = (try? await track.load(.naturalSize)) ?? .zero
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let shown = CGRect(origin: .zero, size: natural).applying(transform).size
        let picture = CGSize(width: abs(shown.width), height: abs(shown.height))
        let size = outputSize(for: picture)
        guard size.width > 0 else { throw Failure.noPicture }

        // The composition turns the picture the way it plays, scales it, and renders `framesPerSecond` frames a second.
        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        let scale = CGAffineTransform(scaleX: size.width / picture.width, y: size.height / picture.height)
        layer.setTransform(transform.concatenating(scale), at: .zero)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
            timeRange: CMTimeRange(start: .zero, duration: duration)))
        let composition = AVVideoComposition(configuration: .init(
            frameDuration: CMTime(value: 1, timescale: framesPerSecond), instructions: [instruction],
            renderSize: size))

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            try? FileManager.default.removeItem(at: destination)
            writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.failed("no reader output") }
        reader.add(output)

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: Int(framesPerSecond),
                AVVideoMaxKeyFrameIntervalKey: Int(framesPerSecond) * 10,
                // Frames in the order they play: no edit list shifting the times the transcript's are matched to.
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw Failure.failed("no writer input") }
        writer.add(input)
        writer.shouldOptimizeForNetworkUse = true

        guard reader.startReading() else {
            throw Failure.failed(reader.error?.localizedDescription ?? "reading didn’t start")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw Failure.failed(writer.error?.localizedDescription ?? "writing didn’t start")
        }
        writer.startSession(atSourceTime: .zero)
        do {
            while let sample = output.copyNextSampleBuffer() {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                try Task.checkCancellation()
                guard input.append(sample) else {
                    throw Failure.failed(writer.error?.localizedDescription ?? "a frame couldn’t be written")
                }
            }
            try Task.checkCancellation()
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw Failure.failed(reader.error?.localizedDescription ?? "reading stopped")
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure.failed(writer.error?.localizedDescription ?? "writing didn’t finish")
        }
    }
}
