import Foundation

/// One captured dictation: 16 kHz mono Float32 samples in [-1, 1].
struct Recording: Sendable, Identifiable, Equatable {
    static let sampleRate: Double = 16_000

    let id: UUID
    var samples: [Float]
    let startedAt: Date
    /// Filled by the recorder at `stop()`.
    var speech: SpeechStats
    var deviceName: String?
    /// The .m4a in History these samples were read from (`HistoryStore.loadRecording`). Saved again, the recording
    /// keeps that file rather than being encoded a second time, and Gemini takes it as it is when it goes compressed.
    var aacFile: URL?

    init(
        id: UUID = UUID(),
        samples: [Float],
        startedAt: Date = Date(),
        speech: SpeechStats = .empty,
        deviceName: String? = nil
    ) {
        self.id = id
        self.samples = samples
        self.startedAt = startedAt
        self.speech = speech
        self.deviceName = deviceName
    }

    var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
}

struct SpeechStats: Sendable, Equatable, Codable {
    /// Seconds of frames whose energy sits more than 10 dB above the adaptive noise floor.
    var voicedSeconds: Double
    var peakDBFS: Float
    /// Flat or zero signal for the whole recording: the mic is muted or broken.
    var isSilent: Bool

    static let empty = SpeechStats(voicedSeconds: 0, peakDBFS: -160, isSilent: true)
}
