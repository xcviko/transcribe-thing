import SwiftUI

// MARK: - Tray

enum PillTrayMetrics {
    /// Between the pill's end and the tray.
    static let gap: CGFloat = 6
    static let buttonSize: CGFloat = 20
    static let spacing: CGFloat = 2
    /// Around the buttons, inside the tray's capsule.
    static let inset: CGFloat = 3
    static let height: CGFloat = buttonSize + 2 * inset
    static let width: CGFloat = 2 * inset + CGFloat(PillToggle.allCases.count) * buttonSize
        + CGFloat(PillToggle.allCases.count - 1) * spacing
    /// How far left of its place the tray starts as it comes out, and how small (from its leading edge).
    static let slide: CGFloat = 10
    static let startScale: CGFloat = 0.8
    /// Between the tray and a button's shortcut over it (the pointer on it), and that label's height.
    static let keyGap: CGFloat = 4
    static let keyLabelHeight: CGFloat = 14
}

/// Send, Polish and Translate for the dictation a pill shows, in a small capsule of the pill's own black beside it, with
/// no edge, out while the pointer is on the pill or the tray (`PillModel.openTray`), and while the talk key is down over
/// the dictation on its way (`PillTrayState.isAimed`). The whole tray comes out at once:
/// it fades in while it slides in from the pill's side and grows from its leading edge on a bouncy spring, and goes
/// back the same way. A button that's on is a white disc with a black glyph, as hands-free's finish is, and the pill
/// itself shows the same glyph inside (the wand, Translate's glyph, the plane). One that can't change this dictation
/// (Polish and Translate on Parakeet while it's processed) is dimmed and takes no click. The pointer over a button
/// puts a faint disc under it at once, with no animation, and its shortcut over it after a short dwell
/// (`PillTrayState.keys`). The tray sits at the pill's
/// height, so it covers no more of what's above the Dock than the pill does.
///
/// It stays laid out while closed, invisible and out of the hit regions, so opening never waits for a layout pass and
/// VoiceOver reaches its buttons without a hover.
struct PillTray: View {
    /// The bottom pill's model: hover, tooltips and the click go through it.
    let model: PillModel
    let owner: PillTrayOwner
    let state: PillTrayState
    let isOpen: Bool
    var regions: PillHitRegions?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame: CGRect?

    var body: some View {
        let shown = isOpen || reduceMotion
        HStack(spacing: PillTrayMetrics.spacing) {
            ForEach(PillToggle.allCases, id: \.self) { toggle in
                PillTrayButtonView(model: model, button: PillTrayButton(owner: owner, toggle: toggle), state: state,
                                   isLive: isOpen, regions: regions)
            }
        }
        .padding(PillTrayMetrics.inset)
        .background { PillCapsule(drawsEdge: false) }
        .fixedSize()
        .contentShape(Capsule(style: .continuous))
        // Its gaps take a click too: nothing reaches the pill or the app under it.
        .onTapGesture {}
        .animation(slideAnimation) {
            $0.scaleEffect(shown ? 1 : PillTrayMetrics.startScale, anchor: .leading)
                .offset(x: shown ? 0 : -PillTrayMetrics.slide)
        }
        .animation(fadeAnimation) { $0.opacity(isOpen ? 1 : 0) }
        .allowsHitTesting(isOpen)
        .environment(\.colorScheme, .dark)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PillCanvasMetrics.space)) } action: { rect in
            frame = rect
            regions?.setTray(owner, rect: isOpen ? rect : nil)
        }
        .onChange(of: isOpen) { _, open in regions?.setTray(owner, rect: open ? frame : nil) }
        .onDisappear { regions?.setTray(owner, rect: nil) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dictation options")
    }

    /// In and back on a bouncy spring: a little past its place, then settled.
    private var slideAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.22, bounce: 0.38)
    }

    private var fadeAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.14)
    }
}

/// One round button of the tray: its glyph, a white disc when it's on, a faint disc under the pointer. Hover comes from
/// the controller, which tracks the pointer for the never-key panel (`PillModel.hoveredTrayButton`).
private struct PillTrayButtonView: View {
    let model: PillModel
    let button: PillTrayButton
    let state: PillTrayState
    /// The tray is out: it reports its region and shows its tooltip.
    var isLive = true
    var regions: PillHitRegions?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame: CGRect?

