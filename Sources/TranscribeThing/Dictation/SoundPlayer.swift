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

    /// Lengths of the bundled WAVs (scripts/gen-sounds.py); used until the files are loaded.
    static let nominalDurations: [SoundEffect: TimeInterval] = [
        .start: 0.07, .stop: 0.085, .lock: 0.125, .paste: 0.045,
        .cancel: 0.095, .alert: 0.25, .error: 0.21, .success: 0.27, .modelSwitch: 0.07,
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

    /// A press is starting: get the output running before its start cue. With sounds off there is nothing to
    /// warm (and no reason to wake AirPods).
    func warmUp() {
        guard isPreloaded, settings.soundsEnabled else { return }
        engine.warmUp()
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
