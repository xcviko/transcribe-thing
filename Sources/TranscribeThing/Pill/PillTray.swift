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
    /// How far left of its place each button starts as it fans out, per place in the row.
    static let fanOffset: CGFloat = 9
    /// Between one button's spring and the next one's as the tray opens.
    static let stagger: TimeInterval = 0.045
}

/// Polish, Translate and Send for the dictation a pill shows, in a small capsule of the pill's own black beside it, out
/// while the pointer is on the pill or the tray (`PillModel.openTray`). Opening, the capsule grows out of the pill's
/// end and the three round buttons fan out of it one after another on the pill's springs; closing, they fold back the
/// other way, quicker. A button that's on is a white disc with a black glyph, as hands-free's finish is, and the pill
/// itself shows the same glyph inside (the wand, Translate's glyph, the plane). One that can't change this dictation
/// (Polish and Translate on Parakeet while it's processed) is dimmed and takes no click. The tray sits at the pill's
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
        HStack(spacing: PillTrayMetrics.spacing) {
            ForEach(Array(PillToggle.allCases.enumerated()), id: \.element) { index, toggle in
                PillTrayButtonView(model: model, button: PillTrayButton(owner: owner, toggle: toggle), state: state,
                                   isLive: isOpen, regions: regions)
                    .scaleEffect(isOpen || reduceMotion ? 1 : 0.4)
                    .offset(x: isOpen || reduceMotion ? 0 : -CGFloat(index + 1) * PillTrayMetrics.fanOffset)
                    .opacity(isOpen ? 1 : 0)
                    .animation(buttonAnimation(index), value: isOpen)
            }
        }
        .padding(PillTrayMetrics.inset)
        .background {
            PillCapsule()
                .scaleEffect(x: isOpen || reduceMotion ? 1 : 0.35, y: isOpen || reduceMotion ? 1 : 0.8,
                             anchor: .leading)
                .opacity(isOpen ? 1 : 0)
                .animation(capsuleAnimation, value: isOpen)
        }
        .fixedSize()
        .contentShape(Capsule(style: .continuous))
        // Its gaps take a click too: nothing reaches the pill or the app under it.
        .onTapGesture {}
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

    /// Out one after another on a bouncy spring, back the other way and quicker.
    private func buttonAnimation(_ index: Int) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        let count = PillToggle.allCases.count
        if isOpen {
            return .spring(duration: 0.34, bounce: 0.34).delay(0.03 + Double(index) * PillTrayMetrics.stagger)
        }
        return .easeIn(duration: 0.1).delay(Double(count - 1 - index) * 0.02)
    }

    private var capsuleAnimation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        return isOpen ? .spring(duration: 0.3, bounce: 0.22) : .easeIn(duration: 0.14).delay(0.04)
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
    private var hovered: Bool { isLive && isEnabled && model.hoveredTrayButton == button }
    private var showsTooltip: Bool { isLive && model.trayTooltip == button }

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
                    .foregroundStyle(isOn ? Color.black : .white.opacity(isEnabled ? (hovered ? 1 : 0.78) : 0.28))
                    .symbolEffect(.bounce, options: .speed(1.4), value: reduceMotion ? false : isOn)
            }
            .frame(width: PillTrayMetrics.buttonSize, height: PillTrayMetrics.buttonSize)
            .scaleEffect(hovered && !reduceMotion ? 1.08 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.26, bounce: 0.4), value: isOn)
        .overlay(alignment: .top) {
            PillLingering(value: showsTooltip ? button : nil,
                          insertion: .opacity.combined(with: .offset(y: 3)).animation(.easeOut(duration: 0.14)),
                          fadeOut: .easeOut(duration: 0.14), fadeIn: .easeOut(duration: 0.14)) { _, _ in
                PillTrayTooltip(toggle: toggle, isOn: isOn, isEnabled: isEnabled)
                    .fixedSize()
                    .offset(y: -(PillMetrics.tooltipHeight + PillTrayMetrics.inset + 7))
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
        .accessibilityHint(isEnabled ? "" : PillTrayTooltip.reason(toggle))
    }
}

/// "Polish · On" over a tray button; a dimmed one says why: "Translate · Gemini only".
struct PillTrayTooltip: View {
    let toggle: PillToggle
    let isOn: Bool
    let isEnabled: Bool

    /// Why a dimmed button can't change the dictation.
    static func reason(_ toggle: PillToggle) -> String {
        toggle == .send ? "Its text waits on a card" : "Gemini only"
    }

    var body: some View {
        PillTooltipBubble {
            Text(toggle.title)
            Text("·").foregroundStyle(.white.opacity(0.4))
            Text(isEnabled ? (isOn ? "On" : "Off") : Self.reason(toggle))
                .foregroundStyle(.white.opacity(0.6))
        }
        .accessibilityElement(children: .combine)
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
                    .transition(rowTransition)
            }
        }
        .animation(PillStackMetrics.animation(reduceMotion: reduceMotion), value: items.map(\.key))
        .animation(PillStackMetrics.animation(reduceMotion: reduceMotion), value: more)
        .onChange(of: items.map(\.key), initial: true) { old, new in
            for key in Set(old).subtracting(new) { regions?.setStackPill(key, rect: nil) }
        }
    }

    /// In from the bottom pill's place, rising; out where it stands, as the pill leaves.
    private var rowTransition: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .asymmetric(
            insertion: .offset(y: PillStackMetrics.pillHeight + PillStackMetrics.gap)
                .combined(with: .opacity)
                .animation(.spring(duration: 0.38, bounce: 0.22)),
            removal: .opacity.combined(with: .scale(scale: 0.86, anchor: .bottom))
                .animation(.easeOut(duration: PillMotion.exitDuration)))
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
