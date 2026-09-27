import Foundation

/// Microphone level for the pill waveform (wispr-ux §1.4) and the input meters.
///
/// The capture thread ingests one RMS value per 10 ms window with its capture timestamp. Readers get a
/// perceptual 0...1 level (adaptive noise floor, attack/release smoothing) as it was `readBehind` seconds
/// ago: taps deliver audio in ~100 ms chunks, so reading slightly in the past yields a smooth envelope
/// instead of a staircase. The pill's equalizer reads `voiceAmplitude(from:to:)` instead: the same windows
/// behind a voice gate, so room noise, fans and keyboard clicks draw nothing at all. All state sits behind
/// one lock; neither side is a realtime thread.
final class LevelMeter: @unchecked Sendable {
    struct Tuning: Sendable {
        var attack: TimeInterval = 0.040
        var release: TimeInterval = 0.140
        var readBehind: TimeInterval = 0.120
        var ceilingDBFS: Float = -12
        var floorRange: ClosedRange<Float> = -60 ... -40
        /// Added to the 10th-percentile level of the last `floorWindow` seconds.
        var floorOffset: Float = 6
        var floorWindow: TimeInterval = 1.5
        var exponent: Float = 0.7
        /// A window counts as voice when it is this far above the noise floor.
        var voiceMargin: Float = 8

        /// Equalizer amplitude: min(1, (rms · gain)^exponent) on linear RMS (the debilgpt composer's curve), with
        /// the gain raised from 9 so conversational speech on a Mac mic (-35 dBFS) lands near half height.
        var eqGain: Float = 12
        var eqExponent: Float = 0.55
        /// Voice gate: opens this far above the gate's own floor estimate (and above `gateMinimumDBFS`) ...
        var gateOpenMargin: Float = 9
        /// ... for this many consecutive windows (60 ms, half a short syllable), so a key click, even one that
        /// rings, or a desk tap never opens it ...
        var gateSustain = 6
        /// ... and closes after `gateHangover` with the mean of the last `gateCloseWindows` windows below this
        /// margin, so gaps between syllables don't flicker and a rumbling noise can't hold it open window by window.
        var gateCloseMargin: Float = 6
        var gateCloseWindows = 5
        var gateHangover: TimeInterval = 0.2
        var gateMinimumDBFS: Float = -55
        /// A breath of 0.25 s or more still closes the gate, and the syllables right after it are often only
        /// 40-50 ms loud: within `gateReopenWindow` of closing after at least `gateReopenMinOpen` of voice (speech,
        /// not a click) the same margin reopens it after `gateReopenSustain` windows instead.
        var gateReopenSustain = 4
        var gateReopenWindow: TimeInterval = 0.5
        var gateReopenMinOpen: TimeInterval = 0.3
        /// The gate's floor is a minimum tracker: it falls quickly into every pause but rises only
        /// `gateFloorRise` dB/s, so continuous speech can't drag it up. The first `gateWarmup` seconds rise
        /// faster, in case the stream opened on a transient.
        var gateFloorFall: TimeInterval = 0.12
        var gateFloorRise: Float = 2.5
        var gateWarmup: TimeInterval = 0.5
        var gateWarmupRise: Float = 30
        /// Speech always dips within a second, a fan that just switched on never does: the floor is kept at most
        /// `gateSteadyOffset` under the quietest window of the last `gateSteadyWindow` seconds.
        var gateSteadyWindow: TimeInterval = 1.0
        var gateSteadyOffset: Float = 1.5
    }

    let tuning: Tuning
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()

    private var history = AudioRing<(time: TimeInterval, level: Float)>(capacity: 192)
    private var recentDB = AudioRing<(time: TimeInterval, db: Float)>(capacity: 200)
    private var smoothed: Float = 0
    private var floorDB: Float = -50
    private var ingestsSinceFloorUpdate = 4
    private var firstTime: TimeInterval?
    private var lastTime: TimeInterval?
    private var lastVoiceTime: TimeInterval?
    private var preview: Preview?

    /// 2.56 s of windows for the equalizer: its visible history plus the read-behind.
    private var windows = AudioRing<Window>(capacity: 256)
    private var gate = VoiceGate()

    private struct Window {
        var time: TimeInterval
        /// Linear mean square (rms²).
        var power: Float
        var voiced: Bool
    }

    private struct VoiceGate {
        var floorDB: Float?
        var floorSince: TimeInterval = 0
        var isOpen = false
        var run = 0
        var lastAbove: TimeInterval = 0
        var openedAt: TimeInterval = 0
        var closedAt: TimeInterval = 0
        /// The last close ended a stretch of voice, so a quick reopen is allowed.
        var reopenArmed = false
    }

    private struct Preview {
        var level: Float
        var animated: Bool
        var hasReceivedAudio: Bool
        var secondsSinceVoice: Double
    }

