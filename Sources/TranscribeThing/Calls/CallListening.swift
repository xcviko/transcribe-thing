import Foundation

/// A call's tracks for listening, what the player plays (`CallPlayer`): each as the Mac played and heard it, at 48 kHz
/// (the journal's listening tracks, `CallJournal.listeningURL`), not the 16 kHz everything else works on, which cuts off
/// what makes a voice sound like itself. Both sides are brought to one loudness, `targetLUFS`, with a limiter that
/// keeps the peaks under `ceiling`, so neither is quieter than the other and both are as loud as a podcast. The mic is
/// cleaned of the other side's voices only where it heard them (on speakers, `EchoCanceller.Settings.listening`);
/// elsewhere it's exactly as recorded: no noise suppression. AAC at `bitRate` in `micFile` and `remoteFile`. Blocking
/// file work: off the main thread.
enum CallListening {
    static let micFile = "mic-48k.m4a"
    static let remoteFile = "remote-48k.m4a"
    /// Where both tracks are brought: speech as loud as podcasts and streaming services put it.
    static let targetLUFS: Double = -16
    /// The most a track is turned up or down, in dB: a mic that heard next to nothing isn't turned into hiss.
    static let gainRange: ClosedRange<Double> = -12...24
    /// -1 dBFS: room for AAC's own overshoot.
    static let ceiling: Float = 0.891
    static let bitRate = 96_000
    static var rate: Double { Recording.listeningRate }

    /// One track made.
    struct Track: Equatable, Sendable {
        var file: String
        var seconds: TimeInterval
        /// What it measured before, in LUFS; nil for silence.
        var loudness: Double?
        /// What it was turned up (or down) by, in dB.
        var gainDB: Double
    }

    /// What `make` made: both tracks, or neither.
    struct Made: Equatable, Sendable {
        var mic: Track?
        var remote: Track?
        /// The mic was cleaned of the other side's voices somewhere.
        var cleanedEcho = false
        /// How long it took, in seconds.
        var seconds: TimeInterval = 0
        /// Why it made nothing for a track that had audio, for the log.
        var failure: String?
    }

    /// The listening tracks of a call from its journal's (`mic`, `remote`: nil or empty for a track it doesn't
    /// have), nothing past `limit` seconds, the mic silent in `silencing`, into `folder`. `cancelEcho`: the 16 kHz
    /// mic's cleaning found echo (`CallAudio.EchoCancelled.tookEchoOut`), so the mic was on speakers somewhere: it's
    /// cleaned again here, at 48 kHz, against the other side's track. A track that fails takes the other with it: a
    /// pair with one side levelled and the other not would play unevenly, so the player keeps to the 16 kHz pair.
    static func make(mic: URL?, remote: URL?, limit: TimeInterval?, silencing: [CallInterval], cancelEcho: Bool,
                     in folder: URL) -> Made {
        let began = Date()
        var made = Made()
        let limit = limit.map { Int(($0 * rate).rounded(.up)) }
        func audio(_ url: URL?) -> URL? { url.flatMap { (RecordingJournal.sampleCount(of: $0) ?? 0) > 0 ? $0 : nil } }
        let micWAV = audio(mic), remoteWAV = audio(remote)
        let micURL = folder.appendingPathComponent(micFile, isDirectory: false)
        let remoteURL = folder.appendingPathComponent(remoteFile, isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let remoteWAV {
                made.remote = try level({ try TrackStream(earlier: nil, then: remoteWAV, at: 0, limit: limit) },
                                        to: remoteURL)
            }
            if let micWAV {
                if cancelEcho, let remoteWAV {
                    let cleaned = folder.appendingPathComponent(".mic-48k-cleaned.wav", isDirectory: false)
                    defer { try? FileManager.default.removeItem(at: cleaned) }
                    made.cleanedEcho = try cleanEcho(
                        mic: TrackStream(earlier: nil, then: micWAV, at: 0, limit: limit),
                        reference: TrackStream(earlier: nil, then: remoteWAV, at: 0, limit: limit),
                        silencing: silencing, to: cleaned)
                    made.mic = try level({ try TrackStream(earlier: nil, then: cleaned, at: 0) }, to: micURL)
                } else {
                    made.mic = try level({ try TrackStream(earlier: nil, then: micWAV, at: 0, limit: limit) },
                                         silencing: silencing, to: micURL)
                }
            }
        } catch {
            for url in [micURL, remoteURL] { try? FileManager.default.removeItem(at: url) }
            made = Made(failure: "failed")
            Log.audio.error("Couldn't keep the call for listening: \(error.localizedDescription, privacy: .public)")
        }
        made.seconds = Date().timeIntervalSince(began)
        return made
    }

