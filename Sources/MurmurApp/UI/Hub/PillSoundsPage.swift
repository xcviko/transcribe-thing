import SwiftUI

/// Live pill preview, when the pill shows, "Hide for 1 hour", and sound settings.
struct PillSoundsPage: View {
    @Environment(HubContext.self) private var hub
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        HubPage("Pill & Sounds", subtitle: "How Murmur looks and sounds while you dictate.") {
            PillPreviewStage()
            HubGroup("Show the pill") {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(PillMode.allCases) { mode in
                        PillModeTile(mode: mode, isSelected: settings.pillMode == mode) {
                            withAnimation(Theme.Motion.snappy) { settings.pillMode = mode }
                        }
                    }
                }
                hideForAnHour
                    .padding(.top, 4)
            }
            HubGroup("Sounds") {
                SettingsGroup {
                    SettingsRow(title: "Play sounds",
                                subtitle: "Soft cues when recording starts, stops and pastes.",
                                systemImage: settings.soundsEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill") {
                        Toggle("", isOn: $settings.soundsEnabled)
                            .toggleStyle(.murmurSwitch)
                            .labelsHidden()
                    }
                    SettingsRow(title: "Volume", subtitle: "Release the slider to hear it.",
                                systemImage: "slider.horizontal.3", iconTint: .inkSecondary) {
                        HStack(spacing: 10) {
                            Image(systemName: "speaker.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.inkTertiary)
                            HubSlider(value: $settings.soundVolume) { editing in
                                if !editing { hub.sounds.preview(.start) }
                            }
                            .frame(width: 180)
                            Image(systemName: "speaker.wave.3.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.inkTertiary)
                        }
                        .disabled(!settings.soundsEnabled)
                    }
                }
            }
        }
    }

    @ViewBuilder private var hideForAnHour: some View {
        let hiddenUntil = settings.pillHiddenUntil.flatMap { $0 > hub.now ? $0 : nil }
        SettingsGroup {
            SettingsRow(title: hiddenUntil == nil ? "Need a break from the pill?" : "Pill hidden until \(Fmt.time(hiddenUntil!))",
                        subtitle: hiddenUntil == nil
                            ? "Hide it for an hour. Dictation, sounds and notices keep working."
                            : "Dictation, sounds and notices keep working.",
                        systemImage: hiddenUntil == nil ? "eye.slash" : "clock",
                        iconTint: .inkSecondary) {
                if hiddenUntil == nil {
                    Button("Hide for 1 hour") {
                        withAnimation(Theme.Motion.snappy) { settings.hidePill(now: hub.now) }
                    }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
                    .disabled(settings.pillMode == .never)
                } else {
                    Button("Show now") {
                        withAnimation(Theme.Motion.snappy) { settings.pillHiddenUntil = nil }
                    }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
                }
            }
        }
    }
}

// MARK: - Preview stage

private enum PreviewState: String, CaseIterable, Identifiable {
    case resting, listening, handsFree, transcribing, done, error

    var id: String { rawValue }

    var title: String {
        switch self {
        case .resting: "Resting"
        case .listening: "Listening"
        case .handsFree: "Hands-free"
        case .transcribing: "Transcribing"
        case .done: "Done"
        case .error: "Error"
        }
    }

    var phase: PillPhase {
        switch self {
        case .resting: .rest
        case .listening: .listening
        case .handsFree: .locked
        case .transcribing: .processing
        case .done: .success
        case .error: .error
        }
    }
}

