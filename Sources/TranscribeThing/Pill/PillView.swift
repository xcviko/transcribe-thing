import AppKit
import SwiftUI

// MARK: - Tokens

/// Pill geometry (wispr-ux §1.3–1.4, made smaller after Wispr Flow's). Everything in points.
enum PillMetrics {
    static let restSize = CGSize(width: 36, height: 8)
    static let peekSize = CGSize(width: 64, height: 20)
    static let listeningSize = CGSize(width: barFieldWidth + 2 * listeningPadding, height: 26)
    /// Between the bars and the push-to-talk capsule's ends.
    static let listeningPadding: CGFloat = 14
    /// Hands-free always carries the timer, so hovering never resizes it (nor does the timer reaching 10:00).
    static let lockedSize = CGSize(width: (2 * (buttonInset + buttonSize) + barFieldWidth + shortTimerWidth
                                           + 3 * targetLockedGap).rounded(.up),
                                   height: maxHeight)
    /// Past an hour the timer reads "1:02:03", wider than its column: the capsule widens once, keeping its even gaps.
    static let lockedHoursSize = CGSize(width: 2 * (buttonInset + buttonSize) + barFieldWidth + hoursTimerWidth
                                            + 3 * lockedGap,
                                        height: maxHeight)
    static let errorSize = listeningSize
    /// Tallest state (hands-free); toasts sit 10 pt above it so they never move while the pill changes shape.
    static let maxHeight: CGFloat = 28

    static let barCount = 11
    static let barWidth: CGFloat = 2
    static let barGap: CGFloat = 2
    static let barFieldWidth: CGFloat = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
    static let barMinHeight: CGFloat = 2
    static let barMaxHeight: CGFloat = 14

    static let buttonSize: CGFloat = 18
    static let buttonInset: CGFloat = 5
    static let timerFontSize: CGFloat = 10
    /// Monospaced digits, so the timer never jitters as it counts.
    static let timerFont = Font.system(size: timerFontSize, weight: .medium, design: .rounded).monospacedDigit()
    /// Fits "59:59" in `timerFont`.
    static let timerWidth = timerTextWidth("59:59")
    /// Fits "1:02:03" in `timerFont`: the timer's column past an hour.
    static let hoursTimerWidth = timerTextWidth("1:02:03")
    /// "9:59", the timer's width for most recordings.
    static let shortTimerWidth = timerTextWidth("9:59")
    private static func timerTextWidth(_ text: String) -> CGFloat {
        textWidth(text, size: timerFontSize, weight: .medium, rounded: true, monospacedDigits: true)
    }
    /// About the gap between X, the bars, the timer and the finish button; the capsule rounds its width up to whole
    /// points, and `lockedGap` is what that leaves.
    private static let targetLockedGap: CGFloat = 10
    /// Hands-free spaces X, the bars, the timer and the finish button by one even gap. That holds for a "9:59"
    /// timer, which sits centered in the timer’s column; "59:59" fills the column, taking a little from each side.
    static let lockedGap: CGFloat = (lockedSize.width - 2 * (buttonInset + buttonSize) - barFieldWidth - shortTimerWidth) / 3
    /// Space between the timer's column and Stop. Past an hour it is `lockedGap`: the text fills its column.
    static let timerTrailing: CGFloat = lockedGap - (timerWidth - shortTimerWidth) / 2
    /// How far left of the pill's center hands-free draws the bars: one gap right of X, in the capsule of an hour
    /// or more (`hours`) or the usual one.
    static func lockedBarsOffset(hours: Bool) -> CGFloat {
        let width = hours ? lockedHoursSize.width : lockedSize.width
        return buttonInset + buttonSize + lockedGap + barFieldWidth / 2 - width / 2
    }
    static let tooltipHeight: CGFloat = 24
    /// Invisible margin around the pill that counts as hovering it (and clicking it).
    static let hoverMargin: CGFloat = 12
    /// What the pill's content and chip are laid out on: fixed, and centered on the capsule, so nothing on it moves when
    /// the capsule changes size (`PillFace`). Room for the widest content and the chip above it.
    static let stageSize = CGSize(width: 420, height: 120)
    /// The model chip (and the Switch model hint) floats this far above the pill's top edge.
    static let chipGap: CGFloat = 6
    static let chipHeight: CGFloat = 20
    /// From the pill's top edge to the chip's.
    static let chipLift: CGFloat = chipGap + chipHeight

    static let captionFontSize: CGFloat = 11
    /// Words inside the capsule: the timer's rounded face, a size up so they read at a glance.
    static let captionFont = Font.system(size: captionFontSize, weight: .medium, design: .rounded)
    /// Between a sentence and the capsule's ends: the push-to-talk pill's own margin around its bars, less the
    /// capsule's rounding the text doesn't need.
    static let captionPadding: CGFloat = 12
    /// A dictation with no words says so inside the capsule, in the caption face.
    static let noSpeechText = "No speech detected"
    /// A cloud model heard no speech in a recording that had plenty: the pill wears its ring, and History has the
    /// recording (`AppError.heardNoSpeech`).
    static let keptNoSpeechText = "Heard no speech · Kept in History"

    /// A sentence inside the capsule: the push-to-talk height, just wide enough for `text` and its padding.
    static func captionSize(for text: String) -> CGSize {
        CGSize(width: (textWidth(text, size: captionFontSize, weight: .medium, rounded: true) + 2 * captionPadding)
                .rounded(.up),
               height: listeningSize.height)
    }

    /// The token count's number: the caption's rounded face, semibold, with digits of one width so it never jitters
    /// as it counts.
    static let counterNumberFontSize: CGFloat = 11
    static let counterNumberFont = Font.system(size: counterNumberFontSize, weight: .semibold, design: .rounded)
        .monospacedDigit()
    /// Between the counter and the capsule's ends.
    static let counterPadding: CGFloat = 12
    /// Between the number and its word.
    static let counterWordGap: CGFloat = 4
    /// A polished count starts with the wand, this wide and this far from the number.
    static let counterWandSize: CGFloat = 11
    static let counterWandGap: CGFloat = 5
    /// "~88.8k thinking", the widest the count says (a request's `max_tokens` keeps counts under 100k).
    private static let widestCount = textWidth("~88.8k", size: counterNumberFontSize, weight: .semibold,
                                               rounded: true, monospacedDigits: true)
        + counterWordGap + textWidth("thinking", size: captionFontSize, weight: .medium, rounded: true)
    /// The processing pill with its token count, centered: the push-to-talk height, wide enough for the widest
    /// count. Fixed, so the capsule never resizes as it counts.
    static let counterSize = CGSize(width: (2 * counterPadding + widestCount).rounded(.up), height: listeningSize.height)
    /// The polished count: the wand, then the count.
    static let polishCounterSize = CGSize(
        width: (2 * counterPadding + counterWandSize + counterWandGap + widestCount).rounded(.up),
        height: listeningSize.height)
    /// The count's capsule just around `label`: the padding, the wand for a polish, the text, and Send's plane.
    static func counterSize(for label: PillCountLabel, polishes: Bool, sends: Bool = false) -> CGSize {
        let wand = polishes ? counterWandSize + 2 + counterWandGap : 0
        let plane = sends ? sendCounterRoom : 0
        let text = textWidth(label.number, size: counterNumberFontSize, weight: .semibold, rounded: true,
                             monospacedDigits: true)
            + counterWordGap + textWidth(label.word, size: captionFontSize, weight: .medium, rounded: true)
        return CGSize(width: (2 * counterPadding + wand + text + plane).rounded(.up), height: listeningSize.height)
    }
    /// A polished dictation carries the wand left of its bars (and of its dots once processing): the capsule widens
    /// by this much for it, the wand and its gap.
    static let polishWandRoom = counterWandSize + counterWandGap
    /// A polished push-to-talk dictation, and its processing wave: the push-to-talk pill, wider by the wand.
    static let polishWaveSize = CGSize(width: listeningSize.width + polishWandRoom, height: listeningSize.height)
    /// In a polished dictation the bars (and dots) sit right of where they'd be by this much, leaving the wand its room.
    static let polishDotsShift = polishWandRoom / 2
    /// The wand's center, from the bars' center: left of them by its own half, its gap and theirs.
    static let polishWandOffset = -(counterWandSize / 2 + counterWandGap + barFieldWidth / 2)
    /// A sent dictation carries Send's paper plane right of its bars (and of its dots), as the wand is left of them:
    /// the capsule widens by as much, and the bars sit left of where they'd be by half of it.
    static let sendRoom = polishWandRoom
    /// The plane's center, from the bars' center: the wand's place, mirrored.
    static let sendPlaneOffset = -polishWandOffset
    /// A sent dictation's count ends with the plane: its gap and its frame, as the wand's before a polish's count.
    static let sendCounterRoom = counterWandGap + counterWandSize + 2
    /// What a selection's polish says until the model's count comes.
    static let polishingText = "Polishing"
    /// A selection's polish before its count: the wand and "Polishing", with the counter's padding and nothing more.
    static let polishingSize = labelSize(polishingText)
    /// What a selection's translation says until the model's count comes.
    static let translatingText = "Translating"
    static let translatingSize = labelSize(translatingText)

