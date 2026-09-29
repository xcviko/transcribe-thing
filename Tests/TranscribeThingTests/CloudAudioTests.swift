import AVFoundation
import Foundation
import Testing
@testable import TranscribeThing

// How a recording of any length goes to OpenRouter: AAC for Gemini, pause-cut FLAC segments for Parakeet, and the
// format `EngineCLI --upload` forces instead.

private let rate = 16_000

/// One second of 220 Hz: a whole number of cycles, so repeats join without a click.
private let toneSecond: [Float] = (0..<rate).map { 0.2 * Float(sin(2 * .pi * 220 * Double($0) / Double(rate))) }

/// `seconds` of the tone, a copy of `toneSecond` per second: synthetic minutes stay cheap to build.
private func tone(_ seconds: Double) -> [Float] {
    let count = Int(seconds * Double(rate))
    var out: [Float] = []
    out.reserveCapacity(count)
    while out.count < count { out.append(contentsOf: toneSecond.prefix(count - out.count)) }
    return out
}

/// `seconds` of the tone over deterministic noise (xorshift), with full scale, clipping and the smallest steps in
/// the first samples: everything a 16-bit sample can hold.
private func noisyTone(_ seconds: Double) -> [Float] {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    var samples = tone(seconds).map { sample -> Float in
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return sample + Float(Double(state % 2_000_001) / 1_000_000 - 1) * 0.005
    }
    let edges: [Float] = [1, -1, 0, 1.5, -2, 1 / 32_767, -1 / 32_767, 0.5 / 32_767, 0.999_99, -0.999_99]
    samples.replaceSubrange(0..<edges.count, with: edges)
    return samples
}

private func temporaryURL(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cloud-audio-\(UUID().uuidString).\(ext)")
}

/// The 16-bit samples a FLAC file holds, as Core Audio decodes them.
private func int16Samples(ofFLAC data: Data) throws -> [Int16] {
    let url = temporaryURL("flac")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
    #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatFLAC)
    #expect(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let channel = try #require(buffer.int16ChannelData?[0])
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
}

/// Codec, sample rate and channels of an encoded file.
private func format(of data: Data, ext: String) throws -> (codec: AudioFormatID, rate: Double, channels: UInt32) {
    let url = temporaryURL(ext)
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    let format = try AVAudioFile(forReading: url).fileFormat
    return (format.streamDescription.pointee.mFormatID, format.sampleRate, format.channelCount)
}

@Suite struct CloudAudioTests {
    /// Gemini's inline budget holds 32 kbps AAC for about 54 minutes; past that, the best rate that fits.
    @Test func aacBitRateThresholds() {
        let budget = OpenRouterClient.maxBase64Bytes
        #expect(CloudAudio.aacBitRate(seconds: 1, budget: budget) == 32_000, "a dictation")
        #expect(CloudAudio.aacBitRate(seconds: 8 * 60, budget: budget) == 32_000)
        #expect(CloudAudio.aacBitRate(seconds: 50 * 60, budget: budget) == 32_000)
        #expect(CloudAudio.aacBitRate(seconds: 60 * 60, budget: budget) == 24_000)
        #expect(CloudAudio.aacBitRate(seconds: 90 * 60, budget: budget) == 16_000)
        #expect(CloudAudio.aacBitRate(seconds: 3 * 3600, budget: budget) == 16_000, "never refused up front")
        #expect(CloudAudio.aacBitRate(seconds: 1, budget: 1_000) == 16_000, "nothing fits: the smallest")
    }

