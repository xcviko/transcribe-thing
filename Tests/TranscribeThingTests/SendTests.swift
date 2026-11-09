import AppKit
import Foundation
import os
import Testing
@testable import TranscribeThing

// MARK: - No shortcut: the pill's button

@Suite struct SendIsNoShortcutTests {
    /// Send is a button on the pill, not a binding: none in the defaults, none to record, and a key saved for it by an
    /// older build is ignored, with every other binding kept.
    @Test func sendIsThePillsButton() throws {
        #expect(!ShortcutAction.allCases.map(\.rawValue).contains("send"))
        #expect(PillToggle.send.title == "Send" && PillToggle.send.symbolName == "paperplane.fill")
        let saved = #"{"send":{"keyCode":36,"modifiers":[{"modifier":"control","side":"either"}]},"#
            + #""handsFree":{"keyCode":49,"modifiers":[{"modifier":"control","side":"either"}]}}"#
        let decoded = try JSONDecoder().decode(ShortcutBindings.self, from: Data(saved.utf8))
        #expect(decoded[.handsFree] == Shortcut(modifiers: [.init(.control)], keyCode: KeyCode.space))
        #expect(!String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("send"))
    }
}

// MARK: - The dictation

@MainActor
@Suite(.serialized) struct SendControllerTests {
    typealias Rig = DictationResumeTests.Rig
    typealias Switch = SwitchModelControllerTests
    typealias Gate = PolishSelectionTests.Lookup

    /// When each paste and each Return came, in order.
    @MainActor final class Keys {
        var log: [String] = []
        var pastedAt: ContinuousClock.Instant?
        var returnedAt: ContinuousClock.Instant?
        var returns: Int { log.filter { $0 == "↩" }.count }
    }

    /// A rig whose pastes come out as `outcome` and whose Returns are counted, never posted.
    static func make(outcome: InsertionOutcome = .pasted) -> (Rig, Switch.Cues, Keys) {
        let (rig, cues) = Switch.make()
        let keys = Keys()
        rig.h.controller.returnDelay = .milliseconds(10)
        rig.h.controller.insertOverride = { [weak rig] text in
            rig?.pasted.append(text)
            keys.log.append(text)
            keys.pastedAt = .now
            return outcome
        }
        rig.h.controller.pressReturnOverride = {
            keys.log.append("↩")
            keys.returnedAt = .now
            return .pressed
        }
        rig.result = { _, _ in "See you at ten." }
        return (rig, cues, keys)
    }

    /// Push-to-talk with Send clicked on the pill, then let go after two seconds of speech.
    static func dictateSent(_ rig: Rig) {
        Switch.hold(rig)
        rig.h.controller.toggle(.send, on: .recording)
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        rig.now += 2
        rig.h.controller.handle(.pttUp)
    }

    /// The pill's Send turns it on and off, with its flick both ways; the pill and its tray show it; the recording goes
    /// on; on Parakeet too (it's no Gemini rewrite).
    @Test func theSendButtonTurnsItOnAndOff() {
        let (rig, cues, _) = Self.make()
        let c = rig.h.controller
        #expect(!c.effectiveChoice.isGemini)
        Switch.hold(rig)
        #expect(rig.h.pill.tray == PillTrayState(dictation: .recording))
        c.toggle(.send, on: .recording)
        #expect(c.isSending && rig.h.pill.sends && rig.h.pill.tray?.sends == true)
        #expect(PillView(model: rig.h.pill).visual == .listening(sends: true))
        c.toggle(.send, on: .recording)
        #expect(!c.isSending && !rig.h.pill.sends)
        c.toggle(.send, on: .recording)
        #expect(cues.played.suffix(3) == [.sendOn, .sendOn, .sendOn])
        #expect(!cues.played.contains(.polishOff), "no Polish drop for Send")
        #expect(c.machine.capture.isListeningOrLocked, "it never stops the recording")
        c.send(.pillCancel)
        #expect(!c.isSending && !rig.h.pill.sends)
    }

    /// Outside a dictation the button does nothing (there's no tray to click then anyway).
    @Test func itDoesNothingWhenNotRecording() {
        let (rig, cues, _) = Self.make()
        rig.h.controller.toggle(.send, on: .recording)
        #expect(!rig.h.controller.isSending && !rig.h.pill.sends)
        #expect(!cues.played.contains(.sendOn))
    }