    private static func labelSize(_ text: String) -> CGSize {
        CGSize(width: (2 * counterPadding + counterWandSize + 2 + counterWandGap
                       + textWidth(text, size: captionFontSize, weight: .medium, rounded: true)).rounded(.up),
               height: listeningSize.height)
    }

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

/// The pill is always black and white, in both appearances; these colors never adapt. The only color on it is the
/// model's ring.
enum PillPalette {
    static let fill = Color(nsColor: Palette.pillFill)
    static let bar = Color.white.opacity(0.96)
    /// The pill's flat edge, and the edge of everything that grows out of it (toasts, chips, tooltips).
    static let hairline = Color.white.opacity(0.17)
    /// Hands-free's finish button: a white disc with a black check.
    static let finish = Color(nsColor: .hex(0xF4F4F2))
    static let tooltipFill = fill

    /// A model color on the pill; graphite is the plain pill. The new colors sit at one depth (OKLCH L 0.645 for the
    /// ring, 0.79 for the marks), so each reads on the fill at least as well as violet does; violet is Gemini's as it
    /// always was, orange the removed clean-up's, and pink the retired Gemini 3.1 Pro's.
    static func accent(for color: ModelColor) -> PillAccent? {
        switch color {
        case .graphite: nil
        case .orange: PillAccent(ringHex: 0xE58A5F, markHex: 0xFFB896)
        case .green: PillAccent(ringHex: 0x57A345, markHex: 0x90CE83)
        case .teal: PillAccent(ringHex: 0x0CA397, markHex: 0x48D3C5)
        case .blue: PillAccent(ringHex: 0x1E95E1, markHex: 0x77C2FE)
        case .violet: PillAccent(ringHex: 0x7F77DD, markHex: 0xAFA9EC)
        case .purple: PillAccent(ringHex: 0xBB68C5, markHex: 0xE39DEB)
        case .pink: PillAccent(ringHex: 0xD4537E, markHex: 0xED93B1)
        }
    }

    /// Color means the model, whichever is main: the one Models gives it (`AppSettings.modelColors`). By default
    /// Gemini violet and Parakeet graphite, the plain pill. nil at rest.
    static func accent(for choice: ModelChoice?, in colors: ModelColors) -> PillAccent? {
        choice.flatMap { accent(for: colors[$0]) }
    }
}

/// A model's tint: the capsule's ring, and `mark`, the lighter one, for marks outside the capsule (the model chip's
/// symbol). Everything inside the capsule stays white.
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

/// What a polish (or translation) is written from: a dictation (its audio, so the processing wave stays) or selected
/// text (nothing was heard, so the pill says "Polishing", or "Translating" for `translatedSelection`).
enum PillPolish: Hashable, Sendable {
    case dictation, selection, translatedSelection

    var isSelection: Bool { self != .dictation }
}

/// What a dictation is rewritten into, shown by one glyph left of its bars or wave: Polish's wand, Translate's glyph,
/// or Translate's with a sparkle for both.
enum PillRewrite: Hashable, Sendable {
    case polish, translate, both

    init?(polishes: Bool, translates: Bool) {
        switch (polishes, translates) {
        case (true, true): self = .both
        case (true, false): self = .polish
        case (false, true): self = .translate
        case (false, false): return nil
        }
    }

    var translates: Bool { self != .polish }
}

extension EnvironmentValues {
    /// The glyph the pill's wand slot shows (`PillWand`).
    @Entry var pillRewrite: PillRewrite = .polish
}

/// What a token count's capsule has to fit: its number with every digit as an 8 ("~8.8k"; digits are all one width)
/// and its word. A count that ticks keeps its label, so the capsule resizes only when the number gains a digit or a
/// decimal point, or the phase changes.
struct PillCountLabel: Hashable, Sendable {
    let number: String
    let word: String

    init(number: String, word: String) {
        self.number = number
        self.word = word
    }

    init(_ count: PillTokenCount) {
        self.init(number: String(count.text.map { $0.isNumber ? "8" : $0 }), word: count.word)
    }
}

/// What the capsule looks like: the phase plus hover, presentation and the recording timer.
enum PillVisual: Equatable, Sendable {
    case hidden, rest, peek
    /// Push-to-talk. `polishes`: Polish is on for the dictation (`PillModel.polishes`), so the wand sits left of the
    /// bars in a capsule wider by it. `sends`: Send is on (`PillModel.sends`), its paper plane right of the bars.
    case listening(polishes: Bool = false, sends: Bool = false)
    /// One-time post-onboarding bloom: listening size, bars ripple once, then rest as dots.
    case hello
    /// `hours`: the recording has run past an hour, and the capsule is wide enough for "1:02:03". `polishes`: the
    /// wand left of the bars, and `sends` the plane right of them, as in push-to-talk.
    case locked(hours: Bool = false, polishes: Bool = false, sends: Bool = false)
    /// The push-to-talk size: stopping hands-free shrinks the pill. `afterHandsFree` only starts the dots
    /// where the hands-free bars stood, so they glide to the center as the pill narrows instead of hopping.
    /// `counting`: the model's token count in place of the dots, in a capsule wide enough for it. The number itself is
    /// never part of the visual, so a tick never springs the capsule. `polish`: a polish is being written, with the
    /// wand before what the pill shows: a dictation's keeps the wave (its audio is being transcribed), a selection's
    /// says "Polishing" (nothing was heard); then both show the count. `label`: what the count's capsule fits, just
    /// around it (none: as wide as the widest count). `sends`: the dictation is sent, the plane right of the wave or
    /// the count.
    case processing(afterHandsFree: Bool, counting: Bool = false, polish: PillPolish? = nil,
                    label: PillCountLabel? = nil, sends: Bool = false)
    case error
    /// The error flash as a sentence instead of the glyph ("No speech detected"): no red, no shake.
    case message(String)

    enum Content: Hashable {
        case empty, peek, hello, recording, processing, error, message

        /// Everything but `.empty`, which draws nothing: one layer each on the pill's stage (`PillFace`).
        static let drawn: [Content] = [.peek, .hello, .recording, .processing, .error, .message]
    }

