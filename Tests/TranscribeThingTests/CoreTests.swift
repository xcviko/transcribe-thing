import AVFAudio
import AppKit
import Carbon.HIToolbox
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
        let commandLeftControlC = Shortcut(modifiers: [.init(.command), .init(.control, .left)], keyCode: KeyCode.ansiC)
        var snapshot = ModifierSnapshot()
        snapshot.leftControl = true
        snapshot.leftCommand = true
        #expect(commandLeftControlC.modifiersMatchExactly(snapshot))
        snapshot.rightControl = true
        #expect(!commandLeftControlC.modifiersMatchExactly(snapshot))
        #expect(commandLeftControlC.requiredModifiersHeld(snapshot))

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

        // Cancel isn't bound: it is always Esc.
        #expect(Shortcut.escape.displayTokens == ["Esc"])
        #expect(Shortcut.escape.spokenDescription == "Escape")

        let paste = try #require(b[.pasteLast])
        #expect(paste.displayTokens == ["fn", "⌘", "V"])
        #expect(paste.compactDescription == "fn ⌘ V")
        #expect(paste.spokenDescription == "Fn + Command + V")

    }

    @Test func sidedModifiersNameTheirSide() {
        let leftControl = Shortcut(modifiers: [.init(.command), .init(.control, .left)], keyCode: KeyCode.ansiC)
        #expect(leftControl.displayTokens == ["Left ⌃", "⌘", "C"])
        #expect(leftControl.compactDescription == "Left ⌃ ⌘ C")
        #expect(leftControl.spokenDescription == "Left Control + Command + C")
        #expect(leftControl.keycaps.first?.sideCaption == "left")
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
        bindings[.pasteLast] = nil
        let data = try JSONEncoder().encode(bindings)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""pasteLast":null"#))
        #expect(try JSONDecoder().decode(ShortcutBindings.self, from: data) == bindings)

        let partial = #"{"pushToTalk":{"modifiers":[{"modifier":"option","side":"right"}]}}"#
        let decoded = try JSONDecoder().decode(ShortcutBindings.self, from: Data(partial.utf8))
        #expect(decoded[.pushToTalk] == .rightOption)
        #expect(decoded[.handsFree] == .fnSpace)
    }

    /// Cancel is always Esc now, but bindings saved while it could be changed still carry it (here F13).
    @Test func storedBindingsWithCancelStillLoad() throws {
        let stored = #"{"cancel":{"keyCode":105,"modifiers":[]},"handsFree":null,"#
            + #""pushToTalk":{"modifiers":[{"modifier":"option","side":"right"}]}}"#
        let decoded = try JSONDecoder().decode(ShortcutBindings.self, from: Data(stored.utf8))
        #expect(decoded[.pushToTalk] == .rightOption)
        #expect(decoded[.handsFree] == nil, "deliberately unbound stays unbound")
        #expect(decoded[.pasteLast] == .commandFnV && decoded[.switchModel] == .fnTab)
        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!reencoded.contains("cancel"))
    }

    /// Copy last transcript is gone (paste last copies too), but bindings saved while it existed still carry it.
    @Test(arguments: [Self.storedCopyLast, #""copyLast":null"#])
    func aRetiredCopyLastKeyKeepsEveryOtherBinding(_ copyLast: String) throws {
        let stored = Self.storedBindings(copyLast: copyLast)
        let decoded = try JSONDecoder().decode(ShortcutBindings.self, from: Data(stored.utf8))
        #expect(decoded == Self.customized)
        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!reencoded.contains("copyLast"))
    }

    static let storedCopyLast = #""copyLast":{"keyCode":8,"modifiers":[{"modifier":"command","side":"either"},{"modifier":"control","side":"left"}]}"#

    /// What an earlier build saved (sorted keys): custom push to talk and hands-free, paste last unbound.
    static func storedBindings(copyLast: String) -> String {
        #"{"cancel":{"keyCode":53,"modifiers":[]},"# + copyLast
            + #","handsFree":{"keyCode":49,"modifiers":[{"modifier":"control","side":"either"},{"modifier":"option","side":"either"}]},"#
            + #""pasteLast":null,"pushToTalk":{"modifiers":[{"modifier":"option","side":"right"}]}}"#
    }

    /// Saved before Switch model existed: it gets its default binding, and the others stay as they were.
    static let customized = ShortcutBindings(bindings: [
        .pushToTalk: .rightOption,
        .handsFree: Shortcut(modifiers: [.init(.control), .init(.option)], keyCode: KeyCode.space),
        .switchModel: .fnTab,
    ])

    @Test func conflictsAndSwap() {
        var bindings = ShortcutBindings.defaults
        #expect(bindings.conflict(for: .fn, excluding: .handsFree) == .pushToTalk)
        #expect(bindings.conflict(for: .fn, excluding: .pushToTalk) == nil)
        bindings.swap(.pushToTalk, .handsFree)
        #expect(bindings[.pushToTalk] == .fnSpace)
        #expect(bindings[.handsFree] == .fn)
    }

    @Test(arguments: ShortcutAction.allCases)
    func defaultsValidateCleanly(_ action: ShortcutAction) throws {
        let shortcut = try #require(ShortcutBindings.defaults[action])
        let validation = ShortcutValidator.validate(shortcut, for: action, bindings: .defaults,
                                                    system: ShortcutPolicyTests.stock(fnUsage: .doNothing))
        #expect(validation.errors.isEmpty)
        #expect(validation.warnings.isEmpty)
    }
}

// MARK: - Shortcut policy

private func combo(_ key: Int, _ modifiers: Shortcut.Modifier...) -> Shortcut {
    Shortcut(modifiers: modifiers.map { .init($0) }, keyCode: UInt16(key))
}

private func chord(_ keys: Shortcut.ModifierKey...) -> Shortcut {
    Shortcut(modifiers: keys)
}

