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

    /// What tells one call from another in the same browser: the service, with the page for Meet, whose title
    /// names the meeting (`CallService.pageNamesTheCall`); a page no service is known for, by its title.
    static func key(service: CallService?, page: String) -> String {
        let page = page.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard let service else { return "page: " + page }
        return service.pageNamesTheCall ? "\(service.rawValue): \(page)" : service.rawValue
    }

    /// One tab in the strip: its accessible title, and whether it's the window's selected tab when the browser says.
    struct Tab: Equatable, Sendable {
        var title: String
        var selected: Bool?
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

        /// Which call it is (`BrowserTabs.key`).
        var key: String { BrowserTabs.key(service: service, page: page) }
    }

    /// The tab a call is in: one that records the mic, then one that records anything; among those the call
    /// already `following` (by its `key`), then a known service, then the selected one. Without any recording
    /// mark, a tab titled like a call service: the one followed, then the selected one, then any. Preferring the
    /// call followed keeps it while you switch to another service's tab, or while Telegram, muted, records nothing.
    static func callTab(in windows: [Window], following: String? = nil) -> CallTab? {
        var candidates: [CallTab] = []
        for (windowIndex, window) in windows.enumerated() {
            for (tabIndex, tab) in window.tabs.enumerated() {
                let title = parse(tab.title)
                let active = tab.selected ?? isWindowTitle(window.title, of: title.page, tab: tab.title)
                candidates.append(CallTab(window: windowIndex, tab: tabIndex, windowTitle: window.title, page: title.page,
                                          recording: title.recording, service: CallService.of(pageTitle: title.page),
                                          active: active))
            }
        }
        func followed(_ tab: CallTab) -> Int { following != nil && tab.key == following ? 0 : 1 }
        func first(_ tabs: [CallTab], by rank: (CallTab) -> [Int]) -> CallTab? {
            tabs.enumerated().min { lhs, rhs in
                (rank(lhs.element) + [lhs.offset]).lexicographicallyPrecedes(rank(rhs.element) + [rhs.offset])
            }?.element
        }
        let recording = candidates.filter { $0.recording != nil }
        if !recording.isEmpty {
            return first(recording) {
                [$0.recording?.hasMic == true ? 0 : 1, followed($0), $0.service == nil ? 1 : 0, $0.active ? 0 : 1]
            }
        }
        return first(candidates.filter { $0.service != nil }) { [followed($0), $0.active ? 0 : 1] }
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
