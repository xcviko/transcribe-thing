import Foundation
import Testing
@testable import TranscribeThing

// MARK: - Dictations being processed: new ones beside them, the pill's buttons, and Undo of a cancel

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
    /// `clickAway`: the clicks away the controller hears, wired as the app wires them.
    static func make(models: [EngineID: LocalModelState] = [.parakeet: .ready], clickAway: ClickAwayMonitor? = nil,
                     answer: @escaping @MainActor (EngineID, String?, Int) async throws -> String)
        -> (Rig, Switch.Cues, Requests) {
        let (rig, cues) = Switch.make(models: models)
        let requests = Requests()
        rig.h.controller.clickAway = clickAway
        rig.h.settings.lineup.main = .gemini
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

// MARK: A new dictation while others are processed

@MainActor
@Suite(.serialized) struct DictationsAlongsideTests {
    typealias R = ProcessingRig
    typealias Switch = SwitchModelControllerTests

    /// Requests answered in their own time: request `n` waits on `gates[n]` (from 1) when there is one.
    static func make(_ gates: [Int: RequestGate]) -> (R.Rig, Switch.Cues, Requests) {
        R.make { _, prompt, number in
            if let gate = gates[number] { try await gate.wait() }
            return prompt == nil ? "words \(number)" : "<message>Polished \(number).</message>"
        }
    }

    /// While a dictation is processed the talk key starts a new one, with its sound and pill: the earlier one moves up
    /// onto a pill of its own, the new recording takes the bottom pill and its tray. Hands-free and a click on the
    /// resting pill would too (the machine takes them from rest with jobs in flight).
    @Test func theTalkKeyStartsANewDictationWhileOneIsProcessed() async throws {
        let first = RequestGate()
        let (rig, cues, requests) = Self.make([1: first])
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        #expect(c.machine.isProcessing && rig.h.pill.stack.isEmpty)
        guard case .processing(let firstKey)? = rig.h.pill.tray?.dictation else {
            Issue.record("the processing pill's tray acts on its dictation")
            return
        }
        let starts = rig.h.recorder.starts
        Switch.hold(rig)
        #expect(c.machine.isRecording && rig.h.recorder.starts == starts + 1 && cues.played.last == .start)
        #expect(rig.h.pill.phase == .listening && rig.h.pill.tray?.dictation == .recording)
        #expect(rig.h.pill.stack.map(\.key) == [firstKey], "the earlier one moved up")
        #expect(rig.h.pill.stack.first?.choice == .gemini)
        c.handle(.cancel)
        #expect(!c.machine.isRecording && c.machine.activeJobs == 1, "Esc cancels the recording, not the one on its way")
        first.isOpen = true
        try await waitUntil { rig.pasted == ["words 1"] && c.machine.activeJobs == 0 }

        // Hands-free and the pill's click start from rest with a dictation on its way too.
        #expect(DictationMachine.Input.handsFreeToggle.startsDictation && DictationMachine.Input.pillClick.startsDictation)
        var machine = DictationMachine()
        _ = machine.handle(.jobStarted, now: 0)
        #expect(machine.handle(.handsFreeToggle, now: 0).contains(.startCapture) && machine.isRecording)
        var clicked = DictationMachine()
        _ = clicked.handle(.jobStarted, now: 0)
        #expect(clicked.handle(.pillClick, now: 0).contains(.startCapture))
    }

    /// Each text is pasted when it's there, in the order the dictations were recorded: a later one that's answered first
    /// waits for the earlier one.
    @Test func textsArePastedInRecordingOrder() async throws {
        let first = RequestGate()
        let (rig, _, requests) = Self.make([1: first])
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 2 }
        try await Task.sleep(for: .milliseconds(60))
        #expect(rig.pasted.isEmpty, "the second waits for the first")
        #expect(rig.h.pill.stack.count == 1, "the first stands above the second's pill")
        first.isOpen = true
        try await waitUntil { rig.pasted == ["words 1", "words 2"] && c.machine.activeJobs == 0 }
        #expect(rig.h.pill.stack.isEmpty)
        #expect(rig.h.history.entries.count == 2)
    }

    /// An earlier dictation's text that comes while a new one records is pasted right away, into the field in front;
    /// the recording goes on.
    @Test func anEarlierTextIsPastedWhileTheNextRecords() async throws {
        let first = RequestGate()
        let (rig, _, requests) = Self.make([1: first])
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        Switch.hold(rig)
        first.isOpen = true
        try await waitUntil { rig.pasted == ["words 1"] && c.machine.activeJobs == 0 }
        #expect(c.machine.capture.isListeningOrLocked, "the new recording goes on")
        #expect(rig.h.pill.stack.isEmpty && rig.h.pill.phase == .listening)
        #expect(rig.h.toasts.notices.isEmpty, "no card for it")
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        rig.now += 2
        c.handle(.pttUp)
        try await waitUntil { rig.pasted == ["words 1", "words 2"] && c.machine.activeJobs == 0 }
    }

    /// Esc cancels the dictation being recorded if there is one; with none, the newest one on its way. Each cancel has
    /// its own Undo notice, and the older ones are pasted as always.
    @Test func escCancelsTheRecordingThenTheNewestOnItsWay() async throws {
        let first = RequestGate(), second = RequestGate()
        let (rig, cues, requests) = Self.make([1: first, 2: second])
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 2 }
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        Switch.hold(rig)
        rig.now += 2
        c.handle(.cancel)
        #expect(!c.machine.isRecording && c.machine.activeJobs == 2 && cues.played.last == .cancel)
        #expect(rig.h.pill.stack.count == 1 && rig.h.pill.phase == .processing)
        c.handle(.cancel)
        #expect(c.machine.activeJobs == 1)
        try await waitUntil { second.wasCancelled }
        #expect(rig.h.pill.stack.isEmpty, "the first is on the bottom pill now")
        #expect(rig.notice("dictation.canceled") != nil)
        first.isOpen = true
        try await waitUntil { rig.pasted == ["words 1"] && c.machine.activeJobs == 0 }
    }

    /// Paste last isn't held off: it pastes the last transcript while the next one is processed.
    @Test func pasteLastStillWorks() async throws {
        let gate = RequestGate()
        let (rig, _, requests) = Self.make([2: gate])
        let c = rig.h.controller
        var pastedLast: [String] = []
        c.pasteLastOverride = { pastedLast.append($0); return .pasted }
        R.dictate(rig)
        try await waitUntil { rig.pasted.count == 1 && c.machine.activeJobs == 0 }
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 2 }
        c.handle(.pasteLast)
        try await waitUntil { pastedLast.count == 1 }
        #expect(pastedLast.first?.contains("words 1") == true)
        gate.isOpen = true
        try await waitUntil { rig.pasted.count == 2 && c.machine.activeJobs == 0 }
    }

    /// Undo of an older cancel while a dictation is processed records on at once, hands-free; the one on its way is
    /// pasted meanwhile.
    @Test func undoRecordsOnWhileOneIsOnItsWay() async throws {
        let gate = RequestGate()
        let (rig, _, requests) = Self.make([1: gate])
        let c = rig.h.controller
        let canceled = DictationResumeTests.speech(seconds: 2)
        rig.h.recorder.next = canceled
        rig.holdThenEsc(2)
        #expect(rig.notice("dictation.canceled") != nil)
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        c.send(.handsFreeToggle)
        rig.now += 2
        c.send(.pillStop)
        try await waitUntil { requests.gemini.count == 1 }
        try rig.click(.undoCancel, in: "dictation.canceled")
        #expect(c.machine.isRecording && c.machine.mode == .handsFree)
        #expect(rig.h.recorder.lastPrefix?.id == canceled.id)
        gate.isOpen = true
        try await waitUntil { rig.pasted.count == 1 }
        #expect(c.machine.isRecording)
        c.handle(.cancel)
    }

    /// A failed dictation's Retry while another records would bring text with nowhere to go: the notice stays,
    /// saying to finish first, and nothing is sent.
    @Test func retryGoesWhileANewDictationRecords() async throws {
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
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        c.send(.handsFreeToggle)
        rig.h.toasts.perform(try #require(failure.actions.first { $0.kind == .retry }), on: failure)
        try await waitUntil { requests.gemini.count == 2 && rig.pasted.count == 1 }
        #expect(c.machine.isRecording, "the new recording goes on")
        #expect(rig.notice(failure.dedupeKey) == nil)
        #expect(rig.h.history.entries.first { $0.id == failure.recordingID }?.status == .success)
        rig.now += 2
        c.send(.pillStop)
        try await waitUntil { rig.pasted.count == 2 && c.machine.activeJobs == 0 }
    }

    /// Each pill keeps its own dictation's state: Polish on the older one shows on its stacked pill, Send on the newer
    /// one on the bottom pill, each on its own tray; the dictation log says how many were on their way.
    @Test func eachPillKeepsItsOwnState() async throws {
        let first = RequestGate(), second = RequestGate()
        let (rig, _, requests) = Self.make([1: first, 2: second, 3: first])
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        rig.h.pill.clickTray(.polish)
        try await waitUntil { requests.gemini.count == 2 }
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        Switch.hold(rig)
        c.toggle(.send, on: .recording)
        rig.now += 2
        c.handle(.pttUp)
        try await waitUntil { requests.gemini.count == 3 }
        let stacked = try #require(rig.h.pill.stack.first)
        #expect(rig.h.pill.stack.count == 1)
        #expect(stacked.tray.polishes && !stacked.tray.sends)
        #expect(rig.h.pill.stackModels[stacked.key]?.polishes == true)
        #expect(rig.h.pill.sends && !rig.h.pill.polishes && rig.h.pill.tray?.sends == true)
        first.isOpen = true
        second.isOpen = true
        try await waitUntil { rig.pasted.count == 2 && c.machine.activeJobs == 0 }
        #expect(rig.pasted.first?.contains("Polished") == true, "the older one first, polished")
    }

    /// A click away holds every dictation on its way, each on its own dashed pill; a click on one dashed pill takes back
    /// only that one, which is pasted, and the other's text comes up on its card.
    @Test func aClickAwayIsTakenBackPerDictation() async throws {
        let first = RequestGate(), second = RequestGate()
        let (rig, _, requests) = Self.make([1: first, 2: second])
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 2 }
        c.clickedAway()
        #expect(rig.h.pill.holdsPaste && rig.h.pill.stack.first?.holdsPaste == true)
        let older = try #require(rig.h.pill.stack.first?.key)
        rig.h.pill.onStackClick?(older)
        #expect(rig.h.pill.stack.first?.holdsPaste == false && rig.h.pill.holdsPaste, "only the clicked one")
        first.isOpen = true
        second.isOpen = true
        try await waitUntil { c.machine.activeJobs == 0 && rig.pasted == ["words 1"] }
        try await waitUntil { rig.h.toasts.notices.contains { $0.transcript == "words 2" } }
    }

    /// Past three, the stack shows the newest three and folds the rest into "+N"; every one is still on its way.
    @Test func manyDictationsStack() async throws {
        let gates = Dictionary(uniqueKeysWithValues: (1...5).map { ($0, RequestGate()) })
        let (rig, _, requests) = Self.make(gates)
        let c = rig.h.controller
        for n in 1...5 {
            R.dictate(rig)
            try await waitUntil { requests.gemini.count == n }
        }
        #expect(rig.h.pill.stack.count == 4 && c.machine.activeJobs == 5)
        #expect(PillStackMetrics.height(for: 4) == 3 * (PillStackMetrics.pillHeight + PillStackMetrics.gap)
                + PillStackMetrics.moreHeight + PillStackMetrics.gap)
        for gate in gates.values { gate.isOpen = true }
        try await waitUntil { rig.pasted.count == 5 && c.machine.activeJobs == 0 }
        #expect(rig.pasted == (1...5).map { "words \($0)" })
    }
}