    /// The track `stream` makes, silent in `silencing`, brought to `targetLUFS`: read through once to measure it, then
    /// again turned up and limited, as AAC in `url` (written beside it first, so `url` never holds half a file).
    static func level(_ stream: () throws -> TrackStream, silencing: [CallInterval] = [], to url: URL) throws -> Track {
        var meter = LoudnessMeter(rate: rate)
        try read(stream(), silencing: silencing) { meter.add($0) }
        let loudness = meter.integrated
        let gainDB = loudness.map { min(max(targetLUFS - $0, gainRange.lowerBound), gainRange.upperBound) } ?? 0
        let gain = Float(pow(10, gainDB / 20))
        let source = try stream()
        let partial = RecordingFile.partialURL(beside: url)
        defer { try? FileManager.default.removeItem(at: partial) }
        var limiter = PeakLimiter(ceiling: ceiling, rate: rate)
        // The limiter's output is behind its input: its first samples are from before the track.
        var early = limiter.lookahead - 1
        var written = 0
        try CloudAudio.writeM4A(bitRate: bitRate, reservingSeconds: Double(source.length) / rate, sampleRate: rate,
                                to: partial) { append in
            func give(_ samples: [Float]) throws {
                let dropped = min(early, samples.count)
                early -= dropped
                guard dropped < samples.count else { return }
                let out = dropped == 0 ? samples : Array(samples[dropped...])
                try append(out)
                written += out.count
            }
            try read(source, silencing: silencing) { samples in
                try give(limiter.process(gain == 1 ? samples : samples.map { $0 * gain }))
            }
            try give(limiter.finish())
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
        return Track(file: url.lastPathComponent, seconds: Double(written) / rate, loudness: loudness, gainDB: gainDB)
    }

    /// The mic cleaned against `reference` at the listening rate, silent in `silencing`, into `url` as a journal's
    /// 16-bit WAV. Whether the canceller's version is in it anywhere.
    static func cleanEcho(mic: TrackStream, reference: TrackStream, silencing: [CallInterval], to url: URL) throws
        -> Bool {
        try RecordingJournal.openHeader(rate: rate).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let canceller = EchoCanceller(settings: .listening)
        var given = 0
        func give(_ cleaned: [Float]) throws {
            guard !cleaned.isEmpty else { return }
            var cleaned = cleaned
            CallMix.silence(&cleaned, first: given, mutes: silencing, rate: rate)
            given += cleaned.count
            try WAVEncoder.int16(cleaned).withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
        }
        var taken = 0
        while true {
            var samples = try mic.next(CallAudio.block)
            if samples.isEmpty { break }
            CallMix.silence(&samples, first: taken, mutes: silencing, rate: rate)
            taken += samples.count
            try give(canceller.process(mic: samples, reference: reference.next(samples.count)))
        }
        try give(canceller.finish())
        return canceller.summary.echoHops > 0
    }

    /// Hands `body` each block of `stream`, silent in `silencing`.
    private static func read(_ stream: TrackStream, silencing: [CallInterval], _ body: ([Float]) throws -> Void)
        throws {
        var position = 0
        while true {
            var samples = try stream.next(CallAudio.block)
            if samples.isEmpty { return }
            CallMix.silence(&samples, first: position, mutes: silencing, rate: rate)
            position += samples.count
            try body(samples)
        }
    }
}
