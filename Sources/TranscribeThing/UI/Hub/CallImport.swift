import Observation
import SwiftUI

/// Audio and video dropped on Calls (or picked with its Transcribe a File…): each file read, then made a call of its
/// own and transcribed at once (`CallTranscriber.importFile`). No model to pick, unlike Home: a call is always
/// transcribed by the Calls model. It lives as long as the Hub, as Home's `FileImport` does: files still being read
/// when the user moves to another page become calls all the same, and what couldn't be read is said when they come
/// back to Calls. Files added while others are read join the same batch.
@MainActor @Observable
final class CallImport {
    /// The files being read, by name, the one being read first.
    private(set) var reading: [String] = []
    /// Why files didn't become calls, said one alert at a time.
    private(set) var problems: [FileImport.Problem] = []
    /// The first problem's alert is up. Off for a moment between two alerts: one asked for while another is closing
    /// doesn't show.
    private(set) var showsProblem = false

    var problem: FileImport.Problem? { problems.first }

    @ObservationIgnored var read: (URL) async throws(ImportedAudio.ReadError) -> ImportedAudio = {
        url async throws(ImportedAudio.ReadError) in try await ImportedAudio.read(url)
    }
    /// Makes a file read into a call and starts transcribing it; its id, or nil when its sound couldn't be kept.
    @ObservationIgnored var start: (ImportedAudio) async -> UUID? = { _ in nil }
    /// The calls one batch made, once it's read: the page opens a single one.
    @ObservationIgnored var onImported: ([UUID]) -> Void = { _ in }
    /// How long a new alert waits for the one before it to go.
    @ObservationIgnored var settle: Duration = .milliseconds(300)

    @ObservationIgnored private var queue: [URL] = []
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var presenting: Task<Void, Never>?

    /// Why a file couldn't be kept as a call though it was read, after its name ("Can't transcribe “x”").
    nonisolated static let unsavedMessage = "Its sound couldn’t be saved with your calls. Check that the disk has room."

    /// Reads `urls` one after another, after any already being read (the bar at the bottom of Calls names the one
    /// being read); each becomes a call as soon as it's read.
    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        queue += urls
        withAnimation(Theme.Motion.fade) { reading += urls.map(\.lastPathComponent) }
        guard reader == nil else { return }
        reader = Task { await readQueue() }
    }

    /// Returns once every file added is read and made a call: tests.
    func waitUntilRead() async {
        await reader?.value
    }

    /// The alert went away: the next problem follows.
    func problemDismissed() {
        guard showsProblem, !problems.isEmpty else { return }
        problems.removeFirst()
        present(settling: true)
    }

    private func readQueue() async {
        var made: [UUID] = []
        var failures: [(name: String, message: String)] = []
        while let url = queue.first {
            do throws(ImportedAudio.ReadError) {
                let file = try await read(url)
                if let id = await start(file) {
                    made.append(id)
                } else {
                    failures.append((url.lastPathComponent, Self.unsavedMessage))
                }
            } catch {
                failures.append((url.lastPathComponent, error.message))
            }
            queue.removeFirst()
            withAnimation(Theme.Motion.fade) { if !reading.isEmpty { reading.removeFirst() } }
        }
        reader = nil
        if let failure = failures.first {
            let more = failures.count > 1 ? " (and \(failures.count - 1) more)" : ""
            problems.append(FileImport.Problem(title: "Can’t transcribe “\(failure.name)”\(more)",
                                               message: failure.message))
        }
        if !made.isEmpty { onImported(made) }
        // An alert up stays until it's dismissed.
        if !showsProblem { present(settling: false) }
    }

    /// Shows the first problem, once the alert up before it (if any) has had time to go.
    private func present(settling: Bool) {
        presenting?.cancel()
        showsProblem = false
        guard !problems.isEmpty else { return }
        guard settling, settle > .zero else {
            showsProblem = true
            return
        }
        presenting = Task {
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            showsProblem = !problems.isEmpty
        }
    }
}
