import Foundation

/// Which browser tab holds a call. Chromium browsers add what a tab records to its accessible title
/// ("Meet - abc-defg-hij - Camera and microphone recording"), so the tab strip says which one has the mic, and the
/// page title says which service it is. Pure: `CallMuteReader` reads the titles.
enum BrowserTabs {
    /// What a tab says it records or shares.
    enum Recording: Equatable, Sendable {
        case cameraAndMic, mic, camera, tab, desktop

        var hasMic: Bool { self == .cameraAndMic || self == .mic }

        var name: String {
            switch self {
            case .cameraAndMic: "camera and microphone"
            case .mic: "microphone"
            case .camera: "camera"
            case .tab: "sharing the tab"
            case .desktop: "sharing the screen"
            }
        }
    }

    /// A tab's title split into the page's own title and what the browser added.
    struct Title: Equatable, Sendable {
        var page: String
        var recording: Recording?
    }

    /// Chrome's English and Russian wording, with a hyphen or an en dash.
    private static let suffixes: [(text: String, recording: Recording)] = {
        let english: [(String, Recording)] = [
            ("Camera and microphone recording", .cameraAndMic), ("Camera or microphone recording", .cameraAndMic),
            ("Microphone recording", .mic), ("Camera recording", .camera),
            ("Tab content shared", .tab), ("Desktop content shared", .desktop),
        ]
        let russian: [(String, Recording)] = [
            (", включена запись с камеры и микрофона", .cameraAndMic), (", включена запись с микрофона", .mic),
            (", включена запись с камеры", .camera), (": доступ к содержимому вкладки открыт", .tab),
            (": доступ к содержимому рабочего стола открыт", .desktop),
        ]
        return english.flatMap { text, recording in [(" - " + text, recording), (" – " + text, recording)] } + russian
    }()

    /// The other alerts Chrome adds after a page's title, each ending it: "Meet – abc - Audio playing - Memory usage
    /// - 446 MB" is the page "Meet – abc". Only one alert shows at a time besides the hover card's memory usage, and
    /// "Permission requested, press ⌘ + Option + Up arrow to respond" takes the place of a recording mark. The
    /// Russian wording is a guess.
    private static let alerts: [String] = {
        let english = ["Audio playing", "Audio muted", "Memory usage", "Permission requested",
                       "Picture-in-picture playing", "Bluetooth device connected", "USB device connected",
                       "Serial port connected", "HID device connected"]
        let russian = ["воспроизводится аудио", "звук отключен", "использование памяти", "запрошено разрешение"]
        return english.flatMap { [" - " + $0, " – " + $0] }
            + russian.flatMap { [" - " + $0, " – " + $0, ", " + $0, ": " + $0] }
    }()