// MARK: Polish, Translate and Send on the pill while a dictation is processed

@MainActor
@Suite(.serialized) struct ProcessingTrayTests {
    typealias R = ProcessingRig

    /// A Gemini dictation whose first request waits on `first`; later requests answer at once.
    static func make(first: RequestGate) -> (R.Rig, SwitchModelControllerTests.Cues, Requests) {
        R.make { _, prompt, number in
            if number == 1 { try await first.wait() }
            return R.gemini(prompt)
        }
    }

    /// Polish clicked on the processing pill: the wand and Polish's sound, and the recording goes again with Polish's
    /// prompt at once, the request in flight stopped. Polish's message is pasted.
    @Test func polishSendsItAgainPolishedAtOnce() async throws {
        let first = RequestGate()
        let (rig, cues, requests) = Self.make(first: first)
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        #expect(rig.h.pill.tray?.rewrites == true && rig.h.pill.tray?.canSend == true)
        rig.h.pill.clickTray(.polish)
        #expect(rig.h.pill.polishes && cues.played.last == .polishOn && rig.h.pill.tray?.polishes == true)
        try await waitUntil { requests.gemini.count == 2 }
        #expect(requests.gemini[1] == Polish.prompt)
        try await waitUntil { rig.pasted.count == 1 && c.machine.activeJobs == 0 }
        #expect(first.wasCancelled, "the plain request stopped")
        #expect(rig.pasted.first?.contains("Polished words") == true)
        #expect(rig.h.history.entries.first?.currentKind == .polish(by: .geminiFlash))
        #expect(!c.machine.isRecording)
    }

