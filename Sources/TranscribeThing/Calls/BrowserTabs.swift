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

    /// Other states a browser adds after the title, dropped from the page's title.
    private static let decorations = [" - Audio playing", " – Audio playing", " - Audio muted", " – Audio muted",
                                      ", воспроизводится аудио", ", звук отключен"]

    /// `title` without what the browser added, and what it records, if it says. The first recording mark cuts the
    /// title, whatever follows it.
    static func parse(_ title: String) -> Title {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let marks = suffixes.compactMap { suffix -> (range: Range<String.Index>, recording: Recording)? in
            trimmed.range(of: suffix.text, options: .caseInsensitive).map { ($0, suffix.recording) }
        }
        // The earliest mark wins; at the same place, the longer one ("Camera and microphone" over "Camera").
        let mark = marks.min { lhs, rhs in
            lhs.range.lowerBound != rhs.range.lowerBound ? lhs.range.lowerBound < rhs.range.lowerBound
                : lhs.range.upperBound > rhs.range.upperBound
        }
        var page = mark.map { String(trimmed[..<$0.range.lowerBound]) } ?? trimmed
        var stripped = true
        while stripped {
            stripped = false
            for decoration in decorations {
                if let range = page.range(of: decoration, options: [.caseInsensitive, .backwards, .anchored]) {
                    page = String(page[..<range.lowerBound])
                    stripped = true
                }
            }
        }
        return Title(page: page.trimmingCharacters(in: .whitespaces), recording: mark?.recording)
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
        /// Nil when no tab says it records and this one was picked by its title alone (Safari adds no mark).
        var recording: Recording?
        var service: CallService?
        /// The window's selected tab: its page is the one in the window's web area, so its buttons can be read.
        var active: Bool
    }

    /// The tab a call is in: one that records the mic, then one that records anything; among those a known
    /// service, then the selected one. Without any recording mark, a selected tab titled like a call service, then
    /// any such tab.
    static func callTab(in windows: [Window]) -> CallTab? {
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
        func rank(_ tab: CallTab) -> [Int] {
            [tab.recording?.hasMic == true ? 0 : 1, tab.service == nil ? 1 : 0, tab.active ? 0 : 1]
        }
        let recording = candidates.filter { $0.recording != nil }
        if !recording.isEmpty {
            return recording.enumerated().min { lhs, rhs in
                (rank(lhs.element) + [lhs.offset]).lexicographicallyPrecedes(rank(rhs.element) + [rhs.offset])
            }?.element
        }
        let titled = candidates.filter { $0.service != nil }
        return titled.first(where: \.active) ?? titled.first
    }

    /// Whether a window titled `windowTitle` shows the tab: browsers title the window with its selected page,
    /// some adding their own name after it.
    static func isWindowTitle(_ windowTitle: String?, of page: String, tab: String) -> Bool {
        guard let windowTitle, !page.isEmpty else { return false }
        let window = windowTitle.trimmingCharacters(in: .whitespaces)
        return window == tab || window == page || window.hasPrefix(page + " - ") || window.hasPrefix(page + " – ")
    }
}
