import AppKit
import SwiftUI

// MARK: - Host context

/// How recorders reach the rest of the app without globals: a window root installs it once with
/// `.shortcutRecorderHost(hotkeys:settings:)`.
struct ShortcutRecordingContext: Sendable {
    /// All bindings, for conflict checks and Swap.
    var settings: AppSettings?
    /// true when a recorder starts capturing keys, false when it stops (always paired).
    var setCapturing: @MainActor @Sendable (Bool) -> Void
}

private struct ShortcutRecordingContextKey: EnvironmentKey {
    static let defaultValue: ShortcutRecordingContext? = nil
}

private struct ShortcutRecorderPreviewMessagesKey: EnvironmentKey {
    static let defaultValue: [ShortcutAction: RecorderMessage] = [:]
}

extension EnvironmentValues {
    var shortcutRecordingContext: ShortcutRecordingContext? {
        get { self[ShortcutRecordingContextKey.self] }
        set { self[ShortcutRecordingContextKey.self] = newValue }
    }

    /// Snapshots of whole pages: the message each action's recorder shows as if a shortcut was just recorded.
    var shortcutRecorderPreviewMessages: [ShortcutAction: RecorderMessage] {
        get { self[ShortcutRecorderPreviewMessagesKey.self] }
        set { self[ShortcutRecorderPreviewMessagesKey.self] = newValue }
    }
}

extension View {
    /// Global hotkeys pause while any recorder below captures keys (otherwise pressing fn to record it
    /// would start a dictation), and recorders validate against, and swap with, the saved bindings.
    func shortcutRecorderHost(hotkeys: HotkeyMonitor, settings: AppSettings) -> some View {
        environment(\.shortcutRecordingContext, ShortcutRecordingContext(settings: settings) { [weak hotkeys] capturing in
            if capturing { hotkeys?.suspend() } else { hotkeys?.resume() }
        })
    }
}

// MARK: - Recorder

/// Shows a shortcut as key caps with a "Change" action; while recording it becomes a dashed iris field that
/// captures modifier-only chords and combinations. Any shortcut is saved; why it may get in the way (a macOS
/// shortcut that is on, a typing key) appears inline underneath as a warning. Only a clash with another action
/// is refused, with Swap offered for a duplicate.
struct ShortcutRecorderView: View {
    enum PreviewState {
        case recording(held: Shortcut?)
        case message(RecorderMessage)
    }

    private enum Source {
        case binding(Binding<Shortcut?>)
        case settings(AppSettings)
    }

    let action: ShortcutAction
    private let source: Source
    private let alignment: HorizontalAlignment
    private let explicitCapturing: (@MainActor (Bool) -> Void)?
    private let isLive: Bool

    @Environment(\.shortcutRecordingContext) private var context
    @Environment(\.shortcutRecorderPreviewMessages) private var previewMessages
    @State private var isRecording: Bool
    @State private var held: Shortcut?
    @State private var message: RecorderMessage?

    /// Uses the host context (`.shortcutRecorderHost`) for hotkey suspension, conflicts and Swap.
    init(shortcut: Binding<Shortcut?>, action: ShortcutAction, alignment: HorizontalAlignment = .trailing) {
        self.init(source: .binding(shortcut), action: action, alignment: alignment, capturing: nil, preview: nil)
    }

    /// Reads and writes `settings.shortcuts[action]` and pauses `hotkeys` while recording.
    init(action: ShortcutAction, settings: AppSettings, hotkeys: HotkeyMonitor?,
         alignment: HorizontalAlignment = .trailing) {
        let capturing: (@MainActor (Bool) -> Void)? = hotkeys.map { monitor in
            { [weak monitor] on in if on { monitor?.suspend() } else { monitor?.resume() } }
        }
        self.init(source: .settings(settings), action: action, alignment: alignment, capturing: capturing, preview: nil)
    }

    /// Snapshots: a frozen state, no key capture.
    init(shortcut: Binding<Shortcut?>, action: ShortcutAction, previewState: PreviewState,
         alignment: HorizontalAlignment = .trailing) {
        self.init(source: .binding(shortcut), action: action, alignment: alignment, capturing: nil, preview: previewState)
    }

