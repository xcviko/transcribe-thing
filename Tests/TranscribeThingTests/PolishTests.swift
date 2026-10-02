import Foundation
import Testing
@testable import TranscribeThing

@MainActor
@Suite(.serialized) struct PolishControllerTests {
    typealias Switch = SwitchModelControllerTests

    /// fn ↩ while a dictation is on Gemini turns Polish on with a rising drop, and off again with a falling one; the
    /// pill shows it, and the next dictation starts without.
    @Test func thePolishKeyTurnsItOnAndOffOnGemini() {
        let (rig, cues) = Switch.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .gemini
        Switch.hold(rig)
        c.handle(.polish)
        #expect(c.isPolishing && rig.h.pill.polishes)
        c.handle(.polish)
        #expect(!c.isPolishing && !rig.h.pill.polishes)
        c.handle(.polish)
        #expect(cues.played.suffix(3) == [.polishOn, .polishOff, .polishOn])
        #expect(c.machine.capture.isListeningOrLocked, "it never stops the recording")
        c.send(.pillCancel)
        #expect(!c.isPolishing)
    }

    /// Pressed again and again (the router sends each autorepeat of a held fn ↩ as one), Polish goes on and off, each
    /// time with its drop's sound.
    @Test func everyPressOfThePolishKeyFlipsIt() {
        let (rig, cues) = Switch.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .gemini
        Switch.hold(rig)
        for _ in 0..<5 { c.handle(.polish) }
        #expect(c.isPolishing)
        #expect(cues.played.suffix(5) == [.polishOn, .polishOff, .polishOn, .polishOff, .polishOn])
        c.send(.pillCancel)
    }

    /// On Parakeet or clean-up the key does nothing at all; switching away from Gemini turns Polish off.
    @Test func onlyGeminiPolishes() {
        let (rig, cues) = Switch.make()
        let c = rig.h.controller
        Switch.hold(rig)
        c.handle(.polish)
        #expect(!c.isPolishing && !rig.h.pill.polishes)
        #expect(!cues.played.contains(.polishOn))
        c.selectModelForCurrentDictation(.gemini)
        c.handle(.polish)
        #expect(c.isPolishing)
        c.selectModelForCurrentDictation(.cleanup)
        #expect(!c.isPolishing, "off once it's not Gemini")
        c.send(.pillCancel)
    }

    /// The audio goes to Gemini with Polish's prompt; what its <message> tags hold is pasted, and History keeps it as
    /// the polished version.
    @Test func polishPastesTheMessageAndKeepsIt() async throws {
        let (rig, _) = Switch.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .gemini
        var engines: [EngineID] = []
        rig.result = { _, engine in
            engines.append(engine)
            return "- thinking it over\n<message>Polished.</message>"
        }
        Switch.hold(rig)
        c.handle(.polish)
        try await Switch.release(rig)
        #expect(engines == [.geminiFlash])
        #expect(rig.pasted == ["Polished."])
        let entry = try #require(rig.h.history.entries.first)
        #expect(entry.engine == .geminiFlash)
        #expect(entry.versions.map(\.kind) == [.polish])
    }

    /// Esc while a polished dictation is being transcribed, then Undo: it goes on polished.
    @Test func undoAfterEscWhileTranscribingKeepsPolish() async throws {
        let (rig, _) = Switch.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .gemini
        rig.result = { _, _ in
            try await Task.sleep(for: .seconds(30))
            return "late"
        }
        Switch.hold(rig)
        c.handle(.polish)
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        rig.now += 2
        c.handle(.pttUp)
        try await waitUntil { rig.transcribed.count == 1 }
        c.handle(.cancel)
        #expect(!c.isPolishing)
        rig.now += 1
        try rig.click(.undoCancel, in: "dictation.canceled")
        #expect(c.machine.capture.isListeningOrLocked)
        #expect(c.isPolishing && rig.h.pill.polishes)
        c.send(.pillCancel)
    }

