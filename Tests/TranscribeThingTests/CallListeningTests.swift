import AudioToolbox
import Foundation
import Testing
@testable import TranscribeThing

// The tracks kept for listening (`CallListening`): the loudness meter and the limiter they're levelled with, both sides
// brought to one loudness at 48 kHz, the mic cleaned of the other side only where it heard them, and a call's way from
// the journal to the player. The audio is synthetic.

private let rate = Recording.listeningRate

private func sine(_ frequency: Double, seconds: Double, amplitude: Float, rate: Double = rate) -> [Float] {
    (0..<Int(seconds * rate)).map { Float(Double(amplitude) * sin(2 * .pi * frequency * Double($0) / rate)) }
}

/// A voice from `from` to `to` seconds: harmonics on a wandering pitch in syllables with a breathy part, up to 14 kHz,
/// as only 48 kHz keeps. Another `pitch` and `seed` is another person.
private func voice(seconds: Double, pitch: Double, seed: UInt32, level: Double, from: Double = 0,
                   to: Double = .infinity) -> [Float] {
    var seed = seed
    var phase = 0.0
    return (0..<Int(seconds * rate)).map { i in
        let t = Double(i) / rate
        let f0 = pitch * (1 + 0.08 * sin(2 * .pi * 0.7 * t) + 0.04 * sin(2 * .pi * 2.3 * t))
        phase += 2 * .pi * f0 / rate
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let noise = Double(seed >> 8) / Double(1 << 24) - 0.5
        guard t >= from, t < to else { return 0 }
        let inPause = t.truncatingRemainder(dividingBy: 1.3) >= 1.0
        let syllable = inPause ? 0 : pow(sin(.pi * (t * 3.7).truncatingRemainder(dividingBy: 1)), 2)
        var harmonics = 0.0
        for harmonic in 1...60 where Double(harmonic) * f0 < 14_000 {
            harmonics += sin(Double(harmonic) * phase) / Double(harmonic)
        }
        return Float(level * syllable * (0.7 * harmonics + 0.6 * noise))
    }
}

/// `remote` as the mic hears it from the speakers: 30 ms late, through a short room, 9 dB down.
private func echo(of remote: [Float]) -> [Float] {
    let taps: [(delay: Int, gain: Float)] = [(1_440, 0.35), (1_560, 0.15), (1_725, -0.1), (2_070, 0.06), (2_640, 0.03)]
    var out = [Float](repeating: 0, count: remote.count)
    for (delay, gain) in taps {
        for i in delay..<remote.count { out[i] += remote[i - delay] * gain }
    }
    return out
}

private func lufs(_ samples: [Float], rate: Double = rate) -> Double? {
    var meter = LoudnessMeter(rate: rate)
    meter.add(samples)
    return meter.integrated
}

private func dB(_ samples: ArraySlice<Float>) -> Double {
    let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count))
    return 10 * log10(max(energy, 1e-16))
}

/// `samples` as a journal's 16-bit WAV at the listening rate.
private func journalWAV(_ samples: [Float], in folder: URL, _ name: String) throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    var data = RecordingJournal.openHeader(rate: rate)
    WAVEncoder.int16(samples).withUnsafeBytes { data.append(contentsOf: $0) }
    try data.write(to: url)
    return url
}

/// A whole .m4a at 48 kHz, and the rate its file says.
private func readListening(_ url: URL) throws -> (rate: Double, samples: [Float]) {
    var opened: ExtAudioFileRef?
    #expect(ExtAudioFileOpenURL(url as CFURL, &opened) == noErr)
    let file = try #require(opened)
    defer { ExtAudioFileDispose(file) }
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    #expect(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format) == noErr)
    return (format.mSampleRate, try CallAudio.read(url, range: 0..<Int(rate * 3_600), rate: rate))
}

// MARK: - Loudness and the limiter

@Suite struct LoudnessTests {
    /// BS.1770's reference: a 997 Hz sine at full scale in one channel reads -3.01 LUFS, so one 20 dB down reads
    /// -23.01, at 48 kHz and at 16 kHz alike; pauses and silence don't pull it down.
    @Test func measuresLikeTheStandard() throws {
        let tone = sine(997, seconds: 5, amplitude: 0.1)
        #expect(abs(try #require(lufs(tone)) - -23.01) < 0.05)
        // Only the blocks across the tone's end, which the standard counts too, take a little off.
        #expect(abs(try #require(lufs(tone + [Float](repeating: 0, count: Int(30 * rate)))) - -23.01) < 0.2)
        let low = sine(997, seconds: 5, amplitude: 0.1, rate: 16_000)
        #expect(abs(try #require(lufs(low, rate: 16_000)) - -23.01) < 0.1)
        #expect(lufs([Float](repeating: 0, count: Int(rate))) == nil, "silence has no loudness")
        #expect(lufs(sine(997, seconds: 0.3, amplitude: 0.5)) == nil, "shorter than one block")
    }