    private init(source: Source, action: ShortcutAction, alignment: HorizontalAlignment,
                 capturing: (@MainActor (Bool) -> Void)?, preview: PreviewState?) {
        self.source = source
        self.action = action
        self.alignment = alignment
        self.explicitCapturing = capturing
        self.isLive = preview == nil
        switch preview {
        case .recording(let held)?:
            _isRecording = State(initialValue: true)
            _held = State(initialValue: held)
            _message = State(initialValue: nil)
        case .message(let message)?:
            _isRecording = State(initialValue: false)
            _held = State(initialValue: nil)
            _message = State(initialValue: message)
        case nil:
            _isRecording = State(initialValue: false)
            _held = State(initialValue: nil)
            _message = State(initialValue: nil)
        }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: alignment, spacing: 7) {
            control
                .background {
                    ShortcutCaptureRepresentable(
                        action: action, isRecording: $isRecording, isLive: isLive,
                        setCapturing: capturingHandler,
                        onHeldChanged: { held = $0 },
                        onResult: handle)
                }
                // In a SettingsRow the title lines up with the keys, not with the middle of keys + note.
                .alignmentGuide(.settingsRowAccessory) { $0[VerticalAlignment.center] }
            if isRecording {
                RecordingHint(action: action)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let message = shownMessage {
                RecorderMessageView(message: message, alignment: alignment, onSwap: swap, onUse: apply,
                                    onDismiss: { self.message = nil })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Theme.Motion.snappy, value: isRecording)
        .animation(Theme.Motion.snappy, value: shownMessage)
        // Rows size to the message underneath, and the message gets room before a row's subtitle does.
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }

    @ViewBuilder private var control: some View {
        if isRecording {
            RecordingField(held: held) { isRecording = false }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: alignment == .leading ? .leading : .trailing)))
        } else {
            IdleShortcut(shortcut: currentShortcut, action: action, alignment: alignment) { startRecording() }
                .contextMenu { contextMenu }
                .transition(.opacity)
        }
    }

    @ViewBuilder private var contextMenu: some View {
        Button("Change Shortcut") { startRecording() }
        if let fallback = ShortcutBindings.defaults[action], fallback != currentShortcut {
            Button("Reset to \(fallback.compactDescription)") { apply(fallback) }
        }
        if ShortcutCaptureEngine.canClear(action), currentShortcut != nil {
            Button("Remove Shortcut") { write(nil); message = nil }
        }
    }

    // MARK: State

    private var shownMessage: RecorderMessage? { message ?? previewMessages[action] }

    private var currentShortcut: Shortcut? {
        switch source {
        case .binding(let binding): binding.wrappedValue
        case .settings(let settings): settings.shortcuts[action]
        }
    }

    private var settings: AppSettings? {
        switch source {
        case .binding: context?.settings
        case .settings(let settings): settings
        }
    }

    /// Every binding as saved, with this action's current value (the binding may not be backed by settings).
    private var allBindings: ShortcutBindings {
        var bindings = settings?.shortcuts ?? ShortcutBindings(bindings: [:])
        bindings[action] = currentShortcut
        return bindings
    }

    private var capturingHandler: (@MainActor (Bool) -> Void)? {
        if let explicitCapturing { return explicitCapturing }
        return context.map { context in { context.setCapturing($0) } }
    }

    private func startRecording() {
        message = nil
        held = nil
        isRecording = true
    }

    private func handle(_ result: ShortcutCaptureEngine.Result) {
        isRecording = false
        held = nil
        switch result {
        case .none, .cancel:
            break
        case .clear:
            write(nil)
            message = nil
        case .commit(let shortcut):
            apply(shortcut)
        }
    }

    private func apply(_ shortcut: Shortcut) {
        let outcome = ShortcutEdit.evaluate(shortcut, for: action, bindings: allBindings, swapAllowed: settings != nil)
        if case .apply = outcome { write(shortcut) }
        message = RecorderMessage(outcome, recording: shortcut)
    }

    private func swap() {
        guard case .conflict(let other, let attempted)? = message, let settings else { return }
        let swapped = ShortcutEdit.swapping(allBindings, action: action, to: attempted, with: other)
        settings.shortcuts[other] = swapped[other]
        write(attempted)
        message = .swapped(other, warning: ShortcutEdit.warningAfterSwap(swapped, action: action, other: other))
    }

    private func write(_ shortcut: Shortcut?) {
        switch source {
        case .binding(let binding): binding.wrappedValue = shortcut
        case .settings(let settings): settings.shortcuts[action] = shortcut
        }
    }
}

