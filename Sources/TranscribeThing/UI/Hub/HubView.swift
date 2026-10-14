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
    /// The custom endpoint, which takes Gemini's requests while it's set up and on.
    var proxy: VertexProxyAccount
    var history: HistoryStore
    /// Recorded calls (the Calls tab), and what records and transcribes them.
    var calls: CallStore
    let callMonitor: CallMonitor
    let callTranscriber: CallTranscriber
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
    /// General → Troubleshooting's Export Logs….
    let diagnostics: DiagnosticsCenter
    /// Files dropped on Home, read and asked about whichever page is showing.
    let imports = FileImport()
    let isPreview: Bool
    /// Stand-in traffic lights so snapshots read like the real window.
    var drawsWindowControls = false
    var firstName: String?
    /// Fixed "now" for deterministic snapshots; nil = the real clock.
    var fixedNow: Date?
    /// Pre-filled history search (snapshots of the "no matches" state).
    var initialSearch = ""
    /// History rows shown as being transcribed or cleaned up from Home, in place of the dictation controller's
    /// (snapshots).
    var previewRunning: [UUID: TranscriptVersionKind]?
    /// History rows shown with why their last Home work failed, in place of the dictation controller's (snapshots).
    var previewFailures: [UUID: HomeFailure]?
    /// A History row drawn as hovered, its actions showing (snapshots).
    var previewHoveredEntry: UUID?
    /// Home drawn with files dragged over it (snapshots).
    var previewDropTarget = false
    /// The live call as the Calls tab shows it, in place of the monitor's (snapshots).
    var previewCallState: CallMonitor.State?
    /// A Calls row drawn as hovered, its actions showing (snapshots).
    var previewHoveredCall: UUID?
    /// The call's transcript row whose speaker is being renamed, its field open (snapshots).
    var previewRenaming: String?
    /// Where the open call's player stands (snapshots).
    var previewCallPosition: TimeInterval?
    /// The open call's waveform drawn before its loudness is read: flat bars (snapshots).
    var previewWaveformFlat = false

    init(env: AppEnvironment) {
        settings = env.settings
        models = env.models
        account = env.account
        proxy = env.proxy
        history = env.history
        calls = env.calls
        callMonitor = env.callMonitor
        callTranscriber = env.callTranscriber
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
        diagnostics = env.diagnostics
        isPreview = env.isPreview
        firstName = HubGreeting.firstName(fullName: NSFullUserName(), accountName: NSUserName())
        imports.choices = { [unowned self] seconds in
            ImportChoices.make(main: self.settings.mainEngine, seconds: seconds, readiness: self.readiness(of:))
        }
        imports.start = { [dictation] file, kind in dictation.transcribe(file, as: kind) }
    }

    var now: Date { fixedNow ?? Date() }

    /// Picks a page: it's there at once, as a pane in System Settings is.
    func show(_ section: HubSection) {
        windows.hubSection = section
    }

    /// Opens a call's page, over the Calls tab.
    func showCall(_ id: UUID) {
        windows.openCallID = id
        windows.hubSection = .callDetail
    }

    /// The live call: the monitor's, or the snapshot's.
    var callState: CallMonitor.State {
        previewCallState ?? callMonitor.state
    }

    /// Opens the folder a call's audio is kept in, in Finder.
    func revealCall(_ id: UUID) {
        guard !isPreview else { return }
        NSWorkspace.shared.activateFileViewerSelecting([calls.folder(for: id)])
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
        EngineReadiness.of(engine, localState: models.state(of: engine), keyStatus: keyStatus(for: engine),
                           localError: models.lastErrors[engine], provider: provider(for: engine))
    }

    /// A model's readiness: its engine's.
    func readiness(of choice: ModelChoice) -> EngineReadiness {
        readiness(of: choice.engine)
    }

    /// The status of the key `engine`'s requests go with: the custom endpoint's for Gemini while it routes Gemini,
    /// else OpenRouter's.
    func keyStatus(for engine: EngineID) -> KeyStatus {
        CloudRoute.keyStatus(for: engine, account: account, proxy: proxy)
    }

    /// Where `engine`'s requests go; nil for the local model.
    func provider(for engine: EngineID) -> CloudProvider? {
        CloudRoute.provider(for: engine, proxy: proxy)
    }

    /// What is being made for a History row's recording right now (a transcription or a polish), if anything.
    func runningVersion(for id: UUID) -> TranscriptVersionKind? {
        (previewRunning ?? dictation.runningVersions)[id]
    }

    /// What runs for the row was started from Home, so the row can cancel it (a dictation's has Esc).
    func runsHomeWork(for id: UUID) -> Bool {
        (previewRunning ?? dictation.homeWork)[id] != nil
    }

    /// Why the last version Home asked for the row didn't come, until it's dismissed or new work starts.
    func homeFailure(for id: UUID) -> HomeFailure? {
        (previewFailures ?? dictation.homeFailures)[id]
    }

    func versionsMenu(for entry: TranscriptEntry) -> VersionsMenu {
        VersionsMenu.make(for: entry, running: runningVersion(for: entry.id), readiness: readiness(of:))
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
            .environment(context.proxy)
            .environment(context.history)
            .environment(context.calls)
            .environment(context.callMonitor)
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

    /// The window as macOS draws its own (Finder, System Settings): a sidebar of Liquid Glass with the pages, and the
    /// page's title and tools in the toolbar. A page shows at once when picked, as theirs do: no fade between pages.
    var body: some View {
        NavigationSplitView {
            HubSidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: HubLayout.sidebarWidth, max: 280)
        } detail: {
            page(windows.hubSection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .navigationTitle(title)
                // Every page keeps a toolbar, tools or none: a page without one lost the window's toolbar, and the
                // sidebar then started under a separate title bar instead of reaching up around the window buttons.
                .toolbar { ToolbarSpacer(.flexible) }
        }
        .frame(minWidth: 820, minHeight: 560)
        .overlay(alignment: .topLeading) {
            if hub.drawsWindowControls { PreviewTrafficLights() }
        }
        // The key's status (and credit left) is a snapshot from the last check: refresh a stale one.
        .task {
            hub.account.refreshIfStale(maxAge: 300)
            hub.proxy.refreshIfStale(maxAge: 300)
        }
    }

    /// The page's name; a call's page is named by the call.
    private var title: String {
        guard windows.hubSection == .callDetail, let id = windows.openCallID,
              let call = hub.calls.call(id: id) else { return windows.hubSection.title }
        return CallFormat.shortTitle(call)
    }

    @ViewBuilder private func page(_ section: HubSection) -> some View {
        switch section {
        case .home: HomePage()
        case .calls: CallsPage()
        case .callDetail: CallDetailPage()
        case .models: ModelsPage()
        case .shortcuts: ShortcutsPage()
        case .dictionary: DictionaryPage()
        case .microphone: MicrophonePage()
        case .general: GeneralPage()
        case .softwareUpdate: SoftwareUpdatePage()
        }
    }
}

