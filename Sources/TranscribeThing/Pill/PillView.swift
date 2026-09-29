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
    /// Past an hour the timer reads "1:02:03", wider than its column: the capsule widens once, keeping its even gaps.
    static let lockedHoursSize = CGSize(width: 2 * (buttonInset + buttonSize) + barFieldWidth + hoursTimerWidth
                                            + 3 * lockedGap,
                                        height: 36)
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
    /// Fits "59:59" in `timerFont`.
    static let timerWidth: CGFloat = 33
    /// Fits "1:02:03" in `timerFont` (measured): the timer's column past an hour.
    static let hoursTimerWidth: CGFloat = 44
    /// "9:59", the timer's width for most recordings.
    static let shortTimerWidth: CGFloat = 26
    /// Hands-free spaces X, the bars, the timer and Stop by one even gap, 15 pt. That holds for a "9:59"
    /// timer, which sits centered in the timer’s column; "59:59" fills the column, taking 3.5 pt from each side.
    static let lockedGap: CGFloat = (lockedSize.width - 2 * (buttonInset + buttonSize) - barFieldWidth - shortTimerWidth) / 3
    /// Space between the timer's column and Stop. Past an hour it is `lockedGap`: the text fills its column.
    static let timerTrailing: CGFloat = lockedGap - (timerWidth - shortTimerWidth) / 2
    /// How far left of the pill's center hands-free draws the bars: one gap right of X, in the capsule of an hour
    /// or more (`hours`) or the usual one.
    static func lockedBarsOffset(hours: Bool) -> CGFloat {
        let width = hours ? lockedHoursSize.width : lockedSize.width
        return buttonInset + buttonSize + lockedGap + barFieldWidth / 2 - width / 2
    }
    static let tooltipHeight: CGFloat = 28
    /// Invisible margin around the pill that counts as hovering it (and clicking it).
    static let hoverMargin: CGFloat = 12
    /// The model chip (and the Switch model hint) floats this far above the pill's top edge.
    static let chipGap: CGFloat = 6
    static let chipHeight: CGFloat = 22
    /// From the pill's top edge to the chip's.
    static let chipLift: CGFloat = chipGap + chipHeight

    static let captionFontSize: CGFloat = 12
    /// Words inside the capsule: the timer's rounded face, a size up so they read at a glance.
    static let captionFont = Font.system(size: captionFontSize, weight: .medium, design: .rounded)
    /// Between a sentence and the capsule's ends: the push-to-talk pill's own margin around its bars, less the
    /// capsule's rounding the text doesn't need.
    static let captionPadding: CGFloat = 15
    /// A dictation with no words says so inside the capsule, in the caption face.
    static let noSpeechText = "No speech detected"

    /// A sentence inside the capsule: the push-to-talk height, just wide enough for `text` and its padding.
    static func captionSize(for text: String) -> CGSize {
        CGSize(width: (textWidth(text, size: captionFontSize, weight: .medium, rounded: true) + 2 * captionPadding)
                .rounded(.up),
               height: listeningSize.height)
    }

    /// The token count's number: the caption's rounded face, semibold, with digits of one width so it never jitters
    /// as it counts.
    static let counterNumberFontSize: CGFloat = 12
    static let counterNumberFont = Font.system(size: counterNumberFontSize, weight: .semibold, design: .rounded)
        .monospacedDigit()
    /// The breathing dot at the counter's start.
    static let counterDotSize: CGFloat = 5
    /// Between the counter and the capsule's ends.
    static let counterPadding: CGFloat = 14
    /// Between the dot and the number at their closest (the widest number), and between the number and its word.
    static let counterDotGap: CGFloat = 6
    static let counterWordGap: CGFloat = 4
    /// The processing pill with its token count: the push-to-talk height, wide enough for "~88.8k thinking", the
    /// widest it says (a request's `max_tokens` keeps counts under 100k). Fixed, so the capsule never resizes as it
    /// counts.
    static let counterSize = CGSize(
        width: (2 * counterPadding + counterDotSize + counterDotGap
                + textWidth("~88.8k", size: counterNumberFontSize, weight: .semibold, rounded: true,
                            monospacedDigits: true)
                + counterWordGap + textWidth("thinking", size: captionFontSize, weight: .medium, rounded: true))
            .rounded(.up),
        height: listeningSize.height)

    /// Width of a single line of `text` in the system font, as SwiftUI's `Font.system` draws it.
    static func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight, rounded: Bool,
                          monospacedDigits: Bool = false) -> CGFloat {
        var font = monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        if rounded, let descriptor = font.fontDescriptor.withDesign(.rounded) {
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        return ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }
}

