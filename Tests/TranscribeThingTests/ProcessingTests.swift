import Foundation
import Testing
@testable import TranscribeThing

// MARK: - A dictation being processed: no new one, its keys, Parakeet beside Gemini, and the talk key as Undo

/// Holds a request until opened. A cancelled request stops waiting, as Gemini's does.
@MainActor final class RequestGate {
    var isOpen = false
    private(set) var wasCancelled = false

    func wait() async throws {
        do {
            while !isOpen { try await Task.sleep(for: .milliseconds(5)) }
        } catch {
            wasCancelled = true
            throw error
        }
    }
}

/// Every request a dictation made, in order: its engine and prompt (nil: the plain transcript's).
@MainActor final class Requests {
    var made: [(engine: EngineID, prompt: String?)] = []
    var gemini: [String?] { made.filter { $0.engine.isGemini }.map(\.prompt) }
    var parakeet: Int { made.filter { $0.engine == .parakeet }.count }
}

@MainActor
enum ProcessingRig {
    typealias Rig = DictationResumeTests.Rig
    typealias Switch = SwitchModelControllerTests

    /// A rig dictating on Gemini, wired as the app is, whose requests are recorded and answered by `answer` (the
    /// request's engine, prompt and number, from 1). Each Gemini request names its generation "gen-<number>".
    static func make(parakeetBeside: Bool = false, models: [EngineID: LocalModelState] = [.parakeet: .ready],
                     answer: @escaping @MainActor (EngineID, String?, Int) async throws -> String)
        -> (Rig, Switch.Cues, Requests) {
        let (rig, cues) = Switch.make(models: models)
        let requests = Requests()
        rig.h.settings.lineup.main = .gemini
        rig.h.settings.showsParakeetWhileGemini = parakeetBeside
        rig.h.controller.processingKeySettleDelay = .milliseconds(30)
        rig.h.controller.start()
        rig.h.controller.requestOverride = { _, engine, prompt, named in
            requests.made.append((engine, prompt))
            let number = requests.made.count
            if engine.isGemini { named("gen-\(number)") }
            let text = try await answer(engine, prompt, number)
            return TranscriptResult(text: text, engine: engine, processingTime: 0.1,
                                    generationID: engine.isGemini ? "gen-\(number)" : nil)
        }
        return (rig, cues, requests)
    }

    /// A push-to-talk dictation of two seconds of speech, let go: its request goes.
    static func dictate(_ rig: Rig) {
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        Switch.hold(rig)
        rig.now += 2
        rig.h.controller.handle(.pttUp)
    }

    /// What Gemini answers: the message in tags for Polish (and Polish translated), as its prompt asks.
    static func gemini(_ prompt: String?, plain: String = "plain words") -> String {
        prompt == nil ? plain : "<message>Polished words.</message>"
    }
}

// MARK: No new dictation while one is processed

@MainActor
@Suite(.serialized) struct ProcessingBlocksDictationTests {
    typealias R = ProcessingRig
    typealias Switch = SwitchModelControllerTests

    /// From the stop until the text is pasted, the talk key, hands-free and a click on the pill do nothing: no sound,
    /// no pill change, no recording. Once it's pasted, the talk key records again.
    @Test func nothingStartsWhileADictationIsProcessed() async throws {
        let gate = RequestGate()
        let (rig, cues, requests) = R.make { _, prompt, _ in
            try await gate.wait()
            return R.gemini(prompt)
        }
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        let played = cues.played
        let starts = rig.h.recorder.starts
        #expect(c.machine.isProcessing && rig.h.pill.phase == .processing)
        #expect(rig.h.hotkeys.isProcessing && rig.h.hotkeys.processingTakesKeys)

        c.handle(.pttDown)
        c.send(.timer(.arming))
        rig.now += 1
        c.handle(.pttUp)
        c.handle(.handsFreeToggle)
        rig.h.pill.onClick?()
        #expect(!c.machine.isRecording && rig.h.recorder.starts == starts)
        #expect(cues.played == played, "no sound")
        #expect(rig.h.pill.phase == .processing)

        gate.isOpen = true
        try await waitUntil { rig.pasted.count == 1 && c.machine.activeJobs == 0 }
        #expect(!rig.h.hotkeys.isProcessing && !rig.h.hotkeys.processingTakesKeys)
        Switch.hold(rig)
        #expect(c.machine.isRecording, "pasted: the talk key records again")
        c.handle(.cancel)
    }

