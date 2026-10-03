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
    /// speck.
    var surfaceOpacity: Double { Double(min(1, max(0, progress / 0.15))) }
}

extension EnvironmentValues {
    @Entry var toastReveal = ToastReveal()
}

/// Drives `ToastReveal.progress` through a transition, handing it to the card below.
struct ToastRevealEffect: ViewModifier, Animatable {
    var reveal: ToastReveal

    var animatableData: CGFloat {
        get { reveal.progress }
        set { reveal.progress = newValue }
    }

    func body(content: Content) -> some View {
        content.environment(\.toastReveal, reveal)
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
struct ToastStack: View {
    let center: ToastCenter
    var pasteShortcut: Shortcut?
    var regions: PillHitRegions?
    /// Where the newest toast grows out of, and closes back into.
    var origin = ToastOrigin()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let newestKey = center.notices.last?.dedupeKey
        // Stacked cards share one width so their edges line up.
        let stackWidth = center.notices.map(ToastCard.preferredWidth(for:)).max()
        VStack(spacing: ToastMetrics.gap) {
            ForEach(center.notices, id: \.dedupeKey) { notice in
                let isNewest = notice.dedupeKey == newestKey
                // Polish Selection's cards are answers to compare: neither recedes.
                let dimmed = !isNewest && !center.isPaused && !notice.takesCardKeys
                ToastCard(notice: notice, center: center, pasteShortcut: pasteShortcut, isDimmed: dimmed,
                          width: stackWidth)
                    .scaleEffect(dimmed ? 0.96 : 1, anchor: .bottom)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PillCanvasMetrics.space)) } action: { rect in
                        // A little wider than the card, for its close button on the corner.
                        regions?.setToast(notice.dedupeKey, rect: rect.insetBy(dx: -ToastCloseButton.overhang,
                                                                               dy: -ToastCloseButton.overhang))
                    }
                    .onDisappear { regions?.setToast(notice.dedupeKey, rect: nil) }
                    .transition(isNewest ? growTransition : recedeTransition)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.34, bounce: 0.12),
                   value: center.notices.map(\.dedupeKey))
        .animation(.easeOut(duration: 0.18), value: center.isPaused)
        .environment(\.colorScheme, .dark)
    }

    /// The newest toast opens out of the pill and closes back into it.
    private var growTransition: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .asymmetric(
            insertion: .modifier(active: ToastRevealEffect(reveal: ToastReveal(progress: 0, origin: origin)),
                                 identity: ToastRevealEffect(reveal: ToastReveal(progress: 1, origin: origin)))
                .animation(.spring(duration: 0.42, bounce: 0.14)),
            removal: .modifier(active: ToastRevealEffect(reveal: ToastReveal(progress: 0, origin: origin)),
                               identity: ToastRevealEffect(reveal: ToastReveal(progress: 1, origin: origin)))
                .animation(.spring(duration: PillCanvasView.toastClosing, bounce: 0)))
    }

    /// An older toast just goes.
    private var recedeTransition: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)).animation(.easeIn(duration: 0.18))
    }
}

// MARK: - Card

struct ToastCard: View {
    let notice: Notice
    let center: ToastCenter
    var pasteShortcut: Shortcut?
    /// The older toast of a stack: its content recedes to about 70% while the card stays opaque, so the
    /// desktop never shows through it.
    var isDimmed = false
    /// Shared width when stacked; nil = the notice's own preferred width.
    var width: CGFloat?

    @Environment(\.toastReveal) private var reveal
    @State private var copiedAt: Date?

