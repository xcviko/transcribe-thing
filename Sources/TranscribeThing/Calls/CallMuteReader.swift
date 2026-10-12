import AppKit
import ApplicationServices

/// Reads a call app's mute control, and for a browser the tab holding the call, through Accessibility; what the
/// controls mean is `MuteRules`' and `BrowserTabs`' business. Every call is synchronous IPC to the app, so this runs
/// on one background queue (never the main thread), with `timeout` on each element and `budget` for a whole read.
/// It is only pointed at the app `CallDetector` follows; an Electron app or browser is asked to build its web
/// Accessibility tree (AXManualAccessibility) then, and told it can stop by `release`.
final class CallMuteReader: @unchecked Sendable {
    struct Report: Equatable, Sendable {
        var read: MuteRead
        var isBrowser = false
        /// For a browser: the tab holding the call, nil when none looks like one.
        var tab: BrowserTabs.CallTab?
        var windowCount = 0
        /// For a browser: whether a tab other than the call's says it plays sound.
        var otherTabPlaysAudio = false
        /// While mute is unknown: the controls that were read, to learn the app's labels from.
        var dump: [String]?

        /// What `CallDetector` takes from the read; nil for a browser none of whose windows could be read, which
        /// says nothing about its tabs.
        var window: CallDetector.Window? {
            if isBrowser, windowCount == 0 { return nil }
            let muted: Bool? = switch read.state {
            case .muted: true
            case .live: false
            case .unknown: nil
            }
            return CallDetector.Window(tab: tab.map(CallDetector.Tab.init), muted: muted, inCall: read.inCall)
        }
    }

    private let timeout: Float
    private let budget: TimeInterval
    /// Apps asked for AXManualAccessibility, and whether it was this reader that turned it on.
    private var manual: [pid_t: Bool] = [:]
    /// A site no service is known for: what its Mute button has shown during the call.
    private var generic = GenericMute()

    /// Why a browser call's mute is unknown when its tab isn't the one shown: a background tab's controls can't be read.
    nonisolated static let tabNotActive = "tab not active"

