import Foundation
import Testing
@testable import MurmurApp

@Suite struct HubGreetingTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }

    private func at(hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: hour, minute: 30))!
    }

    @Test(arguments: [(5, "Good morning"), (11, "Good morning"), (12, "Good afternoon"), (17, "Good afternoon"),
                      (18, "Good evening"), (23, "Good evening"), (2, "Good evening")])
    func dayPartByHour(hour: Int, expected: String) {
        #expect(HubGreeting.text(for: at(hour: hour), name: nil, calendar: calendar) == expected)
    }

    @Test func includesTheName() {
        #expect(HubGreeting.text(for: at(hour: 9), name: "Sam", calendar: calendar) == "Good morning, Sam")
        #expect(HubGreeting.text(for: at(hour: 9), name: "", calendar: calendar) == "Good morning")
    }

    @Test func firstNameFromFullNameOrAccount() {
        #expect(HubGreeting.firstName(fullName: "Sam Smith", accountName: "sam") == "Sam")
        #expect(HubGreeting.firstName(fullName: "  Анна  Петрова", accountName: "anna") == "Анна")
        #expect(HubGreeting.firstName(fullName: "", accountName: "sam") == "Sam")
        #expect(HubGreeting.firstName(fullName: "", accountName: "  ") == nil)
    }
}

@Suite struct HistoryGroupingTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 15))!
    }

    private func entry(hoursAgo: Double, text: String = "hello", status: TranscriptStatus = .success,
                       error: String? = nil) -> TranscriptEntry {
        TranscriptEntry(createdAt: now.addingTimeInterval(-hoursAgo * 3600), text: text, engine: .parakeet,
                        status: status, audioDuration: 4, voicedSeconds: 3, errorMessage: error)
    }

    @Test func groupsByDayNewestFirst() {
        let entries = [entry(hoursAgo: 30), entry(hoursAgo: 1), entry(hoursAgo: 2), entry(hoursAgo: 24 * 10)]
        let days = HistoryGrouping.days(entries, now: now, calendar: calendar)
        #expect(days.map(\.title) == ["Today", "Yesterday", "Sep 15"])
        #expect(days[0].entries.map(\.createdAt) == [entries[1].createdAt, entries[2].createdAt])
    }

    @Test func emptyHistoryHasNoDays() {
        #expect(HistoryGrouping.days([], now: now, calendar: calendar).isEmpty)
    }

    @Test func searchIsCaseAndDiacriticInsensitive() {
        let entries = [entry(hoursAgo: 1, text: "Café meeting at noon"), entry(hoursAgo: 2, text: "Купить молоко"),
                       entry(hoursAgo: 3, text: "", status: .failed, error: "Gemini took too long")]
        #expect(HistoryGrouping.filter(entries, query: "cafe").count == 1)
        #expect(HistoryGrouping.filter(entries, query: "МОЛОКО").count == 1)
        #expect(HistoryGrouping.filter(entries, query: "took too").count == 1)
        #expect(HistoryGrouping.filter(entries, query: "   ").count == 3)
        #expect(HistoryGrouping.filter(entries, query: "zebra").isEmpty)
    }
}

@Suite struct StatFormatTests {
    @Test func timeSaved() {
        #expect(StatFormat.timeSaved(0) == [StatPart(value: "0", unit: "m")])
        #expect(StatFormat.timeSaved(45) == [StatPart(value: "45", unit: "s")])
        #expect(StatFormat.timeSaved(12 * 60 + 20) == [StatPart(value: "12", unit: "m")])
        #expect(StatFormat.timeSaved(72 * 60) == [StatPart(value: "1", unit: "h"), StatPart(value: "12", unit: "m")])
        #expect(StatFormat.timeSaved(3 * 3600) == [StatPart(value: "3", unit: "h")])
        #expect(StatFormat.timeSaved(-5) == [StatPart(value: "0", unit: "m")])
    }

    @Test func sparklineIsRelativeToTheBusiestDay() {
        #expect(StatFormat.sparkline([0, 50, 100, 25, 0, 0, 10]) == [0, 0.5, 1, 0.25, 0, 0, 0.1])
        #expect(StatFormat.sparkline(Array(repeating: 0, count: 7)) == Array(repeating: 0, count: 7))
    }
}

@Suite struct EngineReadinessTests {
    @Test func localStates() {
        #expect(EngineReadiness.of(.parakeet, localState: .ready, keyStatus: .missing) == .ready)
        #expect(EngineReadiness.of(.whisper, localState: .installed, keyStatus: .missing) == .ready)
        #expect(EngineReadiness.of(.whisper, localState: .downloading(.zero), keyStatus: .missing) == .warming)
        #expect(EngineReadiness.of(.whisper, localState: .preparing(since: Date()), keyStatus: .missing) == .warming)
        #expect(EngineReadiness.of(.parakeet, localState: .notInstalled, keyStatus: .missing) == .needsDownload)
        #expect(EngineReadiness.of(.parakeet, localState: .failed("x"), keyStatus: .missing) == .failed("x"))
    }

