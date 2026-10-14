import AppKit
import SwiftUI

/// One call, over the Calls tab (Back, ⌘[): what it was and where it ran, how the transcript was made, both sides
/// played together, its summary (`CallSummaryView`), and the transcript, a line per phrase. A phrase's time plays the call from there; a speaker's name
/// renames them all through the call.
struct CallDetailPage: View {
    @Environment(HubContext.self) private var hub
    @Environment(WindowCoordinator.self) private var windows
    @Environment(CallStore.self) private var store

    @State private var confirmingDelete: CallRecord?
    @State private var player: CallPlayer?
    @State private var scroll = ScrollPosition()
    /// The summary and transcript are scrolled: a hairline under the call's card.
    @State private var scrolled = false

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

    /// The call's card stays at the top, under the toolbar; the summary and the transcript scroll below it, a hairline
    /// between them once they've moved.
    private func page(_ call: CallRecord) -> some View {
        VStack(spacing: 0) {
            CallTopCard(call: call, player: player(for: call),
                        tracks: [CallJournal.Track.mic, .remote].compactMap { store.audioURL(of: call, track: $0) },
                        folder: store.folder(for: call.id),
                        isAsking: CallsList.askingID(hub.callState) == call.id) { confirmingDelete = $0 }
                .padding(.horizontal, HubLayout.pageHorizontal)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .frame(maxWidth: HubLayout.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            Divider()
                .opacity(scrolled ? 1 : 0)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    CallSummaryView(call: call)
                    CallTranscriptView(call: call, player: player(for: call))
                }
                .padding(.horizontal, HubLayout.pageHorizontal)
                .padding(.top, 13)
                .padding(.bottom, HubLayout.pageBottom + 20)
                .frame(maxWidth: HubLayout.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition($scroll)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 0.5
            } action: { _, moved in
                scrolled = moved
            }
            .onAppear { if let y = hub.previewCallScroll { scroll.scrollTo(y: y) } }
        }
        // The card's wrapping lines (a failure, a permission) asked at no width are tall: without a floor of 0 that
        // height became the window's least, and the page was pushed up out of it.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .task(id: call.id) {
            guard player == nil || player?.id != call.id else { return }
            player?.stop()
            player = makePlayer(call, nowPlaying: hub.isPreview ? nil : .shared)
        }
    }

    /// The page's player, or one standing in for it until the page has made its own (it never takes the media keys:
    /// nothing would let them go).
    private func player(for call: CallRecord) -> CallPlayer {
        if let player, player.id == call.id { return player }
        return makePlayer(call)
    }

    /// `nowPlaying`: the media controls the page's own player takes once it plays (the play/pause key, Control
    /// Center), until the page closes.
    private func makePlayer(_ call: CallRecord, nowPlaying: CallNowPlaying? = nil) -> CallPlayer {
        let urls = [CallJournal.Track.mic, .remote].compactMap { store.audioURL(of: call, track: $0) }
        return CallPlayer(id: call.id, urls: hub.isPreview ? [] : urls, duration: call.duration,
                          item: .of(call), nowPlaying: nowPlaying, position: hub.previewCallPosition ?? 0)
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
        .help(call.transcript == nil ? "Transcribe" : "Transcribe Again, with \(hub.settings.callEngine.shortName)")
        .disabled(!hasAudio || call.status == .recording || call.status == .transcribing)
        Button {
            hub.summarizeCall(call)
        } label: {
            Label(call.summary == nil ? "Summarize" : "Summarize Again", systemImage: "list.bullet.clipboard")
        }
        .help(call.summary == nil ? "Summarize: from the transcript, without sending the audio again"
              : "Summarize Again, from the transcript")
        .disabled(!hub.canSummarize(call))
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

// MARK: - Top card

/// The call in one card that stays at the top of its page: its app, title, when, how long, what it cost and where it
/// ran; what it's waiting for or what went wrong; notes on how the transcript was made; then the player (Play/Pause,
/// the waveform in the speakers' colors, where it is) and who's who.
private struct CallTopCard: View {
    var call: CallRecord
    var player: CallPlayer
    /// The call's tracks and folder, where its loudness is read from and kept (`CallPeaks`).
    var tracks: [URL]
    var folder: URL
    var isAsking: Bool
    var onDelete: (CallRecord) -> Void
    @Environment(HubContext.self) private var hub
    /// Where the waveform is held while it's dragged; the player moves on release.
    @State private var scrubbing: Double?
    @State private var peaks: CallPeaks?
    /// Which call's tracks `peaks` are.
    @State private var peaksKey: PeaksKey?

    /// The app's icon and the Play button: the same width, so the title and the waveform start together.
    private static let lead: CGFloat = 28
    private static let gap: CGFloat = 10
    private static var indent: CGFloat { lead + gap }

    /// What the loudness depends on: a track rewritten (joined onto, cleaned again) has another length.
    private struct PeaksKey: Equatable {
        var id: UUID
        var micFile, remoteFile: String?
        var micSeconds, remoteSeconds: TimeInterval
    }

    private var key: PeaksKey {
        PeaksKey(id: call.id, micFile: call.micFile, remoteFile: call.remoteFile, micSeconds: call.micSeconds,
                 remoteSeconds: call.remoteSeconds)
    }

    private var hasAudio: Bool { call.micFile != nil || call.remoteFile != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: Self.gap) {
                CallAppIcon(call: call, size: Self.lead)
                VStack(alignment: .leading, spacing: 2) {
                    let title = CallFormat.title(call)
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                        .help(title)
                    meta
                    if call.status != .done || !CallFormat.problems(call).isEmpty {
                        CallStatusLine(call: call, isAsking: isAsking, onDelete: onDelete)
                            .padding(.top, 6)
                    }
                    CallNotes(call: call)
                        .padding(.top, 5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if hasAudio { playerRows }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sectionFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .task(id: key) {
            guard !hub.isPreview, hasAudio else { return }
            // Another call: flat bars until its own loudness is read.
            if peaksKey?.id != key.id { peaks = nil }
            let key = key, tracks = tracks, folder = folder
            let loaded = await Task.detached(priority: .utility) { CallPeaks.load(tracks: tracks, folder: folder) }.value
            guard !Task.isCancelled else { return }
            peaks = loaded
            peaksKey = key
        }
    }

    /// "Wednesday, October 14 at 8:05 AM · 32:14 · $0.04 · In Google Chrome", on one line when it fits; where it ran
    /// goes under when it doesn't. A call with a title of its own says there what its title said before:
    /// "Google Meet in Google Chrome", the tab's whole title in the tooltip.
    private var meta: some View {
        let origin = CallFormat.origin(call)
        let place = origin ?? CallFormat.place(call)
        let tooltip = origin == nil ? place : CallFormat.source(call)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                when
                Text(" · ")
                Text(place).help(tooltip)
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 2) {
                when
                Text(place)
                    .truncationMode(.middle)
                    .help(tooltip)
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .foregroundStyle(.inkSecondary)
        .lineLimit(1)
    }

    private var when: some View {
        HStack(spacing: 0) {
            Text(CallFormat.date(call.startedAt))
            Text(" · ")
            CallDurationText(call: call)
            if let cost = call.costUSD, cost > 0 {
                Text(" · \(Fmt.usd(cost))")
                    .help("What transcribing it cost on OpenRouter")
            }
        }
    }

    /// Play/Pause, the waveform and where it is, both sides together; under it, who's who.
    private var playerRows: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: Self.gap) {
                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: Self.lead, height: Self.lead)
                        .contentShape(Circle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.ink)
                .background(Color.ink.opacity(0.08), in: Circle())
                .keyboardShortcut(.space, modifiers: [])
                .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                .disabled(!player.canPlay && !player.isPlaying)
                CallWaveformView(call: call, player: player, peaks: shownPeaks, scrubbing: $scrubbing)
                Text("\(Fmt.duration(scrubbing ?? player.currentTime)) / \(Fmt.duration(player.duration))")
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(.inkSecondary)
                    .fixedSize()
            }
            if let problem = player.problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.danger)
                    .padding(.leading, Self.indent)
            }
            CallWaveformLegend(call: call)
                .padding(.leading, Self.indent)
        }
    }

    /// The loudness drawn: the call's, or a snapshot's made-up one.
    private var shownPeaks: CallPeaks? {
        guard hub.isPreview else { return peaksKey?.id == call.id ? peaks : nil }
        return hub.previewWaveformFlat ? nil : PreviewFixtures.peaks(for: call)
    }
}

