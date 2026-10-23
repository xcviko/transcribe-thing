import AppKit
import SwiftUI

/// Toast colors. Toasts grow out of the pill, so they wear its black, its hairline and white text, in both
/// appearances.
enum ToastPalette {
    static let fill = PillPalette.fill
    static let stroke = PillPalette.hairline
    static let transcriptFill = Color.white.opacity(0.07)
    static let title = Color.white.opacity(0.94)
    static let body = Color.white.opacity(0.62)
    static let quiet = Color.white.opacity(0.42)
    /// The countdown along the bottom edge: the time left, over its track.
    static let countdown = Color.white.opacity(0.85)
    static let countdownTrack = Color.white.opacity(0.16)
}

enum ToastMetrics {
    static let width: CGFloat = 320
    static let transcriptWidth: CGFloat = 360
    static let maxWidth: CGFloat = 380
    /// A one-row toast is as wide as its title and button, but never narrower than this.
    static let compactMinWidth: CGFloat = 180
    static let padding: CGFloat = 14
    static let gap: CGFloat = 8
    /// Every card's corners; a one-row toast is exactly twice as tall, so it's a capsule like the pill.
    static let radius: CGFloat = 20
    /// A one-row toast: its title 16 pt from the left end, its button 6 pt from the right one, concentric with it.
    static let compactHeight: CGFloat = 2 * radius
    static let compactLeading: CGFloat = 16
    static let compactButtonInset: CGFloat = 6
    static let buttonHeight: CGFloat = compactHeight - 2 * compactButtonInset
    static let titleFont = Font.system(size: 13, weight: .medium)
    /// A one-row toast's second line (`Notice.detail`).
    static let detailFont = Font.system(size: 11)
    /// The countdown's bar along the bottom edge, inside the card's curve.
    static let countdownHeight: CGFloat = 2.5
    /// A transcript's text in its box: 13 pt, 2 pt between lines, inset 12 by 10.
    static let transcriptFontSize: CGFloat = 13
    static let transcriptLineSpacing: CGFloat = 2
    static let transcriptInsets = CGSize(width: 12, height: 10)
    /// The box shows about five lines; longer text scrolls inside it.
    static let transcriptMaxTextHeight: CGFloat = 92

    /// How tall `text` sets in a box `boxWidth` wide, capped at `transcriptMaxTextHeight` (the rest scrolls).
    static func transcriptTextHeight(_ text: String, boxWidth: CGFloat) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = transcriptLineSpacing
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: transcriptFontSize),
                                                         .paragraphStyle: style]
        let width = max(1, boxWidth - 2 * transcriptInsets.width)
        let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   attributes: attributes)
        return min(ceil(rect.height), transcriptMaxTextHeight)
    }
}

// MARK: - Growing out of the pill

/// Where the newest toast grows out of: the pill's capsule, `size`, its bottom `drop` points below the toast's.
/// In the pill's slot (nothing on the pill), the drop is 0 and the capsule is the resting one.
struct ToastOrigin: Equatable {
    var size: CGSize = PillMetrics.restSize
    var drop: CGFloat = 0
    /// The resting pill is under the toast in its slot (Always) and takes over as the toast closes into it: the card
    /// closes into the pill's very shape without fading, so the two meet with no seam.
    var pillComesBack = false

    /// The pill's slot: the toast stands where the pill would.
    var isSlot: Bool { drop == 0 }
}

/// How far a toast is out of the pill: 0 is the pill's capsule, 1 the whole card. The card's black surface grows
/// from the capsule to its own shape and the words come in over the second half, so the pill seems to open into the
/// toast; leaving, the toast closes back into it.
struct ToastReveal: Equatable {
    var progress: CGFloat = 1
    var origin = ToastOrigin()

    /// The words and buttons: in over the second half.
    var contentOpacity: Double {
        let u = Double(min(1, max(0, (progress - 0.5) / 0.5)))
        return u * u * (3 - 2 * u)
    }