    var size: CGSize {
        switch self {
        case .hidden, .rest: PillMetrics.restSize
        case .peek: PillMetrics.peekSize
        case .processing(_, counting: true, let polish, label: let label?, let sends):
            PillMetrics.counterSize(for: label, polishes: polish != nil, sends: sends)
        case .processing(_, counting: true, let polish, label: nil, let sends):
            Self.wider(polish == nil ? PillMetrics.counterSize : PillMetrics.polishCounterSize,
                       by: sends ? PillMetrics.sendCounterRoom : 0)
        case .processing(_, counting: false, polish: .selection, _, _): PillMetrics.polishingSize
        case .processing(_, counting: false, polish: .translatedSelection, _, _): PillMetrics.translatingSize
        case .processing(_, counting: false, polish: .dictation, _, let sends):
            Self.wider(PillMetrics.polishWaveSize, by: sends ? PillMetrics.sendRoom : 0)
        case .processing(_, counting: false, polish: nil, _, let sends):
            Self.wider(PillMetrics.listeningSize, by: sends ? PillMetrics.sendRoom : 0)
        case .listening(let polishes, let sends):
            Self.wider(PillMetrics.listeningSize, by: (polishes ? PillMetrics.polishWandRoom : 0)
                                                      + (sends ? PillMetrics.sendRoom : 0))
        case .hello: PillMetrics.listeningSize
        case .locked(let hours, let polishes, let sends):
            CGSize(width: (hours ? PillMetrics.lockedHoursSize : PillMetrics.lockedSize).width
                       + (polishes ? PillMetrics.polishWandRoom : 0) + (sends ? PillMetrics.sendRoom : 0),
                   height: PillMetrics.maxHeight)
        case .error: PillMetrics.errorSize
        case .message(let text): PillMetrics.captionSize(for: text)
        }
    }

    private static func wider(_ size: CGSize, by extra: CGFloat) -> CGSize {
        CGSize(width: size.width + extra, height: size.height)
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

    /// Recording and processing show a dictation, so they carry its model (chip and tint), and so does the sentence
    /// about how it ended ("No speech detected"); nothing else does.
    var carriesModel: Bool { content == .recording || content == .processing || content == .message }

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
    var showsHours: Bool { if case .locked(hours: true, _, _) = self { true } else { false } }

    /// Recording a polished dictation: the wand left of the bars.
    var recordsPolished: Bool {
        switch self {
        case .listening(polishes: true, _), .locked(_, polishes: true, _): true
        default: false
        }
    }

    /// A sent dictation, recording or processing: Send's plane right of the bars, the wave or the count.
    var sends: Bool {
        switch self {
        case .listening(_, let sends), .locked(_, _, let sends), .processing(_, _, _, _, let sends): sends
        default: false
        }
    }

    /// Processing with the token count in place of the dots.
    var isCounting: Bool { if case .processing(_, counting: true, _, _, _) = self { true } else { false } }

    /// Processing a polish: the wand inside the capsule.
    var isPolishing: Bool { polish != nil }

    /// What the polish on screen is written from; nil for anything but a polish.
    var polish: PillPolish? { if case .processing(_, _, let polish, _, _) = self { polish } else { nil } }

    /// Horizontal offset of the bars from the pill's center. Hands-free centers them between X and the timer;
    /// processing after it starts its dots where the usual hands-free bars stand, so they don't hop sideways when
    /// Stop is pressed. A dictation's polish starts them where they settle, right of the wand: gliding from the bars,
    /// they would pass under it. Recording a polished dictation, they sit right of where they'd be, by the wand's half;
    /// a sent one, left of it by the plane's half (both: where they'd be). The plane is right of where they settle, so
    /// they glide from hands-free's bars to it.
    var barsOffset: CGFloat {
        switch self {
        case .listening(let polishes, let sends): Self.badgeShift(polishes: polishes, sends: sends)
        case .locked(let hours, let polishes, let sends):
            PillMetrics.lockedBarsOffset(hours: hours) + Self.badgeShift(polishes: polishes, sends: sends)
        case .processing(_, _, polish: .dictation, _, let sends): Self.badgeShift(polishes: true, sends: sends)
        case .processing(afterHandsFree: true, _, polish: nil, _, let sends):
            PillMetrics.lockedBarsOffset(hours: false) + Self.badgeShift(polishes: false, sends: sends)
        case .processing(afterHandsFree: false, _, polish: nil, _, sends: true):
            Self.badgeShift(polishes: false, sends: true)
        default: 0
        }
    }

    /// Where the processing dots settle, from the capsule's center: right of the wand, left of the plane.
    var dotsShift: CGFloat {
        guard case .processing(_, _, let polish, _, let sends) = self, polish?.isSelection != true else { return 0 }
        return Self.badgeShift(polishes: polish == .dictation, sends: sends)
    }

    /// The bars (or dots) beside the wand and the plane: right by the wand's half, left by the plane's.
    private static func badgeShift(polishes: Bool, sends: Bool) -> CGFloat {
        (polishes ? PillMetrics.polishDotsShift : 0) - (sends ? PillMetrics.sendRoom / 2 : 0)
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
    /// A toast took the resting pill's place (`PillCanvasView`): it steps aside until the toasts go.
    var covered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What is still leaving: the last pill while it exits, the last content while it shrinks into the rest shape.
    @State private var stage = PillStage()
    /// 0 → 1 as the pill leaves (`PillExitEffect`).
    @State private var exitProgress: CGFloat = 0
    /// The glyph in the wand's slot: the last rewrite on screen, kept while a wand leaving after its dictation fades.
    @State private var shownRewrite: PillRewrite = .polish

    init(model: PillModel) {
        self.model = model
    }

    init(model: PillModel, context: Context, covered: Bool = false) {
        self.model = model
        self.context = context
        self.covered = covered
    }

    private var isPanel: Bool { if case .panel = context { true } else { false } }

    private var regions: PillHitRegions? { if case .panel(let r) = context { r } else { nil } }

    var visual: PillVisual {
        let phase = model.visiblePhase
        if isPanel {
            guard model.isPresented, !covered else { return .hidden }
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
            return .listening(polishes: model.rewrite != nil, sends: model.sends)
        case .locked:
            return .locked(hours: model.showsHours, polishes: model.rewrite != nil, sends: model.sends)
        case .processing:
            let selection: PillPolish = model.translates ? .translatedSelection : .selection
            return .processing(afterHandsFree: model.processingOrigin == .locked, counting: model.showsCounter,
                               polish: model.rewrite == nil ? nil : model.selectionPolishing ? selection : .dictation,
                               label: model.showsCounter ? model.tokenCount.map(PillCountLabel.init) : nil,
                               sends: model.sends && !model.selectionPolishing)
        case .error:
            if let text = model.errorMessage { return .message(text) }
            return .error
        }
    }

    /// The dictation's model the stage keeps with each visual, so its chip and tint leave with the pill. The error
    /// flash about a dictation has that dictation's, even with another one still in flight behind it.
    private var choice: ModelChoice? { model.errorModel ?? model.sessionModel }

    var body: some View {
        let visual = self.visual
        let shown = visual != .hidden
        let frame = stage.frame(for: visual, choice: choice)
        // From nowhere (hidden, its exit over or not) the pill is just there, whole, at once, a pill of its own: a key
        // press shows it in the same frame, and nothing of the dictation before (hands-free's X and check still
        // fading, the last model's chip rolling on to this one's) comes with it.
        let appears = stage.showsAfresh(visual)
        let session = stage.session &+ (appears ? 1 : 0)
        // The capsule's size animates as one value, and the whole face is laid out at it in every frame: fill, edge, mask
        // and content can't drift apart. Left to SwiftUI's frame animation, a view that appears mid-change (the model's
        // ring as hands-free starts on another model, the controls) is drawn at the final size from the first frame.
        PillSizing(size: frame.capsule.size) { size in
            PillFace(model: model, regions: regions, capsule: frame.capsule, content: frame.content, morph: frame.morph,
                     size: size, choice: frame.choice, appearsAtOnce: appears)
        }
            .environment(\.pillRewrite, model.rewrite ?? shownRewrite)
            .onChange(of: model.rewrite, initial: true) { _, new in
                if let new { shownRewrite = new }
            }
            .id(session)
            // Capsule and content leave together, as one composited piece.
            .modifier(PillExitEffect(progress: appears ? 0 : exitProgress, reduceMotion: reduceMotion))
            .scaleEffect(frame.collapsed && !reduceMotion ? 0.6 : 1, anchor: .bottom)
            // Back before its exit finished, the pill fades back in quickly.
            .animation(appears ? nil : fadeAnimation(shown: shown, to: visual)) { $0.opacity(frame.collapsed ? 0 : 1) }
            .modifier(PillShake(trigger: model.shakeCount, enabled: !reduceMotion))
            .animation(appears ? nil : animation(to: visual), value: visual)
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
        // A polish or translation (a dictation's or a selection's, all by Gemini) names no model.
        case .processing(_, _, polish: .some, _, _):
            "transcribe-thing is \(model.translates ? "translating" : "polishing")"
        case .processing: "transcribe-thing is transcribing"
        case .error: "Dictation failed"
        case .message(let text): text
        }
        // What the dashed outline says (`PillModel.holdsPaste`).
        let held = visual.content == .processing && model.holdsPaste ? ". The text will wait on a card" : ""
        guard let choice, visual.carriesModel, !visual.isPolishing else { return label + held }
        return "\(label) with \(choice.title)\(held)"
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

    /// Content giving way to the next (hands-free's controls and bars to the processing dots, say): the old one fades
    /// out over this long, and the new one starts coming in after this delay, when the old is nearly gone.
    static let contentLeaving: TimeInterval = 0.1
    static let contentEntering: TimeInterval = 0.08
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
    /// The last visual recorded was hidden (exiting, or parked once the exit is over).
    private(set) var hidden = true
    /// Bumped each time the pill shows after being hidden: each showing is a pill of its own, nothing of the one
    /// before carried into it (`PillView` gives the face this identity).
    private(set) var session = 0
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

    /// The pill shows after being hidden, whether its exit had played out or not: it starts afresh, at once, with
    /// nothing of the dictation before (its controls, its chip, its content shrinking away).
    func showsAfresh(_ visual: PillVisual) -> Bool { visual != .hidden && hidden }

    /// `choice` is the model of the dictation `visual` shows (the model's `sessionModel`).
    func frame(for visual: PillVisual, choice: ModelChoice? = nil) -> Frame {
        let shown = visual != .hidden
        let capsule = shown ? visual : (parked ? .hidden : lastShown)
        let content = capsule.content == .empty && !showsAfresh(visual) ? (lingering ?? capsule) : capsule
        let contentChoice = content != capsule ? lingeringChoice : (shown ? choice : lastShownChoice)
        return Frame(capsule: capsule, content: content, exit: shown ? 0 : 1, morph: content == capsule ? 0 : 1,
                     collapsed: !shown && parked, choice: content.carriesModel ? contentChoice : nil)
    }

    mutating func record(_ visual: PillVisual, choice: ModelChoice? = nil) {
        generation &+= 1
        if showsAfresh(visual) {
            session &+= 1
            lingering = nil
            lingeringChoice = nil
        }
        hidden = visual == .hidden
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

    /// Animation of the exit progress on the way to `visual`. Showing after being hidden (`showsAfresh`), even mid
    /// exit, it's there at once; parked, there is nothing to exit or undo.
    func exitAnimation(to visual: PillVisual, reduceMotion: Bool) -> Animation? {
        if parked || showsAfresh(visual) { return nil }
        if visual == .hidden { return PillMotion.exitAnimation(reduceMotion: reduceMotion) }
        return reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.12)
    }
}

/// The capsule's size, animated as one value: `content` is laid out at it in every frame of a change.
struct PillSizing<Content: View>: View, Animatable {
    var size: CGSize
    @ViewBuilder var content: (CGSize) -> Content

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(size.width, size.height) }
        set { size = CGSize(width: newValue.first, height: newValue.second) }
    }

