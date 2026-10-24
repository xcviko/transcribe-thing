import Foundation
import Testing
@testable import TranscribeThing

// MARK: - A click away while a dictation is processed holds its paste (General → Pasting)

@MainActor
@Suite(.serialized) struct ClickAwayTests {
    typealias R = ProcessingRig

    /// A Gemini dictation whose first request waits on `first` (later ones answer at once), with the clicks away heard
    /// through a monitor that stands for the mouse (`ClickAwayMonitor.mouseDown(at:)`); `own` says whether a point is
    /// the pill or a card.
    static func make(first: RequestGate, fails: Bool = false, own: @escaping (CGPoint) -> Bool = { _ in false })
        -> (R.Rig, SwitchModelControllerTests.Cues, Requests, ClickAwayMonitor) {
        let monitor = ClickAwayMonitor(listens: false)
        monitor.isOwnContent = own
        let (rig, cues, requests) = R.make(clickAway: monitor) { engine, prompt, number in
            if number == 1 { try await first.wait() }
            if fails { throw AppError.timeout(engine) }
            return R.gemini(prompt)
        }
        return (rig, cues, requests, monitor)
    }

    static let away = CGPoint(x: 40, y: 700)

    static func card(_ rig: R.Rig) -> Notice? {
        rig.h.toasts.notices.first { $0.dedupeKey.hasPrefix(DictationController.clickedAwayCardPrefix) }
    }

    /// A click elsewhere while it's processed: the pill's outline dashed, and once the text is there it isn't pasted:
    /// it comes up on a card (with its sound) to paste or copy, which takes neither ↩ nor Esc. History has it as usual.
    /// The outline stays dashed as the pill leaves with it, until the next dictation.
    @Test func aClickAwayPutsTheTextOnACard() async throws {
        let first = RequestGate()
        let (rig, cues, requests, monitor) = Self.make(first: first)
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        #expect(monitor.isWatching && !rig.h.pill.holdsPaste)
        monitor.mouseDown(at: Self.away)
        #expect(rig.h.pill.holdsPaste && rig.h.pill.phase == .processing)
        #expect(!monitor.isWatching, "one click is enough")

        first.isOpen = true
        try await waitUntil { Self.card(rig) != nil && c.machine.activeJobs == 0 }
        #expect(rig.pasted.isEmpty, "not pasted")
        let card = try #require(Self.card(rig))
        #expect(card.title == "Not pasted: you clicked away")
        #expect(card.transcript == "plain words")
        #expect(card.actions.map(\.title) == ["Paste Here", "Copy"])
        #expect(card.isPasteCard && !card.takesCardKeys && card.waitsForDictation)
        #expect(!rig.h.hotkeys.cardPaste && !rig.h.hotkeys.cardClose, "↩ and Esc stay the app's")
        #expect(cues.played.last == .polishReady)
        let entry = try #require(rig.h.history.entries.first)
        #expect(entry.status == .success && entry.text == "plain words")
        #expect(rig.h.pill.holdsPaste, "still dashed as the pill leaves")

        SwitchModelControllerTests.hold(rig)
        #expect(!rig.h.pill.holdsPaste, "the next dictation is solid")
        c.handle(.cancel)
    }

    /// Paste Here pastes the text by General → Pasting's rules for the model that wrote it, and the card goes.
    @Test func pasteHerePastesItByPastingsRules() async throws {
        let first = RequestGate()
        let (rig, _, requests, _) = Self.make(first: first)
        let c = rig.h.controller
        rig.h.settings.modelsAddingSpace = [.gemini]
        rig.h.settings.modesAddingSpace = [.pushToTalk]
        var pastedHere: [String] = []
        c.pasteNowOverride = { pastedHere.append($0); return .pasted }
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        c.clickedAway()
        first.isOpen = true
        try await waitUntil { Self.card(rig) != nil && c.machine.activeJobs == 0 }
        let card = try #require(Self.card(rig))
        try rig.click(.pasteText("plain words", by: .gemini, in: .pushToTalk), in: card.dedupeKey)
        try await waitUntil { pastedHere.count == 1 }
        #expect(pastedHere == ["plain words "])
        #expect(Self.card(rig) == nil && rig.pasted.isEmpty)
    }

