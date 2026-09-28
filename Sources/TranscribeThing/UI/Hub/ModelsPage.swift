import SwiftUI

/// The main model (download, use, delete) and storage, the extra models the Switch model shortcut steps through,
/// the clean-up model, and the OpenRouter key.
struct ModelsPage: View {
    @Environment(HubContext.self) private var hub
    @Environment(ModelStore.self) private var models
    @Environment(AppSettings.self) private var settings
    @Environment(OpenRouterAccount.self) private var account

    @State private var keyFocusRequest = 0
    @State private var freeBytes: Int64?
    /// Narrow window: the local model drops "Private" and "Offline" and keeps "Recommended".
    @State private var compactBadges = false

    /// Below this list width the local model's full badge row stops fitting beside its actions.
    static let compactBadgeWidth: CGFloat = 640

    var body: some View {
        @Bindable var settings = settings
        ScrollViewReader { proxy in
            HubPage("Models", subtitle: "Every dictation starts on your main model. Switch to an extra one while you talk.") {
                HubGroup("Main model") {
                    SettingsGroup {
                        ForEach(EngineID.mainCandidates) { engine in row(engine, proxy: proxy) }
                    }
                    .onGeometryChange(for: Bool.self) { $0.size.width < Self.compactBadgeWidth } action: { compact in
                        compactBadges = compact
                    }
                    storageLine
                }
                HubGroup("Extra models", footer: extraFooter) {
                    ExtraModelsLine(status: extraStatus) { hub.show(.shortcuts) }
                    SettingsGroup {
                        CleanupStepRow(isOn: $settings.switchCleanup) { focusKey(proxy) }
                        ForEach(EngineID.switchCandidates) { engine in
                            ExtraModelRow(engine: engine, isOn: extraBinding(engine)) { focusKey(proxy) }
                        }
                    }
                }
                HubGroup("Clean-up", footer: "For dictations you switch to clean-up. Gemini transcripts aren’t cleaned up: Gemini already punctuates and drops filler words. History keeps the original too.") {
                    SettingsGroup {
                        CleanupModelRow(model: .default) { focusKey(proxy) }
                    }
                }
                HubGroup("OpenRouter") {
                    OpenRouterKeyCard(focusRequest: keyFocusRequest)
                        .id(ModelsAnchor.key)
                }
            }
        }
        .task(id: models.diskUsageBytes) {
            freeBytes = hub.paths.freeDiskBytes()
        }
        .task { account.refreshIfStale(maxAge: 300) }
    }

    private var extraStatus: ExtraModels.Status {
        ExtraModels.status(binding: settings.shortcuts[.switchModel], enabled: settings.switchChoices)
    }

    private var extraFooter: String {
        "The next dictation starts on \(settings.selectedEngine.shortName) again."
    }

    private func extraBinding(_ engine: EngineID) -> Binding<Bool> {
        let settings = settings
        return Binding(get: { settings.switchEngines.contains(engine) },
                       set: { on in settings.switchEngines = ExtraModels.setting(engine, on: on, in: settings.switchEngines) })
    }

    private func row(_ engine: EngineID, proxy: ScrollViewProxy) -> some View {
        ModelRow(
            engine: engine,
            isSelected: settings.selectedEngine == engine,
            isPendingSwitch: models.pendingSelection == engine,
            compactBadges: compactBadges,
            choose: { choose(engine, proxy: proxy) },
            use: { use(engine) },
            focusKey: { focusKey(proxy) })
    }

    // MARK: Selection

    private func choose(_ engine: EngineID, proxy: ScrollViewProxy) {
        guard settings.selectedEngine != engine else { return }
        switch hub.readiness(of: engine) {
        case .ready, .warming, .needsDownload, .failed:
            // Downloads keep the current engine until the new one lands (ModelStore finishes the switch
            // even if this window closes).
            withAnimation(Theme.Motion.snappy) { models.selectWhenInstalled(engine) }
        case .needsKey, .keyProblem:
            focusKey(proxy)
        }
    }

    private func use(_ engine: EngineID) {
        withAnimation(Theme.Motion.snappy) { models.select(engine) }
    }

    private func focusKey(_ proxy: ScrollViewProxy) {
        withAnimation(Theme.Motion.expand) { proxy.scrollTo(ModelsAnchor.key, anchor: .top) }
        keyFocusRequest += 1
    }

    // MARK: Storage

    private var storageLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "internaldrive")
                .font(.system(size: 11, weight: .medium))
            Text(storageText)
                .monospacedDigit()
        }
        .typeface(.callout)
        .foregroundStyle(.inkSecondary)
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    /// "Takes 632 MB on disk · 23.6 GB free on this Mac"; just the free space before anything is downloaded.
    private var storageText: String {
        let free = freeBytes.flatMap { $0 > 0 ? "\(Fmt.bytes($0)) free on this Mac" : nil }
        guard models.diskUsageBytes > 0 else { return free ?? "Nothing downloaded yet" }
        let used = "Takes \(Fmt.bytes(models.diskUsageBytes)) on disk"
        return free.map { "\(used) · \($0)" } ?? used
    }
}

