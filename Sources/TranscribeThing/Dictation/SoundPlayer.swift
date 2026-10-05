import Foundation

/// transcribe-thing's UI sounds, as the main actor sees them: a gate ("Play sounds") in front of `CueEngine`,
/// which plays them on its own queue. Nothing here touches audio, so a cue never stalls the main thread, not even
/// while AirPods wake their Bluetooth route. Not system sounds (alert volume, muted by the "UI sound effects"
/// setting). Cues play at full volume: each one's level is baked into its file (scripts/gen-sounds.py), and
/// "Play sounds" in General is the only switch.
@MainActor
final class SoundPlayer {
    private let settings: AppSettings
    private let engine: CueEngine
    private var isPreloaded = false
    /// A mic is starting: `captureStarted()` is due (its first audio, or the wait running out).
    private var micWait: Task<Void, Never>?

    /// How long cues wait for a starting mic's first audio before they go anyway.
    static let micStartWait: Duration = .milliseconds(300)

    /// Lengths of the bundled WAVs (scripts/gen-sounds.py); used until the files are loaded.
    static let nominalDurations: [SoundEffect: TimeInterval] = [
        .start: 0.07, .stop: 0.085, .lock: 0.125, .paste: 0.045,
        .cancel: 0.095, .alert: 0.25, .error: 0.21, .success: 0.27, .modelSwitch: 0.07, .polishOn: 0.09,
        .polishOff: 0.09, .polishReady: 0.12,
    ]

    init(settings: AppSettings, engine: CueEngine = CueEngine()) {
        self.settings = settings
        self.engine = engine
    }

    /// Loads every sound (in the background); call once at launch (never in previews). Until then nothing plays.
    func preload() {
        guard !isPreloaded else { return }
        isPreloaded = true
        engine.load()
    }

    /// Returns at once; the cue plays on the engine's queue.
    func play(_ effect: SoundEffect) {
        guard isPreloaded, settings.soundsEnabled else { return }
        engine.play(effect)
    }

    /// A mic is starting: until its first audio (`captureStarted()`), at most `micStartWait`, the engine holds
    /// the cues that can't play at once without holding the mic up (`CueEngine.micStarting`).
    func captureStarting(bluetooth: Bool) {
        guard isPreloaded else { return }
        engine.micStarting(bluetooth: bluetooth)
        micWait?.cancel()
        micWait = Task { [weak self] in
            try? await Task.sleep(for: Self.micStartWait)
            guard !Task.isCancelled else { return }
            self?.captureStarted()
        }
    }

    /// The mic delivers audio (or gave up): what waited for it plays, in order.
    func captureStarted() {
        guard let micWait else { return }
        micWait.cancel()
        self.micWait = nil
        engine.micStarted()
    }

    /// While a dictation records or waits for its text, the output stays up between its cues.
    func setDictationActive(_ active: Bool) {
        guard isPreloaded else { return }
        engine.setHeld(active)
    }

    var startSoundDuration: TimeInterval { duration(of: .start) }

    func duration(of effect: SoundEffect) -> TimeInterval {
        engine.duration(of: effect) ?? Self.nominalDurations[effect] ?? 0.2
    }
}
