import Foundation
import Testing
import WhisperKit
@testable import MurmurApp

/// WhisperKit's VAD chunker must hand every recorded sample to the decoder, even when a chunk boundary lands
/// inside the last second.
@Suite struct WhisperChunkingTests {
    private static let rate = 16_000

    private func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(Self.rate))).map { 0.2 * sin(Float($0) * 2 * .pi * 220 / Float(Self.rate)) }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(Self.rate)))
    }

    /// The end of the last chunk the chunker returns.
    private func coveredEnd(of audio: [Float]) async throws -> Int {
        let chunks = try await VADAudioChunker().chunkAll(
            audioArray: audio, maxChunkLength: Constants.defaultWindowSamples,
            decodeOptions: WhisperEngine.decodingOptions(language: nil))
        return chunks.map { $0.seekOffsetIndex + $0.audioSamples.count }.max() ?? 0
    }

    @Test func aLastWordAfterAPauseNearTheEndIsKept() async throws {
        // 30.5 s: talking, a pause at 29.2–30.0 s, then one last word.
        let audio = tone(29.2) + silence(0.8) + tone(0.5)
        #expect(try await coveredEnd(of: audio) < audio.count, "WhisperKit alone drops the last word")
        #expect(try await coveredEnd(of: WhisperEngine.paddedForChunking(audio)) >= audio.count)
    }

    @Test func talkingStraightThroughThe30SecondMarkIsKept() async throws {
        let audio = tone(30.8)
        #expect(try await coveredEnd(of: WhisperEngine.paddedForChunking(audio)) >= audio.count)
    }

    @Test func oneWindowOrLessIsLeftAlone() {
        let audio = tone(30)
        #expect(WhisperEngine.paddedForChunking(audio) == audio)
        let long = tone(31)
        let padded = WhisperEngine.paddedForChunking(long)
        #expect(padded.count == long.count + Self.rate)
        #expect(padded.suffix(Self.rate).allSatisfy { $0 == 0 })
    }
}
