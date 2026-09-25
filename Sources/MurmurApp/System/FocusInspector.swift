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
/// main thread with a short messaging timeout (and the main thread must stay free: pasting into Murmur's own
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
