import AppKit
import Observation
import SwiftUI

/// Audio and video dropped on Home (or picked with Transcribe a File…), from reading them to the dialog that asks
/// which model transcribes them. It lives as long as the Hub, not Home's page: files still being read when the user
/// moves to another page are asked about, or said to be unreadable, when they come back. Files added while others are
/// read, or while the dialog is up, join the same batch.
@MainActor @Observable
final class FileImport {
    /// Why files weren't transcribed, said in an alert.
    struct Problem: Equatable {
        var title: String
        var message: String
    }

    /// What Home shows over its page: one at a time, a problem before the model dialog.
    enum Prompt: Equatable {
        case problem
        case models
    }

    /// The files being read, by name, the one being read first.
    private(set) var reading: [String] = []
    /// Files read, waiting for the model to transcribe them with.
    private(set) var pending: [ImportedAudio] = []
    /// Said one after another, before the model dialog.
    private(set) var problems: [Problem] = []
    /// What Home shows now; nil between two, or with nothing to say.
    private(set) var prompt: Prompt?

    var problem: Problem? { problems.first }
    /// The longest file waiting: Gemini takes at most `CloudAudio.maxChatSeconds` of audio.
    var longest: TimeInterval { pending.map(\.duration).max() ?? 0 }

    /// What can transcribe files the longest of which is `seconds` long, as the dialog offers it (`ImportChoices`).
    @ObservationIgnored var choices: (_ seconds: TimeInterval) -> ImportChoices = { _ in .none }
    /// Transcribes a file into History (`DictationController.transcribe(_:as:)`).
    @ObservationIgnored var start: (ImportedAudio, TranscriptVersionKind) -> Void = { _, _ in }
    @ObservationIgnored var read: (URL) async throws(ImportedAudio.ReadError) -> ImportedAudio = {
        url async throws(ImportedAudio.ReadError) in try await ImportedAudio.read(url)
    }
    /// How long a new alert or dialog waits for the one before it to go: a sheet asked for while another is closing
    /// doesn't show.
    @ObservationIgnored var settle: Duration = .milliseconds(300)

    @ObservationIgnored private var queue: [URL] = []
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var presenting: Task<Void, Never>?

    /// Reads `urls` one after another, after any already being read (the bar at the bottom of Home names the one
    /// being read), then asks which model transcribes them, or says which couldn't be read.
    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        queue += urls
        withAnimation(Theme.Motion.fade) { reading += urls.map(\.lastPathComponent) }
        guard reader == nil else { return }
        reader = Task { await readQueue() }
    }

    /// The dialog's model was picked for `files`: each becomes a row of its own.
    func transcribe(_ files: [ImportedAudio], as kind: TranscriptVersionKind) {
        let ids = Set(files.map(\.id))
        pending.removeAll { ids.contains($0.id) }
        if prompt == .models { present(settling: true) }
        for file in files { start(file, kind) }
    }

    /// The model dialog went away (Cancel, Escape): its files aren't transcribed.
    func dialogDismissed() {
        guard prompt == .models else { return }
        pending = []
        present(settling: true)
    }

    /// The alert went away: the next problem, or the model dialog, follows.
    func problemDismissed() {
        guard prompt == .problem, !problems.isEmpty else { return }
        problems.removeFirst()
        present(settling: true)
    }

    private func readQueue() async {
        var files: [ImportedAudio] = []
        var failures: [(name: String, error: ImportedAudio.ReadError)] = []
        while let url = queue.first {
            do throws(ImportedAudio.ReadError) {
                files.append(try await read(url))
            } catch {
                failures.append((url.lastPathComponent, error))
            }
            queue.removeFirst()
            withAnimation(Theme.Motion.fade) { if !reading.isEmpty { reading.removeFirst() } }
        }
        reader = nil
        if let failure = failures.first {
            let more = failures.count > 1 ? " (and \(failures.count - 1) more)" : ""
            problems.append(Problem(title: "Can’t transcribe “\(failure.name)”\(more)", message: failure.error.message))
        }
        if !files.isEmpty {
            let offered = choices(max(longest, files.map(\.duration).max() ?? 0))
            if offered.canRun {
                pending += files
            } else {
                let reason = offered.mainBlocker?.label ?? "No model is ready"
                problems.append(Problem(title: "No model can transcribe it right now",
                                        message: "\(reason). Set one up in Models."))
            }
        }
        // An alert up stays until it's dismissed; a dialog up shows again with the new files.
        if prompt != .problem { present(settling: prompt != nil) }
    }

    /// Shows the first problem, else the model dialog, once the one up now (if any) has had time to go.
    private func present(settling: Bool) {
        presenting?.cancel()
        prompt = nil
        let next: Prompt? = !problems.isEmpty ? .problem : !pending.isEmpty ? .models : nil
        guard let next else { return }
        guard settling, settle > .zero else {
            prompt = next
            return
        }
        presenting = Task {
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            prompt = !problems.isEmpty ? .problem : !pending.isEmpty ? .models : nil
        }
    }
}

