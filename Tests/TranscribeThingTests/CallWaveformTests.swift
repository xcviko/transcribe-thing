import Foundation
import Testing
@testable import TranscribeThing

// The call page's waveform: how loud each bar is (`CallPeaks`: the tracks' buckets, normalized, resampled to the bars,
// kept in peaks.bin), and whose color it wears (`CallWaveform`: who speaks at its time).

private func segment(_ start: TimeInterval, _ end: TimeInterval, _ speaker: String, _ side: CallSide = .remote,
                     muted: Bool = false) -> CallTranscript.Segment {
    CallTranscript.Segment(start: start, end: end, side: side, speaker: speaker, text: "…", duringMute: muted)
}

@Suite struct CallPeaksTests {
    @Test func normalizesByThe97thPercentileNotTheLoudest() {
        // 99 buckets at 0.5 and one click at 1: the click doesn't make the rest half as tall.
        var values = [Float](repeating: 0.5, count: 99)
        values.append(1)
        let normalized = CallPeaks.normalized(values)
        #expect(normalized.prefix(99).allSatisfy { $0 == 1 })
        #expect(normalized.last == 1, "louder than the reference stays at the top")
        let ramp = (1...100).map { Float($0) / 100 }
        let scaled = CallPeaks.normalized(ramp)
        // The 97th percentile is 0.98: 0.49 is half of it.
        #expect(abs(scaled[48] - 0.5) < 0.001)
    }

    @Test func aCallMostlySilentKeepsItsHumLow() {
        // Half an hour that spoke only in its first minute: 98 bars of hum, 2 of speech.
        let values = [Float](repeating: 0.5, count: 2) + [Float](repeating: 0.02, count: 98)
        let normalized = CallPeaks.normalized(values)
        #expect(normalized.prefix(2).allSatisfy { $0 == 1 })
        #expect(normalized.suffix(98).allSatisfy { $0 < 0.15 }, "not the hum scaled up to the top")
        // A call that's all hum (nobody spoke) stays low too.
        #expect(CallPeaks.normalized([Float](repeating: 0.004, count: 50)).allSatisfy { $0 < 0.15 })
    }

    @Test func silenceStillShowsAsADot() {
        let normalized = CallPeaks.normalized([0, 0.001, 1, 1])
        #expect(normalized[0] == 0.05)
        #expect(normalized[1] == 0.05)
        #expect(CallPeaks.normalized([0, 0, 0]) == [0.05, 0.05, 0.05], "all silent: nothing to divide by")
        #expect(CallPeaks.normalized([]) == [])
    }

    @Test func resamplesToTheBarCount() {
        // Fewer bars: each the mean of what it covers.
        #expect(CallPeaks.resample([0, 1, 1, 1, 0.5, 0.5], to: 3) == [0.5, 1, 0.5])
        // More bars: each the value it falls in.
        #expect(CallPeaks.resample([0.2, 0.8], to: 4) == [0.2, 0.2, 0.8, 0.8])
        #expect(CallPeaks.resample([0.3, 0.6, 0.9], to: 2).count == 2)
        #expect(CallPeaks.resample([], to: 5) == [])
        #expect(CallPeaks.resample([1], to: 0) == [])
        // Not a multiple: every value goes to some bar, none past the end.
        let odd = CallPeaks.resample((0..<1000).map { Float($0) / 1000 }, to: 7)
        #expect(odd.count == 7)
        #expect(odd == odd.sorted())
    }

    @Test func barsCoverTheWholeCall() {
        // Ten seconds read, a call of twenty: the second half is silent.
        let peaks = CallPeaks(values: [Float](repeating: 0.4, count: 200))
        let bars = peaks.bars(4, duration: 20)
        #expect(bars == [1, 1, 0.05, 0.05])
        #expect(peaks.bars(0) == [])
        #expect(CallPeaks(values: []).bars(3) == [0.05, 0.05, 0.05])
    }