    /// Paste last isn't held off: it pastes the last transcript while the next one is processed.
    @Test func pasteLastStillWorks() async throws {
        let gate = RequestGate()
        let (rig, _, requests) = R.make { _, _, number in
            if number == 2 { try await gate.wait() }
            return number == 1 ? "first words" : "second words"
        }
        let c = rig.h.controller
        var pastedLast: [String] = []
        c.pasteLastOverride = { pastedLast.append($0); return .pasted }
        R.dictate(rig)
        try await waitUntil { rig.pasted.count == 1 && c.machine.activeJobs == 0 }
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 2 }
        c.handle(.pasteLast)
        try await waitUntil { pastedLast.count == 1 }
        #expect(pastedLast.first?.contains("first words") == true)
        gate.isOpen = true
        try await waitUntil { rig.pasted.count == 2 && c.machine.activeJobs == 0 }
    }

    /// Undo of an older cancel while a dictation is processed records nothing: the notice comes back saying to wait.
    @Test func undoWaitsForTheTextOnItsWay() async throws {
        let gate = RequestGate()
        let (rig, _, requests) = R.make { _, prompt, _ in
            try await gate.wait()
            return R.gemini(prompt)
        }
        let c = rig.h.controller
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        rig.holdThenEsc(2)
        #expect(rig.notice("dictation.canceled") != nil)
        // Hands-free (not the talk key, which would Undo now), stopped: it's processed.
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        c.send(.handsFreeToggle)
        rig.now += 2
        c.send(.pillStop)
        try await waitUntil { requests.gemini.count == 1 }
        try rig.click(.undoCancel, in: "dictation.canceled")
        #expect(!c.machine.isRecording)
        #expect(rig.notice("dictation.canceled")?.body == "Wait for the text on its way to be pasted, then Undo.")
        gate.isOpen = true
        try await waitUntil { rig.pasted.count == 1 && c.machine.activeJobs == 0 }
    }

    /// A failed dictation's Retry while another records would bring text with nowhere to go: the notice stays,
    /// saying to finish first, and nothing is sent.
    @Test func retryWaitsForTheRecordingToEnd() async throws {
        var fails = true
        let (rig, _, requests) = R.make { engine, prompt, _ in
            if fails { throw AppError.timeout(engine) }
            return R.gemini(prompt)
        }
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { rig.h.history.entries.first?.status == .failed && c.machine.activeJobs == 0 }
        let failure = try #require(rig.h.toasts.notices.first { $0.actions.contains { $0.kind == .retry } })
        fails = false
        c.send(.handsFreeToggle)
        rig.h.toasts.perform(try #require(failure.actions.first { $0.kind == .retry }), on: failure)
        #expect(requests.gemini.count == 1 && c.machine.isRecording)
        let again = try #require(rig.notice(failure.dedupeKey))
        #expect(again.body == "Finish this dictation first, then Retry." && again.sound == nil)
        c.handle(.cancel)
    }
}

// MARK: Polish, Translate and Send while a dictation is processed

@MainActor
@Suite(.serialized) struct ProcessingKeysTests {
    typealias R = ProcessingRig

    /// A Gemini dictation whose first request waits on `first`; later requests answer at once.
    static func make(first: RequestGate) -> (R.Rig, SwitchModelControllerTests.Cues, Requests) {
        R.make { _, prompt, number in
            if number == 1 { try await first.wait() }
            return R.gemini(prompt)
        }
    }

