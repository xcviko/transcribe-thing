import SwiftUI

/// Five-step first-run flow (wispr-ux.md §4, SPEC §7.1; shortcuts and practice share one step). 820×600, copy on
/// the left, a live stage on the right.
struct OnboardingView: View {
    @State private var model: OnboardingModel

    init(env: AppEnvironment) {
        _model = State(initialValue: OnboardingModel(context: OnboardingContext(env: env)))
    }

    init(model: OnboardingModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        OnboardingRoot(model: model)
    }
}

enum OnboardingLayout {
    static let window = CGSize(width: 820, height: 600)
    static let footerHeight: CGFloat = 76
    static let stageInset: CGFloat = 16
    static let stageWidth: CGFloat = 392
    static let leading: CGFloat = 44
    static let columnTrailing: CGFloat = 32
    static var bodyHeight: CGFloat { window.height - footerHeight }
    static var stageHeight: CGFloat { bodyHeight - stageInset }
    static var columnWidth: CGFloat { window.width - stageWidth - stageInset }
    /// Leaves the traffic lights their own row.
    static let segmentsTop: CGFloat = 50
}

private struct OnboardingRoot: View {
    let model: OnboardingModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ctx = model.ctx
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                column
                if model.step.usesStage {
                    stage
                        .transition(.opacity.combined(with: .offset(x: 24)))
                }
            }
            .frame(width: OnboardingLayout.window.width, height: OnboardingLayout.bodyHeight, alignment: .topLeading)
            OnboardingFooter(model: model)
                .frame(height: OnboardingLayout.footerHeight)
        }
        .frame(width: OnboardingLayout.window.width, height: OnboardingLayout.window.height)
        .background(Color.bgCanvas)
        .ignoresSafeArea()
        .shortcutRecorderHost(hotkeys: ctx.hotkeys, settings: ctx.settings)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.42, bounce: 0.12), value: model.step)
        .onAppear { model.attach() }
        .onDisappear { model.detach() }
        .onHover { model.isPointerInside = $0 }
        .onChange(of: ctx.permissions.microphone) { model.permissionsChanged() }
        .onChange(of: ctx.permissions.accessibility) { model.permissionsChanged() }
        .onChange(of: ctx.pillModel.phase) { old, new in model.pillPhaseChanged(from: old, to: new) }
        .onChange(of: ctx.history.entries.first) { model.historyChanged() }
        .onChange(of: ctx.settings.onboardingStep) { _, stored in model.externalStepChanged(stored) }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgressSegments(current: model.step) { model.go(to: $0) }
                .padding(.top, OnboardingLayout.segmentsTop)
            ZStack(alignment: .topLeading) {
                stepColumn
                    .id(model.step)
                    .transition(columnTransition)
            }
            .padding(.top, 26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.leading, OnboardingLayout.leading)
        .padding(.trailing, model.step.usesStage ? OnboardingLayout.columnTrailing : OnboardingLayout.stageInset)
        .frame(width: model.step.usesStage ? OnboardingLayout.columnWidth : OnboardingLayout.window.width,
               height: OnboardingLayout.bodyHeight, alignment: .topLeading)
    }

    private var stage: some View {
        OnboardingStage {
            ZStack {
                stepStage
                    .id(model.step)
                    .transition(stageTransition)
            }
        }
        .frame(width: OnboardingLayout.stageWidth, height: OnboardingLayout.stageHeight)
        .padding(.top, OnboardingLayout.stageInset)
    }

    @ViewBuilder private var stepColumn: some View {
        switch model.step {
        case .welcome: WelcomeStep(model: model)
        case .permissions: PermissionsStep(model: model)
        case .model: ModelStep(model: model)
        case .tryIt: TryItStep(model: model)
        case .done: DoneStep(model: model)
        }
    }

    @ViewBuilder private var stepStage: some View {
        switch model.step {
        case .welcome: WelcomeStage(shortcut: model.ctx.settings.shortcuts[.pushToTalk])
        case .permissions: PermissionsStage(model: model)
        case .model: EmptyView()
        case .tryIt: PracticeChat(model: model)
        case .done: DoneStage(model: model)
        }
    }

    private var columnTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let distance: CGFloat = model.movingForward ? 28 : -28
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: distance)),
            removal: .opacity.combined(with: .offset(x: -distance)))
    }

    private var stageTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97))
    }
}

