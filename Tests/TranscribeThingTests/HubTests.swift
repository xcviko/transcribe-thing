import Foundation
import Testing
@testable import TranscribeThing

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

    @Test func countsEachDaysWords() {
        let entries = [entry(hoursAgo: 1, text: "one two three"), entry(hoursAgo: 2, text: "four — five"),
                       entry(hoursAgo: 30, text: "six")]
        let days = HistoryGrouping.days(entries, now: now, calendar: calendar)
        #expect(days.map(\.words) == [5, 1])
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

/// Home's list comes from `HistoryStore.days(matching:now:)`, cached until the history, the day or the search changes.
@Suite @MainActor struct HistoryDaysCacheTests {
    private func entry(minutesAgo: Double, text: String) -> TranscriptEntry {
        TranscriptEntry(createdAt: Date().addingTimeInterval(-minutesAgo * 60), text: text, engine: .parakeet,
                        status: .success, audioDuration: 4, voicedSeconds: 3)
    }

    @Test func followsEditsAndSearch() {
        let store = HistoryStore.preview(entries: [entry(minutesAgo: 1, text: "Café at noon"), entry(minutesAgo: 2, text: "milk")])
        func uncached(_ query: String) -> [HistoryDay] {
            HistoryGrouping.days(HistoryGrouping.filter(store.entries, query: query), now: Date())
        }
        #expect(store.days(matching: "", now: Date()) == uncached(""))
        #expect(store.days(matching: "cafe", now: Date()).flatMap(\.entries).map(\.text) == ["Café at noon"])

        let added = entry(minutesAgo: 0.5, text: "another cafe")
        store.upsert(added)
        #expect(store.days(matching: "cafe", now: Date()) == uncached("cafe"))
        #expect(store.days(matching: "cafe", now: Date()).flatMap(\.entries).count == 2)

        store.delete(added.id)
        #expect(store.days(matching: "", now: Date()) == uncached(""))
        #expect(store.days(matching: "", now: Date()).map(\.words).reduce(0, +) == 4)
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
        #expect(EngineReadiness.of(.parakeet, localState: .installed, keyStatus: .missing) == .ready)
        #expect(EngineReadiness.of(.parakeet, localState: .downloading(.zero), keyStatus: .missing) == .warming)
        #expect(EngineReadiness.of(.parakeet, localState: .preparing(since: Date()), keyStatus: .missing) == .warming)
        #expect(EngineReadiness.of(.parakeet, localState: .notInstalled, keyStatus: .missing) == .needsDownload)
        #expect(EngineReadiness.of(.parakeet, localState: .failed("x"), keyStatus: .missing) == .failed("Download failed"))
    }

    @Test func failedModelsSayWhatFailed() {
        let loadError = AppError.modelLoadFailed(.parakeet, "corrupt")
        #expect(EngineReadiness.of(.parakeet, localState: .failed("x"), keyStatus: .missing, localError: loadError)
            .unavailableReason == "Couldn’t load")
        #expect(EngineReadiness.of(.parakeet, localState: .failed("x"), keyStatus: .missing,
                                   localError: .notEnoughDisk(needed: 2, available: 1)).unavailableReason == "Not enough space")
        #expect(EngineSummary.make(engine: .parakeet, localState: .failed("x"), keyStatus: .missing, localError: loadError)
            .status == "Couldn’t load")
        #expect(EngineSummary.make(engine: .parakeet, localState: .failed("x"), keyStatus: .missing,
                                   localError: .downloadFailed(.parakeet, "offline")).status == "Download failed")
        var input = HubAttention.Input(microphone: .granted, accessibility: .granted, accessibilityLikelyStale: false,
                                       fnKeyUsage: .doNothing, pushToTalkUsesFn: true, engine: .parakeet,
                                       localState: .failed("Couldn’t load the model."), keyStatus: .missing,
                                       localError: loadError)
        #expect(HubAttention.items(input).first?.title == "Couldn’t load Parakeet v3")
        input.localError = .downloadFailed(.parakeet, "offline")
        #expect(HubAttention.items(input).first?.title == "Parakeet v3 didn’t finish downloading")
    }

    @Test func cloudStatesIgnoreLocalState() {
        let info = KeyInfo(limitRemaining: 3)
        #expect(EngineReadiness.of(.geminiFlash, localState: .notInstalled, keyStatus: .valid(info)) == .ready)
        #expect(EngineReadiness.of(.geminiFlash, localState: .notInstalled, keyStatus: .missing) == .needsKey)
        #expect(EngineReadiness.of(.parakeetCloud, localState: .notInstalled, keyStatus: .invalid("401")).unavailableReason == "Key rejected")
        #expect(EngineReadiness.of(.geminiFlash, localState: .notInstalled, keyStatus: .noCredit(nil)).isUsable == false)
        #expect(EngineReadiness.of(.geminiFlash, localState: .notInstalled, keyStatus: .offline).isUsable)
    }

    @Test func summaryChip() {
        #expect(EngineSummary.make(engine: .parakeet, localState: .ready, keyStatus: .missing)
            == EngineSummary(name: "Parakeet v3", status: "Ready", tone: .positive))
        #expect(EngineSummary.make(engine: .parakeet, localState: .preparing(since: Date()), keyStatus: .missing).status == "Optimizing…")
        #expect(EngineSummary.make(engine: .parakeet, localState: .downloading(DownloadProgress(fraction: 0.42)), keyStatus: .missing).status
            == "Downloading 42%")
        #expect(EngineSummary.make(engine: .geminiFlash, localState: .notInstalled, keyStatus: .missing)
            == EngineSummary(name: "Gemini Flash", status: "Needs key", tone: .warning))
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
                                             engine: .parakeet, local: .notInstalled))
        #expect(items.map(\.id) == ["microphone", "accessibility", "model", "fnKey"])
        #expect(items[0].action == .openPane(.microphone))
        #expect(items[1].action == .requestAccessibility)
        #expect(items[2].action == .download(.parakeet))
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
        #expect(items.first?.tone == .error)
    }

    @Test func missingAccessibilitySaysTheShortcutIsDead() throws {
        let item = try #require(HubAttention.items(input(ax: .denied)).first)
        #expect(item.title == "\(Brand.name) can’t hear your shortcut")
        #expect(item.body == "Turn on Accessibility so fn works and text pastes where you type.")
        #expect(item.tone == .error)
        #expect(HubAttention.items(input(ax: .denied, pttUsesFn: false)).first?.body
            == "Turn on Accessibility so your shortcut works and text pastes where you type.")
    }

    @Test func aDeadTapShowsEvenWhenAccessibilityReadsGranted() throws {
        var dead = input()
        dead.shortcutUnavailable = true
        let item = try #require(HubAttention.items(dead).first)
        #expect(item.title == "\(Brand.name) can’t hear your shortcut")
        #expect(item.action == .openPane(.accessibility))
        // Accessibility off already explains it: one card, not two.
        var both = input(ax: .denied)
        both.shortcutUnavailable = true
        #expect(HubAttention.items(both).filter { $0.id == "accessibility" }.count == 1)
    }

    @Test func downloadShowsProgress() throws {
        let progress = DownloadProgress(fraction: 0.64, secondsRemaining: 30)
        let item = try #require(HubAttention.items(input(engine: .parakeet, local: .downloading(progress))).first)
        #expect(item.title == "Parakeet v3 is downloading · 64%")
        #expect(item.body == "About 30 s left.")
        #expect(item.progress == 0.64)
        #expect(item.action == .openModels)
    }

    @Test func keyProblemsForCloudEngines() {
        #expect(HubAttention.items(input(engine: .geminiFlash, key: .missing)).first?.actionTitle == "Add Key")
        #expect(HubAttention.items(input(engine: .parakeetCloud, key: .invalid("401"))).first?.actionTitle == "Update Key")
        #expect(HubAttention.items(input(engine: .parakeetCloud, key: .noCredit(nil))).first?.action == .openURL(OpenRouterLinks.credits))
        #expect(HubAttention.items(input(engine: .parakeetCloud, key: .offline)).isEmpty)
    }

    @Test func keyProblemsNameTheCloudSpeechModel() {
        let limit = KeyStatus.noCredit(KeyInfo(limit: 5, limitRemaining: 0, usage: 5))
        #expect(HubAttention.items(input(engine: .parakeetCloud, key: limit)).first?.body
            == "This key has a spending limit, and it’s used up. Raise it to keep using Parakeet v3 · Cloud.")
        #expect(HubAttention.items(input(engine: .parakeetCloud, key: .noCredit(nil))).first?.body
            == "Add credit to keep using Parakeet v3 · Cloud.")
        #expect(HubAttention.items(input(engine: .geminiFlash, key: .noCredit(nil))).first?.body
            == "Add credit to keep using Gemini.")
        #expect(HubAttention.items(input(engine: .parakeetCloud, key: .missing)).first?.body
            == "Parakeet v3 · Cloud needs a key to transcribe.")
    }

    @Test func fnHintOnlyWhenPushToTalkUsesFn() {
        #expect(HubAttention.items(input(fn: .other("Dictation"), pttUsesFn: false)).isEmpty)
    }
}

