import Foundation
import Testing
@testable import TranscribeThing

// The Calls tab: the list by day and its search, the live call in it, the badge, the speakers' colors, the transcript
// as copied, renaming a speaker, what the menu bar says while a call records, and the question asked about a call.

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return calendar
}()

/// Friday 9 October 2026, 15:00 in Berlin.
private let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 15))!

private func record(_ minutesAgo: Double, _ status: CallStatus = .done, service: CallService? = .telegram,
                    page: String? = nil) -> CallRecord {
    let browser = page != nil
    return CallRecord(id: UUID(), startedAt: now.addingTimeInterval(-minutesAgo * 60),
                      appName: browser ? "Google Chrome" : "Telegram",
                      bundleID: browser ? "com.google.Chrome" : "ru.keepcoder.Telegram", service: service,
                      pageTitle: page, status: status)
}

private func segment(_ start: TimeInterval, _ side: CallSide, _ speaker: String, _ text: String,
                     muted: Bool = false) -> CallTranscript.Segment {
    CallTranscript.Segment(start: start, end: start + 3, side: side, speaker: speaker, text: text, duringMute: muted)
}

private func info(_ id: UUID = UUID(), startedAt: Date = now) -> CallMonitor.CallInfo {
    CallMonitor.CallInfo(id: id, appName: "Google Chrome", bundleID: "com.google.Chrome", service: .meet,
                         pageTitle: "Meet – abc-defg-hij", startedAt: startedAt)
}

@Suite struct CallsListTests {
    @Test func groupsByDayNewestFirst() {
        let today = record(30), earlier = record(120), yesterday = record(60 * 24), lastWeek = record(60 * 24 * 6)
        let days = CallsList.days([lastWeek, earlier, yesterday, today], now: now, calendar: calendar)
        #expect(days.map(\.title) == ["Today", "Yesterday", "Saturday"])
        #expect(days[0].calls.map(\.id) == [today.id, earlier.id])
        #expect(days[1].calls.map(\.id) == [yesterday.id])
        #expect(days[2].calls.map(\.id) == [lastWeek.id])
    }

    /// Search finds a call by its title, its page, a speaker as named by the model or by the person, and what was
    /// said, whatever the case and accents.
    @Test func searchMatchesTitleSpeakersAndTranscript() {
        var meet = record(10, service: .meet, page: "Meet – abc-defg-hij")
        meet.transcript = CallTranscript(segments: [
            segment(0, .remote, "Participant 1", "Let’s start with the release plan."),
            segment(5, .remote, "Аня", "Привет! Всё работает."),
        ])
        meet.speakerNames = ["Participant 1": "Matvey"]
        let telegram = record(20)
        let calls = [meet, telegram]
        #expect(CallsList.filter(calls, query: "").count == 2)
        #expect(CallsList.filter(calls, query: "google meet").map(\.id) == [meet.id])
        #expect(CallsList.filter(calls, query: "abc-defg").map(\.id) == [meet.id])
        #expect(CallsList.filter(calls, query: "matvey").map(\.id) == [meet.id])
        #expect(CallsList.filter(calls, query: "participant 1").map(\.id) == [meet.id])
        #expect(CallsList.filter(calls, query: "аня").map(\.id) == [meet.id])
        #expect(CallsList.filter(calls, query: "RELEASE PLAN").map(\.id) == [meet.id])
        #expect(CallsList.filter(calls, query: "привет").map(\.id) == [meet.id])
        #expect(CallsList.filter(calls, query: "  telegram ").map(\.id) == [telegram.id])
        #expect(CallsList.filter(calls, query: "zoom").isEmpty)
    }

    /// The call being asked about isn't in the store until it's kept: the list shows it anyway, as recording, and
    /// a kept one is brought up to date with what the monitor read since (the browser's tab).
    @Test func liveCallIsListed() {
        let stored = [record(60)]
        let asking = info(startedAt: now.addingTimeInterval(-30))
        let listed = CallsList.calls(stored, live: .asking(asking))
        #expect(listed.count == 2)
        #expect(listed.first?.id == asking.id)
        #expect(listed.first?.status == .recording)
        #expect(CallsList.askingID(.asking(asking)) == asking.id)
        #expect(CallsList.calls(stored, live: .suspected(asking)).count == 1, "a suspicion isn't shown")

        var kept = CallRecord(id: asking.id, startedAt: asking.startedAt, appName: "Google Chrome",
                              bundleID: "com.google.Chrome", status: .recording)
        kept.pageTitle = nil
        let merged = CallsList.calls([kept], live: .recording(asking))
        #expect(merged.count == 1)
        #expect(merged[0].service == .meet)
        #expect(CallFormat.title(merged[0]) == "Google Meet · Meet – abc-defg-hij")
    }