// MARK: - Progress

struct ProgressSegments: View {
    var current: OnboardingStep
    var onSelect: (OnboardingStep) -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases) { step in
                    segment(step)
                }
            }
            Text("\(current.rawValue + 1) of \(OnboardingStep.allCases.count)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.inkTertiary)
                .contentTransition(.numericText(value: Double(current.rawValue)))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count), \(current.title)")
    }

    private func segment(_ step: OnboardingStep) -> some View {
        let isCurrent = step == current
        let isDone = step < current
        return Capsule(style: .continuous)
            .fill(isCurrent ? Color.accent : (isDone ? Color.accent.opacity(0.45) : Color.ink.opacity(0.12)))
            .frame(width: isCurrent ? 28 : 16, height: 4)
            .contentShape(Rectangle().inset(by: -6))
            .onTapGesture { if isDone { onSelect(step) } }
            .help(isDone ? "Back to \(step.title)" : "")
    }
}

// MARK: - Footer

private struct OnboardingFooter: View {
    let model: OnboardingModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            if model.step.previous != nil {
                Button {
                    model.goBack()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Back")
                    }
                }
                .buttonStyle(QuietButtonStyle(tint: .inkSecondary, size: .regular))
                .transition(.opacity)
            }
            Spacer(minLength: 0)
            if model.canSkipAccessibility {
                Button(model.skipAccessibilityArmed ? "Skip Anyway" : "Skip for Now") {
                    model.skipAccessibility()
                }
                .buttonStyle(QuietButtonStyle(tint: .inkSecondary, size: .regular))
                .transition(.opacity)
            }
            primaryButton
        }
        .padding(.leading, OnboardingLayout.leading - 8)
        .padding(.trailing, OnboardingLayout.stageInset + 4)
        .animation(Theme.Motion.fade, value: model.canSkipAccessibility)
    }

    @ViewBuilder private var primaryButton: some View {
        let practiceSkip = model.step == .tryIt && !model.practiceStarted
        let pulses = !reduceMotion
        let button = Button {
            model.primaryAction()
        } label: {
            Text(model.primaryTitle)
                .frame(minWidth: 96)
                .contentTransition(.interpolate)
        }
        .keyboardShortcut(model.primaryUsesReturn ? .defaultAction : nil)
        .disabled(!model.canContinue)
        .keyframeAnimator(initialValue: 1.0, trigger: model.continuePulse) { content, scale in
            content.scaleEffect(pulses ? scale : 1)
        } keyframes: { _ in
            SpringKeyframe(1.07, duration: 0.18, spring: .snappy)
            SpringKeyframe(1.0, duration: 0.34, spring: .bouncy)
        }
        if practiceSkip {
            button.buttonStyle(SecondaryButtonStyle(size: .large))
        } else {
            button.buttonStyle(PrimaryButtonStyle(size: .large))
        }
    }
}

// MARK: - Shared step pieces

/// Serif step title + body, the top of every column.
struct StepHeader: View {
    var title: String
    var subtitle: String?
    var titleSize: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: titleSize, weight: .semibold, design: .serif))
                .tracking(-0.4)
                .foregroundStyle(.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13.5))
                    .lineSpacing(3)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Small inline note (hints, warnings) inside a step column.
struct StepNote<Actions: View>: View {
    var symbol: String
    var tint: Color
    var text: Text
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 6) {
                text
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(tint.opacity(0.16), lineWidth: 1)
        }
    }
}

extension StepNote where Actions == EmptyView {
    init(symbol: String, tint: Color, text: Text) {
        self.init(symbol: symbol, tint: tint, text: text) { EmptyView() }
    }
}

/// Inline key chips inside running copy: "Hold [fn], answer Alex, then let go."
struct InlineKeys: View {
    var shortcut: Shortcut?

    var body: some View {
        ShortcutChips(shortcut: shortcut, size: .small)
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
    }
}
