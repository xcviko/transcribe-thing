import Carbon.HIToolbox
import Foundation
import Testing
@testable import TranscribeThing

// MARK: - The dictionary itself

@Suite struct UserDictionaryTests {
    /// A selection picks up spaces, quotes, its sentence's end and brackets it cut off: they stay out. A term keeps
    /// its own punctuation.
    @Test(arguments: [("Wispr,", "Wispr"), ("  «Flow»\n", "Flow"), ("Gemini  3.8\tFlash.", "Gemini 3.8 Flash"),
                      ("(GPT-6 Luna).", "GPT-6 Luna"), ("Мелания Трамп!", "Мелания Трамп"), (".NET", ".NET"),
                      ("U.S.", "U.S."), ("Ph.D.", "Ph.D."), ("f(x)", "f(x)"), ("Ubuntu (LTS)", "Ubuntu (LTS)"),
                      ("LTS)", "LTS"), ("“Node.js”.", "Node.js")])
    func aSelectionBecomesTheWord(_ selected: String, _ word: String) {
        #expect(UserDictionary.normalized(selected) == word)
    }

    /// Typed by hand, only the spaces around it go: "Yahoo!" is the name.
    @Test func aTypedWordKeepsItsPunctuation() {
        #expect(UserDictionary.normalized("  Yahoo! ", typed: true) == "Yahoo!")
        #expect(UserDictionary.normalized("Yahoo!") == "Yahoo")
    }

    @Test func whatIsntAWordSaysWhy() {
        #expect(UserDictionary.validated("two\nlines") == .failure(.lines))
        #expect(UserDictionary.validated(" ,. ") == .failure(.empty))
        #expect(UserDictionary.validated("<b>Tag</b>") == .failure(.tags))
        #expect(UserDictionary.normalized(String(repeating: "a", count: UserDictionary.maxLength)) != nil)
        #expect(UserDictionary.validated(String(repeating: "a", count: UserDictionary.maxLength + 1)) == .failure(.tooLong))
    }

    /// Each word once, whatever its capitals; the newer spelling wins, at the end, and says what it replaced.
    /// Other letters make another word ("все" and "всё").
    @Test func wordsComeOnce() {
        var dictionary = UserDictionary()
        #expect(dictionary.add("Wispr") == .added("Wispr"))
        #expect(dictionary.add("Flow") == .added("Flow"))
        #expect(dictionary.add("wispr.") == .added("wispr", replacing: "Wispr"))
        #expect(dictionary.words == ["Flow", "wispr"])
        #expect(dictionary.add("wispr") == .alreadyThere("wispr"))
        #expect(dictionary.add("\n") == .invalid(.empty))
        #expect(dictionary.add("всё") == .added("всё") && dictionary.add("все") == .added("все"))
        dictionary.remove("WISPR")
        #expect(dictionary.words.contains("wispr"), "removing takes the exact spelling")
        dictionary.remove("wispr")
        #expect(dictionary.words == ["Flow", "всё", "все"])
    }

    @Test func theOldestGoPastTheLimit() {
        let dictionary = UserDictionary(words: (0...UserDictionary.maxCount).map { "word\($0)" })
        #expect(dictionary.words.count == UserDictionary.maxCount)
        #expect(dictionary.words.first == "word1")
    }

    @Test func itStoresAsAListAndReadsLeniently() throws {
        let dictionary = UserDictionary(words: ["Wispr", "Flow"])
        let data = try JSONEncoder().encode(dictionary)
        #expect(String(decoding: data, as: UTF8.self) == #"["Wispr","Flow"]"#)
        #expect(try JSONDecoder().decode(UserDictionary.self, from: data) == dictionary)
        let odd = #"["ok", "two\nlines", "ok"]"#
        #expect(try JSONDecoder().decode(UserDictionary.self, from: Data(odd.utf8)).words == ["ok"])
        #expect(try JSONDecoder().decode(UserDictionary.self, from: Data("{}".utf8)).words.isEmpty)
    }