    var body: some View { content(size) }
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

/// Content that isn't its capsule's own (shrinking into the resting capsule, or on its way out): laid out at its own
/// pill's size and scaled to fit the capsule as it stands in this frame, so it never reaches past the capsule's ends.
/// The morph into the resting capsule fades it as it shrinks; `progress` runs on the capsule's own spring
/// (`PillMotion.morphPose`), and `capsule` is the size that spring has reached, so the two never drift apart.
private struct PillContentFit: ViewModifier, Animatable {
    var progress: CGFloat
    /// The content's own pill.
    let own: CGSize
    /// The capsule in this frame.
    let capsule: CGSize
    /// Content in its own capsule is laid out on it and never scales.
    var fits = true
    /// The model chip shrinks toward the capsule below it.
    var anchor: UnitPoint = .center
    /// `PillMotion.morphPose`'s: the token count fades early.
    var fadeSpan: CGFloat = 1

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let scale = fits ? min(1, capsule.width / max(own.width, 1), capsule.height / max(own.height, 1)) : 1
        let pose = PillMotion.morphPose(at: progress, from: own, to: own, fadeSpan: fadeSpan)
        content
            .scaleEffect(max(scale, 0.01), anchor: anchor)
            .opacity(pose.opacity)
    }
}

// MARK: - Staying live while leaving

/// Draws `content` for `value`, and once `value` goes nil goes on drawing it, live, while it fades out (`leaving` is
/// true), then drops it out of sight.
///
/// A view taken out of the tree is no longer laid out: through its removal transition it stays frozen at its last
/// frame, placed relative to an ancestor that may itself be moving or resizing. That froze a fading "No speech
/// detected" against the left of a narrowing pill (it slid right and was cut on one side), left a hint behind as the
/// pill widened under it, and kept a closing toast whole over the pill that took its place. So nothing that can still
/// be seen leaves through a removal here: what goes stays laid out (it follows the pill, fits it, takes the current
/// environment) until it's invisible, and only then is it removed, with nothing left to animate.
struct PillLingering<Value: Equatable, Content: View>: View {
    var value: Value?
    /// How it comes in. A transition only runs on the outermost view inserted, so it's applied here.
    var insertion: AnyTransition = .identity
    /// How it fades out; nil: at once.
    var fadeOut: Animation?
    /// How it comes back while it's still fading out; nil: at once.
    var fadeIn: Animation?
    /// How long it's kept once it starts leaving: longer than `fadeOut`, so it's dropped out of sight.
    var hold: TimeInterval = 0.4
    @ViewBuilder var content: (_ value: Value, _ leaving: Bool) -> Content

    @State private var last: Value?

