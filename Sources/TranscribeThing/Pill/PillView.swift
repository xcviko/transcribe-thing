import AppKit
import SwiftUI

// MARK: - Tokens

/// Pill geometry (wispr-ux §1.3–1.4). Everything in points.
enum PillMetrics {
    static let restSize = CGSize(width: 40, height: 10)
    static let peekSize = CGSize(width: 76, height: 24)
    static let listeningSize = CGSize(width: 104, height: 32)
    /// Hands-free always carries the timer, so hovering never resizes it (nor does the timer reaching 10:00).
    static let lockedSize = CGSize(width: 198, height: 36)
    static let errorSize = CGSize(width: 104, height: 32)
    /// Tallest state; toasts sit 10 pt above it so they never move while the pill changes shape.
    static let maxHeight: CGFloat = 36

    static let barCount = 13
    static let barWidth: CGFloat = 3
    static let barGap: CGFloat = 2.5
    static let barFieldWidth: CGFloat = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
    static let barMinHeight: CGFloat = 3
    static let barMaxHeight: CGFloat = 20

    static let buttonSize: CGFloat = 22
    static let buttonInset: CGFloat = 7
    /// Monospaced digits, so the timer never jitters as it counts.
    static let timerFont = Font.system(size: 11, weight: .medium, design: .rounded).monospacedDigit()
    /// Fits "29:59" in `timerFont`: the longest recording limit is 30 min.
    static let timerWidth: CGFloat = 33
    /// "9:59", the timer's width for most recordings.
    static let shortTimerWidth: CGFloat = 26
    /// Hands-free spaces X, the bars, the timer and Stop by one even gap, 15 pt. That holds for a "9:59"
    /// timer, which sits centered in the timer's column; "29:59" fills the column, taking 3.5 pt from each side.
    static let lockedGap: CGFloat = (lockedSize.width - 2 * (buttonInset + buttonSize) - barFieldWidth - shortTimerWidth) / 3
    /// Space between the timer's column and Stop.
    static let timerTrailing: CGFloat = lockedGap - (timerWidth - shortTimerWidth) / 2
    /// How far left of the pill's center hands-free draws the bars: one gap right of X.
    static let lockedBarsOffset: CGFloat = buttonInset + buttonSize + lockedGap + barFieldWidth / 2 - lockedSize.width / 2
    static let tooltipHeight: CGFloat = 28
    /// Invisible margin around the pill that counts as hovering it (and clicking it).
    static let hoverMargin: CGFloat = 12
}

/// The pill is always dark, in both appearances; these colors never adapt.
enum PillPalette {
    static let fill = Color(nsColor: Palette.pillFill)
    static let bar = Color.white.opacity(0.96)
    static let stop = Color(nsColor: .hex(0xFF453A))
    static let warning = Color(nsColor: .hex(0xFFB340))
    static let error = Color(nsColor: .hex(0xFF6B5E))
    static let tooltipFill = Color(nsColor: .hex(0x151517, alpha: 0.96))
}

extension EnvironmentValues {
    /// Snapshots set this: animations that start on appear render in their settled state instead.
    @Entry var pillStaticRendering = false
}

// MARK: - Visual state

enum PillTimerMode: Equatable, Sendable {
    case elapsed, remaining
}

/// What the capsule looks like: the phase plus hover, presentation and the recording timer.
enum PillVisual: Equatable, Sendable {
    case hidden, rest, peek, listening
    /// One-time post-onboarding bloom: listening size, bars ripple once, then rest as dots.
    case hello
    case locked(PillTimerMode)
    /// `wide` after hands-free: keeps the hands-free width, so stopping doesn't shrink the pill.
    case processing(wide: Bool)
    case error

    enum Content: Hashable { case empty, peek, hello, recording, processing, error }

    var size: CGSize {
        switch self {
        case .hidden, .rest: PillMetrics.restSize
        case .peek: PillMetrics.peekSize
        case .listening, .hello: PillMetrics.listeningSize
        case .locked: PillMetrics.lockedSize
        case .processing(let wide): CGSize(width: wide ? PillMetrics.lockedSize.width : PillMetrics.listeningSize.width,
                                           height: PillMetrics.listeningSize.height)
        case .error: PillMetrics.errorSize
        }
    }

    var content: Content {
        switch self {
        case .hidden, .rest: .empty
        case .peek: .peek
        case .hello: .hello
        case .listening, .locked: .recording
        case .processing: .processing
        case .error: .error
        }
    }

    /// Resting shapes cast half the shadow.
    var isQuiet: Bool {
        switch self {
        case .hidden, .rest, .peek: true
        default: false
        }
    }

