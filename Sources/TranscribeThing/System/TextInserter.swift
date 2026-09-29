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
    /// transcribe-thing may not post keystrokes. Nothing was pasted or copied.
    case accessibilityMissing
    /// Nothing was pasted, and the clipboard is as it was.
    case failed(String)
}

/// Pastes text at the cursor of the frontmost app: the text goes on the clipboard only for a synthetic, layout-correct
/// ⌘V, and what the clipboard held before (every item with every type: text, images, files) comes back once the target
/// has read it. Only `copy(_:)` puts text there to stay. On any outcome other than `.pasted` the caller still holds the
/// text and shows it in a transcript card.
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

    /// The earliest the clipboard a paste replaced comes back after ⌘V. ⌘V is only queued: the target reads the
    /// clipboard when its main thread gets to the keystroke, 1–25 ms later in most apps and about a second later on a
    /// busy page (pladder, PR #66), later than 75 ms in Electron apps and on a cold start (souffle, PR #110: those pasted
    /// the old clipboard, and it moved to 400 ms). No fixed delay serves both, so the text is handed over lazily and
    /// its first read is the signal, as in pladder: the clipboard comes back once this has passed since ⌘V and
    /// `readGrace` since that read, or `unreadTimeout` after ⌘V if nothing reads it. The floor is there because the
    /// first reader may be a clipboard helper rather than the target; kept short, so is the time in which the user's
    /// own ⌘V would paste the transcript. A copy made meanwhile is never overwritten.
    var restoreDelay: Duration = .milliseconds(400)
    /// How long after the text's first read the clipboard stays as it is, for a target that reads more than once.
    var readGrace: Duration = .milliseconds(200)
    /// When nothing reads the text (the ⌘V went where nothing takes a paste), the clipboard comes back after this.
    /// Up to then the user's own ⌘V pastes the transcript, and that read brings the clipboard back `readGrace` later.
    var unreadTimeout: Duration = .seconds(8)
    var modifierReleaseTimeout: Duration = .milliseconds(600)
    /// Our active event tap is running. Creating an active tap requires the same PostEvent grant, so a live
    /// tap proves we may post ⌘V even when the preflight still answers from its stale per-process cache.
    var eventTapActive: @MainActor () -> Bool = { false }

    private let pasteboard: NSPasteboard
    private var system: System
    private var pendingRestore: PendingRestore?
    /// The clipboard as `prepareToPaste()` read it, for the next paste while nothing has changed it since.
    private var prepared: (changeCount: Int, snapshot: PasteboardSnapshot?)?
    private var queueTail: Task<Void, Never>?

    private struct PendingRestore {
        /// Nil when the clipboard couldn't be kept (`PasteboardSnapshot.capture`): the pasted text then stays.
        var original: PasteboardSnapshot?
        var ourChangeCount: Int
        var task: Task<Void, Never>
    }

    init() {
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
    init(pasteboard: NSPasteboard, system: System) {
        self.pasteboard = pasteboard
        self.system = system
    }

    func frontmostPID() -> pid_t? {
        system.frontmostPID()
    }

    /// Pastes into the app that was frontmost when the recording stopped (`expectedPID`; nil for paste last).
    func insert(_ text: String, expectedPID: pid_t?) async -> InsertionOutcome {
        await serialized { await self.performInsert(text, expectedPID: expectedPID) }
    }

    /// "Paste here": paste into whatever has focus now, without focus or target checks.
    func pasteNow(_ text: String) async -> InsertionOutcome {
        await serialized { await self.performPasteNow(text) }
    }

    private func performInsert(_ text: String, expectedPID: pid_t?) async -> InsertionOutcome {
        guard !text.isEmpty else { return .failed("There was no text to paste.") }
        guard await mayPostEvents() else { return .accessibilityMissing }
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
        guard await mayPostEvents() else { return .accessibilityMissing }
        await waitForModifierRelease()
        return await paste(text)
    }

    /// A dictation is being transcribed: its paste will need the clipboard as it is, so it's read now rather than
    /// between the target checks and ⌘V, where a large or slow one (`PasteboardSnapshot.timeLimit`) would hold the
    /// paste up. While a restore is pending, the clipboard holds a transcript and the paste takes over that restore.
    func prepareToPaste() {
        guard pendingRestore == nil else { return }
        let changeCount = pasteboard.changeCount
        guard prepared?.changeCount != changeCount else { return }
        prepared = (changeCount, captureClipboard())
    }

    /// A normal, persistent copy (the Copy buttons): it stays on the clipboard and syncs like any other copy.
    func copy(_ text: String) {
        cancelPendingRestore()
        prepared = nil
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(Self.bundleID, forType: PasteboardMarkers.sourceType)
        _ = pasteboard.writeObjects([item])
    }

    // MARK: Pipeline

    /// One insertion at a time: each suspends (focus probe, ⌘V), and a second one starting in between would change
    /// the clipboard under the first one's ⌘V.
    private func serialized(_ work: @escaping @MainActor () async -> InsertionOutcome) async -> InsertionOutcome {
        let previous = queueTail
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        queueTail = Task { @MainActor in _ = await task.value }
        return await task.value
    }

    private func mayPostEvents() async -> Bool {
        if eventTapActive() { return true }
        let canPost = system.canPostEvents
        return await Task.detached(priority: .userInitiated, operation: { canPost() }).value
    }

    /// Pastes `text` from a transient clipboard item, then puts back what the clipboard held before once the target
    /// has had it (`restoreDelay`), unless someone copied something since. When the paste can't go ahead, it comes back
    /// at once.
    private func paste(_ text: String) async -> InsertionOutcome {
        let original = takeOriginalClipboard()
        // Handed over when read, so the restore can wait for the target; written outright with nothing to put back.
        let source = original.map { _ in PastedTextSource(text) }
        // Only there for the ⌘V: off Universal Clipboard, and marked so clipboard managers skip it.
        _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        if let source {
            item.setDataProvider(source, forTypes: [.string])
        } else {
            item.setString(text, forType: .string)
        }
        item.setString(Self.bundleID, forType: PasteboardMarkers.sourceType)
        for marker in [PasteboardMarkers.transientType, PasteboardMarkers.autoGeneratedType,
                       PasteboardMarkers.concealedType] {
            item.setData(Data(), forType: marker)
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
            if pasteboard.changeCount == ourChangeCount { original?.restore(to: pasteboard) }
            return .failed("\(Brand.name) couldn’t send the paste keystroke.")
        }
        scheduleRestore(original, source: source, pastedAt: .now, ourChangeCount: ourChangeCount)
        return .pasted
    }

    /// What the clipboard held before this paste. A paste while the previous one's restore is still waiting takes
    /// over that one's original, so the user's own clipboard comes back at the end, not the previous transcript.
    private func takeOriginalClipboard() -> PasteboardSnapshot? {
        let prepared = prepared
        self.prepared = nil
        if let pending = pendingRestore {
            pending.task.cancel()
            pendingRestore = nil
            if pasteboard.changeCount == pending.ourChangeCount { return pending.original }
        }
        if let prepared, prepared.changeCount == pasteboard.changeCount { return prepared.snapshot }
        return captureClipboard()
    }

    private func captureClipboard() -> PasteboardSnapshot? {
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        if snapshot == nil { Log.app.notice("The clipboard can’t be kept for a paste; the pasted text stays on it") }
        return snapshot
    }

    private func scheduleRestore(_ original: PasteboardSnapshot?, source: PastedTextSource?,
                                 pastedAt: ContinuousClock.Instant, ourChangeCount: Int) {
        let earliest = pastedAt + restoreDelay, readGrace = readGrace, latest = pastedAt + unreadTimeout
        let task = Task { @MainActor [weak self] in
            guard await Self.waitForTheTarget(source, earliest: earliest, readGrace: readGrace, latest: latest),
                  !Task.isCancelled, let self else { return }
            self.pendingRestore = nil
            // Someone copied something since our paste: theirs wins.
            guard self.pasteboard.changeCount == ourChangeCount else { return }
            original?.restore(to: self.pasteboard)
        }
        pendingRestore = PendingRestore(original: original, ourChangeCount: ourChangeCount, task: task)
    }

    /// Until the target has had the text: `earliest`, and `readGrace` after its first read, or `latest` when nothing
    /// reads it. Only the floor without a `source` (nothing to wait for). False when canceled.
    private static func waitForTheTarget(_ source: PastedTextSource?, earliest: ContinuousClock.Instant,
                                         readGrace: Duration, latest: ContinuousClock.Instant) async -> Bool {
        do {
            try await Task.sleep(until: earliest)
            guard let source else { return true }
            while true {
                if let readAt = source.firstRead {
                    try await Task.sleep(until: readAt + readGrace)
                    return true
                }
                if ContinuousClock.now >= latest { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            return false
        }
    }

    /// The app is quitting: what a paste replaced comes back now instead of never.
    func flushPendingRestore() {
        guard let pending = pendingRestore else { return }
        cancelPendingRestore()
        guard pasteboard.changeCount == pending.ourChangeCount else { return }
        pending.original?.restore(to: pasteboard)
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

/// Gives the pasted text to whoever reads the clipboard, and notes when that first happens: the target reading it is
/// the one sign that the paste has been taken. Asked once, on the main thread when another app reads; the pasteboard
/// keeps the text from then on for later reads.
private final class PastedTextSource: NSObject, NSPasteboardItemDataProvider, Sendable {
    private let text: String
    private let read = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

    init(_ text: String) {
        self.text = text
    }

    var firstRead: ContinuousClock.Instant? {
        read.withLock { $0 }
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        read.withLock { $0 = $0 ?? .now }
        item.setString(text, forType: type)
    }
}
