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
                      ("LTS)", "LTS"), ("“Node.js”.", "Node.js"), ("(a) and (b)", "(a) and (b)"),
                      ("((nested))", "nested")])
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

    /// Undo of an add takes back only that add: the spelling it replaced and the words it pushed out come back where
    /// they were, and what changed since stays.
    @Test func undoingAnAddKeepsWhatChangedSince() {
        let before = UserDictionary(words: ["Wispr", "Kubernetes", "Gemini"])
        var dictionary = before
        dictionary.add("WISPR")
        let after = dictionary
        dictionary.remove("Gemini")
        dictionary.add("New one")
        dictionary.undoAdding("WISPR", before: before, after: after)
        #expect(dictionary.words == ["Wispr", "Kubernetes", "New one"])

        let full = UserDictionary(words: (0..<UserDictionary.maxCount).map { "word\($0)" })
        var more = full
        more.add("One more")
        let added = more
        more.undoAdding("One more", before: full, after: added)
        #expect(more == full, "the oldest word it pushed out comes back first")
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

// MARK: - Groups

/// Groups sort the words for the user only: the prompts get every word alike.
@Suite struct DictionaryGroupTests {
    private func sample() -> (UserDictionary, models: UUID, work: UUID) {
        var dictionary = UserDictionary(words: ["Wispr", "Kubernetes", "GPT-6 Luna", "Figma", "Gemini"])
        let work = dictionary.addGroup(named: "Work")
        let models = dictionary.addGroup(named: "  Models\n")
        dictionary.move("GPT-6 Luna", to: models)
        dictionary.move("Gemini", to: models)
        dictionary.move("Kubernetes", to: work)
        return (dictionary, models, work)
    }

    @Test func wordsSortIntoGroupsNewestFirst() {
        let (d, models, work) = sample()
        #expect(d.groups.map(\.name) == ["Models", "Work"], "a new group comes first, its name one trimmed line")
        #expect(d.words(in: nil) == ["Figma", "Wispr"])
        #expect(d.words(in: models) == ["Gemini", "GPT-6 Luna"])
        #expect(d.words(in: work) == ["Kubernetes"])
        #expect(d.words == ["Wispr", "Kubernetes", "GPT-6 Luna", "Figma", "Gemini"], "the prompts' list is untouched")
    }

    @Test func groupsReorderAndRename() {
        var (d, models, work) = sample()
        d.moveGroup(models, before: nil)
        #expect(d.groups.map(\.id) == [work, models])
        d.moveGroup(models, before: work)
        #expect(d.groups.map(\.id) == [models, work])
        d.rename(group: work, to: "Day job")
        d.rename(group: work, to: "   ")
        #expect(d.groups.last?.name == "Day job", "an empty name keeps the old one")
    }

    @Test func aGroupGoesWithItsWordsOrLeavesThem() {
        var (d, models, work) = sample()
        var kept = d
        kept.deleteGroup(models, keepingWords: true)
        #expect(kept.groups.map(\.id) == [work] && kept.words.count == 5)
        #expect(kept.words(in: nil) == ["Gemini", "Figma", "GPT-6 Luna", "Wispr"])
        d.deleteGroup(models, keepingWords: false)
        #expect(d.words == ["Wispr", "Kubernetes", "Figma"] && d.groups.map(\.id) == [work])
    }

    /// A respelling stays in its group; a word removed and added again comes back ungrouped.
    @Test func membershipFollowsTheWord() {
        var (d, models, _) = sample()
        d.add("GEMINI")
        #expect(d.words(in: models) == ["GEMINI", "GPT-6 Luna"])
        d.remove("GEMINI")
        d.add("Gemini")
        #expect(d.group(of: "Gemini") == nil)
    }

    @Test func undoingAnAddPutsTheOldSpellingBackInItsGroup() {
        var (d, models, _) = sample()
        let before = d
        d.add("GPT-6 LUNA")
        let after = d
        d.undoAdding("GPT-6 LUNA", before: before, after: after)
        #expect(d.words(in: models) == ["Gemini", "GPT-6 Luna"])
    }

    @Test func theGroupingIsStoredApartAndCleanedOnTheWayBack() throws {
        let (d, models, _) = sample()
        var stale = d.grouping
        stale.membership["not a word"] = models
        stale.membership["figma"] = UUID()
        var restored = UserDictionary(words: d.words)
        restored.grouping = stale
        #expect(restored == d, "only words still here and groups that exist")
        let data = try JSONEncoder().encode(d)
        #expect(try JSONDecoder().decode([String].self, from: data) == d.words, "older builds read the words as ever")
    }

    @MainActor @Test func groupsPersistInTheSettings() throws {
        let suite = "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let (d, _, _) = sample()
        settings.dictionary = d
        #expect(AppSettings(defaults: defaults).dictionary == d)
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
        // A hold that's only the way to the key: nothing said in it.
        rig.h.recorder.next = Recording(samples: Array(repeating: 0.01, count: 8_000),
                                        speech: SpeechStats(voicedSeconds: 0.2, peakDBFS: -40, isSilent: false))
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
        #expect(rig.h.controller.polishesSelection)
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
        try rig.click(.undoDictionaryAdd("Wispr Flow", before: UserDictionary(), after: UserDictionary(words: ["Wispr Flow"])),
                      in: DictationController.dictionaryCardKey)
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
        try rig.click(.undoDictionaryAdd("WISPR", before: UserDictionary(words: ["Wispr"]),
                                         after: UserDictionary(words: ["WISPR"])),
                      in: DictationController.dictionaryCardKey)
        #expect(rig.h.settings.dictionary.words == ["Wispr"])
    }

    @Test func aWordAlreadyThereSaysSo() async throws {
        let (rig, _) = Self.make()
        rig.h.settings.dictionary.add("Wispr Flow")
        Switch.hold(rig)
        Self.pressD(rig)
        try await waitUntil { rig.notice(DictationController.dictionaryNoteKey) != nil }
        #expect(rig.notice(DictationController.dictionaryNoteKey)?.title == "Already in your dictionary")
        #expect(rig.h.settings.dictionary.words == ["Wispr Flow"])
    }

    @Test func aParagraphIsntAWord() async throws {
        let (rig, _) = Self.make(selection: "First line.\nSecond line.")
        Switch.hold(rig)
        Self.pressD(rig)
        try await waitUntil { rig.notice(DictationController.dictionaryNoteKey) != nil }
        let card = try #require(rig.notice(DictationController.dictionaryNoteKey))
        #expect(card.title == "Select a word or a name" && card.body == DictationController.dictionaryRefusal(.lines))
        #expect(rig.h.settings.dictionary.words.isEmpty)
    }

    /// The hint shows once a press, as fn goes down: a switch of model hides it so the chip names the model, and it
    /// doesn't come back, not even off Gemini, where Polish Selection is there again (its key still works).
    @Test func aSwitchShowsTheChipAndTheHintStaysGone() async throws {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        Switch.hold(rig)
        try await waitUntil { rig.h.pill.selectionHint == .shown }
        c.handle(.cycleEngine)
        #expect(c.effectiveChoice != .parakeet && rig.h.pill.selectionHint == .hidden, "the chip, not the hint")
        #expect(rig.h.pill.showsChip && rig.h.pill.keyHint == nil, "nothing stands in the chip's way")
        c.handle(.cycleEngine)
        #expect(c.effectiveChoice == .gemini && rig.h.pill.selectionHint == .hidden)
        c.handle(.cycleEngine)
        #expect(c.effectiveChoice == .parakeet && rig.h.pill.selectionHint == .hidden)
        #expect(c.polishesSelection, "the polish key polishes the selection again")
        c.send(.pillCancel)
        // The next press shows it again.
        Switch.hold(rig)
        try await waitUntil { rig.h.pill.selectionHint == .shown }
        c.send(.pillCancel)
    }

    /// On Gemini fn P is Polish's, but fn D still adds.
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

    /// In hands-free fn D comes with a press of fn: fn's release after it doesn't finish the dictation, even when it
    /// comes before the lookup has answered.
    @Test func inHandsFreeLettingGoOfFnAfterFnDRecordsOn() async throws {
        let (rig, _) = Self.make()
        let c = rig.h.controller
        c.send(.handsFreeToggle)
        c.handle(.pttDown)
        Self.pressD(rig)
        c.handle(.pttUp)
        try await waitUntil { rig.h.settings.dictionary.words == ["Wispr Flow"] }
        #expect(c.machine.capture.isListeningOrLocked && rig.transcribed.isEmpty)
        c.handle(.pttDown)
        Self.pressD(rig)
        try await waitUntil { rig.notice(DictationController.dictionaryNoteKey) != nil }
        c.handle(.pttUp)
        #expect(c.machine.capture.isListeningOrLocked, "already there: the same")
        #expect(rig.notice(DictationController.dictionaryCardKey) != nil, "the Added card keeps its Undo")
        c.send(.pillCancel)
    }

    /// Where the app can't say what's selected (Chrome, Electron), fn D isn't typed over what may be selected: a card
    /// says why nothing happened, and the hold ends as any other key would end it.
    @Test func fnDWhereTheSelectionCantBeReadIsntTyped() async throws {
        let (rig, _) = Self.make(selection: nil)
        rig.h.controller.selectionMissingOverride = .noFocusedElement
        rig.h.controller.handle(.pttDown)
        Self.pressD(rig)
        try await waitUntil { rig.notice(DictationController.dictionaryNoteKey) != nil }
        #expect(rig.notice(DictationController.dictionaryNoteKey)?.title == "Can’t read the selection here")
        #expect(rig.h.settings.dictionary.words.isEmpty && !rig.h.controller.machine.isRecording)
    }

    /// Where the app can't say (VS Code, Claude), what ⌘C copies goes in; when it copies nothing, nothing was
    /// selected, and the pill says to select a word.
    @Test func fnDWhereTheAppCantSayTakesWhatCopyingFinds() async throws {
        let (rig, _) = Self.make(selection: nil)
        var copy = TextInserter.SelectionCopy.text("Kubernetes")
        rig.h.controller.selectionMissingOverride = .noFocusedElement
        rig.h.controller.selectionCopyOverride = { copy }
        rig.h.controller.send(.handsFreeToggle)
        Self.pressD(rig)
        try await waitUntil { rig.h.settings.dictionary.words == ["Kubernetes"] }
        copy = .nothing
        Self.pressD(rig)
        try await waitUntil { rig.h.pill.keyHint == "Select a word to add it to your dictionary" }
        rig.h.controller.send(.pillCancel)
    }

    /// Another word selected and fn D again, fn still down after the first took the dictation over: it goes in too.
    @Test func aSecondFnDInTheSamePressAddsToo() async throws {
        let (rig, _) = Self.make()
        var current = "Wispr Flow"
        rig.h.controller.selectionOverride = { current }
        Switch.hold(rig)
        Self.pressD(rig)
        try await waitUntil { rig.h.settings.dictionary.words == ["Wispr Flow"] }
        current = "Kubernetes"
        Self.pressD(rig)
        try await waitUntil { rig.h.settings.dictionary.words == ["Wispr Flow", "Kubernetes"] }
        rig.h.controller.handle(.pttUp)
        Self.pressD(rig)
        try await Task.sleep(for: .milliseconds(40))
        #expect(rig.h.settings.dictionary.words.count == 2, "fn let go: the press is over")
    }

    /// A push-to-talk dictation the user had spoken in stays for Undo when fn D takes it over.
    @Test func whatWasSaidBeforeFnDStaysForUndo() async throws {
        let (rig, _) = Self.make()
        rig.h.recorder.next = DictationResumeTests.speech(seconds: 3)
        Switch.hold(rig)
        rig.now += 3
        Self.pressD(rig)
        try await waitUntil { rig.h.settings.dictionary.words == ["Wispr Flow"] }
        #expect(rig.notice("dictation.canceled") != nil && rig.transcribed.isEmpty)
    }

    /// The hint offers the dictionary only for what could go in.
    @Test func aParagraphIsntOfferedToTheDictionary() async throws {
        let (rig, _) = Self.make(selection: "First line.\nSecond line.")
        Switch.hold(rig)
        try await waitUntil { rig.h.pill.selectionHint == .shown }
        #expect(rig.h.pill.selectionOffer == PillSelectionOffer(polish: true, dictionary: false))
        rig.h.controller.send(.pillCancel)
    }

    /// Nothing selected right then: no "d" lands in the app; the pill says to select a word, and the dictation goes on.
    @Test func fnDOverNothingSaysToSelectAWord() async throws {
        let (rig, _) = Self.make(selection: nil)
        rig.h.controller.handle(.pttDown)
        Self.pressD(rig)
        try await waitUntil { rig.h.pill.keyHint != nil }
        #expect(rig.h.pill.keyHint == "Select a word to add it to your dictionary")
        #expect(rig.h.settings.dictionary.words.isEmpty && rig.h.controller.machine.isRecording)
        rig.h.controller.send(.pillCancel)
    }

    /// With hints above the pill off, that word isn't shown, over the pill or as a notice.
    @Test func withHintsOffNothingIsSaid() async throws {
        let (rig, _) = Self.make(selection: nil)
        rig.h.settings.showsPillHints = false
        rig.h.pill.isPresented = false
        rig.h.controller.handle(.pttDown)
        Self.pressD(rig)
        rig.h.controller.handle(.polish)
        try await Task.sleep(for: .milliseconds(60))
        #expect(rig.h.pill.keyHint == nil && rig.notice("key.hint") == nil && rig.h.controller.machine.isRecording)
        rig.h.controller.send(.pillCancel)
    }

    /// fn P and fn D both before anything is known, with nothing selected: each says what it would have done, the D
    /// last, and the dictation goes on.
    @Test func keysWaitingTogetherEachDoTheirPart() async throws {
        let (rig, _) = Self.make(selection: nil)
        let lookup = PolishSelectionTests.Lookup()
        rig.h.controller.selectionOverride = { await lookup.wait(); return nil }
        rig.h.controller.handle(.pttDown)
        rig.h.controller.handle(.polish)
        Self.pressD(rig)
        lookup.isOpen = true
        try await waitUntil { rig.h.pill.keyHint == "Select a word to add it to your dictionary" }
        #expect(rig.h.controller.machine.isRecording)
        rig.h.controller.send(.pillCancel)
    }
}
