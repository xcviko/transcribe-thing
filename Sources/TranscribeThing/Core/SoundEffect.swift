import Foundation

/// transcribe-thing's sound family. Raw values are the file names in Resources/Sounds (`<raw>.wav`).
enum SoundEffect: String, CaseIterable, Sendable {
    case start, stop, lock, paste, cancel, alert, error, success
    /// The soft tick of the Switch model shortcut.
    case modelSwitch
    /// Polish turned on and off for a dictation: a drop rising, and falling (set A only, `scripts/gen-sounds.py`).
    case polishOn, polishOff
    /// Polish Selection's card coming up: a bubble surfacing.
    case polishReady
    /// A word went into the dictionary (fn D): a soft "done?", one tongue pop gliding up.
    case dictionaryAdded

    var fileName: String { rawValue }
    static let fileExtension = "wav"
}
