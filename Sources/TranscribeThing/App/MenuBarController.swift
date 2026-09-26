import AppKit
import QuartzCore

/// The menu bar extra: template icon, a red dot while recording, a slow pulse while transcribing,
/// and the shared transcribe-thing menu (rebuilt each time it opens).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    weak var environment: AppEnvironment? {
        didSet { builder.environment = environment }
    }

    let builder = MenuBuilder()
    private var statusItem: NSStatusItem?
    private var recordingDot: NSView?
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
        guard let button = statusItem?.button else { return }
        setRecordingDot(activity == .recording, on: button)
        setPulsing(activity == .processing, on: button)
        let value = switch activity {
        case .idle: "Idle"
        case .recording: "Recording"
        case .processing: "Transcribing"
        }
        button.setAccessibilityValue(value)
    }

    private func setRecordingDot(_ visible: Bool, on button: NSStatusBarButton) {
        guard visible != (recordingDot != nil) else { return }
        button.image = MenuBarIcon.template(badgeHole: visible)
        guard visible else {
            recordingDot?.removeFromSuperview()
            recordingDot = nil
            return
        }
        let size = MenuBarIcon.badgeDiameter
        let bounds = button.bounds
        // The image is centered in the button; map the badge from image to button coordinates.
        let dx = MenuBarIcon.badgeCenter.x - MenuBarIcon.size.width / 2
        let dy = MenuBarIcon.badgeCenter.y - MenuBarIcon.size.height / 2
        let center = CGPoint(x: bounds.midX + dx, y: button.isFlipped ? bounds.midY - dy : bounds.midY + dy)
        let dot = NSView(frame: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = size / 2
        dot.setAccessibilityElement(false)
        button.addSubview(dot)
        recordingDot = dot
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

/// transcribe-thing's menu bar glyph, drawn in code: a capsule (the pill) holding a five-bar waveform. While recording,
/// a hole is cut behind the badge so the red dot never collides with the outline.
enum MenuBarIcon {
    static let size = NSSize(width: 20, height: 16)
    /// Badge center in image coordinates (origin bottom-left).
    static let badgeCenter = CGPoint(x: 18.5, y: 13.25)
    static let badgeDiameter: CGFloat = 6

    static func template(badgeHole: Bool = false) -> NSImage {
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

            if badgeHole, let context = NSGraphicsContext.current {
                context.compositingOperation = .clear
                let r = badgeDiameter / 2 + 1.25
                NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - r, y: badgeCenter.y - r, width: r * 2, height: r * 2)).fill()
                context.compositingOperation = .sourceOver
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "transcribe-thing"
        return image
    }
}