    /// Hands-free: a click on Send with the talk key down doesn't finish it, and Send sits with Polish in the pill.
    @Test func inHandsFreeItSitsWithPolish() {
        let (rig, _, _) = Self.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .gemini
        c.send(.handsFreeToggle)
        c.handle(.pttDown)
        c.toggle(.send, on: .recording)
        c.handle(.pttUp)
        #expect(c.machine.capture.isListeningOrLocked, "the talk key's press with the click doesn't finish hands-free")
        c.toggle(.polish, on: .recording)
        #expect(c.isSending && c.isPolishing)
        #expect(PillView(model: rig.h.pill).visual == .locked(hours: false, polishes: true, sends: true))
        c.send(.pillCancel)
    }

    /// Return comes once the text is pasted, `returnDelay` after it, and the pill shows the plane until then.
    @Test func returnIsPressedAfterThePaste() async throws {
        let (rig, _, keys) = Self.make()
        let c = rig.h.controller
        c.returnDelay = .milliseconds(120)
        let gate = Gate()
        rig.result = { _, _ in
            await gate.wait()
            return "See you at ten."
        }
        Self.dictateSent(rig)
        try await waitUntil { rig.transcribed.count == 1 }
        #expect(!c.isSending, "the next dictation starts without")
        #expect(rig.h.pill.phase == .processing && rig.h.pill.sends, "the plane stays while it's transcribed")
        #expect(PillView(model: rig.h.pill).visual.sends)
        gate.isOpen = true
        try await waitUntil { keys.returns == 1 && c.machine.activeJobs == 0 }
        #expect(keys.log == ["See you at ten.", "↩"])
        let pastedAt = try #require(keys.pastedAt), returnedAt = try #require(keys.returnedAt)
        #expect(returnedAt - pastedAt >= .milliseconds(120), "Return waits for the paste to land")
        #expect(!rig.h.pill.sends)
        #expect(DictationController.sendReturnDelay == .milliseconds(150))
    }

    /// Send is this dictation's: the next one, without the button, pastes and that's all.
    @Test func itDoesntCarryOverToTheNextDictation() async throws {
        let (rig, _, keys) = Self.make()
        Self.dictateSent(rig)
        try await waitUntil { keys.returns == 1 && rig.h.controller.machine.activeJobs == 0 }
        Switch.hold(rig)
        try await Switch.release(rig)
        try await Task.sleep(for: .milliseconds(60))
        #expect(keys.log == ["See you at ten.", "↩", "See you at ten."])
    }

    /// Nothing pasted, nothing sent: a password field, no Accessibility, a paste that failed.
    @Test(arguments: [InsertionOutcome.passwordField, .accessibilityMissing, .failed("No paste")])
    func returnNeedsThePaste(_ outcome: InsertionOutcome) async throws {
        let (rig, _, keys) = Self.make(outcome: outcome)
        Self.dictateSent(rig)
        try await waitUntil { rig.pasted.count == 1 && rig.h.controller.machine.activeJobs == 0 }
        try await Task.sleep(for: .milliseconds(60))
        #expect(keys.returns == 0)
    }

    /// A transcription that failed or heard nothing sends nothing; a failed one's Retry pastes but doesn't send either.
    @Test func failuresAndSilenceSendNothing() async throws {
        let (rig, _, keys) = Self.make()
        let c = rig.h.controller
        rig.result = { _, engine in throw AppError.timeout(engine) }
        Self.dictateSent(rig)
        try await waitUntil { rig.h.history.entries.first?.status == .failed && c.machine.activeJobs == 0 }
        let notice = try #require(rig.h.toasts.notices.first { $0.actions.contains { $0.kind == .retry } })
        rig.result = { _, _ in "See you at ten." }
        let retry = try #require(notice.actions.first { $0.kind == .retry })
        rig.h.toasts.perform(retry, on: notice)
        try await waitUntil { rig.pasted.count == 1 && c.machine.activeJobs == 0 }
        try await Task.sleep(for: .milliseconds(60))
        #expect(keys.returns == 0, "Retry pastes whenever it comes: no Return after it")

        rig.result = { _, _ in "" }
        Self.dictateSent(rig)
        try await waitUntil { rig.saidNoSpeech && c.machine.activeJobs == 0 }
        try await Task.sleep(for: .milliseconds(60))
        #expect(keys.returns == 0 && rig.pasted.count == 1)
    }

