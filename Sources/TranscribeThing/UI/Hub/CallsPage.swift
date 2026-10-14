import AppKit
import SwiftUI

/// The recorded calls, by day, as Home lists dictations: each call's app, title, speakers, length and where it stands,
/// with what it waits for (an answer, a Retry, a permission). A click opens the call (`CallDetailPage`).
struct CallsPage: View {
    @Environment(HubContext.self) private var hub
    @Environment(CallStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// The call whose trash was clicked, waiting for Delete (Return) or Cancel (Escape).
    @State private var confirmingDelete: CallRecord?
    @State private var hoverGate = ScrollHoverGate()

    var body: some View {
        let state = hub.callState
        let all = CallsList.calls(store.calls, live: state)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                if settings.callRecording == .off, !all.isEmpty {
                    Callout(.info, symbol: "phone.down", text: "Calls aren’t noticed: Record calls is Off.") {
                        Button("Change…") { hub.show(.general) }
                            .buttonStyle(SecondaryButtonStyle(size: .small))
                    }
                }
                if !settings.browserExtensionHintDismissed,
                   let browser = BrowserExtensionCopy.hintBrowser(calls: store.calls, browsers: hub.browserExtension.browsers,
                                                                  connections: hub.browserExtension.connections) {
                    BrowserExtensionHint(browser: browser)
                }
                if all.isEmpty {
                    CallsEmptyState()
                } else {
                    let days = CallsList.days(CallsList.filter(all, query: query), now: hub.now)
                    if days.isEmpty {
                        CallsNoMatches(query: query) { query = "" }
                    } else {
                        CallDays(days: days, askingID: CallsList.askingID(state)) { confirmingDelete = $0 }
                    }
                }
            }
            .padding(.horizontal, HubLayout.pageHorizontal)
            .padding(.top, HubLayout.pageTop)
            .padding(.bottom, HubLayout.pageBottom + 20)
            .frame(maxWidth: HubLayout.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, _ in hoverGate.scrolled() }
        .environment(\.scrollHoverGate, hoverGate)
        .searchable(text: $query, placement: .toolbar, prompt: "Search calls")
        .searchFocused($searchFocused)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { recordButton(state) }
        }
        .background {
            Button("Search") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .callDeleteAlert($confirmingDelete)
        .onAppear {
            if query.isEmpty { query = hub.initialSearch }
        }
    }

    /// Start Call Recording, as the menu bar has it; Stop while one is kept.
    @ViewBuilder private func recordButton(_ state: CallMonitor.State) -> some View {
        if case .recording = state {
            Button {
                hub.stopCall(keep: true)
            } label: {
                Label("Stop Call Recording", systemImage: "stop.circle")
            }
            .help("Stop Call Recording: it’s transcribed now")
        } else {
            Button {
                hub.startCallRecording()
            } label: {
                Label("Start Call Recording", systemImage: "record.circle")
            }
            .help("Start Call Recording: your mic and everything the Mac plays, until you stop it")
        }
    }
}

// MARK: - Actions

extension HubContext {
    /// Transcribe: a call never answered about (live or ended) is kept and transcribed; any other one again.
    func transcribeCall(_ call: CallRecord) {
        guard !isPreview else { return }
        if call.status == .unconfirmed || CallsList.askingID(callState) == call.id {
            callMonitor.keep(callID: call.id)
        } else {
            callTranscriber.retranscribe(call.id)
        }
    }

    /// Summarize: the summary from the call's transcript alone, text only (a call transcribed before summaries, or
    /// one whose summary failed).
    func summarizeCall(_ call: CallRecord) {
        guard !isPreview else { return }
        callTranscriber.summarize(call.id)
    }

    /// Whether Summarize can run on the call now: done, with something said, and not being summed up already.
    func canSummarize(_ call: CallRecord) -> Bool {
        call.status == .done && call.transcript.map { !$0.segments.isEmpty } == true
            && !calls.summarizing.contains(call.id)
    }

    /// Ticks a task of the call's summary off, or back on (a preview's store keeps it for the page only).
    func setTask(_ task: CallTask, done: Bool, in call: CallRecord) {
        calls.setTask(task.id, done: done, in: call.id)
    }

    /// Deletes the call and its audio. A call waiting for an answer is answered No, so its question goes too; a call
    /// being recorded stops.
    func deleteCall(_ call: CallRecord) {
        if windows.openCallID == call.id, windows.hubSection == .callDetail { show(.calls) }
        guard !isPreview else { return }
        if call.status == .unconfirmed || CallsList.askingID(callState) == call.id {
            callMonitor.discard(callID: call.id)
        } else {
            calls.delete(call.id)
        }
    }