    /// fn P (fn's press starts nothing now): the wand and Polish's sound, as while recording; once the keys are let
    /// go the request in flight stops and the recording goes again with Polish's prompt. Polish's message is pasted.
    @Test func polishSendsItAgainPolished() async throws {
        let first = RequestGate()
        let (rig, cues, requests) = Self.make(first: first)
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        c.handle(.pttDown)
        c.handle(.polish)
        #expect(rig.h.pill.polishes && cues.played.last == .polishOn)
        c.handle(.shortcutKeyUp)
        try await Task.sleep(for: .milliseconds(120))
        #expect(requests.gemini.count == 1, "fn still held: nothing goes yet")
        c.handle(.pttUp)
        try await waitUntil { requests.gemini.count == 2 }
        #expect(requests.gemini[1] == Polish.prompt)
        try await waitUntil { rig.pasted.count == 1 && c.machine.activeJobs == 0 }
        #expect(first.wasCancelled, "the plain request stopped")
        #expect(rig.pasted.first?.contains("Polished words") == true)
        #expect(rig.h.history.entries.first?.currentKind == .polish(by: .geminiFlash))
        #expect(!c.machine.isRecording)
    }

    /// Held down, the key flips Polish at every autorepeat with its sound each time, and nothing goes until it's let
    /// go: then once, with where it landed.
    @Test func aHeldKeyGoesOnceWhenLetGo() async throws {
        let first = RequestGate()
        let (rig, cues, requests) = Self.make(first: first)
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        let before = cues.played.count
        c.handle(.polish)
        for _ in 0..<4 { c.handle(.polishRepeat) }
        #expect(Array(cues.played.dropFirst(before)) == [.polishOn, .polishOff, .polishOn, .polishOff, .polishOn])
        try await Task.sleep(for: .milliseconds(150))
        #expect(requests.gemini.count == 1, "still held")
        c.handle(.shortcutKeyUp)
        try await waitUntil { requests.gemini.count == 2 }
        #expect(requests.gemini[1] == Polish.prompt)
        try await waitUntil { c.machine.activeJobs == 0 }
        #expect(requests.gemini.count == 2, "one request for the whole hold")
    }

    /// Flipped back to what's already asked for, the request in flight goes on, and its answer is pasted.
    @Test func settlingBackKeepsTheRequest() async throws {
        let first = RequestGate()
        let (rig, _, requests) = Self.make(first: first)
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        c.handle(.polish)
        c.handle(.polishRepeat)
        c.handle(.shortcutKeyUp)
        try await Task.sleep(for: .milliseconds(120))
        #expect(requests.gemini.count == 1 && !first.wasCancelled)
        first.isOpen = true
        try await waitUntil { rig.pasted.count == 1 && c.machine.activeJobs == 0 }
        #expect(rig.pasted.first?.contains("plain words") == true)
        #expect(rig.h.history.entries.first?.currentKind == .transcription(.geminiFlash))
    }