    private var toggle: PillToggle { button.toggle }
    private var isOn: Bool { state.isOn(toggle) }
    private var isEnabled: Bool { state.isEnabled(toggle) }
    /// The pointer is on it: a faint disc under it, there and gone at once.
    private var hovered: Bool { isLive && isEnabled && model.hoveredTrayButton == button }
    /// The pointer has been on it a moment: its shortcut shows over it.
    private var showsHint: Bool { isLive && isEnabled && model.trayHint == button && state.keys[toggle] != nil }

    var body: some View {
        Button {
            model.onToggle?(toggle, state.dictation)
        } label: {
            ZStack {
                Circle()
                    .fill(isOn ? PillPalette.finish : .white.opacity(hovered ? 0.16 : 0))
                    .brightness(isOn && hovered ? 0.04 : 0)
                Image(systemName: toggle.symbolName)
                    .font(.system(size: toggle == .translate ? 9 : 10, weight: .semibold))
                    .foregroundStyle(isOn ? Color.black : .white.opacity(isEnabled ? (hovered ? 1 : 0.9) : 0.28))
                    .symbolEffect(.bounce, options: .speed(1.4), value: reduceMotion ? false : isOn)
            }
            .frame(width: PillTrayMetrics.buttonSize, height: PillTrayMetrics.buttonSize)
            .contentShape(Circle())
            // The hover is never animated, whatever else animates as the pointer comes or goes.
            .transaction(value: hovered) { $0.animation = nil }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.26, bounce: 0.4), value: isOn)
        .overlay(alignment: .top) {
            // Its shortcut, over it, above the tray, after a short dwell, rising in and fading out as tooltips do. One
            // that comes straight over from the next button, or goes to it, is there or gone at once.
            let carriesOver = model.trayHintCarriesOver
            PillLingering(value: showsHint ? state.keys[toggle] : nil,
                          insertion: carriesOver ? .identity
                              : .opacity.combined(with: .offset(y: 3)).animation(.easeOut(duration: 0.14)),
                          fadeOut: model.trayHint == nil ? .easeOut(duration: 0.14) : nil,
                          fadeIn: carriesOver ? nil : .easeOut(duration: 0.14)) { key, _ in
                PillTrayKeyLabel(key: key)
                    .fixedSize()
                    .offset(y: -(PillTrayMetrics.keyLabelHeight + PillTrayMetrics.inset + PillTrayMetrics.keyGap))
                    .allowsHitTesting(false)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PillCanvasMetrics.space)) } action: { rect in
            frame = rect
            regions?.setTrayButton(button, rect: isLive ? rect : nil)
        }
        .onChange(of: isLive) { _, live in regions?.setTrayButton(button, rect: live ? frame : nil) }
        .onDisappear { regions?.setTrayButton(button, rect: nil) }
        .accessibilityLabel(toggle.title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(isEnabled ? (state.keys[toggle] ?? "") : PillTrayState.reason(toggle))
    }
}

/// A tray button's shortcut over it while the pointer is on it: "fn ↩", "fn P", "fn T", on a small keycap of the
/// pill's black with its hairline, so it reads on light and dark apps alike.
struct PillTrayKeyLabel: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 4)
            .frame(minWidth: PillTrayMetrics.keyLabelHeight, minHeight: PillTrayMetrics.keyLabelHeight)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(PillPalette.fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(PillPalette.hairline, lineWidth: 1)
                    }
            }
            .environment(\.colorScheme, .dark)
            .accessibilityHidden(true)
    }
}

// MARK: - Stack

enum PillStackMetrics {
    /// Between two stacked pills, and between the nearest one and the bottom pill's tallest state.
    static let gap: CGFloat = 6
    /// A stacked pill is always processing: the push-to-talk height.
    static let pillHeight: CGFloat = PillMetrics.listeningSize.height
    /// How many stacked pills show; older ones fold into "+N" on top.
    static let shownLimit = 3
    static let moreHeight: CGFloat = 18
    /// From the nearest stacked pill down to the bottom pill: the bottom pill's tallest state and a gap.
    static let descent: CGFloat = PillMetrics.maxHeight + gap

    /// How tall `count` stacked pills stand, their gaps and "+N" included.
    static func height(for count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let shown = min(count, shownLimit)
        return CGFloat(shown) * (pillHeight + gap) + (count > shownLimit ? moreHeight + gap : 0)
    }

    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.36, bounce: 0.2)
    }
}

