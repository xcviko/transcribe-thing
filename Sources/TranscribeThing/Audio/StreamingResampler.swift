import AVFAudio
import Foundation

/// Converts arbitrary PCM chunks (any rate, any channel count) into one continuous mono Float32 stream.
/// Chunked conversion is sample-identical to converting the whole signal at once, because the converter
/// keeps its filter history between chunks and only sees end-of-stream at `flush`.
final class StreamingResampler {
    enum Failure: Error, Equatable { case unsupportedFormat, conversionFailed }

    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(targetSampleRate: Double = Recording.sampleRate) {
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate,
                                     channels: 1, interleaved: false)!
    }

    var targetSampleRate: Double { outputFormat.sampleRate }

    /// True when the next chunk in `format` continues the current conversion (no drain needed).
    func isConfigured(for format: AVAudioFormat) -> Bool {
        converter != nil && inputFormat == format
    }

    func process(_ input: AVAudioPCMBuffer, into output: inout [Float]) throws {
        guard input.frameLength > 0 else { return }
        if converter == nil || inputFormat != input.format {
            // A device or format switch mid-recording: drain the old converter so nothing is lost.
            if converter != nil { try flush(into: &output) }
            guard input.format.sampleRate > 0, input.format.channelCount > 0,
                  let fresh = AVAudioConverter(from: input.format, to: outputFormat) else {
                throw Failure.unsupportedFormat
            }
            // Without downmix the converter silently drops every channel but the first.
            fresh.downmix = input.format.channelCount > 1
            fresh.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter = fresh
            inputFormat = input.format
        }
        try run(input, endOfStream: false, into: &output)
    }

    /// Drains the 10-50 ms the sample-rate converter still holds. Call once at the end of a recording.
    func flush(into output: inout [Float]) throws {
        guard converter != nil else { return }
        defer {
            converter = nil
            inputFormat = nil
        }
        try run(nil, endOfStream: true, into: &output)
    }

    func reset() {
        converter = nil
        inputFormat = nil
    }

    /// Resamples a whole mono signal in one go (used for decoded WAV files at other rates).
    static func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double = Recording.sampleRate) -> [Float] {
        guard sourceRate > 0, sourceRate != targetRate, !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false)
        else { return samples }
        let resampler = StreamingResampler(targetSampleRate: targetRate)
        var output: [Float] = []
        output.reserveCapacity(Int(Double(samples.count) * targetRate / sourceRate) + 1_024)
        let chunk = 65_536
        var start = 0
        while start < samples.count {
            let count = min(chunk, samples.count - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { return samples }
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress! + start, count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            do { try resampler.process(buffer, into: &output) } catch { return samples }
            start += count
        }
        try? resampler.flush(into: &output)
        return output
    }

    private func run(_ input: AVAudioPCMBuffer?, endOfStream: Bool, into output: inout [Float]) throws {
        guard let converter else { return }
        let total = input?.frameLength ?? 0
        let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(total) * ratio).rounded(.up)) + 1_024
        var offset: AVAudioFrameCount = 0
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw Failure.conversionFailed
            }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { requested, inputStatus in
                // Hand over exactly what the converter asks for. Giving it more makes it park the excess
                // and fall up to ~70 ms behind; saying "no data now" (never end-of-stream until `flush`)
                // keeps its filter state for the next chunk.
                guard let input, offset < total else {
                    inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                    return nil
                }
                let count = min(requested, total - offset)
                let piece = offset == 0 && count == total ? input : input.copyFrames(offset..<offset + count)
                offset += count
                inputStatus.pointee = piece == nil ? .noDataNow : .haveData
                return piece
            }
            if error != nil || status == .error { throw Failure.conversionFailed }
            if buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] {
                output.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
            // `.haveData` means the output filled up and more may be waiting.
            guard status == .haveData, buffer.frameLength > 0 else { return }
        }
    }
}

extension AVAudioPCMBuffer {
    /// A standalone copy of `range` (any PCM layout, interleaved or not).
    func copyFrames(_ range: Range<AVAudioFrameCount>) -> AVAudioPCMBuffer? {
        let start = min(range.lowerBound, frameLength)
        let count = min(range.upperBound, frameLength) - start
        guard count > 0, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return nil }
        copy.frameLength = count
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let src = from.mData, let dst = to.mData else { continue }
            dst.copyMemory(from: src + Int(start) * bytesPerFrame, byteCount: Int(count) * bytesPerFrame)
        }
        return copy
    }
}