    /// Gemini's answer that comes while the keys are still being pressed isn't pasted until they settle: back where
    /// it was, it's pasted then.
    @Test func anAnswerWaitsForTheKeys() async throws {
        let first = RequestGate()
        let (rig, _, requests) = Self.make(first: first)
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        c.handle(.pttDown)
        c.handle(.polish)
        first.isOpen = true
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.pasted.isEmpty, "not while the keys are down")
        c.handle(.polishRepeat)
        c.handle(.shortcutKeyUp)
        c.handle(.pttUp)
        try await waitUntil { rig.pasted.count == 1 && c.machine.activeJobs == 0 }
        #expect(requests.gemini.count == 1)
        #expect(rig.pasted.first?.contains("plain words") == true)
    }

    /// A release that never comes doesn't hold the dictation forever: past the wait limit it goes.
    @Test func aLostReleaseStillGoes() async throws {
        let first = RequestGate()
        let (rig, _, requests) = Self.make(first: first)
        let c = rig.h.controller
        c.heldKeyWaitLimit = 2
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        c.handle(.polish)
        try await Task.sleep(for: .milliseconds(120))
        #expect(requests.gemini.count == 1)
        rig.now += 3
        try await waitUntil { requests.gemini.count == 2 }
        #expect(requests.gemini[1] == Polish.prompt)
        try await waitUntil { c.machine.activeJobs == 0 }
    }

    /// Polish and Translate combine as while recording: the polished message, translated.
    @Test func polishAndTranslateCombine() async throws {
        let first = RequestGate()
        let (rig, cues, requests) = Self.make(first: first)
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        c.handle(.pttDown)
        c.handle(.polish)
        c.handle(.shortcutKeyUp)
        c.handle(.translate)
        #expect(rig.h.pill.polishes && rig.h.pill.translates && cues.played.last == .polishOn)
        c.handle(.shortcutKeyUp)
        c.handle(.pttUp)
        try await waitUntil { requests.gemini.count == 2 }
        #expect(requests.gemini[1] == Translate.polishedPrompt(rig.h.settings.translationPair))
        try await waitUntil { c.machine.activeJobs == 0 }
        #expect(requests.gemini.count == 2)
        #expect(rig.h.history.entries.first?.currentKind == .translation(polished: true, by: .geminiFlash))
    }

    /// Send while processed: the plane and its flick, no request again, and Return once the text is pasted. Held down,
    /// it flips again.
    @Test func sendPressesReturnAfterThePaste() async throws {
        let first = RequestGate()
        let (rig, cues, requests) = Self.make(first: first)
        let c = rig.h.controller
        var returns = 0
        c.returnDelay = .milliseconds(5)
        c.pressReturnOverride = { returns += 1; return .pressed }
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        c.handle(.pttDown)
        c.handle(.send)
        #expect(rig.h.pill.sends && cues.played.last == .sendOn)
        c.handle(.sendRepeat)
        #expect(!rig.h.pill.sends && cues.played.last == .sendOn)
        c.handle(.sendRepeat)
        c.handle(.shortcutKeyUp)
        c.handle(.pttUp)
        try await Task.sleep(for: .milliseconds(80))
        #expect(requests.gemini.count == 1 && !first.wasCancelled, "Send asks Gemini for nothing new")
        first.isOpen = true
        try await waitUntil { returns == 1 && c.machine.activeJobs == 0 }
        #expect(rig.pasted.count == 1)
    }

    /// On Parakeet the text is there at once: the keys do nothing while it's processed.
    @Test func onParakeetTheKeysDoNothing() async throws {
        let gate = RequestGate()
        let (rig, cues, requests) = R.make { _, _, _ in
            try await gate.wait()
            return "parakeet words"
        }
        rig.h.settings.lineup.main = .parakeet
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.parakeet == 1 }
        #expect(rig.h.hotkeys.isProcessing && !rig.h.hotkeys.processingTakesKeys)
        let played = cues.played
        c.handle(.polish)
        c.handle(.send)
        c.handle(.translate)
        #expect(cues.played == played && !rig.h.pill.polishes && !rig.h.pill.sends)
        gate.isOpen = true
        try await waitUntil { rig.pasted.count == 1 && c.machine.activeJobs == 0 }
        #expect(requests.made.count == 1)
    }

    /// What the stopped request cost is looked up later and added to the dictation's, as the other one of a pair is.
    @Test func theStoppedRequestsCostCounts() async throws {
        let first = RequestGate()
        let (rig, _, requests) = Self.make(first: first)
        let c = rig.h.controller
        c.cancelledGenerationDelay = .zero
        c.generationLookupOverride = { id in
            id == "gen-1" ? GenerationDetails(provider: "Google AI Studio", costUSD: 0.00002)
                : GenerationDetails(provider: "Google AI Studio", costUSD: 0.00005)
        }
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        try await Task.sleep(for: .milliseconds(30))
        c.handle(.polish)
        c.handle(.shortcutKeyUp)
        try await waitUntil { requests.gemini.count == 2 }
        let kind = TranscriptVersionKind.polish(by: .geminiFlash)
        try await waitUntil {
            let metadata = rig.h.history.entries.first?.version(kind)?.metadata
            return metadata != nil && metadata?.pendingGenerationIDs == nil && metadata?.costUSD != nil
        }
        let cost = try #require(rig.h.history.entries.first?.version(kind)?.metadata.costUSD)
        #expect(abs(cost - 0.00007) < 1e-12, "the stopped request and the one that answered")
    }
}