/// Any shortcut can be bound. Errors are only an empty shortcut and a clash with another action; everything
/// else that used to be refused is a warning, and macOS shortcuts warn only while they are on.
@Suite struct ShortcutPolicyTests {
    enum Expected: Equatable, Sendable {
        case clean
        /// Saved; the first (shown) warning is of this kind.
        case warning(ShortcutWarning.Kind)
        case error
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var shortcut: Shortcut
        var action: ShortcutAction
        var system: SystemKeyboardState = ShortcutPolicyTests.quiet
        var bindings: ShortcutBindings = .defaults
        var expected: Expected

        var testDescription: String { name }
    }

    /// Every macOS shortcut off, 🌐 does nothing, F-keys are media keys.
    static let quiet = SystemKeyboardState(hotKeys: [], fnUsage: .doNothing, functionKeysAreStandard: false)

    /// A Mac nobody has customized: every default macOS shortcut on.
    static func stock(fnUsage: FnKeyAdvisor.Usage? = nil) -> SystemKeyboardState {
        SystemKeyboardState(hotKeys: SystemSymbolicHotKeys.active(in: nil), fnUsage: fnUsage, functionKeysAreStandard: false)
    }

    static let controlOptionPTT = {
        var bindings = ShortcutBindings.defaults
        bindings[.pushToTalk] = chord(.init(.control), .init(.option))
        return bindings
    }()

    static let cases: [Case] = [
        // Errors: can't work at all.
        Case(name: "nothing pressed", shortcut: Shortcut(modifiers: []), action: .pushToTalk, expected: .error),
        Case(name: "duplicate of hands-free", shortcut: .fnSpace, action: .pasteLast, expected: .error),
        Case(name: "Right ⌃ fires on the way to a ⌃⌥ push to talk", shortcut: chord(.init(.control, .right)),
             action: .handsFree, bindings: controlOptionPTT, expected: .error),

        // macOS shortcuts Keyboard Settings can turn off: a warning only while on.
        Case(name: "⌃Space, input sources on", shortcut: combo(kVK_Space, .control), action: .handsFree,
             system: stock(), expected: .warning(.systemShortcut)),
        Case(name: "⌃Space, input sources off", shortcut: combo(kVK_Space, .control), action: .handsFree, expected: .clean),
        Case(name: "⌘Space, Spotlight on", shortcut: combo(kVK_Space, .command), action: .pushToTalk,
             system: stock(), expected: .warning(.systemShortcut)),
        Case(name: "⌘Space, Spotlight off", shortcut: combo(kVK_Space, .command), action: .pushToTalk, expected: .clean),
        Case(name: "⌃⌥Space, on", shortcut: combo(kVK_Space, .control, .option), action: .handsFree,
             system: stock(), expected: .warning(.systemShortcut)),
        Case(name: "⇧⌘4, on", shortcut: combo(kVK_ANSI_4, .shift, .command), action: .pasteLast,
             system: stock(), expected: .warning(.systemShortcut)),
        Case(name: "⇧⌘4, off", shortcut: combo(kVK_ANSI_4, .shift, .command), action: .pasteLast, expected: .clean),
        Case(name: "⌃← (Spaces), on", shortcut: combo(kVK_LeftArrow, .control), action: .pasteLast,
             system: stock(), expected: .warning(.systemShortcut)),
        Case(name: "⌃← (Spaces), off", shortcut: combo(kVK_LeftArrow, .control), action: .pasteLast, expected: .clean),
        Case(name: "F11 (Show Desktop), on", shortcut: combo(kVK_F11), action: .pushToTalk,
             system: stock(), expected: .warning(.systemShortcut)),

        // Combinations nothing can turn off: always a light warning.
        Case(name: "⌘Tab", shortcut: combo(kVK_Tab, .command), action: .handsFree, expected: .warning(.systemShortcut)),
        Case(name: "⌃⌘Space", shortcut: combo(kVK_Space, .control, .command), action: .handsFree,
             expected: .warning(.systemShortcut)),
        Case(name: "⌥⌘Esc", shortcut: combo(kVK_Escape, .option, .command), action: .handsFree,
             expected: .warning(.systemShortcut)),
        Case(name: "⌘Q", shortcut: combo(kVK_ANSI_Q, .command), action: .pasteLast, expected: .warning(.systemShortcut)),
        Case(name: "⌘V", shortcut: combo(kVK_ANSI_V, .command), action: .pasteLast, expected: .warning(.systemShortcut)),
        Case(name: "⌘K (any ⌘ letter)", shortcut: combo(kVK_ANSI_K, .command), action: .pasteLast,
             expected: .warning(.systemShortcut)),
        Case(name: "fn E (Globe letter)", shortcut: combo(kVK_ANSI_E, .function), action: .pasteLast,
             expected: .warning(.systemShortcut)),

        // Keys that type.
        Case(name: "plain V", shortcut: combo(kVK_ANSI_V), action: .pasteLast, expected: .warning(.typing)),
        Case(name: "plain Space", shortcut: combo(kVK_Space), action: .handsFree, expected: .warning(.typing)),
        Case(name: "⇧V", shortcut: combo(kVK_ANSI_V, .shift), action: .pasteLast, expected: .warning(.typing)),
        Case(name: "⌥V", shortcut: combo(kVK_ANSI_V, .option), action: .pasteLast, expected: .warning(.typing)),
        Case(name: "⇧ alone", shortcut: chord(.init(.shift)), action: .pushToTalk, expected: .warning(.typing)),
        Case(name: "Right ⇧ alone", shortcut: chord(.init(.shift, .right)), action: .pushToTalk,
             expected: .warning(.typing)),

        // Esc.
        Case(name: "Esc for push to talk", shortcut: .escape, action: .pushToTalk, expected: .warning(.escape)),

        // F-keys.
        Case(name: "F5, media keys", shortcut: combo(kVK_F5), action: .pushToTalk, expected: .warning(.mediaKey)),
        Case(name: "F5, standard F-keys",
             shortcut: combo(kVK_F5), action: .pushToTalk,
             system: SystemKeyboardState(hotKeys: [], fnUsage: .doNothing, functionKeysAreStandard: true), expected: .clean),
        Case(name: "fn F5", shortcut: combo(kVK_F5, .function), action: .pushToTalk, expected: .clean),
        Case(name: "F13", shortcut: .f13, action: .pushToTalk, expected: .clean),

        // Lone modifiers.
        Case(name: "⌥ alone", shortcut: chord(.init(.option)), action: .pushToTalk, expected: .warning(.loneModifier)),
        Case(name: "Left ⌘ alone", shortcut: chord(.init(.command, .left)), action: .pushToTalk,
             expected: .warning(.loneModifier)),
        Case(name: "⌃ alone", shortcut: chord(.init(.control)), action: .pushToTalk, expected: .warning(.loneModifier)),
        Case(name: "Right ⌥ alone", shortcut: .rightOption, action: .pushToTalk, expected: .clean),
        Case(name: "⌃⌥ chord", shortcut: chord(.init(.control), .init(.option)), action: .pushToTalk, expected: .clean),

        // The 🌐 key on its own.
        Case(name: "fn, 🌐 switches input sources", shortcut: .fn, action: .pushToTalk,
             system: SystemKeyboardState(hotKeys: [], fnUsage: .changeInputSource, functionKeysAreStandard: false),
             expected: .warning(.globeKey)),
        Case(name: "fn, 🌐 never set", shortcut: .fn, action: .pushToTalk,
             system: SystemKeyboardState(hotKeys: [], fnUsage: nil, functionKeysAreStandard: false),
             expected: .warning(.globeKey)),
        Case(name: "fn, 🌐 does nothing", shortcut: .fn, action: .pushToTalk, expected: .clean),
        Case(name: "fn Space, 🌐 switches input sources", shortcut: .fnSpace, action: .handsFree,
             system: SystemKeyboardState(hotKeys: [], fnUsage: .changeInputSource, functionKeysAreStandard: false),
             expected: .clean),
    ]