    /// The badge counts the calls waiting for the person (an answer, a Transcribe after the app quit, a Retry) and
    /// the live call being asked about.
    @Test func badgeCountsCallsWaiting() {
        let calls = [record(1, .done), record(2, .unconfirmed), record(3, .failed), record(4, .interrupted),
                     record(5, .transcribing), record(6, .recording)]
        #expect(CallsList.badgeCount(calls, live: .idle) == 3)
        #expect(CallsList.badgeCount(calls, live: .asking(info())) == 4)
        #expect(CallsList.badgeCount([], live: .recording(info())) == 0)
    }
}

@MainActor @Suite struct CallFormatTests {
    @Test func titles() {
        #expect(CallFormat.title(record(1)) == "Telegram")
        #expect(CallFormat.title(record(1, service: .meet, page: "Meet – abc-defg-hij")) == "Google Meet · Meet – abc-defg-hij")
        // A page named as the service adds nothing.
        #expect(CallFormat.title(record(1, service: .slack, page: "Slack")) == "Slack")
        var manual = CallRecord(id: UUID(), startedAt: now, appName: CallMonitor.manualName, manual: true,
                                status: .done)
        #expect(CallFormat.title(manual) == "Menu bar recording")
        manual.muteKnown = false
        #expect(CallFormat.place(manual).contains("menu bar"))
        let chrome = CallRecord(id: UUID(), startedAt: now, appName: "Google Chrome", bundleID: "com.google.Chrome",
                                service: .meet, status: .done)
        #expect(CallFormat.place(chrome) == "In Google Chrome")
        #expect(CallFormat.place(record(1)) == "In the Telegram app")
    }