// MARK: Parakeet's text while Gemini works (Experimental)

@MainActor
@Suite(.serialized) struct ParakeetBesideGeminiTests {
    typealias R = ProcessingRig

    /// Gemini waits on `gemini`, Parakeet on `parakeet` (both open by default unless closed by the test).
    static func make(on: Bool = true, gemini: RequestGate, parakeet: RequestGate,
                     models: [EngineID: LocalModelState] = [.parakeet: .ready])
        -> (R.Rig, SwitchModelControllerTests.Cues, Requests) {
        R.make(parakeetBeside: on, models: models) { engine, prompt, _ in
            if engine.isGemini {
                try await gemini.wait()
                return R.gemini(prompt, plain: "gemini words")
            }
            try await parakeet.wait()
            return "parakeet words"
        }
    }

    static func card(_ rig: R.Rig) -> Notice? {
        rig.h.toasts.notices.first { $0.dedupeKey.hasPrefix(DictationController.parakeetCardPrefix) }
    }

    /// Parakeet first: its text on a card, silently, that takes neither ↩ nor Esc; Parakeet's run makes no History
    /// row. Gemini's text pasted, the card goes by itself.
    @Test func parakeetsTextComesOnACardUntilGeminisIsPasted() async throws {
        let gemini = RequestGate(), parakeet = RequestGate()
        parakeet.isOpen = true
        let (rig, cues, requests) = Self.make(gemini: gemini, parakeet: parakeet)
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { Self.card(rig) != nil }
        let card = try #require(Self.card(rig))
        #expect(card.title == "Parakeet v3, while Gemini works")
        #expect(card.transcript == "parakeet words")
        #expect(card.actions.map(\.title) == ["Paste Here", "Copy"])
        #expect(card.sound == nil && !cues.played.contains(.polishReady), "silently")
        #expect(!card.takesCardKeys && card.lifetime == .sticky)
        #expect(!rig.h.hotkeys.cardPaste && !rig.h.hotkeys.cardClose, "↩ and Esc aren't the card's")
        #expect(requests.parakeet == 1 && requests.gemini == [nil])
        #expect(rig.h.history.entries.isEmpty, "Parakeet's run makes no row")

        gemini.isOpen = true
        try await waitUntil { rig.pasted.count == 1 && c.machine.activeJobs == 0 }
        #expect(rig.pasted.first?.contains("gemini words") == true)
        #expect(Self.card(rig) == nil)
        #expect(rig.h.history.entries.count == 1 && rig.h.history.entries.first?.engine == .geminiFlash)
    }

    /// Gemini first: no card, even once Parakeet's text comes.
    @Test func geminiFirstMeansNoCard() async throws {
        let gemini = RequestGate(), parakeet = RequestGate()
        gemini.isOpen = true
        let (rig, _, requests) = Self.make(gemini: gemini, parakeet: parakeet)
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { rig.pasted.count == 1 && c.machine.activeJobs == 0 }
        parakeet.isOpen = true
        try await Task.sleep(for: .milliseconds(80))
        #expect(Self.card(rig) == nil)
        #expect(requests.parakeet <= 1)
    }