    /// Short or long, a recording goes to Gemini as AAC-LC in an .m4a, 16 kHz mono, never as WAV.
    @Test(arguments: [3.0, 60, 8 * 60])
    func geminiGetsAnM4A(_ seconds: Double) throws {
        let samples = tone(seconds)
        let data = try CloudAudio.forChat(samples)
        #expect(String(decoding: data[4..<8], as: UTF8.self) == "ftyp", "an MPEG-4 file")
        #expect(data.count < WAVEncoder.pcm16(samples).count / 5)
        let encoded = try format(of: data, ext: "m4a")
        #expect(encoded.codec == kAudioFormatMPEG4AAC && encoded.rate == 16_000 && encoded.channels == 1)

        let url = temporaryURL("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let decoded = try AudioFileLoader.load16kMono(url)
        #expect(abs(Double(decoded.count - samples.count) / Double(rate)) <= 0.1)
    }

    /// A recording too long for 32 kbps to fit the budget steps down to a rate that does.
    @Test func aLongRecordingStepsDownToFit() throws {
        let samples = tone(60)
        let budget = 300_000
        #expect(CloudAudio.aacBitRate(seconds: 60, budget: budget) == 24_000)
        let stepped = try CloudAudio.forChat(samples, budget: budget)
        #expect(OpenRouterClient.base64Length(ofByteCount: stepped.count) <= budget)
        #expect(try stepped.count < CloudAudio.forChat(samples).count, "fewer bytes than at 32 kbps")
    }

    /// The header holds just what the file needs: no 20 KB of padding on every recording History keeps.
    @Test func anM4AIsNotPadded() throws {
        #expect(try CloudAudio.m4a(tone(1), bitRate: 32_000).count < 10_000)
    }

    /// A recording History keeps goes to Gemini as its own file, byte for byte, whatever its length; it isn't encoded
    /// a second time unless it's too big for the budget. (The file here is at 24 kbps, so no encoding of the samples
    /// at 32 kbps could pass for it.)
    @Test func historysOwnFileGoesAsItIs() throws {
        let samples = tone(10)
        let url = temporaryURL("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try CloudAudio.writeM4A(samples, bitRate: 24_000, to: url)
        let stored = try Data(contentsOf: url)
        let budget = OpenRouterClient.base64Length(ofByteCount: stored.count)

        #expect(try CloudAudio.m4a(samples, bitRate: RecordingFile.bitRate) != stored)
        #expect(try CloudAudio.forChat(samples, stored: url) == stored)
        #expect(try CloudAudio.forChat(samples, stored: url, budget: budget) == stored)
        let tighter = try CloudAudio.forChat(samples, stored: url, budget: budget - 4)
        #expect(tighter != stored && tighter.count < stored.count, "too big for the budget: encoded to fit it")
        let gone = try CloudAudio.forChat(samples, stored: temporaryURL("m4a"))
        #expect(String(decoding: gone[4..<8], as: UTF8.self) == "ftyp", "no file: encoded from the samples")
    }

    /// `EngineCLI --upload` sends Gemini WAV or FLAC instead, encoded from the samples even when History has a file.
    @Test func anotherFormatCanBeForced() throws {
        let samples = tone(2)
        let url = temporaryURL("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try CloudAudio.writeM4A(samples, bitRate: RecordingFile.bitRate, to: url)
        #expect(try CloudAudio.forChat(samples, stored: url, format: .wav) == WAVEncoder.pcm16(samples))
        #expect(try CloudAudio.forChat(samples, stored: url, format: .flac) == CloudAudio.flac(samples))
        #expect(try CloudAudio.encode(samples, as: .m4a) == CloudAudio.m4a(samples, bitRate: 32_000))
    }

    /// FLAC is lossless: it holds the very 16-bit samples the WAV would, full scale and clipping included, in far fewer
    /// bytes, and reads back as the WAV does.
    @Test func flacRoundTripIsBitExact() throws {
        let samples = noisyTone(20)
        let data = try CloudAudio.flac(samples)
        #expect(data.prefix(4) == Data("fLaC".utf8))
        let wav = WAVEncoder.pcm16(samples)
        #expect(data.count < wav.count * 7 / 10)

        let decoded = try int16Samples(ofFLAC: data)
        #expect(decoded == WAVEncoder.int16(samples))
        #expect(decoded.withUnsafeBytes { Data($0) } == wav.dropFirst(44), "the WAV's samples, bit for bit")
        #expect(Array(decoded.prefix(5)) == [32_767, -32_767, 0, 32_767, -32_767])

        let url = temporaryURL("flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        #expect(try AudioFileLoader.load16kMono(url) == WAVEncoder.decode(wav))
    }

    /// Core Audio can't write FLAC shorter than one packet (4,608 samples): that throws, leaving no broken file.
    @Test func flacNeedsAPacketOfAudio() throws {
        #expect(throws: CloudAudio.EncodeError.self) { try CloudAudio.flac(tone(0.2)) }
        #expect(throws: CloudAudio.EncodeError.self) { try CloudAudio.flac([]) }
        #expect(try int16Samples(ofFLAC: CloudAudio.flac(Array(tone(1).prefix(4_608)))).count == 4_608)
    }

    /// A Parakeet segment goes as FLAC, or as WAV when the FLAC encoder fails.
    @Test func aSegmentGoesAsFLACOrElseWAV() throws {
        struct Broken: Error {}
        let samples = tone(2)
        let flac = CloudAudio.forSpeech(samples, format: .flac)
        #expect(try flac.format == .flac && flac.data == CloudAudio.flac(samples))

        let failed = CloudAudio.forSpeech(samples, format: .flac) { _, _ in throw Broken() }
        #expect(failed.format == .wav && failed.data == WAVEncoder.pcm16(samples))
        let short = CloudAudio.forSpeech(tone(0.2), format: .flac)
        #expect(short.format == .wav && short.data == WAVEncoder.pcm16(tone(0.2)), "too short for FLAC")

        let wav = CloudAudio.forSpeech(samples, format: .wav) { _, _ in
            Issue.record("WAV needs no encoder")
            throw Broken()
        }
        #expect(wav.format == .wav && wav.data == WAVEncoder.pcm16(samples))
        #expect(CloudAudio.forSpeech(samples, format: .m4a).format == .m4a, "`EngineCLI --upload m4a`")
    }

    @Test func aRecordingUpToFiveMinutesIsOneSegment() {
        #expect(CloudAudio.speechSegments(tone(3)) == [0..<(3 * rate)])
        let five = [Float](repeating: 0.1, count: 300 * rate)
        #expect(CloudAudio.speechSegments(five) == [0..<five.count])
        #expect(CloudAudio.speechSegments([]) == [0..<0])
    }

    /// Twelve minutes with a pause shortly before each 5-minute mark: each cut lands in the pause.
    @Test func cutsLandInPauses() {
        let gaps: [ClosedRange<Double>] = [290...291, 585...586]
        let samples = tone(290) + [Float](repeating: 0, count: rate) + tone(294) + [Float](repeating: 0, count: rate)
            + tone(134)
        #expect(samples.count == 720 * rate)
        let ranges = CloudAudio.speechSegments(samples)
        #expect(ranges.count == 3)
        for (cut, gap) in zip(ranges.dropLast().map(\.upperBound), gaps) {
            #expect(gap.contains(Double(cut) / Double(rate)), "cut at \(Double(cut) / Double(rate)) s")
        }
        Self.expectContiguousAndShort(ranges, count: samples.count)
    }

    /// Without a pause, the cuts still keep every segment within 5 minutes.
    @Test func withoutAPauseSegmentsStillFit() {
        let samples = tone(11 * 60)
        let ranges = CloudAudio.speechSegments(samples)
        #expect(ranges.count == 3)
        Self.expectContiguousAndShort(ranges, count: samples.count)
    }

    private static func expectContiguousAndShort(_ ranges: [Range<Int>], count: Int) {
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == count, "every sample")
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound }, "no gap, no overlap")
        #expect(ranges.allSatisfy { !$0.isEmpty && $0.count <= 300 * rate })
    }
}

// MARK: - `EngineCLI --upload`

@Suite struct UploadFlagTests {
    private func options(_ extra: String...) -> EngineCLI.Options? {
        EngineCLI.Options(["transcribe-thing", "--transcribe", "/tmp/memo.m4a"] + extra)
    }