    /// The surface itself fades over the first few percent, so a toast leaving where no pill is doesn't end as a
    /// speck. Where the resting pill takes over, it closes whole into the pill's shape instead. Over a dictation's pill
    /// (`drop` above it) it's gone by the time it would reach the pill's top edge, and comes in only above it: never
    /// a card under the pill, wider than it, showing around it.
    var surfaceOpacity: Double {
        if origin.pillComesBack { return 1 }
        if origin.drop > 0 {
            let reachesPill = min(0.9, origin.size.height / origin.drop)
            return Double(min(1, max(0, (progress - reachesPill) / (1 - reachesPill))))
        }
        return Double(min(1, max(0, progress / 0.15)))
    }
}

extension EnvironmentValues {
    @Entry var toastReveal = ToastReveal()
}

/// Drives `ToastReveal.progress`, handing it to the card below: as the newest card's insertion transition (it grows out
/// of the pill), and on every card in the stack (the newest closing back into it, `ToastStack`). The two multiply, so
/// a card closing while it still grows closes from where it got to.
///
/// Only a live card follows it: a view being removed no longer takes new environment values, so a card closing
/// through a removal transition stayed whole and opaque until the removal ended, then vanished in one frame.
struct ToastRevealEffect: ViewModifier, Animatable {
    var reveal: ToastReveal

    var animatableData: CGFloat {
        get { reveal.progress }
        set { reveal.progress = newValue }
    }

    func body(content: Content) -> some View {
        content.transformEnvironment(\.toastReveal) { value in
            value.progress *= reveal.progress
            value.origin = reveal.origin
        }
    }
}

/// The card's outline at `reveal`: the origin's capsule (bottom-centered, `drop` lower) growing into the card's
/// rounded rectangle, its corners rounding from the capsule's to `radius`. Corners as round as it is tall make it a
/// true capsule, so it never shows the flat ends a continuous rounded rectangle gets at that radius.
struct ToastSurfaceShape: InsettableShape {
    var reveal: ToastReveal
    var radius: CGFloat
    var insetAmount: CGFloat = 0

    var animatableData: CGFloat {
        get { reveal.progress }
        set { reveal.progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let frame = Self.frame(reveal, in: rect).insetBy(dx: insetAmount, dy: insetAmount)
        let corner = Self.cornerRadius(reveal, radius: radius, in: rect) - insetAmount
        guard frame.width > 0, frame.height > 0 else { return Path() }
        if corner >= frame.height / 2 - 0.01 { return Capsule(style: .continuous).path(in: frame) }
        return RoundedRectangle(cornerRadius: max(0, corner), style: .continuous).path(in: frame)
    }

    func inset(by amount: CGFloat) -> ToastSurfaceShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }

    static func frame(_ reveal: ToastReveal, in rect: CGRect) -> CGRect {
        let p = reveal.progress
        let from = reveal.origin.size
        let width = from.width + (rect.width - from.width) * p
        let height = from.height + (rect.height - from.height) * p
        let bottom = rect.maxY + reveal.origin.drop * (1 - p)
        return CGRect(x: rect.midX - width / 2, y: bottom - height, width: width, height: height)
    }

    static func cornerRadius(_ reveal: ToastReveal, radius: CGFloat, in rect: CGRect) -> CGFloat {
        let start = reveal.origin.size.height / 2
        let height = frame(reveal, in: rect).height
        return min(height / 2, start + (radius - start) * reveal.progress)
    }
}

/// The card's hairline, following its outline as it grows.
private struct ToastSurfaceEdge: View {
    var reveal: ToastReveal

    var body: some View {
        ToastSurfaceShape(reveal: reveal, radius: ToastMetrics.radius)
            .ring(1)
            .fill(ToastPalette.stroke, style: FillStyle(eoFill: true))
    }
}

/// The card's shadow, cast by its outline as it grows (the card itself is clipped to it).
private struct ToastSurfaceShadow: View {
    var reveal: ToastReveal

    var body: some View {
        ToastSurfaceShape(reveal: reveal, radius: ToastMetrics.radius)
            .fill(ToastPalette.fill)
            .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
    }
}

// MARK: - Stack

