import Foundation
import Testing
@testable import TranscribeThing

// Taking the other side's voices out of a call's mic (`EchoCanceller`), where the store does it (`CallStore.adopt`),
// and the measuring tool's refusal to write into the app's data (`CallsEchoCLI`). The echo is synthetic: the other
// side's track delayed, filtered and turned down, the way laptop speakers reach the mic.

private let rate = Recording.sampleRate

/// A voice from `from` to `to` seconds of a `seconds`-long track: harmonics on a wandering pitch in syllables with a
/// breathy part, broadband like speech. Another `pitch` and `seed` is another person.
private func voice(seconds: Double, pitch: Double, seed: UInt32, from: Double = 0, to: Double = .infinity) -> [Float] {
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
        for harmonic in 1...15 where Double(harmonic) * f0 < 7_000 {
            harmonics += sin(Double(harmonic) * phase) / Double(harmonic)
        }
        return Float(0.1 * syllable * (0.7 * harmonics + 0.6 * noise))
    }
}

/// `remote` as the mic hears it from the speakers: 30 ms late, through a short room, 9 dB down.
private func echo(of remote: [Float]) -> [Float] {
    let taps: [(delay: Int, gain: Float)] = [(480, 0.35), (520, 0.15), (575, -0.1), (690, 0.06), (880, 0.03)]
    var out = [Float](repeating: 0, count: remote.count)
    for (delay, gain) in taps {
        for i in delay..<remote.count { out[i] += remote[i - delay] * gain }
    }
    return out
}

/// The room's faint noise, about -72 dBFS.
private func floor(seconds: Double) -> [Float] {
    var seed: UInt32 = 99
    return (0..<Int(seconds * rate)).map { _ in
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(Double(seed >> 8) / Double(1 << 24) - 0.5) * 0.001
    }
}

/// A 12 s call: the other side talks for the first 8 s, then the person alone from 8.3 s.
private struct EchoScene {
    let remote = voice(seconds: 12, pitch: 125, seed: 1, to: 8)
    let near = voice(seconds: 12, pitch: 210, seed: 2, from: 8.3)
    var mic: [Float] {
        let echoed = echo(of: remote), noise = floor(seconds: 12)
        return (0..<remote.count).map { echoed[$0] + near[$0] + noise[$0] }
    }
}

private func slice(_ samples: [Float], _ from: Double, _ to: Double) -> ArraySlice<Float> {
    samples[Int(from * rate)..<min(samples.count, Int(to * rate))]
}

private func dB(_ samples: ArraySlice<Float>) -> Double {
    let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count))
    return 10 * log10(max(energy, 1e-16))
}

/// Runs `mic` through a canceller in uneven blocks, as the store's reads come.
private func cancel(_ mic: [Float], reference: [Float], settings: EchoCanceller.Settings = .standard) -> [Float] {
    cancelling(mic, reference: reference, settings: settings).out
}

private func cancelling(_ mic: [Float], reference: [Float], settings: EchoCanceller.Settings = .standard)
    -> (out: [Float], summary: EchoCanceller.Summary) {
    let canceller = EchoCanceller(settings: settings)
    var out: [Float] = []
    var start = 0
    while start < mic.count {
        let end = min(mic.count, start + 3_001)
        let far = Array(reference[min(start, reference.count)..<min(end, reference.count)])
        out += canceller.process(mic: Array(mic[start..<end]), reference: far)
        start = end
    }
    out += canceller.finish()
    return (out, canceller.summary)
}

/// Clicks at frame edges (`CallsEchoCLI.FrameEdgeJumps`).
private func edgeJumps(_ samples: some Collection<Float>) -> Int {
    var jumps = CallsEchoCLI.FrameEdgeJumps(frame: EchoCanceller.Settings.standard.frame)
    jumps.add(Array(samples))
    return jumps.count
}

/// A call on headphones: the other side talks all along, the person from 0.65 s, often over them, and the mic never
/// hears the other side. Loud, so its own sample-to-sample jumps reach `FrameEdgeJumps.threshold`.
private struct HeadphonesScene {
    let remote: [Float]
    let mic: [Float]

    init(seconds: Double = 20) {
        remote = voice(seconds: seconds, pitch: 125, seed: 1)
        let near = voice(seconds: seconds, pitch: 210, seed: 2, from: 0.65)
        let noise = floor(seconds: seconds)
        mic = quantized((0..<near.count).map { 4 * near[$0] + noise[$0] })
    }
}

