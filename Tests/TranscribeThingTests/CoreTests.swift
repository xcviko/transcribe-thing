import AVFAudio
import AppKit
import Foundation
import Testing
@testable import TranscribeThing

// MARK: - Shortcut model

@Suite struct ShortcutModelTests {
    @Test func fnSpaceEncodesToTheDocumentedJSON() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(Shortcut.fnSpace), as: UTF8.self)
        #expect(json == #"{"keyCode":49,"modifiers":[{"modifier":"function","side":"either"}]}"#)
    }

    @Test(arguments: ShortcutAction.allCases)
    func defaultBindingRoundTrips(_ action: ShortcutAction) throws {
        let shortcut = try #require(ShortcutBindings.defaults[action])
        let decoded = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(shortcut))
        #expect(decoded == shortcut)
    }

    @Test func decodingNormalizesSidesAndOrder() throws {
        let json = #"{"modifiers":[{"modifier":"command","side":"left"},{"modifier":"control"},{"modifier":"command","side":"right"}],"keyCode":9}"#
        let decoded = try JSONDecoder().decode(Shortcut.self, from: Data(json.utf8))
        #expect(decoded == Shortcut(modifiers: [.init(.control), .init(.command)], keyCode: KeyCode.ansiV))
        #expect(decoded.modifiers.map(\.modifier) == [.control, .command])
    }

    @Test func functionModifierHasNoSide() {
        #expect(Shortcut.ModifierKey(.function, .right).side == .either)
    }

    @Test func exactMatchingRespectsSides() {
        var snapshot = ModifierSnapshot()
        snapshot.leftControl = true
        snapshot.leftCommand = true
        #expect(Shortcut.commandLeftControlC.modifiersMatchExactly(snapshot))
        snapshot.rightControl = true
        #expect(!Shortcut.commandLeftControlC.modifiersMatchExactly(snapshot))
        #expect(Shortcut.commandLeftControlC.requiredModifiersHeld(snapshot))

        var fnOnly = ModifierSnapshot()
        fnOnly.function = true
        #expect(Shortcut.fn.modifiersMatchExactly(fnOnly))
        fnOnly.leftShift = true
        #expect(!Shortcut.fn.modifiersMatchExactly(fnOnly))
    }

    @Test func deviceBitsResolveSides() {
        let raw = CGEventFlags.maskCommand.rawValue | DeviceModifierMask.rightCommand
        let snapshot = ModifierSnapshot(rawFlags: raw, functionDown: false)
        #expect(snapshot.rightCommand && !snapshot.leftCommand)
        #expect(Shortcut.rightCommand.modifiersMatchExactly(snapshot))
    }
}

// MARK: - Display

@Suite struct ShortcutDisplayTests {
    // Runs off the main thread, so letter keys use the deterministic US ANSI legends.
    @Test func defaultBindingsDisplay() throws {
        let b = ShortcutBindings.defaults
        let ptt = try #require(b[.pushToTalk])
        #expect(ptt.displayTokens == ["fn"])
        #expect(ptt.compactDescription == "fn")
        #expect(ptt.spokenDescription == "Fn")

        let handsFree = try #require(b[.handsFree])
        #expect(handsFree.displayTokens == ["fn", "Space"])
        #expect(handsFree.compactDescription == "fn Space")
        #expect(handsFree.spokenDescription == "Fn + Space")

        let cancel = try #require(b[.cancel])
        #expect(cancel.displayTokens == ["Esc"])
        #expect(cancel.spokenDescription == "Escape")

        let paste = try #require(b[.pasteLast])
        #expect(paste.displayTokens == ["fn", "⌘", "V"])
        #expect(paste.compactDescription == "fn ⌘ V")
        #expect(paste.spokenDescription == "Fn + Command + V")

        let copy = try #require(b[.copyLast])
        #expect(copy.displayTokens == ["Left ⌃", "⌘", "C"])
        #expect(copy.compactDescription == "Left ⌃ ⌘ C")
        #expect(copy.spokenDescription == "Left Control + Command + C")
    }

    @Test func symbolOnlyCombosAreCompact() {
        let ctrlCmdV = Shortcut(modifiers: [.init(.command), .init(.control)], keyCode: KeyCode.ansiV)
        #expect(ctrlCmdV.compactDescription == "⌃⌘V")
        #expect(Shortcut.rightOption.compactDescription == "Right ⌥")
        #expect(Shortcut.rightOption.spokenDescription == "Right Option")
    }