/// The real pill on a small desk; the chips drive one preview model, so switching plays the real transitions.
private struct PillPreviewStage: View {
    @Environment(HubContext.self) private var hub
    @State private var state: PreviewState = .listening
    @State private var model = PillModel.preview(phase: PreviewState.listening.phase, level: 0.62)
    @Namespace private var chip

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                DeskScene()
                PillView(model: model)
                    .scaleEffect(1.3, anchor: .bottom)
                    .padding(.bottom, 20)
                    .allowsHitTesting(false)
            }
            .frame(height: 164)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.card, topTrailingRadius: Theme.Radius.card,
                                              style: .continuous))
            Rectangle().fill(Color.stroke).frame(height: 1)
            HStack(spacing: 2) {
                ForEach(PreviewState.allCases) { option in
                    segment(option)
                }
            }
            .padding(3)
            .background(Color.bgSunken, in: Capsule(style: .continuous))
            .overlay { Capsule(style: .continuous).ring(1).fill(Color.stroke, style: FillStyle(eoFill: true)) }
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            guard let initial = PreviewState.allCases.first(where: { $0.phase == hub.initialPillPreview }),
                  initial != state else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                state = initial
                model.phase = initial.phase
            }
        }
        .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1)
        }
        .cardShadow()
    }

    private func segment(_ option: PreviewState) -> some View {
        let selected = option == state
        return Button {
            withAnimation(Theme.Motion.snappy) { state = option }
            model.phase = option.phase
        } label: {
            Text(option.title)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.ink : Color.inkSecondary)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background {
                    if selected {
                        Capsule(style: .continuous)
                            .fill(HubPalette.sidebarSelection)
                            .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                            .matchedGeometryEffect(id: "segment", in: chip)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A calm desktop: soft wallpaper wash and a blurred app window, so the dark pill has something to sit on.
private struct DeskScene: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            LinearGradient(colors: dark
                           ? [Color(nsColor: .hex(0x2A2545)), Color(nsColor: .hex(0x1C1A26)), Color(nsColor: .hex(0x2C2019))]
                           : [Color(nsColor: .hex(0xE9E4FF)), Color(nsColor: .hex(0xF4EFF6)), Color(nsColor: .hex(0xFFE6D6))],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.warm.opacity(dark ? 0.16 : 0.28), .clear], center: .bottomTrailing,
                           startRadius: 0, endRadius: 320)
            // An app window, suggested rather than drawn.
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(Color.white.opacity(dark ? 0.14 : 0.9)).frame(width: 6, height: 6)
                    }
                }
                .padding(.bottom, 4)
                ForEach([0.82, 0.64, 0.4], id: \.self) { width in
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(dark ? 0.08 : 0.75))
                        .frame(width: 250 * width, height: 5)
                }
            }
            .padding(14)
            .frame(width: 300, height: 86, alignment: .topLeading)
            .background(Color.white.opacity(dark ? 0.05 : 0.45),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(dark ? 0.06 : 0.7), lineWidth: 1)
            }
            .offset(y: -28)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Mode tiles

private struct PillModeTile: View {
    var mode: PillMode
    var isSelected: Bool
    var action: () -> Void
    @State private var hovering = false

    private var caption: String {
        switch mode {
        case .always: "A slim bar waits at the bottom of the screen."
        case .whileDictating: "Appears when you start talking, then steps aside."
        case .never: "You’ll still hear sounds and see the menu bar icon."
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                MiniScreen(mode: mode)
                    .frame(height: 76)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.ink)
                    Text(caption)
                        .typeface(.callout)
                        .foregroundStyle(.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .background(Color.bgSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.accent : (hovering ? Color.strokeStrong : Color.stroke),
                                  lineWidth: isSelected ? 2 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentFill)
                        .background(Circle().fill(.white).padding(2))
                        .padding(16)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .cardShadow()
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .accessibilityLabel(mode.title)
        .accessibilityHint(caption)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Miniature screen showing where (and whether) the pill sits.
private struct MiniScreen: View {
    var mode: PillMode
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        ZStack(alignment: .bottom) {
            shape.fill(LinearGradient(colors: dark
                                      ? [Color(nsColor: .hex(0x28243F)), Color(nsColor: .hex(0x2B211C))]
                                      : [Color(nsColor: .hex(0xECE7FF)), Color(nsColor: .hex(0xFFE9DC))],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(dark ? 0.06 : 0.55))
                .frame(width: 70, height: 36)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 10)
            pill.padding(.bottom, 8)
        }
        .overlay { shape.strokeBorder(Color.stroke, lineWidth: 1) }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var pill: some View {
        switch mode {
        case .always:
            Capsule(style: .continuous)
                .fill(Color.pillFill)
                .frame(width: 22, height: 6)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        case .whileDictating:
            HStack(spacing: 1.6) {
                ForEach(Array([0.3, 0.55, 0.85, 1.0, 0.7, 0.5, 0.3].enumerated()), id: \.offset) { _, h in
                    Capsule(style: .continuous).fill(.white).frame(width: 1.6, height: max(1.6, 8 * h))
                }
            }
            .frame(width: 42, height: 14)
            .background(Capsule(style: .continuous).fill(Color.pillFill))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1.5)
        case .never:
            Capsule(style: .continuous)
                .strokeBorder(Color.inkTertiary, style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
                .frame(width: 34, height: 10)
        }
    }
}
