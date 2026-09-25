import Foundation

// STUB (FOUNDATION): SHELL replaces this with preloaded AVAudioPlayers.
@MainActor
final class SoundPlayer {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func preload() {}

    func play(_ effect: SoundEffect) {}

    var startSoundDuration: TimeInterval { 0.15 }
}