    func stopCall(keep: Bool) {
        guard !isPreview else { return }
        callMonitor.stop(keep: keep)
    }

    func startCallRecording() {
        guard !isPreview else { return }
        callMonitor.startManual()
    }

    func openSettings(_ pane: SettingsPane) {
        guard !isPreview else { return }
        permissions.open(pane)
    }
}

extension View {
    /// "Delete This Call?": Delete is the default (Return), Cancel is Escape, as History's.
    func callDeleteAlert(_ call: Binding<CallRecord?>, onDeleted: @escaping () -> Void = {}) -> some View {
        modifier(CallDeleteAlert(call: call, onDeleted: onDeleted))
    }
}

private struct CallDeleteAlert: ViewModifier {
    @Binding var call: CallRecord?
    var onDeleted: () -> Void
    @Environment(HubContext.self) private var hub

    func body(content: Content) -> some View {
        content.alert(call?.status == .recording ? "Stop and Delete This Call?" : "Delete This Call?",
                      isPresented: Binding(get: { call != nil }, set: { if !$0 { call = nil } }),
                      presenting: call) { call in
            Button("Delete", role: .destructive) {
                hub.deleteCall(call)
                onDeleted()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its recording and transcript go too. This can’t be undone.")
        }
    }
}

// MARK: - Days

private struct CallDays: View {
    var days: [CallDay]
    var askingID: UUID?
    var onDelete: (CallRecord) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(days) { day in
                Section {
                    ForEach(day.calls) { call in
                        let isFirst = call.id == day.calls.first?.id
                        let isLast = call.id == day.calls.last?.id
                        VStack(spacing: 0) {
                            if !isFirst {
                                RowDivider(inset: 56)
                            }
                            CallRow(call: call, isAsking: call.id == askingID, isFirst: isFirst, isLast: isLast,
                                    onDelete: onDelete)
                        }
                        .cardSegment(isFirst: isFirst, isLast: isLast)
                        .padding(.top, isFirst ? Theme.Spacing.md : 0)
                        .padding(.bottom, isLast && day.id != days.last?.id ? Theme.Spacing.md : 0)
                    }
                } header: {
                    // Set as Home's day headers: "Today", bold, over its card.
                    HStack(alignment: .firstTextBaseline) {
                        Text(day.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.ink)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 8)
                        Text(day.calls.count == 1 ? "1 call" : "\(day.calls.count) calls")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.inkTertiary)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - Row

struct CallRow: View {
    var call: CallRecord
    /// The live call waiting for "Transcribe your call?".
    var isAsking = false
    var isFirst = false
    var isLast = false
    var onDelete: (CallRecord) -> Void
    @Environment(HubContext.self) private var hub
    @State private var hovering = false

    private var showsActions: Bool { hovering || hub.previewHoveredCall == call.id }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CallAppIcon(call: call, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(CallFormat.title(call))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                    // A place's title ("Google Meet · Meet – abc-defg-hij") keeps both ends; a title of its own, its start.
                    .truncationMode(CallFormat.generatedTitle(call) == nil ? .middle : .tail)
                if let line = CallFormat.rowSubtitle(call) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(line)
                            .font(.system(size: 12))
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(1)
                        if let tasks = CallFormat.taskCount(call) {
                            Label(tasks, systemImage: "checklist")
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(.inkTertiary)
                                .labelStyle(.titleAndIcon)
                                .fixedSize()
                                .help("Tasks from the call’s summary, ticked off of all")
                        }
                    }
                }
                CallStatusLine(call: call, isAsking: isAsking, onDelete: onDelete)
                    .padding(.top, call.status == .done && CallFormat.problems(call).isEmpty ? 0 : 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 11)
        .frame(minHeight: 52)
        .background {
            let radius = Theme.Radius.card
            UnevenRoundedRectangle(topLeadingRadius: isFirst ? radius : 0, bottomLeadingRadius: isLast ? radius : 0,
                                   bottomTrailingRadius: isLast ? radius : 0, topTrailingRadius: isFirst ? radius : 0,
                                   style: .continuous)
                .fill(showsActions ? Color.hover.opacity(0.7) : .clear)
        }
        .contentShape(Rectangle())
        .onSettledHover { hovering = $0 }
        .onTapGesture { hub.showCall(call.id) }
        .contextMenu { menu }
        .animation(Theme.Motion.hover, value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open") { hub.showCall(call.id) }
    }

    private var trailing: some View {
        ZStack(alignment: .topTrailing) {
            meta
                .padding(.top, 1)
                .opacity(showsActions ? 0 : 1)
            actions
                .padding(.top, -4)
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions)
        }
        .frame(minWidth: 96, alignment: .topTrailing)
    }

