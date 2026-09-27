import AppKit
import Observation
import SwiftUI

/// The services the Hub reads, gathered once from the composition root. Snapshots swap single services
/// (a model mid-download, a rejected key, an empty history) without assembling a whole environment.
/// Observable only as an environment carrier; its references never change after the view is built.
@MainActor
final class HubContext: Observable {
    var settings: AppSettings
    var models: ModelStore
    var account: OpenRouterAccount
    var history: HistoryStore
    var permissions: PermissionsCenter
    var devices: AudioDeviceCatalog
    var launchAtLogin: LaunchAtLogin
    var secureInput: SecureInputMonitor
    var updates: UpdateCenter
    var levelMeter: LevelMeter
    let windows: WindowCoordinator
    let sounds: SoundPlayer
    let dictation: DictationController
    let toasts: ToastCenter
    let paths: AppPaths
    let isPreview: Bool
    /// Stand-in traffic lights so snapshots read like the real window.
    var drawsWindowControls = false
    var firstName: String?
    /// Fixed "now" for deterministic snapshots; nil = the real clock.
    var fixedNow: Date?
    /// Pre-filled history search (snapshots of the "no matches" state).
    var initialSearch = ""
    /// History rows shown as being transcribed, in place of the dictation controller's (snapshots).
    var previewTranscribing: [UUID: EngineID]?
    /// A History row drawn as hovered, its actions showing (snapshots).
    var previewHoveredEntry: UUID?

    init(env: AppEnvironment) {
        settings = env.settings
        models = env.models
        account = env.account
        history = env.history
        permissions = env.permissions
        devices = env.devices
        launchAtLogin = env.launchAtLogin
        secureInput = env.secureInput
        updates = env.updates
        levelMeter = env.levelMeter
        windows = env.windows
        sounds = env.sounds
        dictation = env.dictation
        toasts = env.toasts
        paths = env.paths
        isPreview = env.isPreview
        firstName = HubGreeting.firstName(fullName: NSFullUserName(), accountName: NSUserName())
    }

    var now: Date { fixedNow ?? Date() }

    func show(_ section: HubSection) {
        withAnimation(Theme.Motion.snappy) { windows.hubSection = section }
    }

    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func open(_ url: URL) {
        guard !isPreview else { return }
        NSWorkspace.shared.open(url)
    }

    func readiness(of engine: EngineID) -> EngineReadiness {
        EngineReadiness.of(engine, localState: models.state(of: engine), keyStatus: account.status,
                           localError: models.lastErrors[engine])
    }

    /// The engine a History row's recording is being transcribed with right now, if it is.
    func transcribingEngine(for id: UUID) -> EngineID? {
        (previewTranscribing ?? dictation.transcribingEngines)[id]
    }

    /// What is being made for a History row's recording right now (a transcription or a clean-up), if anything.
    func runningVersion(for id: UUID) -> TranscriptVersionKind? {
        if let previewTranscribing { return previewTranscribing[id].map { .transcription($0) } }
        return dictation.runningVersions[id]
    }

    func versionsMenu(for entry: TranscriptEntry) -> VersionsMenu {
        VersionsMenu.make(for: entry, running: runningVersion(for: entry.id), readiness: readiness(of:),
                          hasCleanupPrompt: settings.hasCleanupPrompt)
    }

    /// "transcribe-thing 0.1.0 (build 42)", or without the build when running the bare binary.
    var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = updates.currentVersion?.description ?? info?["CFBundleShortVersionString"] as? String ?? "0.1"
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty, build != version {
            return "\(Brand.name) \(version) (build \(build))"
        }
        return "\(Brand.name) \(version)"
    }
}

/// The main window: sidebar of sections + the selected page. `env.windows.hubSection` drives the selection,
/// so toasts and menus can deep-link (e.g. a key error → Models).
struct HubView: View {
    private let context: HubContext

    init(env: AppEnvironment) {
        context = HubContext(env: env)
    }

    init(context: HubContext) {
        self.context = context
    }

    var body: some View {
        HubRoot()
            .environment(context)
            .environment(context.settings)
            .environment(context.models)
            .environment(context.account)
            .environment(context.history)
            .environment(context.permissions)
            .environment(context.devices)
            .environment(context.launchAtLogin)
            .environment(context.secureInput)
            .environment(context.updates)
            .environment(context.windows)
            .environment(context.toasts)
    }
}

private struct HubRoot: View {
    @Environment(HubContext.self) private var hub
    @Environment(WindowCoordinator.self) private var windows