/// Newest toast nearest the pill, grown out of it; the older one sits above it, slightly smaller and dimmer until
/// hovered.
///
/// The newest toast closes back into the pill as a live card. Gone from `center`, it stays in the stack while it
/// closes: it takes no room, stays at the bottom where the newest card stands, behind the cards closing up over it,
/// follows the stack, takes no clicks, and is dropped once it's closed. Through a removal transition it couldn't close
/// at all: a view being removed is no longer laid out and takes no new environment values, so it stayed whole and
/// opaque where it was, over whatever came there, until the removal ended. A card closing into the pill's slot as the
/// pill comes back into it (Undo on "Dictation canceled", Retry on a failure) is gone in that same frame: the pill is
/// drawn where it was.
struct ToastStack: View {
    let center: ToastCenter
    var regions: PillHitRegions?
    /// Where the newest toast grows out of, and closes back into.
    var origin = ToastOrigin()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The cards and the origin as of the last update. In the update that takes the newest card away, it's still here,
    /// so the card closes from that very frame (`record` keeps it in `closing` right after).
    @State private var seen = Seen()
    /// Newest cards that went, closing into the pill.
    @State private var closing: [ToastClosing] = []

    struct Seen: Equatable {
        var notices: [Notice] = []
        var origin = ToastOrigin()
    }

    var body: some View {
        let notices = center.notices
        let keys = Set(notices.map(\.dedupeKey))
        let newestKey = notices.last?.dedupeKey
        // Stacked cards share one width so their edges line up.
        let stackWidth = notices.map(ToastCard.preferredWidth(for:)).max()
        // Closing cards first: drawn under the cards that stay.
        let entries = closingCards(keys: keys).map { ToastStackEntry(notice: $0.notice, closing: $0) }
            + notices.map { ToastStackEntry(notice: $0, closing: nil) }
        ToastStackLayout(spacing: ToastMetrics.gap) {
            ForEach(entries) { entry in
                let notice = entry.notice
                let isNewest = notice.dedupeKey == newestKey
                let leaving = entry.closing != nil
                // Cards of text to paste (Polish Selection's answers, earlier dictations) are there to pick from:
                // neither recedes.
                let dimmed = !leaving && !isNewest && !center.isPaused && !notice.takesCardKeys
                // Closing into the slot the pill has come back into: under the pill, so gone at once.
                let covered = entry.closing.map { $0.origin.isSlot && !origin.isSlot } ?? false
                ToastCard(notice: notice, center: center, isDimmed: dimmed, isLeaving: leaving,
                          width: entry.closing?.width ?? stackWidth)
                    .scaleEffect(dimmed ? 0.96 : 1, anchor: .bottom)
                    // Not a scoped `animation(_:body:)`: the environment set inside one never reaches the card.
                    .modifier(ToastRevealEffect(reveal: reveal(of: entry)))
                    .opacity(leaving && reduceMotion ? 0 : 1)
                    .animation(closingAnimation, value: leaving)
                    .animation(nil) { $0.opacity(covered ? 0 : 1) }
                    .allowsHitTesting(!leaving)
                    .accessibilityHidden(leaving)
                    .modifier(ToastRegion(key: notice.dedupeKey, regions: regions, isLive: !leaving))
                    .layoutValue(key: ToastLeavingKey.self, value: leaving)
                    .transition(isNewest ? growTransition : recedeTransition)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.34, bounce: 0.12),
                   value: notices.map(\.dedupeKey))
        .animation(.easeOut(duration: 0.18), value: center.isPaused)
        .environment(\.colorScheme, .dark)
        .onChange(of: Seen(notices: notices, origin: origin), initial: true) { _, new in record(new) }
    }