    var body: some View {
        let leaving = value == nil
        // A container that's always there, so its handlers run with nothing inside it.
        ZStack {
            if let shown = value ?? last {
                content(shown, leaving)
                    .animation(leaving ? fadeOut : fadeIn) { $0.opacity(leaving ? 0 : 1) }
                    .allowsHitTesting(!leaving)
                    .accessibilityHidden(leaving)
                    .transition(.asymmetric(insertion: insertion, removal: .identity))
            }
        }
        .onChange(of: value, initial: true) { _, new in
            if let new { last = new }
        }
        .task(id: leaving) {
            guard leaving, last != nil else { return }
            try? await Task.sleep(for: .seconds(hold))
            guard !Task.isCancelled else { return }
            // Out of sight by now: nothing may animate.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { last = nil }
        }
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
    /// The pill shows from nowhere: its content is there at once too, nothing fades or grows in.
    var appearsAtOnce = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var carriesModel: Bool { content.carriesModel }

    /// The choice's tint (its color in Models) while the content carries one; a capsule shrinking to rest lets its
    /// ring go. A color picked mid-dictation fades in.
    private var accent: PillAccent? {
        carriesModel ? PillPalette.accent(for: choice, in: model.settings.modelColors) : nil
    }

    /// What the chip names while it's up (`PillModel.showsChip`): the dictation's model. Content shrinking away
    /// keeps its own choice's chip.
    private var chipChoice: ModelChoice? {
        carriesModel && model.showsChip && model.keyHint == nil ? choice : nil
    }

    /// What the content's layer draws: `content`, laid out on the capsule when it's the capsule's own, shrinking into
    /// it (by `morph`) when it isn't.
    private var contentLayer: PillContentLayer {
        PillContentLayer(visual: content, inOwnCapsule: content == capsule, morph: content == capsule ? 0 : morph)
    }

    /// The chip over the pill while it's up, with what it needs to shrink with its content.
    private var chipLayer: PillChipLayer? {
        chipChoice.map {
            PillChipLayer(choice: $0, isInteractive: capsule == content && capsule.isLocked, contentSize: content.size,
                          shrinks: content != capsule, morph: content == capsule ? 0 : morph)
        }
    }

    var body: some View {
        let size = self.size ?? capsule.size
        let accent = self.accent
        // An overlay, so content larger than the capsule (shrinking into it) never sizes the pill.
        PillCapsule(quiet: capsule.isQuiet, drawsEdge: false)
            .frame(width: size.width, height: size.height)
            // Content and chip stand on a stage of fixed size centered on the capsule, never on the capsule's own
            // frame, so nothing on it moves when the capsule changes size.
            .overlay {
                contentLayers(capsule: size)
                    .frame(width: PillMetrics.stageSize.width, height: PillMetrics.stageSize.height)
                    // Inside the capsule, whatever happens: nothing of the content is ever drawn past its ends.
                    .mask { PillContentMask().frame(width: size.width, height: size.height) }
            }
            .overlay {
                // A click away holds the dictation's text (`PillModel.holdsPaste`): its edge is dashed.
                PillCapsuleEdge(accent: capsule.content == .empty ? nil : accent,
                                dashed: capsule.content == .processing && model.holdsPaste)
            }
            // Above the pill and part of it: it springs in on a switch, shrinks into the resting capsule with the
            // content and leaves with the pill in one piece. When it goes by itself (its hold over, the content no
            // longer a dictation's), it stays live while it fades, riding the capsule's top.
            .overlay {
                PillLingering(value: chipLayer, insertion: chipInsertion,
                              fadeOut: reduceMotion ? .easeInOut(duration: 0.15) : .easeIn(duration: 0.25),
                              fadeIn: reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.2)) { chip, leaving in
                    // One chip for the whole cycle: a switch rolls its names on (`PillModelChip`).
                    PillModelChip(model: model, choice: chip.choice, regions: regions,
                                  isInteractive: chip.isInteractive && !leaving)
                        .modifier(PillContentFit(progress: chip.morph, own: chip.contentSize, capsule: size,
                                                 fits: chip.shrinks, anchor: .bottom))
                        .offset(y: -(size.height / 2 + PillMetrics.chipGap + PillMetrics.chipHeight / 2))
                }
                .frame(width: PillMetrics.stageSize.width, height: PillMetrics.stageSize.height)
            }
    }

    /// A chip springs up out of the pill.
    private var chipInsertion: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .opacity.combined(with: .scale(scale: 0.7, anchor: .bottom)).combined(with: .offset(y: 5))
            .animation(.spring(duration: 0.3, bounce: 0.3))
    }

    /// One layer per kind of content, each lingering live while it leaves (`PillLingering`): one content gives way to
    /// the next without the two piling up. The old one fades out in a tenth of a second, still laid out and fitted to
    /// the capsule as it changes; the new one comes in once the old is nearly gone. A content coming back while it's
    /// still fading out (an error flash and fn again within its hold) is the same view, and fades back in.
    private func contentLayers(capsule size: CGSize) -> some View {
        ZStack {
            ForEach(PillVisual.Content.drawn, id: \.self) { kind in
                PillLingering(value: content.content == kind ? contentLayer : nil,
                              insertion: contentInsertion(anchor: kind == .processing ? content.barsAnchor : .center),
                              fadeOut: reduceMotion ? .easeInOut(duration: 0.15)
                                  : .easeOut(duration: PillMotion.contentLeaving),
                              fadeIn: appearsAtOnce ? nil : (reduceMotion ? .easeInOut(duration: 0.15)
                                  : .easeOut(duration: 0.18).delay(PillMotion.contentEntering))) { layer, leaving in
                    contentView(layer, leaving: leaving, capsule: size)
                }
            }
        }
    }

    /// Content in its own capsule is laid out on the capsule's frame, so it moves with the capsule's one spring
    /// (hands-free's X and check ride its ends as it widens). Leaving for another dictation's content, it keeps its own
    /// pill's layout where it stands, centered, and the capsule's ends close over it as it fades (hands-free's X, timer
    /// and check as it stops, "No speech detected" as fn is pressed again). Shrinking into the resting capsule, it
    /// keeps its own pill's size and only scales, to fit inside the capsule in every frame.
    @ViewBuilder
    private func contentView(_ layer: PillContentLayer, leaving: Bool, capsule size: CGSize) -> some View {
        let visual = layer.visual
        let onCapsule = layer.inOwnCapsule && !leaving
        let frame = onCapsule ? size : visual.size
        let fit = PillContentFit(progress: layer.morph, own: visual.size, capsule: size, fits: !layer.inOwnCapsule,
                                 fadeSpan: visual.isCounting ? PillMotion.counterFadeSpan : 1)
        switch visual.content {
        case .empty:
            EmptyView()
        case .peek:
            PeekDots()
                .modifier(fit)
        case .hello:
            HelloRipple()
                .modifier(fit)
        case .recording:
            RecordingContent(model: model, locked: visual.isLocked, hours: visual.showsHours,
                             polishes: visual.recordsPolished, sends: visual.sends, barsOffset: visual.barsOffset,
                             regions: regions, isLive: !leaving)
                .frame(width: frame.width, height: frame.height)
                .modifier(fit)
        case .processing:
            ProcessingContent(startOffset: visual.barsOffset, dotsShift: visual.dotsShift, tint: .white,
                              count: model.tokenCount, isCounting: visual.isCounting, polish: visual.polish,
                              sends: visual.sends)
                .frame(width: frame.width, height: frame.height)
                .modifier(fit)
        case .error:
            ErrorGlyph()
                .modifier(fit)
        case .message:
            if case .message(let text) = visual {
                PillCaptionText(text: text)
                    .modifier(fit)
            }
        }
    }

    private func contentInsertion(anchor: UnitPoint = .center) -> AnyTransition {
        if appearsAtOnce { return .identity }
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .opacity.combined(with: .scale(scale: 0.85, anchor: anchor))
            .animation(.easeOut(duration: 0.18).delay(PillMotion.contentEntering))
    }
}

/// One content on the pill's stage (`PillFace`): the visual whose content it draws, whether that's the capsule's own,
/// and the morph shrinking it into the capsule when it isn't. Kept as it was while the content leaves.
struct PillContentLayer: Equatable {
    var visual: PillVisual
    var inOwnCapsule: Bool
    var morph: CGFloat
}

/// The model chip above the pill (`PillFace`): its model, whether it opens the model menu, and the content it shrinks
/// with into the resting capsule. Kept as it was while the chip fades out.
struct PillChipLayer: Equatable {
    var choice: ModelChoice
    var isInteractive: Bool
    var contentSize: CGSize
    var shrinks: Bool
    var morph: CGFloat
}

// MARK: - Capsule

/// Black capsule with a flat hairline and a soft shadow, so it reads on white documents and on dark desktops alike.
/// `drawsEdge: false` leaves the hairline to a `PillCapsuleEdge` drawn over the content.
struct PillCapsule: View {
    var quiet = false
    /// The model's ring (`PillPalette.accent`) in place of the hairline.
    var accent: PillAccent?
    var drawsEdge = true

    var body: some View {
        Capsule(style: .continuous)
            .fill(PillPalette.fill)
            .overlay { if drawsEdge { PillCapsuleEdge(accent: accent) } }
            .shadow(color: .black.opacity(quiet ? 0.12 : 0.22), radius: quiet ? 3 : 6, x: 0, y: quiet ? 1 : 3)
    }
}

