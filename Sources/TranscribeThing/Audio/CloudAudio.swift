import Accelerate
import AudioToolbox
import Foundation

/// A file format audio goes to OpenRouter in, as its `input_audio.format` names it.
enum UploadFormat: String, CaseIterable, Sendable {
    /// 16-bit PCM (`WAVEncoder.pcm16`): about 115 MB an hour.
    case wav
    /// AAC-LC in an MPEG-4 container: about 16 MB an hour at 32 kbps.
    case m4a
    /// FLAC: the WAV's very samples, losslessly, in a little over half its bytes (55 to 60% for speech).
    case flac
}

/// A file a recording went to OpenRouter as, and the generation that answered it.
struct AudioUpload: Equatable, Sendable {
    var format: UploadFormat
    var bytes: Int
    /// OpenRouter's id of the request that carried it (`CloudResult.generationID`): one of Parakeet's segments each.
    var generationID: String? = nil
}

/// How a recording of any length goes to OpenRouter (pure, off the main thread). Gemini hears it in one chat request,
/// always as AAC in an .m4a: it bills audio by its length whatever the format, and that is about a seventh of the
/// WAV's upload. Parakeet's speech-to-text endpoint takes it in segments of at most 5 minutes, cut in pauses, each as
/// FLAC. All of it 16 kHz mono.
enum CloudAudio {
    /// The recording for one Gemini request: AAC-LC in an .m4a whose base64 fits `budget`, never built as a WAV. The
    /// recording's own file from History (`stored`, `Recording.aacFile`) as it is while it fits, so it isn't encoded a
    /// second time; otherwise the samples encoded at `aacBitRate`. `format` sends WAV or FLAC instead, whatever its
    /// size (`EngineCLI --upload`; the app never does). Throws when the encoder fails.
    static func forChat(_ samples: [Float], stored: URL? = nil, format: UploadFormat = .m4a,
                        budget: Int = OpenRouterClient.maxBase64Bytes) throws -> Data {
        guard format == .m4a else { return try encode(samples, as: format) }
        if let data = stored.flatMap({ try? Data(contentsOf: $0) }),
           OpenRouterClient.base64Length(ofByteCount: data.count) <= budget {
            return data
        }
        let seconds = Double(samples.count) / Recording.sampleRate
        return try m4a(samples, bitRate: aacBitRate(seconds: seconds, budget: budget))
    }

    /// One of Parakeet's segments as a file in `format` (FLAC unless `EngineCLI --upload` says otherwise), or as a WAV
    /// when `encode` fails: no dictation fails for want of FLAC.
    static func forSpeech(
        _ samples: [Float], format: UploadFormat,
        encode: (_ samples: [Float], _ format: UploadFormat) throws -> Data = CloudAudio.encode(_:as:)
    ) -> (data: Data, format: UploadFormat) {
        if format != .wav {
            do {
                return (try encode(samples, format), format)
            } catch {
                let reason = error.localizedDescription
                Log.net.warning("Couldn’t encode a segment as \(format.rawValue, privacy: .public), sending WAV: \(reason, privacy: .public)")
            }
        }
        return (WAVEncoder.pcm16(samples), .wav)
    }

    /// `samples` as a whole file in `format`, an .m4a at History's 32 kbps (`RecordingFile.bitRate`).
    static func encode(_ samples: [Float], as format: UploadFormat) throws -> Data {
        switch format {
        case .wav: WAVEncoder.pcm16(samples)
        case .m4a: try m4a(samples, bitRate: RecordingFile.bitRate)
        case .flac: try flac(samples)
        }
    }

    /// The AAC bit rate for `seconds` of audio: the highest of 32, 24 and 16 kbps whose estimated file
    /// (`bitRate / 8 × seconds × 1.1 + 4,096` bytes) fits `budget` as base64, so 32 kbps up to about 54 minutes. Past
    /// what 16 kbps fits (over an hour and a half) it is 16 kbps anyway: nothing is refused up front, and a request
    /// OpenRouter finds too large comes back as `recordingTooLarge`.
    static func aacBitRate(seconds: TimeInterval, budget: Int) -> Int {
        for bitRate in [32_000, 24_000, 16_000] {
            let estimate = Int((Double(bitRate) / 8 * max(0, seconds) * 1.1).rounded(.up)) + 4_096
            if OpenRouterClient.base64Length(ofByteCount: estimate) <= budget { return bitRate }
        }
        return 16_000
    }

    /// 16 kHz mono AAC-LC in an MPEG-4 container (.m4a) at `bitRate`: about 15.8, 12.2 and 8.8 MB an hour at 32, 24
    /// and 16 kbps. Written through a temporary file, removed before this returns.
    static func m4a(_ samples: [Float], bitRate: Int) throws -> Data {
        try throughTemporaryFile("m4a") { try writeM4A(samples, bitRate: bitRate, to: $0) }
    }

    /// 16 kHz mono 16-bit FLAC (`writeFLAC`), written through a temporary file removed before this returns.
    static func flac(_ samples: [Float]) throws -> Data {
        try throughTemporaryFile("flac") { try writeFLAC(samples, to: $0) }
    }

    /// Writes `samples` to `url` as `m4a` encodes them, replacing any file there. The header reserves room for just
    /// this length (`kAudioFilePropertyReserveDuration`), with the index up front: left to itself the writer pads every
    /// file with about 20 KB, more than a short dictation's audio takes.
    static func writeM4A(_ samples: [Float], bitRate: Int, to url: URL) throws {
        var aac = AudioStreamBasicDescription(mSampleRate: Recording.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
                                              mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                              mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var created: ExtAudioFileRef?
        try check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &aac, nil,
                                            AudioFileFlags.eraseFile.rawValue, &created))
        guard let file = created else { throw CocoaError(.fileWriteUnknown) }
        var isOpen = true
        defer { if isOpen { ExtAudioFileDispose(file) } }

