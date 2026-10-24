import AppKit

/// Hears a click (left or right button) away from transcribe-thing while a dictation is processed, for General →
/// Pasting's "Hold the paste after a click" (`DictationController.clickedAway`).
///
/// What counts as away is what macOS itself decides. A global event monitor hears only the events the window server
/// delivers to other apps, never one that goes to a window of transcribe-thing's: the Hub, onboarding, the menu bar
/// item and its menu, the pill's context menu, and the pill and its cards while they take the click. The pill's panel
/// lets clicks through wherever it draws nothing (its canvas is far larger than the pill), and takes them only while
/// the pointer is over the pill, its chip or a card (`PillController.updatePointer`). A click that comes before the
/// panel has caught up with the pointer goes through to the app below; it's asked about too (`isOwnContent`), so a
/// click on the pill or a card never counts.
///
/// Mouse monitors need no permission. It listens only while asked to (`isWatching`): while a dictation is processed.
@MainActor
final class ClickAwayMonitor {
    /// A click went to another app.
    var onClickAway: (() -> Void)?
    /// The pill, its chip or a card is at this point of the screen (Cocoa coordinates) and takes clicks there.
    var isOwnContent: ((CGPoint) -> Bool)?
    /// Listening: a dictation is processed.
    var isWatching = false {
        didSet { if isWatching != oldValue { updateMonitor() } }
    }

    /// False in previews and tests: nothing is installed, and `mouseDown(at:)` stands for the clicks.
    private let listens: Bool
    private var monitor: Any?

    init(listens: Bool = true) {
        self.listens = listens
    }

    private func updateMonitor() {
        if isWatching, listens, monitor == nil {
            // Called on the main thread, right as the click goes to the other app: the pointer is where it clicked.
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseDown(at: NSEvent.mouseLocation) }
            }
        } else if !isWatching, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// A click that went to another app, at `point` on the screen.
    func mouseDown(at point: CGPoint) {
        guard isWatching, isOwnContent?(point) != true else { return }
        onClickAway?()
    }
}