/// The pill is always dark, in both appearances; these colors never adapt.
enum PillPalette {
    static let fill = Color(nsColor: Palette.pillFill)
    static let bar = Color.white.opacity(0.96)
    static let stop = Color(nsColor: .hex(0xFF453A))
    static let error = Color(nsColor: .hex(0xFF6B5E))
    static let tooltipFill = Color(nsColor: .hex(0x151517, alpha: 0.96))

    /// Color means the model, whichever is main: Gemini violet, and clean-up warm, like its wand in Settings (a pass
    /// over Parakeet's words, set apart from the models that hear the audio). Parakeet keeps the plain pill.
    static func accent(for choice: ModelChoice?) -> PillAccent? {
        switch choice {
        case .cleanup: PillAccent(ringHex: 0xE58A5F, markHex: 0xFFB896)
        case .gemini: PillAccent(ringHex: 0x7F77DD, markHex: 0xAFA9EC)
        case .parakeet, nil: nil
        }
    }
}

/// A model's tint: the capsule's ring, and the bars and processing dots (lighter, so they read on the fill).
struct PillAccent: Equatable, Sendable {
    let ringHex: UInt32
    let markHex: UInt32

    var ring: Color { Color(nsColor: .hex(ringHex)) }
    var mark: Color { Color(nsColor: .hex(markHex)) }
}

extension EnvironmentValues {
    /// Snapshots set this: animations that start on appear render in their settled state instead.
    @Entry var pillStaticRendering = false
}

// MARK: - Visual state

/// What the capsule looks like: the phase plus hover, presentation and the recording timer.
enum PillVisual: Equatable, Sendable {
    case hidden, rest, peek, listening
    /// One-time post-onboarding bloom: listening size, bars ripple once, then rest as dots.
    case hello
    /// `hours`: the recording has run past an hour, and the capsule is wide enough for "1:02:03".
    case locked(hours: Bool = false)
    /// The push-to-talk size: stopping hands-free shrinks the pill. `afterHandsFree` only starts the dots
    /// where the hands-free bars stood, so they glide to the center as the pill narrows instead of hopping.
    /// `counting`: the model's token count in place of the dots, in a capsule wide enough for it. The number itself is
    /// never part of the visual, so a tick never springs the capsule.
    case processing(afterHandsFree: Bool, counting: Bool = false)
    case error
    /// The error flash as a sentence instead of the glyph ("No speech detected"): no red, no shake.
    case message(String)

    enum Content: Hashable { case empty, peek, hello, recording, processing, error, message }

    var size: CGSize {
        switch self {
        case .hidden, .rest: PillMetrics.restSize
        case .peek: PillMetrics.peekSize
        case .processing(_, counting: true): PillMetrics.counterSize
        case .listening, .hello, .processing: PillMetrics.listeningSize
        case .locked(hours: true): PillMetrics.lockedHoursSize
        case .locked: PillMetrics.lockedSize
        case .error: PillMetrics.errorSize
        case .message(let text): PillMetrics.captionSize(for: text)
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
        case .message: .message
        }
    }

    /// Recording and processing show a dictation, so they carry its model (chip and tint); nothing else does.
    var carriesModel: Bool { content == .recording || content == .processing }

    /// Resting shapes cast half the shadow.
    var isQuiet: Bool {
        switch self {
        case .hidden, .rest, .peek: true
        default: false
        }
    }

    /// Only hands-free shows the timer (and X and Stop).
    var isLocked: Bool { if case .locked = self { true } else { false } }

    /// Hands-free past an hour: the wider timer.
    var showsHours: Bool { self == .locked(hours: true) }

    /// Processing with the token count in place of the dots.
    var isCounting: Bool { if case .processing(_, counting: true) = self { true } else { false } }

    /// Horizontal offset of the bars from the pill's center. Hands-free centers them between X and the timer;
    /// processing after it starts its dots where the usual hands-free bars stand, so they don't hop sideways when
    /// Stop is pressed.
    var barsOffset: CGFloat {
        switch self {
        case .locked(let hours): PillMetrics.lockedBarsOffset(hours: hours)
        case .processing(afterHandsFree: true, _): PillMetrics.lockedBarsOffset(hours: false)
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
    /// What is still leaving: the last pill while it exits, the last content while it shrinks into the rest shape.
    @State private var stage = PillStage()
    /// 0 → 1 as the pill leaves (`PillExitEffect`).
    @State private var exitProgress: CGFloat = 0

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
            return .locked(hours: model.showsHours)
        case .processing:
            return .processing(afterHandsFree: model.processingOrigin == .locked, counting: model.showsCounter)
        case .error:
            if let text = model.errorMessage { return .message(text) }
            return .error
        }
    }

