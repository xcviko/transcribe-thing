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

    /// A rig whose dictations find `selection` selected, and whose models answer from `answers` (or fail with
    /// `errors`), after `gate` lets them when it's set.
    static func make(selection: String? = "short draft, um, of a message",
                     answers: [PolishSelectionModel: String] = [.geminiFlash: "- drafts\n<message>Gemini's.</message>",
                                                                .gpt6Luna: "<message>Luna's.</message>"],
                     errors: [PolishSelectionModel: AppError] = [:]) -> (SwitchModelControllerTests.Rig, SwitchModelControllerTests.Cues, Asked) {
        let (rig, cues) = Switch.make()
        let asked = Asked()
        rig.h.controller.start()
        rig.h.controller.playCueOverride = { cues.played.append($0) }
        rig.h.controller.selectionOverride = { selection }
        rig.h.controller.selectionPolishOverride = { text, model in
            asked.calls.append((text, model))
            if let wait = asked.gates[model] { await wait() }
            if let error = errors[model] { throw error }
            return TranscriptResult(text: answers[model] ?? "", engine: .geminiFlash, processingTime: 0.4)
        }
        return (rig, cues, asked)
    }

    final class Asked {
        var calls: [(String, PolishSelectionModel)] = []
        /// A model whose answer waits until `release(model)`.
        var gates: [PolishSelectionModel: @MainActor () async -> Void] = [:]
        private var continuations: [PolishSelectionModel: CheckedContinuation<Void, Never>] = [:]

        @MainActor func hold(_ model: PolishSelectionModel) {
            gates[model] = { [weak self] in await withCheckedContinuation { self?.continuations[model] = $0 } }
        }

        @MainActor func release(_ model: PolishSelectionModel) {
            continuations.removeValue(forKey: model)?.resume()
        }

        var models: Set<PolishSelectionModel> { Set(calls.map(\.1)) }
    }

    static func card(_ rig: SwitchModelControllerTests.Rig, _ model: PolishSelectionModel) -> Notice? {
        rig.notice(DictationController.selectionCardKey(model))
    }

    /// Holds the key over a selection and presses the polish key once its hint is up.
    static func polish(_ rig: SwitchModelControllerTests.Rig) async throws {
        Switch.hold(rig)
        try await waitUntil { rig.h.pill.selectionHint == .shown }
        rig.h.controller.handle(.polish)
    }

    /// Holding the key with text selected, off Gemini: "fn ↩ Polish selection" over the pill, quietly, and the
    /// polish key goes to the router.
    @Test func aSelectionShowsTheHintOffGemini() async throws {
        let (rig, cues, _) = Self.make()
        Switch.hold(rig)
        try await waitUntil { rig.h.pill.selectionHint == .shown }
        #expect(rig.h.hotkeys.selectionReady && rig.h.hotkeys.currentConfig().polishes)
        #expect(cues.played.allSatisfy { $0 != .polishOn && $0 != .modelSwitch }, "the hint makes no sound")
        rig.h.controller.send(.pillCancel)
        #expect(rig.h.pill.selectionHint == .hidden && !rig.h.hotkeys.selectionReady)
    }

    /// The hint stays as long as the model chip does; the key still polishes the selection after it's gone.
    @Test func theHintGoesButTheKeyStays() async throws {
        let (rig, _, asked) = Self.make()
        rig.h.pill.timing.chipHold = 0.05
        Switch.hold(rig)
        try await waitUntil { rig.h.pill.selectionHint == .shown }
        try await waitUntil { rig.h.pill.selectionHint == .hidden }
        #expect(rig.h.hotkeys.selectionReady)
        rig.h.controller.handle(.polish)
        try await waitUntil { asked.calls.count == 2 }
    }

    /// On Gemini the key is Polish's: no hint, and fn ↩ polishes the dictation, the selection left alone.
    @Test func onGeminiTheKeyStaysPolishs() async throws {
        let (rig, _, asked) = Self.make()
        rig.h.settings.lineup.main = .gemini
        Switch.hold(rig)
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.h.pill.selectionHint == .hidden)
        rig.h.controller.handle(.polish)
        #expect(rig.h.controller.isPolishing && asked.calls.isEmpty)
        rig.h.controller.send(.pillCancel)
    }

    /// The polish key over the hint: the dictation goes without a trace, the pill becomes the polish, and both
    /// models' messages come up on their own cards, kept together in History. Esc closes both.
    @Test func bothModelsAnswerOnTheirOwnCards() async throws {
        let (rig, cues, asked) = Self.make()
        let c = rig.h.controller
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        rig.now += 2
        try await Self.polish(rig)
        #expect(c.machine.capture == .idle)
        #expect(rig.h.pill.selectionHint == .handoff)
        #expect(rig.notice("dictation.canceled") == nil, "no Undo: the recording is gone")
        #expect(cues.played.suffix(1) == [.cancel])
        try await waitUntil { Self.card(rig, .geminiFlash) != nil && Self.card(rig, .gpt6Luna) != nil }
        #expect(asked.models == [.geminiFlash, .gpt6Luna])
        #expect(asked.calls.allSatisfy { $0.0 == "short draft, um, of a message" })
        #expect(Self.card(rig, .geminiFlash)?.transcript == "Gemini's.")
        #expect(Self.card(rig, .gpt6Luna)?.transcript == "Luna's.")
        #expect(Self.card(rig, .geminiFlash)?.title == "Polished by Gemini 3.8 Flash")
        #expect(Self.card(rig, .gpt6Luna)?.actions.map(\.title) == ["Paste Here", "Copy"])
        try await waitUntil { cues.played.contains(.polishOn) }
        #expect(cues.played.filter { $0 == .polishReady }.count == 2)
        #expect(!rig.h.hotkeys.cardPaste && rig.h.hotkeys.cardClose, "↩ can't tell which of two to paste")
        let entry = try #require(rig.h.history.entries.first)
        #expect(rig.h.history.entries.count == 1 && entry.isSelection && entry.audioFileName == nil)
        #expect(Set(entry.versions.map(\.kind)) == [.selection(.geminiFlash), .selection(.gpt6Luna)])
        #expect(rig.transcribed.isEmpty && rig.pasted.isEmpty)
        c.handle(.cardClose)
        #expect(Self.card(rig, .geminiFlash) == nil && Self.card(rig, .gpt6Luna) == nil)
        #expect(!rig.h.hotkeys.cardPaste && !rig.h.hotkeys.cardClose)
    }

    /// The quick model's card comes first, alone, so ↩ pastes it: that's the pick. The other model is stopped and its
    /// card never comes; History shows the pasted one.
    @Test func pastingOneAnswerSettlesTheOther() async throws {
        let (rig, _, asked) = Self.make()
        var pastedHere: [String] = []
        rig.h.controller.pasteNowOverride = { pastedHere.append($0); return .pasted }
        asked.hold(.geminiFlash)
        try await Self.polish(rig)
        try await waitUntil { Self.card(rig, .gpt6Luna) != nil }
        #expect(rig.h.hotkeys.cardPaste, "one card: ↩ pastes it")
        #expect(rig.h.pill.phase == .processing, "Gemini still writes")
        rig.h.controller.handle(.cardPaste)
        try await waitUntil { pastedHere == ["Luna's."] }
        asked.release(.geminiFlash)
        try await Task.sleep(for: .milliseconds(100))
        #expect(Self.card(rig, .geminiFlash) == nil)
        #expect(rig.h.history.entries.first?.currentKind == .selection(.gpt6Luna))
        #expect(rig.h.history.entries.first?.versions.count == 1)
    }

    /// Copy picks an answer too (History shows it) but leaves the other card to compare.
    @Test func copyPicksWithoutClosingTheOther() async throws {
        let (rig, cues, _) = Self.make()
        try await Self.polish(rig)
        try await waitUntil { Self.card(rig, .geminiFlash) != nil && Self.card(rig, .gpt6Luna) != nil }
        let gemini = try #require(Self.card(rig, .geminiFlash))
        let copy = try #require(gemini.actions.first { $0.title == "Copy" })
        rig.h.toasts.perform(copy, on: gemini)
        #expect(rig.h.history.entries.first?.currentKind == .selection(.geminiFlash))
        #expect(Self.card(rig, .gpt6Luna) != nil)
        #expect(cues.played.last == .paste)
    }

    /// One model failing says why on its own notice; the other's card still comes.
    @Test func oneFailingModelSaysWhy() async throws {
        let (rig, _, _) = Self.make(errors: [.geminiFlash: .timeout(.geminiFlash)])
        let shakes = rig.h.pill.shakeCount
        try await Self.polish(rig)
        try await waitUntil { rig.notice("polish.selection.failed.geminiFlash") != nil && Self.card(rig, .gpt6Luna) != nil }
        let notice = try #require(rig.notice("polish.selection.failed.geminiFlash"))
        #expect(notice.title == "Couldn’t polish with Gemini 3.8 Flash" && notice.body == "It took too long.")
        #expect(rig.h.pill.shakeCount > shakes)
        #expect(rig.h.history.entries.first?.versions.map(\.kind) == [.selection(.gpt6Luna)])
    }

    /// Nothing selected: no hint, and off Gemini the key does nothing.
    @Test func withoutASelectionNothingHappens() async throws {
        let (rig, cues, asked) = Self.make(selection: nil)
        Switch.hold(rig)
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.h.pill.selectionHint == .hidden && !rig.h.hotkeys.selectionReady)
        rig.h.controller.handle(.polish)
        #expect(asked.calls.isEmpty && !cues.played.contains(.polishOn))
        #expect(rig.h.controller.machine.capture.isListeningOrLocked)
        rig.h.controller.send(.pillCancel)
    }

    /// A card stays 6 s and a second for every 20 words (lifetimes are nominal: the countdown runs at double speed).
    @Test func theCardStaysLongerForLongerText() {
        let short = DictationController.selectionCard("One two three.", by: .gpt6Luna)
        let long = DictationController.selectionCard(Array(repeating: "word", count: 100).joined(separator: " "),
                                                     by: .geminiFlash)
        #expect(short.lifetime == .seconds((6 + 3.0 / 20) * ToastCountdown.speed))
        #expect(long.lifetime == .seconds(11 * ToastCountdown.speed))
        #expect(DictationController.selectionModel(ofCard: long) == .geminiFlash)
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