// MARK: - Messages

enum RecorderMessage: Equatable {
    /// Not saved: it can't work next to another action's shortcut.
    case error(String, attempted: Shortcut)
    /// Saved, and it may get in the way. `suggestion`: a binding that avoids the problem (Right ⌥ for ⌥),
    /// offered as a one-click fix.
    case warning(ShortcutWarning, suggestion: Shortcut?)
    case conflict(ShortcutAction, attempted: Shortcut)
    case swapped(ShortcutAction, warning: ShortcutWarning?)

    /// What the recorder says after recording `shortcut`; nil when there is nothing to say.
    init?(_ outcome: ShortcutEdit.Outcome, recording shortcut: Shortcut) {
        switch outcome {
        case .unchanged, .apply(warning: nil):
            return nil
        case .apply(let warning?):
            self = .warning(warning, suggestion: ShortcutEdit.betterSide(for: shortcut))
        case .reject(let reason):
            self = .error(reason, attempted: shortcut)
        case .offerSwap(let other):
            self = .conflict(other, attempted: shortcut)
        }
    }
}

private struct RecorderMessageView: View {
    let message: RecorderMessage
    let alignment: HorizontalAlignment
    var onSwap: () -> Void
    var onUse: (Shortcut) -> Void
    var onDismiss: () -> Void

    var body: some View {
        bubble
            .frame(maxWidth: 340, alignment: alignment == .leading ? .leading : .trailing)
    }

    @ViewBuilder private var bubble: some View {
        switch message {
        case .error(let text, let attempted):
            MessageBubble(symbol: "exclamationmark.circle.fill", tint: .danger) {
                HStack(spacing: 5) {
                    Text("Can’t use").foregroundStyle(.ink).fontWeight(.medium)
                    ShortcutChips(shortcut: attempted, size: .small)
                }
                Text(text).foregroundStyle(.inkSecondary)
            }
        case .warning(let warning, let suggestion):
            MessageBubble(symbol: "exclamationmark.triangle.fill", tint: .warning) {
                WarningLines(warning: warning)
                if let suggestion {
                    Button("Use \(suggestion.compactDescription)") { onUse(suggestion) }
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                        .padding(.top, 2)
                }
            }
        case .conflict(let other, let attempted):
            MessageBubble(symbol: "arrow.left.arrow.right.circle.fill", tint: .accent) {
                HStack(spacing: 5) {
                    ShortcutChips(shortcut: attempted, size: .small)
                    Text("is used for \(other.title.lowercased())")
                        .foregroundStyle(.ink).fontWeight(.medium)
                }
                HStack(spacing: 6) {
                    Button("Swap", action: onSwap)
                        .buttonStyle(PrimaryButtonStyle(size: .small))
                        .help("\(other.title) takes this action’s current shortcut")
                    Button("Keep Current", action: onDismiss)
                        .buttonStyle(QuietButtonStyle(tint: .inkSecondary))
                }
                .padding(.top, 2)
            }
        case .swapped(let other, let warning):
            if let warning {
                MessageBubble(symbol: "exclamationmark.triangle.fill", tint: .warning) {
                    Text("Swapped with \(other.title.lowercased()).").foregroundStyle(.ink).fontWeight(.medium)
                    Text(warning.text).foregroundStyle(.inkSecondary)
                }
            } else {
                MessageBubble(symbol: "checkmark.circle.fill", tint: .success) {
                    Text("Swapped with \(other.title.lowercased()).").foregroundStyle(.inkSecondary)
                }
            }
        }
    }
}

/// A saved shortcut's warning: what else reacts to it, then (quieter) what to do about it.
private struct WarningLines: View {
    let warning: ShortcutWarning

    var body: some View {
        Text(warning.text).foregroundStyle(.ink).fontWeight(.medium)
        if let detail = warning.detail {
            Text(detail).foregroundStyle(.inkSecondary)
                .padding(.top, -3)
        }
    }
}

