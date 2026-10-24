import SwiftUI

enum PillCanvasMetrics {
    /// Fixed transparent canvas: room for the widest pill, the chip over it and two stacked cards with their text
    /// boxes full (Polish Selection's two answers: about 250 pt each), with their shadows. Clicks pass through
    /// everywhere but the pill and the cards, so the height costs nothing.
    static let size = CGSize(width: 480, height: 640)
    /// Canvas bottom → pill bottom; leaves room for the pill's shadow.
    static let pillBottomInset: CGFloat = 24
    /// Toasts sit 10 pt above the pill's tallest state, so they never move while the pill changes shape.
    static let toastLift: CGFloat = pillBottomInset + PillMetrics.maxHeight + 10
    /// While the model chip floats above the pill, toasts step up by its height and gap.
    static let chipLift: CGFloat = PillMetrics.chipLift
    static let space = "tt.pill.canvas"
}

/// Interactive rectangles in canvas coordinates (top-left origin), reported by the views so the controller
/// can make everything else click-through.
@MainActor
final class PillHitRegions {
    private(set) var pill: CGRect?
    private(set) var controls: [PillControl: CGRect] = [:]
    /// The model chip above the pill, while it opens the model menu (hands-free).
    private(set) var chip: CGRect?
    private(set) var toasts: [String: CGRect] = [:]
    var onChange: (() -> Void)?

    func setPill(_ rect: CGRect?) {
        guard rect != pill else { return }
        pill = rect
        onChange?()
    }

    func setControl(_ control: PillControl, rect: CGRect?) {
        guard controls[control] != rect else { return }
        controls[control] = rect
        onChange?()
    }

    func setChip(_ rect: CGRect?) {
        guard rect != chip else { return }
        chip = rect
        onChange?()
    }

    func setToast(_ key: String, rect: CGRect?) {
        guard toasts[key] != rect else { return }
        toasts[key] = rect
        onChange?()
    }
}

/// Everything the floating panel draws: the pill (with its hover margin and tooltip) and the toasts, which grow out of
/// it. With nothing on the pill, the newest toast takes the pill's place and the pill waits under it; while a
/// dictation is on the pill, the toasts stand above it.
struct PillCanvasView: View {
    let model: PillModel
    let toasts: ToastCenter
    var regions: PillHitRegions?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The pill's area as last laid out, handed back to the hit regions when a toast uncovers it.
    @State private var pillRect: CGRect?
    /// The last toast is closing back into the pill's slot: the pill waits under it until it's done.
    @State private var closingIntoSlot = false
    /// There were toasts as of the last update. In the update that takes the last one away it's still true, so the
    /// resting pill stays under it from that very update on (`closingIntoSlot` takes over right after): set a pass
    /// late, the pill showed whole over the closing toast, then left again.
    @State private var hadToasts = false

    private var showsRestTooltip: Bool {
        guard model.isPresented, model.visiblePhase.isIdle, toasts.notices.isEmpty else { return false }
        return model.showsTooltip || model.isHelloActive
    }

    /// The Switch model hint over a long push-to-talk hold (the controller decides when).
    private var showsSwitchHint: Bool {
        model.isPresented && model.settings.showsPillHints && model.visiblePhase == .listening && model.showsTabHint
            && model.settings.shortcuts[.switchModel] != nil
    }

    /// A word about a key that did nothing (`PillModel.keyHint`), over a dictation, while hints above the pill are on.
    private var showsKeyHint: Bool {
        model.isPresented && model.settings.showsPillHints && model.keyHint != nil && model.visiblePhase.isRecording
    }

    /// The model chip, or a hint in its place, floats above the pill: toasts make room for it.
    private var showsChip: Bool {
        let chip = model.isPillAllowed && model.showsChip
            && (model.visiblePhase.isRecording || model.visiblePhase == .processing
                || model.visiblePhase == .error && model.errorMessage != nil)
        return model.isPresented && (chip || showsKeyHint)
    }

    /// The pill keeps its place under the toasts while it shows a dictation (or the hello); otherwise (at rest, hidden
    /// until the next dictation, or in Never mode) the newest toast takes it.
    private var pillHoldsSlot: Bool {
        model.isPresented && (!model.visiblePhase.isIdle || model.isHelloActive)
    }

    /// The resting pill is under a toast that took its place: it steps aside, and comes back (at once) as the last
    /// toast closes back into its slot (`slotHandover`).
    private var pillCovered: Bool {
        model.isPresented && !pillHoldsSlot && (!toasts.notices.isEmpty || hadToasts || closingIntoSlot)
    }

    /// How long the last toast takes to close back into the pill's slot: the duration of `ToastStack`'s closing spring.
    static let toastClosing: TimeInterval = 0.3
    /// How long the resting pill waits under the last toast closing into its slot: until the card has closed into the
    /// pill's own shape (`ToastOrigin.pillComesBack`), so the pill takes over from it with no seam. Sooner, the card
    /// still wider than the pill showed around it as a dark halo.
    /// The spring is within a point of the pill by then; the card itself is dropped later (`ToastStack`), so the two
    /// overlap and never leave the slot empty.
    static let slotHandover: TimeInterval = toastClosing + 0.05

