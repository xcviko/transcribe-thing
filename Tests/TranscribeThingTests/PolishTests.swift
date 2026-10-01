import Foundation
import Testing
@testable import TranscribeThing

@MainActor
@Suite(.serialized) struct PolishControllerTests {
    typealias Rig = DictationResumeTests.Rig
    typealias Switch = SwitchModelControllerTests

    /// fn ↩ while holding turns Polish on for this dictation with a rising drop, and off again with a falling one;
    /// the pill shows it, and the next dictation starts without.
    @Test func thePolishKeysTurnItOnAndOff() async throws {
        let (rig, cues) = Switch.make()
        let c = rig.h.controller
        Switch.hold(rig)
        c.handle(.polish(.oneRequest))
        #expect(c.polishMode == .oneRequest && rig.h.pill.polishMode == .oneRequest)
        #expect(rig.h.pill.sessionModel == .gemini, "the audio goes to Gemini: the pill wears its color")
        c.handle(.polish(.oneRequest))
        #expect(c.polishMode == nil && rig.h.pill.polishMode == nil)
        c.handle(.polish(.twoSteps))
        #expect(c.polishMode == .twoSteps)
        #expect(cues.played.suffix(3) == [.polishOn, .polishOff, .polishOn])
        #expect(c.machine.capture.isListeningOrLocked, "it never stops the recording")
        c.send(.pillCancel)
        #expect(c.polishMode == nil)
    }

    /// One request: the audio goes to Gemini with the polish prompt, what its <message> tags hold is pasted, and
    /// History keeps it as the polished version.
    @Test func oneRequestSendsTheAudioToGeminiAndPastesTheMessage() async throws {
        let (rig, _) = Switch.make()
        let c = rig.h.controller
        var engines: [EngineID] = []
        rig.result = { _, engine in
            engines.append(engine)
            return "- thinking it over\n<message>Polished.</message>"
        }
        Switch.hold(rig)
        c.handle(.polish(.oneRequest))
        try await Switch.release(rig)
        #expect(engines == [.geminiFlash])
        #expect(rig.pasted == ["Polished."])
        let entry = try #require(rig.h.history.entries.first)
        #expect(entry.engine == .geminiFlash)
        #expect(entry.versions.map(\.kind) == [.polish(of: nil)])
    }

    /// Two steps: transcribed as usual, then the text is polished (in place of a clean-up); both versions stay.
    @Test func twoStepsPolishTheTranscriptAndKeepIt() async throws {
        let (rig, _) = Switch.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .cleanup
        rig.result = { _, _ in "so um the plan is no wait the plan is Friday" }
        var asked: [String] = []
        c.cleanupOverride = { _, _ in
            Issue.record("polish takes clean-up's place")
            return TranscriptResult(text: "x", engine: .parakeet, processingTime: 0)
        }
        c.polishOverride = { text, source in
            asked.append(text)
            return TranscriptResult(text: "The plan is Friday.", engine: source, processingTime: 0.1)
        }
        Switch.hold(rig)
        c.handle(.polish(.twoSteps))
        try await Switch.release(rig)
        #expect(asked == ["so um the plan is no wait the plan is Friday"])
        #expect(rig.pasted == ["The plan is Friday."])
        let entry = try #require(rig.h.history.entries.first)
        #expect(entry.versions.map(\.kind) == [.transcription(.parakeet), .polish(of: .parakeet)])
        #expect(entry.currentKind == .polish(of: .parakeet))
    }

    /// A second step that fails pastes the transcript, and says so.
    @Test func aFailedPolishPastesTheTranscript() async throws {
        let (rig, _) = Switch.make()
        let c = rig.h.controller
        rig.result = { _, _ in "the transcript" }
        c.polishOverride = { _, _ in throw AppError.offline }
        Switch.hold(rig)
        c.handle(.polish(.twoSteps))
        try await Switch.release(rig)
        #expect(rig.pasted == ["the transcript"])
        #expect(rig.notice("polish.fallback")?.title == "Couldn’t polish · pasted the transcript")
        #expect(rig.h.history.entries.first?.versions.map(\.kind) == [.transcription(.parakeet)])
    }

    /// Polish goes through Gemini: without a key it's refused as Switch model would refuse Gemini.
    @Test func withoutAKeyPolishIsRefused() {
        let (rig, cues) = Switch.make(key: .missing)
        let shakes = rig.h.pill.shakeCount
        Switch.hold(rig)
        rig.h.controller.handle(.polish(.oneRequest))
        #expect(rig.h.controller.polishMode == nil)
        #expect(rig.h.pill.shakeCount == shakes + 1)
        #expect(!cues.played.contains(.polishOn))
        rig.h.controller.send(.pillCancel)
    }

    /// In hands-free, fn ↩'s fn press was for polishing: its release doesn't finish the dictation.
    @Test func inHandsFreeThePolishKeysKeepRecording() {
        let (rig, _) = Switch.make()
        let c = rig.h.controller
        c.send(.handsFreeToggle)
        c.handle(.pttDown)
        c.handle(.polish(.oneRequest))
        c.handle(.pttUp)
        #expect(c.machine.capture.isListeningOrLocked)
        #expect(c.polishMode == .oneRequest)
        c.send(.pillCancel)
    }
}

@Suite struct PolishTests {
    @Test func theMessageIsWhatTheLastTagsHold() {
        #expect(Polish.message(from: "<message>Hi.</message>") == "Hi.")
        #expect(Polish.message(from: "draft <message>a</message> better <message>b</message>") == "b")
        #expect(Polish.message(from: "No tags.") == "No tags.")
    }

    @Test func bothPromptsAskForTheMessageTags() {
        for prompt in [Polish.audioPrompt, Polish.textPrompt] {
            #expect(prompt.contains(Polish.open) && prompt.contains(Polish.close))
            #expect(!prompt.contains("\u{2014}") || prompt.contains("instead of \"\u{2014}\"") || prompt.contains("вместо \"\u{2014}\""))
        }
    }

    @Test func polishedVersionsRoundTrip() {
        for kind in [TranscriptVersionKind.polish(of: nil), .polish(of: .parakeet), .polish(of: .parakeetCloud)] {
            #expect(TranscriptVersionKind(rawValue: kind.rawValue) == kind)
            #expect(!kind.isReadableByOlderBuilds)
        }
        #expect(TranscriptVersionKind.polish(of: nil).rawValue == "polish")
        #expect(TranscriptVersionKind.polish(of: .parakeet).displayName == "Parakeet v3 + Polish by Gemini Flash")
    }
}
