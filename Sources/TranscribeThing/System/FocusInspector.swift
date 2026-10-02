import AppKit
import ApplicationServices
import os

/// What the focused UI element of the frontmost app looks like, as far as Accessibility can tell.
struct FocusInfo: Equatable, Sendable {
    enum Editability: Equatable, Sendable { case editable, notEditable, unknown }

    var pid: pid_t?
    var bundleID: String?
    var role: String?
    var subrole: String?
    var editability: Editability = .unknown
    var isSecure = false
    /// The character right before the insertion point, when readable.
    var precedingCharacter: Character?

    static let unknown = FocusInfo()
}

/// Accessibility focus probe. Every AX call is synchronous IPC to another app, so all of this runs off the
/// main thread with a short messaging timeout (and the main thread must stay free: pasting into transcribe-thing's own
/// window is answered by our main thread).
enum FocusInspector {
    private static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
    private static let nonTextRoles: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXSliderRole, kAXMenuItemRole, kAXMenuBarItemRole,
        kAXListRole, kAXTableRole, kAXOutlineRole, kAXImageRole, kAXPopUpButtonRole, kAXBrowserRole,
        kAXScrollBarRole, kAXToolbarRole, kAXTabGroupRole, kAXDisclosureTriangleRole, kAXColumnRole, kAXRowRole,
    ]

    /// Tri-state probe with an overall deadline: an app that hangs its AX thread yields `.unknown`
    /// (and we paste anyway) instead of stalling the dictation.
    static func inspect(timeout: TimeInterval = 0.25, deadline: TimeInterval = 0.4) async -> FocusInfo {
        let target = await MainActor.run { () -> (pid: pid_t, bundleID: String?)? in
            NSWorkspace.shared.frontmostApplication.map { ($0.processIdentifier, $0.bundleIdentifier) }
        }
        guard let target else { return .unknown }
        let once = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<FocusInfo, Never>) in
            let finish: @Sendable (FocusInfo) -> Void = { info in
                let first = once.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: info) }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                finish(inspectNow(pid: target.pid, bundleID: target.bundleID, timeout: Float(timeout)))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) {
                finish(.unknown)
            }
        }
    }

    /// Synchronous probe of the app `pid`. Never call on the main thread.
    static func inspectNow(pid: pid_t, bundleID: String?, timeout: Float) -> FocusInfo {
        var info = FocusInfo()
        info.pid = pid
        info.bundleID = bundleID
        guard AXIsProcessTrusted() else { return info }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, timeout)
        var focusedRef: CFTypeRef?
        var error = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        if error != .success {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, timeout)
            error = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        }
        // Electron without an AX tree, games and most terminals land here: unknown, paste anyway.
        guard error == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return info }
        let element = unsafeDowncast(focusedRef, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, timeout)

        info.role = string(element, kAXRoleAttribute)
        info.subrole = string(element, kAXSubroleAttribute)
        info.isSecure = info.subrole == kAXSecureTextFieldSubrole

        var settable = DarwinBoolean(false)
        let settableKnown = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
        var rangeRef: CFTypeRef?
        let hasRange = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success

        if let role = info.role, textRoles.contains(role) {
            info.editability = .editable
        } else if hasRange && settableKnown && settable.boolValue {
            info.editability = .editable
        } else if let role = info.role, nonTextRoles.contains(role) {
            info.editability = .notEditable
        }

        if !info.isSecure, hasRange, let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            info.precedingCharacter = precedingCharacter(element, range: unsafeDowncast(rangeRef, to: AXValue.self))
        }
        return info
    }

    /// The longest selection Polish Selection takes (about 3,000 words): past that it's a document, not a message.
    static let maxSelection = 20_000

    /// What a look at the selection found, and why it found nothing: for the log (`DiagnosticLog`), which names the app
    /// (its bundle id) and the outcome, never the text.
    struct SelectionLookup: Sendable {
        enum Outcome: String, Sendable {
            case found
            case nothingSelected
            /// The app has no focused element it tells Accessibility about: Chrome and Electron apps, by default.
            case noFocusedElement
            /// The focused element doesn't say what's selected in it (a terminal, a canvas): something may be.
            case selectionUnsupported
            case passwordField
            case tooLong
            case timedOut
            case noAccessibility
            case noApp
        }

        var text: String?
        var outcome: Outcome
        var app: String?

        /// Whether anything is selected is known: it's `text`, or nothing is (or no app is in front). Otherwise the
        /// app couldn't say, and there may be a selection a key would type over.
        var isKnown: Bool { outcome == .found || outcome == .nothingSelected || outcome == .noApp }
    }

    /// The text selected in the focused field of the frontmost app, for Polish Selection and the dictionary:
    /// Accessibility only, so the clipboard is never touched. nil when nothing (or only whitespace) is selected, in a
    /// password field, past `maxSelection`, or when the app doesn't say within `deadline` (Electron without an AX tree,
    /// most terminals).
    static func selectedText(timeout: TimeInterval = 0.2, deadline: TimeInterval = 0.35) async -> String? {
        await lookUpSelection(timeout: timeout, deadline: deadline).text
    }

    /// `selectedText`, with what it found out on the way.
    static func lookUpSelection(timeout: TimeInterval = 0.2, deadline: TimeInterval = 0.35) async -> SelectionLookup {
        let (pid, app) = await MainActor.run {
            (NSWorkspace.shared.frontmostApplication?.processIdentifier,
             NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        }
        guard let pid else { return SelectionLookup(outcome: .noApp) }
        let once = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<SelectionLookup, Never>) in
            let finish: @Sendable (SelectionLookup) -> Void = { lookup in
                let first = once.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: lookup) }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let (text, outcome) = selectedTextNow(pid: pid, timeout: Float(timeout))
                finish(SelectionLookup(text: text, outcome: outcome, app: app))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) {
                finish(SelectionLookup(outcome: .timedOut, app: app))
            }
        }
    }

    /// Synchronous read of the selection in app `pid`, and why there's none. Never call on the main thread.
    static func selectedTextNow(pid: pid_t, timeout: Float) -> (String?, SelectionLookup.Outcome) {
        guard AXIsProcessTrusted() else { return (nil, .noAccessibility) }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, timeout)
        var focusedRef: CFTypeRef?
        let focused = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        // An app that doesn't answer within `timeout` comes back as .cannotComplete.
        guard focused != .cannotComplete else { return (nil, .timedOut) }
        guard focused == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return (nil, .noFocusedElement)
        }
        let element = unsafeDowncast(focusedRef, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, timeout)
        guard string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole else { return (nil, .passwordField) }
        var selectedRef: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef) {
        case .success, .noValue: break
        case .cannotComplete: return (nil, .timedOut)
        default: return (nil, .selectionUnsupported)
        }
        guard let text = selectedRef as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (nil, .nothingSelected) }
        guard text.count <= maxSelection else { return (nil, .tooLong) }
        return (text, .found)
    }

    /// One cheap parameterized read of the single character before the selection; never the whole value.
    private static func precedingCharacter(_ element: AXUIElement, range value: AXValue) -> Character? {
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value, .cfRange, &range), range.location > 0 else { return nil }
        var previous = CFRange(location: range.location - 1, length: 1)
        guard let parameter = AXValueCreate(.cfRange, &previous) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &out) == .success,
            let text = out as? String else { return nil }
        return text.last
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
