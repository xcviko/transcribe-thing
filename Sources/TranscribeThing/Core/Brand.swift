import Foundation

/// The app's name in copy people read. Always lowercase and hyphenated, even at the start of a sentence.
enum Brand {
    /// "transcribe‑thing" with U+2011 NON-BREAKING HYPHEN. SF and New York draw it with the same glyph as "-",
    /// but a line never breaks between "transcribe" and "thing" (a plain hyphen is a break opportunity, so
    /// wrapped copy could end a line with "transcribe-"). Use it in every string a view can wrap: onboarding,
    /// hub, notices and toasts. Bundle and file names, identifiers, menu items, window titles and CLI output
    /// keep the plain "transcribe-thing": they never wrap, and people type and search for them.
    static let name = "transcribe\u{2011}thing"

    /// The GitHub repository (owner/name) releases and in-app updates come from.
    static let repository = "xcviko/transcribe-thing"
    /// Every release, newest first: where "View on GitHub" and "Download from GitHub" go.
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    /// GitHub's REST listing of the same releases, which the update checker reads.
    static let releasesFeed = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!
}