    /// Paste Here: Parakeet's text is pasted by Parakeet's Pasting rules, Gemini stops, History keeps Parakeet's
    /// text, and Send's Return follows when it's on.
    @Test func pasteHereTakesParakeetsText() async throws {
        let gemini = RequestGate(), parakeet = RequestGate()
        parakeet.isOpen = true
        let (rig, _, _) = Self.make(gemini: gemini, parakeet: parakeet)
        let c = rig.h.controller
        rig.h.settings.modelsAddingSpace = [.parakeet]
        rig.h.settings.modesAddingSpace = [.pushToTalk]
        var returns = 0
        c.returnDelay = .milliseconds(5)
        c.pressReturnOverride = { returns += 1; return .pressed }
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        SwitchModelControllerTests.hold(rig)
        c.handle(.send)
        rig.now += 2
        c.handle(.pttUp)
        try await waitUntil { Self.card(rig) != nil }
        let card = try #require(Self.card(rig))
        try rig.click(.pasteText("parakeet words", by: .parakeet, in: .pushToTalk), in: card.dedupeKey)
        try await waitUntil { returns == 1 && c.machine.activeJobs == 0 }
        #expect(rig.pasted == ["parakeet words "])
        #expect(gemini.wasCancelled)
        let entry = try #require(rig.h.history.entries.first)
        #expect(entry.text == "parakeet words" && entry.engine == .parakeet && entry.status == .success)
        #expect(Self.card(rig) == nil)
        gemini.isOpen = true
        try await Task.sleep(for: .milliseconds(60))
        #expect(rig.pasted.count == 1, "Gemini's text never comes")
    }

    /// Copy: Parakeet's text on the clipboard, the card gone, Gemini stopped, nothing pasted; History keeps the text.
    @Test func copyTakesParakeetsTextWithoutPasting() async throws {
        let gemini = RequestGate(), parakeet = RequestGate()
        parakeet.isOpen = true
        let (rig, _, _) = Self.make(gemini: gemini, parakeet: parakeet)
        let c = rig.h.controller
        var copied: [String] = []
        c.copyOverride = { copied.append($0) }
        R.dictate(rig)
        try await waitUntil { Self.card(rig) != nil }
        try rig.click(.copyText("parakeet words"), in: try #require(Self.card(rig)).dedupeKey)
        #expect(copied == ["parakeet words"])
        #expect(Self.card(rig) == nil)
        try await waitUntil { c.machine.activeJobs == 0 }
        #expect(gemini.wasCancelled && rig.pasted.isEmpty)
        #expect(rig.h.history.entries.first?.text == "parakeet words")
    }

    /// Esc cancels the dictation as always, and the card goes with it.
    @Test func escTakesTheCardAlong() async throws {
        let gemini = RequestGate(), parakeet = RequestGate()
        parakeet.isOpen = true
        let (rig, _, _) = Self.make(gemini: gemini, parakeet: parakeet)
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { Self.card(rig) != nil }
        c.handle(.cancel)
        #expect(Self.card(rig) == nil && c.machine.activeJobs == 0)
        #expect(rig.notice("dictation.canceled") != nil)
    }

    /// Polish pressed while it's processed: the dictation is no longer plain, and the card goes.
    @Test func polishClosesTheCard() async throws {
        let gemini = RequestGate(), parakeet = RequestGate()
        parakeet.isOpen = true
        let (rig, _, requests) = Self.make(gemini: gemini, parakeet: parakeet)
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { Self.card(rig) != nil }
        c.handle(.polish)
        #expect(Self.card(rig) == nil)
        c.handle(.shortcutKeyUp)
        gemini.isOpen = true
        try await waitUntil { c.machine.activeJobs == 0 }
        #expect(requests.parakeet == 1)
        #expect(rig.h.history.entries.first?.currentKind == .polish(by: .geminiFlash))
    }

    /// Never for Polish or Translate, never with the switch off, never without Parakeet downloaded.
    @Test func onlyForAPlainGeminiDictationWithParakeetThere() async throws {
        for setup in ["polish", "off", "notDownloaded"] {
            let gemini = RequestGate(), parakeet = RequestGate()
            gemini.isOpen = true
            parakeet.isOpen = true
            let (rig, _, requests) = Self.make(on: setup != "off", gemini: gemini, parakeet: parakeet,
                                                models: [.parakeet: setup == "notDownloaded" ? .notInstalled : .ready])
            let c = rig.h.controller
            rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
            SwitchModelControllerTests.hold(rig)
            if setup == "polish" { c.handle(.polish) }
            rig.now += 2
            c.handle(.pttUp)
            try await waitUntil { rig.pasted.count == 1 && c.machine.activeJobs == 0 }
            #expect(requests.parakeet == 0, "\(setup)")
            #expect(Self.card(rig) == nil)
        }
    }

    /// The setting is off unless turned on, keeps Parakeet loaded while on, and is said in the diagnostics' settings
    /// line.
    @Test func theSettingIsOffByDefaultAndInTheLog() {
        let settings = AppSettings.inMemory()
        #expect(!settings.showsParakeetWhileGemini)
        #expect(SettingsKey.showsParakeetWhileGemini.defaultsKey == "tt.showsParakeetWhileGemini")
        #expect(DiagnosticSettingsSummary(settings: settings, keySaved: false).line.contains("parakeetWhileGemini=off"))
        settings.lineup.main = .gemini
        settings.showsParakeetWhileGemini = true
        #expect(DiagnosticSettingsSummary(settings: settings, keySaved: false).line.contains("parakeetWhileGemini=on"))
        #expect(settings.keepsParakeetLoaded)
    }
}

// MARK: The talk key as Undo while "Dictation canceled" is up

@MainActor
@Suite(.serialized) struct TalkKeyUndoTests {
    typealias Rig = DictationResumeTests.Rig
    typealias Switch = SwitchModelControllerTests

