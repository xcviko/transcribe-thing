import AppKit
import Observation
import SwiftUI

/// Owns the floating panel: visibility rules, placement, click-through, hover and the toast stack's position.
/// `init` has no side effects; `start()` creates the panel and begins observing.
@MainActor
final class PillController {
    private let model: PillModel
    private let toasts: ToastCenter
    private let settings: AppSettings

    private var panel: PillPanel?
    private var host: PillHostingView?
    private let regions = PillHitRegions()
    private var started = false

    private var globalMonitor: Any?
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    private var hideTask: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?

    /// Display the panel sits on; a dictation pins it there until the session ends.
    private var displayID: CGDirectDisplayID?
    private var sessionActive = false
    private var lastReposition = Date.distantPast
    private var announcedNotices: Set<UUID> = []
    private var knownMaxMinutes: Int?
    private var lastVisiblePhase: PillPhase = .rest

    init(model: PillModel, toasts: ToastCenter, settings: AppSettings) {
        self.model = model
        self.toasts = toasts
        self.settings = settings
    }

    /// Creates the panel, observes settings/model/toasts and screen changes.
    func start() {
        guard !started else { return }
        started = true

        let panel = PillPanel(size: PillCanvasMetrics.size)
        let host = PillHostingView(rootView: PillCanvasView(model: model, toasts: toasts, regions: regions))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.frame = CGRect(origin: .zero, size: PillCanvasMetrics.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        self.host = host

        host.onPointerActivity = { [weak self] in self?.updatePointer() }
        host.onRightMouseDown = { [weak self] event in self?.showContextMenu(for: event) ?? false }
        model.onEngineChipClick = { [weak self] in self?.showEngineMenu() }
        regions.onChange = { [weak self] in self?.updatePointer() }
        // Key-down orders the panel front at once: waiting for the observation's next turn would put the mic
        // open (and whatever else that turn holds) before the pill's first frame.
        model.onVisiblePhaseChange = { [weak self] in self?.update() }
        observeEnvironment()
        track()
        update()
    }

    /// One-time post-onboarding bloom: the pill appears with its "Hold fn" tooltip for a few seconds.
    func showHello() {
        settings.hasShownWelcomeHello = true
        guard PillVisibility.isPillAllowed(mode: settings.pillMode) else {
            toasts.post(Notice(dedupeKey: "pill.hello", style: .info, symbol: "waveform",
                               title: "You’re all set",
                               body: "Hold \(settings.shortcuts[.pushToTalk]?.compactDescription ?? "fn") anywhere to dictate.",
                               lifetime: .seconds(6)))
            return
        }
        if !sessionActive { reposition(on: screenUnderMouse()) }
        model.beginHello(duration: 4.5)
    }

    // MARK: Observation

    private func track() {
        withObservationTracking {
            _ = model.visiblePhase
            _ = model.isHelloActive
            _ = toasts.notices
            _ = settings.pillMode
            _ = settings.shortcuts
            _ = settings.maxRecordingMinutes
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.update()
                self.track()
            }
        }
    }