    private var meta: some View {
        HStack(spacing: 8) {
            // What its transcription cost, as Home's rows say a dictation's.
            if let cost = call.costUSD, cost > 0 {
                Text(Fmt.usd(cost))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.inkTertiary)
            }
            Text(Fmt.time(call.startedAt))
                .font(.system(size: 11.5))
                .foregroundStyle(.inkTertiary)
            CallDurationText(call: call)
                .font(.system(size: 11.5))
                .foregroundStyle(.inkTertiary)
                .frame(minWidth: 34, alignment: .trailing)
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if call.transcript.map({ !$0.segments.isEmpty }) == true {
                CopyButton(text: CallFormat.copyText(call)) { hub.copy($0) }
                    .help("Copy Transcript")
            }
            Button {
                onDelete(call)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .help("Delete")
            .accessibilityLabel("Delete call")
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Open") { hub.showCall(call.id) }
        if call.transcript.map({ !$0.segments.isEmpty }) == true {
            Button("Copy Transcript") { hub.copy(CallFormat.copyText(call)) }
        }
        if call.summary != nil {
            Button("Copy Summary") { hub.copy(CallFormat.summaryText(call)) }
        } else if hub.canSummarize(call) {
            Button("Summarize") { hub.summarizeCall(call) }
        }
        if call.micFile != nil || call.remoteFile != nil {
            Button("Show in Finder") { hub.revealCall(call.id) }
        }
        Divider()
        Button("Delete", role: .destructive) { onDelete(call) }
    }
}

/// "32:14", or a live call's length so far, counting.
struct CallDurationText: View {
    var call: CallRecord
    @Environment(HubContext.self) private var hub

    var body: some View {
        if call.status == .recording {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Fmt.duration(CallFormat.duration(call, now: hub.fixedNow ?? context.date)))
            }
        } else {
            Text(Fmt.duration(call.duration))
        }
    }
}

// MARK: - Status

/// Where the call stands, with what it waits for: recording, transcribing, an answer, a Retry, a permission. A done
/// call with nothing wrong says nothing.
struct CallStatusLine: View {
    var call: CallRecord
    var isAsking = false
    var onDelete: (CallRecord) -> Void
    @Environment(HubContext.self) private var hub

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            status
            ForEach(CallFormat.problems(call), id: \.self) { problem in
                CallProblemLine(problem: problem)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch call.status {
        case .recording:
            HStack(alignment: .center, spacing: 8) {
                RecordingDot()
                Text(isAsking ? "Recording, waiting for your answer" : "Recording")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.ink)
                if isAsking {
                    lineButton("Transcribe") { hub.transcribeCall(call) }
                    lineButton("Don’t Keep") { onDelete(call) }
                } else if CallsList.liveInfo(hub.callState)?.id == call.id {
                    lineButton("Stop") { hub.stopCall(keep: true) }
                }
            }
        case .transcribing:
            HStack(alignment: .center, spacing: 8) {
                ShimmerBar(height: 3)
                    .frame(width: 40)
                Text("Transcribing with \(hub.settings.callEngine.shortName)…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.inkSecondary)
            }
        case .failed:
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().fill(Color.danger).frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                Text("\(Text("Couldn’t transcribe").fontWeight(.medium).foregroundStyle(Color.ink)) · \(CallFormat.failure(call))")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if hasAudio {
                    lineButton("Retry") { hub.transcribeCall(call) }
                }
            }
        case .unconfirmed:
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.warning)
                Text("Not transcribed yet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.ink)
                lineButton("Transcribe") { hub.transcribeCall(call) }
                lineButton("Delete") { onDelete(call) }
            }
        case .interrupted:
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.warning)
                Text("The app quit during this call")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.ink)
                if hasAudio {
                    lineButton("Transcribe") { hub.transcribeCall(call) }
                }
            }
        case .done:
            if call.transcript.map(\.segments.isEmpty) ?? true {
                Text("No speech in this call")
                    .font(.system(size: 12))
                    .foregroundStyle(.inkTertiary)
            }
        }
    }

    private var hasAudio: Bool { call.micFile != nil || call.remoteFile != nil }

    private func lineButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(QuietButtonStyle(size: .small))
            .padding(.vertical, -6)
    }
}

/// "Their side wasn't recorded: allow System Audio Recording in Privacy & Security." with Open Settings.
struct CallProblemLine: View {
    var problem: CallProblem
    @Environment(HubContext.self) private var hub

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(.warning)
            Text(problem.text)
                .font(.system(size: 12))
                .foregroundStyle(.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let pane = problem.pane {
                Button("Open Settings") { hub.openSettings(pane) }
                    .buttonStyle(QuietButtonStyle(size: .small))
                    .padding(.vertical, -6)
                    .fixedSize()
            }
        }
    }
}