    @Test func keycapsForChips() {
        #expect(Shortcut.fnSpace.keycaps == [
            Keycap(label: "fn", systemImage: "globe"),
            Keycap(label: "space", isWide: true),
        ])
        #expect(Shortcut.commandLeftControlC.keycaps.first?.sideCaption == "left")
        #expect(Shortcut.escape.keycaps.map(\.label) == ["esc"])
    }

    @Test @MainActor func mainThreadNamesComeFromAnASCIILayout() {
        let name = KeyNames.name(for: KeyCode.ansiV)
        #expect(name.count == 1)
        #expect(name == name.uppercased())
    }
}

// MARK: - Bindings

@Suite struct ShortcutBindingsTests {
    @Test func encodesAsAStableObjectKeyedByAction() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(ShortcutBindings.defaults)
        let second = try encoder.encode(ShortcutBindings(bindings: ShortcutBindings.defaults.bindings))
        #expect(first == second)

        let object = try #require(try JSONSerialization.jsonObject(with: first) as? [String: Any])
        #expect(Set(object.keys) == Set(ShortcutAction.allCases.map(\.rawValue)))
        #expect(try JSONDecoder().decode(ShortcutBindings.self, from: first) == .defaults)
    }

    @Test func unboundActionsSurviveAndMissingKeysGetDefaults() throws {
        var bindings = ShortcutBindings.defaults
        bindings[.copyLast] = nil
        let data = try JSONEncoder().encode(bindings)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""copyLast":null"#))
        #expect(try JSONDecoder().decode(ShortcutBindings.self, from: data) == bindings)

        let partial = #"{"pushToTalk":{"modifiers":[{"modifier":"option","side":"right"}]}}"#
        let decoded = try JSONDecoder().decode(ShortcutBindings.self, from: Data(partial.utf8))
        #expect(decoded[.pushToTalk] == .rightOption)
        #expect(decoded[.handsFree] == .fnSpace)
        #expect(decoded[.cancel] == .escape)
    }

    @Test func conflictsAndSwap() {
        var bindings = ShortcutBindings.defaults
        #expect(bindings.conflict(for: .fn, excluding: .handsFree) == .pushToTalk)
        #expect(bindings.conflict(for: .fn, excluding: .pushToTalk) == nil)
        bindings.swap(.pushToTalk, .handsFree)
        #expect(bindings[.pushToTalk] == .fnSpace)
        #expect(bindings[.handsFree] == .fn)
    }

    @Test func escapeIsOnlyForCancel() {
        #expect(ShortcutValidator.validate(.escape, for: .cancel).isAcceptable)
        #expect(!ShortcutValidator.validate(.escape, for: .pushToTalk).isAcceptable)
    }

    @Test func validatorRejectsTypingKeysSystemCombosAndDuplicates() {
        let plainV = Shortcut(modifiers: [], keyCode: KeyCode.ansiV)
        #expect(!ShortcutValidator.validate(plainV, for: .pasteLast).isAcceptable)
        let shiftV = Shortcut(modifiers: [.init(.shift)], keyCode: KeyCode.ansiV)
        #expect(!ShortcutValidator.validate(shiftV, for: .pasteLast).isAcceptable)
        let commandV = Shortcut(modifiers: [.init(.command)], keyCode: KeyCode.ansiV)
        #expect(!ShortcutValidator.validate(commandV, for: .pasteLast).isAcceptable)
        let duplicate = ShortcutValidator.validate(.fnSpace, for: .pasteLast)
        #expect(duplicate.conflict == .handsFree)
        #expect(!duplicate.isAcceptable)
        #expect(ShortcutValidator.validate(.f13, for: .pushToTalk).isAcceptable)
        #expect(ShortcutValidator.validate(.rightOption, for: .pushToTalk).isAcceptable)
        #expect(!ShortcutValidator.validate(Shortcut(modifiers: [.init(.shift)]), for: .pushToTalk).isAcceptable)
    }

    @Test(arguments: ShortcutAction.allCases)
    func defaultsValidateCleanly(_ action: ShortcutAction) throws {
        let shortcut = try #require(ShortcutBindings.defaults[action])
        #expect(ShortcutValidator.validate(shortcut, for: action, bindings: .defaults).errors.isEmpty)
    }
}

// MARK: - Errors and notices