    /// The dictation's model the stage keeps with each visual, so its chip and tint leave with the pill.
    private var choice: ModelChoice? { model.sessionModel }

    var body: some View {
        let visual = self.visual
        let shown = visual != .hidden
        let frame = stage.frame(for: visual, choice: choice)
        PillFace(model: model, regions: regions, capsule: frame.capsule, content: frame.content, morph: frame.morph,
                 choice: frame.choice)
            // Capsule and content leave together, as one composited piece.
            .modifier(PillExitEffect(progress: exitProgress, reduceMotion: reduceMotion))
            .scaleEffect(frame.collapsed && !reduceMotion ? 0.6 : 1, anchor: .bottom)
            // Appearing, the fade runs ahead of the spring: a spring starts from rest and would keep the capsule
            // nearly transparent for its first 50 ms. The scale still blooms with the spring.
            .animation(fadeAnimation(shown: shown, to: visual)) { $0.opacity(frame.collapsed ? 0 : 1) }
            .modifier(PillShake(trigger: model.shakeCount, enabled: !reduceMotion))
            .animation(animation(to: visual), value: visual)
            .onChange(of: PillStage.Key(visual: visual, choice: choice), initial: true) { _, new in
                // Its own transaction, so the exit's timing never reaches the capsule's springs (nor the reverse).
                let exit = stage.frame(for: new.visual, choice: new.choice).exit
                let animation = stage.exitAnimation(to: new.visual, reduceMotion: reduceMotion)
                stage.record(new.visual, choice: new.choice)
                if exitProgress != exit { withAnimation(animation) { exitProgress = exit } }
            }
            .task(id: stage.generation) {
                let generation = stage.generation
                try? await Task.sleep(for: .seconds(PillMotion.settleDelay))
                guard !Task.isCancelled else { return }
                // Parking and dropping the shrunk content happen out of sight: nothing may animate.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { stage.settle(generation, visual: self.visual) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel(for: visual))
            .accessibilityHidden(!shown)
    }

    /// Hiding needs none: the exit fades the pill out and parking it collapsed happens out of sight.
    private func fadeAnimation(shown: Bool, to visual: PillVisual) -> Animation? {
        guard shown else { return nil }
        return reduceMotion ? animation(to: visual) : .easeOut(duration: 0.12)
    }

    private func animation(to visual: PillVisual) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        switch visual {
        case .hidden, .rest: return .spring(duration: PillMotion.morphDuration, bounce: 0)
        case .peek: return .spring(duration: 0.22, bounce: 0.15)
        case .hello: return .spring(duration: 0.42, bounce: 0.3)
        case .listening: return .spring(duration: 0.32, bounce: 0.26)
        case .locked: return .spring(duration: 0.34, bounce: 0.3)
        case .processing: return .spring(duration: 0.3, bounce: 0.12)
        case .error: return .spring(duration: 0.3, bounce: 0.2)
        case .message: return .spring(duration: 0.3, bounce: 0.12)
        }
    }

    private func accessibilityLabel(for visual: PillVisual) -> String {
        let label = switch visual {
        case .hidden: "transcribe-thing"
        case .rest, .peek, .hello: "transcribe-thing. Click to start hands-free dictation"
        case .listening: "transcribe-thing is listening"
        case .locked: "transcribe-thing is listening, hands-free"
        case .processing: "transcribe-thing is transcribing"
        case .error: "Dictation failed"
        case .message(let text): text
        }
        guard let choice, visual.carriesModel else { return label }
        return "\(label) with \(choice.title(parakeet: model.settings.parakeetEngine))"
    }
}

// MARK: - Leaving

/// How the pill leaves: it never drops its content first. Hiding, the whole pill (capsule, content, shadows)
/// sinks a little, shrinks toward its bottom edge and fades as one piece; morphing into the resting capsule, the
/// content shrinks and fades with the capsule. Both are pure functions of a progress, so snapshots can render
/// any frame.
enum PillMotion {
    /// The exit runs linearly in time; `exitPose` shapes each property.
    static let exitDuration: TimeInterval = 0.26
    /// Reduce Motion: a plain crossfade of the whole pill.
    static let reducedExitDuration: TimeInterval = 0.15
    /// The spring into the resting capsule (and the entry from it).
    static let morphDuration: TimeInterval = 0.28
    /// After this the hidden pill is parked collapsed and the content left in the resting capsule is dropped:
    /// both are invisible by then (the spring is 99% there at 0.3 s).
    static let settleDelay: TimeInterval = 0.34