    @Test func uploadForcesAFormatOnACloudModel() throws {
        for format in UploadFormat.allCases {
            #expect(options("--engine", "geminiFlash", "--upload", format.rawValue)?.upload == format)
            #expect(options("--upload", format.rawValue, "--engine", "parakeetCloud")?.upload == format)
        }
        let plain = try #require(options("--engine", "geminiFlash"))
        #expect(plain.upload == nil, "the app's own format")
        #expect(plain.file.path == "/tmp/memo.m4a" && plain.engine == .geminiFlash)

        let all = try #require(options("--engine", "flash", "--upload", "wav", "--repeat", "3", "--effort", "high",
                                       "--prompt", "Verbatim."))
        #expect(all.upload == .wav && all.repeatCount == 3 && all.effort == .high && all.prompt == "Verbatim.")
    }

    @Test func aBadUploadIsAUsageError() {
        #expect(options("--engine", "geminiFlash", "--upload", "ogg") == nil)
        #expect(options("--engine", "geminiFlash", "--upload", "FLAC") == nil)
        #expect(options("--engine", "geminiFlash", "--upload") == nil)
        #expect(options("--engine", "geminiFlash", "--upload", "--repeat", "2") == nil)
        #expect(options("--engine", "parakeet", "--upload", "flac") == nil, "the model on this Mac uploads nothing")
        #expect(EngineCLI.Options.usage.contains("[--upload wav|m4a|flac]"))
        #expect(EngineCLI.handles(["transcribe-thing", "--transcribe", "/tmp/memo.m4a", "--upload", "flac"]))
    }

    @Test func eachRunSaysWhatWentUp() throws {
        #expect(EngineCLI.uploadLine([], input: nil) == nil, "the model on this Mac")
        #expect(EngineCLI.uploadLine([AudioUpload(format: .m4a, bytes: 123_456)], input: nil)
            == "UPLOAD: m4a · 123456 bytes")
        let segments = [AudioUpload(format: .flac, bytes: 4_801_234), AudioUpload(format: .wav, bytes: 9_600_044),
                        AudioUpload(format: .wav, bytes: 44)]
        #expect(EngineCLI.uploadLine(segments, input: nil)
            == "UPLOAD: 3 segments · flac 4801234 + wav 9600044 + wav 44 · 14401322 bytes in all")

        let url = temporaryURL("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: 1_000).write(to: url)
        #expect(EngineCLI.uploadLine([AudioUpload(format: .m4a, bytes: 1_000)], input: url)
            == "UPLOAD: m4a · 1000 bytes · the input file as is")
        #expect(EngineCLI.uploadLine([AudioUpload(format: .m4a, bytes: 900)], input: url) == "UPLOAD: m4a · 900 bytes")
    }

    @Test func eachRunSaysWhatTheAppRecords() {
        let gemini = TranscriptResult(text: "Hi.", engine: .geminiFlash, processingTime: 2.3456, costUSD: 0.00123,
                                      provider: "Google AI Studio", generationID: "gen-1",
                                      usage: TokenUsage(promptTokens: 1_020, audioTokens: 960, completionTokens: 812,
                                                        reasoningTokens: 456),
                                      generationTime: 1.9, timeToFirstToken: 1.234)
        #expect(EngineCLI.usageLine(gemini)
            == "USAGE: tokens audio 960 · prompt 1020 · completion 812 · reasoning 456 · cost $0.001230 · "
            + "provider Google AI Studio · generation gen-1 · first token 1.234 s · generated in 1.900 s · "
            + "total 2.346 s")

        let parakeet = TranscriptResult(text: "Hi.", engine: .parakeetCloud, processingTime: 0.8123, costUSD: 0.00012,
                                        generationID: "gen-2", audioSeconds: 12.5)
        #expect(EngineCLI.usageLine(parakeet) == "USAGE: audio 12.50 s billed · cost $0.000120 · provider ? · "
            + "generation gen-2 · generated in ? s · total 0.812 s")
        let cut = TranscriptResult(text: "Hi.", engine: .geminiFlash, processingTime: 1)
        #expect(EngineCLI.usageLine(cut)
            .hasPrefix("USAGE: tokens audio ? · prompt ? · completion ? · reasoning ? · cost ?"), "a stream cut short")
    }
}