    /// The words go after the prompt, in its language, for what the model has: audio it hears or text it reads.
    @Test func thePromptGetsTheWordsInItsLanguage() {
        #expect(UserDictionary.prompt("Prompt.", with: [], heard: true) == "Prompt.")
        #expect(UserDictionary.prompt("", with: ["Wispr"], heard: true) == "", "the CLI's empty prompt sends only the audio")
        let gemini = UserDictionary.prompt(EngineID.geminiSystemPrompt, with: ["Wispr", "Flow"], heard: true)
        #expect(gemini.hasPrefix(EngineID.geminiSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(gemini.contains("Подсказка") && gemini.contains("Если услышишь") && gemini.contains("Решай сам"))
        #expect(gemini.hasSuffix("<dictionary>\nWispr\nFlow\n</dictionary>"))
        let selection = UserDictionary.prompt(Polish.textPrompt, with: ["Wispr"], heard: false)
        #expect(selection.contains("Если встретишь в тексте"))
        let cleanup = UserDictionary.prompt(CleanupModel.systemPrompt, with: ["Wispr"], heard: false)
        #expect(cleanup.contains("A hint") && cleanup.contains("Use your judgment"))
    }

    @MainActor @Test func itPersistsInTheSettings() throws {
        let suite = "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.dictionary.words.isEmpty)
        settings.dictionary.add("Wispr Flow")
        #expect(AppSettings(defaults: defaults).dictionary.words == ["Wispr Flow"])
        #expect(ShortcutBindings.defaults[.addToDictionary] == .fnD)
    }
}

// MARK: - What the models get

@MainActor
@Suite struct DictionaryPromptTests {
    private func service(_ replies: [StubURLProtocol.Reply], words: [String]) -> (TranscriptionService, String) {
        let (client, host) = StubURLProtocol.client(replies)
        let account = OpenRouterAccount(keyStore: KeyFileStore.inMemory("sk-or-v1-test"), client: client, debounce: .zero)
        let service = TranscriptionService(models: .preview(states: [.parakeet: .ready]), account: account,
                                           client: client, providerLookupDelay: .milliseconds(10))
        service.vocabulary = { words }
        return (service, host)
    }

    private func systemMessage(_ host: String) throws -> String {
        let body = try #require(StubURLProtocol.registry.bodies(for: host).first)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try #require((json["messages"] as? [[String: Any]])?.first?["content"] as? String)
    }

    @Test func geminiHearsWithTheDictionary() async throws {
        let (service, host) = service([.stream(SSE.answer("<transcript>Wispr Flow.</transcript>",
                                                          model: "google/gemini-3.8-flash"))], words: ["Wispr Flow"])
        let samples = (0..<16_000).map { 0.1 * sin(Float($0) * 0.09) }
        _ = try await service.transcribe(Recording(samples: samples), engine: .geminiFlash)
        let prompt = try systemMessage(host)
        #expect(prompt.hasPrefix("Я пришлю тебе аудио") && prompt.hasSuffix("<dictionary>\nWispr Flow\n</dictionary>"))
    }

    @Test func lunaCleansUpWithTheDictionary() async throws {
        let (service, host) = service([.stream(SSE.answer("Wispr Flow.", model: "openai/gpt-6-luna"))],
                                      words: ["Wispr Flow"])
        _ = try await service.cleanUp("виспр флоу", of: .parakeet)
        let prompt = try systemMessage(host)
        #expect(prompt.hasPrefix("Clean up the transcript") && prompt.contains("<dictionary>\nWispr Flow\n</dictionary>"))
    }

    @Test func anEmptyDictionaryLeavesThePromptAlone() async throws {
        let (service, host) = service([.stream(SSE.answer("Hi.", model: "openai/gpt-6-luna"))], words: [])
        _ = try await service.cleanUp("hi", of: .parakeet)
        #expect(try systemMessage(host) == CleanupModel.systemPrompt)
    }
}

// MARK: - fn D

@MainActor
@Suite(.serialized) struct AddToDictionaryTests {
    typealias Switch = SwitchModelControllerTests
    static let d = KeyStroke(keyCode: UInt16(kVK_ANSI_D), flags: 0, interruptsHold: true)