    /// Every click is one request: on, then off again, is two more, and the last asks for the plain transcript.
    @Test func everyClickIsOneRequest() async throws {
        let first = RequestGate()
        let (rig, cues, requests) = Self.make(first: first)
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        let before = cues.played.count
        rig.h.pill.clickTray(.polish)
        rig.h.pill.clickTray(.polish)
        #expect(Array(cues.played.dropFirst(before)) == [.polishOn, .polishOff])
        try await waitUntil { requests.gemini.count == 3 }
        #expect(requests.gemini[1] == Polish.prompt && requests.gemini[2] == nil)
        try await waitUntil { rig.pasted.count == 1 && c.machine.activeJobs == 0 }
        #expect(rig.pasted.first?.contains("plain words") == true)
        #expect(requests.gemini.count == 3)
    }

    /// Polish and Translate combine as while recording: the polished message, translated.
    @Test func polishAndTranslateCombine() async throws {
        let first = RequestGate()
        let (rig, cues, requests) = Self.make(first: first)
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        rig.h.pill.clickTray(.polish)
        rig.h.pill.clickTray(.translate)
        #expect(rig.h.pill.polishes && rig.h.pill.translates && cues.played.last == .polishOn)
        try await waitUntil { requests.gemini.count == 3 }
        #expect(requests.gemini[2] == Translate.polishedPrompt(rig.h.settings.translationPair))
        try await waitUntil { c.machine.activeJobs == 0 }
        #expect(rig.h.history.entries.first?.currentKind == .translation(polished: true, by: .geminiFlash))
    }

