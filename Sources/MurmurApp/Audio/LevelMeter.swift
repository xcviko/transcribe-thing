import Foundation

// STUB (FOUNDATION): AUDIO replaces this with the real attack/release meter.
/// Lock-protected level store: written from the audio thread, read by the UI at 60-120 Hz.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var _level: Float = 0
    private var _hasReceivedAudio = false
    private var lastVoiceTime: TimeInterval?
    private var lastTime: TimeInterval = 0
    private var fixedLevel: Float?

    init() {}

    func ingest(rmsDBFS: Float, at time: TimeInterval) {
        lock.withLock {
            let mapped = min(max((rmsDBFS + 60) / 60, 0), 1)
            _level = mapped
            _hasReceivedAudio = true
            lastTime = time
            if rmsDBFS > -40 { lastVoiceTime = time }
        }
    }

    /// 0...1 perceptual.
    var level: Float { lock.withLock { fixedLevel ?? _level } }
    var hasReceivedAudio: Bool { lock.withLock { fixedLevel != nil || _hasReceivedAudio } }
    var secondsSinceVoice: Double {
        lock.withLock { lastVoiceTime.map { max(0, lastTime - $0) } ?? .infinity }
    }

    func reset() {
        lock.withLock {
            _level = 0
            _hasReceivedAudio = false
            lastVoiceTime = nil
            lastTime = 0
        }
    }

    /// Fixed level for snapshots.
    static func preview(level: Float) -> LevelMeter {
        let meter = LevelMeter()
        meter.fixedLevel = min(max(level, 0), 1)
        return meter
    }
}