    /// Only hands-free shows the timer.
    var timer: PillTimerMode? { if case .locked(let t) = self { t } else { nil } }

    /// Horizontal offset of the bars from the pill's center. Hands-free centers them between X and the timer;
    /// processing after it starts its dots there too, so they don't hop sideways when Stop is pressed.
    var barsOffset: CGFloat {
        switch self {
        case .locked, .processing(wide: true): PillMetrics.lockedBarsOffset
        default: 0
        }
    }

    /// The bars' center as a point of the capsule: processing content scales in around it, so dots that start
    /// where the hands-free bars were don't also drift toward the pill's center while they grow in.
    var barsAnchor: UnitPoint { UnitPoint(x: 0.5 + barsOffset / size.width, y: 0.5) }
}

// MARK: - Pill

/// The dark capsule and everything inside it. `PillView(model:)` draws `model.visiblePhase` as-is (for
/// illustrations); the panel canvas uses the `.panel` context, which applies the visibility rules and hit regions.
struct PillView: View {
    enum Context {
        case standalone
        case panel(PillHitRegions?)
    }

    let model: PillModel
    var context: Context = .standalone

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: PillModel) {
        self.model = model
    }

    init(model: PillModel, context: Context) {
        self.model = model
        self.context = context
    }

    private var isPanel: Bool { if case .panel = context { true } else { false } }

    private var regions: PillHitRegions? { if case .panel(let r) = context { r } else { nil } }

    var visual: PillVisual {
        let phase = model.visiblePhase
        if isPanel {
            guard model.isPresented else { return .hidden }
            if phase.isIdle {
                if model.isHelloActive { return .hello }
                return model.isHovering ? .peek : .rest
            }
        } else if phase == .hidden {
            return .hidden
        }
        switch phase {
        case .hidden, .rest:
            return model.isHovering ? .peek : .rest
        case .listening:
            return .listening
        case .locked:
            return .locked(model.isInFinalMinute ? .remaining : .elapsed)
        case .processing:
            return .processing(wide: model.processingOrigin == .locked)
        case .error:
            return .error
        }
    }

    var body: some View {
        let visual = self.visual
        let size = visual.size
        let shown = visual != .hidden
        ZStack {
            PillCapsule(quiet: visual.isQuiet, glow: visual == .error ? PillPalette.error : nil)
            content(for: visual)
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(shown || reduceMotion ? 1 : 0.6, anchor: .bottom)
        // Appearing, the fade runs ahead of the spring: a spring starts from rest and would keep the capsule
        // nearly transparent for its first 50 ms. The scale still blooms with the spring.
        .animation(fadeAnimation(shown: shown, to: visual)) { $0.opacity(shown ? 1 : 0) }
        .modifier(PillShake(trigger: model.shakeCount, enabled: !reduceMotion))
        .animation(animation(to: visual), value: visual)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel(for: visual))
        .accessibilityHidden(!shown)
    }

    @ViewBuilder
    private func content(for visual: PillVisual) -> some View {
        switch visual.content {
        case .empty:
            Color.clear
                .id(PillVisual.Content.empty)
        case .peek:
            PeekDots()
                .id(PillVisual.Content.peek)
                .transition(contentTransition())
        case .hello:
            HelloRipple()
                .id(PillVisual.Content.hello)
                .transition(contentTransition())
        case .recording:
            RecordingContent(model: model, timer: visual.timer, barsOffset: visual.barsOffset, regions: regions)
                .id(PillVisual.Content.recording)
                .transition(contentTransition())
        case .processing:
            ProcessingWaveView(startOffset: visual.barsOffset)
                .id(PillVisual.Content.processing)
                .transition(contentTransition(anchor: visual.barsAnchor))
        case .error:
            ErrorGlyph()
                .id(PillVisual.Content.error)
                .transition(contentTransition())
        }
    }

    private func contentTransition(anchor: UnitPoint = .center) -> AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.85, anchor: anchor))
                .animation(.easeOut(duration: 0.18).delay(0.06)),
            removal: .opacity.animation(.easeIn(duration: 0.1)))
    }

    private func fadeAnimation(shown: Bool, to visual: PillVisual) -> Animation {
        shown && !reduceMotion ? .easeOut(duration: 0.12) : animation(to: visual)
    }

    private func animation(to visual: PillVisual) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        switch visual {
        case .hidden, .rest: return .spring(duration: 0.28, bounce: 0)
        case .peek: return .spring(duration: 0.22, bounce: 0.15)
        case .hello: return .spring(duration: 0.42, bounce: 0.3)
        case .listening: return .spring(duration: 0.32, bounce: 0.26)
        case .locked: return .spring(duration: 0.34, bounce: 0.3)
        case .processing: return .spring(duration: 0.3, bounce: 0.12)
        case .error: return .spring(duration: 0.3, bounce: 0.2)
        }
    }

    private func accessibilityLabel(for visual: PillVisual) -> String {
        switch visual {
        case .hidden: "transcribe-thing"
        case .rest, .peek, .hello: "transcribe-thing. Click to start hands-free dictation"
        case .listening: "transcribe-thing is listening"
        case .locked: "transcribe-thing is listening, hands-free"
        case .processing: "transcribe-thing is transcribing"
        case .error: "Dictation failed"
        }
    }
}