enum ModelsAnchor: Hashable {
    case key
}

// MARK: - Row

private struct ModelRow: View {
    var engine: EngineID
    var isSelected: Bool
    var isPendingSwitch: Bool
    var compactBadges: Bool
    var choose: () -> Void
    var use: () -> Void
    var focusKey: () -> Void

    @Environment(HubContext.self) private var hub
    @Environment(ModelStore.self) private var models
    @Environment(OpenRouterAccount.self) private var account
    @State private var hovering = false
    @State private var confirmingDelete = false

    private var state: LocalModelState { models.state(of: engine) }
    private var readiness: EngineReadiness { hub.readiness(of: engine) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RadioDot(isOn: isSelected)
            EngineIcon(engine: engine, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                ViewThatFits(in: .horizontal) {
                    titleLine(badges: badges)
                    titleLine(badges: [])
                }
                Text(engine.factLine)
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
                    .lineLimit(1)
                if let note = ProviderNote.text(engine) {
                    providerLine(note)
                }
                status
                    .padding(.top, 2)
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 12)
        .frame(minHeight: 76)
        .background { RowHighlight(isSelected: isSelected, isHovering: hovering) }
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var badges: [String] {
        engine.badges.filter { $0 != "Cloud" && !(compactBadges && EngineID.privacyBadges.contains($0)) }
    }

    private func providerLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "server.rack")
                .font(.system(size: 9.5, weight: .semibold))
                .frame(width: 12)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .typeface(.callout)
        .foregroundStyle(.inkTertiary)
    }

    private func titleLine(badges: [String]) -> some View {
        HStack(spacing: 6) {
            Text(engine.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.ink)
                .lineLimit(1)
                .fixedSize()
            ForEach(badges, id: \.self) { Badge.engine($0) }
        }
    }

    // MARK: Status

    @ViewBuilder private var status: some View {
        if engine.isLocal {
            localStatus
        } else {
            ModelStatusText(keyStatus: account.status)
        }
    }

    @ViewBuilder private var localStatus: some View {
        switch state {
        case .downloading(let progress):
            BarThenCaption {
                ProgressBar(fraction: progress.fraction, height: 4)
                    .frame(width: 120)
            } caption: {
                HStack(spacing: 8) {
                    Text(downloadLabel(progress))
                        .typeface(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.inkSecondary)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                    pendingNote
                }
            }
        case .preparing(let since):
            BarThenCaption {
                ShimmerBar(height: 4).frame(width: 100)
            } caption: {
                HStack(spacing: 8) {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        let elapsed = context.date.timeIntervalSince(since)
                        Text("Optimizing for your Mac… usually under a minute" + (elapsed >= 20 ? " · \(Fmt.duration(elapsed))" : ""))
                            .typeface(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(1)
                    }
                    pendingNote
                }
            }
        case .failed(let message):
            HStack(spacing: 4) {
                StatusDot(color: .danger, size: 6).frame(width: 12, height: 12)
                // ModelStore's messages say what failed (download, load, disk space) on their own.
                Text(message.isEmpty ? "Something went wrong. Try again." : message)
                    .typeface(.callout)
                    .foregroundStyle(.danger)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(message)
            }
        case .notInstalled, .installed, .ready:
            HStack(spacing: 6) {
                ModelStatusText(state: state, engine: engine)
                pendingNote
            }
        }
    }

    @ViewBuilder private var pendingNote: some View {
        if isPendingSwitch {
            Text("· Switches when ready")
                .typeface(.callout)
                .foregroundStyle(.accent)
                .lineLimit(1)
        }
    }

    private func downloadLabel(_ p: DownloadProgress) -> String {
        let amount = p.totalBytes > 0
            ? "\(Fmt.bytes(p.bytesReceived)) of \(Fmt.bytes(p.totalBytes))"
            : "\(p.percent)%"
        guard let eta = p.secondsRemaining else { return amount }
        return "\(amount) · \(Fmt.eta(eta))"
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            if isSelected && readiness.isUsable {
                inUse
            }
            if engine.isLocal {
                localActions
            } else {
                cloudActions
            }
        }
    }

    private var inUse: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            Text("In use").font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(.accent)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Color.accentSoft, in: Capsule(style: .continuous))
    }

    @ViewBuilder private var localActions: some View {
        switch state {
        case .notInstalled:
            Button {
                models.download(engine)
            } label: {
                Label("Download", systemImage: "arrow.down")
            }
            .buttonStyle(SecondaryButtonStyle(size: .small))
        case .failed:
            Button("Retry") { models.download(engine) }
                .buttonStyle(SecondaryButtonStyle(size: .small))
            if case .modelLoadFailed? = models.lastErrors[engine] {
                // The files downloaded but don't load: Retry loads the same files again, this replaces them.
                Button("Download Again") {
                    let models = models
                    Task { await models.reinstall(engine) }
                }
                .buttonStyle(SecondaryButtonStyle(size: .small))
                .help("Delete \(engine.displayName) and download it again")
            } else {
                // A partial download or a half-removed install can go even while selected: nothing is loaded.
                deleteButton(isEnabled: true, freedBytes: nil)
            }
        case .downloading:
            Button("Cancel") { models.cancelDownload(engine) }
                .buttonStyle(SecondaryButtonStyle(size: .small))
        case .installed, .ready, .preparing:
            if !isSelected {
                Button("Use", action: use)
                    .buttonStyle(SecondaryButtonStyle(size: .small))
            }
            deleteButton(isEnabled: !isSelected, freedBytes: engine.approxDownloadBytes)
        }
    }

    @ViewBuilder private var cloudActions: some View {
        switch readiness {
        case .needsKey:
            Button("Add Key", action: focusKey)
                .buttonStyle(SecondaryButtonStyle(size: .small))
        case .keyProblem:
            Button("Update Key", action: focusKey)
                .buttonStyle(SecondaryButtonStyle(size: .small))
        case .ready, .warming, .needsDownload, .failed:
            if !isSelected {
                Button("Use", action: use)
                    .buttonStyle(SecondaryButtonStyle(size: .small))
            }
        }
    }

    private func deleteButton(isEnabled: Bool, freedBytes: Int64?) -> some View {
        Button {
            confirmingDelete = true
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(IconButtonStyle(size: 26))
        .disabled(!isEnabled)
        .help(isEnabled ? "Delete \(engine.displayName)" : "Switch to another model to delete this one.")
        .accessibilityLabel("Delete \(engine.displayName)")
        .popover(isPresented: $confirmingDelete, arrowEdge: .bottom) {
            DeleteModelConfirmation(engine: engine, freedBytes: freedBytes) {
                confirmingDelete = false
                let models = models
                Task { await models.delete(engine) }
            } cancel: {
                confirmingDelete = false
            }
        }
    }
}