    /// Canceled: nothing is sent. Undo records on with Send still on, and that dictation is sent.
    @Test func undoKeepsSendOn() async throws {
        let (rig, _, keys) = Self.make()
        let c = rig.h.controller
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        Switch.hold(rig)
        c.toggle(.send, on: .recording)
        rig.now += 2
        c.handle(.cancel)
        #expect(!c.isSending)
        rig.now += 1
        try rig.click(.undoCancel, in: "dictation.canceled")
        #expect(c.machine.capture.isListeningOrLocked && c.isSending && rig.h.pill.sends)
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 3)
        rig.now += 1
        c.send(.pillStop)
        try await waitUntil { keys.returns == 1 && c.machine.activeJobs == 0 }
        #expect(keys.log == ["See you at ten.", "↩"])
    }

    /// Paste Last pastes the last transcript, sent or not, and never presses Return.
    @Test func pasteLastNeverSends() async throws {
        let (rig, _, keys) = Self.make()
        let c = rig.h.controller
        var pastedLast: [String] = []
        c.pasteLastOverride = { text in
            pastedLast.append(text)
            return .pasted
        }
        Self.dictateSent(rig)
        try await waitUntil { keys.returns == 1 && c.machine.activeJobs == 0 }
        c.pasteLast()
        try await waitUntil { pastedLast.count == 1 }
        try await Task.sleep(for: .milliseconds(60))
        #expect(keys.returns == 1)
    }
}

// MARK: - Return in the app the text went to

@MainActor
@Suite struct SendReturnTests {
    @MainActor final class Box {
        var frontmost: pid_t? = 42
        var focus = FocusInfo(pid: 42, editability: .editable)
    }

    final class Posted: @unchecked Sendable {
        private let count = OSAllocatedUnfairLock(initialState: 0)
        var value: Int { count.withLock { $0 } }
        func add() { count.withLock { $0 += 1 } }
    }

    private func inserter(_ box: Box, posted: Posted) -> (TextInserter, NSPasteboard) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.transcribe-thing.tests.send.\(UUID().uuidString)"))
        let system = TextInserter.System(
            canPostEvents: { true }, modifiersHeld: { false }, inspectFocus: { await MainActor.run { box.focus } },
            pasteKeyCode: { 9 }, postPaste: { _ in true },
            frontmostApp: { box.frontmost },
            postReturn: {
                posted.add()
                return true
            })
        let inserter = TextInserter(pasteboard: pasteboard, system: system)
        inserter.restoreDelay = .milliseconds(20)
        inserter.unreadTimeout = .milliseconds(100)
        return (inserter, pasteboard)
    }

    @Test func returnGoesToTheAppThePasteWentTo() async {
        let box = Box(), posted = Posted()
        let (inserter, pasteboard) = inserter(box, posted: posted)
        defer { pasteboard.releaseGlobally() }
        #expect(await inserter.pressReturn() == .failed, "no paste to follow")
        #expect(await inserter.insert("See you at ten.") == .pasted)
        #expect(await inserter.pressReturn() == .pressed)
        #expect(posted.value == 1)

        // Another app came to the front since the paste: it gets nothing.
        #expect(await inserter.insert("Again.") == .pasted)
        box.frontmost = 77
        #expect(await inserter.pressReturn() == .appChanged)
        #expect(posted.value == 1)
    }

    /// A paste that didn't happen (a password field) leaves nothing to follow, even after one that did.
    @Test func noReturnAfterAPasteThatDidntHappen() async {
        let box = Box(), posted = Posted()
        let (inserter, pasteboard) = inserter(box, posted: posted)
        defer { pasteboard.releaseGlobally() }
        #expect(await inserter.insert("First.") == .pasted)
        box.focus.isSecure = true
        #expect(await inserter.insert("secret") == .passwordField)
        #expect(await inserter.pressReturn() == .failed)
        #expect(posted.value == 0)
    }

    /// The test harnesses' inserter never posts a key.
    @Test func theInertInserterNeverPressesReturn() async {
        #expect(await TextInserter.inert().pressReturn() == .failed)
    }
}

// MARK: - The pill

@Suite struct SendPillTests {
    private let room = PillMetrics.sendRoom