/// The capsule's hairline, or the model's ring in its place: one ring whose color changes, never a ring that comes or
/// goes. A ring on its way out is no longer laid out, so it stayed the old size while the capsule changed under it (a
/// colored "No speech detected" ring around a narrowing Parakeet pill).
///
/// Only the color fades (a color picked mid-dictation, the next dictation's model): the animation is scoped to it. On
/// the whole face, it also animated whatever changed with the color, so a pill appearing on a colored model grew out
/// of its top-left corner instead of being there at once.
struct PillCapsuleEdge: View {
    var accent: PillAccent?
    /// The same ring in dashes: the dictation on the pill won't be pasted (`PillModel.holdsPaste`).
    var dashed = false

    var body: some View {
        PillEdgeShape(dashed: dashed)
            .fill(.foreground, style: FillStyle(eoFill: !dashed))
            .animation(.easeOut(duration: 0.2)) { $0.foregroundStyle(accent?.ring ?? PillPalette.hairline) }
            .allowsHitTesting(false)
    }
}

/// The capsule's 1 pt edge: the ring inside its outline (`RingShape`), or that ring as dashes. The dashes are a stroke
/// along the ring's middle turned into a shape to fill, as the ring is (a stroked capsule drew stray lines at its flat
/// ends in snapshots), stretched a little so a whole number of them goes around and no short one is left at the seam.
struct PillEdgeShape: Shape {
    var dashed = false

    /// About how long a dash is, and the gap after it.
    static let dash: CGFloat = 4
    static let gap: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        let ring = Capsule(style: .continuous).ring(1).path(in: rect)
        guard dashed else { return ring }
        let middle = Capsule(style: .continuous).inset(by: 0.5).path(in: rect)
        let period = Self.dash + Self.gap
        let length = middle.length
        guard length > period else { return ring }
        let scale = length / ((length / period).rounded() * period)
        return middle.strokedPath(StrokeStyle(lineWidth: 1, lineCap: .butt,
                                              dash: [Self.dash * scale, Self.gap * scale]))
    }
}

private extension Path {
    /// How long the path is, its curves measured as many short lines.
    var length: CGFloat {
        var total: CGFloat = 0
        var start = CGPoint.zero, current = CGPoint.zero
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
        func addCurve(_ point: (CGFloat) -> CGPoint) {
            var last = current
            for step in 1...24 {
                let next = point(CGFloat(step) / 24)
                total += distance(last, next)
                last = next
            }
        }
        forEach { element in
            switch element {
            case .move(let to):
                start = to
                current = to
            case .line(let to):
                total += distance(current, to)
                current = to
            case .quadCurve(let to, let control):
                let from = current
                addCurve { t in
                    let u = 1 - t
                    return CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                                   y: u * u * from.y + 2 * u * t * control.y + t * t * to.y)
                }
                current = to
            case .curve(let to, let control1, let control2):
                let from = current
                addCurve { t in
                    let u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    return CGPoint(x: a * from.x + b * control1.x + c * control2.x + d * to.x,
                                   y: a * from.y + b * control1.y + c * control2.y + d * to.y)
                }
                current = to
            case .closeSubpath:
                total += distance(current, start)
                current = start
            }
        }
        return total
    }
}

/// What the pill's content may draw on: the capsule inside its edge, and everything above its top edge (a control's
/// tooltip). Inside the edge, not the capsule's outline: letters cut at the outline showed through the 1 pt ring.
struct PillContentMask: View {
    var body: some View {
        Capsule(style: .continuous).inset(by: 1)
            .overlay(alignment: .top) {
                Rectangle()
                    .frame(width: 8000, height: 4000)
                    .offset(y: -4000)
            }
    }
}


// MARK: - Contents

/// Hover peek: nine quiet dots that fade in left to right.
private struct PeekDots: View {
    @Environment(\.pillStaticRendering) private var isStatic
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<9, id: \.self) { i in
                Circle()
                    .fill(.white.opacity(0.35))
                    .frame(width: 2.5, height: 2.5)
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

    /// Center weighting: env(i) = 0.35 + 0.65 · cos²(π(i − middle)/(count + 1)).
    private static func envelope(_ i: Int) -> CGFloat {
        let c = cos(Double.pi * Double(i - PillMetrics.barCount / 2) / Double(PillMetrics.barCount + 1))
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
/// count never restarts the wave or the shimmer. A polish puts the wand first, under a shimmer in the ring's color: a
/// dictation's beside the wave, a selection's beside "Polishing" (no audio, so no wave). Everything inside the capsule
/// is white: the model's color is its ring's alone. A sent dictation has Send's plane right of the wave, then of the
/// count.
private struct ProcessingContent: View {
    var startOffset: CGFloat
    /// Where the dots settle (`PillVisual.dotsShift`): beside the wand and the plane.
    var dotsShift: CGFloat = 0
    var tint: Color
    /// The model's count right now; nil once the controller has let it go (the pill leaving with its number).
    var count: PillTokenCount?
    var isCounting: Bool
    var polish: PillPolish?
    var sends = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pillStaticRendering) private var staticRendering
    /// The last count shown, so a pill that leaves or shrinks after its count went keeps its number to the end.
    @State private var lastCount: PillTokenCount?

    var body: some View {
        ZStack {
            ProcessingWaveView(startOffset: startOffset, tint: tint, showsDots: !isCounting && polish?.isSelection != true,
                               glow: polish == nil ? nil : tint, dotsShift: dotsShift)
            // Live while it fades, where it stood: through a removal it would freeze against the capsule's left end
            // as the capsule widens into the count, beside the count's own wand.
            PillLingering(value: isCounting ? nil : polish, insertion: counterTransition,
                          fadeOut: reduceMotion ? .easeInOut(duration: 0.15)
                              : .easeOut(duration: PillMotion.contentLeaving),
                          fadeIn: reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.18)) { polish, _ in
                switch polish {
                case .dictation:
                    // Left of the dots: the wand, its gap and the dots centered together in the capsule.
                    PillWand(tint: tint, pulses: reduceMotion && !staticRendering)
                        .offset(x: dotsShift + PillMetrics.polishWandOffset)
                case .selection, .translatedSelection:
                    PillPolishingLabel(text: polish == .selection ? PillMetrics.polishingText : PillMetrics.translatingText,
                                       pulses: reduceMotion && !staticRendering)
                }
            }
            // Right of the dots, as the wand is left of them; the count takes it along.
            PillLingering(value: isCounting || !sends ? nil : true, insertion: counterTransition,
                          fadeOut: reduceMotion ? .easeInOut(duration: 0.15)
                              : .easeOut(duration: PillMotion.contentLeaving),
                          fadeIn: reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.18)) { _, _ in
                PillSendPlane(tint: tint)
                    .offset(x: dotsShift + PillMetrics.sendPlaneOffset)
            }
            if isCounting, let shown = count ?? lastCount {
                PillTokenCounter(count: shown, polishes: polish != nil, sends: sends)
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

/// A selection's polish before its count: the wand and "Polishing" (Translate's glyph and "Translating"), the capsule
/// just around them.
private struct PillPolishingLabel: View {
    var text: String
    var pulses = false

    var body: some View {
        HStack(spacing: PillMetrics.counterWandGap) {
            PillWand(tint: .white, pulses: pulses)
            Text(text)
                .font(PillMetrics.captionFont)
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize()
        }
        .accessibilityHidden(true)
    }
}

/// Polish's wand inside the capsule, or Translate's glyph (`pillRewrite`). `pulses`: Reduce Motion, where the shimmer
/// over it stops, so it breathes once a second instead, as the processing dots do.
private struct PillWand: View {
    var tint: Color
    var pulses = false
    @Environment(\.pillRewrite) private var rewrite

    var body: some View {
        if pulses {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let dim = Int(context.date.timeIntervalSinceReferenceDate) % 2 == 1
                wand.opacity(dim ? 0.5 : 1)
                    .animation(.easeInOut(duration: 0.9), value: dim)
            }
        } else {
            wand
        }
    }

    private var wand: some View {
        Image(systemName: rewrite.translates ? "translate" : "wand.and.sparkles")
            .font(.system(size: PillMetrics.counterWandSize - (rewrite.translates ? 2.5 : 0), weight: .semibold))
            .foregroundStyle(tint)
            .overlay(alignment: .topTrailing) {
                // Polish and Translate both on: Translate's glyph with Polish's sparkle.
                if rewrite == .both {
                    Image(systemName: "sparkle")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(tint)
                        .offset(x: 3.5, y: -3.5)
                }
            }
            .frame(width: PillMetrics.counterWandSize + 2)
            .accessibilityHidden(true)
    }
}

/// Send's paper plane inside the capsule: right of the bars, the wave or the count, as the wand is left of them.
private struct PillSendPlane: View {
    var tint: Color

    var body: some View {
        Image(systemName: "paperplane.fill")
            .font(.system(size: PillMetrics.counterWandSize - 1.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: PillMetrics.counterWandSize + 2)
            .accessibilityHidden(true)
    }
}

/// "~1.2k thinking", centered in the capsule: the count and what the model is doing; a polish puts the wand before
/// it, Send the plane after it. Within a phase the digits roll, and from thinking to writing (which starts again from
/// its first tokens) number and word crossfade instead, so the restart never reads as a countdown.
struct PillTokenCounter: View {
    let count: PillTokenCount
    var polishes = false
    var sends = false
    @Environment(\.pillRewrite) private var rewrite

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: PillMetrics.counterWandGap) {
            if polishes { PillWand(tint: .white) }
            label
                .id(count.phase)
                .transition(.opacity.animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.2)))
            if sends { PillSendPlane(tint: .white) }
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.2), value: count.phase)
        .padding(.horizontal, PillMetrics.counterPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(polishes ? "\(rewrite.translates ? "Translating" : "Polishing"), \(count.spokenDescription)"
                                : count.spokenDescription)
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
                .foregroundStyle(.white.opacity(0.55))
        }
        .lineLimit(1)
        .fixedSize()
    }
}