// MARK: - Capsule

/// Near-black capsule with a lit hairline (white 22% → 6%) and a two-layer shadow, so it reads on white
/// documents and on dark desktops alike.
struct PillCapsule: View {
    var quiet = false
    var glow: Color?

    var body: some View {
        let shape = Capsule(style: .continuous)
        shape
            .fill(PillPalette.fill)
            .overlay {
                if let glow {
                    shape.fill(RadialGradient(colors: [glow.opacity(0.2), glow.opacity(0)],
                                              center: .center, startRadius: 0, endRadius: 30))
                }
            }
            .overlay {
                // Soft top sheen: a hint of volume without turning into glass.
                shape.fill(LinearGradient(colors: [.white.opacity(0.08), .white.opacity(0)],
                                          startPoint: .top, endPoint: .center))
            }
            .overlay {
                // The resting shapes are small: a brighter top edge keeps them from sinking into dark content.
                shape.ring(0.5)
                    .fill(LinearGradient(colors: [.white.opacity(quiet ? 0.30 : 0.24), .white.opacity(0.07)],
                                         startPoint: .top, endPoint: .bottom), style: FillStyle(eoFill: true))
            }
            .overlay {
                // Faint outer edge: lost on light documents, it outlines the dark capsule on dark editors.
                shape.inset(by: -0.5).ring(0.5)
                    .fill(.white.opacity(0.11), style: FillStyle(eoFill: true))
            }
            .shadow(color: .black.opacity(quiet ? 0.11 : 0.22), radius: 1, x: 0, y: 1)
            .shadow(color: .black.opacity(quiet ? 0.14 : 0.28), radius: 9, x: 0, y: 6)
    }
}

// MARK: - Contents

/// Hover peek: nine quiet dots that fade in left to right.
private struct PeekDots: View {
    @Environment(\.pillStaticRendering) private var isStatic
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<9, id: \.self) { i in
                Circle()
                    .fill(.white.opacity(0.35))
                    .frame(width: 3, height: 3)
                    .opacity(appeared || isStatic || reduceMotion ? 1 : 0)
                    .animation(.easeOut(duration: 0.16).delay(Double(i) * 0.02), value: appeared)
            }
        }
        .onAppear { appeared = true }
    }
}

/// Hello bloom: the thirteen bars rise in a single wave from the left and settle into quiet dots, the way the
/// Done step previews it. Static snapshots freeze mid-wave; Reduce Motion shows the dots only.
private struct HelloRipple: View {
    @Environment(\.pillStaticRendering) private var isStatic
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appearedAt = Date()
    @State private var finished = false

    /// Bloom settles first, then each bar follows the previous one by 45 ms; each swell lasts 0.62 s.
    private static let start = 0.12
    private static let stagger = 0.045
    private static let swell = 0.62
    static var duration: Double { start + stagger * Double(PillMetrics.barCount - 1) + swell }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: isStatic || reduceMotion || finished)) { timeline in
            let t = isStatic ? 0.62 : (reduceMotion ? Self.duration : timeline.date.timeIntervalSince(appearedAt))
            Canvas(rendersAsynchronously: false) { context, size in
                Self.draw(in: &context, size: size, time: t)
            }
        }
        .frame(width: PillMetrics.barFieldWidth, height: PillMetrics.barMaxHeight)
        .onAppear { appearedAt = Date() }
        .task {
            try? await Task.sleep(for: .seconds(Self.duration + 0.1))
            finished = true
        }
        .accessibilityHidden(true)
    }

    /// Center weighting: env(i) = 0.35 + 0.65 · cos²(π(i − 6)/14).
    private static func envelope(_ i: Int) -> CGFloat {
        let c = cos(Double.pi * Double(i - PillMetrics.barCount / 2) / 14)
        return CGFloat(0.35 + 0.65 * c * c)
    }

    private static func draw(in context: inout GraphicsContext, size: CGSize, time t: Double) {
        let w = PillMetrics.barWidth
        let step = w + PillMetrics.barGap
        let minH = PillMetrics.barMinHeight
        let midY = size.height / 2
        for i in 0..<PillMetrics.barCount {
            let local = (t - start - stagger * Double(i)) / swell
            // 0 → 1 → 0 over the swell: sin(πx), eased so the rise is quicker than the fall.
            let lift = local <= 0 || local >= 1 ? 0 : sin(.pi * pow(local, 0.8))
            let h = minH + (size.height - minH) * Self.envelope(i) * CGFloat(lift) * 0.85
            let x = CGFloat(i) * step
            if h <= minH + 0.4 {
                let rect = CGRect(x: x, y: midY - minH / 2, width: w, height: minH)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.5)))
            } else {
                let rect = CGRect(x: x, y: midY - h / 2, width: w, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: w / 2),
                             with: .color(.white.opacity(0.5 + 0.46 * lift)))
            }
        }
    }
}

