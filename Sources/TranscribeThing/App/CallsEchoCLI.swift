import Foundation

/// Headless measurement of the echo canceller on a recorded call, dispatched by TranscribeThingMain before the app
/// starts:
///
///     transcribe-thing --calls-aec <call-id> --out <dir> [--seconds N] [--frame N] [--filter N]
///                      [--echo-suppress dB] [--echo-suppress-active dB] [--noise-suppress dB|off] [--no-preprocess]
///                      [--no-gate] [--min-erle dB] [--reach N] [--plain-noise-only]
///
/// Reads the call's mic (`mic-raw.m4a` when the app already cleaned it, else `mic.m4a`) and `remote.m4a` from the
/// Calls folder, cleans the mic against the remote as the app does (`EchoCanceller`, the app's settings unless the
/// flags change them), and writes `mic-raw.wav`, `mic-aec.wav` and `remote.wav` into `<dir>`, which must not be inside
/// the app's data folder. Then prints what `EchoMeter` measured before and after. Only reads the app's data: nothing
/// there is written, moved or deleted, and nothing goes over the network.
enum CallsEchoCLI {
    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains("--calls-aec")
    }

    static func run(_ arguments: [String]) -> Never {
        let paths = AppPaths.live()
        guard let id = value(after: "--calls-aec", in: arguments).flatMap(UUID.init(uuidString:)) else {
            fail("Usage: --calls-aec <call-id> --out <dir>")
        }
        guard let outPath = value(after: "--out", in: arguments) else { fail("--out <dir> is needed") }
        let out = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath, isDirectory: true)
        guard isOutside(out, of: paths.root) else {
            fail("Won't write into the app's data (\(paths.root.path)): pick another --out folder")
        }
        var settings = EchoCanceller.Settings.standard
        do {
            if let frame = try number("--frame", in: arguments) { settings.frame = frame }
            if let filter = try number("--filter", in: arguments) { settings.filterLength = filter }
            if let reach = try number("--reach", in: arguments) { settings.reach = max(0, reach) }
            if let level = try number("--echo-suppress", in: arguments) { settings.echoSuppress = Int32(level) }
            if let level = try number("--echo-suppress-active", in: arguments) {
                settings.echoSuppressActive = Int32(level)
            }
            if value(after: "--noise-suppress", in: arguments) == "off" {
                settings.noiseSuppress = nil
            } else if let level = try number("--noise-suppress", in: arguments) {
                settings.noiseSuppress = Int32(level)
            }
        } catch {
            fail("\(error)")
        }
        if arguments.contains("--no-preprocess") { settings.preprocess = false }
        if arguments.contains("--no-gate") { settings.gate = false }
        if arguments.contains("--plain-noise-only") { settings.plainSuppressesEcho = false }
        if let erle = value(after: "--min-erle", in: arguments).flatMap(Double.init) { settings.minimumERLE = erle }
        let seconds = (try? number("--seconds", in: arguments)) ?? nil

        let folder = paths.calls.appendingPathComponent(id.uuidString, isDirectory: true)
        let fm = FileManager.default
        let rawMic = folder.appendingPathComponent(CallStore.rawMicFile)
        let mic = fm.fileExists(atPath: rawMic.path) ? rawMic : folder.appendingPathComponent("mic.m4a")
        let remote = folder.appendingPathComponent("remote.m4a")
        for url in [mic, remote] where !fm.fileExists(atPath: url.path) {
            fail("No \(url.lastPathComponent) in \(folder.path)")
        }
        do {
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            let report = try measure(mic: mic, remote: remote, out: out, settings: settings,
                                     limit: seconds.map { Int(Double($0) * Recording.sampleRate) })
            print("Call \(id.uuidString) · mic from \(mic.lastPathComponent)")
            for line in report { print(line) }
        } catch {
            fail("Failed: \(error.localizedDescription)")
        }
        exit(0)
    }

    /// Cleans `mic` against `remote` with `settings`, writes the three WAVs into `out` and returns what to print.
    static func measure(mic: URL, remote: URL, out: URL, settings: EchoCanceller.Settings,
                        limit: Int? = nil) throws -> [String] {
        let count = try CallAudio.sampleCount(of: mic)
        let micStream = try TrackStream(earlier: mic, then: nil, at: limit.map { min($0, count) } ?? count)
        let remoteStream = try TrackStream(m4a: remote)
        let rawWAV = try WAVWriter(out.appendingPathComponent("mic-raw.wav"))
        let cleanWAV = try WAVWriter(out.appendingPathComponent("mic-aec.wav"))
        let remoteWAV = try WAVWriter(out.appendingPathComponent("remote.wav"))
        let canceller = EchoCanceller(settings: settings)
        var meter = EchoMeter()
        var rawJumps = FrameEdgeJumps(frame: settings.frame), cleanJumps = FrameEdgeJumps(frame: settings.frame)
        var processing: TimeInterval = 0
        var taken = 0
        while true {
            let samples = try micStream.next(CallAudio.block)
            if samples.isEmpty { break }
            let far = try remoteStream.next(samples.count)
            let padded = far + [Float](repeating: 0, count: samples.count - far.count)
            meter.add(raw: samples, remote: padded)
            rawJumps.add(samples)
            try rawWAV.append(samples)
            try remoteWAV.append(padded)
            let began = Date()
            let cleaned = canceller.process(mic: samples, reference: padded)
            processing += Date().timeIntervalSince(began)
            meter.add(cleaned: cleaned)
            cleanJumps.add(cleaned)
            try cleanWAV.append(cleaned)
            taken += samples.count
        }
        let rest = canceller.finish()
        meter.add(cleaned: rest)
        cleanJumps.add(rest)
        try cleanWAV.append(rest)
        for writer in [rawWAV, cleanWAV, remoteWAV] { try writer.close() }

        let stats = meter.result()
        let summary = canceller.summary
        let audio = Double(taken) / Recording.sampleRate
        var lines: [String] = []
        let noise = settings.noiseSuppress.map { "\($0) dB" } ?? "off"
        lines.append("Settings: frame \(settings.frame), filter \(settings.filterLength) "
                     + "(\(settings.filterLength * 1000 / Int(Recording.sampleRate)) ms), "
                     + (settings.preprocess
                        ? "echo suppress \(settings.echoSuppress)/\(settings.echoSuppressActive) dB, noise \(noise)"
                        : "no preprocessor"))
        lines.append(String(format: "Cleaned %@ of audio in %.1f s (%.0fx real time)", CallPrompts.clock(audio),
                            processing, processing > 0 ? audio / processing : 0))
        let erle = summary.erle.compactMap { $0 }.sorted()
        lines.append(String(format: "Echo canceller used in %d of %d %.0f s stretches (%.0f%%)", summary.echoHops,
                            summary.hops, settings.hop, summary.echoShare * 100))
        if !erle.isEmpty {
            lines.append(String(format: "  what it took away where the other side talked, per stretch: "
                                + "min %.1f, median %.1f, max %.1f dB (echo from %.0f dB)",
                                erle[0], erle[erle.count / 2], erle[erle.count - 1], settings.minimumERLE))
        }
        lines.append("Jumps over \(FrameEdgeJumps.threshold) at frame edges (clicks): \(rawJumps.count) as recorded, "
                     + "\(cleanJumps.count) after")
        lines.append(row("", "before", "after"))
        lines.append(row("mic voiced (>= -45 dBFS, 50 ms frames)", percent(stats.before.voicedFraction),
                         percent(stats.after.voicedFraction)))
        lines.append(row("of those, the other side voiced too", percent(stats.before.overlapFraction),
                         percent(stats.after.overlapFraction)))
        func best(_ side: EchoStats.Side) -> String {
            let strongest = side.strongestCorrelation
            return String(format: "%.2f @ %d ms", strongest.value, strongest.lagMS)
        }
        lines.append(row("envelope correlation, best of 0-400 ms", best(stats.before), best(stats.after)))
        for lag in [0, 5, 10, 20, 40] {
            lines.append(row("  at \(lag * 10) ms", String(format: "%.2f", stats.before.correlation[lag]),
                             String(format: "%.2f", stats.after.correlation[lag])))
        }
        lines.append(row("echo: mic where the other side talks alone (\(stats.remoteOnlyFrames) frames)",
                         level(stats.before.echoDBFS), level(stats.after.echoDBFS)))
        lines.append(row("near end: mic where only you talk (\(stats.nearOnlyFrames) frames)",
                         level(stats.before.nearDBFS), level(stats.after.nearDBFS)))
        if let reduction = stats.echoReductionDB {
            lines.append(String(format: "Echo %.1f dB quieter in all, the typical frame %.1f dB", reduction,
                                stats.typicalEchoReductionDB ?? 0))
        }
        if let before = stats.before.nearDBFS, let after = stats.after.nearDBFS {
            lines.append(String(format: "Near end %+.1f dB", after - before))
        }
        lines.append("Wrote mic-raw.wav, mic-aec.wav, remote.wav to \(out.path)")
        return lines
    }

    /// Clicks a frame-by-frame process can leave: sample-to-sample jumps of more than `threshold` (16-bit) right at a
    /// frame's edge, counted a block at a time. Speech has some anyway, about 1 in `frame` of all its big jumps.
    struct FrameEdgeJumps {
        static let threshold = 3_000
        let frame: Int
        private(set) var count = 0
        private var position = 0
        private var last: Int?

        init(frame: Int) { self.frame = frame }

        mutating func add(_ samples: [Float]) {
            for sample in samples {
                let value = Int((sample * 32_768).rounded())
                if position % frame == 0, let last, abs(value - last) > Self.threshold { count += 1 }
                last = value
                position += 1
            }
        }
    }

    /// Whether `out` is somewhere other than `root` and the folders in it, with links and "..", followed.
    static func isOutside(_ out: URL, of root: URL) -> Bool {
        let out = resolved(out).pathComponents.map { $0.lowercased() }
        let root = resolved(root).pathComponents.map { $0.lowercased() }
        return !(out.count >= root.count && Array(out.prefix(root.count)) == root)
    }

    /// `url` standardized with its links followed, as far as it exists: a folder still to be made counts as where its
    /// existing parent really is.
    private static func resolved(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var result = existing.resolvingSymlinksInPath()
        for component in rest { result.appendPathComponent(component) }
        return result
    }

    private static func row(_ label: String, _ before: String, _ after: String) -> String {
        label.padding(toLength: 62, withPad: " ", startingAt: 0)
            + before.padding(toLength: 16, withPad: " ", startingAt: 0) + after
    }

    private static func percent(_ fraction: Double) -> String { String(format: "%.1f%%", fraction * 100) }

    private static func level(_ dBFS: Double?) -> String { dBFS.map { String(format: "%.1f dBFS", $0) } ?? "-" }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private struct BadNumber: Error, CustomStringConvertible {
        var flag: String
        var description: String { "\(flag) takes a whole number" }
    }

    private static func number(_ flag: String, in arguments: [String]) throws -> Int? {
        guard let text = value(after: flag, in: arguments) else { return nil }
        guard let number = Int(text) else { throw BadNumber(flag: flag) }
        return number
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    /// A 16-bit mono WAV at 16 kHz written a block at a time; its sizes are filled in on `close`.
    private final class WAVWriter {
        private let handle: FileHandle
        private var samples = 0

        init(_ url: URL) throws {
            try RecordingJournal.openHeader().write(to: url)
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        }

        func append(_ block: [Float]) throws {
            guard !block.isEmpty else { return }
            try WAVEncoder.int16(block).withUnsafeBytes { try handle.write(contentsOf: $0) }
            samples += block.count
        }

        func close() throws {
            let bytes = samples * 2
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: withUnsafeBytes(of: UInt32(clamping: 36 + bytes).littleEndian) { Data($0) })
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: withUnsafeBytes(of: UInt32(clamping: bytes).littleEndian) { Data($0) })
            try handle.close()
        }
    }
}