    /// Whether the browser marks the tab as playing sound ("YouTube - Audio playing"). Chrome's wording; Safari and
    /// Firefox put no such mark in the title, so for them it's never known.
    static func isPlayingAudio(_ title: String) -> Bool {
        ["Audio playing", "воспроизводится аудио"].contains { title.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// Whether a tab other than `callTab` plays sound: then the call's recording, which takes the whole browser's
    /// sound, has that tab's too.
    static func otherTabPlaysAudio(in windows: [Window], besides callTab: CallTab?) -> Bool {
        for (windowIndex, window) in windows.enumerated() {
            for (tabIndex, tab) in window.tabs.enumerated()
            where !(callTab?.window == windowIndex && callTab?.tab == tabIndex) && isPlayingAudio(tab.title) {
                return true
            }
        }
        return false
    }

    /// `title` without what the browser added, and what it records, if it says. The page's title ends at the first
    /// mark or alert, whatever follows it; a recording mark counts wherever it is. An unread mark in front ("(3) ",
    /// "• ") goes too.
    static func parse(_ title: String) -> Title {
        let trimmed = withoutUnreadMark(title)
        let marks = suffixes.compactMap { suffix -> (range: Range<String.Index>, recording: Recording)? in
            trimmed.range(of: suffix.text, options: .caseInsensitive).map { ($0, suffix.recording) }
        }
        // The earliest mark wins; at the same place, the longer one ("Camera and microphone" over "Camera").
        let mark = marks.min { lhs, rhs in
            lhs.range.lowerBound != rhs.range.lowerBound ? lhs.range.lowerBound < rhs.range.lowerBound
                : lhs.range.upperBound > rhs.range.upperBound
        }
        let ends = alerts.compactMap { trimmed.range(of: $0, options: .caseInsensitive)?.lowerBound }
            + (mark.map { [$0.range.lowerBound] } ?? [])
        let page = ends.min().map { String(trimmed[..<$0]) } ?? trimmed
        return Title(page: page.trimmingCharacters(in: .whitespaces), recording: mark?.recording)
    }

    /// `title` without the unread mark a page puts in front of it: "(3) Inbox", "(99+) Inbox", "• Discord | Friends".
    static func withoutUnreadMark(_ title: String) -> String {
        var text = Substring(title.trimmingCharacters(in: .whitespacesAndNewlines))
        while true {
            if let first = text.first, "•●".contains(first) {
                text = text.dropFirst().drop(while: \.isWhitespace)
            } else if text.hasPrefix("("), let close = text.firstIndex(of: ")"),
                      case let count = text[text.index(after: text.startIndex)..<close],
                      !count.isEmpty, count.allSatisfy({ $0.isNumber || $0 == "+" }) {
                text = text[text.index(after: close)...].drop(while: \.isWhitespace)
            } else {
                return String(text)
            }
        }
    }

    /// What tells one call from another in the same browser: the service, with the meeting for Meet, whose title
    /// names it (`CallService.pageNamesTheCall`: its code when the title has one, else the whole title); a page no
    /// service is known for, by its title.
    static func key(service: CallService?, page: String) -> String {
        let page = page.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard let service else { return "page: " + page }
        guard service.pageNamesTheCall else { return service.rawValue }
        return "\(service.rawValue): \(meetingCode(in: page) ?? page)"
    }

    /// A Meet meeting's code in a title, "abc-defg-hij", lowercased: whatever else the title says around it (an
    /// extension's emoji, a profile's tag) doesn't make it another meeting.
    static func meetingCode(in page: String) -> String? {
        let words = page.lowercased().split { !($0.isASCII && $0.isLetter) && $0 != "-" }
        return words.first { word in
            word.split(separator: "-", omittingEmptySubsequences: false).map(\.count) == [3, 4, 3]
        }.map(String.init)
    }

    /// The parts of a page's title between " - ", " | ", " · " and dashes, each without what decorates it: an
    /// unread mark, a bracketed tag ("[Main]", "(Channel)"), emoji and symbols at either end. Lowercased, spaces
    /// collapsed. "general (Channel) - V-Soft - Slack [Main] 🏠" is "general", "v-soft", "slack".
    static func components(of title: String) -> [String] {
        var text = title.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        for separator in [" - ", " | ", " · ", " – ", " — "] {
            text = text.replacingOccurrences(of: separator, with: "\u{1F}")
        }
        return text.split(separator: "\u{1F}").map { bare(String($0)) }.filter { !$0.isEmpty }
    }

    /// One part of a title without its decorations (`components`).
    private static func bare(_ part: String) -> String {
        var text = Substring(withoutUnreadMark(part))
        func isWordy(_ character: Character) -> Bool { character.isLetter || character.isNumber }
        while true {
            let before = text
            text = text.drop { !isWordy($0) && $0 != "[" && $0 != "(" }
            while let last = text.last, !isWordy(last), last != "]", last != ")" { text = text.dropLast() }
            if text.last == "]", let open = text.lastIndex(of: "[") {
                text = text[..<open]
            } else if text.last == ")", let open = text.lastIndex(of: "("), open > text.startIndex {
                text = text[..<open]
            } else if text.first == "[", let close = text.firstIndex(of: "]") {
                text = text[text.index(after: close)...]
            }
            text = Substring(text.trimmingCharacters(in: .whitespaces))
            if text == before { return String(text) }
        }
    }

    /// Which tab of the strip one is, for as long as it's there: the same from read to read however the tab is
    /// retitled and whichever tab is in front; another tab, or one closed and opened again, has another. Opaque:
    /// `TabIDs` gives them out, tests make their own. Two calls in tabs titled alike ("Идёт звонок · Яндекс
    /// Телемост" twice) are told apart by it.
    struct TabID: Hashable, Sendable, CustomStringConvertible {
        var raw: Int

        init(_ raw: Int) { self.raw = raw }

        var description: String { "#\(raw)" }
    }

    /// Whether a browser's tab strip elements keep their identity while the tab lives, so its tabs get a `TabID`.
    /// Chromium's tab strip is made of views that live as long as their tab; Safari's and Firefox's haven't been
    /// looked into, so their tabs are told apart by their titles alone.
    static func tabsHaveIDs(bundleID: String) -> Bool {
        !["com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox"].contains(bundleID)
    }

    /// One tab in the strip: its accessible title, whether it's the window's selected tab when the browser says,
    /// and which tab it is when that's known.
    struct Tab: Equatable, Sendable {
        var title: String
        var selected: Bool?
        var id: TabID? = nil
        /// Not a tab but a window without a tab strip, read by its title (`stripless`).
        var stripless = false

        /// A window without a tab strip, as its only tab: its title, shown, with no id. Chrome's picture-in-picture
        /// window of a call (opened as the person leaves the call's tab) is one, a pop-up is one, and so is a window
        /// whose strip couldn't be read (hidden in full screen). Titled like the call followed, it's that call's
        /// window, never another tab holding a call (`callTab`, `CallDetector`).
        static func stripless(_ title: String) -> Tab {
            Tab(title: title, selected: true, stripless: true)
        }
    }

    struct Window: Equatable, Sendable {
        var title: String?
        var tabs: [Tab]
    }

    /// The tab holding the call, and where it is.
    struct CallTab: Equatable, Sendable {
        /// Index into the windows, and into that window's tabs.
        var window: Int
        var tab: Int
        var windowTitle: String?
        var page: String
        /// Nil when no tab says it records and this one was picked by its title alone (Safari adds no mark, and
        /// Chrome's "Permission requested" replaces it).
        var recording: Recording?
        var service: CallService?
        /// The window's selected tab: its page is the one in the window's web area, so its buttons can be read.
        var active: Bool
        /// Whether another tab records the mic too: then this one stopping while that one goes on is that tab's call,
        /// not this one retitled (`CallDetector`).
        var othersRecordMic = false
        /// Which tab it is, when the browser's tabs have ids.
        var id: TabID? = nil
        /// The other tabs recording the mic that have ids: `CallDetector` notes when it first saw each, which is
        /// where that tab's call begins if it takes over.
        var otherMicTabs: [TabID] = []
        /// A window without a tab strip, not a tab (`Tab.stripless`).
        var stripless = false

        /// Which call it is (`BrowserTabs.key`).
        var key: String { BrowserTabs.key(service: service, page: page) }
    }

    /// The tab a call was in, for the next read to find it again: that very tab when it has an id, else a tab with
    /// the same `key`, but not one of `others`.
    struct Following: Equatable, Sendable {
        var key: String
        var id: TabID? = nil
        /// Tabs that recorded the mic beside the call's: another call's, whatever their titles (`CallDetector`).
        var others: Set<TabID> = []
    }

    /// The tab a call is in: one that records the mic, then one that records anything; among those the call
    /// already `following` (the same tab, then one with its `key` that never recorded beside it), then a tab before
    /// a window without a strip, then a known service, then the selected one. Without any recording mark, a tab
    /// titled like a call service: the one followed, then a tab before a window without a strip, then the selected
    /// one, then any. Preferring the call followed keeps it while you switch to another service's tab, or while
    /// Telegram, muted, records nothing; preferring a tab keeps the call in its tab, not in its picture-in-picture
    /// window, when the tab's id has changed.
    static func callTab(in windows: [Window], following: Following? = nil) -> CallTab? {
        var candidates: [CallTab] = []
        for (windowIndex, window) in windows.enumerated() {
            for (tabIndex, tab) in window.tabs.enumerated() {
                let title = parse(tab.title)
                let active = tab.selected ?? isWindowTitle(window.title, of: title.page, tab: tab.title)
                candidates.append(CallTab(window: windowIndex, tab: tabIndex, windowTitle: window.title, page: title.page,
                                          recording: title.recording, service: CallService.of(pageTitle: title.page),
                                          active: active, id: tab.id, stripless: tab.stripless))
            }
        }
        func followed(_ tab: CallTab) -> Int {
            guard let following else { return 2 }
            if let id = tab.id {
                if id == following.id { return 0 }
                if following.others.contains(id) { return 2 }
            }
            return tab.key == following.key ? 1 : 2
        }
        func first(_ tabs: [CallTab], by rank: (CallTab) -> [Int]) -> CallTab? {
            tabs.enumerated().min { lhs, rhs in
                (rank(lhs.element) + [lhs.offset]).lexicographicallyPrecedes(rank(rhs.element) + [rhs.offset])
            }?.element
        }
        let recording = candidates.filter { $0.recording != nil }
        var chosen = recording.isEmpty
            ? first(candidates.filter { $0.service != nil }) { [followed($0), $0.stripless ? 1 : 0, $0.active ? 0 : 1] }
            : first(recording) {
                [$0.recording?.hasMic == true ? 0 : 1, followed($0), $0.stripless ? 1 : 0, $0.service == nil ? 1 : 0,
                 $0.active ? 0 : 1]
            }
        if let tab = chosen {
            // A window without a strip titled like the call's tab is that call's window, not another call beside it.
            let others = candidates.filter {
                ($0.window != tab.window || $0.tab != tab.tab) && $0.recording?.hasMic == true
                    && !($0.stripless && $0.key == tab.key)
            }
            chosen?.othersRecordMic = !others.isEmpty
            chosen?.otherMicTabs = others.compactMap(\.id)
        }
        return chosen
    }

    /// Whether a window titled `windowTitle` shows the tab: browsers title the window with its selected page,
    /// some adding their own name after it.
    static func isWindowTitle(_ windowTitle: String?, of page: String, tab: String) -> Bool {
        guard let windowTitle, !page.isEmpty else { return false }
        let window = withoutUnreadMark(windowTitle)
        return window == tab || window == withoutUnreadMark(tab) || window == page || window.hasPrefix(page + " - ")
            || window.hasPrefix(page + " – ")
    }
}

/// Gives each tab a `BrowserTabs.TabID` from its Accessibility element (`CallMuteReader`); generic, so tests can use
/// anything. An element is a tab seen before when `same` says so (CFEqual, for AXUIElements) and it's in the same
/// window.
///
/// Elements can be wrong about tabs in two ways. A tab whose element changes (dragged to another window, its strip
/// rebuilt) gets a new id, which `CallDetector` takes for the call moving to another tab: the old element and the new
/// never recorded side by side. A closed tab's element comparing equal to a new tab's (its address used again) would
/// make two calls one: so a tab missing from a read that saw its window's whole strip, or whose window is gone from a
/// read that saw them all, is forgotten for good, and ids are never given twice.
struct TabIDs<Element> {
    private struct Entry {
        var window: Element
        var tab: Element
        var id: BrowserTabs.TabID
    }

    private let same: (Element, Element) -> Bool
    private var entries: [Entry] = []
    private var next = 1

    init(same: @escaping (Element, Element) -> Bool) {
        self.same = same
    }

    /// The tabs known now.
    var count: Int { entries.count }

    /// The id `tab` of `window` had, or a new one.
    mutating func id(of tab: Element, in window: Element) -> BrowserTabs.TabID {
        if let entry = entries.first(where: { same($0.tab, tab) && same($0.window, window) }) { return entry.id }
        let id = BrowserTabs.TabID(next)
        next += 1
        entries.append(Entry(window: window, tab: tab, id: id))
        return id
    }

    /// A read saw `window`'s whole strip: its tabs besides `seen` are gone.
    mutating func sawWhole(_ window: Element, tabs seen: Set<BrowserTabs.TabID>) {
        entries.removeAll { same($0.window, window) && !seen.contains($0.id) }
    }

    /// A read saw every window of the app: the tabs of any other are gone with it.
    mutating func sawAll(windows: [Element]) {
        entries.removeAll { entry in !windows.contains { same($0, entry.window) } }
    }

    /// Forgets every tab; the ids given so far are still never given again.
    mutating func forget() {
        entries = []
    }
}
