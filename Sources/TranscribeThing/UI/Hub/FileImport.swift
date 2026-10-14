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
    @ObservationIgnored var choices: (_ seconds: TimeInterval) -> [VersionsMenu.Action] = { _ in [] }
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
            if offered.contains(where: \.isEnabled) {
                pending += files
            } else {
                let reason = offered.first?.blocker?.label ?? "No model is ready"
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

// MARK: - Shared by Home and Calls

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