    static func make() -> Rig {
        let (rig, _) = Switch.make()
        rig.h.controller.start()
        return rig
    }

    /// Two seconds held, then Esc: "Dictation canceled · Undo", with the talk key named on Undo.
    static func cancelWhileRecording(_ rig: Rig) throws -> UUID {
        let kept = DictationResumeTests.speech(seconds: 2)
        rig.h.recorder.next = kept
        rig.holdThenEsc(2)
        let notice = try #require(rig.notice("dictation.canceled"))
        #expect(notice.actions.first?.keyHint == "fn")
        return kept.id
    }

    /// A tap of the talk key while the notice is up is its Undo: nothing at the press, the canceled dictation recording
    /// on hands-free at the release. That release doesn't stop it, nor does a stray one after.
    @Test func aTapIsUndoAfterACancelWhileRecording() throws {
        let rig = Self.make()
        let c = rig.h.controller
        let kept = try Self.cancelWhileRecording(rig)
        let starts = rig.h.recorder.starts
        c.handle(.pttDown)
        #expect(!c.machine.isRecording && rig.h.recorder.starts == starts, "the press starts nothing")
        rig.now += 0.2
        c.handle(.pttUp)
        #expect(c.machine.capture.isListeningOrLocked && c.machine.mode == .handsFree)
        #expect(rig.h.recorder.lastPrefix?.id == kept)
        #expect(rig.notice("dictation.canceled") == nil)
        c.handle(.pttUp)
        #expect(c.machine.isRecording && c.machine.mode == .handsFree)
        c.handle(.cancel)
    }

