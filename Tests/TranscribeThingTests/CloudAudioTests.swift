import AVFoundation
import Foundation
import Testing
@testable import TranscribeThing

// How a recording of any length goes to Gemini: AAC, and the format `EngineCLI --upload` forces instead.

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

private func temporaryURL(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cloud-audio-\(UUID().uuidString).\(ext)")
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

    /// `EngineCLI --upload` sends Gemini WAV instead, encoded from the samples even when History has a file.
    @Test func anotherFormatCanBeForced() throws {
        let samples = tone(2)
        let url = temporaryURL("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try CloudAudio.writeM4A(samples, bitRate: RecordingFile.bitRate, to: url)
        #expect(try CloudAudio.forChat(samples, stored: url, format: .wav) == WAVEncoder.pcm16(samples))
        #expect(try CloudAudio.encode(samples, as: .m4a) == CloudAudio.m4a(samples, bitRate: 32_000))
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
            #expect(options("--upload", format.rawValue, "--engine", "geminiArgon")?.upload == format)
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
        #expect(options("--engine", "geminiFlash", "--upload", "flac") == nil, "FLAC went with cloud Parakeet")
        #expect(options("--engine", "geminiFlash", "--upload") == nil)
        #expect(options("--engine", "geminiFlash", "--upload", "--repeat", "2") == nil)
        #expect(options("--engine", "parakeet", "--upload", "wav") == nil, "the model on this Mac uploads nothing")
        #expect(EngineCLI.Options.usage.contains("[--upload wav|m4a]"))
        #expect(EngineCLI.handles(["transcribe-thing", "--transcribe", "/tmp/memo.m4a", "--upload", "wav"]))
    }

    @Test func eachRunSaysWhatWentUp() throws {
        #expect(EngineCLI.uploadLine([], input: nil) == nil, "the model on this Mac")
        #expect(EngineCLI.uploadLine([AudioUpload(format: .m4a, bytes: 123_456)], input: nil)
            == "UPLOAD: m4a · 123456 bytes")

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
        let keyStore = KeyFileStore.inMemory("sk-or-v1-test")
        let account = OpenRouterAccount(keyStore: keyStore, client: client, debounce: .zero)
        return (TranscriptionService(models: .preview(states: [:]), account: account, client: client,
                                     providerLookupDelay: .milliseconds(10)), host)
    }

    private func record(_ id: String, cost: Double, milliseconds: Double) -> StubURLProtocol.Reply {
        StubURLProtocol.Reply(body: #"{"data":{"id":"\#(id)","api_type":"chat","model":"google/gemini-4-argon","provider_name":"Google AI Studio","total_cost":\#(cost),"generation_time":\#(milliseconds),"created_at":"2026-09-29T10:00:00Z"}}"#)
    }

    private let notRecorded = StubURLProtocol.Reply(status: 404, body: #"{"error":{"code":404,"message":"Generation not found"}}"#)

    /// The ids of the generations looked up, in order.
    private func lookups(_ host: String) -> [String] {
        StubURLProtocol.registry.requests(for: host).compactMap { request in
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "id" }?.value
        }
    }

    /// A result missing its generation time and cost asks the record once; what the response said stays.
    @MainActor
    @Test func theRecordFillsInWhatTheResponseLeftOut() async {
        let (service, host) = makeService([record("gen-1", cost: 0.0009, milliseconds: 412)])
        var result = TranscriptResult(text: "Hi.", engine: .geminiArgon, processingTime: 1,
                                      provider: "Google AI Studio", generationID: "gen-1")
        await EngineCLI.fillFromGenerationRecord(&result, service: service)
        #expect(lookups(host) == ["gen-1"])
        #expect(result.generationTime == 0.412 && result.costUSD == 0.0009)
        #expect(result.provider == "Google AI Studio")
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
