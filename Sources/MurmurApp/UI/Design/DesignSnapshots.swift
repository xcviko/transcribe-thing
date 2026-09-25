import SwiftUI

/// Design-system gallery for visual QA of Theme + Components.
enum DesignSnapshots {
    @MainActor static var entries: [SnapshotEntry] {
        [SnapshotEntry("design-gallery", width: 1180, height: 1250) { env in DesignGallery(env: env) }]
    }
}

private struct DesignGallery: View {
    let env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Paper, ink and a quiet glow").typeface(.display).foregroundStyle(.ink)
                Text("Murmur design system · tokens and components")
                    .typeface(.body).foregroundStyle(.inkSecondary)
            }
            HStack(alignment: .top, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    colors
                    typography
                    badgesAndDots
                }
                .frame(width: 440)
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    buttons
                    shortcuts
                    settings
                    models
                    pills
                }
            }
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.bgCanvas)
    }

    // MARK: Sections

    private var colors: some View {
        section("Color") {
            let swatches: [(String, Color)] = [
                ("canvas", .bgCanvas), ("surface", .bgSurface), ("sunken", .bgSunken), ("lilac", .lilacWash),
                ("ink", .ink), ("ink 2", .inkSecondary), ("ink 3", .inkTertiary), ("stroke", .strokeStrong),
                ("iris", .accent), ("iris soft", .accentSoft), ("apricot", .warm), ("pill", .pillFill),
                ("success", .success), ("warning", .warning), ("danger", .danger), ("chip", .chipFill),
            ]
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
                ForEach(swatches, id: \.0) { name, color in
                    VStack(alignment: .leading, spacing: 5) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(color)
                            .frame(height: 44)
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(.stroke, lineWidth: 1)
                            }
                        Text(name).typeface(.caption).foregroundStyle(.inkSecondary)
                    }
                }
            }
        }
    }

    private var typography: some View {
        section("Type") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Good morning, Sam").typeface(.greeting).foregroundStyle(.ink)
                Text("Choose your model").typeface(.title).foregroundStyle(.ink)
                Text("Parakeet v3 is ready").typeface(.headline).foregroundStyle(.ink)
                Text("Hold fn, speak, and let go. Your words appear wherever you type.")
                    .typeface(.body).foregroundStyle(.ink)
                Text("Runs entirely on your Mac. Nothing leaves this computer.")
                    .typeface(.callout).foregroundStyle(.inkSecondary)
                HStack(spacing: Theme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Fmt.number(2_431)).typeface(.numeric).foregroundStyle(.ink)
                        Text("Words this week").typeface(.caption).foregroundStyle(.inkTertiary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("142").typeface(.numeric).foregroundStyle(.ink)
                        Text("Words per minute").typeface(.caption).foregroundStyle(.inkTertiary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("1:24:05").typeface(.numeric).foregroundStyle(.ink)
                        Text("Time saved").typeface(.caption).foregroundStyle(.inkTertiary)
                    }
                }
                Text("sk-or-v1-••••3f9a").typeface(.mono).foregroundStyle(.inkSecondary)
            }
        }
    }

    private var badgesAndDots: some View {
        section("Badges and status") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(["Recommended", "Private", "Offline", "Cloud"], id: \.self) { Badge.engine($0) }
                    Badge(text: "New", tint: .warm)
                    Badge(text: "Failed", tint: .danger, systemImage: "exclamationmark")
                }
                HStack(spacing: 14) {
                    ForEach([("Ready", Color.success), ("Working", .accent), ("Attention", .warning), ("Error", .danger), ("Idle", .inkTertiary)], id: \.0) { label, color in
                        HStack(spacing: 2) {
                            StatusDot(color: color)
                            Text(label).typeface(.callout).foregroundStyle(.inkSecondary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ModelStatusText(state: .ready, engine: .parakeet)
                    ModelStatusText(state: .downloading(DownloadProgress(fraction: 0.42, bytesReceived: 265_000_000, totalBytes: 632_321_326, bytesPerSecond: 6_000_000, secondsRemaining: 64)), engine: .whisper)
                    ModelStatusText(state: .preparing(since: Date()), engine: .whisper)
                    ModelStatusText(state: .notInstalled, engine: .whisper)
                    ModelStatusText(keyStatus: .valid(PreviewFixtures.keyInfo))
                    ModelStatusText(keyStatus: .missing)
                    ModelStatusText(keyStatus: .invalid("401"))
                }
            }
        }
    }

    private var buttons: some View {
        section("Buttons") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button("Continue") {}.buttonStyle(PrimaryButtonStyle(size: .large))
                    Button("Download") {}.buttonStyle(.murmurPrimary)
                    Button("Add key") {}.buttonStyle(PrimaryButtonStyle(size: .small))
                    Button("Disabled") {}.buttonStyle(.murmurPrimary).disabled(true)
                }
                HStack(spacing: 10) {
                    Button("Back") {}.buttonStyle(SecondaryButtonStyle(size: .large))
                    Button {} label: { Label("Open Settings", systemImage: "gearshape") }.buttonStyle(.murmurSecondary)
                    Button("Delete model") {}.buttonStyle(SecondaryButtonStyle(isDestructive: true))
                    Button("Skip for now") {}.buttonStyle(.murmurQuiet)
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        Button {} label: { Image(systemName: "doc.on.doc") }.buttonStyle(.murmurIcon)
                        Button {} label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.murmurIcon)
                        Button {} label: { Image(systemName: "trash") }.buttonStyle(IconButtonStyle(isActive: true))
                    }
                }
            }
        }
    }

    private var shortcuts: some View {
        section("Shortcuts") {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ShortcutAction.allCases) { action in
                        HStack {
                            Text(action.title).typeface(.bodyMedium).foregroundStyle(.ink)
                            Spacer()
                            ShortcutChips(shortcut: env.settings.shortcuts[action])
                        }
                    }
                    RowDivider(inset: 0)
                    HStack(spacing: 8) {
                        KeyChip(label: "fn", systemImage: "globe", size: .large, isPressed: true)
                        KeyChip(label: "space", size: .large, isWide: true)
                        KeyChip(label: "esc", size: .large)
                        KeyChip(label: "⌘", caption: "right", size: .large)
                        Spacer()
                        ShortcutChips(shortcut: nil)
                    }
                }
            }
        }
    }

    private var settings: some View {
        section("Settings group") {
            SettingsGroup {
                SettingsRow(title: "Play sounds", subtitle: "Soft cues when recording starts and stops.",
                            systemImage: "speaker.wave.2.fill") {
                    Toggle("", isOn: .constant(true)).toggleStyle(.murmurSwitch).labelsHidden()
                }
                SettingsRow(title: "Push to talk", subtitle: ShortcutAction.pushToTalk.subtitle, systemImage: "mic.fill") {
                    ShortcutChips(shortcut: .fn)
                }
                SettingsRow(title: "Open at login", systemImage: "power", iconTint: .inkSecondary) {
                    Toggle("", isOn: .constant(false)).toggleStyle(.murmurSwitch).labelsHidden()
                }
            }
        }
    }

    private var models: some View {
        section("Model card") {
            HStack(alignment: .top, spacing: 12) {
                modelCard(.parakeet, state: .ready, selected: true)
                modelCard(.whisper, state: .downloading(DownloadProgress(fraction: 0.42, secondsRemaining: 64)), selected: false)
            }
        }
    }

    private func modelCard(_ engine: EngineID, state: LocalModelState, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                EngineIcon(engine: engine)
                VStack(alignment: .leading, spacing: 1) {
                    Text(engine.displayName).typeface(.headline).foregroundStyle(.ink)
                    Text(engine.providerLine).typeface(.callout).foregroundStyle(.inkSecondary)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.accent)
                }
            }
            Text(engine.factLine).typeface(.callout).foregroundStyle(.inkSecondary)
            HStack(spacing: 5) { ForEach(engine.badges, id: \.self) { Badge.engine($0) } }
            if case .downloading(let p) = state {
                ProgressBar(fraction: p.fraction)
                ModelStatusText(state: state, engine: engine, showsDot: false)
            } else {
                ModelStatusText(state: state, engine: engine)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(selected ? Color.accentSoft : Color.bgSurface)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(.bgSurface))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(selected ? Color.accent : Color.stroke, lineWidth: selected ? 1.5 : 1)
        }
        .cardShadow()
    }

    private var pills: some View {
        section("Pill and progress") {
            VStack(spacing: 14) {
                HStack(spacing: 18) {
                    MiniPill(phase: .rest)
                    MiniPill(phase: .listening)
                    MiniPill(phase: .locked, level: 0.8)
                    MiniPill(phase: .processing)
                    MiniPill(phase: .success)
                    MiniPill(phase: .error)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .background(StageBackground())
                HStack(spacing: 16) {
                    ProgressBar(fraction: 0.42)
                    ShimmerBar()
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title)
            content()
        }
    }
}