private struct ErrorGlyph: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(PillPalette.error.opacity(0.2))
                .frame(width: 20, height: 20)
            Image(systemName: "exclamationmark")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(PillPalette.error)
        }
    }
}

/// Bars while recording; in hands-free, X and Stop slide out from under the bars and the timer sits left
/// of Stop, all four evenly spaced (`PillMetrics.lockedGap`).
private struct RecordingContent: View {
    let model: PillModel
    /// Set in hands-free only.
    let timer: PillTimerMode?
    let barsOffset: CGFloat
    let regions: PillHitRegions?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var locked: Bool { timer != nil }

    var body: some View {
        ZStack {
            WaveformView(meter: model.levelMeter)
                .offset(x: barsOffset)
            // Each piece is inserted on its own so its transition runs (a transition only applies to the
            // outermost view being inserted).
            HStack(spacing: 0) {
                if locked {
                    PillControlButton(control: .cancel, model: model, regions: regions) { model.onCancel?() }
                        .transition(buttonTransition(from: 1, delay: 0))
                }
                Spacer(minLength: 0)
                if let timer {
                    PillTimerLabel(model: model, mode: timer)
                        .frame(width: PillMetrics.timerWidth)
                        .padding(.trailing, PillMetrics.timerTrailing)
                        .transition(.opacity.animation(.easeOut(duration: 0.16).delay(0.08)))
                }
                if locked {
                    PillControlButton(control: .stop, model: model, regions: regions) { model.onStop?() }
                        .transition(buttonTransition(from: -1, delay: 0.06))
                }
            }
            .padding(.horizontal, PillMetrics.buttonInset)
        }
    }

    /// Buttons grow out of the bars toward their edge; the second one follows 60 ms later.
    private func buttonTransition(from direction: CGFloat, delay: Double) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .offset(x: 30 * direction).combined(with: .scale(scale: 0.4)).combined(with: .opacity)
                .animation(.spring(duration: 0.34, bounce: 0.3).delay(delay)),
            removal: .opacity.combined(with: .scale(scale: 0.6)).animation(.easeIn(duration: 0.12)))
    }
}

/// X (cancel) and red Stop of the hands-free pill. Hover comes from the controller, which tracks the pointer
/// for the never-key panel.
private struct PillControlButton: View {
    let control: PillControl
    let model: PillModel
    let regions: PillHitRegions?
    let action: () -> Void

    private var hovered: Bool { model.hoveredControl == control }
    private var showsTooltip: Bool { model.controlTooltip == control }

    var body: some View {
        Button(action: action) {
            ZStack {
                switch control {
                case .cancel:
                    Circle().fill(.white.opacity(hovered ? 0.2 : 0.12))
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(hovered ? 0.95 : 0.8))
                case .stop:
                    Circle().fill(PillPalette.stop)
                        .overlay {
                            Circle().fill(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0)],
                                                         startPoint: .top, endPoint: .center))
                        }
                        .brightness(hovered ? 0.08 : 0)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(.white)
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: PillMetrics.buttonSize, height: PillMetrics.buttonSize)
            .scaleEffect(hovered && control == .stop ? 1.06 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .overlay(alignment: .top) {
            if showsTooltip {
                PillControlTooltip(control: control, settings: model.settings)
                    .fixedSize()
                    .offset(y: -(PillMetrics.tooltipHeight + PillMetrics.buttonInset + 8))
                    .transition(.opacity.combined(with: .offset(y: 3)).animation(.easeOut(duration: 0.14)))
                    .allowsHitTesting(false)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PillCanvasMetrics.space)) } action: { rect in
            regions?.setControl(control, rect: rect)
        }
        .onDisappear { regions?.setControl(control, rect: nil) }
        .accessibilityLabel(control == .cancel ? "Cancel dictation" : "Finish dictation")
    }
}