    /// The newest card closes into the pill on the capsule's own spring; Reduce Motion fades it.
    private var closingAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: PillCanvasView.toastClosing, bounce: 0)
    }

    /// A card that stays is whole; one closing goes to the pill it came from (where the pill was when it went).
    private func reveal(of entry: ToastStackEntry) -> ToastReveal {
        guard let closing = entry.closing else { return ToastReveal(progress: 1, origin: origin) }
        return ToastReveal(progress: reduceMotion ? 1 : 0, origin: closing.origin)
    }

    /// The cards closing now: those already kept, and the newest card of the last update if it has just gone.
    private func closingCards(keys: Set<String>) -> [ToastClosing] {
        var cards = closing.filter { !keys.contains($0.key) }
        if let card = Self.departure(from: seen, keys: keys), !cards.contains(where: { $0.key == card.key }) {
            cards.append(card)
        }
        return cards
    }

    /// `seen`'s newest card, if it's no longer among `keys`: as it stood, its width and the pill it grew out of. Only
    /// when it was the last card: with others left, the next one comes down into its place, and a card closing there
    /// showed under it; it fades where it is instead (`growTransition`'s removal).
    private static func departure(from seen: Seen, keys: Set<String>) -> ToastClosing? {
        guard keys.isEmpty, let newest = seen.notices.last, !keys.contains(newest.dedupeKey) else { return nil }
        return ToastClosing(notice: newest,
                            width: seen.notices.map(ToastCard.preferredWidth(for:)).max()
                                ?? ToastCard.preferredWidth(for: newest),
                            origin: seen.origin)
    }

    private func record(_ new: Seen) {
        let keys = Set(new.notices.map(\.dedupeKey))
        // Posted again while it closed: a live card again, it opens back up.
        closing.removeAll { keys.contains($0.key) }
        if let card = Self.departure(from: seen, keys: keys) {
            closing.removeAll { $0.key == card.key }
            closing.append(card)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(PillCanvasView.toastClosing + 0.15))
                // Closed by now: nothing may animate.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { closing.removeAll { $0.id == card.id } }
            }
        }
        // A card that went takes no clicks and holds no hover from now on, not once its removal has played out.
        for notice in seen.notices where !keys.contains(notice.dedupeKey) {
            regions?.setToast(notice.dedupeKey, rect: nil)
        }
        seen = new
    }

    /// The newest toast opens out of the pill. The last one closes back into it as a live card (`ToastClosing`); one with
    /// others left fades where it is as the next comes down.
    private var growTransition: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .asymmetric(
            insertion: .modifier(active: ToastRevealEffect(reveal: ToastReveal(progress: 0, origin: origin)),
                                 identity: ToastRevealEffect(reveal: ToastReveal(progress: 1, origin: origin)))
                .animation(.spring(duration: 0.42, bounce: 0.14)),
            removal: .opacity.animation(.easeOut(duration: 0.12)))
    }

    /// An older toast just goes, quick and soft from the start: the cards below close up over it, so it's out of the way
    /// before they reach it.
    private var recedeTransition: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)).animation(.easeOut(duration: 0.12))
    }
}

/// The newest card on its way back into the pill (`ToastStack`): as it stood, its width in the stack, and the pill it
/// closes into.
struct ToastClosing: Identifiable, Equatable {
    let id = UUID()
    let notice: Notice
    let width: CGFloat
    let origin: ToastOrigin

    var key: String { notice.dedupeKey }
}

/// Reports a card's area to the hit regions while it's live; a card closing back into the pill takes no clicks and holds
/// no hover from the moment it goes, and one posted again while it closed takes them back at once.
private struct ToastRegion: ViewModifier {
    let key: String
    let regions: PillHitRegions?
    let isLive: Bool

    /// Where the card is on the canvas, as last laid out: a little wider than it, for its close button on the corner.
    @State private var frame: CGRect?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PillCanvasMetrics.space)) } action: { rect in
                frame = rect.insetBy(dx: -ToastCloseButton.overhang, dy: -ToastCloseButton.overhang)
                regions?.setToast(key, rect: isLive ? frame : nil)
            }
            .onChange(of: isLive) { _, live in regions?.setToast(key, rect: live ? frame : nil) }
            .onDisappear { regions?.setToast(key, rect: nil) }
    }
}

/// A card in the stack: a notice, and how it closes when it's one that went.
private struct ToastStackEntry: Identifiable {
    let notice: Notice
    let closing: ToastClosing?

    var id: String { notice.dedupeKey }
}

/// A card closing back into the pill takes no room in the stack.
private struct ToastLeavingKey: LayoutValueKey {
    static let defaultValue = false
}

/// The cards bottom up, newest at the bottom, each centered, `spacing` apart. A card closing back into the pill
/// (`ToastLeavingKey`) takes no room: it stays at the bottom, where the newest card stands, and the others close up
/// over it.
private struct ToastStackLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var size = CGSize.zero
        var count = 0
        for subview in subviews where !subview[ToastLeavingKey.self] {
            let card = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            size.width = max(size.width, card.width)
            size.height += card.height
            count += 1
        }
        size.height += spacing * CGFloat(max(0, count - 1))
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var bottom = bounds.maxY
        for subview in subviews.reversed() {
            let card = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            let leaving = subview[ToastLeavingKey.self]
            subview.place(at: CGPoint(x: bounds.midX, y: leaving ? bounds.maxY : bottom), anchor: .bottom,
                          proposal: ProposedViewSize(card))
            if !leaving { bottom -= card.height + spacing }
        }
    }
}