    @Test func theLimiterKeepsPeaksUnderItsCeilingAndLeavesQuietAudioAlone() {
        var limiter = PeakLimiter(ceiling: 0.891, rate: rate)
        let delay = limiter.lookahead - 1
        let loud = sine(440, seconds: 1, amplitude: 2)
        let out = limiter.process(loud) + limiter.finish()
        #expect(out.count == loud.count + delay)
        #expect(out.allSatisfy { abs($0) <= 0.891 })
        // The whole wave comes down, not just its tops: in the middle it's the input scaled, no flat-topped (clipped)
        // waves.
        let ratios = (24_000..<24_480).compactMap { i in abs(loud[i]) > 0.2 ? out[i + delay] / loud[i] : nil }
        #expect((ratios.max() ?? 0) - (ratios.min() ?? 1) < 0.005)
        #expect(abs((ratios.first ?? 0) - 0.891 / 2) < 0.01)

        var quiet = PeakLimiter(ceiling: 0.891, rate: rate)
        let soft = sine(440, seconds: 1, amplitude: 0.5)
        let passed = quiet.process(soft) + quiet.finish()
        #expect(Array(passed[delay...]) == soft, "under the ceiling, only delayed")

        // A single loud click in a quiet tone: the gain comes down ahead of it, and back up after.
        var click = PeakLimiter(ceiling: 0.891, rate: rate)
        var input = sine(440, seconds: 1, amplitude: 0.3)
        input[24_000] = 3
        let clicked = Array((click.process(input) + click.finish())[delay...])
        #expect(abs(clicked[24_000]) <= 0.891)
        #expect(abs(clicked[24_000 - 1_000] - input[24_000 - 1_000]) < 1e-6, "untouched well before")
        #expect(abs(clicked[24_000 + 24_000 - 1] - input[47_999]) < 0.01, "back up half a second after")
    }
}

// MARK: - Making the listening tracks

@Suite struct CallListeningTests {
    /// A quiet mic and a loud other side come out at one loudness, -16 LUFS, at 48 kHz, as long as they went in, with
    /// their peaks under -1 dBFS; the mic stays silent in its mutes.
    @Test func bothSidesComeOutAtOneLoudness() throws {
        let folder = AppPaths.temporary().calls.appendingPathComponent(UUID().uuidString)
        let mic = voice(seconds: 12, pitch: 210, seed: 2, level: 0.05)
        let remote = voice(seconds: 12, pitch: 125, seed: 1, level: 0.3, from: 1)
        #expect((lufs(mic) ?? 0) < -30 && (lufs(remote) ?? 0) > -20, "far apart as recorded")
        let made = CallListening.make(mic: try journalWAV(mic, in: folder, "mic-48k.wav"),
                                      remote: try journalWAV(remote, in: folder, "remote-48k.wav"), limit: nil,
                                      silencing: [CallInterval(start: 4, end: 6)], cancelEcho: false, in: folder)
        #expect(made.failure == nil && !made.cleanedEcho)
        let micTrack = try #require(made.mic), remoteTrack = try #require(made.remote)
        #expect(micTrack.file == "mic-48k.m4a" && remoteTrack.file == "remote-48k.m4a")
        #expect(micTrack.gainDB > 15 && remoteTrack.gainDB < 5)
        let micOut = try readListening(folder.appendingPathComponent(micTrack.file))
        let remoteOut = try readListening(folder.appendingPathComponent(remoteTrack.file))
        #expect(micOut.rate == 48_000 && remoteOut.rate == 48_000)
        #expect(abs(micOut.samples.count - mic.count) < 2_048 && abs(remoteOut.samples.count - remote.count) < 2_048)
        let micLoudness = try #require(lufs(micOut.samples)), remoteLoudness = try #require(lufs(remoteOut.samples))
        #expect(abs(micLoudness - CallListening.targetLUFS) < 1, "\(micLoudness), was \(micTrack.loudness ?? 0)")
        #expect(abs(remoteLoudness - CallListening.targetLUFS) < 1, "\(remoteLoudness)")
        #expect(micOut.samples.allSatisfy { abs($0) <= 1 } && remoteOut.samples.allSatisfy { abs($0) <= 1 })
        #expect(dB(micOut.samples[Int(4.1 * rate)..<Int(5.9 * rate)]) < -70, "muted")
        // What 16 kHz would have cut off is there: the voice's harmonics above 8 kHz.
        let high = highPassEnergy(micOut.samples[Int(1 * rate)..<Int(3.5 * rate)])
        #expect(high > -45, "\(high) dB above 9 kHz")
        #expect(!((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains { $0.contains("partial") })
    }