private struct ErrorGlyph: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.16))
                .frame(width: 17, height: 17)
            Image(systemName: "exclamationmark")
                .font(.system(size: 9.5, weight: .heavy))
                .foregroundStyle(.white)
        }
    }
}

/// Bars while recording; in hands-free, X and the check ride the capsule's ends as it widens and the timer sits left
/// of the check, all four evenly spaced (`PillMetrics.lockedGap`). A polished dictation has Polish's wand just left of
/// the bars, in a capsule wider by it; a sent one, Send's plane just right of them.
private struct RecordingContent: View {
    let model: PillModel
    /// Hands-free: X, the timer and Stop.
    let locked: Bool
    /// Past an hour: the timer's wider column.
    var hours = false
    /// Polish is on: the wand left of the bars.
    var polishes = false
    /// Send is on: the plane right of the bars.
    var sends = false
    let barsOffset: CGFloat
    let regions: PillHitRegions?
    /// Still the pill's content: once it's leaving, X and the check take no clicks, report no regions and show no
    /// tooltips.
    var isLive = true
    var tint: Color = .white

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            WaveformView(meter: model.levelMeter, tint: tint)
                .offset(x: barsOffset)
            // Live while it fades, beside the bars as they slide back: removed, it would freeze where it stood. Moved
            // into place outside its transition, so it grows where it stands, not from the pill's center.
            PillLingering(value: polishes ? true : nil, insertion: wandTransition,
                          fadeOut: .easeOut(duration: reduceMotion ? 0.15 : 0.12),
                          fadeIn: .easeOut(duration: 0.14)) { _, _ in
                PillWand(tint: tint)
            }
            .offset(x: barsOffset + PillMetrics.polishWandOffset)
            PillLingering(value: sends ? true : nil, insertion: wandTransition,
                          fadeOut: .easeOut(duration: reduceMotion ? 0.15 : 0.12),
                          fadeIn: .easeOut(duration: 0.14)) { _, _ in
                PillSendPlane(tint: tint)
            }
            .offset(x: barsOffset + PillMetrics.sendPlaneOffset)
            // Each piece is inserted on its own so its transition runs (a transition only applies to the
            // outermost view being inserted).
            HStack(spacing: 0) {
                if locked {
                    PillControlButton(control: .cancel, model: model, regions: regions, isLive: isLive) {
                        model.onCancel?()
                    }
                        .transition(controlTransition)
                }
                Spacer(minLength: 0)
                if locked {
                    PillTimerLabel(model: model)
                        .frame(width: hours ? PillMetrics.hoursTimerWidth : PillMetrics.timerWidth)
                        .padding(.trailing, hours ? PillMetrics.lockedGap : PillMetrics.timerTrailing)
                        .transition(timerTransition)
                }
                if locked {
                    PillControlButton(control: .stop, model: model, regions: regions, isLive: isLive) {
                        model.onStop?()
                    }
                        .transition(controlTransition)
                }
            }
            .padding(.horizontal, PillMetrics.buttonInset)
        }
    }

    /// The controls only fade: where they are comes from the capsule, so they never lag its ends.
    private var controlTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.14)),
                           removal: .opacity.animation(.easeOut(duration: PillMotion.contentLeaving)))
    }

    /// The wand comes in as the capsule widens for it, a little after it starts, so it never shows over the bars still
    /// sliding aside.
    private var wandTransition: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .opacity.combined(with: .scale(scale: 0.6))
            .animation(.spring(duration: 0.3, bounce: 0.35).delay(0.08))
    }

    /// The timer sits near the middle, where the bars still are while the capsule widens: it comes in once there's
    /// room for it.
    private var timerTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.14).delay(0.1)),
                           removal: .opacity.animation(.easeOut(duration: PillMotion.contentLeaving)))
    }
}

/// X (cancel) and the white finish check of the hands-free pill. Hover comes from the controller, which tracks the
/// pointer for the never-key panel.
private struct PillControlButton: View {
    let control: PillControl
    let model: PillModel
    let regions: PillHitRegions?
    /// Its content is leaving the pill: no region, no hover, no tooltip.
    var isLive = true
    let action: () -> Void

    /// Where it is on the canvas, as last laid out.
    @State private var frame: CGRect?

    private var hovered: Bool { isLive && model.hoveredControl == control }
    private var showsTooltip: Bool { isLive && model.controlTooltip == control }

    var body: some View {
        Button(action: action) {
            ZStack {
                switch control {
                case .cancel:
                    Circle().fill(.white.opacity(hovered ? 0.34 : 0.24))
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white)
                case .stop:
                    Circle().fill(PillPalette.finish)
                        .brightness(hovered ? 0.04 : 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.black)
                }
            }
            .frame(width: PillMetrics.buttonSize, height: PillMetrics.buttonSize)
            .scaleEffect(hovered && control == .stop ? 1.06 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .overlay(alignment: .top) {
            // Live while it fades, so it follows the button as the capsule changes under it.
            PillLingering(value: showsTooltip ? control : nil,
                          insertion: .opacity.combined(with: .offset(y: 3)).animation(.easeOut(duration: 0.14)),
                          fadeOut: .easeOut(duration: 0.14), fadeIn: .easeOut(duration: 0.14)) { control, _ in
                PillControlTooltip(control: control, settings: model.settings)
                    .fixedSize()
                    .offset(y: -(PillMetrics.tooltipHeight + PillMetrics.buttonInset + 8))
                    .allowsHitTesting(false)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PillCanvasMetrics.space)) } action: { rect in
            frame = rect
            regions?.setControl(control, rect: isLive ? rect : nil)
        }
        // Leaving (hands-free stopped), the button no longer counts as one at once, not when it's finally removed.
        .onChange(of: isLive) { _, live in regions?.setControl(control, rect: live ? frame : nil) }
        .onDisappear { regions?.setControl(control, rect: nil) }
        .accessibilityLabel(control == .cancel ? "Cancel dictation" : "Finish dictation")
    }
}