    static func exitAnimation(reduceMotion: Bool) -> Animation {
        .linear(duration: reduceMotion ? reducedExitDuration : exitDuration)
    }

    struct ExitPose: Equatable {
        var scale: CGFloat
        /// Downward drift, in points.
        var drop: CGFloat
        var blur: CGFloat
        var opacity: Double
    }

    /// The exiting pill at `progress` (0…1, linear in time): it eases down to 86% toward its bottom edge and
    /// 3 pt lower while the fade, slow to start, takes it away; a last hint of blur softens the final frames.
    static func exitPose(at progress: CGFloat, reduceMotion: Bool) -> ExitPose {
        let p = min(1, max(0, progress))
        let fade = Double(p * p * (3 - 2 * p))
        if reduceMotion { return ExitPose(scale: 1, drop: 0, blur: 0, opacity: 1 - fade) }
        let settle = 1 - pow(1 - p, 3)
        return ExitPose(scale: 1 - 0.14 * settle, drop: 3 * settle, blur: 1.5 * p * p, opacity: 1 - fade)
    }

    struct MorphPose: Equatable {
        /// The capsule at this point of the morph.
        var size: CGSize
        /// The content's scale: it shrinks with the capsule and always fits inside it.
        var scale: CGFloat
        var opacity: Double
    }

    /// Content of a `from`-sized pill while its capsule morphs into a `to`-sized one, at `progress` 0…1 of
    /// the capsule's own spring. The content keeps its proportions inside the capsule and fades over the whole
    /// morph, so it is gone exactly as the capsule reaches rest and never leaves a large capsule empty. Content that
    /// spans the capsule edge to edge (the token count) fades over the first `fadeSpan` of it instead: the capsule's
    /// ends round in faster than it shrinks.
    static func morphPose(at progress: CGFloat, from: CGSize, to: CGSize, fadeSpan: CGFloat = 1) -> MorphPose {
        let p = min(1, max(0, progress))
        let size = CGSize(width: from.width + (to.width - from.width) * p,
                          height: from.height + (to.height - from.height) * p)
        let scale = min(1, size.width / from.width, size.height / from.height)
        let u = Double(min(1, p / max(fadeSpan, 0.01)))
        return MorphPose(size: size, scale: scale, opacity: 1 - u * u * (3 - 2 * u))
    }

    /// The part of the morph the token count fades over: gone by about 60 ms of the spring.
    static let counterFadeSpan: CGFloat = 0.35
}

/// Which pill to draw around a change of visual. The view asks for the frame of each new visual first and
/// records it right after (`onChange`), so the first frame of an exit still knows the pill that was on screen.
struct PillStage: Equatable {
    /// The last visual on screen: an exiting pill keeps drawing it, size and content, until it has faded out.
    private(set) var lastShown: PillVisual = .rest
    /// The last visual with content: the resting capsule shrinks it away while morphing; `nil` once it's gone.
    private(set) var lingering: PillVisual?
    /// The exit is over: hidden, the pill waits collapsed at rest size, so the next appearance blooms as before.
    private(set) var parked = true
    /// Bumped at every change; the view settles `PillMotion.settleDelay` after the last one.
    private(set) var generation = 0
    /// The models of `lastShown`'s and `lingering`'s dictations: an exiting or shrinking pill keeps its chip and
    /// tint.
    private(set) var lastShownChoice: ModelChoice?
    private(set) var lingeringChoice: ModelChoice?

    /// What the view records at every change: the visual, and the model of the dictation it shows.
    struct Key: Equatable {
        var visual: PillVisual
        var choice: ModelChoice?
    }

    struct Frame: Equatable {
        /// Shape, style and size of the capsule.
        var capsule: PillVisual
        /// Whose content to draw: `capsule`'s own, or the content still shrinking into the resting capsule.
        var content: PillVisual
        /// Target of the exit progress (`PillExitEffect`): 1 while hidden.
        var exit: CGFloat
        /// Target of the morph progress: 1 while `content` shrinks into `capsule`.
        var morph: CGFloat
        /// Parked: at rest size, scaled to 0.6 and transparent, ready to bloom.
        var collapsed: Bool
        /// The model of `content`'s dictation (its chip and tint); nil at rest.
        var choice: ModelChoice? = nil
    }

