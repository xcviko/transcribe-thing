import AVFAudio
import CoreAudio
import Foundation

/// transcribe-thing's UI sounds: one prepared `AVAudioPlayer` per effect so playback starts within a few ms.
/// Not AVAudioEngine (it must never share an engine with capture, and a running engine keeps the output
/// device busy) and not system sounds (alert volume, muted by the "UI sound effects" setting).
/// Players stay at their full volume (1.0): each cue's level is baked into its file (scripts/gen-sounds.py),
/// and "Play sounds" in General is the only switch.
@MainActor
final class SoundPlayer {
    private let settings: AppSettings
    private var players: [SoundEffect: AVAudioPlayer] = [:]
    private var durations: [SoundEffect: TimeInterval] = [:]
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var isPreloaded = false

    /// Lengths of the bundled WAVs (scripts/gen-sounds.py); used until the files are loaded.
    static let nominalDurations: [SoundEffect: TimeInterval] = [
        .start: 0.07, .stop: 0.085, .lock: 0.125, .paste: 0.045,
        .cancel: 0.095, .alert: 0.25, .error: 0.21, .success: 0.27, .modelSwitch: 0.07,
    ]

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Loads and primes every sound; call once at launch (never in previews).
    func preload() {
        guard !isPreloaded else { return }
        isPreloaded = true
        loadPlayers()
        observeDefaultOutput()
    }

    func play(_ effect: SoundEffect) {
        guard settings.soundsEnabled, let player = players[effect] else { return }
        if player.isPlaying { player.stop() }
        player.currentTime = 0
        if !player.play() {
            // A player bound to a vanished output device refuses to play; rebuild once.
            reload()
            players[effect]?.play()
        }
    }

    var startSoundDuration: TimeInterval { duration(of: .start) }

    func duration(of effect: SoundEffect) -> TimeInterval {
        durations[effect] ?? Self.nominalDurations[effect] ?? 0.2
    }

    private func loadPlayers() {
        var loaded: [SoundEffect: AVAudioPlayer] = [:]
        for effect in SoundEffect.allCases {
            guard let url = AppResources.url(effect.fileName, ext: SoundEffect.fileExtension, subdirectory: "Sounds") else {
                Log.app.error("Missing sound \(effect.rawValue, privacy: .public).wav")
                continue
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                loaded[effect] = player
                durations[effect] = player.duration
            } catch {
                Log.app.error("Couldn't load sound \(effect.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        players = loaded
    }

    private func reload() {
        for player in players.values { player.stop() }
        loadPlayers()
    }

    /// Players stay bound to the device that was default when they were prepared (AirPods connecting,
    /// switching to an external display's speakers), so rebuild them when the default output changes.
    private func observeDefaultOutput() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block = Self.makeOutputListener { [weak self] in self?.reload() }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        if status == noErr { outputListener = block }
    }

    /// Built outside main-actor code: CoreAudio calls the block on the queue we pass (main), and the
    /// hop back into the actor is explicit.
    private nonisolated static func makeOutputListener(_ action: @escaping @MainActor () -> Void) -> AudioObjectPropertyListenerBlock {
        { _, _ in
            MainActor.assumeIsolated { action() }
        }
    }
}