        var float = AudioStreamBasicDescription(mSampleRate: Recording.sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &float))
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter))
        guard let converter else { throw CocoaError(.fileWriteUnknown) }
        var rate = UInt32(bitRate)
        try check(AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size),
                                            &rate))
        // A NULL configuration makes the file take up the converter's new settings.
        var configuration: UnsafeRawPointer?
        try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig,
                                          UInt32(MemoryLayout<UnsafeRawPointer?>.size), &configuration))
        var audioFile: AudioFileID?
        size = UInt32(MemoryLayout<AudioFileID?>.size)
        try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioFile, &size, &audioFile))
        if let audioFile {
            var seconds = Double(samples.count) / Recording.sampleRate
            try check(AudioFileSetProperty(audioFile, kAudioFilePropertyReserveDuration,
                                           UInt32(MemoryLayout<Double>.size), &seconds))
        }

        try write(samples, to: file)
        isOpen = false
        try check(ExtAudioFileDispose(file))
    }

    /// Writes `samples` to `url` as FLAC, replacing any file there: the very 16-bit samples `WAVEncoder.pcm16` writes,
    /// so the audio is the WAV's bit for bit. Throws for audio shorter than one FLAC packet (4,608 samples, 0.29 s):
    /// Core Audio's writer leaves such a file with neither its audio nor its "fLaC" marker.
    static func writeFLAC(_ samples: [Float], to url: URL) throws {
        var flac = AudioStreamBasicDescription()
        flac.mSampleRate = Recording.sampleRate
        flac.mFormatID = kAudioFormatFLAC
        flac.mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData     // FLAC's source depth, in ALAC's flags
        flac.mChannelsPerFrame = 1
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &flac))
        guard samples.count >= Int(flac.mFramesPerPacket) else {
            throw EncodeError.shorterThanAPacket(samples: samples.count, packet: Int(flac.mFramesPerPacket))
        }
        var created: ExtAudioFileRef?
        try check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileFLACType, &flac, nil,
                                            AudioFileFlags.eraseFile.rawValue, &created))
        guard let file = created else { throw CocoaError(.fileWriteUnknown) }
        var isOpen = true
        defer { if isOpen { ExtAudioFileDispose(file) } }

        var pcm = AudioStreamBasicDescription(mSampleRate: Recording.sampleRate, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                                              mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &pcm))
        try write(WAVEncoder.int16(samples), to: file)
        isOpen = false
        try check(ExtAudioFileDispose(file))
    }

    enum EncodeError: Error, LocalizedError {
        case shorterThanAPacket(samples: Int, packet: Int)

        var errorDescription: String? {
            switch self {
            case .shorterThanAPacket(let samples, let packet):
                "\(samples) samples are too few for FLAC, which needs at least \(packet)."
            }
        }
    }

    /// Where Parakeet's requests split a recording: one range up to `maxSeconds`, otherwise a cut before each
    /// `maxSeconds` boundary, in the middle of the quietest 50 ms (by RMS) of the `searchSeconds` before it, so a
    /// word is rarely cut in two. The ranges are contiguous, cover every sample, and none is longer than `maxSeconds`.
    static func speechSegments(_ samples: [Float], maxSeconds: TimeInterval = 300,
                               searchSeconds: TimeInterval = 20) -> [Range<Int>] {
        let maxLength = Int(maxSeconds * Recording.sampleRate)
        guard maxLength > 0, samples.count > maxLength else { return [0..<samples.count] }
        let window = 800
        let searchLength = Int(searchSeconds * Recording.sampleRate)
        var ranges: [Range<Int>] = []
        var start = 0
        samples.withUnsafeBufferPointer { buffer in
            while buffer.count - start > maxLength {
                let boundary = start + maxLength
                var cut = boundary
                var quietest = Float.infinity
                // Half-overlapping windows that end by the boundary: the cut, a window's middle, stays inside it.
                var position = max(start, boundary - searchLength)
                while position + window <= boundary {
                    var energy: Float = 0
                    vDSP_svesq(buffer.baseAddress! + position, 1, &energy, vDSP_Length(window))
                    if energy < quietest {
                        quietest = energy
                        cut = position + window / 2
                    }
                    position += window / 2
                }
                ranges.append(start..<cut)
                start = cut
            }
        }
        ranges.append(start..<samples.count)
        return ranges
    }

    // MARK: Writing

    /// What `write` puts in a temporary file with the extension `ext`; the file is removed before this returns.
    private static func throughTemporaryFile(_ ext: String, _ write: (URL) throws -> Void) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-thing-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(url)
        return try Data(contentsOf: url)
    }

    /// Hands `frames` (mono, in the file's client format) to `file` 16,384 at a time.
    private static func write<Frame>(_ frames: [Frame], to file: ExtAudioFileRef) throws {
        try frames.withUnsafeBufferPointer { source in
            var offset = 0
            while offset < source.count {
                let count = min(16_384, source.count - offset)
                var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32(count * MemoryLayout<Frame>.stride),
                    mData: UnsafeMutableRawPointer(mutating: source.baseAddress! + offset)))
                try check(ExtAudioFileWrite(file, UInt32(count), &buffers))
                offset += count
            }
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