    /// An answer waiting behind an older dictation is asked for again too.
    @Test func anAnswerWaitingItsTurnIsAskedAgain() async throws {
        let first = RequestGate()
        let (rig, _, requests) = Self.make(first: first)
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 2 }
        try await Task.sleep(for: .milliseconds(40))
        rig.h.pill.clickTray(.polish)
        try await waitUntil { requests.gemini.count == 3 }
        #expect(requests.gemini[2] == Polish.prompt)
        first.isOpen = true
        try await waitUntil { rig.pasted.count == 2 && c.machine.activeJobs == 0 }
        #expect(rig.pasted[0].contains("plain words") && rig.pasted[1].contains("Polished words"))
    }

    /// A stacked pill's tray acts on its own dictation: Polish there sends that one again, and the bottom pill's stays.
    @Test func aStackedPillsTrayActsOnItsDictation() async throws {
        let first = RequestGate()
        let (rig, _, requests) = R.make { _, prompt, number in
            if number <= 3 { try await first.wait() }
            return R.gemini(prompt)
        }
        let c = rig.h.controller
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 2 }
        let stacked = try #require(rig.h.pill.stack.first)
        rig.h.pill.onToggle?(.polish, stacked.tray.dictation)
        try await waitUntil { requests.gemini.count == 3 }
        #expect(rig.h.pill.stack.first?.tray.polishes == true, "\(rig.h.pill.stack)")
        #expect(!rig.h.pill.polishes)
        first.isOpen = true
        try await waitUntil { rig.pasted.count == 2 && c.machine.activeJobs == 0 }
        #expect(rig.pasted[0].contains("Polished words") && rig.pasted[1].contains("plain words"))
    }

    /// Send while processed: the plane and its flick, no request again, and Return once the text is pasted.
    @Test func sendPressesReturnAfterThePaste() async throws {
        let first = RequestGate()
        let (rig, cues, requests) = Self.make(first: first)
        let c = rig.h.controller
        var returns = 0
        c.returnDelay = .milliseconds(5)
        c.pressReturnOverride = { returns += 1; return .pressed }
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        rig.h.pill.clickTray(.send)
        #expect(rig.h.pill.sends && cues.played.last == .sendOn)
        rig.h.pill.clickTray(.send)
        #expect(!rig.h.pill.sends && cues.played.last == .sendOn)
        rig.h.pill.clickTray(.send)
        try await Task.sleep(for: .milliseconds(80))
        #expect(requests.gemini.count == 1 && !first.wasCancelled, "Send asks Gemini for nothing new")
        first.isOpen = true
        try await waitUntil { returns == 1 && c.machine.activeJobs == 0 }
        #expect(rig.pasted.count == 1)
    }

    /// On Parakeet the text is there at once: Polish and Translate are dimmed and do nothing; Send still works.
    @Test func onParakeetOnlySendWorks() async throws {
        let gate = RequestGate()
        let (rig, cues, requests) = R.make { _, _, _ in
            try await gate.wait()
            return "parakeet words"
        }
        rig.h.settings.lineup.main = .parakeet
        let c = rig.h.controller
        var returns = 0
        c.returnDelay = .milliseconds(5)
        c.pressReturnOverride = { returns += 1; return .pressed }
        R.dictate(rig)
        try await waitUntil { requests.parakeet == 1 }
        #expect(rig.h.pill.tray?.rewrites == false && rig.h.pill.tray?.canSend == true)
        let played = cues.played
        rig.h.pill.clickTray(.polish)
        rig.h.pill.clickTray(.translate)
        #expect(cues.played == played && !rig.h.pill.polishes && !rig.h.pill.translates)
        rig.h.pill.clickTray(.send)
        #expect(rig.h.pill.sends)
        gate.isOpen = true
        try await waitUntil { rig.pasted.count == 1 && returns == 1 && c.machine.activeJobs == 0 }
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
        rig.h.pill.clickTray(.polish)
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

extension PillModel {
    /// A click on a button of the bottom pill's tray, as the tray makes it.
    @MainActor func clickTray(_ toggle: PillToggle) {
        guard let tray else { return }
        onToggle?(toggle, tray.dictation)
    }
}

// MARK: The removed "Show Parakeet's text while Gemini works"

@MainActor
@Suite(.serialized) struct ParakeetBesideGeminiRemovalTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        try body(defaults)
    }

    /// The switch an older build stored goes at load, Parakeet isn't kept loaded for it, and the log no longer says it.
    @Test func theStoredSwitchGoesAtLoad() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: "tt.showsParakeetWhileGemini")
            let settings = AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() })
            #expect(defaults.object(forKey: "tt.showsParakeetWhileGemini") == nil)
            settings.lineup.main = .gemini
            settings.lineup.setSwitchable(.parakeet, false)
            #expect(!settings.usesLocalParakeet)
            #expect(!DiagnosticSettingsSummary(settings: settings, keySaved: false).line.contains("parakeetWhileGemini"))
        }
    }

    /// A plain dictation on Gemini goes to Gemini alone, with Parakeet downloaded and loaded: no request to Parakeet,
    /// no card, Gemini's text pasted.
    @Test func aGeminiDictationGoesToGeminiAlone() async throws {
        let (rig, _, requests) = ProcessingRig.make { _, prompt, _ in ProcessingRig.gemini(prompt) }
        let c = rig.h.controller
        ProcessingRig.dictate(rig)
        try await waitUntil { rig.pasted.count == 1 && c.machine.activeJobs == 0 }
        #expect(requests.parakeet == 0 && requests.gemini == [nil])
        #expect(rig.pasted.first?.contains("plain words") == true)
        #expect(!rig.h.toasts.notices.contains { $0.dedupeKey.hasPrefix("dictation.parakeet.") })
    }
}

