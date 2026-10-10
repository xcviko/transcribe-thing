import AppKit
import SwiftUI

/// One call, over the Calls tab (Back, ⌘[): what it was and where it ran, how the transcript was made, both sides
/// played together, and the transcript, a line per phrase. A phrase's time plays the call from there; a speaker's name
/// renames them all through the call.
struct CallDetailPage: View {
    @Environment(HubContext.self) private var hub
    @Environment(WindowCoordinator.self) private var windows
    @Environment(CallStore.self) private var store

    @State private var confirmingDelete: CallRecord?
    @State private var player: CallPlayer?

    private var call: CallRecord? {
        guard let id = windows.openCallID else { return nil }
        return CallsList.calls(store.calls, live: hub.callState).first { $0.id == id }
    }

    var body: some View {
        Group {
            if let call {
                page(call)
            } else {
                Color.clear
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    hub.show(.calls)
                } label: {
                    Label("Back to Calls", systemImage: "chevron.backward")
                }
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to Calls")
            }
            if let call {
                ToolbarItemGroup(placement: .primaryAction) { tools(call) }
            }
        }
        .callDeleteAlert($confirmingDelete)
        // The call went (deleted here or elsewhere, auto-deleted): back to the list.
        .onChange(of: call == nil) { _, gone in if gone, !hub.isPreview { hub.show(.calls) } }
        .onAppear { if call == nil, !hub.isPreview { hub.show(.calls) } }
        .onDisappear { player?.stop() }
    }

    private func page(_ call: CallRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                CallHeader(call: call, isAsking: CallsList.askingID(hub.callState) == call.id) { confirmingDelete = $0 }
                CallNotes(call: call)
                if call.micFile != nil || call.remoteFile != nil {
                    CallPlayerBar(player: player(for: call))
                }
                CallTranscriptView(call: call, player: player(for: call))
            }
            .padding(.horizontal, HubLayout.pageHorizontal)
            .padding(.top, HubLayout.pageTop)
            .padding(.bottom, HubLayout.pageBottom + 20)
            .frame(maxWidth: HubLayout.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: call.id) {
            guard player == nil || player?.id != call.id else { return }
            player?.stop()
            player = makePlayer(call)
        }
    }

    /// The page's player, or one standing in for it until the page has made its own (it plays nothing).
    private func player(for call: CallRecord) -> CallPlayer {
        if let player, player.id == call.id { return player }
        return makePlayer(call)
    }

    private func makePlayer(_ call: CallRecord) -> CallPlayer {
        let urls = [CallJournal.Track.mic, .remote].compactMap { store.audioURL(of: call, track: $0) }
        return CallPlayer(id: call.id, urls: hub.isPreview ? [] : urls, duration: call.duration)
    }

    @ViewBuilder private func tools(_ call: CallRecord) -> some View {
        let hasTranscript = call.transcript.map { !$0.segments.isEmpty } ?? false
        let hasAudio = call.micFile != nil || call.remoteFile != nil
        Button {
            hub.copy(CallFormat.copyText(call))
        } label: {
            Label("Copy Transcript", systemImage: "doc.on.doc")
        }
        .help("Copy Transcript")
        .disabled(!hasTranscript)
        Button {
            hub.transcribeCall(call)
        } label: {
            Label(call.transcript == nil ? "Transcribe" : "Transcribe Again", systemImage: "arrow.clockwise")
        }
        .help(call.transcript == nil ? "Transcribe" : "Transcribe Again, with \(EngineID.geminiFlash.shortName)")
        .disabled(!hasAudio || call.status == .recording || call.status == .transcribing)
        Button {
            hub.revealCall(call.id)
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
        .help("Show in Finder")
        .disabled(!hasAudio)
        Button {
            confirmingDelete = call
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .help("Delete")
    }
}

// MARK: - Header

private struct CallHeader: View {
    var call: CallRecord
    var isAsking: Bool
    var onDelete: (CallRecord) -> Void
    @Environment(HubContext.self) private var hub

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                CallAppIcon(call: call, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(CallFormat.title(call))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.ink)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    HStack(spacing: 0) {
                        Text(CallFormat.date(call.startedAt))
                        Text(" · ")
                        CallDurationText(call: call)
                        if let cost = call.costUSD, cost > 0 {
                            Text(" · \(Fmt.usd(cost))")
                                .help("What transcribing it cost on OpenRouter")
                        }
                    }
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.inkSecondary)
                    Text(CallFormat.place(call))
                        .font(.system(size: 12))
                        .foregroundStyle(.inkTertiary)
                }
                Spacer(minLength: 0)
            }
            if call.status != .done || !CallFormat.problems(call).isEmpty {
                CallStatusLine(call: call, isAsking: isAsking, onDelete: onDelete)
                    .padding(.leading, 58)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sectionFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// How the transcript was made: mutes, mute not followed, another tab's sound.
private struct CallNotes: View {
    var call: CallRecord

    var body: some View {
        let notes = CallFormat.notes(call)
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(notes, id: \.self) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.inkTertiary)
                        Text(note)
                            .font(.system(size: 12))
                            .foregroundStyle(.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, -8)
        }
    }
}