    @Test func bucketsTakeTheLouderTrackAcrossBlocks() {
        var accumulator = CallPeaks.Accumulator()
        // 1000 samples in blocks of 300: a bucket is 800, so the first block boundary falls inside bucket 0.
        var mic = [Float](repeating: 0.1, count: 1000)
        mic[700] = -0.6
        mic[900] = 0.3
        for start in stride(from: 0, to: mic.count, by: 300) {
            accumulator.add(Array(mic[start..<min(mic.count, start + 300)]))
        }
        #expect(accumulator.values == [0.6, 0.3])
        accumulator.nextTrack()
        var remote = [Float](repeating: 0, count: 2000)
        remote[100] = 0.2
        remote[1200] = 0.9
        remote[1700] = 0.4
        accumulator.add(remote)
        #expect(accumulator.values == [0.6, 0.9, 0.4], "the longer track adds its buckets")
    }

    // MARK: The cache

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("peaks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A 16 kHz tone `seconds` long, at `level` in its second half.
    private func track(_ url: URL, seconds: Double, level: Float = 0.5) throws {
        let count = Int(seconds * Recording.sampleRate)
        let samples = (0..<count).map { index -> Float in
            index < count / 2 ? 0 : level * sin(Float(index) * 2 * .pi * 440 / Float(Recording.sampleRate))
        }
        try CloudAudio.writeM4A(samples, bitRate: RecordingFile.bitRate, to: url)
    }

    @Test func readsBothTracksAndKeepsThePeaks() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.m4a"), remote = dir.appendingPathComponent("remote.m4a")
        try track(mic, seconds: 2, level: 0.2)
        try track(remote, seconds: 3, level: 0.8)
        let peaks = try #require(CallPeaks.load(tracks: [mic, remote], folder: dir))
        // Three seconds of 50 ms buckets (the encoder may add a little).
        #expect((59...64).contains(peaks.values.count))
        #expect(peaks.values.prefix(18).allSatisfy { $0 < 0.05 }, "the first second of both is silent")
        #expect((peaks.values.max() ?? 0) > 0.6, "the remote's louder half")
        let cache = dir.appendingPathComponent(CallPeaks.fileName)
        #expect(FileManager.default.fileExists(atPath: cache.path))
        #expect(try Data(contentsOf: cache).count < 400)
        // Read back from the cache, the same to 16 bits.
        let again = try #require(CallPeaks.load(tracks: [mic, remote], folder: dir))
        #expect(again.values.count == peaks.values.count)
        #expect(zip(again.values, peaks.values).allSatisfy { abs($0 - $1) < 0.0001 })
    }