@Suite struct NoticeCopyTests {
    static let allErrors: [AppError] = [
        .microphonePermissionDenied, .noMicrophone, .microphoneNotResponding("AVAudioEngine start failed"),
        .microphoneDisconnected, .microphoneSilent, .accessibilityMissing,
        .modelNotDownloaded(.parakeet), .modelDownloading(.parakeet, 0.64), .modelPreparing(.parakeet),
        .modelLoadFailed(.parakeet, "Corrupt weights"), .downloadFailed(.parakeet, "Connection lost"),
        .notEnoughDisk(needed: 2_000_000_000, available: 1_200_000_000),
        .openRouterMissingKey, .openRouterInvalidKey("No auth credentials found"),
        .openRouterNoCredits("Insufficient credits"), .openRouterRateLimited(retryAfter: 4),
        .openRouterRateLimited(retryAfter: nil), .openRouterNoRoute("No endpoints found"),
        .openRouterProviderUnavailable("Provider returned error"), .openRouterRefused("Content blocked by the provider"),
        .openRouterBadRequest("Invalid audio format"), .openRouterServer("Internal server error"),
        .timeout(.geminiFlash), .timeout(.parakeetCloud), .timeout(.parakeet), .offline, .noSpeech,
        .engineFailed(.parakeet, "CoreML error"), .recordingTooLarge,
        .openRouterKeyUnreadable, .openRouterKeyLimit("Key limit exceeded"),
        .openRouterTruncated("So the plan is so the plan is so the plan is"), .openRouterTruncated(""),
    ]

    static let fallbacks: [EngineID?] = [nil, .parakeet, .parakeetCloud]

    @Test(arguments: allErrors)
    func copyIsPoliteAndCompact(_ error: AppError) {
        for recordingID in [nil, UUID()] as [UUID?] {
            for fallback in Self.fallbacks {
                let notice = error.notice(recordingID: recordingID, fallbackEngine: fallback)
                let texts = [notice.title, notice.body ?? ""] + notice.actions.map(\.title)
                #expect(texts.allSatisfy { !$0.contains("!") }, "\(error) has an exclamation mark")
                #expect(texts.allSatisfy { !$0.contains("transcribe-thing") }, "\(error): use Brand.name so the name never wraps at its hyphen")
                #expect(notice.actions.count <= 2)
                #expect(notice.actions.filter(\.isPrimary).count == (notice.actions.isEmpty ? 0 : 1))
                #expect(notice.actions.first?.isPrimary ?? true)
                #expect(!notice.title.isEmpty && !notice.title.hasSuffix("."))
                // Sentence case, except that the brand is always written lowercase, even first.
                #expect(notice.title.first?.isUppercase == true || notice.title.hasPrefix("\(Brand.name) "))
                #expect(notice.recordingID == recordingID)
                #expect(notice.dedupeKey.hasPrefix("error."))

                for action in notice.actions {
                    switch action.kind {
                    case .retry:
                        #expect(recordingID != nil && error.isRetryable, "\(error): Retry without retained audio")
                    case .retryWith(let engine):
                        #expect(recordingID != nil && fallback == engine, "\(error): Retry with unexpected engine")
                        #expect(action.title == "Retry with \(engine.shortName)")
                    case .selectEngine(let engine):
                        #expect(recordingID == nil && fallback == engine)
                    default:
                        break
                    }
                }
                if notice.actions.contains(where: { if case .retry = $0.kind { true } else { false } }) {
                    #expect(notice.body?.contains("Your recording is saved.") == true)
                }
            }
        }
    }

    @Test(arguments: allErrors)
    @MainActor func symbolsExist(_ error: AppError) {
        let symbol = error.notice(recordingID: nil, fallbackEngine: nil).symbol
        #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "Missing SF Symbol \(symbol)")
    }

    @Test func retryableCloudFailureOffersRetryThenFallback() {
        let notice = AppError.timeout(.geminiFlash).notice(recordingID: UUID(), fallbackEngine: .parakeet)
        #expect(notice.actions.map(\.title) == ["Retry", "Retry with Parakeet v3"])
        #expect(notice.actions.map(\.kind) == [.retry, .retryWith(.parakeet)])
        #expect(notice.style == .error)
        #expect(notice.sound == .error)
        #expect(notice.lifetime == .seconds(10))
    }