/// A small tinted callout under the recorder: icon, then stacked lines.
private struct MessageBubble<Content: View>: View {
    let symbol: String
    let tint: Color
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(height: 18)
            VStack(alignment: .leading, spacing: 6) {
                content
            }
        }
        .typeface(.callout)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(shape.fill(tint.opacity(scheme == .dark ? 0.12 : 0.07)))
        .overlay(shape.strokeBorder(tint.opacity(scheme == .dark ? 0.22 : 0.16), lineWidth: 1))
    }
}

// MARK: - Idle

private struct IdleShortcut: View {
    let shortcut: Shortcut?
    let action: ShortcutAction
    let alignment: HorizontalAlignment
    var onChange: () -> Void
    @State private var hovering = false

    /// The hover wash around the chips is an inset, not a margin: the caps line up with neighbouring text.
    private let washInset: CGFloat = 5

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onChange) {
                ShortcutChips(shortcut: shortcut, placeholder: "Not set")
                    .padding(.horizontal, washInset)
                    .padding(.vertical, 4)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(hovering ? Color.hover : .clear)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.leading, alignment == .leading ? -washInset : 0)
            .onHover { hovering = $0 }
            .animation(Theme.Motion.hover, value: hovering)
            .accessibilityLabel("\(action.title): \(shortcut?.spokenDescription ?? "not set")")
            .accessibilityHint("Records a new shortcut")

            Button(shortcut == nil ? "Set" : "Change", action: onChange)
                .buttonStyle(QuietButtonStyle())
                .accessibilityHidden(true)
                // The label, not its hover wash, lines up with the row's trailing edge.
                .padding(.trailing, -8)
        }
    }
}

// MARK: - Recording

private struct RecordingField: View {
    let held: Shortcut?
    var onStop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.control + 1, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: .accent, size: 6, pulsing: true)
                .frame(width: 14, height: 14)
            ZStack(alignment: .leading) {
                if let held, !held.isEmpty {
                    ShortcutChips(shortcut: held, size: .small)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                } else {
                    Text("Press keys…")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.accent)
                        .transition(.opacity)
                }
            }
            .animation(Theme.Motion.hover, value: held)
            Spacer(minLength: 6)
            Button(action: onStop) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(size: 20, tint: .inkSecondary))
            .help("Stop recording")
            .accessibilityLabel("Stop recording")
        }
        .padding(.leading, 6)
        .padding(.trailing, 5)
        .frame(width: 184, height: 32)
        .background(shape.fill(Color.accentSoft))
        .overlay {
            shape.strokeBorder(Color.accent.opacity(breathing ? 0.95 : 0.5),
                               style: StrokeStyle(lineWidth: 1.25, dash: [4, 3]))
        }
        .background(shape.inset(by: -3).fill(Color.accent.opacity(breathing ? 0.10 : 0.04)))
        .onAppear {
            guard !reduceMotion else {
                breathing = true
                return
            }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathing = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording shortcut. Press keys.")
    }
}

private struct RecordingHint: View {
    let action: ShortcutAction

    var body: some View {
        HStack(spacing: 10) {
            Text(action == .pushToTalk ? "Hold keys, then let go" : "Press a combination")
                .foregroundStyle(.inkTertiary)
            if action == .cancel {
                Text("× stops recording").foregroundStyle(.inkTertiary)
            } else {
                hint("esc", "cancel")
            }
            if ShortcutCaptureEngine.canClear(action) {
                hint("delete", "clear")
            }
        }
        .typeface(.caption)
        .lineLimit(1)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            KeyChip(label: key, size: .small)
            Text(label).foregroundStyle(.inkTertiary)
        }
    }
}

// MARK: - Key capture

/// Invisible NSView behind the control: while recording it holds first responder and a local event monitor
/// that swallows every key (so ⌘W or ⌘Q are recorded instead of acting on the window).
private struct ShortcutCaptureRepresentable: NSViewRepresentable {
    let action: ShortcutAction
    @Binding var isRecording: Bool
    let isLive: Bool
    let setCapturing: (@MainActor (Bool) -> Void)?
    let onHeldChanged: (Shortcut?) -> Void
    let onResult: (ShortcutCaptureEngine.Result) -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        ShortcutCaptureNSView()
    }

    func updateNSView(_ view: ShortcutCaptureNSView, context: Context) {
        view.onHeldChanged = onHeldChanged
        view.onResult = onResult
        view.onStoppedByUser = { isRecording = false }
        guard isLive else { return }
        if isRecording && !view.isRecording {
            view.startRecording(action: action, setCapturing: setCapturing)
        } else if !isRecording && view.isRecording {
            view.stopRecording(notify: false)
        }
    }

    static func dismantleNSView(_ view: ShortcutCaptureNSView, coordinator: ()) {
        view.stopRecording(notify: false)
    }
}