/// How the transcript was made: mutes, mute not followed, another tab's sound, cut off. A few words each, side by
/// side (wrapping when they don't fit); the whole sentence is in its tooltip and what VoiceOver reads.
private struct CallNotes: View {
    var call: CallRecord

    var body: some View {
        let notes = CallFormat.shortNotes(call)
        if !notes.isEmpty {
            FlowLayout(spacing: 14, lineSpacing: 3) {
                ForEach(notes, id: \.self) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.inkTertiary)
                        Text(note.label)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.inkSecondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .help(note.text)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(note.text)
                }
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
                    if hub.calls.namingSpeakers.contains(call.id) {
                        // The names step (`CallTranscriber.nameFromVideo`): speakers may get their names in a moment.
                        HStack(spacing: 8) {
                            ShimmerBar(height: 3)
                                .frame(width: 28)
                            Text("Finding who’s who in the video…")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.inkTertiary)
                    } else {
                        Text("Click a phrase to play from there, a name to rename them.")
                            .font(.system(size: 11))
                            .foregroundStyle(.inkTertiary)
                    }
                    Button {
                        hub.copy(CallFormat.copyText(call))
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                    .help("Copy Transcript")
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
        case .transcribing: "\(hub.settings.callEngine.shortName) is writing the transcript…"
        case .unconfirmed: "Not transcribed: Transcribe sends it to \(hub.settings.callEngine.shortName)."
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

    @Environment(HubContext.self) private var hub
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(CallPrompts.clock(segment.start))
                .font(.system(size: 11.5, weight: isCurrent ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isCurrent ? Color.ink : Color.inkTertiary)
                .frame(width: 52, alignment: .leading)
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
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // The whole phrase plays from its start: the one playing is lit, the one under the pointer shaded.
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? Color.accentColor.opacity(0.14) : (hovering && player.canPlay ? Color.hover : .clear))
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { if player.canPlay { player.seek(to: segment.start, play: true) } }
        .onHover { hovering = $0 }
        .help(player.canPlay ? "Play from \(CallPrompts.clock(segment.start))" : "")
        .contextMenu {
            Button("Play from \(CallPrompts.clock(segment.start))") { player.seek(to: segment.start, play: true) }
                .disabled(!player.canPlay)
            Button("Copy Phrase") { hub.copy("\(call.name(of: segment.speaker)): \(segment.text)") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if player.canPlay { player.seek(to: segment.start, play: true) } }
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
