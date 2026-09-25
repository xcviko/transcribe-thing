import AppKit
import SwiftUI

/// Borderless, non-activating overlay panel that can never become key or main, so the app the user is
/// typing in keeps focus even while the pill or a toast is clicked.
final class PillPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // `isFloatingPanel` resets the level to .floating; the status bar level sits above the Dock and menu bar.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
                              .canJoinAllApplications]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        worksWhenModal = true
        // ⌘H on a Murmur window must not hide the pill.
        canHide = false
        isOpaque = false
        backgroundColor = .clear
        // SwiftUI draws the shadows; a window shadow would be computed from stale alpha while the pill morphs.
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        ignoresMouseEvents = true
        // Never in screenshots, screen shares or recordings (Wispr parity).
        sharingType = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Accepts the first click without activating the app, reports pointer movement while the panel takes mouse
/// events, and routes right-clicks on the pill to its context menu.
final class PillHostingView: NSHostingView<PillCanvasView> {
    var onPointerActivity: (() -> Void)?
    /// Returns true when it handled the click (showed the menu).
    var onRightMouseDown: ((NSEvent) -> Bool)?

    required init(rootView: PillCanvasView) {
        super.init(rootView: rootView)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerActivity?()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerActivity?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerActivity?()
    }

    override func rightMouseDown(with event: NSEvent) {
        if onRightMouseDown?(event) == true { return }
        super.rightMouseDown(with: event)
    }
}