    @Test(arguments: cases)
    func policy(_ c: Case) {
        let validation = ShortcutValidator.validate(c.shortcut, for: c.action, bindings: c.bindings, system: c.system)
        switch c.expected {
        case .clean:
            #expect(validation.errors.isEmpty)
            #expect(validation.warnings.isEmpty, "\(validation.warnings.map(\.text))")
        case .warning(let kind):
            #expect(validation.errors.isEmpty, "\(validation.errors)")
            #expect(validation.warnings.first?.kind == kind, "\(validation.warnings.map(\.text))")
        case .error:
            #expect(!validation.errors.isEmpty)
        }
    }

    /// A warning never stops the recorder from saving.
    @Test(arguments: cases.filter { if case .warning = $0.expected { true } else { false } })
    func warningsAreSaved(_ c: Case) {
        // Recording what is already bound changes nothing, so start from an unbound action.
        var bindings = c.bindings
        if bindings[c.action] == c.shortcut { bindings[c.action] = nil }
        let outcome = ShortcutEdit.evaluate(c.shortcut, for: c.action, bindings: bindings, swapAllowed: true,
                                            system: c.system)
        guard case .apply(let warning?) = outcome else {
            Issue.record("expected a save with a warning, got \(outcome)")
            return
        }
        #expect(!warning.text.isEmpty)
    }

    @Test func copyIsShortAndNamesTheCombination() {
        let stock = Self.stock()
        let inputSources = ShortcutValidator.validate(combo(kVK_Space, .control, .option), for: .handsFree, system: stock)
        #expect(inputSources.warnings.first?.text == "macOS also uses ⌃⌥Space for input sources.")
        #expect(inputSources.warnings.first?.detail?.contains("Keyboard Settings") == true)
        let typing = ShortcutValidator.validate(combo(kVK_ANSI_V), for: .pasteLast, system: Self.quiet)
        #expect(typing.warnings.first?.text == "This will fire while you type.")
        #expect(typing.warnings.first?.detail == "Apps won’t get V while it’s bound here.")
        let quit = ShortcutValidator.validate(combo(kVK_ANSI_Q, .command), for: .pasteLast, system: Self.quiet)
        #expect(quit.warnings.first?.text == "Apps use ⌘Q for Quit.")
        let tab = ShortcutValidator.validate(combo(kVK_Tab, .command), for: .handsFree, system: Self.quiet)
        #expect(tab.warnings.first?.text == "macOS also uses ⌘⇥ for the app switcher.")
        #expect(tab.warnings.first?.detail == nil)
    }
}

// MARK: - Keyboard Settings › Keyboard Shortcuts

@Suite struct SystemSymbolicHotKeysTests {
    private static func entry(_ enabled: Any, _ parameters: [Int]? = nil) -> [String: Any] {
        var entry: [String: Any] = ["enabled": enabled]
        if let parameters { entry["value"] = ["parameters": parameters, "type": "standard"] }
        return entry
    }

    /// This Mac as probed: Spotlight (64) off, "select previous input source" (60) moved to ⌘Space and off,
    /// "select next source" (61) on, screenshots rearranged, Spaces (79) on with no value, 164 unset.
    private static var probed: [String: Any] {
        [
            "28": entry(true, [52, 21, 655360]),     // ⌥⇧4
            "29": entry(true, [52, 21, 1179648]),    // ⇧⌘4
            "30": entry(true, [51, 20, 655360]),     // ⌥⇧3
            "31": entry(true, [51, 20, 1179648]),    // ⇧⌘3
            "60": entry(false, [32, 49, 1048576]),   // ⌘Space, off
            "61": entry(true, [32, 49, 786432]),     // ⌃⌥Space
            "64": entry(false, [32, 49, 1048576]),   // ⌘Space, off
            "65": entry(false, [32, 49, 1572864]),   // ⌥⌘Space, off
            "79": entry(true),
            "164": entry(true, [65535, 65535, 0]),
            "184": entry(false, [53, 23, 1179648]),  // ⇧⌘5, off
        ]
    }