    /// On speakers, the mic is cleaned of the other side, at 48 kHz: where only they talked, it's far quieter than
    /// as recorded; where only the person talked, it's as loud as they were.
    @Test func onSpeakersTheOtherSideIsTakenOutOfTheMic() throws {
        let folder = AppPaths.temporary().calls.appendingPathComponent(UUID().uuidString)
        let remote = voice(seconds: 20, pitch: 125, seed: 1, level: 0.2, to: 12)
        let near = voice(seconds: 20, pitch: 210, seed: 2, level: 0.1, from: 12.5)
        let echoed = echo(of: remote)
        let mic = (0..<remote.count).map { echoed[$0] + near[$0] }
        let made = CallListening.make(mic: try journalWAV(mic, in: folder, "mic-48k.wav"),
                                      remote: try journalWAV(remote, in: folder, "remote-48k.wav"), limit: nil,
                                      silencing: [], cancelEcho: true, in: folder)
        #expect(made.cleanedEcho && made.failure == nil)
        let out = try readListening(folder.appendingPathComponent(try #require(made.mic).file)).samples
        let gain = try #require(made.mic).gainDB
        // Compared with the mic as recorded turned up by the same gain.
        let before = dB(mic[Int(6 * rate)..<Int(11 * rate)]) + gain
        let after = dB(out[Int(6 * rate)..<Int(11 * rate)])
        #expect(before - after > 10, "the echo \(before - after) dB down")
        let person = dB(near[Int(14 * rate)..<Int(19 * rate)]) + gain
        #expect(abs(dB(out[Int(14 * rate)..<Int(19 * rate)]) - person) < 2.5, "the person as loud as they were")
        #expect(!((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains { $0.hasPrefix(".") })
    }

    /// A mic that heard next to nothing is turned up no more than 24 dB: not into hiss.
    @Test func aNearlySilentMicIsTurnedUpOnlySoFar() throws {
        let folder = AppPaths.temporary().calls.appendingPathComponent(UUID().uuidString)
        let whisper = voice(seconds: 6, pitch: 200, seed: 4, level: 0.003)
        let made = CallListening.make(mic: try journalWAV(whisper, in: folder, "mic-48k.wav"), remote: nil, limit: nil,
                                      silencing: [], cancelEcho: false, in: folder)
        let mic = try #require(made.mic)
        #expect(mic.gainDB == 24 && (mic.loudness ?? 0) < -40)
    }

    /// A track that has nothing gets no file, and a call with only one side has only that one.
    @Test func onlyTheTracksWithAudio() throws {
        let folder = AppPaths.temporary().calls.appendingPathComponent(UUID().uuidString)
        let empty = try journalWAV([], in: folder, "remote-48k.wav")
        let made = CallListening.make(mic: try journalWAV(voice(seconds: 3, pitch: 200, seed: 3, level: 0.1),
                                                          in: folder, "mic-48k.wav"),
                                      remote: empty, limit: nil, silencing: [], cancelEcho: true, in: folder)
        #expect(made.mic != nil && made.remote == nil && !made.cleanedEcho)
        #expect(CallListening.make(mic: nil, remote: nil, limit: nil, silencing: [], cancelEcho: false,
                                   in: folder).mic == nil)
    }

    /// A call recorded at both rates, ended and handed to `store`.
    @MainActor private func recordedCall(in store: CallStore) async throws -> CallRecord {
        let journal = try #require(store.journal)
        let mic = ListeningSource(), remote = ListeningSource()
        let info = CallJournal.Info(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                    appName: "Telegram", bundleID: "ru.keepcoder.Telegram", service: .telegram,
                                    consent: .kept)
        journal.begin(info, origin: 100, sources: [.mic: mic, .remote: remote])
        let near = voice(seconds: 4, pitch: 210, seed: 2, level: 0.03)
        let far = voice(seconds: 4, pitch: 125, seed: 1, level: 0.3)
        mic.push(StreamingResampler.resample(near, from: rate), listening: near, at: 100)
        remote.push(StreamingResampler.resample(far, from: rate), listening: far, at: 100)
        let ended = try #require(await journal.end(info.id))
        return await store.adopt(ended, status: .unconfirmed)
    }

