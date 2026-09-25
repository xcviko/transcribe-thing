import AppKit
import SwiftUI

/// Toast surface colors. Unlike the pill, toasts follow the system appearance (wispr-ux §1.7).
enum ToastPalette {
    static let fill = Color(nsColor: Palette.dynamic("toastFill", light: .hex(0xFFFFFF, alpha: 0.97),
                                                     dark: .hex(0x1F1E1D, alpha: 0.97)))
    static let stroke = Color(nsColor: Palette.dynamic("toastStroke", light: .hex(0x1C1A17, alpha: 0.09),
                                                       dark: .hex(0xFFFFFF, alpha: 0.11)))
    static let transcriptFill = Color(nsColor: Palette.dynamic("toastTranscript", light: .hex(0xF6F3EE),
                                                               dark: .hex(0x161514)))

    static func tint(for style: NoticeStyle) -> Color {
        switch style {
        case .info: .accent
        case .success: .success
        case .warning: .warning
        case .error: .danger
        }
    }
}

enum ToastMetrics {
    static let width: CGFloat = 340
    static let transcriptWidth: CGFloat = 380
    static let maxWidth: CGFloat = 380
    /// Icon (24) + spacing (10): where the title, body and actions start.
    static let textInset: CGFloat = 34
    static let padding: CGFloat = 14
    static let gap: CGFloat = 8
}

// MARK: - Stack

/// Newest toast nearest the pill; the older one sits above it, slightly smaller and dimmer until hovered.
struct ToastStack: View {
    let center: ToastCenter
    var pasteShortcut: Shortcut?
    var regions: PillHitRegions?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let newestKey = center.notices.last?.dedupeKey
        // Stacked cards share one width so their edges line up.
        let stackWidth = center.notices.map(ToastCard.preferredWidth(for:)).max()
        VStack(spacing: ToastMetrics.gap) {
            ForEach(center.notices, id: \.dedupeKey) { notice in
                let isOlder = notice.dedupeKey != newestKey
                let dimmed = isOlder && !center.isPaused
                ToastCard(notice: notice, center: center, pasteShortcut: pasteShortcut, isDimmed: dimmed,
                          width: stackWidth)
                    .scaleEffect(dimmed ? 0.96 : 1, anchor: .bottom)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PillCanvasMetrics.space)) } action: { rect in
                        regions?.setToast(notice.dedupeKey, rect: rect)
                    }
                    .onDisappear { regions?.setToast(notice.dedupeKey, rect: nil) }
                    .transition(transition)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.32, bounce: 0.2),
                   value: center.notices.map(\.dedupeKey))
        .animation(.easeOut(duration: 0.18), value: center.isPaused)
    }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 10)).animation(.spring(duration: 0.32, bounce: 0.2)),
            removal: .opacity.combined(with: .offset(y: 6)).animation(.easeIn(duration: 0.18)))
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

    @Environment(\.colorScheme) private var scheme
    @State private var copiedAt: Date?

    private var isTranscript: Bool { notice.transcript != nil }
    /// A delivered transcript that didn't land points at paste-last instead of repeating its body. A failure
    /// showing text that came back (warning or error) keeps its explanation, and paste-last wouldn't paste it.
    private var showsPasteHint: Bool { isTranscript && notice.style == .info }
    private var tint: Color { ToastPalette.tint(for: notice.style) }

    /// Title with one short action and nothing else: a single compact row.
    private var isCompact: Bool { Self.isCompact(notice) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.toast, style: .continuous)
        Group {
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
                            .padding(.leading, isTranscript ? 0 : ToastMetrics.textInset)
                    }
                    if showsPasteHint {
                        pasteHint
                    }
                }
            }
        }
        .padding(ToastMetrics.padding)
        .frame(width: cardWidth, alignment: .leading)
        .overlay {
            shape.fill(ToastPalette.fill)
                .opacity(isDimmed ? 0.35 : 0)
                .allowsHitTesting(false)
        }
        .background {
            shape.fill(ToastPalette.fill)
                .overlay { shape.strokeBorder(ToastPalette.stroke, lineWidth: 1) }
                .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.06), radius: 1, x: 0, y: 1)
                .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.14), radius: 12, x: 0, y: 8)
        }
        .contentShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel([notice.title, notice.body].compactMap { $0 }.joined(separator: ". "))
    }

    private var cardWidth: CGFloat { width ?? Self.preferredWidth(for: notice) }

    /// 340 pt, widened up to 380 pt so a title stays on one line (wispr-ux §1.7); transcript cards are 380.
    static func preferredWidth(for notice: Notice) -> CGFloat {
        if notice.transcript != nil { return ToastMetrics.transcriptWidth }
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let title = ceil((notice.title as NSString).size(withAttributes: [.font: font]).width)
        // padding · icon · gap · title · gap · spacer · gap · close
        var chrome = ToastMetrics.padding * 2 + 24 + 10 + 10 + 4 + 10 + 20
        if isCompact(notice), let action = notice.actions.first {
            let label = NSFont.systemFont(ofSize: 12, weight: .semibold)
            // the compact spacer is 8, and the button (label + 24 padding) adds one more gap
            chrome += 4 + ceil((action.title as NSString).size(withAttributes: [.font: label]).width) + 24 + 10
        }
        return min(ToastMetrics.maxWidth, max(ToastMetrics.width, title + chrome + 2))
    }

    static func isCompact(_ notice: Notice) -> Bool {
        notice.body == nil && notice.transcript == nil && notice.actions.count == 1
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            ToastIcon(symbol: notice.symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let body = notice.body, !showsPasteHint {
                    Text(body)
                        .font(.system(size: 12))
                        .foregroundStyle(.inkSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 3)
            Spacer(minLength: 4)
            ToastCloseButton(notice: notice, center: center)
        }
    }

    private var compactRow: some View {
        HStack(spacing: 10) {
            ToastIcon(symbol: notice.symbol, tint: tint)
            Text(notice.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.ink)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let action = actions.first {
                actionButton(action, isPrimary: true)
            }
            ToastCloseButton(notice: notice, center: center)
        }
    }

    private func transcriptBlock(_ transcript: String) -> some View {
        Text(transcript)
            .font(.system(size: 13))
            .foregroundStyle(.ink)
            .lineSpacing(2)
            .lineLimit(4)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ToastPalette.transcriptFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(ToastPalette.stroke, lineWidth: 1)
                    }
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

    /// Only one filled button per toast: the first action flagged primary.
    private var primaryID: UUID? { actions.first(where: \.isPrimary)?.id }

    private var actionRow: some View {
        HStack(spacing: 6) {
            ForEach(actions) { action in
                actionButton(action, isPrimary: action.id == primaryID)
            }
            Spacer(minLength: 0)
        }
    }

    private func actionButton(_ action: NoticeAction, isPrimary: Bool) -> some View {
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
        .buttonStyle(ToastActionStyle(isPrimary: isPrimary))
        .animation(.snappy(duration: 0.2), value: copied)
        .accessibilityLabel(copied ? "Copied" : action.title)
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
        .foregroundStyle(.inkTertiary)
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

/// Style glyph in a soft tinted disc.
private struct ToastIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
            .background(Circle().fill(tint.opacity(0.13)))
            .accessibilityHidden(true)
    }
}