    /// Copy takes the text with the paste tick, and the card goes.
    @Test func copyTakesTheText() async throws {
        let first = RequestGate()
        let (rig, cues, requests, _) = Self.make(first: first)
        let c = rig.h.controller
        var copied: [String] = []
        c.copyOverride = { copied.append($0) }
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        c.clickedAway()
        first.isOpen = true
        try await waitUntil { Self.card(rig) != nil && c.machine.activeJobs == 0 }
        try rig.click(.copyText("plain words"), in: try #require(Self.card(rig)).dedupeKey)
        #expect(copied == ["plain words"])
        #expect(cues.played.last == .paste)
        #expect(Self.card(rig) == nil && rig.pasted.isEmpty)
    }

    /// Send on for it: the click turns it off with Send's sound and the plane leaves the pill. Its key can't turn it
    /// back on, and no Return is ever pressed. Another click changes nothing more.
    @Test func aClickTurnsSendOff() async throws {
        let first = RequestGate()
        let (rig, cues, requests, monitor) = Self.make(first: first)
        let c = rig.h.controller
        var returns = 0
        c.returnDelay = .milliseconds(5)
        c.pressReturnOverride = { returns += 1; return .pressed }
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        SwitchModelControllerTests.hold(rig)
        c.handle(.send)
        rig.now += 2
        c.handle(.pttUp)
        try await waitUntil { requests.gemini.count == 1 }
        #expect(rig.h.pill.sends)
        let before = cues.played.count
        monitor.mouseDown(at: Self.away)
        #expect(!rig.h.pill.sends && rig.h.pill.holdsPaste)
        #expect(Array(cues.played.dropFirst(before)) == [.sendOn], "Send's sound, as its key turning it off")
        c.clickedAway()
        c.handle(.send)
        c.handle(.shortcutKeyUp)
        #expect(!rig.h.pill.sends && cues.played.count == before + 1, "nothing more")

        first.isOpen = true
        try await waitUntil { Self.card(rig) != nil && c.machine.activeJobs == 0 }
        try await Task.sleep(for: .milliseconds(40))
        #expect(returns == 0 && rig.pasted.isEmpty)
    }

    /// While recording, a click is part of dictating (into another field, say): nothing changes, and the text is
    /// pasted as always. No click is listened for until the recording stops.
    @Test func aClickWhileRecordingChangesNothing() async throws {
        let first = RequestGate()
        first.isOpen = true
        let (rig, _, _, monitor) = Self.make(first: first)
        let c = rig.h.controller
        var returns = 0
        c.returnDelay = .milliseconds(5)
        c.pressReturnOverride = { returns += 1; return .pressed }
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        SwitchModelControllerTests.hold(rig)
        c.handle(.send)
        #expect(!monitor.isWatching)
        c.clickedAway()
        monitor.mouseDown(at: Self.away)
        #expect(rig.h.pill.sends && !rig.h.pill.holdsPaste)
        rig.now += 2
        c.handle(.pttUp)
        try await waitUntil { rig.pasted.count == 1 && returns == 1 && c.machine.activeJobs == 0 }
        #expect(Self.card(rig) == nil)
        #expect(!monitor.isWatching)
    }

    /// A click on the pill or a card is the app's own, even one the panel let through: nothing changes.
    @Test func aClickOnTheAppsOwnContentChangesNothing() async throws {
        let first = RequestGate()
        let pill = CGRect(x: 400, y: 20, width: 120, height: 40)
        let (rig, _, requests, monitor) = Self.make(first: first, own: { pill.contains($0) })
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        monitor.mouseDown(at: CGPoint(x: 450, y: 40))
        #expect(!rig.h.pill.holdsPaste && monitor.isWatching)
        first.isOpen = true
        try await waitUntil { rig.pasted.count == 1 && c.machine.activeJobs == 0 }
        #expect(Self.card(rig) == nil)
    }

    /// With the setting off, nothing is listened for and a click changes nothing: the text is pasted as before.
    @Test func withTheSettingOffItsPasted() async throws {
        let first = RequestGate()
        let (rig, _, requests, monitor) = Self.make(first: first)
        let c = rig.h.controller
        rig.h.settings.holdsPasteAfterClick = false
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        #expect(!monitor.isWatching)
        c.clickedAway()
        #expect(!rig.h.pill.holdsPaste)
        first.isOpen = true
        try await waitUntil { rig.pasted.count == 1 && c.machine.activeJobs == 0 }
        #expect(Self.card(rig) == nil)
    }

    /// Esc after a click cancels the dictation as always: no card, then or later.
    @Test func escAfterAClickCancels() async throws {
        let first = RequestGate()
        let (rig, _, requests, _) = Self.make(first: first)
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        c.clickedAway()
        c.handle(.cancel)
        #expect(c.machine.activeJobs == 0 && rig.notice("dictation.canceled") != nil)
        #expect(!rig.h.pill.holdsPaste || rig.h.pill.phase != .processing)
        first.isOpen = true
        try await Task.sleep(for: .milliseconds(60))
        #expect(Self.card(rig) == nil && rig.pasted.isEmpty)
    }

    /// Polish after a click sends it again with Polish, as without one; the polished message comes up on the card.
    @Test func polishAfterAClickResendsAndTheCardHasIt() async throws {
        let first = RequestGate()
        let (rig, _, requests, _) = Self.make(first: first)
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        c.clickedAway()
        c.handle(.polish)
        #expect(rig.h.pill.polishes && rig.h.pill.holdsPaste)
        c.handle(.shortcutKeyUp)
        try await waitUntil { requests.gemini.count == 2 }
        #expect(requests.gemini[1] == Polish.prompt)
        try await waitUntil { Self.card(rig) != nil && c.machine.activeJobs == 0 }
        #expect(first.wasCancelled)
        #expect(Self.card(rig)?.transcript == "Polished words.")
        #expect(rig.pasted.isEmpty)
        #expect(rig.h.history.entries.first?.currentKind == .polish(by: .geminiFlash))
    }

    /// A dictation that fails after a click fails as always: its notice with Retry, no card.
    @Test func aFailureShowsAsAlways() async throws {
        let first = RequestGate()
        let (rig, _, requests, _) = Self.make(first: first, fails: true)
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        c.clickedAway()
        first.isOpen = true
        try await waitUntil { rig.h.history.entries.first?.status == .failed && c.machine.activeJobs == 0 }
        #expect(rig.h.toasts.notices.contains { $0.actions.contains { $0.kind == .retry } })
        #expect(Self.card(rig) == nil)
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        try body(defaults)
    }

    /// On by default (an older build stored nothing), kept once turned off, and said in the diagnostics' settings line.
    @Test func theSettingIsOnByDefaultAndKept() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() })
            #expect(settings.holdsPasteAfterClick)
            #expect(DiagnosticSettingsSummary(settings: settings, keySaved: false).line
                .contains("holdPasteAfterClick=on"))
            settings.holdsPasteAfterClick = false
            #expect(defaults.object(forKey: "tt.holdsPasteAfterClick") as? Bool == false)
            let again = AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() })
            #expect(!again.holdsPasteAfterClick)
            #expect(DiagnosticSettingsSummary(settings: again, keySaved: false).line
                .contains("holdPasteAfterClick=off"))
        }
    }
}