// MARK: Undo of a cancel is its button's only: the talk key always starts a new dictation

@MainActor
@Suite(.serialized) struct CancelUndoTests {
    typealias Rig = DictationResumeTests.Rig
    typealias Switch = SwitchModelControllerTests

    /// When the dictation was canceled: while it recorded (Esc with the talk key held), or on its way to the engine.
    enum Canceled: CaseIterable { case recording, processing }

    static func make() -> Rig {
        let (rig, _) = Switch.make()
        rig.h.controller.start()
        return rig
    }

    /// Two seconds dictated, canceled `when`: "Dictation canceled · Undo", the plain button and nothing beside it.
    /// `gate` holds every request from here on (the canceled one's too, for `processing`).
    static func cancel(_ rig: Rig, _ when: Canceled, gate: RequestGate) async throws -> UUID {
        rig.result = { _, _ in
            try await gate.wait()
            return "new words"
        }
        let kept = DictationResumeTests.speech(seconds: 2)
        rig.h.recorder.next = kept
        switch when {
        case .recording:
            rig.holdThenEsc(2)
        case .processing:
            Switch.hold(rig)
            rig.now += 2
            rig.h.controller.handle(.pttUp)
            try await waitUntil { rig.transcribed.count == 1 }
            rig.h.controller.handle(.cancel)
            try await waitUntil { rig.h.controller.machine.activeJobs == 0 && rig.notice("dictation.canceled") != nil }
        }
        let notice = try #require(rig.notice("dictation.canceled"))
        #expect(notice.actions.map(\.title) == ["Undo"] && notice.actions.map(\.kind) == [.undoCancel])
        #expect(!rig.h.controller.machine.isBusy)
        return kept.id
    }