    @Test func aRewrittenTrackMakesTheCacheStale() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.m4a")
        try track(mic, seconds: 2)
        let first = try #require(CallPeaks.load(tracks: [mic], folder: dir))
        // Joined onto: longer, and newer.
        try track(mic, seconds: 4)
        let second = try #require(CallPeaks.load(tracks: [mic], folder: dir))
        #expect(second.values.count > first.values.count + 30)
        // The cache is the new one's.
        let data = try Data(contentsOf: dir.appendingPathComponent(CallPeaks.fileName))
        #expect(CallPeaks.decode(data, sources: [CallPeaks.Source.of(mic)])?.values.count == second.values.count)
    }

    @Test func aCacheOfOtherFilesIsNotRead() {
        let peaks = CallPeaks(values: [0.1, 0.5, 1])
        let sources: [CallPeaks.Source?] = [CallPeaks.Source(size: 100, modified: 5), nil]
        let data = CallPeaks.encode(peaks, sources: sources)
        #expect(CallPeaks.decode(data, sources: sources)?.values.count == 3)
        #expect(CallPeaks.decode(data, sources: [CallPeaks.Source(size: 101, modified: 5), nil]) == nil)
        #expect(CallPeaks.decode(data, sources: [CallPeaks.Source(size: 100, modified: 6), nil]) == nil)
        #expect(CallPeaks.decode(data, sources: [sources[0]]) == nil, "a track more or less")
        #expect(CallPeaks.decode(data.prefix(data.count - 1), sources: sources) == nil, "cut short")
        #expect(CallPeaks.decode(Data("not peaks".utf8), sources: sources) == nil)
    }

    @Test func aMissingTrackIsSkippedAndNoAudioIsNone() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.m4a"), remote = dir.appendingPathComponent("remote.m4a")
        #expect(CallPeaks.load(tracks: [mic, remote], folder: dir) == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(CallPeaks.fileName).path))
        try track(remote, seconds: 1)
        let peaks = try #require(CallPeaks.load(tracks: [mic, remote], folder: dir))
        #expect((19...23).contains(peaks.values.count))
        // An unreadable file: nothing to draw from it.
        let broken = dir.appendingPathComponent("broken.m4a")
        try Data("not audio".utf8).write(to: broken)
        #expect(CallPeaks.load(tracks: [broken], folder: try folder()) == nil)
    }

    /// An hour's two tracks read for the waveform: `WAVEFORM_BENCHMARK=1 swift test --filter benchmarkAnHour`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WAVEFORM_BENCHMARK"] == "1"))
    func benchmarkAnHour() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = [dir.appendingPathComponent("mic.m4a"), dir.appendingPathComponent("remote.m4a")]
        for url in urls {
            try CloudAudio.writeM4A(bitRate: RecordingFile.bitRate, reservingSeconds: 3600, to: url) { append in
                for minute in 0..<60 {
                    do {
                        let samples = (0..<Int(60 * Recording.sampleRate)).map { index -> Float in
                            0.3 * sin(Float(index + minute) * 0.07) * (index % 16_000 < 9_000 ? 1 : 0.05)
                        }
                        try append(samples)
                    }
                }
            }
        }
        let began = Date()
        let peaks = try #require(CallPeaks.load(tracks: urls, folder: dir))
        let read = Date().timeIntervalSince(began)
        let cachedBegan = Date()
        _ = CallPeaks.load(tracks: urls, folder: dir)
        let cached = Date().timeIntervalSince(cachedBegan)
        let size = try Data(contentsOf: dir.appendingPathComponent(CallPeaks.fileName)).count
        print("Waveform of an hour: read in \(read) s, from the cache in \(cached) s, \(peaks.values.count) buckets, peaks.bin \(size) bytes")
        #expect(peaks.values.count >= 72_000)
    }
}

@Suite struct CallWaveformTests {
    @Test func theSpeakerIsWhoeverCoversTheTime() {
        let segments = [segment(0, 5, "Аня"), segment(5, 8, "Sam", .local), segment(10, 12, "Аня")]
        #expect(CallWaveform.segment(at: 0, in: segments)?.speaker == "Аня")
        #expect(CallWaveform.segment(at: 4.99, in: segments)?.speaker == "Аня")
        #expect(CallWaveform.segment(at: 5, in: segments)?.speaker == "Sam", "an end is not part of the phrase")
        #expect(CallWaveform.segment(at: 9, in: segments) == nil, "a pause")
        #expect(CallWaveform.segment(at: 12, in: segments) == nil)
        #expect(CallWaveform.segment(at: -1, in: []) == nil)
    }

    @Test func overlapsGoToWhoStartedLast() {
        let segments = [segment(0, 10, "Аня"), segment(3, 5, "Sam", .local), segment(4, 6, "Matvey")]
        #expect(CallWaveform.segment(at: 3.5, in: segments)?.speaker == "Sam")
        #expect(CallWaveform.segment(at: 4.5, in: segments)?.speaker == "Matvey")
        #expect(CallWaveform.segment(at: 5.5, in: segments)?.speaker == "Matvey")
        #expect(CallWaveform.segment(at: 7, in: segments)?.speaker == "Аня", "back to who's still speaking")
        // Out of order in the transcript: by time all the same.
        #expect(CallWaveform.segment(at: 4.5, in: segments.reversed())?.speaker == "Matvey")
    }

    @Test func aPhraseWithoutAnEndLastsUntilTheNext() {
        let segments = [segment(0, 0, "Аня"), segment(6, 4, "Sam", .local), segment(9, 10, "Matvey")]
        #expect(CallWaveform.segment(at: 5, in: segments)?.speaker == "Аня")
        #expect(CallWaveform.segment(at: 7, in: segments)?.speaker == "Sam")
        #expect(CallWaveform.segment(at: 9.5, in: segments)?.speaker == "Matvey")
        #expect(CallWaveform.segment(at: 100, in: [segment(3, 0, "Аня")])?.speaker == "Аня", "the last one: to the end")
    }

