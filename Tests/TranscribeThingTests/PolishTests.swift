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

    /// Held down, fn ↩ turns Polish on and off at every autorepeat, each with its drop's sound.
    @Test func holdingThePolishKeyFlipsItOnEveryRepeat() {
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