    /// `choice` is the model of the dictation `visual` shows (the model's `sessionModel`).
    func frame(for visual: PillVisual, choice: ModelChoice? = nil) -> Frame {
        let shown = visual != .hidden
        let capsule = shown ? visual : (parked ? .hidden : lastShown)
        let content = capsule.content == .empty ? (lingering ?? capsule) : capsule
        let contentChoice = content != capsule ? lingeringChoice : (shown ? choice : lastShownChoice)
        return Frame(capsule: capsule, content: content, exit: shown ? 0 : 1, morph: content == capsule ? 0 : 1,
                     collapsed: !shown && parked, choice: content.carriesModel ? contentChoice : nil)
    }

    mutating func record(_ visual: PillVisual, choice: ModelChoice? = nil) {
        generation &+= 1
        if visual != .hidden {
            lastShown = visual
            lastShownChoice = choice
            parked = false
        }
        if visual.content != .empty {
            lingering = visual
            lingeringChoice = choice
        }
    }

    /// The last change (`generation`) has played out: an empty capsule drops the content it shrank, a hidden
    /// pill parks. A settle from before a newer change does nothing.
    mutating func settle(_ generation: Int, visual: PillVisual) {
        guard generation == self.generation, visual.content == .empty else { return }
        lingering = nil
        lingeringChoice = nil
        if visual == .hidden {
            parked = true
            lastShownChoice = nil
        }
    }

    /// Animation of the exit progress on the way to `visual`. Back before the exit finished, the pill comes
    /// back at the entry's quick fade; parked, there is nothing to exit or undo: it simply blooms.
    func exitAnimation(to visual: PillVisual, reduceMotion: Bool) -> Animation? {
        if parked { return nil }
        if visual == .hidden { return PillMotion.exitAnimation(reduceMotion: reduceMotion) }
        return reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.12)
    }
}

/// The pill leaving: capsule and content composited, then scaled, dropped, blurred and faded together.
struct PillExitEffect: ViewModifier, Animatable {
    var progress: CGFloat
    var reduceMotion = false

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let pose = PillMotion.exitPose(at: progress, reduceMotion: reduceMotion)
        content
            .compositingGroup()
            .blur(radius: pose.blur)
            .scaleEffect(pose.scale, anchor: .bottom)
            .offset(y: pose.drop)
            .opacity(pose.opacity)
    }
}

/// Content shrinking with its capsule into the resting one; `progress` runs on the capsule's own spring.
private struct PillMorphEffect: ViewModifier, Animatable {
    var progress: CGFloat
    let from: CGSize
    let to: CGSize
    /// The model chip shrinks toward the capsule below it.
    var anchor: UnitPoint = .center
    /// `PillMotion.morphPose`'s: the token count fades early.
    var fadeSpan: CGFloat = 1

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let pose = PillMotion.morphPose(at: progress, from: from, to: to, fadeSpan: fadeSpan)
        content
            .scaleEffect(pose.scale, anchor: anchor)
            .opacity(pose.opacity)
    }
}

// MARK: - Face

/// One frame of the pill: the capsule of `capsule` with the content of `content`, shrunk by `morph` when that
/// is a different visual. `PillView` animates it; film-strip snapshots pin every value, `size` included.
struct PillFace: View {
    let model: PillModel
    var regions: PillHitRegions?
    let capsule: PillVisual
    let content: PillVisual
    var morph: CGFloat = 0
    /// The capsule's size when it isn't `capsule.size` (a snapshot mid-morph).
    var size: CGSize?
    /// The model of `content`'s dictation: the chip above the pill and the tint.
    var choice: ModelChoice?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var carriesModel: Bool { content.carriesModel }

    /// The choice's tint while the content carries one; a capsule shrinking to rest lets its ring go.
    private var accent: PillAccent? { carriesModel ? PillPalette.accent(for: choice) : nil }

    /// What the chip names while it's up (`PillModel.showsChip`): the dictation's model. Content shrinking away
    /// keeps its own choice's chip.
    private var chipChoice: ModelChoice? {
        carriesModel && model.showsChip ? choice : nil
    }

