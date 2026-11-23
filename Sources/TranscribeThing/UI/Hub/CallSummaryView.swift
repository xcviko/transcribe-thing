import SwiftUI

/// The call's summary on its page, over the transcript: what the call was about, the key points, what was decided, the
/// tasks (ticked off here, saved at once), and what's still open, each part only when it has something. While the call
/// is transcribed it says the summary comes with the transcript; a call without one (transcribed before summaries, or
/// whose summary failed) has Summarize. The call's speakers it mentions wear their colors, renamed as in the transcript.
struct CallSummaryView: View {
    var call: CallRecord
    @Environment(HubContext.self) private var hub
    @Environment(CallStore.self) private var store

    private var hasTranscript: Bool { call.transcript.map { !$0.segments.isEmpty } == true }
    private var isSummarizing: Bool { store.summarizing.contains(call.id) }

    var body: some View {
        if call.status == .transcribing {
            section { placeholder(Text("Summary comes with the transcript.")) }
        } else if isSummarizing {
            section {
                placeholder(HStack(spacing: 10) {
                    ShimmerBar(height: 3)
                        .frame(width: 40)
                    Text("Gemini is writing the summary…")
                })
            }
        } else if let summary = call.summary, call.status == .done {
            section(copy: !summary.isEmpty) { content(summary) }
        } else if hasTranscript, call.status == .done {
            section { missing }
        }
    }

    private func section(copy: Bool = false, @ViewBuilder _ body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Summary")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if copy {
                    Button {
                        hub.copy(CallFormat.summaryText(call))
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                    .help("Copy Summary")
                }
            }
            .padding(.horizontal, 4)
            body()
        }
    }

    private func placeholder(_ line: some View) -> some View {
        line
            .font(.system(size: 13))
            .foregroundStyle(.inkTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 18)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color.strokeStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
    }

    /// No summary: why, and Summarize.
    private var missing: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if call.summaryError != nil {
                Circle().fill(Color.danger).frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                Text("\(Text("Summary failed").fontWeight(.medium).foregroundStyle(Color.ink)) · \(reason)")
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This call was transcribed before summaries. Summarize writes one from its transcript, without "
                     + "sending the audio again.")
                    .foregroundStyle(Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Summarize") { hub.summarizeCall(call) }
                .controlSize(.small)
                .fixedSize()
                .disabled(!hub.canSummarize(call))
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sectionFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private var reason: String {
        let text = (call.summaryError ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Something went wrong." }
        return text.hasSuffix(".") ? text : text + "."
    }

    @ViewBuilder private func content(_ summary: CallSummary) -> some View {
        let slots = CallSpeakerPalette.slots(call.transcript)
        VStack(alignment: .leading, spacing: 18) {
            if summary.isEmpty {
                Text("Nothing to sum up in this call.")
                    .font(.system(size: 13))
                    .foregroundStyle(.inkTertiary)
            }
            if !summary.summary.isEmpty {
                CallSummaryText.text(call, summary.summary, slots: slots)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !summary.keyPoints.isEmpty { list("Key points", summary.keyPoints, slots: slots) }
            if !summary.decided.isEmpty { list("Decided", summary.decided, slots: slots) }
            if !summary.tasks.isEmpty {
                part("Tasks") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(summary.tasks) { task in
                            CallTaskRow(call: call, task: task, slots: slots)
                        }
                    }
                }
            }
            if !summary.open.isEmpty { list("Open", summary.open, slots: slots) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sectionFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func part(_ title: String, @ViewBuilder _ body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.inkSecondary)
                .accessibilityAddTraits(.isHeader)
            body()
        }
    }

    private func list(_ title: String, _ items: [String], slots: [String: CallSpeakerSlot]) -> some View {
        part(title) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .foregroundStyle(.inkTertiary)
                        CallSummaryText.text(call, item, slots: slots)
                            .foregroundStyle(.ink)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: 13))
                }
            }
        }
    }
}

/// A task: its checkbox (saved at once), who does it in their speaker color, what, and when it's due. Done, it's struck
/// through and dimmed.
private struct CallTaskRow: View {
    var call: CallRecord
    var task: CallTask
    var slots: [String: CallSpeakerSlot]
    @Environment(HubContext.self) private var hub

    private var slot: CallSpeakerSlot? { CallFormat.ownerSpeaker(call, task).flatMap { slots[$0] } }

    var body: some View {
        Toggle(isOn: Binding(get: { task.done }, set: { hub.setTask(task, done: $0, in: call) })) {
            label
                .font(.system(size: 13))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(task.done ? 0.5 : 1)
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel(String(CallFormat.taskLine(call, task).dropFirst(4)))
    }

    private var label: Text {
        let owner = CallFormat.ownerName(call, task).map { name in
            Text("\(Text(name).fontWeight(.semibold).foregroundStyle(CallSpeakerColors.color(slot)))  ")
        } ?? Text(verbatim: "")
        let due = task.due.map { Text("  ·  \(CallFormat.plain(call, $0))").foregroundStyle(Color.inkSecondary) }
            ?? Text(verbatim: "")
        let text = CallSummaryText.text(call, task.text, slots: slots).foregroundStyle(Color.ink)
        return Text("\(owner)\(text)\(due)")
            .strikethrough(task.done, color: Color.inkSecondary)
    }
}

/// A summary's text with the call's speakers it mentions in their colors, renamed as in the transcript
/// (`CallFormat.shown`).
enum CallSummaryText {
    static func text(_ call: CallRecord, _ text: String, slots: [String: CallSpeakerSlot]) -> Text {
        CallFormat.shown(call, text).reduce(Text(verbatim: "")) { result, piece in
            let words = Text(verbatim: piece.text)
            guard let speaker = piece.speaker else { return Text("\(result)\(words)") }
            return Text("\(result)\(words.fontWeight(.medium).foregroundStyle(CallSpeakerColors.color(slots[speaker])))")
        }
    }
}