// MARK: - Extra models

/// What the Switch model shortcut does, with the user's own binding as key caps; or what's missing for it to work.
private struct ExtraModelsLine: View {
    var status: ExtraModels.Status
    var openShortcuts: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isReady ? Color.accent : Color.inkTertiary)
            switch status {
            case .ready(let binding):
                // Key caps mid-sentence; the explanation's text is the accessibility label.
                HStack(spacing: 5) {
                    Text("Press")
                    ShortcutChips(shortcut: binding, size: .small)
                    Text("while dictating to use one for that dictation.")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ExtraModels.explanation(status))
            case .noneEnabled, .unbound:
                Text(ExtraModels.explanation(status))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if status == .unbound {
                Button("Set Shortcut", action: openShortcuts)
                    .buttonStyle(.appQuiet)
                    .fixedSize()
            }
        }
        .typeface(.callout)
        .foregroundStyle(.inkSecondary)
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private var isReady: Bool {
        if case .ready = status { true } else { false }
    }
}

/// An extra model: what it's like, its OpenRouter status, and whether the Switch model shortcut steps to it.
private struct ExtraModelRow: View {
    var engine: EngineID
    @Binding var isOn: Bool
    var focusKey: () -> Void

    @Environment(HubContext.self) private var hub
    @Environment(OpenRouterAccount.self) private var account

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            EngineIcon(engine: engine, size: 36)
                .opacity(isOn ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 3) {
                Text(engine.modelName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? Color.ink : Color.inkSecondary)
                    .lineLimit(1)
                Text(engine.factLine)
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
                    .lineLimit(1)
                if let note = ProviderNote.text(engine) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 9.5, weight: .semibold))
                            .frame(width: 12)
                        Text(note)
                    }
                    .typeface(.callout)
                    .foregroundStyle(.inkTertiary)
                }
                ModelStatusText(keyStatus: account.status)
                    .padding(.top, 2)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                switch hub.readiness(of: engine) {
                case .needsKey:
                    Button("Add Key", action: focusKey)
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                case .keyProblem:
                    Button("Update Key", action: focusKey)
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                case .ready, .warming, .needsDownload, .failed:
                    EmptyView()
                }
                Toggle("", isOn: $isOn)
                    .toggleStyle(.appSwitch)
                    .labelsHidden()
                    .accessibilityLabel("Include \(engine.displayName) when switching")
                    .help(isOn ? "Included when switching models" : "Not included when switching models")
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 12)
        .frame(minHeight: 76)
        .animation(Theme.Motion.hover, value: isOn)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Clean-up