final class ShortcutCaptureNSView: NSView {
    var onHeldChanged: ((Shortcut?) -> Void)?
    var onResult: ((ShortcutCaptureEngine.Result) -> Void)?
    var onStoppedByUser: (() -> Void)?
    private(set) var isRecording = false

    private var engine = ShortcutCaptureEngine(action: .pushToTalk)
    private var monitor: Any?
    private var capturing: (@MainActor (Bool) -> Void)?
    private var resignObserver: MainNotificationObserver?

    override var acceptsFirstResponder: Bool { true }
    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    func startRecording(action: ShortcutAction, setCapturing: (@MainActor (Bool) -> Void)?) {
        guard !isRecording else { return }
        isRecording = true
        engine = ShortcutCaptureEngine(action: action)
        // Paired with exactly one `false` in stopRecording, whatever ends the recording.
        capturing = setCapturing
        capturing?(true)
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            // Local monitors run on the main thread.
            let swallow = MainActor.assumeIsolated { self?.swallows(event) ?? false }
            return swallow ? nil : event
        }
        if let window {
            resignObserver = MainNotificationObserver(center: .default, name: NSWindow.didResignKeyNotification,
                                                      object: window) { [weak self] in
                self?.stopRecording(notify: true)
            }
        }
    }

    func stopRecording(notify: Bool) {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        resignObserver = nil
        capturing?(false)
        capturing = nil
        engine.reset()
        // May run inside a SwiftUI update (focus change, view removal): report on the next turn.
        if notify, let onStoppedByUser { DispatchQueue.main.async(execute: onStoppedByUser) }
    }

    /// Every key event is swallowed while recording; clicks pass through (and end recording when outside).
    private func swallows(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        let result: ShortcutCaptureEngine.Result
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            let inside = event.window === window && bounds.contains(convert(event.locationInWindow, from: nil))
            if !inside { stopRecording(notify: true) }
            return false
        case .flagsChanged:
            result = engine.flagsChanged(keyCode: event.keyCode, rawFlags: UInt64(event.modifierFlags.rawValue))
            onHeldChanged?(engine.held)
        case .keyDown:
            result = engine.keyDown(keyCode: event.keyCode, rawFlags: UInt64(event.modifierFlags.rawValue),
                                    isRepeat: event.isARepeat)
        default:
            return true
        }
        if result != .none {
            stopRecording(notify: false)
            onResult?(result)
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        stopRecording(notify: true)
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopRecording(notify: true) }
        super.viewWillMove(toWindow: newWindow)
    }
}

// MARK: - Snapshots

/// Recorder states for visual QA. Not in `SnapshotCatalog` (owned by SHELL); rendered by `SystemSnapshotTests`
/// when `TRANSCRIBE_THING_SNAPSHOT_DIR` is set, and available for the catalog as `ShortcutRecorderSnapshots.entries`.
enum ShortcutRecorderSnapshots {
    @MainActor static var entries: [SnapshotEntry] {
        [SnapshotEntry("system-shortcut-recorder", width: 640, height: 1420) { _ in RecorderGallery() },
         SnapshotEntry("system-shortcut-recorder-leading", width: 520, height: 420) { _ in RecorderLeadingDemo() }]
    }

    /// macOS's default shortcuts all on and 🌐 set to Do Nothing, so snapshots don't depend on this Mac.
    static let system = SystemKeyboardState(hotKeys: SystemSymbolicHotKeys.active(in: nil), fnUsage: .doNothing,
                                            functionKeysAreStandard: false)
    static let controlOptionSpace = Shortcut(modifiers: [.init(.control), .init(.option)], keyCode: KeyCode.space)

    /// What the recorder shows right after recording `shortcut`, with the real validator's copy.
    static func message(recording shortcut: Shortcut, for action: ShortcutAction,
                        bindings: ShortcutBindings = .defaults) -> RecorderMessage? {
        RecorderMessage(ShortcutEdit.evaluate(shortcut, for: action, bindings: bindings, swapAllowed: true, system: system),
                        recording: shortcut)
    }
}

