import Foundation

/// transcribe-thing's sound family. Raw values are the file names in Resources/Sounds (`<raw>.wav`).
enum SoundEffect: String, CaseIterable, Sendable {
    case start, stop, lock, paste, cancel, alert, error, success
    /// The soft tick of the Switch model shortcut.
    case modelSwitch
    /// Polish turned on and off for a dictation: a drop rising, and falling (set A only, `scripts/gen-sounds.py`).
    case polishOn, polishOff

    var fileName: String { rawValue }
    static let fileExtension = "wav"
}
