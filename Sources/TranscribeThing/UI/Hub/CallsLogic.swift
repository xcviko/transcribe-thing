import Foundation

// What the Calls tab shows, worked out apart from its views: the list by day and its search, the badge, each call's
// words (title, speakers, where it ran, notes, problems), the transcript and the summary as text to copy, the tasks
// ticked off, and the speakers' colors.

/// One day of calls in the Calls tab, newest first.
struct CallDay: Identifiable, Equatable {
    /// Start of the day.
    let id: Date
    let title: String
    var calls: [CallRecord]
}

enum CallsList {
    /// The calls the tab lists: the store's, the live one brought up to date (a browser's tab read since it was kept),
    /// and the live call being asked about, which the store doesn't have until it's kept.
    static func calls(_ stored: [CallRecord], live state: CallMonitor.State) -> [CallRecord] {
        guard let info = liveInfo(state) else { return stored }
        if let index = stored.firstIndex(where: { $0.id == info.id }) {
            var calls = stored
            calls[index].service = info.service ?? calls[index].service
            calls[index].pageTitle = info.pageTitle ?? calls[index].pageTitle
            calls[index].muteIntervals = info.mutes
            calls[index].muteKnown = info.muteKnown
            return calls
        }
        guard case .asking = state else { return stored }
        var record = CallRecord(id: info.id, startedAt: info.startedAt, appName: info.appName, bundleID: info.bundleID,
                                service: info.service, pageTitle: info.pageTitle, manual: info.manual,
                                status: .recording)
        record.muteIntervals = info.mutes
        record.muteKnown = info.muteKnown
        return ([record] + stored).sorted { $0.startedAt > $1.startedAt }
    }

    /// The call being recorded and asked about, or kept; a suspicion isn't shown anywhere yet.
    static func liveInfo(_ state: CallMonitor.State) -> CallMonitor.CallInfo? {
        switch state {
        case .asking(let info), .recording(let info): info
        case .idle, .suspected, .ending: nil
        }
    }

    /// The live call waiting for "Transcribe your call?".
    static func askingID(_ state: CallMonitor.State) -> UUID? {
        if case .asking(let info) = state { return info.id }
        return nil
    }

    /// Newest day first, newest call first within a day.
    static func days(_ calls: [CallRecord], now: Date = Date(), calendar: Calendar = .current) -> [CallDay] {
        var days: [CallDay] = []
        for call in calls.sorted(by: { $0.startedAt > $1.startedAt }) {
            let start = calendar.startOfDay(for: call.startedAt)
            if days.last?.id != start {
                days.append(CallDay(id: start, title: Fmt.relativeDay(call.startedAt, now: now, calendar: calendar),
                                    calls: []))
            }
            days[days.count - 1].calls.append(call)
        }
        return days
    }

    /// Case- and diacritic-insensitive match on the title, the app, the speakers (as the model named them and as
    /// renamed) and what was said.
    static func filter(_ calls: [CallRecord], query: String) -> [CallRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return calls }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func matches(_ text: String?) -> Bool { text?.range(of: needle, options: options) != nil }
        return calls.filter { call in
            if matches(CallFormat.title(call)) || matches(call.appName) { return true }
            let speakers = call.transcript?.speakers ?? []
            if speakers.contains(where: { matches($0) || matches(call.name(of: $0)) }) { return true }
            return call.transcript?.segments.contains { matches($0.text) } ?? false
        }
    }

    /// Whether a call waits for the person: an answer to "Transcribe your call?", a Transcribe after the app quit
    /// during it, or a Retry.
    static func needsAttention(_ call: CallRecord) -> Bool {
        switch call.status {
        case .unconfirmed, .failed, .interrupted: true
        case .recording, .transcribing, .done: false
        }
    }

    /// The count on the Calls tab: the calls waiting for the person, and the live call being asked about.
    static func badgeCount(_ stored: [CallRecord], live state: CallMonitor.State) -> Int {
        let waiting = stored.filter(needsAttention).count
        guard let asking = askingID(state), !stored.contains(where: { $0.id == asking }) else { return waiting }
        return waiting + 1
    }
}

// MARK: - Words

/// Something that kept a side of the call from being recorded, and where it's fixed.
struct CallProblem: Equatable, Hashable {
    var text: String
    var pane: SettingsPane?
}

enum CallFormat {
    /// "Google Meet · Meet – abc-defg-hij", "Telegram", "Menu bar recording".
    static func title(_ call: CallRecord) -> String {
        if call.manual { return "Menu bar recording" }
        let name = call.title
        guard let page = call.pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !page.isEmpty,
              page.caseInsensitiveCompare(name) != .orderedSame else { return name }
        return "\(name) · \(page)"
    }

    /// The service's name alone, as the question about it says: "Google Meet", "Telegram".
    static func shortTitle(_ call: CallRecord) -> String {
        call.manual ? "Menu bar recording" : call.title
    }