    /// No speech is news, not a failure: the quiet info notice, nothing to retry.
    @Test func noSpeechIsAQuietInfoNotice() {
        let notice = AppError.noSpeech.notice(recordingID: nil, fallbackEngine: .parakeetCloud, engine: .parakeet)
        #expect(notice.style == .info)
        #expect(notice.title == "No speech detected")
        #expect(notice.sound == nil)
        #expect(notice.lifetime == .seconds(4))
        #expect(notice.actions.isEmpty)
        #expect(!AppError.noSpeech.isRetryable)
    }

    /// Gemini's reasoning used every output token before any text: a real failure, retryable, never silence.
    @Test func runningOutOfTokensBeforeAnyTextIsAFailure() {
        let notice = AppError.openRouterTruncated("").notice(recordingID: UUID(), fallbackEngine: .parakeet)
        #expect(notice.title == "Gemini stopped before finishing")
        #expect(notice.body == "It ran out of room before writing any text. Your recording is saved.")
        #expect(notice.transcript == nil)
        #expect(notice.actions.map(\.kind) == [.retry, .retryWith(.parakeet)])
        #expect(notice.sound == .alert)
    }

    @Test func truncatedTranscriptIsShownNotPasted() {
        let notice = AppError.openRouterTruncated("Let's move the review to").notice(recordingID: UUID(), fallbackEngine: nil)
        #expect(notice.transcript == "Let's move the review to")
        #expect(notice.actions.map(\.title) == ["Retry", "Copy"])
        #expect(notice.actions.last?.kind == .copyText("Let's move the review to"))
        #expect(AppError.openRouterTruncated("x").isRetryable)
    }

    @Test func keyLimitPointsAtTheKeysPage() {
        let notice = AppError.openRouterKeyLimit("limit").notice(recordingID: nil, fallbackEngine: .parakeet)
        #expect(notice.actions.map(\.kind) == [.openURL(OpenRouterLinks.keys), .selectEngine(.parakeet)])
    }

    @Test func keyProblemsLeadWithTheFix() {
        let invalid = AppError.openRouterInvalidKey("401").notice(recordingID: UUID(), fallbackEngine: .parakeet)
        #expect(invalid.actions.map(\.title) == ["Update Key", "Retry with Parakeet v3"])
        let missing = AppError.openRouterMissingKey.notice(recordingID: nil, fallbackEngine: .parakeet)
        #expect(missing.actions.map(\.kind) == [.openHub(.models), .selectEngine(.parakeet)])
    }

    @Test func noRetryWithoutAudioOrForUnusableRecordings() {
        let noAudio = AppError.engineFailed(.parakeet, "x").notice(recordingID: nil, fallbackEngine: .parakeetCloud)
        #expect(!noAudio.actions.contains { $0.kind == .retry })
        let silent = AppError.microphoneSilent.notice(recordingID: UUID(), fallbackEngine: .parakeet)
        #expect(!silent.actions.contains { if case .retryWith = $0.kind { true } else { false } })
        #expect(AppError.noSpeech.notice(recordingID: UUID(), fallbackEngine: .parakeet).actions.isEmpty)
    }

    @Test func missingModelOffersDownloadThenSwitch() {
        let withFallback = AppError.modelNotDownloaded(.parakeet).notice(recordingID: nil, fallbackEngine: .parakeetCloud)
        #expect(withFallback.actions.map(\.title) == ["Download", "Use Parakeet v3 · Cloud"])
        let alone = AppError.modelNotDownloaded(.parakeet).notice(recordingID: nil, fallbackEngine: nil)
        #expect(alone.actions.map(\.kind) == [.download(.parakeet), .openHub(.models)])
        #expect(alone.body == "Download it (about 632 MB) or pick another model.")
    }

    @Test func onlyTheLocalModelHelpsWhenTheKeyOrConnectionFails() {
        for error in [AppError.openRouterMissingKey, .openRouterKeyUnreadable, .openRouterInvalidKey("401"),
                      .openRouterNoCredits(""), .openRouterKeyLimit(""), .offline] {
            #expect(error.stopsEveryCloudModel, "\(error.code)")
        }
        for error in [AppError.openRouterRateLimited(retryAfter: nil), .openRouterNoRoute(""), .timeout(.geminiPro),
                      .openRouterProviderUnavailable(""), .recordingTooLarge, .modelNotDownloaded(.parakeet)] {
            #expect(!error.stopsEveryCloudModel, "\(error.code)")
        }
    }

    @Test func micDisconnectKeepsTheAudioAndPointsAtTheMic() {
        let notice = AppError.microphoneDisconnected.notice(recordingID: UUID(), fallbackEngine: .parakeetCloud)
        #expect(notice.actions.map(\.title) == ["Transcribe It", "Choose Mic"])
    }

