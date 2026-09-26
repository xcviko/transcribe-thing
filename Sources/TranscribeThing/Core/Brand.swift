import Foundation

/// The app's name in copy people read. Always lowercase and hyphenated, even at the start of a sentence.
enum Brand {
    /// "transcribe‑thing" with U+2011 NON-BREAKING HYPHEN. SF and New York draw it with the same glyph as "-",
    /// but a line never breaks between "transcribe" and "thing" (a plain hyphen is a break opportunity, so
    /// wrapped copy could end a line with "transcribe-"). Use it in every string a view can wrap: onboarding,
    /// hub, notices and toasts. Bundle and file names, identifiers, menu items, window titles and CLI output
    /// keep the plain "transcribe-thing": they never wrap, and people type and search for them.
    static let name = "transcribe\u{2011}thing"
}