@Suite struct CloudSpeechHubTests {
    @Test func readinessAndSummaryFollowTheKey() {
        for engine in EngineID.cloudTranscriptionEngines {
            #expect(EngineReadiness.of(engine, localState: .notInstalled, keyStatus: .valid(KeyInfo())) == .ready)
            #expect(EngineReadiness.of(engine, localState: .ready, keyStatus: .missing).unavailableReason == "Needs key")
        }
        #expect(EngineSummary.make(engine: .parakeetCloud, localState: .ready, keyStatus: .valid(KeyInfo()))
            == EngineSummary(name: "Parakeet v3 · Cloud", status: "Ready", tone: .positive))
    }

    @Test func providerNotesNameWhoServesEachCloudModel() {
        #expect(ProviderNote.text(.parakeetCloud) == "Served by Together.")
        #expect(ProviderNote.text(.geminiFlash) == "Served by Google AI Studio only.")
        #expect(ProviderNote.text(.parakeet) == nil)
    }

    @Test func preparingCopyFitsParakeetsShortFirstLoad() throws {
        let input = HubAttention.Input(microphone: .granted, accessibility: .granted, accessibilityLikelyStale: false,
                                       fnKeyUsage: .doNothing, pushToTalkUsesFn: true, engine: .parakeet,
                                       localState: .preparing(since: Date()), keyStatus: .missing)
        let item = try #require(HubAttention.items(input).first)
        #expect(item.title == "Getting Parakeet v3 ready")
        #expect(!item.body.contains("minutes"))
    }
}

