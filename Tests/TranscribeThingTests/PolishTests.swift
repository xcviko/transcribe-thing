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

    /// On Parakeet the key does nothing at all; switching away from Gemini turns Polish off.
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
        c.selectModelForCurrentDictation(.parakeet)
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
        #expect(PillView(model: rig.h.pill).visual.polish == .dictation, "its audio is in: the wave, with the wand")
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
                     answers: [PolishSelectionModel: String] = [.geminiFlash: "- drafts\n<message>Gemini's.</message>"],
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

    /// Holds the key over a selection and presses the polish key; returns once the selection is read and the dictation
    /// has given way.
    static func polish(_ rig: SwitchModelControllerTests.Rig) async throws {
        Switch.hold(rig)
        try await waitUntil { rig.h.controller.machine.isRecording }
        rig.h.controller.handle(.polish)
        try await waitUntil { !rig.h.controller.machine.isRecording }
    }

    /// On Gemini the key is Polish's: fn P polishes the dictation, the selection left alone.
    @Test func onGeminiTheKeyStaysPolishs() async throws {
        let (rig, _, asked) = Self.make()
        rig.h.settings.lineup.main = .gemini
        Switch.hold(rig)
        try await waitUntil { rig.h.controller.machine.isRecording }
        rig.h.controller.handle(.polish)
        #expect(rig.h.controller.isPolishing && asked.calls.isEmpty)
        rig.h.controller.send(.pillCancel)
    }

    /// The polish key over a selection: the dictation gives way (something was said in it, so it stays for Undo), the
    /// pill becomes the polish, and Gemini's message comes up on its card, kept in History. GPT-6 Luna is no longer
    /// asked. Esc closes the card.
    @Test func geminiAnswersOnACard() async throws {
        let (rig, cues, asked) = Self.make()
        let c = rig.h.controller
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        rig.now += 2
        try await Self.polish(rig)
        #expect(c.machine.capture == .idle)
        #expect(rig.notice("dictation.canceled") != nil, "2 s said: Undo brings the dictation back")
        #expect(Array(cues.played.prefix(2)) == [.start, .cancel], "the dictation gives way with the cancel cue")
        try await waitUntil { Self.card(rig, .geminiFlash) != nil }
        #expect(asked.calls.count == 1 && asked.models == [.geminiFlash])
        #expect(asked.calls.allSatisfy { $0.0 == "short draft, um, of a message" })
        #expect(Self.card(rig, .geminiFlash)?.transcript == "Gemini's.")
        #expect(Self.card(rig, .geminiFlash)?.title == "Polished by Gemini 3.8 Flash")
        #expect(Self.card(rig, .geminiFlash)?.actions.map(\.title) == ["Paste Here", "Copy"])
        try await waitUntil { cues.played.contains(.polishOn) }
        #expect(cues.played.filter { $0 == .polishReady }.count == 1)
        #expect(rig.h.hotkeys.cardPaste && rig.h.hotkeys.cardClose)
        #expect(rig.h.toasts.cardKeys.returnPastes, "the footer offers ↩ for the only card")
        let entry = try #require(rig.h.history.entries.first { $0.isSelection })
        #expect(entry.audioFileName == nil)
        #expect(entry.versions.map(\.kind) == [.selection(.geminiFlash)])
        #expect(rig.transcribed.isEmpty && rig.pasted.isEmpty)
        c.handle(.cardClose)
        #expect(Self.card(rig, .geminiFlash) == nil)
        #expect(!rig.h.hotkeys.cardPaste && !rig.h.hotkeys.cardClose)
    }

    /// ↩ pastes the card over the selection: that settles the polish, and History shows it.
    @Test func returnPastesTheAnswer() async throws {
        let (rig, _, _) = Self.make()
        var pastedHere: [String] = []
        rig.h.controller.pasteNowOverride = { pastedHere.append($0); return .pasted }
        // General → Pasting's rules are for dictations: the answer takes the selection's place as the model wrote it.
        rig.h.settings.modelsAddingSpace = Set(ModelChoice.allCases)
        rig.h.settings.modelsRemovingFinalPeriod = Set(ModelChoice.allCases)
        try await Self.polish(rig)
        try await waitUntil { Self.card(rig, .geminiFlash) != nil }
        #expect(rig.h.hotkeys.cardPaste, "one card: ↩ pastes it")
        rig.h.controller.handle(.cardPaste)
        try await waitUntil { pastedHere == ["Gemini's."] }
        #expect(Self.card(rig, .geminiFlash) == nil)
        #expect(rig.h.history.entries.first?.currentKind == .selection(.geminiFlash))
        #expect(rig.h.history.entries.first?.versions.count == 1)
    }

    /// Copy picks the answer too (History shows it) and leaves its card up.
    @Test func copyPicksTheAnswerAndKeepsItsCard() async throws {
        let (rig, cues, _) = Self.make()
        try await Self.polish(rig)
        try await waitUntil { Self.card(rig, .geminiFlash) != nil }
        let gemini = try #require(Self.card(rig, .geminiFlash))
        let copy = try #require(gemini.actions.first { $0.title == "Copy" })
        rig.h.toasts.perform(copy, on: gemini)
        #expect(rig.h.history.entries.first?.currentKind == .selection(.geminiFlash))
        #expect(Self.card(rig, .geminiFlash) != nil)
        #expect(cues.played.last == .paste)
    }

    /// A polish that fails says why on its own notice; nothing goes to History.
    @Test func aFailedPolishSaysWhy() async throws {
        let (rig, _, _) = Self.make(errors: [.geminiFlash: .timeout(.geminiFlash)])
        let shakes = rig.h.pill.shakeCount
        try await Self.polish(rig)
        try await waitUntil { rig.notice("polish.selection.failed.geminiFlash") != nil }
        let notice = try #require(rig.notice("polish.selection.failed.geminiFlash"))
        #expect(notice.title == "Couldn’t polish with Gemini 3.8 Flash" && notice.body == "It took too long.")
        #expect(rig.h.pill.shakeCount > shakes)
        #expect(Self.card(rig, .geminiFlash) == nil)
        #expect(!rig.h.history.entries.contains { $0.isSelection })
    }

    /// Nothing selected, off Gemini: the key says what Polish works on; the dictation goes on.
    @Test func withoutASelectionTheKeySaysPolishIsGeminis() async throws {
        let (rig, cues, asked) = Self.make(selection: nil)
        Switch.hold(rig)
        rig.h.controller.handle(.polish)
        try await waitUntil { rig.h.pill.keyHint != nil }
        #expect(asked.calls.isEmpty && !cues.played.contains(.polishOn))
        #expect(rig.h.pill.keyHint == "Polish works on Gemini, or on selected text")
        #expect(rig.h.controller.machine.capture.isListeningOrLocked)
        rig.h.controller.send(.pillCancel)
    }

    /// A card stays 6 s and a second for every 20 words (lifetimes are nominal: the countdown runs at double speed).
    @Test func theCardStaysLongerForLongerText() {
        let short = DictationController.selectionCard("One two three.", by: .geminiFlash)
        let long = DictationController.selectionCard(Array(repeating: "word", count: 100).joined(separator: " "),
                                                     by: .geminiFlash)
        #expect(short.lifetime == .seconds((6 + 3.0 / 20) * ToastCountdown.speed))
        #expect(long.lifetime == .seconds(11 * ToastCountdown.speed))
        #expect(DictationController.selectionModel(ofCard: long) == .geminiFlash)
    }

    /// A selection's polish reads back from History, stays out of the dictation stats and offers no other version.
    @Test func aSelectionEntryIsItsOwnKind() throws {
        #expect(TranscriptVersionKind(rawValue: "selection:geminiFlash") == .selection(.geminiFlash))
        #expect(TranscriptVersionKind(rawValue: "selection:gpt6Luna") == .selection(.gpt6Luna),
                "GPT-6 Luna is no longer asked, but its answers in History stay readable")
        #expect(PolishSelectionModel.asked == [.geminiFlash])
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

    /// Holds a selection lookup until opened.
    @MainActor final class Lookup {
        var isOpen = false
        func wait() async { while !isOpen { try? await Task.sleep(for: .milliseconds(5)) } }
    }

    /// A quick fn P, before the lookup has answered: it waits for the lookup, and once that finds text, it's Polish
    /// Selection.
    @Test func aQuickPolishKeyWaitsForTheLookup() async throws {
        let (rig, _, asked) = Self.make()
        let lookup = Lookup()
        rig.h.controller.selectionOverride = { await lookup.wait(); return "short draft" }
        rig.h.controller.handle(.pttDown)
        rig.h.controller.handle(.polish)
        try await Task.sleep(for: .milliseconds(40))
        #expect(asked.calls.isEmpty)
        lookup.isOpen = true
        try await waitUntil { asked.calls.count == 1 }
        #expect(asked.calls.allSatisfy { $0.0 == "short draft" })
    }

    /// fn let go before the lookup answered: the press is still decided by its key. With text selected it's Polish
    /// Selection all the same, and the release changes nothing; a second fn P meanwhile follows the first.
    @Test func lettingGoOfFnWaitsForTheKeysDecision() async throws {
        let (rig, cues, asked) = Self.make()
        let lookup = Lookup()
        rig.h.controller.selectionOverride = { await lookup.wait(); return "short draft" }
        rig.h.controller.handle(.pttDown)
        rig.h.controller.handle(.polish)
        rig.h.controller.handle(.polish)
        rig.now += 0.1
        rig.h.controller.handle(.pttUp)
        #expect(rig.h.controller.machine.isRecording, "the release waits for the key")
        lookup.isOpen = true
        try await waitUntil { asked.calls.count == 1 }
        #expect(rig.h.controller.machine.capture == .idle)
        #expect(rig.transcribed.isEmpty)
        #expect(cues.played.filter { $0 == .start }.count == 1, "fn's own cue at key-down, and no other")
        try await Task.sleep(for: .milliseconds(60))
        #expect(asked.calls.count == 1, "one Polish Selection, not one per key")
    }

    /// fn P reads what's selected when it's pressed: text selected after fn went down (the start found nothing) is
    /// polished all the same.
    @Test func textSelectedAfterFnWentDownIsPolished() async throws {
        let (rig, _, asked) = Self.make()
        var current: String?
        rig.h.controller.selectionOverride = { current }
        Switch.hold(rig)
        try await Task.sleep(for: .milliseconds(40))
        current = "selected later"
        rig.h.controller.handle(.polish)
        try await waitUntil { asked.calls.count == 1 }
        #expect(asked.calls.allSatisfy { $0.0 == "selected later" })
    }

    /// Where the app can't say what's selected (VS Code, Claude), fn P polishes what ⌘C copies.
    @Test func whereTheAppCantSayCopyingFindsTheSelection() async throws {
        let (rig, _, asked) = Self.make(selection: nil)
        rig.h.controller.selectionMissingOverride = .noFocusedElement
        rig.h.controller.selectionCopyOverride = { .text("copied draft") }
        Switch.hold(rig)
        rig.h.controller.handle(.polish)
        try await waitUntil { asked.calls.count == 1 }
        #expect(asked.calls.allSatisfy { $0.0 == "copied draft" })
    }

    /// Held down off Gemini, fn P's autorepeats do nothing more: one look at the selection, one word over the pill.
    @Test func holdingThePolishKeyOffGeminiLooksOnce() async throws {
        let (rig, _, asked) = Self.make(selection: nil)
        var looks = 0
        rig.h.controller.selectionOverride = { looks += 1; return nil }
        Switch.hold(rig)
        rig.h.controller.handle(.polish)
        try await waitUntil { rig.h.pill.keyHint != nil }
        for _ in 0..<5 { rig.h.controller.handle(.polishRepeat) }
        try await Task.sleep(for: .milliseconds(40))
        #expect(looks == 1 && asked.calls.isEmpty && rig.h.controller.machine.isRecording)
        rig.h.controller.send(.pillCancel)
    }

    /// With no pill on screen (Never), the word about the key comes as a short notice.
    @Test func withNoPillTheKeySaysSoInANotice() async throws {
        let (rig, _, _) = Self.make(selection: nil)
        rig.h.pill.isPresented = false
        Switch.hold(rig)
        rig.h.controller.handle(.polish)
        try await waitUntil { rig.notice("key.hint") != nil }
        #expect(rig.notice("key.hint")?.title == "Polish works on Gemini, or on selected text")
        rig.h.controller.send(.pillCancel)
    }

    /// A long dictation Polish Selection took over isn't lost: it's in History, to transcribe from there.
    @Test func aLongDictationPolishSelectionTookOverIsInHistory() async throws {
        let (rig, _, asked) = Self.make()
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 25)
        rig.h.controller.send(.handsFreeToggle)
        rig.now += 25
        rig.h.controller.handle(.polish)
        try await waitUntil { asked.calls.count == 1 }
        #expect(rig.h.history.entries.contains { $0.status == .cancelled })
        #expect(rig.transcribed.isEmpty)
    }

    /// Nothing selected after all: the key never goes to the app; it says Polish is Gemini's, and the dictation goes on.
    @Test func aQuickPolishKeyOverNothingSaysSo() async throws {
        let (rig, _, asked) = Self.make(selection: nil)
        let lookup = Lookup()
        rig.h.controller.selectionOverride = { await lookup.wait(); return nil }
        rig.h.controller.handle(.pttDown)
        rig.h.controller.handle(.polish)
        lookup.isOpen = true
        try await waitUntil { rig.h.pill.keyHint != nil }
        #expect(asked.calls.isEmpty && rig.h.controller.machine.isRecording)
        rig.h.controller.send(.pillCancel)
    }

    /// Without an OpenRouter key Polish Selection can't happen: the key says Polish is Gemini's, and nothing is looked
    /// up.
    @Test func withoutAKeyThereIsNoPolishSelection() async throws {
        let (rig, _) = Switch.make(key: .missing)
        rig.h.controller.start()
        rig.h.settings.shortcuts[.addToDictionary] = nil
        var looked = false
        rig.h.controller.selectionOverride = { looked = true; return "text" }
        Switch.hold(rig)
        try await Task.sleep(for: .milliseconds(60))
        #expect(!looked)
        rig.h.controller.handle(.polish)
        #expect(rig.h.pill.keyHint == "Polish works on Gemini only")
        rig.h.controller.send(.pillCancel)
    }

    /// Copy picks an answer to paste elsewhere: ↩ goes back to the app (it would paste the card a second time), and
    /// the footer stops offering it. Esc still closes.
    @Test func copyingGivesReturnBack() async throws {
        let (rig, _, _) = Self.make()
        try await Self.polish(rig)
        try await waitUntil { Self.card(rig, .geminiFlash) != nil }
        #expect(rig.h.hotkeys.cardPaste && rig.h.toasts.cardKeys.returnPastes)
        let card = try #require(Self.card(rig, .geminiFlash))
        rig.h.controller.perform(try #require(card.actions.first { $0.title == "Copy" }), from: card)
        #expect(!rig.h.hotkeys.cardPaste && rig.h.hotkeys.cardClose)
        #expect(!rig.h.toasts.cardKeys.returnPastes)
        rig.h.controller.handle(.cardPaste)
        #expect(Self.card(rig, .geminiFlash) != nil && rig.pasted.isEmpty)
        rig.h.controller.handle(.cardClose)
    }

    /// Esc stops a polish still under way: the answer is dropped, the pill rests, with the cancel cue. While it runs
    /// it counts as the app's work (an update waits for it).
    @Test func escStopsAPolishUnderWay() async throws {
        let (rig, cues, asked) = Self.make()
        asked.hold(.geminiFlash)
        try await Self.polish(rig)
        try await waitUntil { asked.calls.count == 1 }
        #expect(rig.h.controller.activity == .polishing && rig.h.hotkeys.cardClose)
        #expect(PillView(model: rig.h.pill).visual == .processing(afterHandsFree: false, polish: .selection),
                "nothing heard: “Polishing”, with the wand")
        rig.h.controller.handle(.cardClose)
        #expect(rig.h.pill.phase == .rest && rig.h.controller.activity == .idle)
        #expect(cues.played.filter { $0 == .cancel }.count == 2, "the handoff's, then Esc's")
        asked.release(.geminiFlash)
        try await Task.sleep(for: .milliseconds(200))
        #expect(Self.card(rig, .geminiFlash) == nil)
        #expect(!cues.played.contains(.polishOn), "no Polish cue for a polish already stopped")
    }

    /// The pill counts Gemini's tokens while it writes, and nothing once it's done.
    @Test func theCountFollowsTheModelWhileItWrites() {
        let work = DictationController.SelectionPolish(estimates: [:])
        work.pending = [.geminiFlash]
        work.counts = [.geminiFlash: PillTokenCount(phase: .writing, tokens: 380)]
        #expect(work.count?.tokens == 380)
        work.pending.remove(.geminiFlash)
        #expect(work.count == nil)
    }

    /// Paste Last pastes the last dictation, never a polished selection (closing its card said no).
    @Test func pasteLastSkipsAPolishedSelection() throws {
        let version = TranscriptResult(text: "Polished.", engine: .geminiFlash, processingTime: 1)
            .version(.selection(.gpt6Luna))
        let store = HistoryStore.preview(entries: [
            TranscriptEntry(engine: .geminiFlash, audioDuration: 0, voicedSeconds: 0, versions: [version]),
            TranscriptEntry(createdAt: Date().addingTimeInterval(-60), text: "dictated", engine: .parakeet,
                            audioDuration: 1, voicedSeconds: 1),
        ])
        #expect(store.lastSuccessful?.text == "dictated")
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
