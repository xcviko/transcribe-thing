import Foundation

// STUB (FOUNDATION): AUDIO replaces this with the AVAudioEngine recorder.
enum AudioRecorderEvent: Sendable {
    case firstBuffer, deviceLost, configurationChanged, failed(MurmurError)
}

@MainActor
final class AudioRecorder {
    private let levelMeter: LevelMeter
    private let devices: AudioDeviceCatalog
    private var startedAt = Date()

    var onEvent: ((AudioRecorderEvent) -> Void)?
    private(set) var isCapturing = false

    init(levelMeter: LevelMeter, devices: AudioDeviceCatalog) {
        self.levelMeter = levelMeter
        self.devices = devices
    }

    /// Throws `MurmurError`.
    func start(preferredDeviceUID: String?) throws {
        startedAt = Date()
        isCapturing = true
    }

    func stop() -> Recording {
        isCapturing = false
        return Recording(samples: [], startedAt: startedAt, speech: .empty, deviceName: currentDeviceName)
    }

    /// Captured audio for Undo, or nil if shorter than 0.3 s.
    func cancel() -> Recording? {
        isCapturing = false
        return nil
    }

    func duckRecording(from: TimeInterval, duration: TimeInterval) {}

    var currentDeviceName: String? { nil }
}