    var body: some View {
        let size = self.size ?? capsule.size
        let accent = self.accent
        // An overlay, so content larger than the capsule (shrinking into it) never sizes the pill.
        PillCapsule(quiet: capsule.isQuiet, glow: capsule == .error ? PillPalette.error : nil,
                    accent: capsule.content == .empty ? nil : accent)
            .frame(width: size.width, height: size.height)
            .overlay { contentView(accent: accent) }
            // Above the pill and part of it: it springs in on a switch, shrinks into the resting capsule with the
            // content and leaves with the pill in one piece.
            .overlay(alignment: .top) {
                if let chipChoice {
                    PillModelChip(model: model, choice: chipChoice, regions: regions,
                                   isInteractive: capsule == content && capsule.isLocked)
                        .modifier(PillMorphEffect(progress: content == capsule ? 0 : morph, from: content.size,
                                                  to: size, anchor: .bottom))
                        .offset(y: -PillMetrics.chipLift)
                        .id(chipChoice)
                        .transition(chipTransition)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.3),
                       value: chipChoice)
            .animation(.easeOut(duration: 0.2), value: accent)
    }

    /// A chip springs up out of the pill and goes quietly.
    private var chipTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.7, anchor: .bottom)).combined(with: .offset(y: 5)),
            removal: .opacity.animation(.easeIn(duration: 0.25)))
    }

    /// Every content keeps its own pill's size, so content shrinking into a smaller capsule stays laid out as
    /// it was and only scales.
    @ViewBuilder
    private func contentView(accent: PillAccent?) -> some View {
        let visual = content
        let morph = PillMorphEffect(progress: content == capsule ? 0 : morph, from: visual.size,
                                    to: size ?? capsule.size,
                                    fadeSpan: visual.isCounting ? PillMotion.counterFadeSpan : 1)
        switch visual.content {
        case .empty:
            Color.clear
                .id(PillVisual.Content.empty)
        case .peek:
            PeekDots()
                .modifier(morph)
                .id(PillVisual.Content.peek)
                .transition(contentTransition())
        case .hello:
            HelloRipple()
                .modifier(morph)
                .id(PillVisual.Content.hello)
                .transition(contentTransition())
        case .recording:
            RecordingContent(model: model, locked: visual.isLocked, hours: visual.showsHours,
                             barsOffset: visual.barsOffset, regions: regions, tint: accent?.mark ?? .white)
                .frame(width: visual.size.width, height: visual.size.height)
                .modifier(morph)
                .id(PillVisual.Content.recording)
                .transition(contentTransition())
        case .processing:
            ProcessingContent(startOffset: visual.barsOffset, tint: accent?.mark ?? .white, accent: accent,
                              count: model.tokenCount, isCounting: visual.isCounting)
                .frame(width: visual.size.width, height: visual.size.height)
                .modifier(morph)
                .id(PillVisual.Content.processing)
                .transition(contentTransition(anchor: visual.barsAnchor))
        case .error:
            ErrorGlyph()
                .modifier(morph)
                .id(PillVisual.Content.error)
                .transition(contentTransition())
        case .message:
            if case .message(let text) = visual {
                PillCaptionText(text: text)
                    .modifier(morph)
                    .id(PillVisual.Content.message)
                    .transition(contentTransition())
            }
        }
    }

    private func contentTransition(anchor: UnitPoint = .center) -> AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.85, anchor: anchor))
                .animation(.easeOut(duration: 0.18).delay(0.06)),
            removal: .opacity.animation(.easeIn(duration: 0.1)))
    }
}

// MARK: - Capsule