    @Test func fallbackEqualToTheFailingEngineIsIgnored() {
        let notice = AppError.engineFailed(.parakeet, "x").notice(recordingID: UUID(), fallbackEngine: .parakeet)
        #expect(!notice.actions.contains { if case .retryWith = $0.kind { true } else { false } })
    }

    @Test func criticalNoticesAreSticky() {
        #expect(AppError.microphonePermissionDenied.notice(recordingID: nil, fallbackEngine: nil).lifetime == .sticky)
    }

    @Test func errorDescriptionCombinesTitleAndBody() {
        #expect(AppError.offline.localizedDescription == "You’re offline. Gemini needs the internet.")
    }
}

// MARK: - Sounds

@Suite @MainActor struct SoundFileTests {
    /// scripts/build-app.sh copies every Resources/Sounds/*.wav into the app: exactly one file per effect.
    @Test func theSoundsFolderHoldsOneFilePerEffect() throws {
        let folder = try #require(AppResources.developmentRoot).appendingPathComponent("Sounds", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".wav") }
        #expect(Set(files) == Set(SoundEffect.allCases.map { "\($0.fileName).\(SoundEffect.fileExtension)" }))
    }

    /// SoundPlayer ducks the mic for a cue's length before the players load; that length must be the file's.
    @Test(arguments: SoundEffect.allCases)
    func nominalDurationMatchesTheFile(_ effect: SoundEffect) throws {
        let url = try #require(AppResources.url(effect.fileName, ext: SoundEffect.fileExtension, subdirectory: "Sounds"))
        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        let nominal = try #require(SoundPlayer.nominalDurations[effect])
        #expect(abs(seconds - nominal) < 0.002, "\(effect.rawValue).wav is \(seconds) s")
    }
}

// MARK: - Formatters

@Suite struct FormatterTests {
    @Test func bytes() {
        #expect(Fmt.bytes(632_321_326) == "632 MB")
        #expect(Fmt.bytes(629_700_000) == "630 MB")
        #expect(Fmt.bytes(48_500_000) == "48.5 MB")
        #expect(Fmt.bytes(1_234_567_890) == "1.2 GB")
        #expect(Fmt.bytes(2_000_000_000) == "2 GB")
        #expect(Fmt.bytes(12_000) == "12 KB")
        #expect(Fmt.bytes(999) == "999 bytes")
        #expect(Fmt.bytes(1) == "1 byte")
    }

    @Test func durations() {
        #expect(Fmt.duration(14) == "0:14")
        #expect(Fmt.duration(62.9) == "1:02")
        #expect(Fmt.duration(3723) == "1:02:03")
        #expect(Fmt.duration(-3) == "0:00")
    }

    @Test func eta() {
        #expect(Fmt.eta(4) == "a few seconds left")
        #expect(Fmt.eta(30) == "about 30 s left")
        #expect(Fmt.eta(64) == "about 1 min left")
        #expect(Fmt.eta(600) == "about 10 min left")
        #expect(Fmt.eta(4800) == "about 1 h 20 min left")
        #expect(Fmt.eta(7200) == "about 2 h left")
    }

    @Test func words() {
        #expect(Fmt.words(0) == "0 words")
        #expect(Fmt.words(1) == "1 word")
        #expect(Fmt.words(1234) == "1,234 words")
    }

    @Test func relativeDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12)))
        func daysAgo(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: now)! }
        #expect(Fmt.relativeDay(now.addingTimeInterval(-3600), now: now, calendar: calendar) == "Today")
        #expect(Fmt.relativeDay(daysAgo(1), now: now, calendar: calendar) == "Yesterday")
        #expect(Fmt.relativeDay(daysAgo(3), now: now, calendar: calendar) == "Tuesday")
        #expect(Fmt.relativeDay(daysAgo(13), now: now, calendar: calendar) == "Sep 12")
        let lastYear = try #require(calendar.date(from: DateComponents(year: 2025, month: 9, day: 12, hour: 9)))
        #expect(Fmt.relativeDay(lastYear, now: now, calendar: calendar) == "Sep 12, 2025")
    }

    @Test func money() {
        #expect(Fmt.usd(12.4) == "$12.40")
        #expect(Fmt.usd(0) == "$0.00")
        #expect(Fmt.usd(0.0031) == "$0.0031")
        #expect(Fmt.percent(0.428) == "42%")
    }
}

