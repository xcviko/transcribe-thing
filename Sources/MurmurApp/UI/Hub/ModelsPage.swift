import SwiftUI

/// Four engines (download, use, delete), storage, the OpenRouter key, Gemini instructions and Whisper's language.
struct ModelsPage: View {
    @Environment(HubContext.self) private var hub
    @Environment(ModelStore.self) private var models
    @Environment(AppSettings.self) private var settings
    @Environment(OpenRouterAccount.self) private var account

    @State private var keyFocusRequest = 0
    @State private var freeBytes: Int64?

    var body: some View {
        ScrollViewReader { proxy in
            HubPage("Models", subtitle: "Choose how Murmur turns speech into text. Switch anytime.") {
                HubGroup("On your Mac", footer: nil) {
                    SettingsGroup {
                        ForEach(EngineID.localEngines) { engine in row(engine, proxy: proxy) }
                    }
                    storageLine
                }
                HubGroup("Through OpenRouter") {
                    SettingsGroup {
                        ForEach(EngineID.cloudEngines) { engine in row(engine, proxy: proxy) }
                    }
                    OpenRouterKeyCard(focusRequest: keyFocusRequest)
                        .id(ModelsAnchor.key)
                        .padding(.top, 4)
                }
                HubGroup("Gemini") {
                    GeminiInstructionsCard()
                }
                HubGroup("Language") {
                    SettingsGroup {
                        SettingsRow(title: "Whisper language",
                                    subtitle: "A hint for Whisper. Parakeet detects the language on its own.",
                                    systemImage: "character.bubble") {
                            HubMenuPicker(options: [nil] + WhisperLanguage.all.map(\.code),
                                          selection: whisperLanguage,
                                          label: WhisperLanguage.name(for:))
                        }
                    }
                }
            }
        }
        .task(id: models.diskUsageBytes) {
            freeBytes = hub.paths.freeDiskBytes()
        }
    }

    private var whisperLanguage: Binding<String?> {
        Binding(get: { settings.whisperLanguage }, set: { settings.whisperLanguage = $0 })
    }

    private func row(_ engine: EngineID, proxy: ScrollViewProxy) -> some View {
        ModelRow(
            engine: engine,
            isSelected: settings.selectedEngine == engine,
            isPendingSwitch: models.pendingSelection == engine,
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
        .foregroundStyle(.inkTertiary)
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private var storageText: String {
        let used = models.diskUsageBytes > 0 ? "Models use \(Fmt.bytes(models.diskUsageBytes))" : "No models downloaded yet"
        guard let freeBytes, freeBytes > 0 else { return used }
        return "\(used) · \(Fmt.bytes(freeBytes)) free on this Mac"
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
                    titleLine(badges: Array(badges.prefix(1)))
                    titleLine(badges: [])
                }
                Text(engine.factLine)
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
                    .lineLimit(1)
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

    private var badges: [String] { engine.badges.filter { $0 != "Cloud" } }

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
            HStack(spacing: 8) {
                ProgressBar(fraction: progress.fraction, height: 4)
                    .frame(width: 120)
                Text(downloadLabel(progress))
                    .typeface(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.inkSecondary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                pendingNote
            }
        case .preparing(let since):
            HStack(spacing: 8) {
                ShimmerBar(height: 4).frame(width: 100)
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let elapsed = context.date.timeIntervalSince(since)
                    Text("Optimizing for your Mac… can take a few minutes" + (elapsed >= 20 ? " · \(Fmt.duration(elapsed))" : ""))
                        .typeface(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.inkSecondary)
                        .lineLimit(1)
                }
                pendingNote
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
        case .downloading:
            Button("Cancel") { models.cancelDownload(engine) }
                .buttonStyle(SecondaryButtonStyle(size: .small))
        case .installed, .ready, .preparing:
            if !isSelected {
                Button("Use", action: use)
                    .buttonStyle(SecondaryButtonStyle(size: .small))
            }
            deleteButton
        }
    }

    @ViewBuilder private var cloudActions: some View {
        switch readiness {
        case .needsKey:
            Button("Add key", action: focusKey)
                .buttonStyle(SecondaryButtonStyle(size: .small))
        case .keyProblem:
            Button("Update key", action: focusKey)
                .buttonStyle(SecondaryButtonStyle(size: .small))
        case .ready, .warming, .needsDownload, .failed:
            if !isSelected {
                Button("Use", action: use)
                    .buttonStyle(SecondaryButtonStyle(size: .small))
            }
        }
    }

    private var deleteButton: some View {
        Button {
            confirmingDelete = true
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(IconButtonStyle(size: 26))
        .disabled(isSelected)
        .help(isSelected ? "Switch to another model to delete this one." : "Delete \(engine.displayName)")
        .accessibilityLabel("Delete \(engine.displayName)")
        .popover(isPresented: $confirmingDelete, arrowEdge: .bottom) {
            DeleteModelConfirmation(engine: engine, freedBytes: engine.approxDownloadBytes) {
                confirmingDelete = false
                let models = models
                Task { await models.delete(engine) }
            } cancel: {
                confirmingDelete = false
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