    /// "Matvey, Аня, Participant 2": everyone who spoke, by the names the person gave them, in the order they first
    /// spoke. nil before there's a transcript with anyone in it.
    static func speakers(_ call: CallRecord) -> String? {
        let names = (call.transcript?.speakers ?? []).map(call.name(of:))
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// Where the call ran: "In Google Chrome", "In the Telegram app", "Your mic and all sound, from the menu bar".
    static func place(_ call: CallRecord) -> String {
        if call.manual { return "Your mic and all sound, from the menu bar" }
        if let bundleID = call.bundleID, CallAppKind.of(bundleID) == .browser { return "In \(call.appName)" }
        return "In the \(call.appName) app"
    }

    /// "Thursday, October 9 at 2:10 PM": the detail page's date.
    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute())
    }

    /// The call's length so far: a live one's from its start, an ended one's from its tracks.
    static func duration(_ call: CallRecord, now: Date) -> TimeInterval {
        call.status == .recording ? max(0, now.timeIntervalSince(call.startedAt)) : call.duration
    }

    /// What's worth knowing about how the transcript was made: mutes, mute not followed, another tab's sound.
    static func notes(_ call: CallRecord) -> [String] {
        var notes: [String] = []
        let mutes = call.muteIntervals
        if !mutes.isEmpty {
            let total = Fmt.duration(mutes.reduce(0) { $0 + $1.duration })
            let muted = mutes.count == 1 ? "You were muted once (\(total))"
                                         : "You were muted \(mutes.count) times (\(total) in all)"
            // A call recorded before the mic was silenced while muted still has what was said then.
            notes.append(call.micSilencedWhenMuted ? "\(muted); your mic wasn’t recorded then." : "\(muted).")
        }
        if call.manual {
            notes.append("Mute isn’t followed in a menu bar recording: what you said while muted is in the transcript.")
        } else if !call.muteKnown {
            notes.append("Mute isn’t known for this app: what you said while muted may be in the transcript.")
        }
        if !call.otherBrowserAudio.isEmpty {
            notes.append("Another tab played sound during the call, so it may be mixed into their side.")
        }
        if let cut = call.cutOffAt {
            notes.append("The transcript may be cut off at \(CallPrompts.clock(cut)): Gemini’s answer ran out of room there.")
        }
        return notes
    }

    /// Why a side wasn't recorded (or stopped), with the Privacy & Security pane that fixes it when there is one.
    static func problems(_ call: CallRecord) -> [CallProblem] {
        var problems: [CallProblem] = []
        // A silent other side said nothing about the permission when it's granted: nobody spoke there (calls saved
        // before the app asked macOS, too).
        if let problem = call.remoteProblem,
           problem != CallStore.silentTapMessage || SystemAudioPermission.current() != .authorized {
            if problem == CallStore.silentTapMessage {
                problems.append(CallProblem(text: "Their side wasn’t recorded: allow System Audio Recording in "
                                                + "Privacy & Security.", pane: .systemAudio))
            } else {
                let lead = call.remoteFile == nil ? "Their side wasn’t recorded" : "Their side stopped recording"
                problems.append(CallProblem(text: "\(lead). \(sentence(problem))", pane: .systemAudio))
            }
        }
        if let problem = call.micProblem {
            let lead = call.micFile == nil ? "Your side wasn’t recorded" : "Your mic stopped for a while"
            let pane: SettingsPane? = problem.localizedCaseInsensitiveContains("permission") ? .microphone : nil
            problems.append(CallProblem(text: "\(lead). \(sentence(problem))", pane: pane))
        }
        return problems
    }

    /// Why transcription failed, as a sentence.
    static func failure(_ call: CallRecord) -> String {
        sentence(call.error.flatMap { $0.isEmpty ? nil : $0 } ?? "Something went wrong.")
    }

    /// The transcript as plain text, a line per phrase: "[02:14] Matvey: Text". What was said muted says so.
    static func copyText(_ call: CallRecord) -> String {
        guard let transcript = call.transcript else { return "" }
        return transcript.segments.map { segment in
            let name = call.name(of: segment.speaker) + (segment.duringMute ? " (muted)" : "")
            return "[\(CallPrompts.clock(segment.start))] \(name): \(segment.text)"
        }.joined(separator: "\n")
    }

    // MARK: Summary

    /// The speaker a task's owner is, as the transcript names them (the model's name, matched case aside); nil for
    /// an owner who isn't one of the call's speakers, or no owner.
    static func ownerSpeaker(_ call: CallRecord, _ task: CallTask) -> String? {
        guard let owner = task.owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty else { return nil }
        let speakers = call.transcript?.speakers ?? []
        if speakers.contains(owner) { return owner }
        return speakers.first { $0.caseInsensitiveCompare(owner) == .orderedSame }
    }

    /// A task's owner as the page shows them: renamed when they're one of the call's speakers, else as written.
    static func ownerName(_ call: CallRecord, _ task: CallTask) -> String? {
        if let speaker = ownerSpeaker(call, task) { return call.name(of: speaker) }
        guard let owner = task.owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty else { return nil }
        return owner
    }

    /// "[x] Matvey: Send the notes (Friday)", "[ ] Book the room".
    static func taskLine(_ call: CallRecord, _ task: CallTask) -> String {
        let owner = ownerName(call, task).map { "\($0): " } ?? ""
        let due = task.due.map { " (\($0))" } ?? ""
        return "[\(task.done ? "x" : " ")] \(owner)\(task.text)\(due)"
    }

    /// The summary as plain text to copy: each part that has something, under its heading. Empty without a summary.
    static func summaryText(_ call: CallRecord) -> String {
        guard let summary = call.summary else { return "" }
        var sections: [String] = []
        if !summary.summary.isEmpty { sections.append("Summary\n\(summary.summary)") }
        func list(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            sections.append(([title] + items.map { "- \($0)" }).joined(separator: "\n"))
        }
        list("Key points", summary.keyPoints)
        list("Decided", summary.decided)
        if !summary.tasks.isEmpty {
            sections.append((["Tasks"] + summary.tasks.map { taskLine(call, $0) }).joined(separator: "\n"))
        }
        list("Open", summary.open)
        return sections.joined(separator: "\n\n")
    }

    /// "2/3 tasks": the summary's tasks ticked off, of all; nil without any.
    static func taskCount(_ call: CallRecord) -> String? {
        guard let tasks = call.summary?.tasks, !tasks.isEmpty else { return nil }
        let done = tasks.filter(\.done).count
        return "\(done)/\(tasks.count) \(tasks.count == 1 ? "task" : "tasks")"
    }

    /// `text` ending in a period.
    private static func sentence(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasSuffix(".") ? text : text + "."
    }
}