    init(tuning: Tuning = Tuning(), clock: @escaping @Sendable () -> TimeInterval = { AudioClock.now() }) {
        self.tuning = tuning
        self.clock = clock
    }

    // MARK: Writing (capture thread)

    /// `time` is the capture time of the window on the `AudioClock` timebase. `ducked`: the capture path
    /// attenuated the window to keep a UI sound out of the recording, so it says nothing about the voice.
    func ingest(rmsDBFS: Float, at time: TimeInterval, ducked: Bool = false) {
        let db = rmsDBFS.isFinite ? max(rmsDBFS, -160) : -160
        lock.withLock {
            guard preview == nil else { return }
            if let lastTime, time < lastTime - 0.5 {
                // Timestamps jumped backwards (a new session reusing the meter without reset).
                resetLocked()
            }
            recentDB.append((time, db))
            ingestsSinceFloorUpdate += 1
            if ingestsSinceFloorUpdate >= 5 {
                ingestsSinceFloorUpdate = 0
                floorDB = adaptiveFloorLocked(now: time)
            }

            let target = Self.perceptual(db: db, floor: floorDB, ceiling: tuning.ceilingDBFS, exponent: tuning.exponent)
            let dt = lastTime.map { max(0, min(time - $0, 0.25)) } ?? 0.010
            let tau = target > smoothed ? tuning.attack : tuning.release
            smoothed += (target - smoothed) * Float(1 - exp(-dt / tau))

            history.append((time, smoothed))
            if firstTime == nil { firstTime = time }
            lastTime = max(lastTime ?? time, time)
            if db >= floorDB + tuning.voiceMargin { lastVoiceTime = time }
            if ducked, gate.isOpen, let last = windows.last {
                // A cue played over speech (the hands-free lock ping): hold the gate and the voice's last level
                // instead of dropping the bars for the length of the ping.
                windows.append(Window(time: time, power: last.power, voiced: true))
            } else {
                gateLocked(db: db, at: time, dt: dt)
            }
        }
    }

    // MARK: Reading (UI, 60-120 Hz)

    /// 0...1 perceptual level, `readBehind` seconds in the past.
    var level: Float { level(at: clock() - tuning.readBehind) }

    var hasReceivedAudio: Bool {
        lock.withLock { preview?.hasReceivedAudio ?? (firstTime != nil) }
    }

    /// Seconds since the last voiced window (or since audio started when nobody spoke yet); 0 before audio.
    var secondsSinceVoice: Double {
        let now = clock() - tuning.readBehind
        return lock.withLock {
            if let preview { return preview.secondsSinceVoice }
            guard let reference = lastVoiceTime ?? firstTime else { return 0 }
            return max(0, now - reference)
        }
    }

    /// Current adaptive noise floor in dBFS (diagnostics and tests).
    var noiseFloorDBFS: Float { lock.withLock { floorDB } }

    /// The moment readers look at: now minus `readBehind`, on the meter's clock.
    var readTime: TimeInterval { clock() - tuning.readBehind }

    /// `voiceAmplitude(from:to:)` of a range ending at or before this time is final: its audio has arrived and
    /// the gate can no longer mark its windows as an onset. Later ranges may still grow. Nil before audio.
    var settledTime: TimeInterval? {
        lock.withLock {
            if preview != nil { return .infinity }
            guard windows.count > 0 else { return nil }
            // Opening on the next window marks the `gateSustain - 1` windows before it.
            return windows[max(0, windows.count - (tuning.gateSustain - 1))].time
        }
    }

    /// Equalizer amplitude 0...1 of the audio captured in `start..<end`: the RMS of its windows with every
    /// window outside the voice gate counted as silence. Exactly 0 unless someone spoke.
    func voiceAmplitude(from start: TimeInterval, to end: TimeInterval) -> Float {
        lock.withLock {
            if let preview { return Self.previewAmplitude(preview, from: start, to: end) }
            var voiced: Float = 0
            var count = 0
            for index in stride(from: windows.count - 1, through: 0, by: -1) {
                let window = windows[index]
                if window.time >= end { continue }
                if window.time < start { break }
                count += 1
                if window.voiced { voiced += window.power }
            }
            guard count > 0, voiced > 0 else { return 0 }
            return Self.eqAmplitude(rms: (voiced / Float(count)).squareRoot(), gain: tuning.eqGain,
                                    exponent: tuning.eqExponent)
        }
    }