/// Close button inside an 18 pt countdown ring; the ring drains as the toast's lifetime runs out.
private struct ToastCloseButton: View {
    let notice: Notice
    let center: ToastCenter
    @State private var hovering = false

    var body: some View {
        Button {
            center.dismiss(notice.id)
        } label: {
            ZStack {
                Circle().fill(hovering ? Color.hover : .clear)
                if center.countdowns[notice.id] != nil {
                    CountdownRing(center: center, id: notice.id)
                        .accessibilityHidden(true)
                }
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(hovering ? Color.ink : Color.inkTertiary)
            }
            .frame(width: 20, height: 20)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Dismiss")
    }
}

private struct CountdownRing: View {
    let center: ToastCenter
    let id: UUID

    var body: some View {
        let running = center.countdowns[id]?.isRunning ?? false
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { context in
            let fraction = center.fractionRemaining(for: id, at: context.date) ?? 0
            ZStack {
                Circle()
                    .stroke(Color.stroke, lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color.inkTertiary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(1)
        }
    }
}

/// Compact toast buttons: a filled iris capsule for the primary action, a quiet tinted label otherwise.
private struct ToastActionStyle: ButtonStyle {
    var isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        ToastActionBody(configuration: configuration, isPrimary: isPrimary)
    }
}

private struct ToastActionBody: View {
    let configuration: ButtonStyleConfiguration
    let isPrimary: Bool
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isPrimary ? Color.onAccent : Color.ink)
            .lineLimit(1)
            .padding(.horizontal, isPrimary ? 12 : 10)
            .frame(height: 26)
            .background {
                if isPrimary {
                    Capsule(style: .continuous)
                        .fill(Color.accentFill)
                        .overlay {
                            Capsule(style: .continuous)
                                .fill(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0)],
                                                     startPoint: .top, endPoint: .center))
                        }
                        .brightness(pressed ? -0.07 : (hovering ? 0.05 : 0))
                } else {
                    Capsule(style: .continuous)
                        .fill(pressed ? Color.pressed : (hovering ? Color.hover : Color.hover.opacity(0.9)))
                }
            }
            .scaleEffect(pressed ? 0.97 : 1)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(Theme.Motion.hover, value: hovering)
    }
}
