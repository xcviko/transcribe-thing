import Foundation

/// Microphone level for the pill waveform (wispr-ux §1.4).
///
/// The capture thread ingests one RMS value per 10 ms window with its capture timestamp. Readers get a
/// perceptual 0...1 level (adaptive noise floor, attack/release smoothing) as it was `readBehind` seconds
/// ago: taps deliver audio in ~100 ms chunks, so reading slightly in the past yields a smooth envelope
/// instead of a staircase. All state sits behind one lock; neither side is a realtime thread.
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

    /// `time` is the capture time of the window on the `AudioClock` timebase.
    func ingest(rmsDBFS: Float, at time: TimeInterval) {
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

    // MARK: Preview

    /// A meter that ignores input and reports a gently moving level around `level` (for snapshots and
    /// the Pill & Sounds preview stage).
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

    // MARK: Private

    private func resetLocked() {
        history.removeAll()
        recentDB.removeAll()
        smoothed = 0
        floorDB = -50
        ingestsSinceFloorUpdate = 4
        firstTime = nil
        lastTime = nil
        lastVoiceTime = nil
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
        storage[(head + index) % storage.count]!
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
