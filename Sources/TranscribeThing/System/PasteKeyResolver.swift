import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// The virtual key code that produces "v" *with ⌘ held* in the current keyboard layout.
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
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return fallback }
        return resolve(source: source) ?? fallback
    }

    static let fallback = CGKeyCode(kVK_ANSI_V)

    static func resolve(source: TISInputSource) -> CGKeyCode? {
        let command = UInt32(cmdKey)
        if KeyboardLayout.translate(keyCode: KeyCode.ansiV, carbonModifiers: command, source: source)?.lowercased() == "v" {
            return CGKeyCode(KeyCode.ansiV)
        }
        for code in UInt16(0)..<128 where !KeyCode.modifierKeyCodes.contains(code) {
            if KeyboardLayout.translate(keyCode: code, carbonModifiers: command, source: source)?.lowercased() == "v" {
                return CGKeyCode(code)
            }
        }
        return nil
    }

    /// An installed keyboard layout by id ("com.apple.keylayout.Dvorak"), enabled or not.
    static func layout(id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first
    }
}