// MARK: - Sidebar

/// The pages, as a source list: Home and Calls, then Settings. Software Update keeps General selected, and an update
/// waiting (with reminders on) puts a count on General, as System Settings does; calls waiting for an answer or a
/// Retry put theirs on Calls. ⌘1…⌘N follow `HubSection.sidebar`.
private struct HubSidebar: View {
    @Environment(HubContext.self) private var hub
    @Environment(WindowCoordinator.self) private var windows
    @Environment(UpdateCenter.self) private var updates
    @Environment(CallStore.self) private var calls

    var body: some View {
        List(selection: selection) {
            ForEach(HubSection.sidebarTop) { section in
                row(section)
            }
            Section("Settings") {
                ForEach(HubSection.sidebar.filter { !HubSection.sidebarTop.contains($0) }) { section in
                    row(section)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Just the version: the main model and how it's doing are in Models, and a problem with it is on Home.
            Text(hub.versionLine)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .background { shortcuts }
    }

    private var selection: Binding<HubSection?> {
        let hub = hub, windows = windows
        return Binding(get: { windows.hubSection.sidebarItem }, set: { section in
            if let page = section.flatMap(windows.hubSection.pageOpened(byClicking:)) { hub.show(page) }
        })
    }

    private func row(_ section: HubSection) -> some View {
        Label(section.title, systemImage: section.symbolName)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Software Update keeps General selected, and a click on a row already selected changes no selection:
            // the click itself goes back to General.
            .simultaneousGesture(TapGesture().onEnded {
                if let page = windows.hubSection.pageOpened(byClicking: section) { hub.show(page) }
            })
            .badge(badge(section))
            .tag(section)
            .accessibilityLabel(accessibilityLabel(section))
    }

    private func badge(_ section: HubSection) -> Int {
        switch section {
        case .general: updates.showsBadge ? 1 : 0
        case .calls: CallsList.badgeCount(calls.calls, live: hub.callState)
        default: 0
        }
    }

    private func accessibilityLabel(_ section: HubSection) -> String {
        let count = badge(section)
        guard count > 0 else { return section.title }
        return section == .general ? "\(section.title), update available"
            : "\(section.title), \(count) waiting"
    }

    /// ⌘1…⌘N: a page each, as the sidebar lists them.
    private var shortcuts: some View {
        ZStack {
            ForEach(HubSection.sidebar) { section in
                if let digit = section.shortcutDigit {
                    Button(section.title) { hub.show(section) }
                        .keyboardShortcut(KeyEquivalent(digit), modifiers: .command)
                }
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
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