// MARK: - Player

/// Play/Pause, a scrubber over the whole call, and where it is: both sides together.
private struct CallPlayerBar: View {
    var player: CallPlayer
    /// Where the scrubber is held while it's dragged; the player moves on release.
    @State private var scrubbing: Double?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.ink)
            .background(Color.ink.opacity(0.08), in: Circle())
            .keyboardShortcut(.space, modifiers: [])
            .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .disabled(!player.canPlay && !player.isPlaying)
            Slider(value: Binding(get: { scrubbing ?? player.currentTime },
                                  set: { scrubbing = $0 }),
                   in: 0...max(player.duration, 1)) { editing in
                if !editing, let target = scrubbing {
                    player.seek(to: target, play: player.isPlaying)
                    scrubbing = nil
                }
            }
            .controlSize(.small)
            .accessibilityLabel("Position")
            .accessibilityValue(Fmt.duration(player.currentTime))
            Text("\(Fmt.duration(scrubbing ?? player.currentTime)) / \(Fmt.duration(player.duration))")
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(.inkSecondary)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.sectionFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if let problem = player.problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.danger)
                    .padding(.leading, 56)
                    .padding(.bottom, 2)
            }
        }
    }
}

// MARK: - Transcript

private struct CallTranscriptView: View {
    var call: CallRecord
    var player: CallPlayer
    @Environment(HubContext.self) private var hub

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Transcript")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if call.transcript.map({ !$0.segments.isEmpty }) == true {
                    Text("Click a name to rename them, a time to play from there.")
                        .font(.system(size: 11))
                        .foregroundStyle(.inkTertiary)
                }
            }
            .padding(.horizontal, 4)
            content
        }
    }

    @ViewBuilder private var content: some View {
        if let transcript = call.transcript, !transcript.segments.isEmpty {
            let slots = CallSpeakerPalette.slots(transcript)
            let segments = transcript.segments
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    let isFirst = index == 0
                    let isLast = index == segments.count - 1
                    let previous = index > 0 ? segments[index - 1] : nil
                    let showsName = previous?.speaker != segment.speaker || previous?.duringMute != segment.duringMute
                    CallSegmentRow(call: call, segment: segment, slot: slots[segment.speaker],
                                   showsName: showsName, isCurrent: isCurrent(segment, next: segments[safe: index + 1]),
                                   player: player)
                        .padding(.top, isFirst ? 8 : (showsName ? 6 : 0))
                        .padding(.bottom, isLast ? 10 : 0)
                        .cardSegment(isFirst: isFirst, isLast: isLast)
                }
            }
        } else {
            placeholder
        }
    }

    /// The phrase playing now.
    private func isCurrent(_ segment: CallTranscript.Segment, next: CallTranscript.Segment?) -> Bool {
        guard player.isPlaying else { return false }
        let time = player.currentTime
        return time >= segment.start && time < (next?.start ?? segment.end)
    }

    private var placeholder: some View {
        Text(placeholderText)
            .font(.system(size: 13))
            .foregroundStyle(.inkTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 28)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color.strokeStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
    }

    private var placeholderText: String {
        switch call.status {
        case .recording: "The transcript comes once the call ends."
        case .transcribing: "Gemini is writing the transcript…"
        case .unconfirmed: "Not transcribed: Transcribe sends it to \(EngineID.geminiFlash.shortName)."
        case .interrupted: "Not transcribed: the app quit during the call. Transcribe sends what was recorded."
        case .failed: "No transcript: Retry above, or Transcribe Again in the toolbar."
        case .done: "Nobody spoke in this call."
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// One phrase: its time (plays from there), its speaker when it changes (renames them), and what they said,
/// selectable. Said while muted, it's dimmed and tagged.
private struct CallSegmentRow: View {
    var call: CallRecord
    var segment: CallTranscript.Segment
    var slot: CallSpeakerSlot?
    var showsName: Bool
    var isCurrent: Bool
    var player: CallPlayer

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                player.seek(to: segment.start, play: true)
            } label: {
                Text(CallPrompts.clock(segment.start))
                    .font(.system(size: 11.5, weight: isCurrent ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? Color.ink : Color.inkTertiary)
                    .frame(width: 52, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!player.canPlay)
            .help("Play from \(CallPrompts.clock(segment.start))")
            VStack(alignment: .leading, spacing: 3) {
                if showsName {
                    HStack(spacing: 6) {
                        SpeakerName(call: call, speaker: segment.speaker, slot: slot)
                        if segment.duringMute {
                            Text("muted")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.inkSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.ink.opacity(0.08), in: Capsule(style: .continuous))
                                .help("Said while you were muted: the other side didn’t hear it.")
                        }
                    }
                }
                Text(segment.text)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(.ink)
                    .opacity(segment.duringMute ? 0.5 : 1)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }
}

/// A speaker's name in their color: a click opens a field to rename them all through the call.
private struct SpeakerName: View {
    var call: CallRecord
    var speaker: String
    var slot: CallSpeakerSlot?
    @Environment(HubContext.self) private var hub
    @State private var renaming = false

    var body: some View {
        Button {
            renaming = true
        } label: {
            Text(call.name(of: speaker))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CallSpeakerColors.color(slot))
        }
        .buttonStyle(.plain)
        .help("Rename \(call.name(of: speaker))")
        .popover(isPresented: Binding(get: { renaming || hub.previewRenaming == speaker }, set: { renaming = $0 }),
                 arrowEdge: .bottom) {
            SpeakerRenameForm(original: speaker, current: call.name(of: speaker)) { name in
                renaming = false
                guard let name else { return }
                hub.calls.rename(speaker: speaker, to: name, in: call.id)
            }
        }
    }
}

/// The popover's field: Return renames, Escape leaves it. Empty, or the model's own name, undoes a rename.
struct SpeakerRenameForm: View {
    var original: String
    var current: String
    /// The name typed, or nil for Cancel.
    var done: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename speaker")
                .font(.system(size: 13, weight: .semibold))
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($focused)
                .onSubmit { done(text) }
            Text(original == current ? "Renames them all through this call."
                 : "Renames them all through this call. Leave it empty for “\(original)”.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 220, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { done(text) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(14)
        .onAppear {
            text = current
            focused = true
        }
    }
}

/// The speakers' colors: the mic's side in blues and teal, the other side's in violet, pink, purple and green.
enum CallSpeakerColors {
    static let local: [NSColor] = [Palette.modelBlue, Palette.modelTeal]
    static let remote: [NSColor] = [Palette.modelViolet, Palette.modelPink, Palette.modelPurple, Palette.modelGreen]

    static func color(_ slot: CallSpeakerSlot?) -> Color {
        guard let slot else { return .ink }
        let colors = slot.side == .local ? local : remote
        return Color(nsColor: colors[slot.index % colors.count])
    }
}
