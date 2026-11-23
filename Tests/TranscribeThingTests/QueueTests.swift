import Foundation
import Testing
@testable import TranscribeThing

// MARK: - A text that waits its turn: "ready", Paste now, and Send on the newest only

@MainActor
@Suite(.serialized) struct QueueTests {
    typealias R = ProcessingRig
    typealias Switch = SwitchModelControllerTests

    /// The first dictation on Gemini, whose request waits on `gemini`, then a second on GigaAM, whose text is there
    /// at once. The second's pill is the bottom one; the first stands above it.
    static func geminiThenGigaAM(_ gemini: RequestGate) async throws -> (R.Rig, Switch.Cues, Requests) {
        let (rig, cues, requests) = R.make { engine, prompt, _ in
            guard engine.isGemini else { return "gigaam words" }
            try await gemini.wait()
            return R.gemini(prompt)
        }
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        rig.h.settings.lineup.main = .gigaam
        R.dictate(rig)
        try await waitUntil { requests.gigaam == 1 }
        return (rig, cues, requests)
    }

    /// GigaAM's text waits for Gemini's above it: its pill says "ready" instead of the wave, its tray has Paste now,
    /// and Gemini's pill above still works on. Once Gemini answers, both go in, in the order they were recorded.
    @Test func aTextThatWaitsSaysReady() async throws {
        let gemini = RequestGate()
        let (rig, _, _) = try await Self.geminiThenGigaAM(gemini)
        let c = rig.h.controller
        try await waitUntil { rig.h.pill.isReady }
        #expect(rig.pasted.isEmpty, "it waits for the first")
        #expect(rig.h.pill.tray?.canPasteNow == true && rig.h.pill.tray?.buttons.first == .pasteNow)
        let stacked = try #require(rig.h.pill.stack.first)
        #expect(!stacked.isReady && !stacked.tray.canPasteNow, "the first is still being written")
        #expect(rig.h.pill.stackModels[stacked.key]?.isReady == false)
        #expect(PillView(model: rig.h.pill).visual == .ready)
        gemini.isOpen = true
        try await waitUntil { rig.pasted == ["plain words", "gigaam words"] && c.machine.activeJobs == 0 }
        #expect(!rig.h.pill.isReady)
    }

    /// A text pasted the moment it comes never says "ready", not even while its Return waits.
    @Test func aTextPastedAtOnceNeverSaysReady() async throws {
        let (rig, _, requests) = R.make { _, _, _ in "gigaam words" }
        rig.h.settings.lineup.main = .gigaam
        let c = rig.h.controller
        var returns = 0
        c.returnDelay = .milliseconds(300)
        c.pressReturnOverride = { returns += 1; return .pressed }
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        Switch.hold(rig)
        c.toggle(.send, on: .recording)
        rig.now += 2
        c.handle(.pttUp)
        try await waitUntil { requests.gigaam == 1 && rig.pasted.count == 1 }
        #expect(c.machine.activeJobs == 1, "its Return still waits")
        #expect(!rig.h.pill.isReady && rig.h.pill.tray?.canPasteNow != true)
        try await waitUntil { returns == 1 && c.machine.activeJobs == 0 }
    }

    /// Paste now pastes the ready text at once, ahead of the one above, with its Return; the older one follows when
    /// its text comes, and its pill comes down to the bottom meanwhile.
    @Test func pasteNowGoesAheadOfTheOlderOne() async throws {
        let gemini = RequestGate()
        let (rig, _, _) = try await Self.geminiThenGigaAM(gemini)
        let c = rig.h.controller
        var returns = 0
        c.returnDelay = .milliseconds(5)
        c.pressReturnOverride = { returns += 1; return .pressed }
        try await waitUntil { rig.h.pill.isReady }
        rig.h.pill.clickTray(.send)
        rig.h.pill.clickTray(.pasteNow)
        try await waitUntil { rig.pasted == ["gigaam words"] && returns == 1 }
        try await waitUntil { rig.h.pill.stack.isEmpty && rig.h.pill.sessionModel == .gemini }
        #expect(!rig.h.pill.isReady && c.machine.activeJobs == 1, "the older one is still on its way")
        gemini.isOpen = true
        try await waitUntil { rig.pasted == ["gigaam words", "plain words"] && c.machine.activeJobs == 0 }
        #expect(returns == 1, "the older one had no Send")
    }