@MainActor @Suite struct HubChoicesTests {
    @Test func autoDeleteLabels() {
        #expect(AutoDeleteChoice.days.map(AutoDeleteChoice.label)
                == ["Never", "After 1 day", "After 7 days", "After 30 days", "After 90 days"])
        #expect(AutoDeleteChoice.days.first == AppSettings.inMemory().autoDeleteHistoryDays, "Never by default")
    }
}

@Suite struct HubSidebarTests {
    @Test func everyPageHasASidebarItem() {
        // Pill & Sounds is gone (its settings live in General): the sidebar lists every section but the
        // sub-pages, in case order.
        #expect(HubSection.sidebar == [.home, .models, .shortcuts, .microphone, .general])
        #expect(HubSection.sidebar == HubSection.allCases.filter { $0 != .softwareUpdate })
    }

    @Test func softwareUpdateSelectsGeneral() {
        #expect(HubSection.softwareUpdate.sidebarItem == .general)
        #expect(HubSection.softwareUpdate.shortcutDigit == nil)
        #expect(HubSection.sidebar.allSatisfy { $0.sidebarItem == $0 })
    }

    @Test func commandDigitsFollowTheSidebar() {
        #expect(HubSection.sidebar.compactMap(\.shortcutDigit) == ["1", "2", "3", "4", "5"])
    }
}

@Suite struct PillCaptionTests {
    @Test func describesEachMode() {
        #expect(PillCaption.text(.always) == "A slim bar waits at the bottom of the screen.")
        #expect(PillCaption.text(.whileDictating) == "Appears when you start talking, then steps aside.")
        #expect(PillCaption.text(.never) == "Nothing on screen while you dictate. Notices still appear.")
    }
}

@Suite struct SwitchModelLineTests {
    private let rightCommand = Shortcut.rightCommand