// MARK: - Choosing files

extension FileImport {
    /// Transcribe a File…'s panel: audio or video, one or more; `done` gets what was chosen, nothing on Cancel.
    static func choose(message: String, then done: @escaping @MainActor ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImportedAudio.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = message
        panel.prompt = "Transcribe"
        panel.begin { response in
            guard response == .OK else { return }
            done(panel.urls)
        }
    }
}

// MARK: - The dialog

/// What the files dropped on Home are made into, and by which model (`ImportChoices`), on a sheet over the Hub: the
/// title and how long they are, a picker of Transcribe, Polish and Translate, then a row per model as Your models
/// lists them, the main model's first. A click on a row starts it on every file; Return starts the first that can run
/// (its ↩ says so), Esc or Cancel closes the dialog with nothing started. A row that can't run keeps its place, dimmed,
/// and says why.
struct ImportDialog: View {
    var title: String
    var message: String
    var choices: ImportChoices
    var start: (TranscriptVersionKind) -> Void
    var cancel: () -> Void

    @State private var mode: ImportChoices.Mode

    static let width: CGFloat = 440

    /// `mode`: the one picked as it opens (snapshots); Transcribe otherwise.
    init(title: String, message: String, choices: ImportChoices, mode: ImportChoices.Mode = .transcribe,
         start: @escaping (TranscriptVersionKind) -> Void, cancel: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.choices = choices
        self.start = start
        self.cancel = cancel
        _mode = State(initialValue: mode)
    }

    var body: some View {
        let defaultRow = choices.defaultRow(mode)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .typeface(.headline)
                    .foregroundStyle(.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Make", selection: $mode) {
                ForEach(ImportChoices.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Spacing.md)
            // The same models in every mode, in the same places: only what they say changes with the picker.
            SettingsGroup {
                ForEach(choices.rows(mode)) { row in
                    ImportChoiceRow(row: row, isDefault: row.id == defaultRow?.id, start: start)
                }
            }
            .padding(.top, Theme.Spacing.sm)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(.appSecondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, Theme.Spacing.md)
        }
        .padding(Theme.Spacing.lg)
        .frame(width: Self.width)
        .environment(\.inNativeForm, false)
    }
}

/// A model's row in the dialog: its tile and name as Your models draws them, then the Reasoning level a Gemini model
/// thinks at, or why the row can't run. The default one (Return's) wears the soft fill of a row picked in Your models.
private struct ImportChoiceRow: View {
    var row: ImportChoices.Row
    var isDefault: Bool
    var start: (TranscriptVersionKind) -> Void

    @Environment(AppSettings.self) private var settings
    @State private var hovering = false

    var body: some View {
        Button {
            if let kind = row.kind { start(kind) }
        } label: {
            HStack(spacing: 12) {
                ModelChoiceIcon(choice: row.model, color: settings.modelColors[row.model], size: 30)
                    .opacity(row.isEnabled ? 1 : 0.4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.model.modelName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(row.isEnabled ? Color.ink : Color.ink.opacity(0.4))
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .typeface(.callout)
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isDefault {
                    Image(systemName: "return")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.inkTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Theme.Spacing.md - 2)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ImportRowButtonStyle(isDefault: isDefault, isHovering: hovering && row.isEnabled))
        .disabled(!row.isEnabled)
        .keyboardShortcut(isDefault ? .defaultAction : nil)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .accessibilityLabel(row.model.modelName)
        .accessibilityValue(detail ?? "")
    }

    /// Why it can't run; else "Reasoning: Medium" for a Gemini model, nothing for GigaAM.
    private var detail: String? {
        if let reason = row.reason { return reason }
        guard !row.model.engine.reasoningEfforts.isEmpty else { return nil }
        return "Reasoning: \((settings.reasoningEffort(for: row.model.engine) ?? .medium).title)"
    }
}

/// A dialog row lit as Your models' rows are (`RowHighlight`): the default's soft fill, hover's and a press's in its
/// place.
private struct ImportRowButtonStyle: ButtonStyle {
    var isDefault: Bool
    var isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(configuration.isPressed ? Color.pressed
                          : isHovering ? Color.hover : isDefault ? Color.accentSoft.opacity(0.7) : Color.clear)
                    .padding(4)
            }
    }
}

/// Over the page while files are dragged onto it: what dropping them does.
struct FileDropTarget: View {
    var title: String
    var subtitle: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.ink.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.ink)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.ink)
                Text(subtitle)
                    .typeface(.callout)
                    .foregroundStyle(.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(.horizontal, 24)
        }
        .padding(14)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// "Reading Interview.mp4…", at the bottom of the page while dropped files are read.
struct FileReadingBar: View {
    var name: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text("Reading \(name)…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .frame(maxWidth: 420)
        .fixedSize()
        .background(Capsule(style: .continuous).fill(Color.pillFill))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .padding(.bottom, 18)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