    func level(at time: TimeInterval) -> Float {
        lock.withLock {
            if let preview { return Self.previewLevel(preview, at: time) }
            guard let newest = history.last else { return 0 }
            if time >= newest.time {
                // Audio stopped arriving (stall, or the read-behind is shorter than the chunk size):
                // hold briefly, then fall with the release curve instead of freezing.
                let late = time - newest.time - 0.10
                guard late > 0 else { return newest.level }
                return newest.level * Float(exp(-late / tuning.release))
            }
            var newer = newest
            for index in stride(from: history.count - 2, through: 0, by: -1) {
                let sample = history[index]
                if sample.time <= time {
                    let span = newer.time - sample.time
                    guard span > 0 else { return sample.level }
                    let f = Float((time - sample.time) / span)
                    return sample.level + (newer.level - sample.level) * f
                }
                newer = sample
            }
            return newer.level
        }
    }

    func reset() {
        lock.withLock { resetLocked() }
    }

    // MARK: Mapping

    /// dBFS → 0...1: linear between the noise floor and the ceiling, then a perceptual curve.
    static func perceptual(db: Float, floor: Float, ceiling: Float = -12, exponent: Float = 0.7) -> Float {
        guard ceiling > floor else { return 0 }
        let x = min(max((db - floor) / (ceiling - floor), 0), 1)
        return pow(x, exponent)
    }

    /// Linear RMS → 0...1 bar height.
    static func eqAmplitude(rms: Float, gain: Float = 12, exponent: Float = 0.55) -> Float {
        guard rms > 0 else { return 0 }
        return min(1, pow(rms * gain, exponent))
    }

    // MARK: Preview

    /// A meter that ignores input and reports a gently moving level around `level`, plus speech-like bursts
    /// and pauses for the equalizer, louder as `level` rises (for snapshots and illustrations).
    static func preview(level: Float) -> LevelMeter {
        preview(level: level, animated: true)
    }

    static func preview(level: Float, animated: Bool, hasReceivedAudio: Bool = true,
                        secondsSinceVoice: Double = 0) -> LevelMeter {
        let meter = LevelMeter()
        meter.preview = Preview(level: min(max(level, 0), 1), animated: animated,
                                hasReceivedAudio: hasReceivedAudio, secondsSinceVoice: secondsSinceVoice)
        return meter
    }

    /// Speech-like motion: syllables at ~4-5 Hz inside slower phrase swells, never fully dropping out.
    private static func previewLevel(_ preview: Preview, at time: TimeInterval) -> Float {
        guard preview.animated, preview.level > 0 else { return preview.level }
        let syllable = 0.5 + 0.5 * sin(2 * .pi * 4.3 * time) * sin(2 * .pi * 1.7 * time + 0.8)
        let phrase = 0.5 + 0.5 * sin(2 * .pi * 0.37 * time + 1.3)
        let motion = 0.80 + 0.14 * syllable + 0.06 * phrase
        return min(1, preview.level * Float(motion))
    }

    /// Equalizer preview: `previewVoice` through the same RMS-and-curve path as live audio, scaled so a
    /// `level` of 0.6 is an ordinary speaking voice.
    private static func previewAmplitude(_ preview: Preview, from start: TimeInterval, to end: TimeInterval) -> Float {
        guard preview.level > 0 else { return 0 }
        guard preview.animated else { return preview.level }
        let samples = 4
        var power: Float = 0
        for index in 0..<samples {
            let voice = previewVoice(at: start + (end - start) * (Double(index) + 0.5) / Double(samples))
            power += voice * voice
        }
        guard power > 0 else { return 0 }
        return min(1, preview.level / 0.6 * pow(power / Float(samples), 0.275))
    }

    /// Deterministic speech, 0...1: phrases of ~2.4 s every 3.4 s; inside a phrase, syllables of 120-250 ms
    /// with 60-120 ms gaps and varied stress, each rising quickly and trailing off.
    private static func previewVoice(at time: TimeInterval) -> Float {
        let period = 3.4
        let phrase = (time / period).rounded(.down)
        let local = time - phrase * period
        // Stable pseudo-random 0...1 per (phrase, syllable, property).
        func hash(_ syllable: Int, _ property: Int) -> Double {
            let x = sin(phrase * 12.9898 + Double(syllable) * 78.233 + Double(property) * 37.719) * 43_758.5453
            return x - x.rounded(.down)
        }
        var cursor = 0.0
        for syllable in 0..<16 {
            let length = 0.12 + 0.13 * hash(syllable, 0)
            if cursor + length > 2.4 { return 0 }
            if local < cursor + length {
                guard local >= cursor else { return 0.02 }   // breath between syllables: the gate holds
                let x = (local - cursor) / length
                let peak = 0.2 + 0.8 * hash(syllable, 1)
                return Float(peak * pow(sin(.pi * pow(x, 0.7)), 0.6))
            }
            cursor += length + 0.06 + 0.06 * hash(syllable, 2)
        }
        return 0
    }

    // MARK: Private