    /// The line reads the cycle from the main model, in the lineup's order, and follows a move.
    @Test func lineupLineNamesTheStepsFromTheMainModel() {
        var lineup = ModelLineup.default
        let fnTab = Shortcut.fnTab.spokenDescription
        #expect(SwitchModelLine.explanation(.ready(.fnTab), lineup: lineup)
            == "Press \(fnTab) while dictating to step from Parakeet to Clean-up, then Gemini.")
        lineup.main = .gemini
        #expect(SwitchModelLine.explanation(.ready(.fnTab), lineup: lineup)
            == "Press \(fnTab) while dictating to step from Gemini to Parakeet, then Clean-up.")
        lineup.move(.gemini, to: 0)
        #expect(lineup.order == [.gemini, .parakeet, .cleanup])
        lineup.move(.cleanup, to: 1)
        #expect(SwitchModelLine.explanation(.ready(.fnTab), lineup: lineup)
            == "Press \(fnTab) while dictating to step from Gemini to Clean-up, then Parakeet.")
        lineup.setSwitchable(.parakeet, false)
        #expect(SwitchModelLine.explanation(.ready(rightCommand), lineup: lineup)
            == "Press \(rightCommand.spokenDescription) while dictating to step from Gemini to Clean-up.")
    }

    /// Steps that can't run now (no key yet) stay in the line, which says so: Switch model skips them.
    @Test func lineupLineSaysWhichStepsArentReady() {
        let fnTab = Shortcut.fnTab.spokenDescription
        #expect(SwitchModelLine.explanation(.ready(.fnTab), lineup: .default, blocked: [.cleanup, .gemini])
            == "Press \(fnTab) while dictating to step from Parakeet to Clean-up, then Gemini. Clean-up and Gemini aren’t ready yet.")
        #expect(SwitchModelLine.explanation(.ready(.fnTab), lineup: .default, blocked: [.gemini])
            == "Press \(fnTab) while dictating to step from Parakeet to Clean-up, then Gemini. Gemini isn’t ready yet.")
        var geminiMain = ModelLineup.default
        geminiMain.main = .gemini
        #expect(!SwitchModelLine.explanation(.ready(.fnTab), lineup: geminiMain, blocked: [.gemini]).contains("ready yet"),
                "only steps count, never the main model")
    }

    @Test func lineupLineStatuses() {
        var alone = ModelLineup.default
        alone.setSwitchable(.cleanup, false)
        alone.setSwitchable(.gemini, false)
        #expect(SwitchModelLine.status(binding: .fnTab, lineup: .default) == .ready(.fnTab))
        #expect(SwitchModelLine.status(binding: nil, lineup: .default) == .unbound)
        #expect(SwitchModelLine.status(binding: Shortcut(modifiers: []), lineup: .default) == .unbound)
        #expect(SwitchModelLine.status(binding: .fnTab, lineup: alone) == .alone(.fnTab))
        #expect(SwitchModelLine.status(binding: nil, lineup: alone) == .alone(nil))
        // The copy names the user's own binding, never a hard-coded fn Tab.
        let custom = SwitchModelLine.explanation(.alone(rightCommand), lineup: alone)
        #expect(custom == "Switch on another model to reach it with \(rightCommand.compactDescription) while dictating.")
        #expect(!custom.contains("fn"))
        #expect(SwitchModelLine.explanation(.alone(nil), lineup: alone)
            == "Switch on another model and give Switch model a shortcut to use it while dictating.")
        #expect(SwitchModelLine.explanation(.unbound, lineup: .default)
            == "Switch model has no shortcut yet. Set one to switch models while dictating.")
    }
}

