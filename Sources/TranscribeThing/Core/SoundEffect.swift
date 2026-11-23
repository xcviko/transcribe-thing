import Foundation

/// transcribe-thing's sound family. Raw values are the file names in Resources/Sounds (`<raw>.wav`).
enum SoundEffect: String, CaseIterable, Sendable {
    case start, stop, lock, paste, cancel, alert, error, success
    /// A light start: start's pop, higher, shorter and much quieter. The talk key went down over a dictation on its
    /// way and nothing records; the pill says "fn again to dictate".
    case startLight
    /// The soft tick of the Switch model shortcut.
    case modelSwitch
    /// Polish turned on and off for a dictation: a drop rising, and falling (set A only, `scripts/gen-sounds.py`).
    case polishOn, polishOff
    /// A card of text to paste coming up (Polish Selection's answer, an earlier dictation's text): a bubble surfacing.
    case polishReady
    /// A word went into the dictionary (fn D): a soft "done?", one tongue pop gliding up.
    case dictionaryAdded
    /// Send turned on or off for a dictation (the pill's paper plane): an airy flick up, a breath rising into a tongue pop.
    case sendOn
    /// A click away held a dictation's paste (its pill turned dashed): three tiny ticks rolling down. A click on the
    /// dashed pill takes it back: the same three going up.
    case pasteHeld, pasteTakenBack

    var fileName: String { rawValue }
    static let fileExtension = "wav"
}
