import AppKit
import Observation

// STUB (FOUNDATION): PILL owns this model.
@MainActor @Observable
final class PillModel {
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let levelMeter: LevelMeter

    var phase: PillPhase = .hidden
    var isHovering = false
    /// Hands-free timer (shown on hover or in the last 60 s).
    var recordingStartedAt: Date?
    var limitSeconds: TimeInterval = 1200
    /// Key-chip text for the tooltip, from `settings.shortcuts[.pushToTalk]`.
    var shortcutHint: String = "fn"
    /// Increment to shake.
    var shakeTrigger = 0
    @ObservationIgnored var onClick: (() -> Void)?
    @ObservationIgnored var onStop: (() -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?
    @ObservationIgnored var contextMenuProvider: (() -> NSMenu)?

    init(settings: AppSettings, levelMeter: LevelMeter) {
        self.settings = settings
        self.levelMeter = levelMeter
        self.limitSeconds = settings.maxRecordingDuration
        self.shortcutHint = settings.shortcuts[.pushToTalk]?.compactDescription ?? "fn"
    }

    static func preview(phase: PillPhase, level: Float = 0.55) -> PillModel {
        let model = PillModel(settings: .inMemory(), levelMeter: .preview(level: level))
        model.phase = phase
        return model
    }
}
