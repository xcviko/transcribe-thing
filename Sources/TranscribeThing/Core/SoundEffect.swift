import Foundation

/// transcribe-thing's sound family. Raw values are the file names in Resources/Sounds (`<raw>.wav`).
enum SoundEffect: String, CaseIterable, Sendable {
    case start, stop, lock, paste, cancel, alert, error, success
    /// The soft tick of the Switch model shortcut.
    case modelSwitch
    /// Polish turned on and off for a dictation: a drop rising, and falling (set A only, `scripts/gen-sounds.py`).
    case polishOn, polishOff
    /// A card of text to paste coming up (Polish Selection's answer, an earlier dictation's text): a bubble surfacing.
    case polishReady
    /// A word went into the dictionary (fn D): a soft "done?", one tongue pop gliding up.
    case dictionaryAdded
    /// Send turned on or off for a dictation (fn ↩): an airy flick up, a breath rising into a tongue pop.
    case sendOn

    var fileName: String { rawValue }
    static let fileExtension = "wav"
}