/// Near-black capsule with a lit hairline (white 22% → 6%) and a two-layer shadow, so it reads on white
/// documents and on dark desktops alike.
struct PillCapsule: View {
    var quiet = false
    var glow: Color?
    /// The model's ring (`PillPalette.accent`), with a faint halo of its color.
    var accent: PillAccent?

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
            .overlay {
                if let accent {
                    shape.ring(1.25)
                        .fill(LinearGradient(colors: [accent.mark.opacity(0.95), accent.ring.opacity(0.9)],
                                             startPoint: .top, endPoint: .bottom), style: FillStyle(eoFill: true))
                        .shadow(color: accent.ring.opacity(0.55), radius: 4)
                        .transition(.opacity)
                }
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

/// A sentence inside the capsule ("No speech detected"), in the caption face.
private struct PillCaptionText: View {
    var text: String

    var body: some View {
        Text(text)
            .font(PillMetrics.captionFont)
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .fixedSize()
    }
}

/// The processing wave, and once the model has streamed for a moment, its token count: the dots fade out as the
/// capsule widens and the count fades in while the shimmer keeps sweeping. Same content either way, so starting to
/// count never restarts the wave or the shimmer.
private struct ProcessingContent: View {
    var startOffset: CGFloat
    var tint: Color
    var accent: PillAccent?
    /// The model's count right now; nil once the controller has let it go (the pill leaving with its number).
    var count: PillTokenCount?
    var isCounting: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The last count shown, so a pill that leaves or shrinks after its count went keeps its number to the end.
    @State private var lastCount: PillTokenCount?

    var body: some View {
        ZStack {
            ProcessingWaveView(startOffset: startOffset, tint: tint, showsDots: !isCounting)
            if isCounting, let shown = count ?? lastCount {
                PillTokenCounter(count: shown, accent: accent)
                    .transition(counterTransition)
            }
        }
        .onChange(of: count, initial: true) { _, new in
            if let new { lastCount = new }
        }
    }

    /// The count follows the dots out, so the two never overlap at full strength.
    private var counterTransition: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .opacity.combined(with: .scale(scale: 0.96))
            .animation(.easeOut(duration: 0.22).delay(0.08))
    }
}

/// "● ~1.2k thinking": a breathing dot that says the request is alive, then the count and what the model is doing.
/// The word's right edge stays put and the number grows leftward; within a phase its digits roll, and from thinking
/// to writing (which starts again from its first tokens) number and word crossfade instead, so the restart never
/// reads as a countdown.
struct PillTokenCounter: View {
    let count: PillTokenCount
    var accent: PillAccent?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            BreathingDot(color: accent?.mark ?? .white)
            Spacer(minLength: PillMetrics.counterDotGap)
            ZStack(alignment: .trailing) {
                label
                    .id(count.phase)
                    .transition(.opacity.animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.2)))
            }
            .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.2), value: count.phase)
        }
        .padding(.horizontal, PillMetrics.counterPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count.spokenDescription)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var label: some View {
        HStack(spacing: PillMetrics.counterWordGap) {
            Text(count.text)
                .font(PillMetrics.counterNumberFont)
                .foregroundStyle(.white.opacity(0.92))
                .contentTransition(reduceMotion ? .identity : .numericText(value: Double(count.tokens)))
                .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: count.text)
            Text(count.word)
                .font(PillMetrics.captionFont)
                .foregroundStyle(accent?.mark ?? .white.opacity(0.55))
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// The counter's liveness cue: a small dot that breathes between 45% and full, 1.2 s each way. Reduce Motion holds
/// it still at 80%; static snapshots at full.
private struct BreathingDot: View {
    var color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pillStaticRendering) private var isStatic

    var body: some View {
        if isStatic || reduceMotion {
            dot.opacity(isStatic ? 1 : 0.8)
        } else {
            PhaseAnimator([false, true]) { lit in
                dot.opacity(lit ? 1 : 0.45)
            } animation: { _ in
                .easeInOut(duration: 1.2)
            }
        }
    }

    private var dot: some View {
        Circle()
            .fill(color)
            .frame(width: PillMetrics.counterDotSize, height: PillMetrics.counterDotSize)
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
    /// Hands-free: X, the timer and Stop.
    let locked: Bool
    /// Past an hour: the timer's wider column.
    var hours = false
    let barsOffset: CGFloat
    let regions: PillHitRegions?
    var tint: Color = .white

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            WaveformView(meter: model.levelMeter, tint: tint)
                .offset(x: barsOffset)
            // Each piece is inserted on its own so its transition runs (a transition only applies to the
            // outermost view being inserted).
            HStack(spacing: 0) {
                if locked {
                    PillControlButton(control: .cancel, model: model, regions: regions) { model.onCancel?() }
                        .transition(buttonTransition(from: 1, delay: 0))
                }
                Spacer(minLength: 0)
                if locked {
                    PillTimerLabel(model: model)
                        .frame(width: hours ? PillMetrics.hoursTimerWidth : PillMetrics.timerWidth)
                        .padding(.trailing, hours ? PillMetrics.lockedGap : PillMetrics.timerTrailing)
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

/// The dictation's model, floating above the pill for a moment after a switch, by its full name: sparkles and
/// "Gemini 3.8 Flash" in its color; clean-up as the pass it is, "Parakeet → GPT-6 Luna" with Parakeet dimmed ahead of
/// the wand; or a bolt and "Parakeet". In hands-free it stays while the pointer is on it, and opens the model menu
/// (the controller pops it up).
private struct PillModelChip: View {
    let model: PillModel
    let choice: ModelChoice
    let regions: PillHitRegions?
    /// Hands-free only: push-to-talk holds a key, and processing is past choosing.
    let isInteractive: Bool

    var body: some View {
        let accent = PillPalette.accent(for: choice)
        let settings = model.settings
        Button { model.onEngineChipClick?() } label: {
            PillChipCapsule(accent: accent) {
                if choice == .cleanup {
                    Text(ModelChoice.parakeet.chipName)
                        .foregroundStyle(.white.opacity(0.5))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                }
                symbol(accent: accent)
                Text(choice.chipName)
                    .foregroundStyle(.white.opacity(0.92))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .allowsHitTesting(isInteractive)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PillCanvasMetrics.space)) } action: { rect in
            regions?.setChip(isInteractive ? rect : nil)
        }
        .onChange(of: isInteractive) { _, interactive in if !interactive { regions?.setChip(nil) } }
        .onDisappear { regions?.setChip(nil) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Model: \(choice.title(parakeet: settings.parakeetEngine))")
        .accessibilityAddTraits(isInteractive ? .isButton : [])
    }

    private func symbol(accent: PillAccent?) -> some View {
        Image(systemName: choice.symbolName(parakeet: model.settings.parakeetEngine))
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(accent?.mark ?? .white.opacity(0.75))
    }
}

/// The small dark capsule of the model chip and the Switch model hint: the pill's fill, its lit hairline, and the
/// model's ring.
struct PillChipCapsule<Content: View>: View {
    var accent: PillAccent?
    @ViewBuilder var content: Content

    var body: some View {
        let shape = Capsule(style: .continuous)
        HStack(spacing: 4) { content }
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: PillMetrics.chipHeight)
            .background {
                shape.fill(PillPalette.fill)
                    .overlay {
                        shape.ring(0.5)
                            .fill(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.07)],
                                                 startPoint: .top, endPoint: .bottom), style: FillStyle(eoFill: true))
                    }
                    .overlay {
                        if let accent {
                            shape.ring(1)
                                .fill(accent.ring.opacity(0.85), style: FillStyle(eoFill: true))
                        }
                    }
                    .overlay {
                        shape.inset(by: -0.5).ring(0.5)
                            .fill(.white.opacity(0.11), style: FillStyle(eoFill: true))
                    }
                    .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.24), radius: 6, x: 0, y: 3)
            }
            .environment(\.colorScheme, .dark)
    }
}