    /// The plane widens the capsule as the wand does, the bars making room on its left.
    @Test func thePlaneTakesTheWandsRoomOnTheRight() {
        let plain = PillVisual.listening(), sent = PillVisual.listening(sends: true)
        #expect(sent.size.width == plain.size.width + room && sent.size.height == plain.size.height)
        #expect(sent.barsOffset == -room / 2 && sent.sends && !plain.sends)
        let both = PillVisual.listening(polishes: true, sends: true)
        #expect(both.size.width == plain.size.width + PillMetrics.polishWandRoom + room)
        #expect(both.barsOffset == 0, "wand and plane balance")
        #expect(PillMetrics.sendPlaneOffset == -PillMetrics.polishWandOffset)
        // Inside the capsule, as far from its end as the bars are from the other's.
        let planeEnd = sent.barsOffset + PillMetrics.sendPlaneOffset + PillMetrics.counterWandSize / 2
        #expect(abs(sent.size.width / 2 - planeEnd - (PillMetrics.listeningSize.width - PillMetrics.barFieldWidth) / 2) < 0.01)
    }

    /// Hands-free: the bars keep their place beside X, the plane goes between them and the timer.
    @Test func handsFreeKeepsTheBarsBesideX() {
        let locked = PillVisual.locked(), sent = PillVisual.locked(sends: true)
        #expect(sent.size.width == locked.size.width + room)
        #expect(sent.barsOffset == PillMetrics.lockedBarsOffset(hours: false) - room / 2)
        // The bars' distance from the capsule's left end is unchanged.
        #expect(abs((sent.barsOffset + sent.size.width / 2) - (locked.barsOffset + locked.size.width / 2)) < 0.01)
        #expect(PillVisual.locked(hours: true, sends: true).size.width == PillVisual.locked(hours: true).size.width + room)
    }

    /// Processing: the dots settle left of the plane, gliding there from hands-free's bars; the count ends with it.
    @Test func processingAndTheCountKeepThePlane() {
        let afterHandsFree = PillVisual.processing(afterHandsFree: true, sends: true)
        #expect(afterHandsFree.barsOffset == PillMetrics.lockedBarsOffset(hours: false) - room / 2)
        #expect(afterHandsFree.dotsShift == -room / 2)
        #expect(afterHandsFree.size.width == PillVisual.processing(afterHandsFree: true).size.width + room)
        let held = PillVisual.processing(afterHandsFree: false, sends: true)
        #expect(held.barsOffset == -room / 2, "they start where they settle, as the push-to-talk bars stood")
        let polished = PillVisual.processing(afterHandsFree: false, polish: .dictation, sends: true)
        #expect(polished.dotsShift == 0 && polished.size.width == PillMetrics.polishWaveSize.width + room)

        let label = PillCountLabel(number: "~8.8k", word: "thinking")
        let count = PillVisual.processing(afterHandsFree: false, counting: true, label: label, sends: true)
        #expect(count.size.width
                == PillMetrics.counterSize(for: label, polishes: false, sends: true).width)
        #expect(PillMetrics.counterSize(for: label, polishes: false, sends: true).width
                - PillMetrics.counterSize(for: label, polishes: false).width
                >= PillMetrics.sendCounterRoom - 1)
        #expect(PillVisual.processing(afterHandsFree: false, counting: true, sends: true).size.width
                == PillMetrics.counterSize.width + PillMetrics.sendCounterRoom)
    }

    /// The pill model's flag reaches every phase that shows a dictation; a selection's polish is never sent.
    @Test @MainActor func theModelsFlagReachesTheVisual() {
        let listening = PillModel.preview(phase: .listening)
        listening.sends = true
        #expect(PillView(model: listening).visual == .listening(sends: true))
        let processing = PillModel.preview(phase: .processing)
        processing.sends = true
        #expect(PillView(model: processing).visual.sends)
        processing.polishes = true
        processing.selectionPolishing = true
        #expect(!PillView(model: processing).visual.sends)
    }
}

// MARK: - The sound

@MainActor
@Suite struct SendSoundTests {
    /// Its own on cue, a key's feedback like Polish's drops (dropped when it would come late), one voice.
    @Test func sendOnIsKeyFeedback() {
        #expect(CueEngine.keyFeedback.contains(.sendOn))
        #expect(AVCueOutput.voices(for: .sendOn) == 1)
        #expect(SoundPlayer.nominalDurations[.sendOn] == 0.155)
    }
}