/// What `EngineCLI` finds out about a run beyond its answer: whether an input .m4a is kept as History keeps a
/// recording, and what OpenRouter's generation record adds to the result.
@Suite struct UploadInputAndUsageTests {
    /// Only an .m4a as History keeps it (AAC at 32 kbps, 16 kHz mono) goes to Gemini as it is. The rate is the one its
    /// encoder aimed at, which even a fifth of a second says exactly.
    @Test func anInputGoesAsItIsOnlyAtHistorysRate() throws {
        for (seconds, bitRate) in [(3.0, RecordingFile.bitRate), (0.2, RecordingFile.bitRate), (3, 24_000), (3, 16_000)] {
            let url = temporaryURL("m4a")
            defer { try? FileManager.default.removeItem(at: url) }
            try CloudAudio.writeM4A(tone(seconds), bitRate: bitRate, to: url)
            #expect(EngineCLI.encodedBitRate(of: url) == bitRate, "\(seconds) s at \(bitRate)")
            #expect(EngineCLI.isKeptLikeHistory(url) == (bitRate == RecordingFile.bitRate), "\(seconds) s at \(bitRate)")
        }
        let wav = temporaryURL("wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try WAVEncoder.pcm16(tone(1)).write(to: wav)
        #expect(EngineCLI.encodedBitRate(of: wav) == nil)
        #expect(!EngineCLI.isKeptLikeHistory(wav))
    }

    /// The decoder configuration of an MPEG-4 ES_Descriptor, as History's .m4a keeps it, and with the optional fields
    /// its flags announce; anything short or else is nil.
    @Test func theEncodedRateIsReadFromTheDescriptor() {
        func bytes(_ hex: String) -> [UInt8] {
            stride(from: 0, to: hex.count, by: 2).map {
                UInt8(hex.dropFirst($0).prefix(2), radix: 16)!
            }
        }
        let config = "0480808014" + "40" + "14" + "001800" + "00001e70" + "00007d00" + "05808080021408068080800102"
        #expect(EngineCLI.averageBitRate(esDescriptor: bytes("0380808022" + "0000" + "00" + config)) == 32_000)
        // dependsOn_ES_ID, a 3-byte URL and OCR_ES_Id, and a one-byte size.
        #expect(EngineCLI.averageBitRate(esDescriptor: bytes("0330" + "0000" + "e0" + "0001" + "03616263" + "0002"
                                                             + config)) == 32_000)
        #expect(EngineCLI.averageBitRate(esDescriptor: bytes("0380808022" + "0000" + "00" + config.prefix(30))) == nil)
        #expect(EngineCLI.averageBitRate(esDescriptor: bytes("0580808002" + "1408")) == nil)
        #expect(EngineCLI.averageBitRate(esDescriptor: []) == nil)
    }

    @MainActor
    private func makeService(_ replies: [StubURLProtocol.Reply]) -> (TranscriptionService, String) {
        let (client, host) = StubURLProtocol.client(replies)
        let keychain = KeychainStore.inMemory([KeychainStore.openRouterAccount: "sk-or-v1-test"])
        let account = OpenRouterAccount(keychain: keychain, client: client, debounce: .zero)
        return (TranscriptionService(models: .preview(states: [:]), account: account, client: client,
                                     providerLookupDelay: .milliseconds(10)), host)
    }

    private func record(_ id: String, cost: Double, milliseconds: Double) -> StubURLProtocol.Reply {
        StubURLProtocol.Reply(body: #"{"data":{"id":"\#(id)","api_type":"stt","model":"nvidia/parakeet-tdt-0.6b-v3","provider_name":"Together","total_cost":\#(cost),"generation_time":\#(milliseconds),"created_at":"2026-09-29T10:00:00Z"}}"#)
    }

    private let notRecorded = StubURLProtocol.Reply(status: 404, body: #"{"error":{"code":404,"message":"Generation not found"}}"#)

    /// The ids of the generations looked up, in order.
    private func lookups(_ host: String) -> [String] {
        StubURLProtocol.registry.requests(for: host).compactMap { request in
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "id" }?.value
        }
    }

    private func parakeet(segments ids: [String?], cost: Double?, provider: String? = nil) -> TranscriptResult {
        TranscriptResult(text: "Hi.", engine: .parakeetCloud, processingTime: 1, costUSD: cost, provider: provider,
                         generationID: ids.first ?? nil, audioSeconds: 12.5,
                         uploads: ids.map { AudioUpload(format: .flac, bytes: 1_000, generationID: $0) })
    }

    /// A speech-to-text answer never says how long it took to generate: the record is asked even when the response
    /// named its provider and cost.
    @MainActor
    @Test func theGenerationTimeIsAlwaysLookedUpForSpeech() async {
        let (service, host) = makeService([record("gen-1", cost: 0.0009, milliseconds: 412)])
        var result = parakeet(segments: ["gen-1"], cost: 0.0001, provider: "Together")
        await EngineCLI.fillFromGenerationRecord(&result, service: service)
        #expect(lookups(host) == ["gen-1"])
        #expect(result.generationTime == 0.412)
        #expect(result.costUSD == 0.0001 && result.provider == "Together", "what the response said stays")
    }

    /// A recording in segments asks each segment's generation and adds their times up; a cost the responses gave
    /// stays theirs.
    @MainActor
    @Test func everySegmentsRecordCounts() async throws {
        let (service, host) = makeService([record("gen-1", cost: 0.001, milliseconds: 200),
                                           record("gen-2", cost: 0.001, milliseconds: 300),
                                           record("gen-3", cost: 0.0005, milliseconds: 100)])
        var result = parakeet(segments: ["gen-1", "gen-2", "gen-3"], cost: 0.003)
        await EngineCLI.fillFromGenerationRecord(&result, service: service)
        #expect(lookups(host) == ["gen-1", "gen-2", "gen-3"])
        #expect(abs(try #require(result.generationTime) - 0.6) < 1e-9)
        #expect(result.costUSD == 0.003 && result.provider == "Together")
        #expect(EngineCLI.usageLine(result).contains("provider Together · generation gen-1 · generated in 0.600 s"))
    }

    /// When a segment's record can't be had, no sum stands for the whole recording: its time and cost stay unknown.
    @MainActor
    @Test func aMissingSegmentLeavesTheSumsUnknown() async {
        let (service, host) = makeService([record("gen-1", cost: 0.001, milliseconds: 200), notRecorded, notRecorded])
        var result = parakeet(segments: ["gen-1", "gen-2", "gen-3"], cost: nil)
        await EngineCLI.fillFromGenerationRecord(&result, service: service)
        #expect(lookups(host) == ["gen-1", "gen-2", "gen-2"], "asked twice, as the app does; never gen-3")
        #expect(result.generationTime == nil && result.costUSD == nil)
        #expect(result.provider == "Together")
    }

    /// A result that already says everything asks for nothing.
    @MainActor
    @Test func aCompleteResultAsksNothing() async {
        let (service, host) = makeService([record("gen-1", cost: 1, milliseconds: 1)])
        var result = TranscriptResult(text: "Hi.", engine: .geminiFlash, processingTime: 1, costUSD: 0.001,
                                      provider: "Google AI Studio", generationID: "gen-1", generationTime: 1.9,
                                      uploads: [AudioUpload(format: .m4a, bytes: 1_000, generationID: "gen-1")])
        let before = result
        await EngineCLI.fillFromGenerationRecord(&result, service: service)
        #expect(lookups(host).isEmpty)
        #expect(result == before)
    }
}