    /// One window through the voice gate; `dt` is the time since the previous window.
    private func gateLocked(db: Float, at time: TimeInterval, dt: TimeInterval) {
        // Digital silence (a device still warming up) says nothing about the room.
        if db > -100 {
            if let floor = gate.floorDB {
                if db < floor {
                    gate.floorDB = floor + (db - floor) * Float(1 - exp(-dt / tuning.gateFloorFall))
                } else {
                    let rise = time - gate.floorSince < tuning.gateWarmup ? tuning.gateWarmupRise : tuning.gateFloorRise
                    gate.floorDB = min(db, floor + rise * Float(dt))
                }
                if let quietest = steadyMinimumLocked(at: time) {
                    gate.floorDB = max(gate.floorDB ?? quietest, quietest - tuning.gateSteadyOffset)
                }
            } else {
                gate.floorDB = db
                gate.floorSince = time
            }
        }
        let floor = gate.floorDB ?? -160
        if gate.isOpen {
            // This window and the ones before it, as one level.
            var power = pow(10, db / 10)
            let previous = min(tuning.gateCloseWindows - 1, windows.count)
            for back in stride(from: 1, through: previous, by: 1) {
                power += windows[windows.count - back].power
            }
            let recentLevel = 10 * log10(max(power / Float(previous + 1), 1e-16))
            if recentLevel >= max(floor + tuning.gateCloseMargin, tuning.gateMinimumDBFS - 3) {
                gate.lastAbove = time
            } else if time - gate.lastAbove > tuning.gateHangover {
                gate.isOpen = false
                gate.closedAt = time
                // A key click that slipped through never arms it, so typing can't chain reopens.
                gate.reopenArmed = time - gate.openedAt >= tuning.gateReopenMinOpen
            }
        }
        if !gate.isOpen {
            let reopening = gate.reopenArmed && time - gate.closedAt <= tuning.gateReopenWindow
            let sustain = reopening ? tuning.gateReopenSustain : tuning.gateSustain
            gate.run = db >= max(floor + tuning.gateOpenMargin, tuning.gateMinimumDBFS) ? gate.run + 1 : 0
            if gate.run >= sustain {
                gate.isOpen = true
                gate.run = 0
                gate.lastAbove = time
                gate.openedAt = time
                // The windows that proved the onset are voice too.
                for back in stride(from: 1, to: min(sustain, windows.count + 1), by: 1) {
                    windows[windows.count - back].voiced = true
                }
            }
        }
        windows.append(Window(time: time, power: pow(10, db / 10), voiced: gate.isOpen))
    }

    /// The quietest non-silent window of the last `gateSteadyWindow` seconds; nil until that much audio arrived.
    private func steadyMinimumLocked(at time: TimeInterval) -> Float? {
        guard recentDB.count > 0, recentDB[0].time <= time - tuning.gateSteadyWindow else { return nil }
        var quietest: Float?
        for index in stride(from: recentDB.count - 1, through: 0, by: -1) {
            let entry = recentDB[index]
            if time - entry.time > tuning.gateSteadyWindow { break }
            if entry.db > -100 { quietest = min(quietest ?? entry.db, entry.db) }
        }
        return quietest
    }

    private func resetLocked() {
        history.removeAll()
        recentDB.removeAll()
        smoothed = 0
        floorDB = -50
        ingestsSinceFloorUpdate = 4
        firstTime = nil
        lastTime = nil
        lastVoiceTime = nil
        windows.removeAll()
        gate = VoiceGate()
    }

    private func adaptiveFloorLocked(now: TimeInterval) -> Float {
        var values: [Float] = []
        values.reserveCapacity(recentDB.count)
        for index in 0..<recentDB.count {
            let entry = recentDB[index]
            if now - entry.time <= tuning.floorWindow { values.append(entry.db) }
        }
        guard !values.isEmpty else { return floorDB }
        values.sort()
        let p10 = values[min(values.count - 1, values.count / 10)]
        return min(max(p10 + tuning.floorOffset, tuning.floorRange.lowerBound), tuning.floorRange.upperBound)
    }
}

/// Fixed-capacity ring buffer; index 0 is the oldest element.
struct AudioRing<Element> {
    private var storage: [Element?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        storage = Array(repeating: nil, count: max(1, capacity))
    }

    var capacity: Int { storage.count }
    var last: Element? { count == 0 ? nil : self[count - 1] }

    subscript(index: Int) -> Element {
        get { storage[(head + index) % storage.count]! }
        set { storage[(head + index) % storage.count] = newValue }
    }

    mutating func append(_ element: Element) {
        let slot = (head + count) % storage.count
        storage[slot] = element
        if count < storage.count {
            count += 1
        } else {
            head = (head + 1) % storage.count
        }
    }

    mutating func removeAll() {
        for index in storage.indices { storage[index] = nil }
        head = 0
        count = 0
    }
}