    private var isTranscript: Bool { notice.transcript != nil }
    /// A delivered transcript that didn't land points at paste-last instead of repeating its body. A failure
    /// showing text that came back (warning or error) keeps its explanation, and paste-last wouldn't paste it.
    private var showsPasteHint: Bool { isTranscript && notice.style == .info }

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
            .overlay(alignment: .topLeading) { closeButton }
            .contentShape(RoundedRectangle(cornerRadius: ToastMetrics.radius, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel([notice.title, notice.body].compactMap { $0 }.joined(separator: ". "))
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
                if !actions.isEmpty {
                    actionRow
                }
                if notice.takesCardKeys {
                    cardKeysHint
                } else if showsPasteHint {
                    pasteHint
                }
            }
            .padding(ToastMetrics.padding)
        }
    }

    @ViewBuilder
    private var countdown: some View {
        if center.countdowns[notice.id] != nil {
            // A point above the edge, so the card keeps a dark rim under it on a white page.
            ToastCountdownBar(center: center, id: notice.id)
                .padding(.bottom, 1)
                .opacity(reveal.contentOpacity)
        }
    }

    private var closeButton: some View {
        ToastCloseButton(notice: notice, center: center)
            .offset(x: -ToastCloseButton.overhang, y: -ToastCloseButton.overhang)
            .opacity(center.isPaused && reveal.progress > 0.99 ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: center.isPaused)
    }

    private var cardWidth: CGFloat { width ?? Self.preferredWidth(for: notice) }

    /// A one-row toast is as wide as its title and button (within 180-380 pt); a card is 320 pt, a transcript's 360.
    static func preferredWidth(for notice: Notice) -> CGFloat {
        if notice.transcript != nil { return ToastMetrics.transcriptWidth }
        guard isCompact(notice) else { return ToastMetrics.width }
        let title = ceil((notice.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width)
        var width = ToastMetrics.compactLeading + title
        if let action = notice.actions.first {
            let label = ceil((action.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width)
            width += 14 + label + 2 * ToastActionBody.padding + ToastMetrics.compactButtonInset
        } else {
            width += ToastMetrics.compactLeading
        }
        return min(ToastMetrics.maxWidth, max(ToastMetrics.compactMinWidth, (width + 2).rounded(.up)))
    }

    static func isCompact(_ notice: Notice) -> Bool {
        notice.body == nil && notice.transcript == nil && notice.actions.count <= 1
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(notice.title)
                .font(ToastMetrics.titleFont)
                .foregroundStyle(ToastPalette.title)
                .fixedSize(horizontal: false, vertical: true)
            if let body = notice.body, !showsPasteHint {
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
            Text(notice.title)
                .font(ToastMetrics.titleFont)
                .foregroundStyle(ToastPalette.title)
                .lineLimit(2)
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

    private var actionRow: some View {
        HStack(spacing: 6) {
            ForEach(actions) { action in
                actionButton(action, isFilled: action.id == primaryID)
            }
            Spacer(minLength: 0)
        }
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
            }
        }
        .buttonStyle(ToastActionStyle(isFilled: isFilled))
        .animation(.snappy(duration: 0.2), value: copied)
        .accessibilityLabel(copied ? "Copied" : action.title)
    }

    /// "[return] pastes · [esc] closes": the card's own keys while it's up. Next to another such card ↩ couldn't tell
    /// which to paste: "[esc] closes both".
    /// What the keys do right now (`ToastCenter.cardKeys`). While a dictation is busy with them, the footer dims.
    private var cardKeysHint: some View {
        let together = center.notices.filter(\.takesCardKeys).count > 1
        let keys = center.cardKeys
        return HStack(spacing: 5) {
            if keys.returnPastes, !together {
                ShortcutChips(shortcut: Shortcut(modifiers: [], keyCode: KeyCode.returnKey), size: .small)
                Text("pastes")
                Text("·").foregroundStyle(ToastPalette.quiet.opacity(0.6))
            }
            ShortcutChips(shortcut: Shortcut(modifiers: [], keyCode: KeyCode.escape), size: .small)
            Text(together ? "closes both" : "closes")
        }
        .opacity(keys.escCloses ? 1 : 0.45)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(ToastPalette.quiet)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((keys.returnPastes && !together ? "Return pastes, " : "")
                            + (together ? "Escape closes both" : "Escape closes")
                            + (keys.escCloses ? "" : ", once the dictation is done"))
    }

    private var pasteHint: some View {
        HStack(spacing: 5) {
            Text("Or click a text field and press")
            if let pasteShortcut, !pasteShortcut.isEmpty {
                ShortcutChips(shortcut: pasteShortcut, size: .small)
            } else {
                Text("⌘V")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(ToastPalette.quiet)
        .padding(.horizontal, 2)
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