    /// From the journal to the player: a call recorded at both rates gets its listening tracks after the store takes
    /// it (its transcription doesn't wait for them), and the player plays those from then on; a call without them
    /// plays its 16 kHz tracks.
    @Test @MainActor func theStoreKeepsThemAndThePlayerPlaysThem() async throws {
        let paths = AppPaths.temporary()
        let store = CallStore(paths: paths, settings: .inMemory())
        let journal = try #require(store.journal)
        let adopted = try await recordedCall(in: store)
        let info = adopted
        #expect(adopted.micFile == "mic.m4a" && adopted.remoteFile == "remote.m4a")
        #expect(adopted.listeningMicFile == nil, "not waited for")
        await store.listeningSettled(adopted.id)
        let record = try #require(store.call(id: adopted.id))
        #expect(record.listeningMicFile == "mic-48k.m4a" && record.listeningRemoteFile == "remote-48k.m4a")
        let folder = store.folder(for: info.id)
        #expect(store.playbackURLs(of: record).map(\.lastPathComponent) == ["mic-48k.m4a", "remote-48k.m4a"])
        #expect(store.playbackURLs(of: record).allSatisfy { $0.deletingLastPathComponent() == folder })
        var older = record
        older.listeningMicFile = nil
        older.listeningRemoteFile = nil
        #expect(store.playbackURLs(of: older).map(\.lastPathComponent) == ["mic.m4a", "remote.m4a"])
        // A file gone: the 16 kHz pair, never one of each.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("remote-48k.m4a"))
        #expect(store.playbackURLs(of: record).map(\.lastPathComponent) == ["mic.m4a", "remote.m4a"])
        // The journal's files, the listening ones too, are gone once the store has the call.
        await journal.settle()
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: paths.callJournals.path)) ?? []).isEmpty)
        let reread = try CallStore.readRecords(from: Data(contentsOf: paths.callsFile)).first { $0.id == info.id }
        #expect(reread?.listeningMicFile == "mic-48k.m4a" && reread?.listeningRemoteFile == "remote-48k.m4a")
    }

    /// A call deleted while its listening tracks are being made keeps none, and its folder doesn't come back.
    @Test @MainActor func aCallDeletedMeanwhileKeepsNone() async throws {
        let paths = AppPaths.temporary()
        let store = CallStore(paths: paths, settings: .inMemory())
        let journal = try #require(store.journal)
        let record = try await recordedCall(in: store)
        store.delete(record.id)
        await store.listeningSettled(record.id)
        await store.flush()
        await journal.settle()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: store.folder(for: record.id).path))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: paths.callJournals.path)) ?? []).isEmpty)
    }

    /// Energy above 9 kHz relative to the whole, in dB (a crude two-pole high-pass, enough to tell 48 kHz from 16).
    private func highPassEnergy(_ samples: ArraySlice<Float>) -> Double {
        var filter = Biquad.highPass(9_000, rate: rate)
        var second = Biquad.highPass(9_000, rate: rate)
        let high = samples.map { Float(second.process(filter.process(Double($0)))) }
        return dB(high[...]) - dB(samples)
    }
}

/// A source that hands what it's given, at both rates.
private final class ListeningSource: CallTrackSource, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [TimedAudio] = []

    func push(_ samples: [Float], listening: [Float], at start: TimeInterval?) {
        lock.withLock { pending.append(TimedAudio(samples: samples, listening: listening, start: start)) }
    }

    func start() {}
    func stop() {}
    var problem: String? { nil }
    func drain() -> [TimedAudio] {
        lock.withLock {
            defer { pending = [] }
            return pending
        }
    }
}

private extension Biquad {
    /// A Butterworth high-pass at `frequency` (RBJ's cookbook).
    static func highPass(_ frequency: Double, rate: Double) -> Biquad {
        let w = 2 * Double.pi * frequency / rate, alpha = sin(w) / (2 * 0.7071)
        let a0 = 1 + alpha
        return Biquad(b0: (1 + cos(w)) / 2 / a0, b1: -(1 + cos(w)) / a0, b2: (1 + cos(w)) / 2 / a0,
                      a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0)
    }
}