/// Elapsed "0:42", or the countdown in the last minute (amber in the last 10 s).
private struct PillTimerLabel: View {
    let model: PillModel
    let mode: PillTimerMode

    var body: some View {
        let start = model.recordingStartedAt ?? Date()
        TimelineView(.periodic(from: start, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(start))
            let remaining = max(0, model.limitSeconds - elapsed)
            let seconds = mode == .remaining ? remaining.rounded(.up) : elapsed.rounded(.down)
            Text(Fmt.duration(seconds))
                .font(PillMetrics.timerFont)
                .foregroundStyle(mode == .remaining && remaining <= 10 ? PillPalette.warning : .white.opacity(0.7))
                .lineLimit(1)
                .contentTransition(.numericText(countsDown: mode == .remaining))
        }
    }
}

// MARK: - Tooltips

/// Dark tooltip capsule used above the pill.
struct PillTooltipBubble<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = Capsule(style: .continuous)
        HStack(spacing: 5) { content }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.leading, 11)
            .padding(.trailing, 11)
            .frame(height: PillMetrics.tooltipHeight)
            .background {
                shape.fill(PillPalette.tooltipFill)
                    .overlay {
                        shape.ring(0.5)
                            .fill(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.06)],
                                                 startPoint: .top, endPoint: .bottom), style: FillStyle(eoFill: true))
                    }
                    .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
            }
            .environment(\.colorScheme, .dark)
    }
}

/// Key cap inside the dark tooltip: globe + fn, ⌘, space… on a white 18% chip.
struct PillKeyChip: View {
    var keycap: Keycap

    var body: some View {
        HStack(spacing: 2) {
            if let caption = keycap.sideCaption {
                Text(caption)
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
            if let symbol = keycap.systemImage {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
            }
            Text(keycap.label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .frame(minWidth: 18, minHeight: 17)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.18)))
        .fixedSize()
    }
}

struct PillShortcutChips: View {
    var shortcut: Shortcut?
    var fallback: String

    var body: some View {
        HStack(spacing: 3) {
            if let shortcut, !shortcut.isEmpty {
                ForEach(Array(shortcut.keycaps.enumerated()), id: \.offset) { _, cap in PillKeyChip(keycap: cap) }
            } else {
                PillKeyChip(keycap: Keycap(label: fallback))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut?.spokenDescription ?? fallback)
    }
}

/// "Hold [fn] to dictate · Click for hands-free"; the chip follows the push-to-talk binding.
struct PillRestTooltip: View {
    let model: PillModel

    var body: some View {
        PillTooltipBubble {
            Text("Hold")
            PillShortcutChips(shortcut: model.settings.shortcuts[.pushToTalk], fallback: model.shortcutHint)
            Text("to dictate")
            Text("·").foregroundStyle(.white.opacity(0.4))
            Text("Click for hands-free")
                .foregroundStyle(.white.opacity(0.7))
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Hold [fn] anywhere to dictate": the one-time hello after onboarding. No click hint, since in the default
/// mode the pill steps aside a few seconds later.
struct PillHelloTooltip: View {
    let model: PillModel

    var body: some View {
        PillTooltipBubble {
            Text("Hold")
            PillShortcutChips(shortcut: model.settings.shortcuts[.pushToTalk], fallback: model.shortcutHint)
            Text("anywhere to dictate")
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Cancel [esc]" over X, "Finish [fn][space]" over Stop.
private struct PillControlTooltip: View {
    let control: PillControl
    let settings: AppSettings

    var body: some View {
        PillTooltipBubble {
            switch control {
            case .cancel:
                Text("Cancel")
                PillShortcutChips(shortcut: settings.shortcuts[.cancel], fallback: "esc")
            case .stop:
                Text("Finish")
                PillShortcutChips(shortcut: settings.shortcuts[.handsFree], fallback: "fn space")
            }
        }
    }
}

// MARK: - Shake

/// Error shake: x 0 → −5 → 5 → −4 → 4 → −2 → 0 over 360 ms.
private struct PillShake: ViewModifier {
    var trigger: Int
    var enabled: Bool

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { view, x in
            view.offset(x: enabled ? x : 0)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(-5, duration: 0.06)
                CubicKeyframe(5, duration: 0.06)
                CubicKeyframe(-4, duration: 0.06)
                CubicKeyframe(4, duration: 0.06)
                CubicKeyframe(-2, duration: 0.06)
                CubicKeyframe(0, duration: 0.06)
            }
        }
    }
}