/// `samples` as the journal's 16-bit WAV keeps them.
private func quantized(_ samples: [Float]) -> [Float] {
    samples.map { Float(Int16(clamping: Int(($0 * 32_768).rounded()))) / 32_768 }
}

/// Settings that never use the canceller's version, and that always do.
private var neverCancelling: EchoCanceller.Settings {
    var settings = EchoCanceller.Settings.standard
    settings.minimumERLE = .infinity
    return settings
}

private var alwaysCancelling: EchoCanceller.Settings {
    var settings = EchoCanceller.Settings.standard
    settings.gate = false
    return settings
}

@Suite struct EchoCancellerTests {
    @Test func theEchoGoesAndThePersonStays() {
        let call = EchoScene()
        let mic = call.mic
        let out = cancel(mic, reference: call.remote)
        #expect(out.count == mic.count)
        // Once the filter has learned the room: at least 15 dB less of the other side.
        let erle = dB(slice(mic, 3, 8)) - dB(slice(out, 3, 8))
        #expect(erle >= 15, "ERLE \(erle) dB")
        // The person alone keeps their level, within a few dB.
        let near = dB(slice(out, 8.6, 12)) - dB(slice(mic, 8.6, 12))
        #expect(abs(near) <= 3, "near end \(near) dB")
    }

    @Test func aMuteStaysSilentAndTheFilterRemembersTheRoom() {
        let call = EchoScene()
        var mic = call.mic
        for i in Int(4 * rate)..<Int(5 * rate) { mic[i] = 0 }
        let out = cancel(mic, reference: call.remote)
        #expect(out[Int(4 * rate)..<Int(5 * rate)].allSatisfy { $0 == 0 })
        // Right after the mute, the echo is as gone as before it.
        let erle = dB(slice(mic, 5.1, 8)) - dB(slice(out, 5.1, 8))
        #expect(erle >= 15, "ERLE after the mute \(erle) dB")
    }

    @Test func theMeterSeesTheEchoGo() {
        let call = EchoScene()
        let mic = call.mic
        let out = cancel(mic, reference: call.remote)
        var meter = EchoMeter()
        meter.add(raw: mic, remote: call.remote)
        meter.add(cleaned: out)
        let stats = meter.result()
        #expect(stats.remoteOnlyFrames > 50 && stats.nearOnlyFrames > 30)
        #expect((stats.echoReductionDB ?? 0) >= 15)
        #expect(stats.after.strongestCorrelation.value < stats.before.strongestCorrelation.value)
        // Where only the other side talks, the mic followed them closely, and no longer does.
        var echoOnly = EchoMeter()
        echoOnly.add(raw: Array(mic.prefix(Int(8 * rate))), remote: Array(call.remote.prefix(Int(8 * rate))))
        echoOnly.add(cleaned: Array(out.prefix(Int(8 * rate))))
        let echoStats = echoOnly.result()
        #expect(echoStats.before.strongestCorrelation.value > 0.9 && echoStats.before.strongestCorrelation.lagMS == 30)
        #expect(echoStats.after.strongestCorrelation.value < 0.6)
        #expect(stats.before.overlapFraction > stats.after.overlapFraction)
        #expect(abs((stats.after.nearDBFS ?? 0) - (stats.before.nearDBFS ?? 0)) <= 3)
    }

    @Test func withoutEchoTheCancellersVersionIsNeverUsedAndNothingClicks() {
        let call = HeadphonesScene()
        var mic = call.mic
        for i in Int(5 * rate)..<Int(6 * rate) { mic[i] = 0 }
        let (out, summary) = cancelling(mic, reference: call.remote)
        #expect(out.count == mic.count)
        #expect(summary.hops == 4 && summary.echoHops == 0, "\(summary.erle)")
        // Exactly the recorded mic's version, as if the canceller were never trusted.
        #expect(out == cancel(mic, reference: call.remote, settings: neverCancelling))
        // The person keeps their level; the mute stays digital silence.
        let near = dB(slice(out, 1, 5)) - dB(slice(mic, 1, 5))
        #expect(abs(near) <= 3, "near end \(near) dB")
        #expect(out[Int(5 * rate)..<Int(6 * rate)].allSatisfy { $0 == 0 })
        // No click at a frame's edge that the mic didn't have.
        let before = edgeJumps(mic), after = edgeJumps(out)
        #expect(before > 0 && after <= before, "\(before) as recorded, \(after) after")
    }

