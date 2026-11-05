import AppKit
import QuartzCore

/// The menu bar extra: template icon, a slow pulse while transcribing, and the shared transcribe-thing menu (rebuilt
/// each time it opens).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    weak var environment: AppEnvironment? {
        didSet { builder.environment = environment }
    }

    let builder = MenuBuilder()
    private var statusItem: NSStatusItem?
    private(set) var activity: DictationActivity = .idle

    override init() {
        super.init()
    }

    func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "TranscribeThingStatusItem"
        if let button = item.button {
            button.image = MenuBarIcon.template()
            button.imagePosition = .imageOnly
            button.toolTip = "transcribe-thing"
            button.setAccessibilityLabel("transcribe-thing")
            button.wantsLayer = true
        }
        let menu = NSMenu(title: "transcribe-thing")
        menu.delegate = self
        item.menu = menu
        statusItem = item
        show(environment?.dictation.activity ?? .idle)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        builder.populate(menu, includeQuit: true)
    }

    /// Reflects the dictation state in the icon.
    func show(_ activity: DictationActivity) {
        self.activity = activity
        refresh()
    }

    private func refresh() {
        guard let button = statusItem?.button else { return }
        setPulsing(activity != .idle && activity != .recording, on: button)
        button.setAccessibilityValue(Self.accessibilityValue(activity: activity))
    }

    static func accessibilityValue(activity: DictationActivity) -> String {
        switch activity {
        case .idle: "Idle"
        case .recording: "Recording"
        case .processing: "Transcribing"
        case .polishing: "Polishing"
        case .translating: "Translating"
        }
    }

    private func setPulsing(_ pulsing: Bool, on button: NSStatusBarButton) {
        guard let layer = button.layer else { return }
        layer.removeAnimation(forKey: "tt.pulse")
        guard pulsing else {
            layer.opacity = 1
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            layer.opacity = 0.55
            return
        }
        layer.opacity = 1
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.35
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "tt.pulse")
    }
}

/// transcribe-thing's menu bar glyph, drawn in code: a capsule (the pill) holding a five-bar waveform.
enum MenuBarIcon {
    static let size = NSSize(width: 20, height: 16)

    static func template() -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.set()
            let stroke: CGFloat = 1.4
            let capsuleRect = NSRect(x: rect.minX + 0.75, y: rect.midY - 5.5, width: rect.width - 1.5, height: 11)
                .insetBy(dx: stroke / 2, dy: stroke / 2)
            let capsule = NSBezierPath(roundedRect: capsuleRect, xRadius: capsuleRect.height / 2, yRadius: capsuleRect.height / 2)
            capsule.lineWidth = stroke
            capsule.stroke()

            let heights: [CGFloat] = [2.5, 4.5, 6.25, 4.5, 2.5]
            let barWidth: CGFloat = 1.5
            let gap: CGFloat = 1.35
            let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
            var x = rect.midX - total / 2
            for height in heights {
                let bar = NSRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height)
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
                x += barWidth + gap
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "transcribe-thing"
        return image
    }
}