    /// The main model changed under a polishing dictation (Models, a notice's "Use Parakeet v3"): it goes to Parakeet
    /// as a plain transcript, never as a polished one.
    @Test func aDictationThatLeftGeminiIsNotPolished() async throws {
        let (rig, _) = Switch.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .gemini
        var engines: [EngineID] = []
        rig.result = { _, engine in
            engines.append(engine)
            return "words"
        }
        Switch.hold(rig)
        c.handle(.polish)
        rig.h.settings.lineup.main = .parakeet
        try await Switch.release(rig)
        #expect(engines == [.parakeet])
        let entry = try #require(rig.h.history.entries.first)
        #expect(entry.versions.map(\.kind) == [.transcription(.parakeet)])
    }

    /// Polish from a failed dictation's Retry With: the polished message becomes its text.
    @Test func polishingAFailedDictationMakesItsText() async throws {
        let (rig, _) = Switch.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .gemini
        rig.result = { _, _ in throw AppError.timeout(.geminiFlash) }
        Switch.hold(rig)
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        rig.now += 2
        c.handle(.pttUp)
        try await waitUntil { rig.h.history.entries.first?.status == .failed && c.machine.activeJobs == 0 }
        let failed = try #require(rig.h.history.entries.first)
        rig.result = { _, _ in "thinking it over <message>Polished.</message>" }
        c.makeVersion(.polish, of: failed)
        try await waitUntil { rig.h.history.entries.first?.status == .success }
        let entry = try #require(rig.h.history.entries.first)
        #expect(entry.text == "Polished.")
        #expect(entry.versions.map(\.kind) == [.polish])
    }

    /// In hands-free, fn ↩'s fn press was for polishing: its release doesn't finish the dictation.
    @Test func inHandsFreeThePolishKeyKeepsRecording() {
        let (rig, _) = Switch.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .gemini
        c.send(.handsFreeToggle)
        c.handle(.pttDown)
        c.handle(.polish)
        c.handle(.pttUp)
        #expect(c.machine.capture.isListeningOrLocked)
        #expect(c.isPolishing)
        c.send(.pillCancel)
    }
}

@MainActor
@Suite(.serialized) struct PolishSelectionTests {
    typealias Switch = SwitchModelControllerTests

    /// A rig whose dictations find `selection` selected, and whose model answers `answer` (or fails with `error`).
    static func make(selection: String? = "short draft, um, of a message", answer: String = "- drafts\n<message>Polished.</message>",
                     error: AppError? = nil) -> (SwitchModelControllerTests.Rig, SwitchModelControllerTests.Cues, Asked) {
        let (rig, cues) = Switch.make()
        let asked = Asked()
        rig.h.controller.start()
        rig.h.controller.playCueOverride = { cues.played.append($0) }
        rig.h.controller.selectionOverride = { selection }
        rig.h.controller.selectionPolishOverride = { text, model in
            asked.calls.append((text, model))
            if let error { throw error }
            return TranscriptResult(text: answer, engine: .geminiFlash, processingTime: 0.4)
        }
        return (rig, cues, asked)
    }

    final class Asked { var calls: [(String, PolishSelectionModel)] = [] }

    /// Holding the key with text selected, off Gemini: "↩ Polish selection" over the pill, a light "hm?", and the
    /// polish key goes to the router.
    @Test func aSelectionShowsTheHintOffGemini() async throws {
        let (rig, cues, _) = Self.make()
        Switch.hold(rig)
        try await waitUntil { rig.h.pill.selectionHint == .shown }
        #expect(rig.h.hotkeys.selectionReady && rig.h.hotkeys.currentConfig().polishes)
        #expect(cues.played.contains(.polishHint))
        rig.h.controller.send(.pillCancel)
        #expect(rig.h.pill.selectionHint == .hidden && !rig.h.hotkeys.selectionReady)
    }