    static func make(selection: String? = "Wispr Flow", key: KeyStatus = .valid(KeyInfo()))
        -> (SwitchModelControllerTests.Rig, SwitchModelControllerTests.Cues) {
        let (rig, cues) = Switch.make(key: key)
        rig.h.controller.start()
        rig.h.controller.playCueOverride = { cues.played.append($0) }
        rig.h.controller.selectionOverride = { selection }
        return (rig, cues)
    }

    /// fn D as the tap gives it: held, for the controller to read what's selected right then.
    static func pressD(_ rig: SwitchModelControllerTests.Rig) {
        rig.h.controller.handle(.heldForSelection(.addToDictionary, d))
    }

    /// Holding the key over a selection offers both: Polish Selection and the dictionary.
    @Test func theHintOffersBoth() async throws {
        let (rig, _) = Self.make()
        Switch.hold(rig)
        try await waitUntil { rig.h.pill.selectionHint == .shown }
        #expect(rig.h.pill.selectionOffer == PillSelectionOffer(polish: true, dictionary: true))
        #expect(rig.h.controller.polishesSelection && rig.h.hotkeys.currentConfig().addsToDictionary)
        rig.h.controller.send(.pillCancel)
    }

    /// fn D: the word goes in, the push-to-talk dictation goes without a trace, and a card says so with Undo.
    @Test func fnDAddsTheSelection() async throws {
        let (rig, _) = Self.make()
        Switch.hold(rig)
        Self.pressD(rig)
        try await waitUntil { rig.h.settings.dictionary.words == ["Wispr Flow"] }
        #expect(rig.h.controller.machine.capture == .idle && rig.transcribed.isEmpty)
        #expect(rig.notice("dictation.canceled") == nil)
        let card = try #require(rig.notice(DictationController.dictionaryCardKey))
        #expect(card.title == "Added to your dictionary")
        try rig.click(.restoreDictionary(UserDictionary()), in: DictationController.dictionaryCardKey)
        #expect(rig.h.settings.dictionary.words.isEmpty)
    }

    /// The same word in other capitals takes the old spelling's place, and Undo brings the old one back.
    @Test func undoBringsBackTheSpellingItReplaced() async throws {
        let (rig, _) = Self.make(selection: "WISPR")
        rig.h.settings.dictionary.add("Wispr")
        Switch.hold(rig)
        Self.pressD(rig)
        try await waitUntil { rig.h.settings.dictionary.words == ["WISPR"] }
        let card = try #require(rig.notice(DictationController.dictionaryCardKey))
        #expect(card.body?.contains("replaces “Wispr”") == true)
        try rig.click(.restoreDictionary(UserDictionary(words: ["Wispr"])), in: DictationController.dictionaryCardKey)
        #expect(rig.h.settings.dictionary.words == ["Wispr"])
    }

    @Test func aWordAlreadyThereSaysSo() async throws {
        let (rig, _) = Self.make()
        rig.h.settings.dictionary.add("Wispr Flow")
        Switch.hold(rig)
        Self.pressD(rig)
        try await waitUntil { rig.notice(DictationController.dictionaryCardKey) != nil }
        #expect(rig.notice(DictationController.dictionaryCardKey)?.title == "Already in your dictionary")
        #expect(rig.h.settings.dictionary.words == ["Wispr Flow"])
    }

    @Test func aParagraphIsntAWord() async throws {
        let (rig, _) = Self.make(selection: "First line.\nSecond line.")
        Switch.hold(rig)
        Self.pressD(rig)
        try await waitUntil { rig.notice(DictationController.dictionaryCardKey) != nil }
        let card = try #require(rig.notice(DictationController.dictionaryCardKey))
        #expect(card.title == "Select a word or a name" && card.body == DictationController.dictionaryRefusal(.lines))
        #expect(rig.h.settings.dictionary.words.isEmpty)
    }