private struct RecorderGallery: View {
    private let defaults = ShortcutBindings.defaults

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader("Shortcuts")
            SettingsGroup {
                ForEach(ShortcutAction.allCases) { action in
                    row(action) {
                        ShortcutRecorderView(shortcut: .constant(defaults[action]), action: action)
                    }
                }
            }
            SectionHeader("Recorder states")
                .padding(.top, Theme.Spacing.xs)
            SettingsGroup {
                row(.pushToTalk) {
                    ShortcutRecorderView(shortcut: .constant(.fn), action: .pushToTalk,
                                         previewState: .recording(held: nil))
                }
                row(.pushToTalk) {
                    ShortcutRecorderView(shortcut: .constant(.fn), action: .pushToTalk,
                                         previewState: .recording(held: Shortcut(modifiers: [.init(.control), .init(.option, .right)])))
                }
                // Saved with a warning: a macOS shortcut that is on.
                saved(ShortcutRecorderSnapshots.controlOptionSpace, for: .handsFree)
                // Saved with a warning: a key that types.
                saved(Shortcut(modifiers: [], keyCode: KeyCode.space), for: .handsFree)
                // Saved with a warning and a one-click fix.
                saved(Shortcut(modifiers: [.init(.option)]), for: .pushToTalk)
                row(.pasteLast) {
                    ShortcutRecorderView(shortcut: .constant(.commandFnV), action: .pasteLast,
                                         previewState: .message(.conflict(.handsFree, attempted: .fnSpace)))
                }
                // Not saved: it would go off on the way to push to talk.
                recorded(Shortcut(modifiers: [.init(.control, .right)]), for: .handsFree, current: .fnSpace,
                         bindings: bindings([.pushToTalk: Shortcut(modifiers: [.init(.control), .init(.option)])]))
                row(.handsFree) {
                    ShortcutRecorderView(shortcut: .constant(.rightOption), action: .handsFree,
                                         previewState: .message(.swapped(.pushToTalk, warning: nil)))
                }
                row(.copyLast) {
                    ShortcutRecorderView(shortcut: .constant(nil), action: .copyLast)
                }
            }
        }
        .padding(Theme.Spacing.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.bgCanvas)
    }

    /// `shortcut` recorded over the defaults and saved: the row shows it with its warning.
    private func saved(_ shortcut: Shortcut, for action: ShortcutAction) -> some View {
        recorded(shortcut, for: action, current: shortcut, bindings: defaults)
    }

    /// `shortcut` recorded over `bindings`; the row shows `current` (the new value when saved).
    @ViewBuilder
    private func recorded(_ shortcut: Shortcut, for action: ShortcutAction, current: Shortcut?,
                          bindings: ShortcutBindings) -> some View {
        if let message = ShortcutRecorderSnapshots.message(recording: shortcut, for: action, bindings: bindings) {
            row(action) {
                ShortcutRecorderView(shortcut: .constant(current), action: action, previewState: .message(message))
            }
        }
    }

    private func bindings(_ changes: [ShortcutAction: Shortcut]) -> ShortcutBindings {
        var result = defaults
        for (action, shortcut) in changes { result[action] = shortcut }
        return result
    }

    private func row<Trailing: View>(_ action: ShortcutAction, @ViewBuilder trailing: () -> Trailing) -> some View {
        SettingsRow(title: action.title, subtitle: action.subtitle, trailing: trailing)
    }
}

/// Onboarding-style usage: left-aligned under a heading, on a stage.
private struct RecorderLeadingDemo: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Push to talk").typeface(.headline).foregroundStyle(.ink)
                ShortcutRecorderView(shortcut: .constant(.fn), action: .pushToTalk, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Hands-free").typeface(.headline).foregroundStyle(.ink)
                ShortcutRecorderView(shortcut: .constant(.fnSpace), action: .handsFree,
                                     previewState: .recording(held: .fn), alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Paste last transcript").typeface(.headline).foregroundStyle(.ink)
                ShortcutRecorderView(shortcut: .constant(.commandFnV), action: .pasteLast,
                                     previewState: .message(.conflict(.handsFree, attempted: .fnSpace)),
                                     alignment: .leading)
            }
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(StageBackground(cornerRadius: 0))
    }
}