/// Dictations still on their way while a newer one is on the bottom pill (recording, or itself on its way): each on its
/// own pill, the newest nearest, the oldest on top, so they read in the order their text will come. Each shows its own
/// state as the bottom pill would (its count, its glyphs, its model's ring, its dashed edge) and has its own tray. A
/// dictation the bottom pill hands up rises out of it; one that's pasted fades where it stands and the pills above
/// settle down into its place. Past `PillStackMetrics.shownLimit` the oldest fold into "+N" on top.
struct PillStack: View {
    let model: PillModel
    var regions: PillHitRegions?
    /// The bottom pill holds its place (a dictation is on it) and the pill mode shows pills at all.
    var isShown = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let items = isShown ? model.stack : []
        let shown = Array(items.prefix(PillStackMetrics.shownLimit))
        let more = items.count - shown.count
        VStack(spacing: PillStackMetrics.gap) {
            if more > 0 {
                PillStackMore(count: more)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottom)))
            }
            ForEach(shown.reversed(), id: \.key) { item in
                PillStackRow(parent: model, item: item, regions: regions)
                    .transition(rowTransition(item.key))
            }
        }
        .animation(PillStackMetrics.animation(reduceMotion: reduceMotion), value: items.map(\.key))
        .animation(PillStackMetrics.animation(reduceMotion: reduceMotion), value: more)
        .onChange(of: items.map(\.key), initial: true) { old, new in
            for key in Set(old).subtracting(new) { regions?.setStackPill(key, rect: nil) }
        }
    }

    /// In from the bottom pill's place, rising; out where it stands, as the pill leaves, or down onto the bottom pill
    /// when it's the one coming down to it (`PillModel.descentKey`).
    private func rowTransition(_ key: UUID) -> AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .asymmetric(
            insertion: .offset(y: PillStackMetrics.pillHeight + PillStackMetrics.gap)
                .combined(with: .opacity)
                .animation(.spring(duration: 0.38, bounce: 0.22)),
            removal: .modifier(active: PillStackRowExit(model: model, key: key, isGone: true),
                               identity: PillStackRowExit(model: model, key: key, isGone: false))
                .animation(.easeOut(duration: PillMotion.exitDuration)))
    }
}

/// A stacked pill leaving: fading where it stands as it shrinks a little, or, coming down to the bottom pill (the one
/// there was canceled), sliding down onto it as it fades, while the bottom pill comes in under it. Which one is read as
/// it leaves, from the model.
private struct PillStackRowExit: ViewModifier {
    let model: PillModel
    let key: UUID
    let isGone: Bool

    func body(content: Content) -> some View {
        let descends = model.descentKey == key
        content
            .opacity(isGone ? 0 : 1)
            .scaleEffect(isGone && !descends ? 0.86 : 1, anchor: .bottom)
            .offset(y: isGone && descends ? PillStackMetrics.descent : 0)
    }
}

/// One stacked pill: its own pill model draws it (`PillModel.stackModels`), with its tray beside it. A click on a
/// dashed one takes its click away back.
private struct PillStackRow: View {
    let parent: PillModel
    let item: PillStackItem
    var regions: PillHitRegions?

    var body: some View {
        if let child = parent.stackModels[item.key] {
            let owner = PillTrayOwner.stacked(item.key)
            PillView(model: child)
                .contentShape(Capsule(style: .continuous))
                .onTapGesture { parent.onStackClick?(item.key) }
                .overlay(alignment: .trailing) {
                    PillTray(model: parent, owner: owner, state: item.tray, isOpen: parent.showsTray(owner),
                             regions: regions)
                        .alignmentGuide(.trailing) { $0[.leading] - PillTrayMetrics.gap }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PillCanvasMetrics.space)) } action: { rect in
                    // With its hover margin to the sides, and half the gap above and below.
                    regions?.setStackPill(item.key, rect: rect.insetBy(dx: -PillMetrics.hoverMargin,
                                                                      dy: -PillStackMetrics.gap / 2))
                }
                .onDisappear { regions?.setStackPill(item.key, rect: nil) }
        }
    }
}

/// "+2" on top of the stack: older dictations still on their way that don't get a pill of their own.
private struct PillStackMore: View {
    let count: Int

    var body: some View {
        let shape = Capsule(style: .continuous)
        Text("+\(count)")
            .font(PillMetrics.captionFont)
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 8)
            .frame(height: PillStackMetrics.moreHeight)
            .background {
                shape.fill(PillPalette.fill)
                    .overlay { shape.ring(1).fill(PillPalette.hairline, style: FillStyle(eoFill: true)) }
                    .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(count) more \(count == 1 ? "dictation" : "dictations") on the way")
    }
}