    /// A switch onto Gemini only takes Polish Selection away: the hint goes, so the chip can name the model. Back off
    /// Gemini, Polish Selection is there again, and so is the hint.
    @Test func switchingOntoGeminiLetsTheChipNameIt() async throws {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        Switch.hold(rig)
        try await waitUntil { rig.h.pill.selectionHint == .shown }
        c.handle(.cycleEngine)
        c.handle(.cycleEngine)
        #expect(c.effectiveChoice == .gemini && rig.h.pill.selectionHint == .hidden)
        c.handle(.cycleEngine)
        #expect(c.effectiveChoice == .parakeet && rig.h.pill.selectionHint == .shown)
        c.send(.pillCancel)
    }

    /// On Gemini fn ↩ is Polish's, but fn D still adds.
    @Test func fnDWorksOnGemini() async throws {
        let (rig, _) = Self.make()
        rig.h.settings.lineup.main = .gemini
        Switch.hold(rig)
        try await waitUntil { rig.h.pill.selectionHint == .shown }
        #expect(rig.h.pill.selectionOffer == PillSelectionOffer(polish: false, dictionary: true))
        Self.pressD(rig)
        try await waitUntil { rig.h.settings.dictionary.words == ["Wispr Flow"] }
    }

    /// Without an OpenRouter key Polish Selection isn't offered, but the dictionary is.
    @Test func fnDWorksWithoutAKey() async throws {
        let (rig, _) = Self.make(key: .missing)
        #expect(rig.h.hotkeys.currentConfig().addsToDictionary)
        Switch.hold(rig)
        try await waitUntil { rig.h.pill.selectionHint == .shown }
        #expect(rig.h.pill.selectionOffer == PillSelectionOffer(polish: false, dictionary: true))
        #expect(!rig.h.controller.polishesSelection)
        Self.pressD(rig)
        try await waitUntil { rig.h.settings.dictionary.words == ["Wispr Flow"] }
    }

    /// fn D reads what's selected now: in a long hands-free dictation, the word just selected, not what was selected as
    /// it started. The dictation goes on.
    @Test func inHandsFreeFnDTakesWhatsSelectedNowAndRecordsOn() async throws {
        let (rig, _) = Self.make()
        var current = "start of the dictation"
        rig.h.controller.selectionOverride = { current }
        rig.h.controller.send(.handsFreeToggle)
        try await waitUntil { rig.h.pill.selectionHint == .shown }
        current = "Kubernetes"
        Self.pressD(rig)
        try await waitUntil { rig.h.settings.dictionary.words == ["Kubernetes"] }
        #expect(rig.h.controller.machine.capture.isListeningOrLocked)
        rig.h.controller.send(.pillCancel)
    }

    /// Nothing selected right then: the D goes on to the app, and ends the push-to-talk hold as a key would.
    @Test func fnDOverNothingGoesToTheApp() async throws {
        let (rig, _) = Self.make(selection: nil)
        var replayed: [KeyStroke] = []
        rig.h.controller.replayKeyOverride = { replayed.append($0) }
        rig.h.controller.handle(.pttDown)
        Self.pressD(rig)
        try await waitUntil { replayed == [Self.d] }
        #expect(rig.h.settings.dictionary.words.isEmpty && !rig.h.controller.machine.isRecording)
    }

    /// fn P and fn D both before anything is known, with nothing selected: fn P says Polish is Gemini's, and the D goes
    /// on to the app.
    @Test func keysWaitingTogetherEachDoTheirPart() async throws {
        let (rig, _) = Self.make(selection: nil)
        let lookup = PolishSelectionTests.Lookup()
        rig.h.controller.selectionOverride = { await lookup.wait(); return nil }
        var replayed: [KeyStroke] = []
        rig.h.controller.replayKeyOverride = { replayed.append($0) }
        rig.h.controller.handle(.pttDown)
        rig.h.controller.handle(.polish)
        Self.pressD(rig)
        lookup.isOpen = true
        try await waitUntil { replayed.count == 1 }
        #expect(replayed == [Self.d] && rig.h.pill.keyHint == "Polish works on Gemini, or on selected text")
    }
}
