import Foundation
import Testing
@testable import TranscribeThing

// MARK: - A dictation's text that comes once the next one has started goes on a card, not into the new one

@MainActor
@Suite(.serialized) struct EarlierDictationTests {
    typealias Rig = DictationResumeTests.Rig
    typealias Switch = SwitchModelControllerTests
    /// Holds a transcription until opened.
    typealias Gate = PolishSelectionTests.Lookup

    /// A rig wired as the app is (cards' sounds and keys), whose cues are counted.
    static func make() -> (Rig, Switch.Cues) {
        let (rig, cues) = Switch.make()
        rig.h.controller.start()
        return (rig, cues)
    }

    /// A push-to-talk dictation of two seconds of speech, let go: its text is on its way.
    static func dictate(_ rig: Rig) {
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        Switch.hold(rig)
        rig.now += 2
        rig.h.controller.handle(.pttUp)
    }

    /// The next dictation started, then Esc: too short to keep, so no "Dictation canceled" notice joins the cards.
    static func startThenCancel(_ rig: Rig) {
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 0.5)
        Switch.hold(rig)
        rig.now += 0.5
        rig.h.controller.handle(.cancel)
    }

    static func cards(_ rig: Rig) -> [Notice] {
        rig.h.toasts.notices.filter { $0.dedupeKey.hasPrefix(DictationController.earlierCardPrefix) }
    }

    /// The first dictation's text comes while the second is recording: History has it, a card shows it, and nothing is
    /// pasted into the dictation going on. The card comes up without a sound, and its countdown waits for the
    /// recording; once that's over, the second dictation's own text is pasted and the card's countdown starts.
    @Test func aTranscriptThatComesDuringTheNextRecordingGoesOnACard() async throws {
        let (rig, cues) = Self.make()
        let gate = Gate()
        var calls = 0
        rig.result = { _, _ in
            calls += 1
            if calls == 1 {
                await gate.wait()
                return "first words"
            }
            return "second words"
        }
        Self.dictate(rig)
        try await waitUntil { calls == 1 }
        Switch.hold(rig)
        gate.isOpen = true
        try await waitUntil { Self.cards(rig).count == 1 }

        let card = try #require(Self.cards(rig).first)
        #expect(rig.pasted.isEmpty, "never pasted into the dictation going on")
        #expect(card.transcript == "first words")
        #expect(card.title == "Earlier dictation, by Parakeet v3")
        #expect(card.actions.map(\.title) == ["Paste Here", "Copy"])
        let entry = try #require(rig.h.history.entries.first)
        #expect(entry.status == .success && entry.text == "first words", "History has it as always")
        #expect(!cues.played.contains(.polishReady), "no sound into the recording")
        #expect(rig.h.toasts.countdowns[card.id]?.isRunning == false, "it waits while the user dictates")
        #expect(rig.h.hotkeys.cardClose)
        #expect(!rig.h.toasts.cardKeys.returnPastes, "↩ isn’t the card’s while a dictation records")

        try await Switch.release(rig)
        #expect(rig.pasted == ["second words"], "the dictation that was going on pastes as always")
        #expect(rig.h.toasts.countdowns[card.id]?.isRunning == true, "its countdown starts once it’s over")
        #expect(Self.cards(rig).count == 1)
        #expect(rig.h.toasts.cardKeys.returnPastes && rig.h.hotkeys.cardPaste)
        #expect(!cues.played.contains(.polishReady))
    }

    /// The rule is that a new recording started: one canceled before the text came still sends it to a card. Nothing
    /// records when it comes, so the card has its sound, and its countdown runs.
    @Test func oneWhoseNextRecordingWasCanceledStillGoesOnACard() async throws {
        let (rig, cues) = Self.make()
        let c = rig.h.controller
        let gate = Gate()
        rig.result = { _, _ in
            await gate.wait()
            return "first words"
        }
        Self.dictate(rig)
        try await waitUntil { rig.transcribed.count == 1 }
        Self.startThenCancel(rig)
        #expect(!c.machine.isRecording)
        gate.isOpen = true
        try await waitUntil { Self.cards(rig).count == 1 && c.machine.activeJobs == 0 }

        let card = try #require(Self.cards(rig).first)
        #expect(rig.pasted.isEmpty)
        #expect(card.transcript == "first words")
        #expect(cues.played.last == .polishReady, "nothing records: it comes up with its sound")
        #expect(rig.h.toasts.countdowns[card.id]?.isRunning == true)
    }

    /// A hold that turns out to be a shortcut isn't a dictation: fn ← after holding fn a moment or a while, or fn let go
    /// as a tap just past the confirm delay. The text on its way is pasted as before once it comes.
    @Test func aHoldThatWasAShortcutLeavesTheTextToBePasted() async throws {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        let gate = Gate()
        rig.result = { _, _ in
            await gate.wait()
            return "first words"
        }
        Self.dictate(rig)
        try await waitUntil { rig.transcribed.count == 1 }
        for seconds in [0.5, 2] {
            rig.h.recorder.next = DictationResumeTests.speech(seconds: seconds)
            Switch.hold(rig)
            rig.now += seconds
            c.handle(.pttInterrupted)
            #expect(!c.machine.isRecording)
        }
        Switch.hold(rig)
        rig.now += 0.2
        c.handle(.pttUp)
        #expect(!c.machine.isRecording && rig.transcribed.count == 1, "a tap: nothing to transcribe")
        gate.isOpen = true
        try await waitUntil { rig.pasted == ["first words"] && c.machine.activeJobs == 0 }
        #expect(Self.cards(rig).isEmpty)
    }

    /// fn P over a selection takes the hold over for Polish Selection: no dictation, so the text on its way is pasted
    /// as before, and the polish comes up on its own card.
    @Test func polishSelectionLeavesTheTextToBePasted() async throws {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        c.selectionOverride = { "short draft" }
        c.selectionPolishOverride = { _, _, _ in
            TranscriptResult(text: "<message>Polished.</message>", engine: .geminiFlash, processingTime: 0.1)
        }
        let gate = Gate()
        rig.result = { _, _ in
            await gate.wait()
            return "first words"
        }
        Self.dictate(rig)
        try await waitUntil { rig.transcribed.count == 1 }
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 0.5)
        Switch.hold(rig)
        c.handle(.polish)
        try await waitUntil { rig.notice(DictationController.selectionCardKey(.geminiFlash)) != nil }
        #expect(!c.machine.isRecording)
        gate.isOpen = true
        try await waitUntil { rig.pasted == ["first words"] && c.machine.activeJobs == 0 }
        #expect(Self.cards(rig).isEmpty)
    }

    /// fn D over a selection likewise: the word goes into the dictionary, and the text on its way is pasted.
    @Test func addingToTheDictionaryLeavesTheTextToBePasted() async throws {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        c.selectionOverride = { "Wispr Flow" }
        let gate = Gate()
        rig.result = { _, _ in
            await gate.wait()
            return "first words"
        }
        Self.dictate(rig)
        try await waitUntil { rig.transcribed.count == 1 }
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 0.5)
        Switch.hold(rig)
        c.handle(.heldForSelection(.addToDictionary, AddToDictionaryTests.d))
        try await waitUntil { rig.h.settings.dictionary.words == ["Wispr Flow"] }
        #expect(!c.machine.isRecording)
        gate.isOpen = true
        try await waitUntil { rig.pasted == ["first words"] && c.machine.activeJobs == 0 }
        #expect(Self.cards(rig).isEmpty)
    }

    /// No new recording: the text is pasted as it always was. A quick fn tap meanwhile isn't a recording: it never
    /// commits.
    @Test func withNoNewRecordingTheTextIsPastedAsBefore() async throws {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        let gate = Gate()
        rig.result = { _, _ in
            await gate.wait()
            return "first words"
        }
        Self.dictate(rig)
        try await waitUntil { rig.transcribed.count == 1 }
        c.handle(.pttDown)
        rig.now += 0.05
        c.handle(.pttUp)
        #expect(!c.machine.isRecording)
        gate.isOpen = true
        try await waitUntil { rig.pasted == ["first words"] && c.machine.activeJobs == 0 }
        #expect(Self.cards(rig).isEmpty)
    }

    /// Two earlier texts give two cards, each with its own: a third recording (canceled) held both back. ↩ can't
    /// tell which to paste and does nothing; Esc closes both.
    @Test func twoEarlierDictationsGiveTwoCards() async throws {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        let gate = Gate()
        var calls = 0
        rig.result = { _, _ in
            calls += 1
            let text = calls == 1 ? "first words" : "second words"
            await gate.wait()
            return text
        }
        var pastedHere: [String] = []
        c.pasteNowOverride = { pastedHere.append($0); return .pasted }
        Self.dictate(rig)
        try await waitUntil { calls == 1 }
        Self.dictate(rig)
        try await waitUntil { calls == 2 }
        Self.startThenCancel(rig)
        gate.isOpen = true
        try await waitUntil { Self.cards(rig).count == 2 && c.machine.activeJobs == 0 }

        #expect(Self.cards(rig).map(\.transcript) == ["first words", "second words"])
        #expect(rig.pasted.isEmpty)
        #expect(!rig.h.toasts.cardKeys.returnPastes)
        c.handle(.cardPaste)
        try await Task.sleep(for: .milliseconds(50))
        #expect(pastedHere.isEmpty && Self.cards(rig).count == 2, "two cards: ↩ can’t tell which")
        c.handle(.cardClose)
        #expect(Self.cards(rig).isEmpty)
        #expect(!rig.h.hotkeys.cardPaste && !rig.h.hotkeys.cardClose)
    }

    /// The card's Paste Here follows General → Pasting's rules for the model that wrote it and how it was dictated
    /// (hands-free here: no period, no space). ↩ does it too, once nothing records.
    @Test func pasteHereFollowsThePastingRules() async throws {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        rig.h.settings.modelsAddingSpace = [.parakeet]
        rig.h.settings.modesAddingSpace = [.pushToTalk]
        rig.h.settings.modelsRemovingFinalPeriod = [.parakeet]
        rig.h.settings.modesRemovingFinalPeriod = [.handsFree]
        let gate = Gate()
        rig.result = { _, _ in
            await gate.wait()
            return "Hello."
        }
        var pastedHere: [String] = []
        c.pasteNowOverride = { pastedHere.append($0); return .pasted }
        c.send(.handsFreeToggle)
        rig.now += 2
        c.send(.pillStop)
        try await waitUntil { rig.transcribed.count == 1 }
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 0.5)
        Switch.hold(rig)
        gate.isOpen = true
        try await waitUntil { Self.cards(rig).count == 1 }

        let card = try #require(Self.cards(rig).first)
        #expect(card.actions.first?.kind == .pasteText("Hello.", by: .parakeet, in: .handsFree))
        c.handle(.cardPaste)
        try await Task.sleep(for: .milliseconds(50))
        #expect(pastedHere.isEmpty, "not while the next dictation records")

        rig.now += 0.5
        c.handle(.cancel)
        c.handle(.cardPaste)
        try await waitUntil { !pastedHere.isEmpty }
        #expect(pastedHere == ["Hello"])
        #expect(Self.cards(rig).isEmpty)
        #expect(rig.pasted.isEmpty)
    }

    /// Copy takes the text elsewhere: the card goes and ↩ goes back to the app.
    @Test func copyingGivesReturnBack() async throws {
        let (rig, cues) = Self.make()
        let c = rig.h.controller
        let gate = Gate()
        rig.result = { _, _ in
            await gate.wait()
            return "first words"
        }
        var copied: [String] = []
        c.copyOverride = { copied.append($0) }
        Self.dictate(rig)
        try await waitUntil { rig.transcribed.count == 1 }
        Self.startThenCancel(rig)
        gate.isOpen = true
        try await waitUntil { Self.cards(rig).count == 1 }
        #expect(rig.h.hotkeys.cardPaste)

        try rig.click(.copyText("first words"), in: try #require(Self.cards(rig).first).dedupeKey)
        #expect(copied == ["first words"])
        #expect(cues.played.last == .paste)
        // Copied, the card goes, and ↩ is the app's again.
        #expect(Self.cards(rig).isEmpty)
        #expect(!rig.h.hotkeys.cardPaste)
        #expect(!rig.h.toasts.cardKeys.returnPastes)
    }

    /// The title says it's the earlier dictation and who wrote it, polished or translated; it stays as long as Polish
    /// Selection's card, waits for a dictation recording, and comes up quietly during one. Each dictation has its own.
    @Test func theCardSaysWhoWroteIt() {
        typealias C = DictationController
        #expect(C.earlierDictationTitle(.transcription(.parakeet)) == "Earlier dictation, by Parakeet v3")
        #expect(C.earlierDictationTitle(.transcription(.geminiFlash)) == "Earlier dictation, by Gemini 3.8 Flash")
        #expect(C.earlierDictationTitle(.polish()) == "Earlier dictation, polished by Gemini 3.8 Flash")
        #expect(C.earlierDictationTitle(.translation(polished: false)) == "Earlier dictation, translated by Gemini 3.8 Flash")
        #expect(C.earlierDictationTitle(.translation(polished: true))
                == "Earlier dictation, polished and translated by Gemini 3.8 Flash")
        let card = C.earlierDictationCard("One two three.", kind: .polish(), mode: .handsFree, id: UUID(), quiet: false)
        #expect(card.takesCardKeys && card.waitsForDictation && card.sound == .polishReady)
        #expect(card.lifetime == C.selectionCard("One two three.", by: .geminiFlash).lifetime)
        #expect(card.actions.first?.kind == .pasteText("One two three.", by: .gemini, in: .handsFree))
        let quiet = C.earlierDictationCard("One.", kind: .transcription(.parakeet), mode: .pushToTalk, id: UUID(),
                                           quiet: true)
        #expect(quiet.sound == nil)
        #expect(quiet.dedupeKey != card.dedupeKey)
        #expect(C.selectionModel(ofCard: card) == nil, "not Polish Selection’s")
        // Polish Selection's card waits for a dictation the same way, and comes up quietly during one.
        #expect(C.selectionCard("Hi.", by: .geminiFlash).waitsForDictation)
        #expect(C.selectionCard("Hi.", by: .geminiFlash).sound == .polishReady)
        #expect(C.selectionCard("Hi.", by: .geminiFlash, quiet: true).sound == nil)
    }
}
