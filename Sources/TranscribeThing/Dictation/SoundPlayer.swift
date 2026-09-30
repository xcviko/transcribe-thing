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
    /// Cues (nil: a warm-up) asked for while a mic starts, with when; nil while no mic is starting.
    private var heldForMic: [(effect: SoundEffect?, requestedAt: UInt64)]?
    private var micWait: Task<Void, Never>?

    /// How long cues wait for a starting mic's first audio before they go anyway.
    static let micStartWait: Duration = .milliseconds(300)

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
        if heldForMic != nil {
            heldForMic?.append((effect, DispatchTime.now().uptimeNanoseconds))
        } else {
            engine.play(effect)
        }
    }

    /// A press is starting: get the output running before its start cue. With sounds off there is nothing to
    /// warm (and no reason to wake AirPods).
    func warmUp() {
        guard isPreloaded, settings.soundsEnabled else { return }
        if heldForMic != nil {
            heldForMic?.append((nil, DispatchTime.now().uptimeNanoseconds))
        } else {
            engine.warmUp()
        }
    }

    /// A mic is starting: cues and warm-ups wait for its first audio (`captureStarted()`), at most
    /// `micStartWait`. Waking AirPods keeps Core Audio busy for ~450 ms, and a mic start or a Core Audio call
    /// made meanwhile waits for it: the recording would start late and the pill's first frame with it.
    func captureStarting() {
        guard isPreloaded else { return }
        if heldForMic == nil { heldForMic = [] }
        micWait?.cancel()
        micWait = Task { [weak self] in
            try? await Task.sleep(for: Self.micStartWait)
            guard !Task.isCancelled else { return }
            self?.captureStarted()
        }
    }

    /// The mic delivers audio (or gave up): what waited for it goes to the engine, in order.
    func captureStarted() {
        micWait?.cancel()
        micWait = nil
        guard let held = heldForMic else { return }
        heldForMic = nil
        for item in held {
            if let effect = item.effect {
                engine.play(effect, requestedAt: item.requestedAt)
            } else {
                engine.warmUp()
            }
        }
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