@Suite struct ModelChoiceHubTests {
    /// Clean-up needs Parakeet first, then the key: a download says so before the key does.
    @Test func cleanupReadinessPutsParakeetFirstThenTheKey() {
        #expect(EngineReadiness.of(.cleanup, parakeet: .parakeet, localState: .notInstalled, keyStatus: .missing)
            == .needsDownload)
        #expect(EngineReadiness.of(.cleanup, parakeet: .parakeet, localState: .ready, keyStatus: .missing) == .needsKey)
        #expect(EngineReadiness.of(.cleanup, parakeet: .parakeet, localState: .downloading(.zero),
                                   keyStatus: .invalid("401")) == .keyProblem("Key rejected"))
        #expect(EngineReadiness.of(.cleanup, parakeet: .parakeet, localState: .ready, keyStatus: .valid(KeyInfo())) == .ready)
        #expect(EngineReadiness.of(.cleanup, parakeet: .parakeetCloud, localState: .notInstalled, keyStatus: .missing)
            == .needsKey, "on OpenRouter Parakeet needs the key itself")
        #expect(EngineReadiness.of(.parakeet, parakeet: .parakeet, localState: .ready, keyStatus: .missing) == .ready)
        #expect(EngineReadiness.of(.gemini, parakeet: .parakeet, localState: .notInstalled, keyStatus: .valid(KeyInfo()))
            == .ready)
    }

    @Test func theSidebarChipNamesTheMainModel() {
        #expect(EngineSummary.make(choice: .cleanup, parakeet: .parakeet, localState: .ready, keyStatus: .missing)
            == EngineSummary(name: "Parakeet + Luna", status: "Needs key", tone: .warning))
        #expect(EngineSummary.make(choice: .cleanup, parakeet: .parakeet, localState: .preparing(since: Date()),
                                   keyStatus: .missing).status == "Optimizing…", "Parakeet first")
        #expect(EngineSummary.make(choice: .gemini, parakeet: .parakeet, localState: .notInstalled,
                                   keyStatus: .valid(KeyInfo()))
            == EngineSummary(name: "Gemini Flash", status: "Ready", tone: .positive))
        #expect(EngineSummary.make(choice: .parakeet, parakeet: .parakeetCloud, localState: .notInstalled,
                                   keyStatus: .valid(KeyInfo())).name == "Parakeet v3 · Cloud")
    }

    /// One key state reads the same on a lineup row, the sidebar chip and Where Parakeet runs: a missing key or
    /// spent credit is a warning to act on, as the key card's triangle says, a rejected key an error.
    @Test func oneKeyStateHasOneColor() {
        let states: [KeyStatus] = [.missing, .checking, .valid(KeyInfo()), .invalid("401"), .noCredit(nil),
                                   .noCredit(KeyInfo(limit: 10, limitRemaining: 0)), .offline, .failed("x")]
        for state in states {
            let summary = EngineSummary.make(engine: .geminiFlash, localState: .ready, keyStatus: state)
            let row = ModelStatusText.describe(state)
            #expect(summary.tone == row.tone, "\(state)")
            if case .valid = state { continue }
            #expect(summary.status == row.text || (state == .offline && summary.status == "Offline"), "\(state)")
        }
        #expect(ModelStatusText.describe(.missing).tone == .warning)
        #expect(ModelStatusText.describe(.noCredit(nil)).tone == .warning)
        #expect(ModelStatusText.describe(.invalid("401")).tone == .negative)
    }

    /// A model wears one color: its tile in Models and the sidebar, and its pill.
    @Test func eachModelWearsThePillsColor() {
        #expect(ModelChoice.gemini.tint == .accent && PillPalette.accent(for: .gemini) != nil, "violet")
        #expect(ModelChoice.cleanup.tint == .warm && PillPalette.accent(for: .cleanup) != nil, "warm")
        #expect(ModelChoice.parakeet.tint == .inkSecondary && PillPalette.accent(for: .parakeet) == nil, "plain")
    }

    @Test func aCleanupMainWithoutAKeyShowsTheKeyCard() throws {
        func items(_ key: KeyStatus, cleansUp: Bool = true) -> [AttentionItem] {
            HubAttention.items(HubAttention.Input(microphone: .granted, accessibility: .granted,
                                                  accessibilityLikelyStale: false, fnKeyUsage: .doNothing,
                                                  pushToTalkUsesFn: true, engine: .parakeet, localState: .ready,
                                                  keyStatus: key, cleansUp: cleansUp))
        }
        let missing = try #require(items(.missing).first)
        #expect(missing.title == "Add your OpenRouter key")
        #expect(missing.body == "Clean-up needs a key to tidy your text.")
        #expect(missing.action == .openModels)
        #expect(items(.invalid("401")).first?.title == "Your OpenRouter key stopped working")
        #expect(items(.noCredit(nil)).first?.body == "Add credit to keep using clean-up.")
        #expect(items(.valid(KeyInfo())).isEmpty)
        #expect(items(.missing, cleansUp: false).isEmpty, "Parakeet alone needs no key")
    }
}