// MARK: - Card

struct ToastCard: View {
    let notice: Notice
    let center: ToastCenter
    /// The older toast of a stack: its content recedes to about 70% while the card stays opaque, so the
    /// desktop never shows through it.
    var isDimmed = false
    /// Closing back into the pill (`ToastStack`): gone from the center. Its close button hides; its countdown stays,
    /// emptied, and fades with the words.
    var isLeaving = false
    /// Shared width when stacked; nil = the notice's own preferred width.
    var width: CGFloat?

    @Environment(\.toastReveal) private var reveal
    @State private var copiedAt: Date?

    private var isTranscript: Bool { notice.transcript != nil }
    /// A delivered transcript that didn't land says only "Not pasted" over its text. A failure showing text that came
    /// back (warning or error) keeps its explanation.
    private var hidesBody: Bool { isTranscript && notice.style == .info }

    /// Title with at most one short action and nothing else: a single row, in a capsule.
    private var isCompact: Bool { Self.isCompact(notice) }

    var body: some View {
        let surface = ToastSurfaceShape(reveal: reveal, radius: ToastMetrics.radius)
        content
            .frame(width: cardWidth, alignment: .leading)
            .opacity(reveal.contentOpacity * (isDimmed ? 0.65 : 1))
            .background { surface.fill(ToastPalette.fill) }
            .overlay(alignment: .bottom) { countdown }
            .clipShape(surface)
            .overlay { ToastSurfaceEdge(reveal: reveal) }
            .background { ToastSurfaceShadow(reveal: reveal) }
            .opacity(reveal.surfaceOpacity)
            .contentShape(RoundedRectangle(cornerRadius: ToastMetrics.radius, style: .continuous))
            // After the card's shape: the button's middle is past the card's rounded corner, which would take its clicks.
            .overlay(alignment: .topLeading) { closeButton }
            .accessibilityElement(children: .contain)
            .accessibilityLabel([notice.title, notice.body, notice.detail].compactMap { $0 }.joined(separator: ". "))
    }

    @ViewBuilder
    private var content: some View {
        if isCompact {
            compactRow
        } else {
            VStack(alignment: .leading, spacing: 10) {
                header
                if let transcript = notice.transcript {
                    transcriptBlock(transcript)
                }
                if !actions.isEmpty || notice.link != nil {
                    actionRow
                }
            }
            .padding(ToastMetrics.padding)
        }
    }

    @ViewBuilder
    private var countdown: some View {
        // Closing, its bar stays (emptied) and fades with the words, rather than going through a removal.
        if center.countdowns[notice.id] != nil || isLeaving {
            // A point above the edge, so the card keeps a dark rim under it on a white page.
            ToastCountdownBar(center: center, id: notice.id)
                .padding(.bottom, 1)
                .opacity(reveal.contentOpacity)
        }
    }

    private var closeButton: some View {
        ToastCloseButton(notice: notice, center: center)
            .offset(x: -ToastCloseButton.overhang, y: -ToastCloseButton.overhang)
            .opacity(center.isPaused && !isLeaving && reveal.progress > 0.99 ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: center.isPaused)
    }

    private var cardWidth: CGFloat { width ?? Self.preferredWidth(for: notice) }

