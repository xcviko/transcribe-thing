import SwiftUI

struct DoneStep: View {
    let model: OnboardingModel

    private var settings: AppSettings { model.ctx.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(title: "You’re set.", subtitle: nil)
                .padding(.bottom, 8)
            Text("Hold \(Text(model.pushToTalkLabel).fontWeight(.semibold).foregroundColor(.ink)) in any app to start talking.")
                .font(.system(size: 13.5))
                .foregroundStyle(.inkSecondary)
                .padding(.bottom, 16)

            FlowLayout(spacing: 6, lineSpacing: 6) {
                // Every chip reads label (secondary), then value (ink).
                SummaryChip {
                    Text("Model").foregroundStyle(.inkSecondary)
                    ModelChoiceIcon(choice: settings.lineup.main, parakeet: settings.parakeetEngine,
                                    color: settings.modelColors[settings.lineup.main], size: 18)
                    Text(settings.lineup.main.title(parakeet: settings.parakeetEngine))
                }
                SummaryChip {
                    Text("Push to talk").foregroundStyle(.inkSecondary)
                    ShortcutChips(shortcut: settings.shortcuts[.pushToTalk], size: .small)
                }
                SummaryChip {
                    Text("Hands-free").foregroundStyle(.inkSecondary)
                    ShortcutChips(shortcut: settings.shortcuts[.handsFree], size: .small)
                }
            }
            .padding(.bottom, 22)

            SectionHeader("Show the pill")
                .padding(.bottom, 8)
            HStack(spacing: 8) {
                ForEach(PillMode.allCases) { mode in
                    PillModeTile(mode: mode, isSelected: settings.pillMode == mode) {
                        settings.pillMode = mode
                    }
                }
            }
            .padding(.bottom, 16)

            VStack(spacing: 0) {
                prefRow("Open \(Brand.name) at login", symbol: "power",
                        isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                RowDivider(inset: 44)
                prefRow("Show \(Brand.name) in the Dock", symbol: "dock.rectangle",
                        isOn: Binding(get: { settings.showDockIcon }, set: { settings.showDockIcon = $0 }))
                RowDivider(inset: 44)
                prefRow("Play sounds", symbol: "speaker.wave.2.fill",
                        isOn: Binding(get: { settings.soundsEnabled }, set: { settings.soundsEnabled = $0 }))
            }
            .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1) }
            .cardShadow()

            if let error = model.openAtLoginError {
                StepNote(symbol: "exclamationmark.triangle.fill", tint: .warning, text: Text(error))
                    .padding(.top, 10)
                    .transition(.opacity)
            } else if model.openAtLogin && model.ctx.launchAtLogin.requiresApproval {
                StepNote(symbol: "person.badge.key.fill", tint: .accent,
                         text: Text("macOS wants your OK in Login Items before \(Brand.name) can open at login.")) {
                    Button("Open Login Items") { model.ctx.launchAtLogin.openLoginItemsSettings() }
                        .buttonStyle(QuietButtonStyle(tint: .accent, size: .small))
                        .padding(.leading, -8)
                        .frame(height: 20)
                }
                .padding(.top, 10)
                .transition(.opacity)
            }
        }
        .animation(Theme.Motion.fade, value: model.openAtLoginError)
    }

    private func prefRow(_ title: String, symbol: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.accent)
                .frame(width: 24, height: 24)
                .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.ink)
            Spacer(minLength: 8)
            Toggle(isOn: isOn) { EmptyView() }
                .toggleStyle(.appSwitch)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }
}

private struct SummaryChip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.ink)
            .padding(.leading, 10)
            .padding(.trailing, 9)
            .frame(height: 30)
            .background(Color.bgSurface, in: Capsule(style: .continuous))
            .overlay { Capsule(style: .continuous).ring(1).fill(Color.stroke, style: FillStyle(eoFill: true)) }
            .fixedSize()
    }
}

private struct PillModeTile: View {
    var mode: PillMode
    var isSelected: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            VStack(spacing: 7) {
                PillModeMiniScreen(mode: mode, compact: true)
                    .frame(height: 44)
                Text(mode.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accent : Color.ink)
                    .lineLimit(1)
            }
            .padding(7)
            .frame(maxWidth: .infinity)
            .background {
                shape.fill(Color.bgSurface)
                shape.fill(isSelected ? Color.accentSoft : (hovering ? Color.hover : .clear))
            }
            .overlay { shape.strokeBorder(isSelected ? Color.accent : Color.stroke, lineWidth: isSelected ? 1.5 : 1) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .animation(Theme.Motion.expand, value: isSelected)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Left-to-right wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: - Stage

/// Confetti, the transcribe-thing mark, and the pill saying hello the way it will on the desktop.
struct DoneStage: View {
    let model: OnboardingModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack {
                    StageGlow(color: .accent, radius: 150, opacity: 0.26)
                    StageGlow(color: .warm, radius: 90, opacity: 0.18)
                        .offset(x: 40, y: 30)
                    AppMark(size: 96)
                }
                .frame(height: 200)
                Text("\(Brand.name) is ready")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundStyle(.ink)
                    .padding(.top, 4)
                Spacer(minLength: 0)
                HelloTooltip(label: model.ctx.settings.shortcuts[.pushToTalk])
                    .padding(.bottom, 10)
                StageClock(paused: reduceMotion) { t in
                    StagePill(phase: .listening, level: 0.35 + 0.3 * HeroTimeline.voice(t * 0.7), time: reduceMotion ? 0 : t)
                }
                .frame(height: 40)
                .padding(.bottom, 46)
            }
            ConfettiBurst(origin: UnitPoint(x: 0.5, y: 0.34))
                .id(model.confettiBurst)
        }
    }
}

/// The dark tooltip the real pill shows on its first hello.
private struct HelloTooltip: View {
    var label: Shortcut?

    var body: some View {
        HStack(spacing: 5) {
            Text("Hold")
            HStack(spacing: 3) {
                ForEach(Array((label ?? .fn).keycaps.enumerated()), id: \.offset) { _, cap in
                    HStack(spacing: 2) {
                        if let symbol = cap.systemImage {
                            Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
                        }
                        Text(cap.label).font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 5)
                    .frame(height: 18)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            Text("anywhere to dictate")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.pillFill, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous).ring(0.75)
                .fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                      style: FillStyle(eoFill: true))
        }
        .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
    }
}