    @Test func cloudStatesIgnoreLocalState() {
        let info = KeyInfo(limitRemaining: 3)
        #expect(EngineReadiness.of(.geminiFlash, localState: .notInstalled, keyStatus: .valid(info)) == .ready)
        #expect(EngineReadiness.of(.geminiPro, localState: .notInstalled, keyStatus: .missing) == .needsKey)
        #expect(EngineReadiness.of(.geminiPro, localState: .notInstalled, keyStatus: .invalid("401")).unavailableReason == "Key rejected")
        #expect(EngineReadiness.of(.geminiPro, localState: .notInstalled, keyStatus: .noCredit(nil)).isUsable == false)
        #expect(EngineReadiness.of(.geminiFlash, localState: .notInstalled, keyStatus: .offline).isUsable)
    }

    @Test func summaryChip() {
        #expect(EngineSummary.make(engine: .parakeet, localState: .ready, keyStatus: .missing)
            == EngineSummary(name: "Parakeet v3", status: "Ready", tone: .positive))
        #expect(EngineSummary.make(engine: .whisper, localState: .preparing(since: Date()), keyStatus: .missing).status == "Optimizing…")
        #expect(EngineSummary.make(engine: .whisper, localState: .downloading(DownloadProgress(fraction: 0.42)), keyStatus: .missing).status
            == "Downloading 42%")
        #expect(EngineSummary.make(engine: .geminiFlash, localState: .notInstalled, keyStatus: .missing)
            == EngineSummary(name: "Gemini Flash", status: "Key missing", tone: .negative))
    }
}

@Suite struct HubAttentionTests {
    private func input(mic: PermissionState = .granted, ax: PermissionState = .granted, stale: Bool = false,
                       fn: FnKeyUsage = .doNothing, pttUsesFn: Bool = true, engine: EngineID = .parakeet,
                       local: LocalModelState = .ready, key: KeyStatus = .missing) -> HubAttention.Input {
        HubAttention.Input(microphone: mic, accessibility: ax, accessibilityLikelyStale: stale, fnKeyUsage: fn,
                           pushToTalkUsesFn: pttUsesFn, engine: engine, localState: local, keyStatus: key)
    }

    @Test func nothingWhenAllIsWell() {
        #expect(HubAttention.items(input()).isEmpty)
        // A missing key only matters when a cloud engine is selected.
        #expect(HubAttention.items(input(engine: .parakeet, key: .invalid("401"))).isEmpty)
    }

    @Test func blockingIssuesComeFirst() {
        let items = HubAttention.items(input(mic: .denied, ax: .notDetermined, fn: .other("Emoji & Symbols"),
                                             engine: .whisper, local: .notInstalled))
        #expect(items.map(\.id) == ["microphone", "accessibility", "model", "fnKey"])
        #expect(items[0].action == .openPane(.microphone))
        #expect(items[1].action == .requestAccessibility)
        #expect(items[2].action == .download(.whisper))
        #expect(items[3].title == "The fn key opens Emoji & Symbols")
    }

    @Test func undecidedMicrophoneAsksDirectly() {
        let items = HubAttention.items(input(mic: .notDetermined))
        #expect(items.first?.action == .requestMicrophone)
        #expect(items.first?.actionTitle == "Allow")
    }

    @Test func staleAccessibilityPointsToSettings() {
        let items = HubAttention.items(input(ax: .denied, stale: true))
        #expect(items.first?.action == .openPane(.accessibility))
    }

    @Test func downloadShowsProgress() throws {
        let progress = DownloadProgress(fraction: 0.64, secondsRemaining: 30)
        let item = try #require(HubAttention.items(input(engine: .whisper, local: .downloading(progress))).first)
        #expect(item.title == "Whisper Large V3 Turbo is downloading · 64%")
        #expect(item.body == "About 30 s left.")
        #expect(item.progress == 0.64)
        #expect(item.action == .openModels)
    }

    @Test func keyProblemsForCloudEngines() {
        #expect(HubAttention.items(input(engine: .geminiFlash, key: .missing)).first?.actionTitle == "Add key")
        #expect(HubAttention.items(input(engine: .geminiPro, key: .invalid("401"))).first?.actionTitle == "Update key")
        #expect(HubAttention.items(input(engine: .geminiPro, key: .noCredit(nil))).first?.action == .openURL(OpenRouterLinks.credits))
        #expect(HubAttention.items(input(engine: .geminiPro, key: .offline)).isEmpty)
    }

    @Test func fnHintOnlyWhenPushToTalkUsesFn() {
        #expect(HubAttention.items(input(fn: .other("Dictation"), pttUsesFn: false)).isEmpty)
    }
}

@Suite struct HubChoicesTests {
    @Test func whisperLanguageNames() {
        #expect(WhisperLanguage.name(for: nil) == "Automatic")
        #expect(WhisperLanguage.name(for: "ru") == "Russian")
        #expect(WhisperLanguage.name(for: "xx") == "XX")
        #expect(Set(WhisperLanguage.all.map(\.code)).count == WhisperLanguage.all.count)
    }

    @Test func retentionLabels() {
        #expect(RetentionChoice.days.map(RetentionChoice.label) == ["Don’t keep", "1 day", "7 days", "14 days", "30 days"])
        #expect(RetentionChoice.days.contains(14))
    }
}