    @Test func manyTimesInOneSweep() {
        let segments = [segment(0, 2, "A"), segment(1, 3, "B"), segment(5, 6, "C")]
        let times: [TimeInterval] = [0.5, 1.5, 2.5, 4, 5.5, 7]
        #expect(CallWaveform.segments(at: times, in: segments).map { $0?.speaker } == ["A", "B", "B", nil, "C", nil])
    }

    @Test func tonesFollowTheSpeakersSlotsAndMutes() {
        let transcript = CallTranscript(segments: [segment(0, 5, "Participant 1"), segment(5, 10, "Sam", .local),
                                                   segment(10, 15, "Sam", .local, muted: true)])
        let tones = CallWaveform.tones(count: 4, duration: 20, transcript: transcript)
        #expect(tones == [.speaker(CallSpeakerSlot(side: .remote, index: 0), muted: false),
                          .speaker(CallSpeakerSlot(side: .local, index: 0), muted: false),
                          .speaker(CallSpeakerSlot(side: .local, index: 0), muted: true),
                          .silence])
        #expect(CallWaveform.tones(count: 3, duration: 20, transcript: nil) == [.unknown, .unknown, .unknown])
        #expect(CallWaveform.tones(count: 2, duration: 20, transcript: CallTranscript(segments: [])) == [.silence, .silence],
                "transcribed, nobody spoke")
        #expect(CallWaveform.tones(count: 2, duration: 0, transcript: transcript) == [.silence, .silence])
    }

    @Test func flatBarsBeforeTheLoudnessIsKnown() {
        let tones: [CallWaveform.Tone] = [.silence, .speaker(nil, muted: false), .unknown]
        #expect(CallWaveform.heights(tones: tones, peaks: nil, duration: 10) == [0.06, 0.42, 0.06])
        #expect(CallWaveform.heights(tones: Array(tones.prefix(2)), peaks: CallPeaks(values: [0, 1]), duration: 0.1)
                == [0.05, 1])
    }

    @MainActor @Test func thePlayerStartsWhereItIsToldAndIdle() {
        let player = CallPlayer(id: UUID(), urls: [], duration: 100, position: 30)
        #expect(player.currentTime == 30)
        #expect(player.isIdle, "the waveform's first click plays")
        #expect(player.livePosition == 30, "not playing: the playhead stays where it is")
    }

    @Test func barCountFollowsTheWidthWithAFloor() {
        #expect(CallWaveform.barCount(width: 400) == 100)
        #expect(CallWaveform.barCount(width: 401) == 100)
        #expect(CallWaveform.barCount(width: 40) == 24)
        #expect(CallWaveform.barCount(width: 0) == 24)
    }

    @Test func aRenameKeepsTheColorsAndNamesTheLegend() {
        var call = CallRecord(id: UUID(), startedAt: Date(), appName: "Google Chrome", status: .done)
        call.micSeconds = 30
        call.transcript = CallTranscript(segments: [segment(0, 5, "Participant 1"), segment(5, 10, "Sam", .local),
                                                    segment(10, 15, "Аня"), segment(15, 20, "Participant 1")])
        let before = CallWaveform.tones(count: 30, duration: 30, transcript: call.transcript)
        let legendBefore = CallWaveform.legend(call)
        call.speakerNames = ["Participant 1": "Matvey"]
        #expect(CallWaveform.tones(count: 30, duration: 30, transcript: call.transcript) == before)
        let legend = CallWaveform.legend(call)
        #expect(legend.map(\.name) == ["Matvey", "Sam", "Аня"], "in the order they first speak, as renamed")
        #expect(legend.map(\.slot) == legendBefore.map(\.slot))
        #expect(legend.map(\.slot) == [CallSpeakerSlot(side: .remote, index: 0), CallSpeakerSlot(side: .local, index: 0),
                                       CallSpeakerSlot(side: .remote, index: 1)])
        call.transcript = nil
        #expect(CallWaveform.legend(call).isEmpty)
    }
}