// MARK: - Speakers

/// Which color a speaker wears in a call's transcript: the mic's side in one family, the other side's in another,
/// each speaker the next color of their side's in the order they first speak. Keyed by the name the model gave, so a
/// rename keeps the color.
struct CallSpeakerSlot: Equatable, Hashable {
    var side: CallSide
    /// Into the side's colors, wrapping round.
    var index: Int
}

enum CallSpeakerPalette {
    static func slots(_ transcript: CallTranscript?) -> [String: CallSpeakerSlot] {
        var slots: [String: CallSpeakerSlot] = [:]
        var counts: [CallSide: Int] = [:]
        for segment in transcript?.segments ?? [] where slots[segment.speaker] == nil {
            let index = counts[segment.side, default: 0]
            slots[segment.speaker] = CallSpeakerSlot(side: segment.side, index: index)
            counts[segment.side] = index + 1
        }
        return slots
    }
}

// MARK: - Settings

extension CallRecordingMode {
    /// General → Calls → Record calls.
    var title: String {
        switch self {
        case .off: "Off"
        case .ask: "Ask First"
        case .automatic: "Automatically"
        }
    }

    static let pickerOrder: [CallRecordingMode] = [.off, .ask, .automatic]
}

enum CallsCopy {
    /// How long the mic and sound have to stay on together: "20 seconds".
    static var confirmAfter: String { "\(Int(CallDetector.Settings().confirmAfter)) seconds" }
    /// Where mute is followed, in their apps and in the browser.
    static let muteFollowed = "Zoom, Discord, Slack, Google Meet, Telemost and Telegram"

    /// What counts as a call, for General → Calls and the empty Calls tab.
    static var whatIsACall: String {
        "A call is any app or browser tab that uses your microphone and plays sound for \(confirmAfter)."
    }

    /// General → Calls' footer.
    static var settingsFooter: String {
        "\(whatIsACall) Mute is followed in \(muteFollowed). Music and recording apps like GarageBand, Logic Pro "
            + "and OBS never count. In a browser, the call’s tab is found through Accessibility (already on for "
            + "pasting), and all of the browser’s sound is recorded. Models → Calls picks the model that transcribes them."
    }

    /// General → Calls → Never recorded, under its title.
    static func exclusionsSubtitle(empty: Bool) -> String {
        empty ? "Nothing yet. Choose Never for… when you’re asked about a call, and that app or site is left alone."
              : "Calls in these apps and sites aren’t noticed. Remove one to notice its calls again."
    }

    /// The menu bar's line while a call is recorded: "Recording call · Google Meet · 12:34".
    static func menuStatus(_ info: CallMonitor.CallInfo, now: Date) -> String {
        let title = info.manual ? "All sound" : info.title
        return "Recording call · \(title) · \(Fmt.duration(now.timeIntervalSince(info.startedAt)))"
    }
}