/// The dictation's model, floating above the pill for a moment after a switch, by its full name: sparkles and
/// "Gemini 3.8 Flash" in its color, or a bolt and "Parakeet". It comes up naming the new model. One chip for the whole cycle: each switch while
/// it's up puts the new name at the end of a strip, and the strip rolls on to it (`PillChipRoll`). The strip only ever
/// moves on, so switches in a row (fn ⇥ held down) keep it rolling: the spring takes each new end in its stride and
/// never starts over. In hands-free it stays while the pointer is on it, and opens the model menu (the controller pops
/// it up).
private struct PillModelChip: View {
    let model: PillModel
    let choice: ModelChoice
    let regions: PillHitRegions?
    /// Hands-free only: push-to-talk holds a key, and processing is past choosing.
    let isInteractive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The names this chip has shown, in order; the last is the dictation's model. Empty until it's up.
    @State private var names: [ModelChoice] = []
    /// Where the strip is: the index of the name it shows, between two while it rolls.
    @State private var position: Double = 0

    var body: some View {
        let settings = model.settings
        Button { model.onEngineChipClick?() } label: {
            PillChipRoll(names: names.isEmpty ? [choice] : names, position: position, settings: settings,
                         crossfades: reduceMotion)
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
        .onAppear {
            names = [choice]
            position = 0
        }
        .onChange(of: choice) { _, new in roll(to: new) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Model: \(choice.title)")
        .accessibilityAddTraits(isInteractive ? .isButton : [])
    }

    /// `new` goes at the end of the strip, and the strip rolls on to it from wherever it is.
    private func roll(to new: ModelChoice) {
        guard names.last != new else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { names.append(new) }
        let animation: Animation = reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.35, bounce: 0)
        withAnimation(animation) { position = Double(names.count - 1) }
    }
}

/// The chip at `position` along its strip of names, everything worked out from that one number so the pieces never
/// drift apart: between two names, they sit side by side, the strip moved on by the first one's width times how far
/// along it is, the chip as wide as the first, then the second (clipping the first away past its left edge, never
/// fading it), and the ring passing from the first model's color to the second's. On a whole number: that name, at
/// rest. `crossfades` (Reduce Motion): the two names stacked, one fading into the other, while the width still changes.
struct PillChipRoll: View, Animatable {
    let names: [ModelChoice]
    var position: Double
    let settings: AppSettings
    var crossfades = false

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        let last = max(0, names.count - 1)
        let at = min(max(position, 0), Double(last))
        let index = min(Int(at.rounded(.down)), last)
        let next = min(index + 1, last)
        let p = next == index ? 0 : CGFloat(at - Double(index))
        let from = names[index], to = names[next]
        let fromWidth = Self.width(of: from)
        let toWidth = Self.width(of: to)
        let rolling = next != index && p > 0
        Group {
            if !rolling {
                label(from)
            } else if crossfades {
                ZStack(alignment: .leading) {
                    label(from).opacity(Double(1 - p))
                    label(to).opacity(Double(p))
                }
            } else {
                HStack(spacing: 0) {
                    label(from)
                    label(to)
                }
                .offset(x: -fromWidth * p)
            }
        }
        .frame(width: fromWidth + (toWidth - fromWidth) * p, height: PillMetrics.chipHeight, alignment: .leading)
        .clipShape(Capsule(style: .continuous))
        .background {
            PillChipChrome(accent: PillPalette.accent(for: settings.modelColors[from]),
                           nextAccent: rolling ? PillPalette.accent(for: settings.modelColors[to]) : nil,
                           blend: p)
        }
    }

    private func label(_ choice: ModelChoice) -> some View {
        Self.label(choice,
                   accent: PillPalette.accent(for: settings.modelColors[choice]))
    }

    @MainActor static func label(_ choice: ModelChoice, accent: PillAccent?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: choice.symbolName)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(accent?.mark ?? .white.opacity(0.75))
            Text(choice.chipName)
                .foregroundStyle(.white.opacity(0.92))
        }
        .font(.system(size: 10.5, weight: .semibold))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: PillMetrics.chipHeight)
        .fixedSize()
    }

    /// A name's width, laid out once ahead of any roll (so the very first one already knows where it goes).
    @MainActor private static var widths: [String: CGFloat] = [:]

    @MainActor static func width(of choice: ModelChoice) -> CGFloat {
        let key = "\(choice.rawValue).\(choice.symbolName)"
        if let width = widths[key] { return width }
        let host = NSHostingView(rootView: label(choice, accent: nil))
        let width = ceil(host.fittingSize.width)
        widths[key] = width
        return width
    }
}

/// The chip's capsule: the pill's fill, its hairline, and the model's ring. `nextAccent` at `blend` (0…1) is the ring a
/// roll passes on to: the two crossfade.
struct PillChipChrome: View {
    var accent: PillAccent?
    var nextAccent: PillAccent?
    var blend: CGFloat = 0

    var body: some View {
        let shape = Capsule(style: .continuous)
        shape.fill(PillPalette.fill)
            .overlay {
                shape.ring(1).fill(PillPalette.hairline, style: FillStyle(eoFill: true))
            }
            .overlay {
                if let accent {
                    shape.ring(1)
                        .fill(accent.ring.opacity(Double(1 - blend)), style: FillStyle(eoFill: true))
                }
            }
            .overlay {
                if let nextAccent {
                    shape.ring(1)
                        .fill(nextAccent.ring.opacity(Double(blend)), style: FillStyle(eoFill: true))
                }
            }
            .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 2)
            .environment(\.colorScheme, .dark)
    }
}

/// The small dark capsule of the model chip and the Switch model hint: the pill's fill, its lit hairline, and the
/// model's ring.
struct PillChipCapsule<Content: View>: View {
    var accent: PillAccent?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) { content }
            .font(.system(size: 10.5, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: PillMetrics.chipHeight)
            .background { PillChipChrome(accent: accent) }
            .environment(\.colorScheme, .dark)
    }
}

/// "[fn][tab] · Gemini 3.8 Flash": the Switch model shortcut, shown faintly above a long push-to-talk hold its first
/// few times. The keys follow the user's binding.
struct PillSwitchHint: View {
    let model: PillModel

    /// What the shortcut steps to (`ModelLineup.steps`): the one model by its full name, several by their short names
    /// in order.
    static func label(for steps: [ModelChoice]) -> String {
        guard steps.count == 1, let step = steps.first else { return steps.map(\.shortName).joined(separator: ", ") }
        return step.modelName
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
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .contentTransition(.numericText())
        }
    }
}

// MARK: - Tooltips

/// Black tooltip capsule used above the pill, with the pill's hairline.
struct PillTooltipBubble<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = Capsule(style: .continuous)
        HStack(spacing: 5) { content }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 10)
            .frame(height: PillMetrics.tooltipHeight)
            .background {
                shape.fill(PillPalette.tooltipFill)
                    .overlay { shape.ring(1).fill(PillPalette.hairline, style: FillStyle(eoFill: true)) }
                    .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 2)
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
                // The pill's secondary text (the timer's): "left" at 8.5 pt keeps 4.5:1 on the cap, in the tooltip
                // and on the hint.
                Text(caption)
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
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

/// "Polish works on Gemini only": a key pressed where it does nothing says so, over the pill, in the chip's place.
struct PillKeyHint: View {
    let text: String

    var body: some View {
        PillChipCapsule {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text(text)
                .foregroundStyle(.white.opacity(0.85))
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
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