    var body: some View {
        HStack(spacing: 0) {
            HubSidebar()
                .frame(width: HubLayout.sidebarWidth)
            Rectangle()
                .fill(Color.stroke)
                .frame(width: 1)
            VStack(spacing: 0) {
                // Transparent titlebar band: keeps page content clear of it and stays draggable.
                Color.clear.frame(height: HubLayout.titlebar)
                page(windows.hubSection)
                    .id(windows.hubSection)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .overlay(alignment: .top) {
                        // Content softens as it scrolls under the titlebar band instead of being cut off.
                        LinearGradient(colors: [Color.bgCanvas, Color.bgCanvas.opacity(0)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 8)
                            .allowsHitTesting(false)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.bgCanvas)
        }
        .animation(Theme.Motion.fade, value: windows.hubSection)
        .background(Color.bgCanvas)
        .ignoresSafeArea()
        .frame(minWidth: 820, minHeight: 560)
        .background(HubWindowChrome())
        .overlay(alignment: .topLeading) {
            if hub.drawsWindowControls { PreviewTrafficLights() }
        }
        // The key's status (and credit left) is a snapshot from the last check: refresh a stale one.
        .task { hub.account.refreshIfStale(maxAge: 300) }
    }

    @ViewBuilder private func page(_ section: HubSection) -> some View {
        switch section {
        case .home: HomePage()
        case .models: ModelsPage()
        case .shortcuts: ShortcutsPage()
        case .microphone: MicrophonePage()
        case .general: GeneralPage()
        case .softwareUpdate: SoftwareUpdatePage()
        }
    }
}

// MARK: - Sidebar

private struct HubSidebar: View {
    @Environment(HubContext.self) private var hub
    @Environment(WindowCoordinator.self) private var windows
    @Environment(AppSettings.self) private var settings
    @Environment(ModelStore.self) private var models
    @Environment(OpenRouterAccount.self) private var account
    @Environment(UpdateCenter.self) private var updates
    @Namespace private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights.
            Color.clear.frame(height: 40)
            HStack(spacing: 9) {
                AppIconMark(size: 22)
                Text(Brand.name)
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .tracking(-0.2)
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 2) {
                item(.home)
                Text("SETTINGS")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.inkTertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
                ForEach(HubSection.sidebar.filter { $0 != .home }) { section in
                    item(section)
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 16)

            footer
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(HubPalette.sidebar)
    }

    /// ⌘1…⌘N follow `HubSection.sidebar`. Software Update keeps General selected, and an update waiting
    /// (with reminders on) puts a red count on General, as System Settings does.
    private func item(_ section: HubSection) -> some View {
        SidebarItem(section: section, isSelected: windows.hubSection.sidebarItem == section,
                    badge: section == .general && updates.showsBadge ? 1 : nil, namespace: selection) {
            hub.show(section)
        }
        .keyboardShortcut(section.shortcutDigit.map { KeyboardShortcut(KeyEquivalent($0), modifiers: .command) })
    }

    private var footer: some View {
        let engine = settings.selectedEngine
        let summary = EngineSummary.make(engine: engine, localState: models.state(of: engine), keyStatus: account.status,
                                         localError: models.lastErrors[engine])
        return VStack(alignment: .leading, spacing: 10) {
            EngineStatusChip(summary: summary, engine: engine) { hub.show(.models) }
            Text(hub.versionLine)
                .font(.system(size: 11))
                .foregroundStyle(.inkTertiary)
                .padding(.horizontal, 6)
        }
    }
}

private struct SidebarItem: View {
    var section: HubSection
    var isSelected: Bool
    var badge: Int?
    var namespace: Namespace.ID
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.symbolName)
                    .symbolVariant(isSelected ? .fill : .none)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accent : Color.inkSecondary)
                    .frame(width: 20)
                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Color.ink)
                Spacer(minLength: 0)
                if let badge {
                    CountBadge(count: badge)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(HubPalette.sidebarSelection)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.stroke, lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.05), radius: 1.5, y: 1)
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.hover)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .animation(Theme.Motion.snappy, value: badge)
        .accessibilityLabel(badge == nil ? section.title : "\(section.title), update available")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// "Parakeet v3 · Ready" with a status dot; opens Models.
private struct EngineStatusChip: View {
    var summary: EngineSummary
    var engine: EngineID
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                EngineIcon(engine: engine, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    nameLine
                    HStack(spacing: 4) {
                        StatusDot(color: summary.tone.color, size: 6, pulsing: summary.tone == .progress)
                            .frame(width: 10, height: 10)
                        Text(summary.status)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(summary.tone == .negative ? Color.danger : Color.inkSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.inkTertiary)
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(hovering ? HubPalette.sidebarSelection : HubPalette.sidebarSelection.opacity(scheme == .dark ? 0.7 : 0.75))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.stroke, lineWidth: 1)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .help("Open Models")
        .accessibilityLabel("\(summary.name), \(summary.status). Open Models.")
    }

    /// Cloud Parakeet shows the model's name with a cloud, the same mark its history rows carry, rather than
    /// spelling out "· Cloud" in the narrow sidebar.
    private var nameLine: some View {
        HStack(spacing: 4) {
            Text(engine.cloudAPI == .transcriptions ? (engine.localCounterpart?.shortName ?? summary.name) : summary.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.ink)
                .lineLimit(1)
            if engine.cloudAPI == .transcriptions {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(HubPalette.apricotInk)
            }
        }
    }
}

// MARK: - Window chrome

/// Hides the window title (the sidebar carries the name) once the view is in its window.
private struct HubWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.styleMask.contains(.titled) else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        }
    }
}

/// Snapshot-only stand-in for the close/minimize/zoom buttons.
private struct PreviewTrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { rgb in
                Circle()
                    .fill(Color(nsColor: .hex(UInt32(rgb))))
                    .overlay { Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5) }
                    .frame(width: 12, height: 12)
            }
        }
        .padding(.leading, 14)
        .padding(.top, 14)
        .accessibilityHidden(true)
    }
}