    /// After either cancel the talk key starts a new dictation at once: no Undo, and the notice stays. Undo clicked
    /// during the new recording is refused ("finish first"); once the new one is pasted, the click brings the
    /// canceled one back.
    @Test(arguments: Canceled.allCases)
    func theTalkKeyStartsANewDictation(_ when: Canceled) async throws {
        let rig = Self.make()
        let c = rig.h.controller
        let gate = RequestGate()
        let kept = try await Self.cancel(rig, when, gate: gate)
        let starts = rig.h.recorder.starts
        let transcribed = rig.transcribed.count

        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        c.handle(.pttDown)
        #expect(c.machine.capture.isArming && rig.h.recorder.starts == starts + 1, "the press starts a dictation")
        c.send(.timer(.arming))
        #expect(rig.h.recorder.lastPrefix == nil, "a new dictation, not the canceled one")
        #expect(rig.notice("dictation.canceled") != nil, "the notice stays")

        try rig.click(.undoCancel, in: "dictation.canceled")
        let refused = try #require(rig.notice("dictation.canceled"))
        #expect(refused.body == "Finish this dictation first, then Undo.")
        #expect(refused.actions.map(\.kind) == [.undoCancel])
        #expect(c.machine.capture.isListeningOrLocked && c.machine.mode == .pushToTalk, "the new one goes on")
        #expect(rig.h.recorder.lastPrefix == nil)

        rig.now += 2
        c.handle(.pttUp)
        gate.isOpen = true
        try await waitUntil { rig.pasted == ["new words"] && c.machine.activeJobs == 0 }
        #expect(rig.transcribed.count == transcribed + 1 && rig.transcribed.last?.id != kept)

        try rig.click(.undoCancel, in: "dictation.canceled")
        #expect(c.machine.isRecording && c.machine.mode == .handsFree)
        #expect(rig.h.recorder.lastPrefix?.id == kept)
        c.handle(.cancel)
    }