    private func hit(_ s: Shortcut, in preferences: [String: Any]?) -> SystemSymbolicHotKeys.HotKey? {
        SystemSymbolicHotKeys.active(in: preferences).first { $0.matches(s) }
    }

    @Test func switchedOffShortcutsDontWarn() {
        #expect(hit(combo(kVK_Space, .control), in: Self.probed) == nil)
        #expect(hit(combo(kVK_Space, .command), in: Self.probed) == nil)
        #expect(hit(combo(kVK_Space, .option, .command), in: Self.probed) == nil)
        #expect(hit(combo(kVK_ANSI_5, .shift, .command), in: Self.probed) == nil)
        let system = SystemKeyboardState(hotKeys: SystemSymbolicHotKeys.active(in: Self.probed), fnUsage: .doNothing,
                                         functionKeysAreStandard: false)
        #expect(ShortcutValidator.validate(combo(kVK_Space, .control), for: .handsFree, system: system).warnings.isEmpty)
        #expect(ShortcutValidator.validate(combo(kVK_Space, .command), for: .pushToTalk, system: system).warnings.isEmpty)
    }

    @Test func switchedOnShortcutsWarnWithTheirPurpose() {
        let next = hit(combo(kVK_Space, .control, .option), in: Self.probed)
        #expect(next?.id == 61)
        #expect(next?.purpose == "input sources")
    }

    @Test func remappedShortcutsWarnOnTheirNewCombination() {
        #expect(hit(combo(kVK_ANSI_4, .option, .shift), in: Self.probed)?.id == 28)
        #expect(hit(combo(kVK_ANSI_4, .shift, .command), in: Self.probed)?.purpose == "screenshots")
        // ⌃⇧⌘4 is 31's default, but 31 now lives on ⇧⌘3.
        #expect(hit(combo(kVK_ANSI_4, .control, .shift, .command), in: Self.probed) == nil)
        // An input-source shortcut moved to ⌘Space and left on.
        let moved: [String: Any] = ["60": Self.entry(true, [32, 49, 1048576]), "64": Self.entry(false)]
        #expect(hit(combo(kVK_Space, .command), in: moved)?.purpose == "input sources")
        #expect(hit(combo(kVK_Space, .control), in: moved) == nil)
    }

    @Test func onWithoutAValueOrNotListedMeansTheMacOSDefault() {
        // 79 is listed as on without parameters: ⌃← (arrows carry the function bit).
        #expect(hit(combo(kVK_LeftArrow, .control), in: Self.probed)?.id == 79)
        // 32 isn't listed at all: Mission Control keeps ⌃↑.
        #expect(hit(combo(kVK_UpArrow, .control), in: Self.probed)?.id == 32)
        // Unreadable preferences: every default is on.
        #expect(SystemSymbolicHotKeys.active(in: nil) == SystemSymbolicHotKeys.defaults)
    }

    @Test func unsetEntriesAndNumericFlagsAreHandled() {
        #expect(!SystemSymbolicHotKeys.active(in: Self.probed).contains { $0.id == 164 })
        let numeric: [String: Any] = ["61": Self.entry(NSNumber(value: 0)), "60": Self.entry(NSNumber(value: 1))]
        #expect(hit(combo(kVK_Space, .control, .option), in: numeric) == nil)
        #expect(hit(combo(kVK_Space, .control), in: numeric)?.id == 60)
    }

    @Test func fnCombinationsNeedTheFunctionBit() {
        let custom: [String: Any] = ["300": Self.entry(true, [101, 14, 8388608])]   // fn E
        #expect(hit(combo(kVK_ANSI_E, .function), in: custom)?.id == 300)
        #expect(hit(combo(kVK_ANSI_E), in: custom) == nil)
        #expect(hit(combo(kVK_ANSI_E, .function), in: custom)?.purpose == nil)
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
        for error in [AppError.openRouterRateLimited(retryAfter: nil), .openRouterNoRoute(""), .timeout(.geminiFlash),
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
        #expect(AppError.offline.localizedDescription == "No connection. Couldn’t reach OpenRouter. Check your internet or VPN.")
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
        #expect(settings.parakeetEngine == .parakeet)
        #expect(settings.lineup == .default)
        #expect(settings.pillMode == .whileDictating)
        #expect(settings.modelColors == .default)
        #expect(settings.shortcuts == .defaults)

        settings.parakeetEngine = .parakeetCloud
        settings.lineup.main = .cleanup
        settings.lineup.setSwitchable(.gemini, false)
        settings.lineup.move(.gemini, to: 0)
        settings.modelColors[.gemini] = .blue
        settings.modelColors[.parakeet] = .teal
        settings.switchHintShownCount = 2
        settings.pillMode = .always
        settings.microphoneUID = "usb-mic"
        settings.soundsEnabled = false
        settings.autoDeleteHistoryDays = 30
        settings.addsSpaceAfterText = true
        settings.removesFinalPeriod = true
        var bindings = ShortcutBindings.defaults
        bindings[.pushToTalk] = .rightOption
        settings.shortcuts = bindings

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.parakeetEngine == .parakeetCloud)
        #expect(reloaded.lineup == settings.lineup)
        #expect(reloaded.lineup.order == [.gemini, .parakeet, .cleanup] && reloaded.lineup.main == .cleanup)
        #expect(reloaded.lineup.cycle == [.cleanup, .parakeet])
        #expect(reloaded.modelColors[.gemini] == .blue && reloaded.modelColors[.parakeet] == .teal)
        #expect(reloaded.modelColors[.cleanup] == .orange)
        #expect(reloaded.switchHintShownCount == 2)
        #expect(reloaded.pillMode == .always)
        #expect(reloaded.microphoneUID == "usb-mic")
        #expect(!reloaded.soundsEnabled)
        #expect(reloaded.autoDeleteHistoryDays == 30)
        #expect(reloaded.addsSpaceAfterText && reloaded.removesFinalPeriod)
        #expect(reloaded.shortcuts[.pushToTalk] == .rightOption)

        settings.microphoneUID = nil
        #expect(AppSettings(defaults: defaults).microphoneUID == nil)
    }