    private func update() {
        guard let panel else { return }

        let hint = settings.shortcuts[.pushToTalk]?.compactDescription ?? "fn"
        if model.shortcutHint != hint { model.shortcutHint = hint }
        // Follow the setting only when it changes, so a limit the dictation controller sets stays put.
        if knownMaxMinutes != settings.maxRecordingMinutes {
            if knownMaxMinutes != nil { model.limitSeconds = settings.effectiveMaxRecordingDuration }
            knownMaxMinutes = settings.maxRecordingMinutes
        }

        let allowed = PillVisibility.isPillAllowed(mode: settings.pillMode)
        let showsPill = PillVisibility.showsPill(phase: model.visiblePhase, mode: settings.pillMode,
                                                 isHelloActive: model.isHelloActive)
        if model.isPillAllowed != allowed { model.isPillAllowed = allowed }

        // The hands-free latch is felt as well as heard (only when a finger rests on a Force Touch trackpad).
        if model.visiblePhase == .locked, lastVisiblePhase != .locked, showsPill {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        lastVisiblePhase = model.visiblePhase

        // A dictation pins the panel to the screen where the text will go.
        if model.visiblePhase.isActive, !sessionActive {
            sessionActive = true
            reposition(on: Self.screenOfFrontmostWindow() ?? screenUnderMouse())
        } else if !model.visiblePhase.isActive, sessionActive {
            sessionActive = false
        }

        if PillVisibility.needsPanel(showsPill: showsPill, toastCount: toasts.notices.count) {
            show(panel)
        } else {
            scheduleHide()
        }
        // Presentation flips after the panel is on screen, so the bloom animation is visible.
        if model.isPresented != showsPill { model.isPresented = showsPill }

        announceNewNotices()
    }

    private func show(_ panel: PillPanel) {
        hideTask?.cancel()
        hideTask = nil
        if !panel.isVisible {
            if !sessionActive { reposition(on: screenUnderMouse()) }
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            setGlobalMonitor(enabled: true)
            updatePointer()
        } else if model.visiblePhase.isActive {
            // Re-assert z-order over other floating windows at every dictation.
            panel.orderFrontRegardless()
        }
    }

    /// How long the panel stays up once nothing needs it: the pill's exit (and a toast's removal) plays out first.
    static let orderOutDelay: TimeInterval = 0.45

    /// Lets the pill's exit finish, then removes the window and all pointer tracking. Anything shown meanwhile
    /// cancels it (`show`), and the pill comes back from wherever its exit had got to.
    private func scheduleHide() {
        guard let panel, panel.isVisible, hideTask == nil else { return }
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.orderOutDelay))
            guard !Task.isCancelled, let self, let panel = self.panel else { return }
            self.hideTask = nil
            panel.orderOut(nil)
            panel.ignoresMouseEvents = true
            self.setGlobalMonitor(enabled: false)
            self.model.resetPointer()
            self.toasts.setPaused(false)
        }
    }

    private func announceNewNotices() {
        let current = Set(toasts.notices.map(\.id))
        for notice in toasts.notices where !announcedNotices.contains(notice.id) {
            let text = [notice.title, notice.body].compactMap { $0 }.joined(separator: ". ")
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        announcedNotices = current
    }

    // MARK: Placement

    /// Bottom-center of `screen`: the pill sits 10 pt above the Dock, or about 14 pt above the bezel when the
    /// Dock hides or lives on a side.
    private func reposition(on screen: NSScreen?) {
        guard let panel, let screen else { return }
        displayID = Self.displayID(of: screen)
        lastReposition = Date()
        let visible = screen.visibleFrame
        let full = screen.frame
        let pillBottom = max(visible.minY + 10, full.minY + 14)
        let origin = CGPoint(x: (visible.midX - PillCanvasMetrics.size.width / 2).rounded(),
                             y: (pillBottom - PillCanvasMetrics.pillBottomInset).rounded())
        panel.setFrame(CGRect(origin: origin, size: PillCanvasMetrics.size), display: false)
    }

    private func repositionIfIdle() {
        guard !sessionActive else { return }
        reposition(on: displayID.flatMap(Self.screen(withDisplayID:)) ?? screenUnderMouse())
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// While idle the pill follows the pointer to other displays, at most once a second, with a short fade.
    private func followPointer(to point: CGPoint) {
        guard let panel, !sessionActive, !model.visiblePhase.isActive, toasts.notices.isEmpty,
              fadeTask == nil, Date().timeIntervalSince(lastReposition) >= 1,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
              Self.displayID(of: screen) != displayID
        else { return }
        lastReposition = Date()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.1))
            guard let self, let panel = self.panel else { return }
            self.fadeTask = nil
            self.reposition(on: screen)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.1
                panel.animator().alphaValue = 1
            }, completionHandler: nil)
        }
    }

    private func observeEnvironment() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.repositionIfIdle() }
        }
        observers.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                     object: nil, queue: .main, using: handler)))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                           object: nil, queue: .main, using: handler)))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                                           object: nil, queue: .main, using: handler)))
    }

    /// Screen showing the frontmost app's frontmost window: where the text will be pasted.
    /// Window bounds from CGWindowList need no Screen Recording permission (only titles do).
    static func screenOfFrontmostWindow() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let primary = NSScreen.screens.first
        else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  bounds.width > 50, bounds.height > 50
            else { continue }
            // Quartz: top-left origin of the primary display → Cocoa: bottom-left origin.
            let rect = CGRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY,
                              width: bounds.width, height: bounds.height)
            return NSScreen.screens.max { a, b in
                let ia = a.frame.intersection(rect), ib = b.frame.intersection(rect)
                return ia.width * ia.height < ib.width * ib.height
            }
        }
        return nil
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private static func screen(withDisplayID id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == id }
    }

    // MARK: Pointer

    /// Mouse monitors need no permission. While the panel ignores the mouse, this global monitor sees the
    /// moves; while it doesn't, the hosting view's tracking area reports them.
    private func setGlobalMonitor(enabled: Bool) {
        if enabled, globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePointer() }
            }
        } else if !enabled, let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }

    private func screenRect(_ canvasRect: CGRect) -> CGRect? {
        guard let panel, let host else { return nil }
        var rect = canvasRect
        if !host.isFlipped { rect.origin.y = host.bounds.height - rect.maxY }
        return panel.convertToScreen(host.convert(rect, to: nil))
    }

    private func updatePointer() {
        guard let panel, panel.isVisible else { return }
        let point = NSEvent.mouseLocation

        let overPill = model.isPresented && (regions.pill.flatMap(screenRect)?.contains(point) ?? false)
        let overChip = model.isPresented && model.visiblePhase == .locked
            && (regions.chip.flatMap(screenRect)?.contains(point) ?? false)
        let overToast = regions.toasts.values.contains { screenRect($0)?.contains(point) ?? false }
        let interactive = overPill || overChip || overToast
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }

        // The chip counts as the pill: hovering hands-free brings it up, and moving onto it keeps it there.
        model.setPointerInside(overPill || overChip)
        let control = overPill ? regions.controls.first { screenRect($0.value)?.contains(point) ?? false }?.key : nil
        model.setHoveredControl(model.visiblePhase == .locked ? control : nil)
        toasts.setPaused(overToast)

        followPointer(to: point)
    }

    /// The hands-free chip's model menu, just above the chip: the main model, clean-up and the extra models, the
    /// current one checked. Picking one switches this dictation's model.
    private func showEngineMenu() {
        guard let host, model.isPresented, model.visiblePhase == .locked, let chip = regions.chip else { return }
        let settings = model.settings
        let current = model.sessionModel ?? .engine(settings.selectedEngine)
        let menu = Self.modelMenu(choices: model.menuChoices, current: current, main: settings.selectedEngine,
                                  cleanup: settings.cleanupModel) { [weak model] choice in model?.onSelectModel?(choice) }
        // Canvas coordinates have a top-left origin; the menu's top-left goes where its bottom clears the chip.
        let top = chip.minY - 6 - menu.size.height
        let point = host.isFlipped ? CGPoint(x: chip.minX, y: top) : CGPoint(x: chip.minX, y: host.bounds.height - top)
        menu.popUp(positioning: nil, at: point, in: host)
        updatePointer()
    }

    /// One item per choice, titled like the chip with its symbol; `current` is checked. The main model and its
    /// clean-up come first, the extra models after a separator: those hear the audio themselves.
    static func modelMenu(choices: [ModelChoice], current: ModelChoice, main: EngineID, cleanup: CleanupModel,
                          select: @escaping @MainActor (ModelChoice) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, choice) in choices.enumerated() {
            if index > 0, choice.switchEngine != nil, choices[index - 1].switchEngine == nil {
                menu.addItem(.separator())
            }
            let item = MenuActionItem(title: choice.title(main: main, cleanup: cleanup)) { select(choice) }
            item.state = choice == current ? .on : .off
            let image = NSImage(systemSymbolName: choice.symbolName, accessibilityDescription: nil)
            image?.isTemplate = true
            item.image = image
            menu.addItem(item)
        }
        return menu
    }

    private func showContextMenu(for event: NSEvent) -> Bool {
        guard let host, model.isPresented,
              let pill = regions.pill.flatMap(screenRect), pill.contains(NSEvent.mouseLocation),
              let menu = model.contextMenuProvider?()
        else { return false }
        NSMenu.popUpContextMenu(menu, with: event, for: host)
        updatePointer()
        return true
    }
}