    /// The transcript copies as a line a phrase: its time, the speaker as renamed, what was said; muted says so.
    @Test func copiedTranscript() {
        var call = record(1)
        call.transcript = CallTranscript(segments: [
            segment(4, .remote, "Participant 1", "Okay, let’s start."),
            segment(65, .local, "Sam", "Sure."),
            segment(3700, .local, "Sam", "My coffee’s cold.", muted: true),
        ])
        call.speakerNames = ["Participant 1": "Matvey"]
        #expect(CallFormat.copyText(call) == """
            [00:04] Matvey: Okay, let’s start.
            [01:05] Sam: Sure.
            [1:01:40] Sam (muted): My coffee’s cold.
            """)
        #expect(CallFormat.copyText(record(1)).isEmpty)
        #expect(CallFormat.speakers(call) == "Matvey, Sam")
        #expect(CallFormat.speakers(record(1)) == nil)
    }

    @Test func notesAndProblems() {
        var call = record(1)
        call.muteKnown = true
        call.muteIntervals = [CallInterval(start: 10, end: 40), CallInterval(start: 100, end: 130)]
        call.otherBrowserAudio = [CallInterval(start: 5, end: 9)]
        #expect(CallFormat.notes(call) == [
            "You were muted 2 times (1:00 in all).",
            "Another tab played sound during the call, so it may be mixed into their side.",
        ])
        call.muteIntervals = []
        call.otherBrowserAudio = []
        call.muteKnown = false
        #expect(CallFormat.notes(call).first?.hasPrefix("Mute isn’t known for this app") == true)

        call.remoteProblem = CallStore.silentTapMessage
        call.micProblem = "No permission to use the microphone"
        call.remoteFile = "remote.m4a"
        let problems = CallFormat.problems(call)
        #expect(problems.count == 2)
        #expect(problems[0] == CallProblem(text: "Their side wasn’t recorded: allow System Audio Recording in "
                                               + "Privacy & Security.", pane: .systemAudio))
        #expect(problems[1].text == "Your side wasn’t recorded. No permission to use the microphone.")
        #expect(problems[1].pane == .microphone)
    }
}

@Suite struct CallSpeakerColorTests {
    /// Each speaker keeps one slot all through the call: the mic's side and the other side counted apart, in the
    /// order they first speak, and keyed by the model's name so a rename changes nothing.
    @Test func slotsAreStablePerSpeaker() {
        let transcript = CallTranscript(segments: [
            segment(0, .remote, "Participant 1", "a"),
            segment(1, .local, "Sam", "b"),
            segment(2, .remote, "Аня", "c"),
            segment(3, .remote, "Participant 1", "d"),
            segment(4, .local, "Nearby 1", "e"),
            segment(5, .local, "Sam", "f", muted: true),
        ])
        let slots = CallSpeakerPalette.slots(transcript)
        #expect(slots["Participant 1"] == CallSpeakerSlot(side: .remote, index: 0))
        #expect(slots["Аня"] == CallSpeakerSlot(side: .remote, index: 1))
        #expect(slots["Sam"] == CallSpeakerSlot(side: .local, index: 0))
        #expect(slots["Nearby 1"] == CallSpeakerSlot(side: .local, index: 1))
        #expect(CallSpeakerPalette.slots(transcript) == slots)
        // Later phrases don't move earlier speakers.
        var longer = transcript
        longer.segments.insert(segment(0.5, .remote, "Participant 2", "g"), at: 1)
        #expect(CallSpeakerPalette.slots(longer)["Participant 1"] == slots["Participant 1"])
        #expect(CallSpeakerPalette.slots(nil).isEmpty)
    }

    @Test func sidesWearDifferentColors() {
        let local = CallSpeakerSlot(side: .local, index: 0), remote = CallSpeakerSlot(side: .remote, index: 0)
        #expect(Set(CallSpeakerColors.local).isDisjoint(with: CallSpeakerColors.remote))
        #expect(CallSpeakerColors.color(local) != CallSpeakerColors.color(remote))
        #expect(CallSpeakerColors.color(CallSpeakerSlot(side: .remote, index: CallSpeakerColors.remote.count))
                == CallSpeakerColors.color(remote), "wraps round")
    }
}

@MainActor @Suite struct CallRenameTests {
    /// Renaming flows through the store: every phrase of that speaker, the speakers line, search and the copied
    /// text; an empty name, or the model's own, undoes it.
    @Test func renameShowsEverywhereInTheCall() {
        var call = record(1)
        call.transcript = CallTranscript(segments: [
            segment(0, .remote, "Participant 1", "Hello."),
            segment(4, .local, "Sam", "Hi."),
            segment(8, .remote, "Participant 1", "Bye."),
        ])
        let other = record(2)
        let store = CallStore.preview(calls: [call, other])
        store.rename(speaker: "Participant 1", to: "  Matvey ", in: call.id)
        let renamed = store.call(id: call.id)!
        #expect(renamed.speakerNames == ["Participant 1": "Matvey"])
        #expect(CallFormat.speakers(renamed) == "Matvey, Sam")
        #expect(CallFormat.copyText(renamed).components(separatedBy: "\n").filter { $0.contains("Matvey:") }.count == 2)
        #expect(CallsList.filter(store.calls, query: "matvey").map(\.id) == [call.id])
        #expect(store.call(id: other.id)!.speakerNames.isEmpty)

        store.rename(speaker: "Participant 1", to: "", in: call.id)
        #expect(store.call(id: call.id)!.speakerNames.isEmpty)
        store.rename(speaker: "Participant 1", to: "Participant 1", in: call.id)
        #expect(store.call(id: call.id)!.speakerNames.isEmpty)
    }
}

@MainActor @Suite struct CallMenuTests {
    @Test func statusLineWhileACallRecords() {
        let call = info(startedAt: now.addingTimeInterval(-754))
        #expect(CallsCopy.menuStatus(call, now: now) == "Recording call · Google Meet · 12:34")
        let manual = CallMonitor.CallInfo(id: UUID(), appName: CallMonitor.manualName,
                                          startedAt: now.addingTimeInterval(-3725), manual: true)
        #expect(CallsCopy.menuStatus(manual, now: now) == "Recording call · All sound · 1:02:05")
    }

    /// The menu bar's red dot shows for a dictation recording and for a call recorded, asked about or kept.
    @Test func menuBarDot() {
        #expect(MenuBarController.showsRecordingDot(activity: .idle, recordingCall: true))
        #expect(MenuBarController.showsRecordingDot(activity: .recording, recordingCall: false))
        #expect(!MenuBarController.showsRecordingDot(activity: .processing, recordingCall: false))
        #expect(MenuBarController.accessibilityValue(activity: .idle, recordingCall: true) == "Recording call")
        #expect(MenuBarController.accessibilityValue(activity: .idle, recordingCall: false) == "Idle")
        #expect(CallsList.liveInfo(.suspected(info())) == nil, "a suspicion shows no dot")
        #expect(CallsList.liveInfo(.asking(info())) != nil)
    }

    /// The question names the service, keeps Transcribe first, and stays until it's answered.
    @Test func callQuestion() {
        let id = UUID()
        let notice = Notice.transcribeCall(id, service: "Google Meet")
        #expect(notice.title == "Transcribe your call in Google Meet?")
        #expect(notice.lifetime == .sticky)
        #expect(notice.actions.map(\.title) == ["Transcribe", "Don’t Keep"])
        #expect(notice.primaryAction?.kind == .keepCall(id))
        #expect(notice.actions.last?.kind == .discardCall(id))
        #expect(notice.dedupeKey == Notice.callQuestionKey(id))
    }

    @Test func recordCallsChoices() {
        #expect(CallRecordingMode.pickerOrder.map(\.title) == ["Off", "Ask First", "Automatically"])
        #expect(Set(CallRecordingMode.pickerOrder) == Set(CallRecordingMode.allCases))
    }
}
