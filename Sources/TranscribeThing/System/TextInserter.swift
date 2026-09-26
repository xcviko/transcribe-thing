import AppKit
import Carbon.HIToolbox
import CoreGraphics
import os

enum InsertionOutcome: Equatable, Sendable {
    case pasted
    /// No text field has focus, or it is a password field. Nothing was pasted or copied.
    case noEditableTarget
    /// Another app came to the front while we transcribed. Nothing was pasted or copied.
    case targetChanged
    /// transcribe-thing may not post keystrokes. The text was copied to the clipboard.
    case accessibilityMissing
    case failed(String)
}

/// Pastes text at the cursor of the frontmost app: pasteboard + a synthetic, layout-correct ⌘V, then the
/// user's clipboard is put back. On any outcome other than `.pasted` the caller still holds the text and
/// shows it in a transcript card.
@MainActor
final class TextInserter {
    /// Everything that touches the system, injectable so the pipeline is testable without posting events.
    struct System {
        var frontmostPID: @MainActor () -> pid_t?
        /// PostEvent permission (listed under Accessibility). Called off the main thread.
        var canPostEvents: @Sendable () -> Bool
        /// Any of ⌘ ⌃ ⌥ ⇧ fn physically held right now.
        var modifiersHeld: @MainActor () -> Bool
        var inspectFocus: @Sendable () async -> FocusInfo
        var pasteKeyCode: @MainActor () -> CGKeyCode
        /// Posts ⌘V; false if the event source couldn't be created. Called off the main thread.
        var postPaste: @Sendable (CGKeyCode) -> Bool
    }

    var restoreDelay: Duration = .milliseconds(800)
    var modifierReleaseTimeout: Duration = .milliseconds(600)
    /// Our active event tap is running. Creating an active tap requires the same PostEvent grant, so a live
    /// tap proves we may post ⌘V even when the preflight still answers from its stale per-process cache.
    var eventTapActive: @MainActor () -> Bool = { false }

    private let settings: AppSettings
    private let pasteboard: NSPasteboard
    private var system: System
    private var pendingRestore: PendingRestore?
    private var queueTail: Task<Void, Never>?

    private struct PendingRestore {
        var original: PasteboardSnapshot
        var ourChangeCount: Int
        var task: Task<Void, Never>
    }

    init(settings: AppSettings) {
        self.settings = settings
        self.pasteboard = .general
        self.system = System(
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            // CGPreflightPostEventAccess() caches its first answer for the life of the process, so a grant
            // given after launch stays "denied" there; AXIsProcessTrusted() follows live changes.
            canPostEvents: { AXIsProcessTrusted() || CGPreflightPostEventAccess() },
            modifiersHeld: { TextInserter.physicalModifiersHeld() },
            inspectFocus: { await FocusInspector.inspect() },
            pasteKeyCode: { PasteKeyResolver.resolveCurrent() },
            postPaste: { TextInserter.postCommandV(keyCode: $0) })
    }

    /// Tests: a private pasteboard and fake system hooks.
    init(settings: AppSettings, pasteboard: NSPasteboard, system: System) {
        self.settings = settings
        self.pasteboard = pasteboard
        self.system = system
    }

    func frontmostPID() -> pid_t? {
        system.frontmostPID()
    }

    /// Pastes into the app that was frontmost when the recording stopped (`expectedPID`).
    func insert(_ text: String, expectedPID: pid_t?) async -> InsertionOutcome {
        await serialized { await self.performInsert(text, expectedPID: expectedPID) }
    }

    /// "Paste here": paste into whatever has focus now, without focus or target checks.
    func pasteNow(_ text: String) async -> InsertionOutcome {
        await serialized { await self.performPasteNow(text) }
    }

    private func performInsert(_ text: String, expectedPID: pid_t?) async -> InsertionOutcome {
        guard !text.isEmpty else { return .failed("There was no text to paste.") }
        if let outcome = await checkPermission(for: text) { return outcome }
        if let expectedPID, system.frontmostPID() != expectedPID { return .targetChanged }

        await waitForModifierRelease()
        let focus = await system.inspectFocus()
        Log.app.notice("Paste target: \(focus.bundleID ?? "?", privacy: .public) role=\(focus.role ?? "-", privacy: .public) subrole=\(focus.subrole ?? "-", privacy: .public) editable=\(String(describing: focus.editability), privacy: .public)")
        if let expectedPID, let focusPID = focus.pid, focusPID != expectedPID { return .targetChanged }
        if let expectedPID, system.frontmostPID() != expectedPID { return .targetChanged }
        if focus.isSecure || focus.editability == .notEditable {
            // Leave the clipboard alone: the transcript card offers Copy, and paste-last works once a text
            // field has focus. Next to a password field this also keeps the text out of clipboard history.
            return .noEditableTarget
        }

        var final = text
        if let previous = focus.precedingCharacter, Self.needsLeadingSpace(after: previous, before: text) {
            final = " " + text
        }
        return await paste(final)
    }

    private func performPasteNow(_ text: String) async -> InsertionOutcome {
        guard !text.isEmpty else { return .failed("There was no text to paste.") }
        if let outcome = await checkPermission(for: text) { return outcome }
        await waitForModifierRelease()
        return await paste(text)
    }

    /// A normal, persistent copy (it stays on the clipboard and syncs like any other copy).
    func copy(_ text: String) {
        cancelPendingRestore()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(Self.bundleID, forType: PasteboardSnapshot.sourceType)
        _ = pasteboard.writeObjects([item])
    }

    // MARK: Pipeline

