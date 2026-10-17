import AppKit
import Carbon.HIToolbox
import CoreGraphics
import os

enum InsertionOutcome: Equatable, Sendable {
    case pasted
    /// The cursor is in a password field, where dictated text never goes. Nothing was pasted or copied.
    case passwordField
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
        /// PostEvent permission (listed under Accessibility). Called off the main thread.
        var canPostEvents: @Sendable () -> Bool
        /// Any of ⌘ ⌃ ⌥ ⇧ fn physically held right now.
        var modifiersHeld: @MainActor () -> Bool
        var inspectFocus: @Sendable () async -> FocusInfo
        var pasteKeyCode: @MainActor () -> CGKeyCode
        /// Posts ⌘V; false if the event source couldn't be created. Called off the main thread.
        var postPaste: @Sendable (CGKeyCode) -> Bool
        var copyKeyCode: @MainActor () -> CGKeyCode = { PasteKeyResolver.resolveCurrentCopy() }
        /// Posts ⌘C, as `postPaste` does ⌘V (`copySelection`).
        var postCopy: @Sendable (CGKeyCode) -> Bool = { _ in false }
        /// The app in front, which a paste goes to: Send's Return goes only to the one its paste went to.
        var frontmostApp: @MainActor () -> pid_t? = { nil }
        /// Posts Return, as `postPaste` does ⌘V (`pressReturn`).
        var postReturn: @Sendable () -> Bool = { false }
    }

    /// What Send's Return came to (`pressReturn()`).
    enum ReturnOutcome: String, Equatable, Sendable {
        case pressed
        /// The app the text was pasted into isn't in front any more: Return would land somewhere else.
        case appChanged
        /// No paste to follow, no permission to post keys, or the key couldn't be posted.
        case failed
    }

    /// What copying the selection found (`copySelection()`).
    enum SelectionCopy: Equatable, Sendable {
        case text(String)
        /// ⌘C copied nothing (the clipboard didn't change), or only the whole line VS Code copies for an empty
        /// selection.
        case nothing
        /// It couldn't be tried: no permission to post keys, or a clipboard that couldn't be put back after.
        case unavailable
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
    /// Where whether each paste was taken is written (`paste.read`).
    var log: DiagnosticLog = .shared
    var modifierReleaseTimeout: Duration = .milliseconds(600)
    /// How long ⌘C has to put the selection on the clipboard: an Electron app takes tens of milliseconds, a busy one
    /// longer. Past this, nothing was selected.
    var copyTimeout: Duration = .milliseconds(500)
    /// Our active event tap is running. Creating an active tap requires the same PostEvent grant, so a live
    /// tap proves we may post ⌘V even when the preflight still answers from its stale per-process cache.
    var eventTapActive: @MainActor () -> Bool = { false }

    private let pasteboard: NSPasteboard
    private var system: System
    private var pendingRestore: PendingRestore?
    /// The app the last paste's ⌘V went to (`System.frontmostApp`), for Send's Return.
    private var lastPasteTarget: pid_t?
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
            // CGPreflightPostEventAccess() caches its first answer for the life of the process, so a grant
            // given after launch stays "denied" there; AXIsProcessTrusted() follows live changes.
            canPostEvents: { AXIsProcessTrusted() || CGPreflightPostEventAccess() },
            modifiersHeld: { TextInserter.physicalModifiersHeld() },
            inspectFocus: { await FocusInspector.inspect() },
            pasteKeyCode: { PasteKeyResolver.resolveCurrent() },
            postPaste: { TextInserter.postCommand(keyCode: $0) },
            postCopy: { TextInserter.postCommand(keyCode: $0) },
            frontmostApp: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            postReturn: { TextInserter.postReturn() })
    }

    /// Tests: a private pasteboard and fake system hooks.
    init(pasteboard: NSPasteboard, system: System) {
        self.pasteboard = pasteboard
        self.system = system
    }

    /// Pastes at the cursor of whatever has focus now. Whether a text field has it can't be told everywhere (Chrome
    /// and Electron apps don't say), so the paste never depends on it; only a password field, which macOS always
    /// names, is refused.
    func insert(_ text: String) async -> InsertionOutcome {
        await serialized { await self.performInsert(text) }
    }

    /// "Paste here": paste into whatever has focus now, without focus or target checks.
    func pasteNow(_ text: String) async -> InsertionOutcome {
        await serialized { await self.performPasteNow(text) }
    }

    private func performInsert(_ text: String) async -> InsertionOutcome {
        // Whatever this comes to, Send's Return follows it, never an earlier paste.
        lastPasteTarget = nil
        guard !text.isEmpty else { return .failed("There was no text to paste.") }
        guard await mayPostEvents() else { return .accessibilityMissing }

        await waitForModifierRelease()
        let focus = await system.inspectFocus()
        Log.app.notice("Paste target: \(focus.bundleID ?? "?", privacy: .public) role=\(focus.role ?? "-", privacy: .public) subrole=\(focus.subrole ?? "-", privacy: .public) editable=\(String(describing: focus.editability), privacy: .public)")
        if focus.isSecure {
            // Leave the clipboard alone, which also keeps the text out of clipboard history: the transcript card
            // offers Copy.
            return .passwordField
        }

        var final = text
        if let previous = focus.precedingCharacter, Self.needsLeadingSpace(after: previous, before: text) {
            final = " " + text
        }
        return await paste(final)
    }

    /// Send: Return in the app the last paste went to, after any paste still queued, once the keys held for the
    /// dictation are up (Return with ⌃ held is another key in most apps). Never into another app: one that came to the
    /// front since the paste gets nothing.
    func pressReturn() async -> ReturnOutcome {
        await serialized { await self.performPressReturn() }
    }

    private func performPressReturn() async -> ReturnOutcome {
        guard let target = lastPasteTarget, await mayPostEvents() else { return .failed }
        await waitForModifierRelease()
        guard system.frontmostApp() == target else { return .appChanged }
        let post = system.postReturn
        let posted = await Task.detached(priority: .userInitiated) { post() }.value
        return posted ? .pressed : .failed
    }

    private func performPasteNow(_ text: String) async -> InsertionOutcome {
        lastPasteTarget = nil
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

    /// The text selected in the frontmost app, for one that doesn't tell Accessibility what's selected (Chrome,
    /// Electron apps): copied with ⌘C, then the clipboard goes back to what it held, marked so clipboard managers
    /// don't count that as a new copy. The selection itself may still show up in their history: that copy is the
    /// app's own. Not tried when the clipboard couldn't be put back after.
    func copySelection() async -> SelectionCopy {
        await serialized { await self.performCopySelection() }
    }

    private func performCopySelection() async -> SelectionCopy {
        guard await mayPostEvents() else { return .unavailable }
        // A paste's restore still waiting: the clipboard holds that transcript, and what goes back is the user's own.
        let tookOverRestore = pendingRestore.map { pasteboard.changeCount == $0.ourChangeCount } ?? false
        guard let original = takeOriginalClipboard() else { return .unavailable }
        let before = pasteboard.changeCount
        let keyCode = system.copyKeyCode()
        let post = system.postCopy
        let posted = await Task.detached(priority: .userInitiated) { post(keyCode) }.value
        // The app clears the clipboard, then writes to it: what it copied is there once it has types again.
        let deadline = ContinuousClock.now + copyTimeout
        var copied = false
        while posted, ContinuousClock.now < deadline {
            if pasteboard.changeCount != before, pasteboard.types?.isEmpty == false {
                copied = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard copied else {
            if pasteboard.changeCount != before {
                original.restore(to: pasteboard, transient: true)
            } else if tookOverRestore {
                original.restore(to: pasteboard)
            }
            return posted ? .nothing : .unavailable
        }
        let text = pasteboard.string(forType: .string)
        let wholeLine = Self.isEmptySelectionCopy(pasteboard)
        original.restore(to: pasteboard, transient: true)
        guard !wholeLine, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothing }
        return .text(text)
    }

    /// VS Code (and Cursor, Windsurf, the other editors built on it) copies the cursor's whole line for ⌘C with
    /// nothing selected, and says so in its "vscode-editor-data", which Chromium keeps inside its own web data type
    /// as UTF-16: looked for in every small type of the copy, whatever it's called.
    nonisolated static func isEmptySelectionCopy(_ pasteboard: NSPasteboard) -> Bool {
        guard let item = pasteboard.pasteboardItems?.first else { return false }
        let marker = #""isFromEmptySelection":true"#
        let patterns = [Data(marker.utf8), marker.data(using: .utf16LittleEndian) ?? Data()]
        return item.types.contains { type in
            guard let data = item.data(forType: type), data.count < 1_000_000 else { return false }
            return patterns.contains { data.range(of: $0) != nil }
        }
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
    private func serialized<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
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
        let target = system.frontmostApp()
        let conditions = PasteConditions(toUs: target == ProcessInfo.processInfo.processIdentifier,
                                         secureInput: IsSecureEventInputEnabled(),
                                         layout: PasteKeyResolver.currentLayoutName(),
                                         systemLayout: PasteKeyResolver.savedLayoutName())
        let posted = await Task.detached(priority: .userInitiated) { post(keyCode) }.value
        guard posted else {
            if pasteboard.changeCount == ourChangeCount { original?.restore(to: pasteboard) }
            return .failed("\(Brand.name) couldn’t send the paste keystroke.")
        }
        scheduleRestore(original, source: source, pastedAt: .now, ourChangeCount: ourChangeCount,
                        conditions: conditions)
        lastPasteTarget = target
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
                                 pastedAt: ContinuousClock.Instant, ourChangeCount: Int, conditions: PasteConditions) {
        let earliest = pastedAt + restoreDelay, readGrace = readGrace, latest = pastedAt + unreadTimeout, log = log
        let task = Task { @MainActor [weak self] in
            let waited = await Self.waitForTheTarget(source, earliest: earliest, readGrace: readGrace, latest: latest)
            Self.logDelivery(source, to: log, pastedAt: pastedAt, conditions: conditions, superseded: !waited)
            guard waited, !Task.isCancelled, let self else { return }
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

    /// What was true as ⌘V went out: it went to transcribe-thing itself (one of its windows was in front), Secure
    /// Keyboard Entry was on somewhere, and the keyboard layout ("RussianWin"), as this app sees it and as macOS last
    /// saved it (they differ when this app wasn't told of a switch). Never which app it went to.
    struct PasteConditions: Sendable {
        var toUs: Bool
        var secureInput: Bool
        var layout: String?
        var systemLayout: String?
    }

    /// Whether the paste was taken: an app reads the text when ⌘V reaches it, so `read=no` once the wait is over means
    /// the keystroke went where nothing pastes. `unknown`: the text was written outright (the clipboard was empty), so
    /// its reads can't be seen. `superseded`: a newer paste came first, and `read` says only what happened until then.
    private static func logDelivery(_ source: PastedTextSource?, to log: DiagnosticLog,
                                    pastedAt: ContinuousClock.Instant, conditions: PasteConditions, superseded: Bool) {
        let readAt = source?.firstRead
        let read = source == nil ? "unknown" : readAt == nil ? "no" : "yes"
        let ms = readAt.map { Int((($0 - pastedAt) / .milliseconds(1)).rounded()) }
        log.event(.dictation, "paste.read", [
            "read": read, "ms": ms, "superseded": superseded ? true : nil,
            "toUs": conditions.toUs ? true : nil, "secureInput": conditions.secureInput ? true : nil,
            "layout": conditions.layout,
            "systemLayout": conditions.systemLayout == conditions.layout ? nil : conditions.systemLayout,
        ])
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

    /// Return down and up, with no modifiers, from the combined session state and tagged as ours (our tap lets it
    /// through: it's never Send's own ↩), posted at the session tap as ⌘V is.
    nonisolated static func postReturn() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        source.userData = SyntheticEvent.tag
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: false)
        else { return false }
        down.flags = []
        up.flags = []
        down.post(tap: .cgSessionEventTap)
        usleep(5_000)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    /// ⌘ down, V (or C) down and up, ⌘ up from the combined session state, posted at the session tap (posting at
    /// the HID tap would also mutate the HID state table, and a lost keyUp could leave ⌘ stuck).
    nonisolated static func postCommand(keyCode: CGKeyCode) -> Bool {
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