/// Clean-up's mark: a warm wand, on the Models page and on the pill's clean-up chip.
private struct CleanupIcon: View {
    var size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Image(systemName: ModelChoice.cleanup.symbolName)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(Color.warm)
            .frame(width: size, height: size)
            .background {
                shape.fill(Color.warm.opacity(0.13))
                    .overlay { shape.strokeBorder(Color.warm.opacity(0.18), lineWidth: 0.5) }
            }
            .accessibilityHidden(true)
    }
}

/// Clean-up as a Switch model step, first among the extra models: the main model transcribes and the clean-up model
/// tidies its words. Named as the pass it is ("Parakeet v3 + GPT-6 Luna").
private struct CleanupStepRow: View {
    @Binding var isOn: Bool
    var focusKey: () -> Void

    @Environment(HubContext.self) private var hub
    @Environment(OpenRouterAccount.self) private var account
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let cleanup = CleanupModel.default
        HStack(alignment: .center, spacing: 12) {
            CleanupIcon(size: 36)
                .opacity(isOn ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 3) {
                Text(ModelChoice.cleanup.title(main: settings.selectedEngine))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? Color.ink : Color.inkSecondary)
                    .lineLimit(1)
                Text("\(settings.selectedEngine.chipName) transcribes, then \(cleanup.shortName) tidies the text.")
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ModelStatusText(keyStatus: account.status)
                    .padding(.top, 2)
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                // The clean-up goes through the same OpenRouter key as Gemini.
                switch hub.readiness(of: .geminiFlash) {
                case .needsKey:
                    Button("Add Key", action: focusKey)
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                case .keyProblem:
                    Button("Update Key", action: focusKey)
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                case .ready, .warming, .needsDownload, .failed:
                    EmptyView()
                }
                Toggle("", isOn: $isOn)
                    .toggleStyle(.appSwitch)
                    .labelsHidden()
                    .accessibilityLabel("Include clean-up when switching")
                    .help(isOn ? "Included when switching models" : "Not included when switching models")
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 12)
        .frame(minHeight: 76)
        .animation(Theme.Motion.hover, value: isOn)
        .accessibilityElement(children: .contain)
    }
}

/// The clean-up model, for information: what it does, who serves it and the OpenRouter key's status, like the
/// extra models. Nothing to pick: it's the only one. It reads text, never audio, so it has no place among the
/// models a dictation can go to.
private struct CleanupModelRow: View {
    var model: CleanupModel
    var focusKey: () -> Void

    @Environment(HubContext.self) private var hub
    @Environment(OpenRouterAccount.self) private var account

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            CleanupIcon(size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.modelName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                Text("Tidies punctuation, fillers and false starts · reads text, not audio")
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 9.5, weight: .semibold))
                        .frame(width: 12)
                    Text("Served by \(model.providerName) only.")
                }
                .typeface(.callout)
                .foregroundStyle(.inkTertiary)
                ModelStatusText(keyStatus: account.status)
                    .padding(.top, 2)
            }
            Spacer(minLength: 8)
            // The clean-up goes through the same OpenRouter key as Gemini.
            switch hub.readiness(of: .geminiFlash) {
            case .needsKey:
                Button("Add Key", action: focusKey)
                    .buttonStyle(SecondaryButtonStyle(size: .small))
            case .keyProblem:
                Button("Update Key", action: focusKey)
                    .buttonStyle(SecondaryButtonStyle(size: .small))
            case .ready, .warming, .needsDownload, .failed:
                EmptyView()
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 12)
        .frame(minHeight: 76)
        .accessibilityElement(children: .contain)
    }
}

/// A progress bar with its caption on the same line, or under it when the row is too narrow for both (a narrow
/// window, beside "In use" and an action button), so the caption keeps its end: "about 40 s left".
private struct BarThenCaption<Bar: View, Caption: View>: View {
    private let bar: Bar
    private let caption: Caption

    init(@ViewBuilder bar: () -> Bar, @ViewBuilder caption: () -> Caption) {
        self.bar = bar()
        self.caption = caption()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                bar
                caption
            }
            VStack(alignment: .leading, spacing: 6) {
                bar
                caption
            }
        }
    }
}

private struct DeleteModelConfirmation: View {
    var engine: EngineID
    var freedBytes: Int64?
    var confirm: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete \(engine.displayName)?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.ink)
            Text(message)
                .typeface(.callout)
                .foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(SecondaryButtonStyle(size: .small))
                    .keyboardShortcut(.cancelAction)
                Button("Delete", action: confirm)
                    .buttonStyle(PrimaryButtonStyle(size: .small, tint: .danger))
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private var message: String {
        let size = freedBytes.map { "This frees \(Fmt.bytes($0)). " } ?? ""
        return "\(size)You can download it again anytime."
    }
}