    /// A tap of the talk key (press and release at once) is no Undo either, on F5 as on fn: whatever a tap does, the
    /// canceled dictation isn't picked up, and the notice stays.
    @Test(arguments: [false, true])
    func aTapIsNoUndo(_ onF5: Bool) async throws {
        let rig = Self.make()
        if onF5 { rig.h.settings.shortcuts[.pushToTalk] = Shortcut(modifiers: [], keyCode: KeyCode.f5) }
        let c = rig.h.controller
        _ = try await Self.cancel(rig, .recording, gate: RequestGate())
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 1)
        c.handle(.pttDown)
        rig.now += 0.1
        c.handle(.pttUp)
        #expect(rig.h.recorder.lastPrefix == nil, "not the canceled dictation")
        #expect(rig.notice("dictation.canceled") != nil)
        c.handle(.cancel)
    }

    /// With nothing busy, a click on Undo brings the canceled dictation back, recording on hands-free.
    @Test(arguments: Canceled.allCases)
    func undoClickedWhenIdleRestoresIt(_ when: Canceled) async throws {
        let rig = Self.make()
        let c = rig.h.controller
        let kept = try await Self.cancel(rig, when, gate: RequestGate())
        try rig.click(.undoCancel, in: "dictation.canceled")
        #expect(c.machine.isRecording && c.machine.mode == .handsFree)
        #expect(rig.h.recorder.lastPrefix?.id == kept)
        #expect(rig.notice("dictation.canceled") == nil)
        c.handle(.cancel)
    }

    // MARK: Esc closes the notice

    /// With the notice up and nothing busy, Esc is the notice's (swallowed by the router: `cardClose`) and closes it,
    /// as its X does; then Esc is the app's again. The same for both cancels.
    @Test(arguments: Canceled.allCases)
    func escClosesTheNotice(_ when: Canceled) async throws {
        let rig = Self.make()
        let c = rig.h.controller
        #expect(!rig.h.hotkeys.cardClose, "no notice: Esc is the app's")
        _ = try await Self.cancel(rig, when, gate: RequestGate())
        #expect(rig.h.hotkeys.cardClose)

        c.handle(.cardClose)
        #expect(rig.notice("dictation.canceled") == nil)
        #expect(!rig.h.hotkeys.cardClose)
        c.handle(.pttDown)
        #expect(c.machine.capture.isArming, "the talk key records")
        #expect(!rig.h.hotkeys.cardClose, "recording: Esc cancels it")
        c.handle(.cancel)
    }

    /// Esc during a dictation started while the notice is up cancels that dictation: the router gives it to the
    /// dictation (`cardClose` is off while busy), and an Esc that reached the notice's path anyway leaves it.
    @Test func escWhileRecordingCancelsItAndLeavesTheNotice() async throws {
        let rig = Self.make()
        let c = rig.h.controller
        let canceled = try await Self.cancel(rig, .processing, gate: RequestGate())
        // Too short to keep for Undo: its cancel posts nothing over the notice.
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 0.5)
        Switch.hold(rig)
        #expect(c.machine.isRecording && rig.h.hotkeys.isBusy && !rig.h.hotkeys.cardClose)
        c.handle(.cardClose)
        #expect(c.machine.isRecording && rig.notice("dictation.canceled") != nil)
        rig.now += 0.5
        c.handle(.cancel)
        #expect(!c.machine.isRecording)
        let notice = try #require(rig.notice("dictation.canceled"), "the notice stays")
        #expect(notice.recordingID == canceled)
        #expect(rig.h.hotkeys.cardClose, "idle again: the next Esc closes it")
    }

    /// Chords off the talk key work as usual with the notice up: Paste last (F5 V), hands-free (a new dictation).
    @Test func chordsWorkAsUsual() async throws {
        let rig = Self.make()
        let c = rig.h.controller
        _ = try await Self.cancel(rig, .recording, gate: RequestGate())

        // F5 V: the router ends the hold, then Paste last (nothing to paste yet, it says).
        c.handle(.pttDown)
        c.handle(.pttInterrupted)
        c.handle(.pasteLast)
        #expect(rig.notice("pasteLast.empty") != nil, "Paste last ran")
        #expect(rig.notice("dictation.canceled") != nil)

        rig.h.recorder.next = DictationResumeTests.speech(seconds: 1)
        c.handle(.pttDown)
        c.handle(.handsFreeToggle)
        #expect(c.machine.mode == .handsFree && rig.h.recorder.lastPrefix == nil, "a new dictation, not the old one")
        c.handle(.cancel)
    }
}