    @Test func withNothingElseToDoAMicWithoutEchoComesOutAsRecorded() {
        // No preprocessor: the mic's own version is the mic, bit for bit, on the same clock.
        var settings = EchoCanceller.Settings.standard
        settings.preprocess = false
        let call = HeadphonesScene()
        #expect(cancel(call.mic, reference: call.remote, settings: settings) == call.mic)
    }

    @Test func echoThatStartsLaterIsTakenOutFromThereAfterAFade() throws {
        // 40 s, the other side talking all along: the first 20 s on headphones (the person talks, the mic doesn't
        // hear the other side), then on speakers (the mic hears them, the person is quiet).
        let seconds = 40.0
        let remote = voice(seconds: seconds, pitch: 125, seed: 1)
        let near = voice(seconds: seconds, pitch: 210, seed: 2, from: 0.65, to: 18)
        let echoed = echo(of: remote), noise = floor(seconds: seconds)
        let speakers = Int(20 * rate)
        let mic = quantized((0..<remote.count).map { near[$0] + noise[$0] + ($0 >= speakers ? echoed[$0] : 0) })
        let (out, summary) = cancelling(mic, reference: remote)
        #expect(summary.echoHops > 0 && summary.echoHops < summary.hops, "\(summary.erle)")
        let plain = cancel(mic, reference: remote, settings: neverCancelling)
        let cleaned = cancel(mic, reference: remote, settings: alwaysCancelling)
        // The recorded mic's version up to the fade, the canceller's from its end: one fade, before the echo starts.
        let first = try #require(out.indices.first { out[$0] != plain[$0] })
        let last = try #require(out.indices.last { out[$0] != cleaned[$0] })
        #expect(first >= Int(5 * rate) && last < speakers, "fade \(first)...\(last)")
        #expect(last - first >= 800 && last - first <= 3_200, "fade \(last - first) samples")
        // Through the fade the mix moves smoothly from one to the other, and no sample jumps further than in either.
        // (The mix is read where the two versions differ enough to read it, and compared 1 ms apart at most.)
        var mix: (value: Double, at: Int)?
        var rough = 0, jumps = 0
        for i in first...last + 1 {
            let step = abs(out[i] - out[i - 1])
            if step > max(abs(plain[i] - plain[i - 1]), abs(cleaned[i] - cleaned[i - 1])) + 0.002 { jumps += 1 }
            guard abs(cleaned[i] - plain[i]) > 0.01 else { continue }
            let now = Double((out[i] - plain[i]) / (cleaned[i] - plain[i]))
            if let mix, i - mix.at <= 16, abs(now - mix.value) > 0.05 { rough += 1 }
            mix = (now, i)
        }
        #expect(rough == 0 && jumps == 0, "\(rough) rough steps, \(jumps) jumps")
        // Once the filter has learned the speakers: at least 15 dB less of the other side.
        let erle = dB(slice(mic, 25, 40)) - dB(slice(out, 25, 40))
        #expect(erle >= 15, "ERLE \(erle) dB")
    }
}