    /// Paste now does nothing on a dictation still being written, or on one a click away holds.
    @Test func pasteNowOnlyOnAReadyTextThatWouldBePasted() async throws {
        let gemini = RequestGate()
        let (rig, _, _) = try await Self.geminiThenGigaAM(gemini)
        let c = rig.h.controller
        let stacked = try #require(rig.h.pill.stack.first)
        rig.h.pill.onToggle?(.pasteNow, stacked.tray.dictation)
        try await waitUntil { rig.h.pill.isReady }
        c.clickedAway()
        #expect(rig.h.pill.holdsPaste && rig.h.pill.isReady && rig.h.pill.tray?.canPasteNow == false)
        rig.h.pill.clickTray(.pasteNow)
        try await Task.sleep(for: .milliseconds(60))
        #expect(rig.pasted.isEmpty && c.machine.activeJobs == 2)
        gemini.isOpen = true
        try await waitUntil { c.machine.activeJobs == 0 }
    }

    /// Send on the newest turns it off on every older one, with Send's one sound: Return goes once, after the last
    /// paste. Send on an older one leaves the newer one's.
    @Test func sendOnTheNewestTurnsItOffOnOlderOnes() async throws {
        let first = RequestGate(), second = RequestGate()
        let (rig, cues, requests) = DictationsAlongsideTests.make([1: first, 2: second])
        let c = rig.h.controller
        var returns = 0
        c.returnDelay = .milliseconds(5)
        c.pressReturnOverride = { returns += 1; return .pressed }
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        rig.h.pill.clickTray(.send)
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 2 }
        #expect(rig.h.pill.stack.first?.tray.sends == true && !rig.h.pill.sends, "a new dictation leaves it")
        let played = cues.played
        rig.h.pill.clickTray(.send)
        #expect(rig.h.pill.sends && rig.h.pill.stack.first?.tray.sends == false)
        #expect(cues.played == played + [.sendOn], "one sound")
        let older = try #require(rig.h.pill.stack.first)
        rig.h.pill.onToggle?(.send, older.tray.dictation)
        #expect(rig.h.pill.stack.first?.tray.sends == true && rig.h.pill.sends, "a newer one keeps its Send")
        rig.h.pill.onToggle?(.send, older.tray.dictation)
        first.isOpen = true
        second.isOpen = true
        try await waitUntil { rig.pasted.count == 2 && c.machine.activeJobs == 0 }
        #expect(returns == 1)
    }

    /// Send turned on while a new dictation records turns it off on the ones on their way.
    @Test func sendWhileRecordingTurnsItOffOnTheOnesOnTheirWay() async throws {
        let first = RequestGate()
        let (rig, _, requests) = DictationsAlongsideTests.make([1: first])
        let c = rig.h.controller
        var returns = 0
        c.returnDelay = .milliseconds(5)
        c.pressReturnOverride = { returns += 1; return .pressed }
        R.dictate(rig)
        try await waitUntil { requests.gemini.count == 1 }
        rig.h.pill.clickTray(.send)
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 2)
        Switch.hold(rig)
        #expect(rig.h.pill.stack.first?.tray.sends == true)
        c.toggle(.send, on: .recording)
        #expect(rig.h.pill.sends && rig.h.pill.stack.first?.tray.sends == false)
        rig.now += 2
        c.handle(.pttUp)
        try await waitUntil { requests.gemini.count == 2 }
        first.isOpen = true
        try await waitUntil { rig.pasted.count == 2 && c.machine.activeJobs == 0 }
        #expect(returns == 1)
    }
}