/// The red dot of a call being recorded, breathing.
struct RecordingDot: View {
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seconds from bright to faint and back.
    private static let period: TimeInterval = 1.8

    /// Its opacity follows the clock rather than an animation: an animation also carried the dot's first move into
    /// place, and on a call's page it slid in from the window's edge.
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate / Self.period * 2 * .pi
            Circle()
                .fill(Color(nsColor: .systemRed))
                .frame(width: size, height: size)
                .opacity(reduceMotion ? 1 : 0.675 + 0.325 * cos(phase))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Icons

/// The call app's own icon (the browser's for a call in a tab); a phone, or a waveform for a menu bar recording, when
/// the app isn't on this Mac.
struct CallAppIcon: View {
    var call: CallRecord
    var size: CGFloat = 30

    var body: some View {
        if !call.manual, let image = CallAppIcons.image(for: call.bundleID) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            IconTile(symbol: call.manual ? "waveform" : "phone.fill", tint: .inkSecondary, size: size * 0.9)
                .frame(width: size, height: size)
        }
    }
}

@MainActor
enum CallAppIcons {
    private static var cache: [String: NSImage?] = [:]

    static func image(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = image
        return image
    }
}

// MARK: - Empty states

/// After a call in a Chromium browser that has no extension in any profile: what it would do, Set Up (General),
/// and × to never show it again.
private struct BrowserExtensionHint: View {
    var browser: BrowserExtension.Browser
    @Environment(HubContext.self) private var hub
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Callout(.info, symbol: "puzzlepiece.extension", text: BrowserExtensionCopy.callsHint(browser: browser.name)) {
            HStack(spacing: 6) {
                Button("Set Up…") { hub.show(.general) }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
                Button {
                    settings.browserExtensionHintDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.inkTertiary)
                .help("Don’t show again")
                .accessibilityLabel("Don’t show again")
            }
        }
    }
}

private struct CallsEmptyState: View {
    @Environment(AppSettings.self) private var settings
    @Environment(HubContext.self) private var hub

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 12) {
            ZStack {
                StageBackground(cornerRadius: 22)
                    .frame(width: 176, height: 84)
                Image(systemName: "phone.badge.waveform.fill")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.ink)
            }
            .padding(.bottom, 4)
            Text("No calls yet")
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(.ink)
            Text("Calls are recorded here, then transcribed with who said what. \(CallsCopy.whatIsACall) "
                 + "Mute is followed in \(CallsCopy.muteFollowed).")
                .font(.system(size: 13))
                .foregroundStyle(.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
            Text(modeLine)
                .font(.system(size: 13))
                .foregroundStyle(.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
            HStack(spacing: 8) {
                Text("Record calls")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.ink)
                HubMenuPicker(title: "Record calls", options: CallRecordingMode.pickerOrder,
                              selection: $settings.callRecording, label: \.title)
            }
            .padding(.top, 4)
            Text("Anything else: Start Call Recording in the menu bar records your mic and everything the Mac plays.")
                .font(.system(size: 12))
                .foregroundStyle(.inkTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
                .padding(.top, 2)
            if offersExtension {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { extensionLine }
                        .fixedSize()
                    VStack(spacing: 2) { extensionLine }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color.strokeStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }

    @ViewBuilder private var extensionLine: some View {
        Text("Calls in a browser are noticed more surely with the browser extension.")
            .font(.system(size: 12))
            .foregroundStyle(.inkTertiary)
            .multilineTextAlignment(.center)
        Button("Set Up…") { hub.show(.general) }
            .buttonStyle(QuietButtonStyle(tint: .accent, size: .small))
    }

    /// A Chromium browser is here and no profile has the extension.
    private var offersExtension: Bool {
        let ext = hub.browserExtension
        return ext.connections.isEmpty && ext.browsers.contains { $0.family == .chromium }
    }

    private var modeLine: String {
        switch settings.callRecording {
        case .off: "Record calls is Off, so calls aren’t noticed."
        case .ask: "When a call starts, you’re asked whether to transcribe it. Nothing is sent until you say so."
        case .automatic: "Each call is recorded, and transcribed when it ends."
        }
    }
}

private struct CallsNoMatches: View {
    var query: String
    var onClear: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.inkTertiary)
            Text("No calls match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                .font(.system(size: 13))
                .foregroundStyle(.inkSecondary)
                .multilineTextAlignment(.center)
            Button("Clear Search", action: onClear)
                .buttonStyle(.appQuiet)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}
