import Foundation
import Testing
@testable import TranscribeThing

// MARK: - Prompts and versions

@Suite struct TranslatePromptTests {
    @Test func theRuleGoesBothWaysAndSendsAnythingElseToTheSecond() {
        #expect(Translate.rule(.default, audio: true)
                == "if I speak Russian, translate into English; if I speak English, translate into Russian; "
                + "if I speak any other language, translate into English")
        let pair = TranslationPair(first: .german, second: .japanese)
        #expect(Translate.rule(pair, audio: false)
                == "if the text is in German, translate it into Japanese; if the text is in Japanese, translate it "
                + "into German; if the text is in any other language, translate it into Japanese")
    }

    /// Gemini's translation comes in its usual tags; Polish translated keeps Polish's tags and drops its "never
    /// translate".
    @Test func eachPromptAsksForItsTagsAndTheRule() {
        let rule = Translate.rule(.default, audio: true)
        let plain = Translate.prompt(.default)
        #expect(plain.contains("<transcript>") && plain.contains("</transcript>") && plain.contains(rule))
        #expect(!plain.contains("never translate"))
        #expect(EngineID.geminiSystemPrompt.contains("never translate"))
        let polished = Translate.polishedPrompt(.default)
        #expect(Polish.prompt.contains(Translate.polishFirstParagraphEnd))
        #expect(Polish.prompt.contains(Translate.polishKeepsLanguage))
        #expect(Polish.prompt.contains("never translate"))
        #expect(polished.contains(rule) && polished.contains(Polish.open) && polished.contains(Polish.close))
        #expect(polished.contains(Translate.polishFirstParagraphEnd + " Write it translated: " + rule + "."))
        #expect(polished.contains(Translate.polishKeepsLanguageTranslated))
        #expect(!polished.contains("never translate"))
        let text = Translate.textPrompt(.default)
        #expect(text.contains(Translate.rule(.default, audio: false)) && text.contains(Polish.open))
    }

    @Test func translationVersionsRoundTrip() throws {
        for kind: TranscriptVersionKind in [.translation(polished: false), .translation(polished: true),
                                            .translation(polished: false, by: .geminiArgon),
                                            .translation(polished: true, by: .geminiArgon),
                                            .polish(by: .geminiArgon), .selectionTranslation(.geminiFlash)] {
            #expect(TranscriptVersionKind(rawValue: kind.rawValue) == kind)
            let data = try JSONEncoder().encode(kind)
            #expect(try JSONDecoder().decode(TranscriptVersionKind.self, from: data) == kind)
        }
        #expect(TranscriptVersionKind.selectionTranslation(.geminiFlash).isSelection)
        #expect(!TranscriptVersionKind.translation(polished: false).isSelection)
        #expect(TranscriptVersionKind.translation(polished: true).answersInMessageTags)
        #expect(!TranscriptVersionKind.translation(polished: false).answersInMessageTags)
        #expect(TranscriptVersionKind.translation(polished: true).displayName
                == "Polished and translated by Gemini 3.8 Flash")
        // Flash's keep the raw values older builds wrote; another Gemini's carry the model, as the retired Gemini 4
        // Argon's in History do.
        #expect(TranscriptVersionKind.translation(polished: true).rawValue == "translation:polished")
        #expect(TranscriptVersionKind.translation(polished: false, by: .geminiArgon).rawValue == "translation:geminiArgon")
        #expect(TranscriptVersionKind.translation(polished: true, by: .geminiArgon).rawValue
                == "translation:polished:geminiArgon")
        #expect(TranscriptVersionKind.polish(by: .geminiArgon).rawValue == "polish:geminiArgon")
        #expect(TranscriptVersionKind(rawValue: "polish:someFutureModel") == nil)
        #expect(TranscriptVersionKind(rawValue: "translation:junk:geminiArgon") == nil)
        #expect(TranscriptVersionKind.translation(polished: false, by: .geminiArgon).displayName
                == "Translated by Gemini 4 Argon")
        #expect(TranscriptVersionKind.polish(by: .geminiArgon).progressTitle == "Polishing with Gemini 4 Argon…")
        #expect(TranscriptVersionKind.polish(by: .geminiArgon).engine == .geminiArgon)
        #expect(TranscriptVersionKind.translation(polished: true, by: .geminiArgon).answersInMessageTags)
    }

    @Test func whatGeminiWritesFollowsBothKeys() {
        #expect(DictationController.rewriteKind(polishes: false, translates: false) == nil)
        #expect(DictationController.rewriteKind(polishes: true, translates: false) == .polish())
        #expect(DictationController.rewriteKind(polishes: false, translates: true) == .translation(polished: false))
        #expect(DictationController.rewriteKind(polishes: true, translates: true) == .translation(polished: true))
    }

    @Test func fnTIsTheDefault() {
        #expect(ShortcutBindings.defaults[.translate] == .fnT)
        #expect(ShortcutAction.translate.isDuringDictation)
    }

    @Test func theMachineHandsTheKeyOnWithoutStoppingTheRecording() {
        var machine = DictationMachine()
        _ = machine.handle(.handsFreeToggle, now: 0)
        _ = machine.handle(.pttDown, now: 1)
        #expect(machine.handle(.translate, now: 1.1) == [.translate])
        _ = machine.handle(.pttUp, now: 1.2)
        #expect(machine.capture.isListeningOrLocked, "fn T's fn press doesn't finish hands-free")
    }
}

