import Foundation

/// transcribe-thing's sound family. Raw values are the file names in Resources/Sounds (`<raw>.wav`).
enum SoundEffect: String, CaseIterable, Sendable {
    case start, stop, lock, paste, cancel, alert, error, success
    /// The soft tick of the Switch model shortcut.
    case modelSwitch

    var fileName: String {
        switch self {
        // Placeholder until scripts/gen-sounds.py makes its own file: the paste tick is the closest cue.
        case .modelSwitch: "paste"
        default: rawValue
        }
    }
    static let fileExtension = "wav"
}