    /// A one-row toast is as wide as its title and button (within 180-380 pt); a card is 320 pt, a transcript's 360.
    static func preferredWidth(for notice: Notice) -> CGFloat {
        if notice.transcript != nil { return ToastMetrics.transcriptWidth }
        guard isCompact(notice) else { return ToastMetrics.width }
        var title = ceil((notice.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width)
        if let detail = notice.detail {
            title = max(title, ceil((detail as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width))
        }
        var width = ToastMetrics.compactLeading + title
        if let action = notice.actions.first {
            var label = ceil((action.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width)
            if let hint = action.keyHint { label += 4 + ToastKeyHint.width(hint) }
            width += 14 + label + 2 * ToastActionBody.padding + ToastMetrics.compactButtonInset
        } else {
            width += ToastMetrics.compactLeading
        }
        return min(ToastMetrics.maxWidth, max(ToastMetrics.compactMinWidth, (width + 2).rounded(.up)))
    }

    static func isCompact(_ notice: Notice) -> Bool {
        notice.body == nil && notice.transcript == nil && notice.actions.count <= 1 && notice.link == nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(notice.title)
                .font(ToastMetrics.titleFont)
                .foregroundStyle(ToastPalette.title)
                .fixedSize(horizontal: false, vertical: true)
            if let body = notice.body, !hidesBody {
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(ToastPalette.body)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 2)
    }

    private var compactRow: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title)
                    .font(ToastMetrics.titleFont)
                    .foregroundStyle(ToastPalette.title)
                    .lineLimit(2)
                if let detail = notice.detail {
                    Text(detail)
                        .font(ToastMetrics.detailFont)
                        .foregroundStyle(ToastPalette.body)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action = actions.first {
                actionButton(action, isFilled: false)
                    .fixedSize()
            }
        }
        .padding(.leading, ToastMetrics.compactLeading)
        .padding(.trailing, actions.isEmpty ? ToastMetrics.compactLeading : ToastMetrics.compactButtonInset)
        .padding(.vertical, ToastMetrics.compactButtonInset)
        .frame(minHeight: ToastMetrics.compactHeight)
    }

    /// The text, selectable, in a box as tall as it needs up to about five lines, scrolling past that. A selectable
    /// `Text` with a line limit draws every line once clicked, out over the buttons, so the box never truncates.
    private func transcriptBlock(_ transcript: String) -> some View {
        let boxWidth = cardWidth - 2 * ToastMetrics.padding
        let insets = ToastMetrics.transcriptInsets
        return ScrollView(.vertical) {
            Text(transcript)
                .font(.system(size: ToastMetrics.transcriptFontSize))
                .foregroundStyle(ToastPalette.title)
                .lineSpacing(ToastMetrics.transcriptLineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, insets.width)
                .padding(.vertical, insets.height)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        .frame(height: ToastMetrics.transcriptTextHeight(transcript, boxWidth: boxWidth) + 2 * insets.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ToastPalette.transcriptFill)
        }
    }

    /// Transcript cards always offer Copy: primary unless the poster already chose one ("Paste Here").
    private var actions: [NoticeAction] {
        var list = Array(notice.actions.prefix(2))
        if let transcript = notice.transcript,
           !list.contains(where: { if case .copyText = $0.kind { true } else { false } }) {
            let hasPrimary = list.contains(where: \.isPrimary)
            let copy = NoticeAction(id: Self.copyActionID(for: notice), title: "Copy",
                                    kind: .copyText(transcript), isPrimary: !hasPrimary)
            if hasPrimary { list.append(copy) } else { list.insert(copy, at: 0) }
        }
        return Array(list.prefix(2))
    }

    /// Stable across re-renders so the button keeps its identity (and its "Copied" state).
    private static func copyActionID(for notice: Notice) -> UUID {
        var bytes = notice.id.uuid
        bytes.15 ^= 0xA5
        return UUID(uuid: bytes)
    }

    /// Only one white button per card: the first action flagged primary.
    private var primaryID: UUID? { actions.first(where: \.isPrimary)?.id }

    /// The buttons, and the notice's link under them, in line with the words above: three buttons don't fit a card,
    /// and the link is the answer given least.
    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                buttons
                Spacer(minLength: 0)
            }
            if let link = notice.link {
                linkButton(link)
                    .padding(.leading, 2)
            }
        }
    }

    private var buttons: some View {
        ForEach(actions) { action in
            actionButton(action, isFilled: action.id == primaryID)
        }
    }

    private func linkButton(_ action: NoticeAction) -> some View {
        Button(action.title) { center.perform(action, on: notice) }
            .buttonStyle(ToastLinkStyle())
            .fixedSize()
            .accessibilityLabel(action.title)
    }

    private func actionButton(_ action: NoticeAction, isFilled: Bool) -> some View {
        let isCopy = { if case .copyText = action.kind { true } else { false } }()
        let copied = isCopy && copiedAt != nil
        return Button {
            if isCopy { flashCopied() }
            center.perform(action, on: notice)
        } label: {
            HStack(spacing: 4) {
                if copied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .transition(.scale.combined(with: .opacity))
                } else if isCopy && isTranscript {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(copied ? "Copied" : action.title)
                    .contentTransition(.opacity)
                if let hint = action.keyHint, !copied {
                    ToastKeyHint(text: hint, onFilled: isFilled)
                }
            }
        }
        .buttonStyle(ToastActionStyle(isFilled: isFilled))
        .animation(.snappy(duration: 0.2), value: copied)
        .accessibilityLabel(copied ? "Copied" : action.title)
    }

    private func flashCopied() {
        let stamp = Date()
        copiedAt = stamp
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copiedAt == stamp { copiedAt = nil }
        }
    }
}