    /// On Gemini the key is Polish's: no hint, and fn ↩ polishes the dictation, the selection left alone.
    @Test func onGeminiTheKeyStaysPolishs() async throws {
        let (rig, cues, asked) = Self.make()
        rig.h.settings.lineup.main = .gemini
        Switch.hold(rig)
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.h.pill.selectionHint == .hidden && !cues.played.contains(.polishHint))
        rig.h.controller.handle(.polish)
        #expect(rig.h.controller.isPolishing && asked.calls.isEmpty)
        rig.h.controller.send(.pillCancel)
    }

    /// The polish key over the hint: the dictation goes without a trace, the pill becomes the polish, and the message
    /// comes up on the card, in History too.
    @Test func thePolishKeyPolishesTheSelection() async throws {
        let (rig, cues, asked) = Self.make()
        let c = rig.h.controller
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        Switch.hold(rig)
        rig.now += 2
        try await waitUntil { rig.h.pill.selectionHint == .shown }
        c.handle(.polish)
        #expect(c.machine.capture == .idle)
        #expect(rig.h.pill.selectionHint == .handoff)
        #expect(rig.notice("dictation.canceled") == nil, "no Undo: the recording is gone")
        #expect(cues.played.suffix(1) == [.cancel])
        try await waitUntil { rig.notice(DictationController.selectionCardKey) != nil }
        #expect(asked.calls.count == 1 && asked.calls.first?.0 == "short draft, um, of a message")
        #expect(asked.calls.first?.1 == .geminiFlash)
        let card = try #require(rig.notice(DictationController.selectionCardKey))
        #expect(card.transcript == "Polished." && card.title == "Polished")
        #expect(card.actions.map(\.title) == ["Paste Here", "Copy"])
        // The drop follows the cancel cue 110 ms later (here the answer came quicker than any model's).
        try await waitUntil { cues.played.contains(.polishOn) }
        #expect(cues.played.contains(.polishReady))
        #expect(rig.h.hotkeys.cardKeys, "↩ and Esc are the card's while it's up")
        let entry = try #require(rig.h.history.entries.first)
        #expect(entry.isSelection && entry.text == "Polished." && entry.audioFileName == nil)
        #expect(rig.transcribed.isEmpty, "the recording was never transcribed")
        #expect(rig.pasted.isEmpty)
        // Esc closes the card and hands the keys back.
        c.handle(.cardClose)
        #expect(rig.notice(DictationController.selectionCardKey) == nil && !rig.h.hotkeys.cardKeys)
    }

    /// ↩ with the card up pastes it (over the selection still selected in the app).
    @Test func returnPastesTheCard() async throws {
        let (rig, _, _) = Self.make()
        var pastedHere: [String] = []
        rig.h.controller.pasteNowOverride = { pastedHere.append($0); return .pasted }
        Switch.hold(rig)
        try await waitUntil { rig.h.pill.selectionHint == .shown }
        rig.h.controller.handle(.polish)
        try await waitUntil { rig.notice(DictationController.selectionCardKey) != nil }
        rig.h.controller.handle(.cardPaste)
        try await waitUntil { pastedHere == ["Polished."] }
        #expect(rig.notice(DictationController.selectionCardKey) == nil)
    }

    /// While it's being written the pill is the polish in its model's color; GPT-6 Luna when picked in Models.
    @Test func lunaPolishesWhenPicked() async throws {
        let (rig, _, asked) = Self.make()
        rig.h.settings.polishSelectionModel = .gpt6Luna
        var release: CheckedContinuation<Void, Never>?
        rig.h.controller.selectionPolishOverride = { text, model in
            asked.calls.append((text, model))
            await withCheckedContinuation { release = $0 }
            return TranscriptResult(text: "<message>Short.</message>", engine: .geminiFlash, processingTime: 0.2)
        }
        Switch.hold(rig)
        try await waitUntil { rig.h.pill.selectionHint == .shown }
        rig.h.controller.handle(.polish)
        try await waitUntil { release != nil }
        #expect(rig.h.pill.phase == .processing && rig.h.pill.polishes)
        #expect(rig.h.pill.sessionModel == .cleanup, "Luna wears clean-up's color")
        release?.resume()
        try await waitUntil { rig.notice(DictationController.selectionCardKey) != nil }
        #expect(asked.calls.first?.1 == .gpt6Luna)
        let entry = try #require(rig.h.history.entries.first)
        #expect(entry.currentKind == .selection(.gpt6Luna))
    }

    /// A failure says why, on its own notice, and the pill shakes.
    @Test func aFailedPolishSaysWhy() async throws {
        let (rig, _, _) = Self.make(error: .timeout(.geminiFlash))
        let shakes = rig.h.pill.shakeCount
        Switch.hold(rig)
        try await waitUntil { rig.h.pill.selectionHint == .shown }
        rig.h.controller.handle(.polish)
        try await waitUntil { rig.notice("polish.selection.failed") != nil }
        #expect(rig.notice("polish.selection.failed")?.body == "It took too long.")
        #expect(rig.h.pill.shakeCount > shakes)
        #expect(rig.h.history.entries.isEmpty)
    }

    /// Nothing selected: no hint, and off Gemini the key does nothing.
    @Test func withoutASelectionNothingHappens() async throws {
        let (rig, cues, asked) = Self.make(selection: nil)
        Switch.hold(rig)
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.h.pill.selectionHint == .hidden && !rig.h.hotkeys.selectionReady)
        rig.h.controller.handle(.polish)
        #expect(asked.calls.isEmpty && !cues.played.contains(.polishHint))
        #expect(rig.h.controller.machine.capture.isListeningOrLocked)
        rig.h.controller.send(.pillCancel)
    }

    /// The card stays 6 s and a second for every 20 words (lifetimes are nominal: the countdown runs at double speed).
    @Test func theCardStaysLongerForLongerText() {
        let short = DictationController.selectionCard("One two three.")
        let long = DictationController.selectionCard(Array(repeating: "word", count: 100).joined(separator: " "))
        #expect(short.lifetime == .seconds((6 + 3.0 / 20) * ToastCountdown.speed))
        #expect(long.lifetime == .seconds(11 * ToastCountdown.speed))
    }

    /// A selection's polish reads back from History, stays out of the dictation stats and offers no other version.
    @Test func aSelectionEntryIsItsOwnKind() throws {
        #expect(TranscriptVersionKind(rawValue: "selection:geminiFlash") == .selection(.geminiFlash))
        #expect(TranscriptVersionKind.selection(.gpt6Luna).rawValue == "selection:gpt6Luna")
        #expect(TranscriptVersionKind(rawValue: "selection:nope") == nil)
        #expect(!TranscriptVersionKind.selection(.geminiFlash).isReadableByOlderBuilds)
        let version = TranscriptResult(text: "Polished.", engine: .geminiFlash, processingTime: 1)
            .version(.selection(.geminiFlash))
        let entry = TranscriptEntry(engine: .geminiFlash, audioDuration: 0, voicedSeconds: 0, versions: [version])
        let data = try JSONEncoder().encode([entry])
        let back = try JSONDecoder().decode([TranscriptEntry].self, from: data)
        #expect(back.first?.isSelection == true && back.first?.text == "Polished.")
        let stats = HistoryStats.compute([entry], now: Date(), calendar: .current)
        #expect(stats.wordsThisWeek == 0 && stats.totalDictations == 0)
        let menu = VersionsMenu.make(for: entry, running: nil) { _ in .ready }
        #expect(menu.actions.isEmpty)
    }
}

@Suite struct PolishTests {
    @Test func theMessageIsWhatTheLastTagsHold() {
        #expect(Polish.message(from: "<message>Hi.</message>") == "Hi.")
        #expect(Polish.message(from: "draft <message>a</message> better <message>b</message>") == "b")
        #expect(Polish.message(from: "No tags.") == "No tags.")
    }

    @Test func thePromptAsksForTheMessageTags() {
        #expect(Polish.prompt.contains(Polish.open) && Polish.prompt.contains(Polish.close))
    }

    @Test func thePolishedVersionRoundTrips() {
        #expect(TranscriptVersionKind(rawValue: "polish") == .polish)
        #expect(TranscriptVersionKind.polish.rawValue == "polish")
        #expect(!TranscriptVersionKind.polish.isReadableByOlderBuilds)
        #expect(TranscriptVersionKind.polish.displayName == "Polished by Gemini 3.8 Flash")
    }
}