    /// One insertion at a time: each suspends (focus probe, ⌘V) and a second one starting in between would
    /// snapshot the first transcript as "the user's clipboard".
    private func serialized(_ work: @escaping @MainActor () async -> InsertionOutcome) async -> InsertionOutcome {
        let previous = queueTail
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        queueTail = Task { @MainActor in _ = await task.value }
        return await task.value
    }

    private func checkPermission(for text: String) async -> InsertionOutcome? {
        if eventTapActive() { return nil }
        let canPost = system.canPostEvents
        guard await Task.detached(priority: .userInitiated, operation: { canPost() }).value else {
            copy(text)
            return .accessibilityMissing
        }
        return nil
    }

    private func paste(_ text: String) async -> InsertionOutcome {
        let original = takeOriginalClipboard()
        let transient = original != nil

        if transient {
            // Keep the transient text off Universal Clipboard.
            _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        } else {
            pasteboard.clearContents()
        }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(Self.bundleID, forType: PasteboardSnapshot.sourceType)
        if transient {
            for marker in [PasteboardSnapshot.transientType, PasteboardSnapshot.autoGeneratedType,
                           PasteboardSnapshot.concealedType] {
                item.setData(Data(), forType: marker)
            }
        }
        guard pasteboard.writeObjects([item]) else {
            original?.restore(to: pasteboard)
            return .failed("\(Brand.name) couldn’t use the clipboard.")
        }
        let ourChangeCount = pasteboard.changeCount

        let keyCode = system.pasteKeyCode()
        let post = system.postPaste
        let posted = await Task.detached(priority: .userInitiated) { post(keyCode) }.value
        guard posted else {
            if let original, pasteboard.changeCount == ourChangeCount { original.restore(to: pasteboard) }
            return .failed("\(Brand.name) couldn’t send the paste keystroke.")
        }
        if let original { scheduleRestore(original, ourChangeCount: ourChangeCount) }
        return .pasted
    }

    /// The clipboard to put back after pasting, or nil to leave the transcript on it.
    /// Back-to-back pastes reuse the original still waiting to be restored, so the user's own clipboard
    /// (not the previous transcript) comes back at the end.
    private func takeOriginalClipboard() -> PasteboardSnapshot? {
        var original: PasteboardSnapshot?
        if let pending = pendingRestore {
            pending.task.cancel()
            pendingRestore = nil
            if pasteboard.changeCount == pending.ourChangeCount { original = pending.original }
        }
        guard settings.restoreClipboard else { return nil }
        if original == nil, PasteboardSnapshot.mayRead(pasteboard) {
            original = PasteboardSnapshot.capture(pasteboard)
        }
        return original
    }

    private func scheduleRestore(_ original: PasteboardSnapshot, ourChangeCount: Int) {
        let delay = restoreDelay
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pendingRestore = nil
            // Someone copied something since our paste: theirs wins.
            guard self.pasteboard.changeCount == ourChangeCount else { return }
            if original.containsConcealed {
                // Restoring bumps changeCount, which stops password managers from auto-clearing the secret.
                self.pasteboard.clearContents()
            } else {
                original.restore(to: self.pasteboard)
            }
        }
        pendingRestore = PendingRestore(original: original, ourChangeCount: ourChangeCount, task: task)
    }

    private func cancelPendingRestore() {
        pendingRestore?.task.cancel()
        pendingRestore = nil
    }

    /// A chord like ⌃⌥ may still be half-held when the PTT release stops recording; ⌘V with ⌥ held
    /// would type something else.
    private func waitForModifierRelease() async {
        let deadline = ContinuousClock.now + modifierReleaseTimeout
        while system.modifiersHeld(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    // MARK: Helpers

    private static var bundleID: String { Bundle.main.bundleIdentifier ?? "dev.transcribe-thing.app" }

    /// A space goes in only after a known, non-space, non-opening character, and never before closing
    /// punctuation. Consecutive dictations then flow without trailing blanks.
    nonisolated static func needsLeadingSpace(after previous: Character, before text: String) -> Bool {
        guard let first = text.first else { return false }
        if previous.isWhitespace || previous.isNewline { return false }
        if "([{«\"'“‘/-–—\u{00A0}".contains(previous) { return false }
        if first.isWhitespace || first.isNewline { return false }
        if ".,;:!?…)]}»”’%".contains(first) { return false }
        return true
    }

    nonisolated static func physicalModifiersHeld() -> Bool {
        let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        return !CGEventSource.flagsState(.combinedSessionState).intersection(relevant).isEmpty
    }

    /// ⌘ down, V down, V up, ⌘ up from the combined session state, posted at the session tap (posting at
    /// the HID tap would also mutate the HID state table, and a lost keyUp could leave ⌘ stuck).
    nonisolated static func postCommandV(keyCode: CGKeyCode) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        source.userData = SyntheticEvent.tag
        // Never hold back the user's own keys: a suppressed flagsChanged would be a PTT release our tap never
        // sees (the recording would run on, with a phantom Fn held), and typed keys would be lost. The four
        // posts take about 15 ms, so interleaving is unlikely anyway.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)

        let commandFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | DeviceModifierMask.leftCommand)
        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false)
        else { return false }
        commandDown.flags = commandFlags
        vDown.flags = commandFlags
        vUp.flags = commandFlags
        commandUp.flags = []

        // Small gaps help slow consumers (Electron, remote desktops). About 15 ms in total.
        commandDown.post(tap: .cgSessionEventTap)
        usleep(5_000)
        vDown.post(tap: .cgSessionEventTap)
        usleep(5_000)
        vUp.post(tap: .cgSessionEventTap)
        usleep(5_000)
        commandUp.post(tap: .cgSessionEventTap)
        return true
    }
}