/// A Gemini model ignored short audio and made text up when the system prompt was Russian, so every dictation prompt
/// is written in English: Russian may appear only inside quoted examples ("или или" -> "или").
@Suite struct DictationPromptLanguageTests {
    /// `prompt` without its quoted spans ("...", on one line).
    static func instructions(_ prompt: String) -> String {
        prompt.replacingOccurrences(of: #""[^"\n]*""#, with: "", options: .regularExpression)
    }

    static func hasCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    static var prompts: [(String, String)] {
        var prompts = [("transcription", EngineID.geminiSystemPrompt), ("Polish", Polish.prompt),
                       ("Polish Selection", Polish.textPrompt)]
        for first in TranslationLanguage.allCases {
            for second in TranslationLanguage.allCases where second != first {
                let pair = TranslationPair(first: first, second: second)
                prompts += [("Translate \(pair.title)", Translate.prompt(pair)),
                            ("Polish translated \(pair.title)", Translate.polishedPrompt(pair)),
                            ("Translate Selection \(pair.title)", Translate.textPrompt(pair))]
            }
        }
        return prompts.flatMap { name, prompt in
            [(name, prompt),
             (name + " with the dictionary", UserDictionary.prompt(prompt, with: ["Wispr Flow"], heard: true)),
             (name + " with the dictionary, read", UserDictionary.prompt(prompt, with: ["Wispr Flow"], heard: false))]
        }
    }

    @Test func noDictationPromptHasRussianOutsideItsQuotedExamples() {
        for (name, prompt) in Self.prompts {
            #expect(!Self.hasCyrillic(Self.instructions(prompt)), "\(name) has Russian instructions")
        }
        // The check sees Russian when it's there, and leaves quoted examples alone.
        #expect(Self.hasCyrillic(Self.instructions("Расшифруй это аудио.")))
        #expect(!Self.hasCyrillic(Self.instructions(#"Keep doubts ("наверное", "я хз") as said."#)))
        #expect(Self.hasCyrillic(EngineID.geminiSystemPrompt), "the Russian examples are still there")
    }
}

// MARK: - Dictation

@MainActor
@Suite(.serialized) struct TranslateControllerTests {
    typealias Switch = SwitchModelControllerTests

    @Test func theTranslateKeyTurnsItOnAndOffOnGemini() {
        let (rig, cues) = Switch.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .gemini
        Switch.hold(rig)
        c.handle(.translate)
        #expect(c.isTranslating && rig.h.pill.translates && rig.h.pill.rewrite == .translate)
        c.handle(.polish)
        #expect(rig.h.pill.rewrite == .both)
        c.handle(.translate)
        #expect(!c.isTranslating && rig.h.pill.rewrite == .polish)
        #expect(cues.played.suffix(3) == [.polishOn, .polishOn, .polishOff])
        #expect(c.machine.capture.isListeningOrLocked)
        c.send(.pillCancel)
        #expect(!c.isTranslating && !c.isPolishing)
    }

    @Test func leavingGeminiTurnsItOff() {
        let (rig, _) = Switch.make()
        let c = rig.h.controller
        Switch.hold(rig)
        c.selectModelForCurrentDictation(.gemini)
        c.handle(.translate)
        #expect(c.isTranslating)
        c.selectModelForCurrentDictation(.parakeet)
        #expect(!c.isTranslating)
        c.send(.pillCancel)
    }

    /// The translation is pasted as Gemini wrote it, and History keeps it as the translated version.
    @Test func aTranslatedDictationPastesTheTranslation() async throws {
        let (rig, _) = Switch.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .gemini
        rig.result = { _, _ in "Let's meet at ten." }
        Switch.hold(rig)
        c.handle(.translate)
        try await Switch.release(rig)
        #expect(rig.pasted == ["Let's meet at ten."])
        let entry = try #require(rig.h.history.entries.first)
        #expect(entry.versions.map(\.kind) == [.translation(polished: false)])
    }