    /// Toasts stand above a pill that holds its place, and in its slot, bottoms aligned, when it doesn't.
    static func toastBottomPadding(pillOnScreen: Bool, showsChip: Bool) -> CGFloat {
        guard pillOnScreen else { return PillCanvasMetrics.pillBottomInset }
        return PillCanvasMetrics.toastLift + (showsChip ? PillCanvasMetrics.chipLift : 0)
    }

    /// Where the newest toast grows out of: the pill's slot, or the dictation's pill under the toasts.
    private var toastOrigin: ToastOrigin {
        guard pillHoldsSlot else { return ToastOrigin(pillComesBack: model.isPresented) }
        let pill = PillView(model: model, context: .panel(nil)).visual.size
        let lift = Self.toastBottomPadding(pillOnScreen: true, showsChip: showsChip) - PillCanvasMetrics.pillBottomInset
        return ToastOrigin(size: pill, drop: lift)
    }

    /// Toasts stand above the pill the moment it shows in their slot (it's there at once, so a toast still rising
    /// out of the slot was drawn under it), and settle into the slot only once its exit has played out, so they never
    /// slide over the fading pill.
    private var slotAnimation: Animation? {
        guard !pillHoldsSlot else { return nil }
        let move: Animation = reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.32, bounce: 0.15)
        return move.delay(reduceMotion ? PillMotion.reducedExitDuration : PillMotion.exitDuration)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ToastStack(center: toasts, regions: regions, origin: toastOrigin)
                .padding(.bottom, Self.toastBottomPadding(pillOnScreen: pillHoldsSlot, showsChip: showsChip))
                .animation(slotAnimation, value: pillHoldsSlot)
                .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.32, bounce: 0.15),
                           value: showsChip)
            pillArea
                .padding(.bottom, PillCanvasMetrics.pillBottomInset - PillMetrics.hoverMargin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .coordinateSpace(.named(PillCanvasMetrics.space))
        .onChange(of: toasts.notices.isEmpty, initial: true) { old, empty in
            if old != empty { closingIntoSlot = empty }
            hadToasts = !empty
        }
        .task(id: closingIntoSlot) {
            guard closingIntoSlot else { return }
            try? await Task.sleep(for: .seconds(Self.slotHandover))
            closingIntoSlot = false
        }
    }

    /// What floats over the pill, in the chip's place, one at a time.
    private var hint: PillHint? {
        if showsRestTooltip { return .rest(hello: model.isHelloActive) }
        if showsKeyHint, let text = model.keyHint { return .key(text) }
        if showsSwitchHint { return .switchModel }
        return nil
    }

    private var pillArea: some View {
        PillView(model: model, context: .panel(regions), covered: pillCovered)
            .overlay(alignment: .top) {
                // Live while it fades (`PillLingering`): a hint going as the pill changes size (the Switch model hint
                // as fn Space widens the pill into hands-free) stays over the pill's middle, where the pill's corner
                // would otherwise have left it.
                PillLingering(value: hint, insertion: tooltipTransition, fadeOut: .easeOut(duration: 0.18),
                              fadeIn: .easeOut(duration: 0.18)) { hint, _ in
                    hintView(hint)
                        .allowsHitTesting(false)
                }
            }
            .padding(PillMetrics.hoverMargin)
            .contentShape(Rectangle())
            .onTapGesture {
                // Clicking the resting pill (or its hover margin) starts hands-free, like Wispr; clicking the dashed one
                // (a click away held its paste) takes that click back, while its text is still on the way.
                if model.isPresented, model.visiblePhase.isIdle || model.holdsPaste && model.phase == .processing {
                    model.onClick?()
                }
            }
            // Under a toast, the toast takes the clicks and the pointer.
            .allowsHitTesting(!pillCovered)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PillCanvasMetrics.space)) } action: { rect in
                pillRect = rect
                regions?.setPill(pillCovered ? nil : rect)
            }
            .onChange(of: pillCovered) { _, covered in
                regions?.setPill(covered ? nil : pillRect)
            }
    }

    @ViewBuilder
    private func hintView(_ hint: PillHint) -> some View {
        switch hint {
        case .rest(let hello):
            Group {
                if hello {
                    PillHelloTooltip(model: model)
                } else {
                    PillRestTooltip(model: model)
                }
            }
                .fixedSize()
                .offset(y: -(PillMetrics.tooltipHeight + 8))
        case .key(let text):
            PillKeyHint(text: text)
                .offset(y: -PillMetrics.chipLift)
        case .switchModel:
            PillSwitchHint(model: model)
                .offset(y: -PillMetrics.chipLift)
        }
    }

    private var tooltipTransition: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeInOut(duration: 0.15)) }
        return .opacity.combined(with: .offset(y: 4)).combined(with: .scale(scale: 0.96, anchor: .bottom))
            .animation(.easeOut(duration: 0.18))
    }
}

/// What floats over the pill in the chip's place (`PillCanvasView`), as it was when it went, so it leaves as it stood.
enum PillHint: Equatable {
    /// "Hold fn to dictate", or the one-time hello.
    case rest(hello: Bool)
    /// A key that did nothing (`PillModel.keyHint`).
    case key(String)
    case switchModel
}
