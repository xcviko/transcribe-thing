import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// The virtual key code that produces "v" (or "c", for ⌘C) *with ⌘ held* in the current keyboard layout.
/// The target app reads the key code through its layout, so a hard-coded `kVK_ANSI_V` is wrong for
/// some layouts. Verified on macOS 26.6: RussianWin/Russian/Greek/Hebrew → 9 (their ⌘ layer is Latin),
/// Dvorak → 47, "Dvorak – QWERTY ⌘" → 9, ABC/German/French/Colemak → 9.
///
/// Resolved on every paste rather than cached: the input-source-changed notification is distributed, and
/// AppKit holds those back while transcribe-thing (an agent app) is inactive, which is nearly always.
@MainActor
enum PasteKeyResolver {
    /// Text Input Sources are main-thread APIs inside apps, hence the main actor. Usually one
    /// `UCKeyTranslate` (the ANSI V check answers for most layouts).
    static func resolveCurrent() -> CGKeyCode {
        resolveCurrent(letter: "v", ansi: KeyCode.ansiV)
    }

    /// ⌘C's key, for copying what's selected.
    static func resolveCurrentCopy() -> CGKeyCode {
        resolveCurrent(letter: "c", ansi: KeyCode.ansiC)
    }

    private static func resolveCurrent(letter: String, ansi: UInt16) -> CGKeyCode {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return CGKeyCode(ansi) }
        return resolve(source: source, letter: letter, ansi: ansi) ?? CGKeyCode(ansi)
    }

    static let fallback = CGKeyCode(kVK_ANSI_V)

    static func resolve(source: TISInputSource, letter: String = "v", ansi: UInt16 = KeyCode.ansiV) -> CGKeyCode? {
        let command = UInt32(cmdKey)
        if KeyboardLayout.translate(keyCode: ansi, carbonModifiers: command, source: source)?.lowercased() == letter {
            return CGKeyCode(ansi)
        }
        for code in UInt16(0)..<128 where !KeyCode.modifierKeyCodes.contains(code) {
            if KeyboardLayout.translate(keyCode: code, carbonModifiers: command, source: source)?.lowercased() == letter {
                return CGKeyCode(code)
            }
        }
        return nil
    }

    /// The current keyboard layout as this app sees it, by its short id ("RussianWin", "ABC"), for the log.
    static func currentLayoutName() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return shortName(Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String)
    }

    /// The layout macOS last saved as current (com.apple.HIToolbox), which a switch made from another app updates
    /// even when this app isn't told of it.
    static func savedLayoutName() -> String? {
        let key = "AppleCurrentKeyboardLayoutInputSourceID" as CFString
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        guard let id = CFPreferencesCopyAppValue(key, "com.apple.HIToolbox" as CFString) as? String else { return nil }
        return shortName(id)
    }

    private static func shortName(_ id: String) -> String {
        id.replacingOccurrences(of: "com.apple.keylayout.", with: "")
    }

    /// An installed keyboard layout by id ("com.apple.keylayout.Dvorak"), enabled or not.
    static func layout(id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first
    }
}