/// "[fn][tab] · Clean-up, Gemini": the Switch model shortcut, shown faintly above a long push-to-talk hold its first
/// few times. The keys follow the user's binding.
struct PillSwitchHint: View {
    let model: PillModel

    /// What the shortcut steps to (`ModelLineup.steps`): the one model by its full name, several by their short names
    /// in order.
    static func label(for steps: [ModelChoice]) -> String {
        guard steps.count == 1, let step = steps.first else { return steps.map(\.shortName).joined(separator: ", ") }
        return step == .cleanup ? "\(CleanupModel.default.shortName) clean-up" : step.modelName
    }

    private var label: String {
        Self.label(for: model.settings.lineup.steps)
    }

    var body: some View {
        let shortcut = model.settings.shortcuts[.switchModel]
        PillChipCapsule {
            PillShortcutChips(shortcut: shortcut, fallback: shortcut?.compactDescription ?? "")
                .scaleEffect(0.9)
            Text("·").foregroundStyle(.white.opacity(0.35))
            Text(label)
                .foregroundStyle(.white.opacity(0.7))
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Press \(shortcut?.spokenDescription ?? "the Switch model shortcut") to use \(label)")
    }
}

/// Elapsed time: "0:42", "12:05", past an hour "1:02:03".
private struct PillTimerLabel: View {
    let model: PillModel

    var body: some View {
        let start = model.recordingStartedAt ?? Date()
        TimelineView(.periodic(from: start, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(start))
            Text(Fmt.duration(elapsed.rounded(.down)))
                .font(PillMetrics.timerFont)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .contentTransition(.numericText())
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

/// "Cancel [esc]" over X, "Finish [fn]" over Stop: a press of the push-to-talk key finishes hands-free.
private struct PillControlTooltip: View {
    let control: PillControl
    let settings: AppSettings

    var body: some View {
        PillTooltipBubble {
            switch control {
            case .cancel:
                Text("Cancel")
                PillShortcutChips(shortcut: .escape, fallback: "esc")
            case .stop:
                Text("Finish")
                PillShortcutChips(shortcut: settings.shortcuts[.pushToTalk], fallback: "fn")
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