@MainActor @Suite(.serialized) struct CallEchoStoreTests {
    /// A kept call an earlier run left in the journal with `tracks` as its WAVs, brought back by a fresh store.
    private func recover(_ tracks: [CallJournal.Track: [Float]], mutes: [CallInterval] = []) async throws
        -> (CallStore, CallRecord) {
        let paths = AppPaths.temporary()
        let journal = CallJournal(directory: paths.callJournals)
        var info = CallJournal.Info(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                    appName: "Telegram", bundleID: "ru.keepcoder.Telegram", service: .telegram,
                                    consent: .kept)
        info.mutes = mutes
        info.muteKnown = true
        try FileManager.default.createDirectory(at: paths.callJournals, withIntermediateDirectories: true)
        for (track, samples) in tracks {
            var wav = RecordingJournal.openHeader()
            WAVEncoder.int16(samples).withUnsafeBytes { wav.append(contentsOf: $0) }
            try wav.write(to: journal.audioURL(for: info.id, track: track))
        }
        try JSONEncoder().encode(info).write(to: journal.infoURL(for: info.id))
        let store = CallStore(paths: paths, settings: .inMemory())
        store.load()
        await store.waitForRecovery()
        return (store, try #require(store.call(id: info.id)))
    }

    private func level(_ url: URL, _ from: Double, _ to: Double) throws -> Double {
        dB(try CallAudio.read(url, range: Int(from * rate)..<Int(to * rate))[...])
    }

    @Test func aKeptCallsMicIsCleanedAndTheRecordedOneKept() async throws {
        let call = EchoScene()
        let (store, record) = try await recover([.mic: call.mic, .remote: call.remote],
                                                mutes: [CallInterval(start: 6, end: 7)])
        #expect(record.echoCancelled)
        #expect((record.echoReductionDB ?? 0) >= 12, "\(String(describing: record.echoReductionDB))")
        let folder = store.folder(for: record.id)
        let mic = folder.appendingPathComponent("mic.m4a"), raw = folder.appendingPathComponent(CallStore.rawMicFile)
        #expect(FileManager.default.fileExists(atPath: raw.path))
        #expect(store.audioURL(of: record, track: .mic) == mic)
        // The other side is gone from the mic, kept in the one as recorded.
        let drop = try level(raw, 3, 6) - level(mic, 3, 6)
        #expect(drop >= 12, "\(drop) dB")
        // The person, the same in both.
        #expect(try abs(level(raw, 8.6, 12) - level(mic, 8.6, 12)) <= 3)
        // The mute, digital silence in both.
        #expect(try level(mic, 6.05, 6.95) < -60 && level(raw, 6.05, 6.95) < -60)
        // Saved, and gone with the call.
        await store.flush()
        let again = CallStore(paths: AppPaths(root: folder.deletingLastPathComponent().deletingLastPathComponent()),
                              settings: .inMemory())
        again.load()
        #expect(again.call(id: record.id)?.echoCancelled == true)
        store.delete(record.id)
        await store.flush()
        #expect(!FileManager.default.fileExists(atPath: raw.path))
    }

    @Test func aMicThatNeverHeardTheOtherSideIsCleanedOfNoiseOnly() async throws {
        let call = HeadphonesScene()
        let (store, record) = try await recover([.mic: call.mic, .remote: call.remote])
        #expect(!record.echoCancelled && record.echoReductionDB == nil)
        let folder = store.folder(for: record.id)
        let raw = folder.appendingPathComponent(CallStore.rawMicFile)
        #expect(FileManager.default.fileExists(atPath: raw.path))
        let mic = try #require(store.audioURL(of: record, track: .mic))
        #expect(try abs(level(raw, 1, 19) - level(mic, 1, 19)) <= 3)
    }

    @Test func withoutTheOtherSidesSoundTheMicStaysAsRecorded() async throws {
        let call = EchoScene()
        for tracks: [CallJournal.Track: [Float]] in [
            [.mic: call.mic],
            [.mic: call.mic, .remote: [Float](repeating: 0, count: call.remote.count)],
        ] {
            let (store, record) = try await recover(tracks)
            #expect(!record.echoCancelled && record.echoReductionDB == nil)
            let folder = store.folder(for: record.id)
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(CallStore.rawMicFile).path))
            let mic = try #require(store.audioURL(of: record, track: .mic))
            #expect(try abs(level(mic, 3, 6) - dB(slice(call.mic, 3, 6))) < 1)
        }
    }
}

@Suite struct CallsEchoCLITests {
    @Test func theMeasuringToolNeverWritesIntoTheAppsData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tt-\(UUID().uuidString)/transcribe-thing")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Calls"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        #expect(!CallsEchoCLI.isOutside(root, of: root))
        #expect(!CallsEchoCLI.isOutside(root.appendingPathComponent("Calls/out"), of: root))
        #expect(!CallsEchoCLI.isOutside(root.appendingPathComponent("../transcribe-thing/new"), of: root))
        #expect(!CallsEchoCLI.isOutside(URL(fileURLWithPath: root.path.uppercased()), of: root))
        // A link pointing inside is inside.
        let link = root.deletingLastPathComponent().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(!CallsEchoCLI.isOutside(link.appendingPathComponent("out"), of: root))
        #expect(CallsEchoCLI.isOutside(root.deletingLastPathComponent().appendingPathComponent("out"), of: root))
        #expect(CallsEchoCLI.isOutside(root.deletingLastPathComponent().appendingPathComponent("transcribe-thing-2"),
                                       of: root))
    }
}
