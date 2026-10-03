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

/// Everything the floating panel draws: the pill (with its hover margin and tooltip) and the toast stack above it.
struct PillCanvasView: View {
    let model: PillModel
    let toasts: ToastCenter
    var regions: PillHitRegions?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsRestTooltip: Bool {
        guard model.isPresented, model.visiblePhase.isIdle, toasts.notices.isEmpty else { return false }
        return model.showsTooltip || model.isHelloActive
    }

    /// The Switch model hint over a long push-to-talk hold (the controller decides when).
    private var showsSwitchHint: Bool {
        model.isPresented && model.settings.showsPillHints && model.visiblePhase == .listening && model.showsTabHint
            && model.settings.shortcuts[.switchModel] != nil
    }

    /// Polish Selection's hint over a recording with text selected, and as it drops into the pill.
    private var showsSelectionHint: Bool {
        model.isPresented && model.settings.showsPillHints && model.selectionHint != .hidden
            && (model.visiblePhase.isRecording || model.selectionHint == .handoff)
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
        return model.isPresented && (chip || showsKeyHint || showsSelectionHint && model.visiblePhase.isRecording)
    }

    /// With no pill on screen (hidden until the next dictation, or Never mode) toasts drop into its slot, bottoms
    /// aligned, instead of hovering over an empty gap.
    static func toastBottomPadding(pillOnScreen: Bool, showsChip: Bool) -> CGFloat {
        guard pillOnScreen else { return PillCanvasMetrics.pillBottomInset }
        return PillCanvasMetrics.toastLift + (showsChip ? PillCanvasMetrics.chipLift : 0)
    }

    /// Toasts rise with the pill at once, and settle into its slot only once its exit has played out, so they
    /// never slide over the fading pill.
    private var slotAnimation: Animation {
        let move: Animation = reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.32, bounce: 0.15)
        guard !model.isPresented else { return move }
        return move.delay(reduceMotion ? PillMotion.reducedExitDuration : PillMotion.exitDuration)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ToastStack(center: toasts, pasteShortcut: model.settings.shortcuts[.pasteLast], regions: regions)
                .padding(.bottom, Self.toastBottomPadding(pillOnScreen: model.isPresented, showsChip: showsChip))
                .animation(slotAnimation, value: model.isPresented)
                .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.32, bounce: 0.15),
                           value: showsChip)
            pillArea
                .padding(.bottom, PillCanvasMetrics.pillBottomInset - PillMetrics.hoverMargin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .coordinateSpace(.named(PillCanvasMetrics.space))
    }

    private var pillArea: some View {
        PillView(model: model, context: .panel(regions))
            .overlay(alignment: .top) {
                if showsRestTooltip {
                    Group {
                        if model.isHelloActive {
                            PillHelloTooltip(model: model)
                        } else {
                            PillRestTooltip(model: model)
                        }
                    }
                        .fixedSize()
                        .offset(y: -(PillMetrics.tooltipHeight + 8))
                        .transition(tooltipTransition)
                        .allowsHitTesting(false)
                } else if showsKeyHint, let text = model.keyHint {
                    PillKeyHint(text: text)
                        .offset(y: -PillMetrics.chipLift)
                        .transition(tooltipTransition)
                        .allowsHitTesting(false)
                } else if showsSelectionHint {
                    // Handed off, it drops into the pill and dissolves while the pill becomes the polish.
                    let handoff = model.selectionHint == .handoff
                    PillSelectionHint(model: model)
                        .scaleEffect(handoff && !reduceMotion ? 0.6 : 1, anchor: .bottom)
                        .offset(y: handoff && !reduceMotion ? PillMetrics.chipGap : -PillMetrics.chipLift)
                        .opacity(handoff ? 0 : 1)
                        .transition(tooltipTransition)
                        .allowsHitTesting(false)
                } else if showsSwitchHint {
                    PillSwitchHint(model: model)
                        .offset(y: -PillMetrics.chipLift)
                        .transition(tooltipTransition)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.16), value: showsRestTooltip)
            .animation(.easeOut(duration: 0.2), value: showsSwitchHint)
            .animation(.easeOut(duration: 0.2), value: showsKeyHint)
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.1),
                       value: model.selectionHint)
            .padding(PillMetrics.hoverMargin)
            .contentShape(Rectangle())
            .onTapGesture {
                // Clicking the resting pill (or its hover margin) starts hands-free, like Wispr.
                if model.isPresented, model.visiblePhase.isIdle { model.onClick?() }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PillCanvasMetrics.space)) } action: { rect in
                regions?.setPill(rect)
            }
    }

    private var tooltipTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .opacity.combined(with: .offset(y: 4)).combined(with: .scale(scale: 0.96, anchor: .bottom))
    }
}