    /// The removed capsule color (General › Pill color): a color left by an older build is dropped; color means the
    /// model now.
    @Test func theRemovedPillColorIsDropped() throws {
        try withSuite { defaults in
            defaults.set("sapphire", forKey: SettingsKey.pillColor.defaultsKey)
            #expect(AppSettings(defaults: defaults).modelColors == .default)
            #expect(defaults.object(forKey: "tt.pillColor") == nil)
            #expect(SettingsKey.pillColor.defaultsKey == "tt.pillColor")
        }
    }

    /// A stored value outlives builds: a color this build doesn't offer, a value of the wrong kind or an unknown model
    /// leaves the defaults. As with the lineup, a load stores what this build reads.
    @Test func storedModelColorsDecodeLeniently() throws {
        let json = #"{"gemini":"blue","cleanup":"chartreuse","whisper":"pink","parakeet":7}"#
        let decoded = try JSONDecoder().decode(ModelColors.self, from: Data(json.utf8))
        #expect(decoded[.gemini] == .blue && decoded[.cleanup] == .orange && decoded[.parakeet] == .graphite)
        #expect(try JSONDecoder().decode(ModelColors.self, from: Data("{}".utf8)) == .default)
        #expect(SettingsKey.modelColors.defaultsKey == "tt.modelColors")

        try withSuite { defaults in
            defaults.set(Data(json.utf8), forKey: SettingsKey.modelColors.defaultsKey)
            let settings = AppSettings(defaults: defaults)
            #expect(settings.modelColors[.gemini] == .blue && settings.modelColors[.cleanup] == .orange)
            let stored = defaults.data(forKey: SettingsKey.modelColors.defaultsKey).map { String(decoding: $0, as: UTF8.self) }
            #expect(stored == #"{"cleanup":"orange","gemini":"blue","parakeet":"graphite"}"#)
            #expect(AppSettings(defaults: defaults).modelColors == settings.modelColors, "a reload changes nothing")
            // Not an object at all: the defaults.
            defaults.set(Data("[]".utf8), forKey: SettingsKey.modelColors.defaultsKey)
            #expect(AppSettings(defaults: defaults).modelColors == .default)
        }
    }