    private static let maxDepth = 40
    private static let maxNodes = 4000
    private static let controlRoles: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXMenuButtonRole, kAXPopUpButtonRole, kAXMenuItemRole, "AXSwitch", "AXToggle",
    ]
    /// Roles whose AXValue is a number worth reading. Nothing else's value is read: a text field's is what the
    /// person typed.
    private static let valueRoles: Set<String> = [kAXCheckBoxRole, kAXRadioButtonRole, "AXSwitch", "AXToggle"]

    init(timeout: Float = 0.25, budget: TimeInterval = 1.5) {
        self.timeout = timeout
        self.budget = budget
    }

    /// One read of `app`, whose processes with windows are `pids`; for a browser, `following` is the key of the tab
    /// the call was in (`BrowserTabs.callTab`). Call on the reader's queue.
    func read(_ app: CallApp, pids: [pid_t], following: String? = nil) -> Report {
        let deadline = Date() + budget
        switch CallAppKind.of(app.id) {
        case .telegramDesktop:
            return Report(read: MuteRead(state: .unknown("Telegram: mute = mic released"), inCall: nil, detail: ""))
        case .zoomDesktop:
            return readZoom(pids, deadline: deadline)
        case .electron(let service):
            return readWindows(pids, rules: service.rules, manual: true, deadline: deadline)
        case .browser:
            return readBrowser(pids, following: following, deadline: deadline)
        case .other:
            return readWindows(pids, rules: nil, manual: false, deadline: deadline)
        }
    }

    /// Turns AXManualAccessibility back off where this reader turned it on: the call is over.
    func release() {
        for (pid, ours) in manual where ours {
            AXUIElementSetAttributeValue(application(pid), "AXManualAccessibility" as CFString, kCFBooleanFalse)
        }
        manual = [:]
        generic = GenericMute()
    }

    // MARK: Apps

    private func readZoom(_ pids: [pid_t], deadline: Date) -> Report {
        var menus: [(title: String, menu: AXUIElement?)] = []
        for pid in pids {
            guard let bar = element(application(pid), kAXMenuBarAttribute) else { continue }
            for item in children(bar) {
                guard let node = node(item, children: true), let title = node.title else { continue }
                menus.append((title, node.children.first))
            }
        }
        // The other menus are only read for the dump, when there's no Meeting menu.
        let meeting = menus.filter { ZoomMenu.isMeetingMenu($0.title) }
        var items: [CallControl] = []
        for (title, menu) in meeting.isEmpty ? Array(menus.dropFirst()) : meeting {
            guard let menu, Date() < deadline else { continue }
            items += children(menu).compactMap { node($0, children: false) }
                .filter { $0.role == kAXMenuItemRole }
                .map { $0.control(menu: title) }
        }
        let read = ZoomMenu.read(items)
        let dump = read.state.isKnown ? nil
            : ["menus: " + menus.map { CallLabels.safe($0.title, limit: 30) }.joined(separator: ", ")]
                + CallControl.dump(items, limit: 59)
        return Report(read: read, dump: dump)
    }

    private func readWindows(_ pids: [pid_t], rules: MuteRules?, manual: Bool, deadline: Date) -> Report {
        var controls: [CallControl] = []
        var windowCount = 0
        for pid in pids {
            let app = application(pid)
            if manual { askForWebTree(app, pid: pid) }
            for window in elements(app, kAXWindowsAttribute) {
                windowCount += 1
                controls += self.controls(in: window, rules: rules, deadline: deadline)
            }
        }
        let read = rules?.read(controls)
            ?? MuteRead(state: .unknown("no labels known for this app"), inCall: nil, detail: "\(controls.count) controls read")
        return Report(read: read, windowCount: windowCount, dump: read.state.isKnown ? nil : CallControl.dump(controls))
    }

    private func readBrowser(_ pids: [pid_t], following: String?, deadline: Date) -> Report {
        var windows: [BrowserTabs.Window] = []
        var windowElements: [AXUIElement] = []
        for pid in pids {
            let app = application(pid)
            askForWebTree(app, pid: pid)
            for window in elements(app, kAXWindowsAttribute) {
                let title = node(window, children: false)?.title
                var tabs = self.tabs(in: window, deadline: deadline)
                if tabs.isEmpty, let title { tabs = [BrowserTabs.Tab(title: title, selected: true)] }
                windows.append(BrowserTabs.Window(title: title, tabs: tabs))
                windowElements.append(window)
            }
        }
        var report = Report(read: MuteRead(state: .unknown("no tab records or is titled like a call"), inCall: nil, detail: ""),
                            isBrowser: true, windowCount: windows.count)
        let callTab = BrowserTabs.callTab(in: windows, following: following)
        report.otherTabPlaysAudio = BrowserTabs.otherTabPlaysAudio(in: windows, besides: callTab)
        guard let tab = callTab else { return report }
        report.tab = tab
        guard let service = tab.service else {
            report.read.state = .unknown("not a call service it knows")
            // A site using the mic that no service is known for: its buttons are tried for a Mute that can be
            // trusted (`GenericMute`), in the tab's own page only, without a walk of the whole window.
            guard tab.recording?.hasMic == true, tab.active else { return report }
            var controls: [CallControl] = []
            for area in webAreas(in: windowElements[tab.window], deadline: deadline) {
                controls += search(area, keys: ["AXButtonSearchKey", "AXCheckBoxSearchKey"], deadline: deadline)
            }
            let read = generic.read(controls)
            if read.state.isKnown { report.read = read }
            return report
        }
        guard tab.active else {
            report.read.state = .unknown(Self.tabNotActive)
            return report
        }
        let controls = self.controls(in: windowElements[tab.window], rules: service.rules, deadline: deadline)
        report.read = service.rules.read(controls)
        if !report.read.state.isKnown { report.dump = CallControl.dump(controls) }
        return report
    }

    // MARK: Trees

    /// The buttons and switches in `window`: from its web areas' search for buttons and checkboxes when that finds
    /// what `rules` know, else from a walk of the whole window (into iframes, which a search may skip).
    private func controls(in window: AXUIElement, rules: MuteRules?, deadline: Date) -> [CallControl] {
        var found: [CallControl] = []
        if let rules, !rules.isEmpty {
            for area in webAreas(in: window, deadline: deadline) {
                found += search(area, keys: ["AXButtonSearchKey", "AXCheckBoxSearchKey"], deadline: deadline)
            }
            if !found.isEmpty, rules.read(found).state.isKnown { return found }
        }
        var walked: [CallControl] = []
        walk(window, maxDepth: Self.maxDepth, maxNodes: Self.maxNodes, deadline: deadline) { node, _ in
            if Self.controlRoles.contains(node.role ?? "") { walked.append(node.control(menu: nil)) }
            return true
        }
        return walked.isEmpty ? found : walked
    }

    private func webAreas(in window: AXUIElement, deadline: Date) -> [AXUIElement] {
        var areas: [AXUIElement] = []
        walk(window, maxDepth: 25, maxNodes: 1500, deadline: deadline) { node, _ in
            guard node.role == "AXWebArea" else { return areas.count < 3 }
            areas.append(node.element)
            return false
        }
        return areas
    }

    /// Chromium's and WebKit's own search: one request for every element of a kind in the whole page, instead of a
    /// walk. A busy page (Slack's, whose huddle bar sits after every channel and message) has hundreds of buttons, so
    /// the limit is high and the results are read until the deadline.
    private func search(_ area: AXUIElement, keys: [String], deadline: Date) -> [CallControl] {
        keys.flatMap { key -> [CallControl] in
            let query: [String: Any] = ["AXSearchKey": key, "AXResultsLimit": 1500, "AXDirection": "AXDirectionNext",
                                        "AXImmediateDescendantsOnly": false, "AXVisibleOnly": false]
            var out: CFTypeRef?
            guard Date() < deadline, AXUIElementCopyParameterizedAttributeValue(
                area, "AXUIElementsForSearchPredicate" as CFString, query as CFDictionary, &out) == .success,
                let results = out as? [AXUIElement] else { return [] }
            var controls: [CallControl] = []
            for result in results {
                guard Date() < deadline else { break }
                if let control = node(result, children: false)?.control(menu: nil) { controls.append(control) }
            }
            return controls
        }
    }

    /// The tabs of a browser window: radio buttons in a tab group (Chrome, Safari), or anything whose title says it
    /// records (other tab strips). Web content is skipped.
    private func tabs(in window: AXUIElement, deadline: Date) -> [BrowserTabs.Tab] {
        var tabs: [BrowserTabs.Tab] = []
        walk(window, maxDepth: 15, maxNodes: 1500, deadline: deadline) { node, parentRole in
            if node.role == "AXWebArea" { return false }
            let texts = [node.title, node.label].compactMap { $0 }
            let recording = texts.first { BrowserTabs.parse($0).recording != nil }
            let isTab = node.role == kAXRadioButtonRole && parentRole == kAXTabGroupRole
            guard recording != nil || isTab, let title = recording ?? texts.first(where: { !$0.isEmpty }) else { return true }
            tabs.append(BrowserTabs.Tab(title: title, selected: node.value.map { $0 != 0 } ?? node.selected))
            return false
        }
        return tabs
    }

    /// Depth-first, in order, while `visit` says to go into a node's children and the limits allow.
    private func walk(_ root: AXUIElement, maxDepth: Int, maxNodes: Int, deadline: Date,
                      visit: (Node, _ parentRole: String?) -> Bool) {
        var stack: [(element: AXUIElement, depth: Int, parentRole: String?)] = [(root, 0, nil)]
        var visited = 0
        while let (element, depth, parentRole) = stack.popLast(), visited < maxNodes, Date() < deadline {
            visited += 1
            guard let node = node(element, children: depth < maxDepth), visit(node, parentRole) else { continue }
            stack += node.children.reversed().map { ($0, depth + 1, node.role) }
        }
    }

    /// Asks a Chromium browser or Electron app for its web content's tree, once per process. One that already has
    /// it on (another assistive app asked) is left alone by `release`.
    private func askForWebTree(_ app: AXUIElement, pid: pid_t) {
        guard manual[pid] == nil else { return }
        var current: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, "AXManualAccessibility" as CFString, &current) == .success,
           (current as? Bool) == true {
            manual[pid] = false
            return
        }
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        manual[pid] = true
    }

    // MARK: Elements

    private struct Node {
        var element: AXUIElement
        var role: String?
        var subrole: String?
        var title: String?
        var label: String?
        var identifier: String?
        var enabled: Bool?
        var selected: Bool?
        var value: Int?
        var children: [AXUIElement]

        func control(menu: String?) -> CallControl {
            CallControl(role: role ?? "?", subrole: subrole, title: title, label: label, value: value,
                        identifier: identifier, enabled: enabled, menu: menu)
        }
    }

    private static let nodeAttributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                                         kAXIdentifierAttribute, kAXEnabledAttribute, kAXSelectedAttribute]

    /// An element's attributes in one request (its children too when asked), and the value of a checkbox-like one.
    private func node(_ element: AXUIElement, children: Bool) -> Node? {
        AXUIElementSetMessagingTimeout(element, timeout)
        let names = Self.nodeAttributes + (children ? [kAXChildrenAttribute] : [])
        var valuesRef: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0),
                                                     &valuesRef) == .success,
              let values = valuesRef as? [AnyObject], values.count == names.count else { return nil }
        // An attribute the element lacks comes back as an AXValue holding the error, which none of these casts take.
        var node = Node(element: element, role: values[0] as? String, subrole: values[1] as? String,
                        title: values[2] as? String, label: values[3] as? String, identifier: values[4] as? String,
                        enabled: values[5] as? Bool, selected: values[6] as? Bool,
                        children: children ? (values[7] as? [AXUIElement] ?? []) : [])
        if let role = node.role, Self.valueRoles.contains(role) || Self.valueRoles.contains(node.subrole ?? "") {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success {
                node.value = (value as? NSNumber)?.intValue
            }
        }
        return node
    }

    private func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return app
    }

    private func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &ref) == .success, let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(ref, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    private func elements(_ parent: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &ref) == .success else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    private func children(_ parent: AXUIElement) -> [AXUIElement] {
        elements(parent, kAXChildrenAttribute)
    }
}