// MARK: - Settings and small models

@Suite @MainActor struct CoreModelTests {
    @Test func settingsPersistEveryPropertyOnSet() throws {
        // An absolute-path suite keeps the plist in the temporary folder instead of ~/Library/Preferences.
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.selectedEngine == .parakeet)
        #expect(settings.pillMode == .whileDictating)
        #expect(settings.geminiSystemPrompt.isEmpty)
        #expect(settings.shortcuts == .defaults)

        settings.selectedEngine = .geminiPro
        settings.pillMode = .always
        settings.microphoneUID = "usb-mic"
        settings.soundsEnabled = false
        settings.maxRecordingMinutes = 10
        var bindings = ShortcutBindings.defaults
        bindings[.pushToTalk] = .rightOption
        settings.shortcuts = bindings

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.selectedEngine == .geminiPro)
        #expect(reloaded.pillMode == .always)
        #expect(reloaded.microphoneUID == "usb-mic")
        #expect(!reloaded.soundsEnabled)
        #expect(reloaded.maxRecordingMinutes == 10)
        #expect(reloaded.shortcuts[.pushToTalk] == .rightOption)

        settings.microphoneUID = nil
        #expect(AppSettings(defaults: defaults).microphoneUID == nil)
    }

    @Test(arguments: ["whisper", "whisperCloud", "someFutureEngine"])
    func aSelectedEngineThisBuildDoesntOfferFallsBackToTheDefault(_ raw: String) throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        defaults.set(raw, forKey: SettingsKey.selectedEngine.defaultsKey)
        #expect(AppSettings(defaults: defaults).selectedEngine == .default)
        defaults.set(EngineID.geminiFlash.rawValue, forKey: SettingsKey.selectedEngine.defaultsKey)
        #expect(AppSettings(defaults: defaults).selectedEngine == .geminiFlash)
    }

    /// The removed volume slider: left at zero it meant no sounds; any other level now plays at full volume.
    @Test(arguments: [(0.0, false), (0.4, true)])
    func anOldVolumeSettingIsReadOnceThenRemoved(_ volume: Double, soundsOn: Bool) throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        defaults.set(volume, forKey: SettingsKey.soundVolume.defaultsKey)
        #expect(AppSettings(defaults: defaults).soundsEnabled == soundsOn)
        #expect(defaults.object(forKey: SettingsKey.soundVolume.defaultsKey) == nil)
        #expect(AppSettings(defaults: defaults).soundsEnabled == soundsOn)
    }

    @Test func inMemorySettingsAreIndependent() {
        let a = AppSettings.inMemory()
        let b = AppSettings.inMemory()
        a.selectedEngine = .geminiPro
        #expect(b.selectedEngine == .parakeet)
    }

    @Test func pillTemporaryHide() {
        let settings = AppSettings.inMemory()
        let now = Date()
        #expect(!settings.isPillTemporarilyHidden(now: now))
        settings.hidePill(for: 3600, now: now)
        #expect(settings.isPillTemporarilyHidden(now: now.addingTimeInterval(60)))
        #expect(!settings.isPillTemporarilyHidden(now: now.addingTimeInterval(3601)))
    }

    @Test func inMemoryKeychain() throws {
        let keychain = KeychainStore.inMemory()
        #expect(keychain.read("k") == nil)
        try keychain.write("secret", account: "k")
        #expect(keychain.read("k") == "secret")
        keychain.delete("k")
        #expect(keychain.read("k") == nil)
    }

    @Test func engineFacts() {
        #expect(EngineID.default == .parakeet)
        #expect(EngineID.localEngines == [.parakeet])
        #expect(EngineID.geminiPro.openRouterModelID == "google/gemini-3.1-pro-preview")
        #expect(EngineID.parakeet.approxDownloadBytes == 632_321_326)
        #expect(EngineID.geminiFlash.approxDownloadBytes == nil)
    }

    @Test func temporaryPathsAreUnique() {
        let a = AppPaths.temporary(), b = AppPaths.temporary()
        #expect(a.root != b.root)
        #expect(a.historyFile.lastPathComponent == "history.json")
        #expect(a.freeDiskBytes() > 0)
    }

    @Test func recordingDuration() {
        let recording = Recording(samples: Array(repeating: 0, count: 24_000))
        #expect(recording.duration == 1.5)
    }
}
