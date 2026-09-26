import AVFoundation
import Foundation

/// Reads any audio file AVFoundation understands into 16 kHz mono Float32 (the engines' input format).
enum AudioFileLoader {
    enum LoadError: Error, LocalizedError {
        case unsupportedFormat
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "This audio format can’t be converted."
            case .conversionFailed(let detail): "Couldn’t convert the audio: \(detail)"
            }
        }
    }

    static func load16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let input = file.processingFormat
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Recording.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output)
        else { throw LoadError.unsupportedFormat }
        converter.downmix = true

        let chunk: AVAudioFrameCount = 32_768
        let outCapacity = AVAudioFrameCount(Double(chunk) * output.sampleRate / input.sampleRate) + 1_024
        let reader = ChunkReader(file: file, format: input, capacity: chunk)
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * output.sampleRate / input.sampleRate) + 1_024)

        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: outCapacity) else {
                throw LoadError.unsupportedFormat
            }
            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { _, outStatus in
                reader.next(outStatus)
            }
            if let conversionError { throw LoadError.conversionFailed(conversionError.localizedDescription) }
            if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
            switch status {
            case .endOfStream: return samples
            case .error: throw LoadError.conversionFailed("converter error")
            default: if buffer.frameLength == 0 && reader.finished { return samples }
            }
        }
    }

    /// Feeds the converter one file chunk per call; reports end of stream once the file is exhausted.
    private final class ChunkReader: @unchecked Sendable {
        private let file: AVAudioFile
        private let format: AVAudioFormat
        private let capacity: AVAudioFrameCount
        private(set) var finished = false

        init(file: AVAudioFile, format: AVAudioFormat, capacity: AVAudioFrameCount) {
            self.file = file
            self.format = format
            self.capacity = capacity
        }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard !finished, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                status.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: buffer)
            } catch {
                finished = true
                status.pointee = .endOfStream
                return nil
            }
            guard buffer.frameLength > 0 else {
                finished = true
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return buffer
        }
    }
}