    @Test func modelColorsEncodeStably() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(ModelColors.default), as: UTF8.self)
        #expect(json == #"{"cleanup":"orange","gemini":"violet","parakeet":"graphite"}"#)
        var colors = ModelColors.default
        colors[.cleanup] = .violet
        #expect(try JSONDecoder().decode(ModelColors.self, from: encoder.encode(colors)) == colors)
        #expect(colors[.cleanup] == colors[.gemini], "two may share one")
    }

    /// The pasting switches and Auto-delete are off (Never) out of the box.
    @Test func pastingAndAutoDeleteAreOffByDefault() {
        let settings = AppSettings.inMemory()
        #expect(!settings.addsSpaceAfterText && !settings.removesFinalPeriod)
        #expect(settings.autoDeleteHistoryDays == 0)
    }

    /// "Maximum recording length", "Restore the clipboard after pasting" and the two audio retention choices are
    /// gone: what an older build stored goes at load.
    @Test func removedSettingsAreRemovedAtLoad() throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        let removed: [SettingsKey] = [.maxRecordingMinutes, .restoreClipboard, .keepFailedRecordingsDays,
                                      .keepSuccessfulRecordingsDays]
        defaults.set(10, forKey: SettingsKey.maxRecordingMinutes.defaultsKey)
        defaults.set(false, forKey: SettingsKey.restoreClipboard.defaultsKey)
        defaults.set(14, forKey: SettingsKey.keepFailedRecordingsDays.defaultsKey)
        defaults.set(0, forKey: SettingsKey.keepSuccessfulRecordingsDays.defaultsKey)
        _ = AppSettings(defaults: defaults)
        for key in removed {
            #expect(defaults.object(forKey: key.defaultsKey) == nil, "\(key)")
        }
    }

    /// Double-press for hands-free is off unless the user turned it on: an install that never touched it gets the
    /// new default, one that turned it on keeps it.
    @Test func doublePressIsOffUnlessTheUserTurnedItOn() throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        let key = SettingsKey.doublePressForHandsFree.defaultsKey
        #expect(!AppSettings(defaults: defaults).doublePressForHandsFree)
        #expect(defaults.object(forKey: key) == nil, "nothing is stored until the user flips it")
        #expect(!AppSettings.inMemory().doublePressForHandsFree)
        #expect(DictationMachine.Config().doublePressEnabled, "the machine follows the setting, copied by the controller")

        AppSettings(defaults: defaults).doublePressForHandsFree = true
        #expect(AppSettings(defaults: defaults).doublePressForHandsFree)
    }

    /// Shortcuts saved by a build that still had Copy last transcript load as they were, minus that one.
    @Test func storedShortcutsWithCopyLastStillLoad() throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        let stored = ShortcutBindingsTests.storedBindings(copyLast: ShortcutBindingsTests.storedCopyLast)
        defaults.set(Data(stored.utf8), forKey: "tt.shortcuts")

        let settings = AppSettings(defaults: defaults)
        #expect(settings.shortcuts == ShortcutBindingsTests.customized)
        #expect(settings.shortcuts != .defaults)
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
        #expect(AppSettings(defaults: defaults).parakeetEngine == .default)
        defaults.set(EngineID.parakeetCloud.rawValue, forKey: SettingsKey.selectedEngine.defaultsKey)
        #expect(AppSettings(defaults: defaults).parakeetEngine == .parakeetCloud)
    }

    /// Where Parakeet runs is still stored under the key that named the main model, so an older build reads it too.
    @Test func whereParakeetRunsKeepsTheOldKey() throws {
        try withSuite { defaults in
            defaults.set("parakeetCloud", forKey: SettingsKey.selectedEngine.defaultsKey)
            let settings = AppSettings(defaults: defaults)
            #expect(settings.parakeetEngine == .parakeetCloud)
            #expect(settings.lineup == .default)
            settings.parakeetEngine = .parakeet
            #expect(defaults.string(forKey: SettingsKey.selectedEngine.defaultsKey) == "parakeet")
        }
    }

    /// Gemini was the main model in builds before 0.2.0 (Gemini 3.1 Pro too): it is again, with Parakeet in its
    /// place under the old key.
    @Test(arguments: [EngineID.geminiFlash, .geminiPro])
    func aStoredGeminiMainModelIsTheMainAgain(_ engine: EngineID) throws {
        try withSuite { defaults in
            defaults.set(engine.rawValue, forKey: SettingsKey.selectedEngine.defaultsKey)
            let settings = AppSettings(defaults: defaults)
            #expect(settings.lineup.main == .gemini)
            #expect(settings.parakeetEngine == .parakeet)
            #expect(settings.lineup.cycle == [.gemini, .parakeet, .cleanup])
            #expect(defaults.string(forKey: SettingsKey.selectedEngine.defaultsKey) == EngineID.parakeet.rawValue)
            #expect(AppSettings(defaults: defaults).lineup == settings.lineup, "once")
        }
    }

    @Test func onlyAParakeetRunsParakeet() {
        let settings = AppSettings.inMemory()
        settings.parakeetEngine = .parakeetCloud
        settings.parakeetEngine = .geminiFlash
        #expect(settings.parakeetEngine == .parakeet)
        #expect(EngineID.parakeetRuntimes == [.parakeet, .parakeetCloud])
        #expect(EngineID.offered.filter(\.isParakeet) == EngineID.parakeetRuntimes)
        #expect(!EngineID.geminiPro.isParakeet && CleanupModel.canClean(.parakeetCloud) && !CleanupModel.canClean(.geminiFlash))
    }

    /// The user's settings from 0.2.0 (clean-up off, Gemini on) become the lineup once; the old keys go.
    @Test func theOldSwitchSettingsBecomeTheLineupOnce() throws {
        try withSuite { defaults in
            defaults.set("parakeet", forKey: SettingsKey.selectedEngine.defaultsKey)
            defaults.set(false, forKey: SettingsKey.switchCleanup.defaultsKey)
            defaults.set(try JSONEncoder().encode(["geminiFlash"]), forKey: SettingsKey.switchEngines.defaultsKey)
            let settings = AppSettings(defaults: defaults)
            #expect(settings.lineup.switchable == [.gemini])
            #expect(settings.lineup.cycle == [.parakeet, .gemini])
            #expect(defaults.object(forKey: SettingsKey.switchCleanup.defaultsKey) == nil)
            #expect(defaults.object(forKey: SettingsKey.switchEngines.defaultsKey) == nil)
            #expect(defaults.data(forKey: SettingsKey.lineup.defaultsKey) != nil, "written once, explicitly")
            #expect(AppSettings(defaults: defaults).lineup == settings.lineup, "a reload changes nothing")
        }
        // Today's defaults stored explicitly: the carousel stays as it was.
        try withSuite { defaults in
            defaults.set(true, forKey: SettingsKey.switchCleanup.defaultsKey)
            defaults.set(try JSONEncoder().encode(["geminiFlash"]), forKey: SettingsKey.switchEngines.defaultsKey)
            #expect(AppSettings(defaults: defaults).lineup == .default)
        }
    }

    @Test func legacyGeminiOffIsNotSwitchable() throws {
        try withSuite { defaults in
            defaults.set(try JSONEncoder().encode([String]()), forKey: SettingsKey.switchEngines.defaultsKey)
            let settings = AppSettings(defaults: defaults)
            #expect(!settings.lineup.isSwitchable(.gemini))
            #expect(settings.lineup.cycle == [.parakeet, .cleanup])
        }
        #expect(AppSettings.migratedLineup(storedEngine: nil, switchCleanup: nil, switchEngines: ["geminiPro"])?
            .isSwitchable(.gemini) == false, "the retired Pro isn’t Flash")
    }

    @Test func withNoOldSettingsNothingIsWritten() throws {
        #expect(AppSettings.migratedLineup(storedEngine: nil, switchCleanup: nil, switchEngines: nil) == nil)
        #expect(AppSettings.migratedLineup(storedEngine: .parakeetCloud, switchCleanup: nil, switchEngines: nil) == nil)
        try withSuite { defaults in
            let settings = AppSettings(defaults: defaults)
            #expect(settings.lineup == .default)
            #expect(defaults.object(forKey: SettingsKey.lineup.defaultsKey) == nil)
            #expect(defaults.object(forKey: SettingsKey.selectedEngine.defaultsKey) == nil)
        }
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

    /// The removed "Hide Pill for 1 Hour": a deadline left by an older build is dropped, the pill mode kept.
    @Test func anOldPillHiddenUntilIsRemoved() throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        defaults.set(Date().addingTimeInterval(3600), forKey: SettingsKey.pillHiddenUntil.defaultsKey)
        defaults.set(PillMode.always.rawValue, forKey: SettingsKey.pillMode.defaultsKey)
        #expect(AppSettings(defaults: defaults).pillMode == .always)
        #expect(defaults.object(forKey: SettingsKey.pillHiddenUntil.defaultsKey) == nil)
    }

    // MARK: The removed "Use the built-in mic even when AirPods are connected"

    private func withSuite(_ body: (UserDefaults) throws -> Void) throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        try body(defaults)
    }

    private static let airPodsDefault = MicrophoneMigrationProbe(defaultInput: .bluetooth,
                                                                 availableBuiltInUID: "BuiltInMicrophoneDevice")

    /// (stored switch, onboarding done, stored mic) -> mic after the migration, with AirPods as the default input.
    @Test(arguments: [
        (true as Bool?, true, nil as String?, "BuiltInMicrophoneDevice" as String?),
        (true, false, nil, "BuiltInMicrophoneDevice"),
        (nil, true, nil, "BuiltInMicrophoneDevice"),   // on by default for an existing install
        (nil, false, nil, nil),                         // a fresh install stays Automatic
        (false, true, nil, nil),                        // turned off: Automatic, as it behaved
        (true, true, "usb-mic", "usb-mic"),             // an explicit pick is kept
    ])
    func theOldBuiltInSwitchBecomesAMicChoiceOnce(_ stored: Bool?, onboarded: Bool, mic: String?, expected: String?) throws {
        try withSuite { defaults in
            if let stored { defaults.set(stored, forKey: SettingsKey.preferBuiltInMicOverBluetooth.defaultsKey) }
            defaults.set(onboarded, forKey: SettingsKey.onboardingCompleted.defaultsKey)
            if let mic { defaults.set(mic, forKey: SettingsKey.microphoneUID.defaultsKey) }
            var lookups = 0
            let settings = AppSettings(defaults: defaults, microphoneProbe: {
                lookups += 1
                return Self.airPodsDefault
            })
            #expect(settings.microphoneUID == expected)
            #expect(lookups == (expected == "BuiltInMicrophoneDevice" ? 1 : 0), "the HAL is asked only when needed")
            #expect(defaults.string(forKey: SettingsKey.microphoneUID.defaultsKey) == expected)
            #expect(defaults.object(forKey: SettingsKey.preferBuiltInMicOverBluetooth.defaultsKey) == nil)

            // Once: going back to Automatic afterwards sticks.
            settings.microphoneUID = nil
            let reloaded = AppSettings(defaults: defaults, microphoneProbe: {
                lookups += 100
                return Self.airPodsDefault
            })
            #expect(reloaded.microphoneUID == nil)
            #expect(lookups < 100)
        }
    }

    /// The switch only ever acted on a Bluetooth default: where it wasn't acting, Automatic stays, and a closed
    /// lid never pins a mic that can't record (which would warn about a fallback on every launch).
    /// (stored switch, default input, built-in mic available) -> mic after the migration.
    @Test(arguments: [
        (nil as Bool?, MicrophoneMigrationProbe.DefaultInput.other as MicrophoneMigrationProbe.DefaultInput?,
         true, nil as String?),                                 // USB default, never touched: keeps the USB mic
        (true, .other, true, nil),                              // USB default, turned on: the USB mic, as before
        (nil, .bluetooth, false, nil),                          // lid closed, AirPods default
        (true, .bluetooth, false, nil),
        (nil, .other, false, nil),                              // clamshell with a USB mic
        (nil, .builtInMicrophone, true, nil),                   // untouched, built-in default: stays Automatic
        (true, .builtInMicrophone, true, "BuiltInMicrophoneDevice"), // turned on: AirPods later still don't win
        (nil, nil, true, nil),                                  // no default input at all
    ])
    func theOldSwitchMigratesOnlyWhereItActed(_ stored: Bool?, defaultInput: MicrophoneMigrationProbe.DefaultInput?,
                                              builtInAvailable: Bool, expected: String?) throws {
        try withSuite { defaults in
            if let stored { defaults.set(stored, forKey: SettingsKey.preferBuiltInMicOverBluetooth.defaultsKey) }
            defaults.set(true, forKey: SettingsKey.onboardingCompleted.defaultsKey)
            let probe = MicrophoneMigrationProbe(defaultInput: defaultInput,
                                                 availableBuiltInUID: builtInAvailable ? "BuiltInMicrophoneDevice" : nil)
            let settings = AppSettings(defaults: defaults, microphoneProbe: { probe })
            #expect(settings.microphoneUID == expected)
            #expect(defaults.string(forKey: SettingsKey.microphoneUID.defaultsKey) == expected)
            #expect(defaults.object(forKey: SettingsKey.preferBuiltInMicOverBluetooth.defaultsKey) == nil)
        }
    }

    @Test func noBuiltInMicLeavesAutomatic() throws {
        try withSuite { defaults in
            defaults.set(true, forKey: SettingsKey.preferBuiltInMicOverBluetooth.defaultsKey)
            let probe = MicrophoneMigrationProbe(defaultInput: .bluetooth, availableBuiltInUID: nil)
            #expect(AppSettings(defaults: defaults, microphoneProbe: { probe }).microphoneUID == nil)
            #expect(defaults.object(forKey: SettingsKey.preferBuiltInMicOverBluetooth.defaultsKey) == nil)
        }
    }

    @Test func inMemorySettingsAreIndependent() {
        let a = AppSettings.inMemory()
        let b = AppSettings.inMemory()
        a.parakeetEngine = .parakeetCloud
        a.lineup.main = .gemini
        #expect(b.parakeetEngine == .parakeet && b.lineup == .default)
    }


    @Test func inMemoryKeyStore() throws {
        let keyStore = KeyFileStore.inMemory()
        #expect(try keyStore.lookup() == nil)
        try keyStore.write("secret")
        #expect(try keyStore.lookup() == "secret")
        keyStore.delete()
        #expect(try keyStore.lookup() == nil)
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

// MARK: - The lineup

@Suite struct ModelLineupTests {
    @Test func theDefaultLineupStepsParakeetThenCleanupThenGemini() {
        let lineup = ModelLineup.default
        #expect(lineup.order == [.parakeet, .cleanup, .gemini] && lineup.main == .parakeet)
        #expect(lineup.cycle == [.parakeet, .cleanup, .gemini])
        #expect(lineup.steps == [.cleanup, .gemini])
        #expect(ModelChoice.allCases == [.parakeet, .cleanup, .gemini], "declaration order is the default order")
    }

    @Test func theCycleStartsAtTheMainModelAndWrapsInOrder() {
        var lineup = ModelLineup.default
        lineup.main = .gemini
        #expect(lineup.cycle == [.gemini, .parakeet, .cleanup])
        lineup.main = .cleanup
        #expect(lineup.cycle == [.cleanup, .gemini, .parakeet])
        #expect(lineup.cycle.first == lineup.main)
    }

    @Test func aModelSwitchedOffIsLeftOutButTheMainModelNeverIs() {
        var lineup = ModelLineup.default
        lineup.setSwitchable(.cleanup, false)
        #expect(lineup.cycle == [.parakeet, .gemini])
        lineup.setSwitchable(.parakeet, false)
        #expect(lineup.isSwitchable(.parakeet) && lineup.cycle.first == .parakeet, "the main model's flag is ignored")
        lineup.setSwitchable(.gemini, false)
        #expect(lineup.cycle == [.parakeet] && lineup.steps.isEmpty)
        // The main model it replaces stays in the cycle.
        lineup.main = .gemini
        #expect(lineup.cycle == [.gemini, .parakeet])
    }

    /// A model switched off, then main for a while, is in the cycle after: it was in it all the while it was main.
    @Test func aModelThatStopsBeingMainIsSwitchedOn() {
        var lineup = ModelLineup.default
        lineup.setSwitchable(.gemini, false)
        lineup.main = .gemini
        lineup.main = .parakeet
        #expect(lineup.isSwitchable(.gemini))
        #expect(lineup.cycle == [.parakeet, .cleanup, .gemini])
    }

    @Test func aSentenceListsModelsByShortName() {
        #expect(ModelChoice.sentenceList([]) == ("", false))
        #expect(ModelChoice.sentenceList([.gemini]) == ("Gemini", false))
        #expect(ModelChoice.sentenceList([.cleanup, .gemini]) == ("Clean-up and Gemini", true))
        #expect(ModelChoice.sentenceList([.parakeet, .cleanup, .gemini]) == ("Parakeet, Clean-up and Gemini", true))
    }

    @Test func movingAModelReordersTheCycle() {
        var lineup = ModelLineup.default
        lineup.move(.gemini, to: 0)
        #expect(lineup.order == [.gemini, .parakeet, .cleanup])
        #expect(lineup.cycle == [.parakeet, .cleanup, .gemini], "from the main model, wrapping around")
        lineup.move(.gemini, to: 99)
        #expect(lineup.order == [.parakeet, .cleanup, .gemini], "clamped to the end")
        lineup.move(.cleanup, to: -3)
        #expect(lineup.order == [.cleanup, .parakeet, .gemini], "clamped to the start")
        lineup.move(.cleanup, to: 1)
        #expect(lineup.order == [.parakeet, .cleanup, .gemini])
    }

    @Test func aStoredLineupDecodesLeniently() throws {
        let json = #"{"main":"whisper","order":["gemini","whisper","gemini","parakeet"],"switchable":["gemini","x"]}"#
        let lineup = try JSONDecoder().decode(ModelLineup.self, from: Data(json.utf8))
        #expect(lineup.order == [.gemini, .parakeet, .cleanup], "unknown and duplicate dropped, the missing appended")
        #expect(lineup.main == .parakeet)
        #expect(lineup.switchable == [.gemini], "the appended one is off")
        #expect(try JSONDecoder().decode(ModelLineup.self, from: Data("{}".utf8)).order == ModelChoice.allCases)
    }

    @Test func theLineupEncodesStably() throws {
        var lineup = ModelLineup.default
        lineup.move(.gemini, to: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(lineup), as: UTF8.self)
        #expect(json == #"{"main":"parakeet","order":["gemini","parakeet","cleanup"],"switchable":["gemini","cleanup"]}"#)
        #expect(try JSONDecoder().decode(ModelLineup.self, from: Data(json.utf8)) == lineup)
    }

    /// A job's engine and clean-up flag give its model back, and the model its engine.
    @Test func modelChoiceFromAJob() {
        for parakeet in EngineID.parakeetRuntimes {
            for choice in ModelChoice.allCases {
                let engine = choice.engine(parakeet: parakeet)
                #expect(ModelChoice(engine: engine, cleansUp: choice.cleansUp) == choice)
            }
        }
        #expect(ModelChoice(engine: .geminiFlash, cleansUp: true) == .gemini, "Gemini is never cleaned up")
        #expect(ModelChoice(engine: .geminiPro, cleansUp: false) == .gemini)
    }

    @Test func modelChoiceNames() {
        #expect(ModelChoice.allCases.map(\.modelName) == ["Parakeet v3", "Parakeet v3 + GPT-6 Luna", "Gemini 3.8 Flash"])
        #expect(ModelChoice.parakeet.title(parakeet: .parakeetCloud) == "Parakeet v3 · Cloud")
        #expect(ModelChoice.allCases.map(\.shortName) == ["Parakeet", "Clean-up", "Gemini"])
        #expect(ModelChoice.allCases.map { $0.compactName(parakeet: .parakeet) }
            == ["Parakeet v3", "Parakeet + Luna", "Gemini Flash"])
        #expect(ModelChoice.allCases.map { $0.symbolName(parakeet: .parakeetCloud) }
            == ["cloud.bolt.fill", "wand.and.stars", "sparkles"])
        #expect(ModelChoice.allCases.map { $0.needsOpenRouter(parakeet: .parakeet) } == [false, true, true])
        #expect(ModelChoice.allCases.map { $0.usesLocalParakeet(parakeet: .parakeet) } == [true, true, false])
        #expect(ModelChoice.allCases.map { $0.needsOpenRouter(parakeet: .parakeetCloud) } == [true, true, true])
    }
}