    /// Polish and Translate both on: the message in its tags, translated.
    @Test func polishedAndTranslatedPastesTheMessage() async throws {
        let (rig, _) = Switch.make()
        let c = rig.h.controller
        rig.h.settings.lineup.main = .gemini
        rig.result = { _, _ in "drafting <message>See you at ten.</message>" }
        Switch.hold(rig)
        c.handle(.polish)
        c.handle(.translate)
        try await Switch.release(rig)
        #expect(rig.pasted == ["See you at ten."])
        #expect(rig.h.history.entries.first?.versions.map(\.kind) == [.translation(polished: true)])
    }

    /// The prompt follows General → Translate's pair.
    @Test func thePromptUsesThePair() {
        let (rig, _) = Switch.make()
        let c = rig.h.controller
        rig.h.settings.translationPair = TranslationPair(first: .spanish, second: .english)
        let prompt = c.geminiPrompt(for: .translation(polished: false)) ?? ""
        #expect(prompt.contains("if I speak Spanish, translate into English"))
        #expect(c.geminiPrompt(for: .transcription(.geminiFlash)) == nil)
    }

    /// From History: Translate with Gemini makes a translated version of the recording.
    @Test func historyTranslatesARecording() async throws {
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
        rig.result = { _, _ in "In English." }
        c.makeVersion(.translation(polished: false), of: failed)
        try await waitUntil { rig.h.history.entries.first?.status == .success }
        let entry = try #require(rig.h.history.entries.first)
        #expect(entry.text == "In English." && entry.versions.map(\.kind) == [.translation(polished: false)])
    }
}

// MARK: - Selected text

@MainActor
@Suite(.serialized) struct TranslateSelectionTests {
    typealias Switch = SwitchModelControllerTests

    /// Off Gemini, the translate key over a selection: the dictation gives way, and Gemini's translation comes up on a
    /// card, kept in History as the selection's translation.
    @Test func theSelectionIsTranslatedOnACard() async throws {
        let (rig, _, asked) = PolishSelectionTests.make(
            selection: "привет, как дела", answers: [.geminiFlash: "<message>Hi, how are you?</message>"])
        Switch.hold(rig)
        try await waitUntil { rig.h.controller.machine.isRecording }
        rig.h.controller.handle(.translate)
        try await waitUntil { PolishSelectionTests.card(rig, .geminiFlash) != nil }
        let card = try #require(PolishSelectionTests.card(rig, .geminiFlash))
        #expect(card.title == "Translated by Gemini 3.8 Flash" && card.transcript == "Hi, how are you?")
        #expect(asked.calls.map(\.0) == ["привет, как дела"])
        let entry = try #require(rig.h.history.entries.first { $0.isSelection })
        #expect(entry.versions.map(\.kind) == [.selectionTranslation(.geminiFlash)])
        #expect(rig.pasted.isEmpty)
    }

    /// While the selection is being translated the app says so (the menu bar reads "Translating", not "Polishing"),
    /// and Esc stops it.
    @Test func translatingASelectionIsTheAppsActivity() async throws {
        let (rig, _, asked) = PolishSelectionTests.make(selection: "привет")
        asked.hold(.geminiFlash)
        Switch.hold(rig)
        try await waitUntil { rig.h.controller.machine.isRecording }
        rig.h.controller.handle(.translate)
        try await waitUntil { asked.calls.count == 1 }
        #expect(rig.h.controller.activity == .translating)
        rig.h.controller.handle(.cardClose)
        #expect(rig.h.controller.activity == .idle)
        asked.release(.geminiFlash)
    }

    /// Nothing selected, off Gemini: the key says where Translate works; the dictation goes on.
    @Test func withoutASelectionTheKeySaysWhereItWorks() async throws {
        let (rig, _, asked) = PolishSelectionTests.make(selection: nil)
        Switch.hold(rig)
        rig.h.controller.handle(.translate)
        try await waitUntil { rig.h.pill.keyHint != nil }
        #expect(rig.h.pill.keyHint == "Translate works on Gemini, or on selected text")
        #expect(asked.calls.isEmpty && rig.h.controller.machine.isRecording)
        rig.h.controller.send(.pillCancel)
    }

    /// On Gemini the key is the dictation's: the selection is left alone.
    @Test func onGeminiTheKeyTranslatesTheDictation() async throws {
        let (rig, _, asked) = PolishSelectionTests.make()
        rig.h.settings.lineup.main = .gemini
        Switch.hold(rig)
        try await waitUntil { rig.h.controller.machine.isRecording }
        rig.h.controller.handle(.translate)
        #expect(rig.h.controller.isTranslating && asked.calls.isEmpty)
        rig.h.controller.send(.pillCancel)
    }
}