/// The key that does a button's action too (`NoticeAction.keyHint`): its name, small and dim in a keycap's outline,
/// after the title ("Undo  F5").
struct ToastKeyHint: View {
    let text: String
    /// On the white button of a card's primary action: dark rather than light.
    var onFilled = false

    static let font = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let padding: CGFloat = 4

    /// What it takes beside the title, for a one-row toast's width (`ToastCard.preferredWidth`).
    static func width(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2 * padding
    }

    var body: some View {
        let ink = onFilled ? Color.black : Color.white
        Text(text)
            .font(Font(Self.font))
            .foregroundStyle(ink.opacity(0.55))
            .padding(.horizontal, Self.padding)
            .frame(height: 15)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(ink.opacity(0.22), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

/// The close button on the card's top-left corner, as on macOS notifications: it shows while the pointer is over the
/// toasts.
struct ToastCloseButton: View {
    let notice: Notice
    let center: ToastCenter
    /// How far it sits out past the card's corner.
    static let overhang: CGFloat = 5

    @State private var hovering = false

    var body: some View {
        Button {
            center.dismiss(notice.id)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.75))
                .frame(width: 18, height: 18)
                .background {
                    Circle().fill(Color(nsColor: .hex(hovering ? 0x2A2A2A : 0x1A1A1A)))
                        .overlay { Circle().strokeBorder(ToastPalette.stroke, lineWidth: 1) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Dismiss")
    }
}

/// The time a toast has left, as a thin bar along its bottom edge that shortens toward the left; the card's curve
/// clips its ends.
private struct ToastCountdownBar: View {
    let center: ToastCenter
    let id: UUID

    var body: some View {
        let running = center.countdowns[id]?.isRunning ?? false
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { context in
            let fraction = center.fractionRemaining(for: id, at: context.date) ?? 0
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(ToastPalette.countdownTrack)
                    Rectangle().fill(ToastPalette.countdown)
                        .frame(width: geometry.size.width * fraction)
                }
            }
        }
        .frame(height: ToastMetrics.countdownHeight)
        .accessibilityHidden(true)
    }
}

/// Toast buttons, capsules concentric with a one-row toast: white with black words for a card's primary action, quiet
/// gray otherwise (a one-row toast's only button too, as Undo is in Wispr Flow).
private struct ToastActionStyle: ButtonStyle {
    var isFilled: Bool

    func makeBody(configuration: Configuration) -> some View {
        ToastActionBody(configuration: configuration, isFilled: isFilled)
    }
}

/// A toast's link (`Notice.link`): small quiet words, brighter and underlined under the pointer.
private struct ToastLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToastLinkBody(configuration: configuration)
    }
}

private struct ToastLinkBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(hovering || configuration.isPressed ? ToastPalette.title : ToastPalette.body)
            .underline(hovering)
            .lineLimit(1)
            // A taller target than the words, without moving them.
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .padding(.vertical, -4)
            .onHover { hovering = $0 }
            .animation(Theme.Motion.hover, value: hovering)
    }
}

private struct ToastActionBody: View {
    static let padding: CGFloat = 12

    let configuration: ButtonStyleConfiguration
    let isFilled: Bool
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isFilled ? Color.black : Color.white.opacity(0.94))
            .lineLimit(1)
            .padding(.horizontal, Self.padding)
            .frame(height: ToastMetrics.buttonHeight)
            .background {
                Capsule(style: .continuous)
                    .fill(isFilled ? Color.white.opacity(pressed ? 0.8 : (hovering ? 1 : 0.92))
                                   : Color.white.opacity(pressed ? 0.2 : (hovering ? 0.16 : 0.11)))
            }
            .scaleEffect(pressed ? 0.97 : 1)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(Theme.Motion.hover, value: hovering)
    }
}
