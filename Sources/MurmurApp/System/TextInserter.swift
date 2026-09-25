import AppKit

// STUB (FOUNDATION): SYSTEM replaces this with the pasteboard + ⌘V pipeline.
enum InsertionOutcome: Equatable, Sendable {
    case pasted, noEditableTarget, targetChanged, accessibilityMissing, failed(String)
}

@MainActor
final class TextInserter {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// On non-pasted outcomes the text is not lost: the caller shows a transcript card.
    func insert(_ text: String, expectedPID: pid_t?) async -> InsertionOutcome {
        .failed("Not available yet.")
    }

    /// "Paste here": paste into the current focus without checks.
    func pasteNow(_ text: String) async -> InsertionOutcome {
        .failed("Not available yet.")
    }

    func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