    /// The same after Esc while the dictation was being transcribed.
    @Test func aTapIsUndoAfterACancelWhileProcessing() async throws {
        let rig = Self.make()
        let c = rig.h.controller
        let gate = RequestGate()
        rig.result = { _, _ in
            try await gate.wait()
            return "words"
        }
        let kept = DictationResumeTests.speech(seconds: 2)
        rig.h.recorder.next = kept
        Switch.hold(rig)
        rig.now += 2
        c.handle(.pttUp)
        try await waitUntil { rig.transcribed.count == 1 }
        c.handle(.cancel)
        try await waitUntil { c.machine.activeJobs == 0 && rig.notice("dictation.canceled") != nil }
        c.handle(.pttDown)
        #expect(!c.machine.isRecording)
        c.handle(.pttUp)
        #expect(c.machine.isRecording && c.machine.mode == .handsFree)
        #expect(rig.h.recorder.lastPrefix?.id == kept.id)
        c.handle(.cancel)
    }

    /// A chord off the talk key does what it does, and no Undo: Paste last (F5 V), hands-free (a new dictation), or
    /// any other key in the press. The notice stays.
    @Test func aChordIsNoUndo() throws {
        let rig = Self.make()
        let c = rig.h.controller
        _ = try Self.cancelWhileRecording(rig)

        // F5 V: the router ends the hold, then Paste last (nothing to paste yet, it says).
        c.handle(.pttDown)
        c.handle(.pttInterrupted)
        c.handle(.pasteLast)
        #expect(rig.notice("pasteLast.empty") != nil, "Paste last ran")
        #expect(!c.machine.isRecording && rig.notice("dictation.canceled") != nil)

        c.handle(.pttDown)
        c.handle(.keyDuringHold)
        c.handle(.pttUp)
        #expect(!c.machine.isRecording && rig.notice("dictation.canceled") != nil, "another key in the press")

        rig.h.recorder.next = DictationResumeTests.speech(seconds: 1)
        c.handle(.pttDown)
        c.handle(.handsFreeToggle)
        #expect(c.machine.mode == .handsFree && rig.h.recorder.lastPrefix == nil, "a new dictation, not the old one")
        c.handle(.cancel)
    }

    /// Closed, or gone by itself, the notice no longer owns the talk key: it starts a dictation again.
    @Test(arguments: ["closed", "expired"])
    func withTheNoticeGoneTheTalkKeyRecords(_ how: String) throws {
        let rig = Self.make()
        let c = rig.h.controller
        _ = try Self.cancelWhileRecording(rig)
        if how == "closed" {
            rig.h.toasts.dismiss(dedupeKey: "dictation.canceled")
        } else {
            rig.h.toasts.expire(now: Date().addingTimeInterval(60))
        }
        #expect(rig.notice("dictation.canceled") == nil)
        c.handle(.pttDown)
        #expect(c.machine.capture.isArming)
        c.handle(.cancel)
    }

    /// The button names the user's own talk key; a recording a key took over (Polish Selection, fn D) isn't the
    /// user's cancel, and its notice leaves the talk key alone.
    @Test func theButtonNamesTheTalkKey() throws {
        let rig = Self.make()
        rig.h.settings.shortcuts[.pushToTalk] = Shortcut(modifiers: [], keyCode: KeyCode.f5)
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        rig.holdThenEsc(2)
        #expect(rig.notice("dictation.canceled")?.actions.first?.keyHint == "F5")
        #expect(rig.h.hotkeys.reportsKeysDuringHold)

        rig.h.toasts.dismissAll()
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        SwitchModelControllerTests.hold(rig)
        rig.now += 2
        rig.h.controller.send(.discard)
        let taken = try #require(rig.notice("dictation.canceled"))
        #expect(taken.actions.first?.keyHint == nil)
        #expect(!rig.h.hotkeys.reportsKeysDuringHold)
        rig.h.controller.handle(.pttDown)
        #expect(rig.h.controller.machine.capture.isArming, "a new dictation")
        rig.h.controller.handle(.cancel)
    }
}
