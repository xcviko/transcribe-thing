import Foundation

/// What the pill shows. `.rest` resolves to the resting capsule when the pill mode is Always, else hidden.
enum PillPhase: Equatable, Sendable {
    case hidden, rest, listening, locked, processing, success, error

    /// Phases in which the microphone is live.
    var isRecording: Bool { self == .listening || self == .locked }

    /// Phases that belong to an active dictation (shown even in "Only while dictating" mode).
    var isActive: Bool {
        switch self {
        case .listening, .locked, .processing, .success, .error: true
        case .hidden, .rest: false
        }
    }
}
