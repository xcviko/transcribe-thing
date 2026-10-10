import Foundation

// What a call app's own controls say about the person's mic: the Mute button Meet, Discord, Slack and Zoom show.
// Pure: `CallMuteReader` collects the controls through Accessibility, these tables say what they mean. Labels are
// matched whole after `CallLabels.normalize`, so "Turn off microphone (⌘ + d)" is "turn off microphone".

/// Whether the person's mic is muted in the call, as the app shows it.
enum MuteState: Equatable, Sendable, CustomStringConvertible {
    case muted
    case live
    /// Not readable, and why: no permission, a background tab, labels nobody has seen yet.
    case unknown(String)

    var isKnown: Bool {
        if case .unknown = self { false } else { true }
    }

    var description: String {
        switch self {
        case .muted: "muted"
        case .live: "live"
        case .unknown(let reason): "unknown - \(reason)"
        }
    }
}

/// One read of a call app's controls.
struct MuteRead: Equatable, Sendable {
    var state: MuteState
    /// Whether the app shows a way to leave a call (Leave call, Disconnect, Leave huddle); nil when its labels have
    /// no such sign or nothing was read.
    var inCall: Bool?
    /// What was matched, for a person reading the probe: `AXCheckBox "Mute" value=1`, `Meeting ▸ Unmute audio`.
    /// Never a link.
    var detail: String
}

/// A button, checkbox, switch or menu item as Accessibility shows it. Text fields are never collected.
struct CallControl: Equatable, Sendable {
    var role: String
    var subrole: String?
    var title: String?
    /// AXDescription: where Chromium and Electron put an aria-label.
    var label: String?
    /// AXValue of a checkbox, switch or radio button: 1 when on.
    var value: Int?
    var identifier: String?
    var enabled: Bool?
    /// The menu bar menu a menu item is in ("Meeting").
    var menu: String?

    init(role: String, subrole: String? = nil, title: String? = nil, label: String? = nil, value: Int? = nil,
         identifier: String? = nil, enabled: Bool? = nil, menu: String? = nil) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.label = label
        self.value = value
        self.identifier = identifier
        self.enabled = enabled
        self.menu = menu
    }

    /// Something whose AXValue says on or off: a checkbox, a switch, a toggle button.
    var isToggle: Bool {
        role == "AXCheckBox" || subrole == "AXSwitch" || subrole == "AXToggle"
    }

    /// The title and the description, whichever are set: both are tried against the tables.
    var texts: [String] {
        [title, label].compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The control as `detail` shows a match on `text`: `AXCheckBox "Mute" value=1 id=…`, `Meeting ▸ Unmute audio`.
    func summary(matching text: String) -> String {
        let id = identifier.map { $0.isEmpty ? "" : " id=\(CallLabels.safe($0, limit: 60))" } ?? ""
        if let menu { return "\(menu) ▸ \(CallLabels.safe(text))\(id)" }
        return "\(role) \"\(CallLabels.safe(text))\"" + (value.map { " value=\($0)" } ?? "") + id
    }

    /// One line of a dump: role, title, description, value, identifier; empty ones left out.
    var dumpLine: String {
        var parts: [String] = []
        if let menu { parts.append("\(CallLabels.safe(menu)) ▸") }
        parts.append(role + (subrole.map { "/\($0)" } ?? ""))
        if let title, !title.isEmpty { parts.append("t=\"\(CallLabels.safe(title))\"") }
        if let label, !label.isEmpty { parts.append("d=\"\(CallLabels.safe(label))\"") }
        if let value { parts.append("v=\(value)") }
        if let identifier, !identifier.isEmpty { parts.append("id=\(CallLabels.safe(identifier, limit: 60))") }
        if enabled == false { parts.append("disabled") }
        return parts.joined(separator: " ")
    }

    /// Up to `limit` distinct lines for the controls that have a title, a description or an identifier: what to learn
    /// a new app's labels from.
    static func dump(_ controls: [CallControl], limit: Int = 60) -> [String] {
        var seen: Set<String> = []
        var lines: [String] = []
        for control in controls where !control.texts.isEmpty || control.identifier?.isEmpty == false {
            let line = control.dumpLine
            guard seen.insert(line).inserted else { continue }
            lines.append(line)
            if lines.count == limit { break }
        }
        return lines
    }
}

// MARK: - Labels

enum CallLabels {
    /// A label as the tables hold it: lowercased, spaces collapsed, "ё" as "е", a trailing shortcut hint "(⌘ + d)"
    /// and trailing dots dropped, and a label said twice ("Mute microphone Mute microphone", as some web
    /// apps' aria-label plus visible text come out) said once.
    static func normalize(_ label: String) -> String {
        var text = label.lowercased().replacingOccurrences(of: "ё", with: "е")
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        text = undoubled(text)
        while text.hasSuffix(")"), let open = text.lastIndex(of: "("), open > text.startIndex {
            text = text[..<open].trimmingCharacters(in: .whitespaces)
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .…:,"))
        return undoubled(text)
    }

    private static func undoubled(_ text: String) -> String {
        let words = text.split(separator: " ")
        guard words.count >= 2, words.count.isMultiple(of: 2) else { return text }
        let half = words.count / 2
        guard Array(words[..<half]) == Array(words[half...]) else { return text }
        return words[..<half].joined(separator: " ")
    }

    /// `text` fit for the probe's output: anything that looks like a link (a meeting link carries its passcode)
    /// becomes "<link>", line breaks become spaces, and it's cut at `limit` characters.
    static func safe(_ text: String, limit: Int = 80) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map { word -> String in
            let lower = word.lowercased()
            let isLink = lower.contains("://") || lower.hasPrefix("www.") || lower.contains("pwd=")
                || lower.contains("zoom.us/") || lower.contains("meet.google.com/") || lower.contains("telemost.yandex")
            return isLink ? "<link>" : String(word)
        }
        let joined = words.joined(separator: " ")
        return joined.count > limit ? String(joined.prefix(limit - 1)) + "…" : joined
    }
}

/// Which labels mean what in one call app. Each label is compared whole, after `CallLabels.normalize`.
struct MuteRules: Equatable, Sendable {
    /// A button that would unmute: the mic is muted.
    var muted: Set<String>
    /// A button that would mute: the mic is live.
    var live: Set<String>
    /// A switch or checkbox whose AXValue 1 means muted (Discord's "Mute").
    var mutedWhenOn: Set<String>
    /// A switch or checkbox whose AXValue 1 means live (Slack's "Microphone").
    var liveWhenOn: Set<String>
    /// Shown only during a call: Leave call, Disconnect.
    var inCall: Set<String>
    /// Shown while the person's mic isn't in the call yet, enabled or not: Zoom's "join audio" before joining it.
    var notJoined: Set<String>
    /// Why mute is unknown when none of these labels shows: the app has no mute control at all, or none was found.
    var noControl: String

    init(muted: [String] = [], live: [String] = [], mutedWhenOn: [String] = [], liveWhenOn: [String] = [],
         inCall: [String] = [], notJoined: [String] = [], noControl: String? = nil) {
        func set(_ labels: [String]) -> Set<String> { Set(labels.map(CallLabels.normalize)) }
        self.muted = set(muted)
        self.live = set(live)
        self.mutedWhenOn = set(mutedWhenOn)
        self.liveWhenOn = set(liveWhenOn)
        self.inCall = set(inCall)
        self.notJoined = set(notJoined)
        let isEmpty = muted.isEmpty && live.isEmpty && mutedWhenOn.isEmpty && liveWhenOn.isEmpty
        self.noControl = noControl ?? (isEmpty ? "no labels known for it yet" : "no mute control found")
    }

    var isEmpty: Bool { muted.isEmpty && live.isEmpty && mutedWhenOn.isEmpty && liveWhenOn.isEmpty }

    /// What `text` on `control` says, if the tables know it. A switch's value wins over its label's wording.
    func state(of control: CallControl, text: String) -> MuteState? {
        let label = CallLabels.normalize(text)
        if control.isToggle, let value = control.value {
            if mutedWhenOn.contains(label) { return value != 0 ? .muted : .live }
            if liveWhenOn.contains(label) { return value != 0 ? .live : .muted }
        }
        if muted.contains(label) { return .muted }
        if live.contains(label) { return .live }
        return nil
    }

    /// The first enabled control the tables know decides; a Leave button anywhere says the call is on. Without one,
    /// a "join audio" says the mic isn't in the call yet.
    func read(_ controls: [CallControl]) -> MuteRead {
        var match: (state: MuteState, detail: String)?
        var leaveSeen = false
        var notJoined: String?
        for control in controls {
            for text in control.texts {
                let label = CallLabels.normalize(text)
                if inCall.contains(label) { leaveSeen = true }
                if notJoined == nil, self.notJoined.contains(label) { notJoined = control.summary(matching: text) }
                if match == nil, control.enabled != false, let state = state(of: control, text: text) {
                    match = (state, control.summary(matching: text))
                }
            }
        }
        let inCall = self.inCall.isEmpty ? nil : leaveSeen
        guard let match else {
            if let notJoined { return MuteRead(state: .unknown("audio not joined yet"), inCall: inCall, detail: notJoined) }
            return MuteRead(state: .unknown(noControl), inCall: inCall, detail: "\(controls.count) controls read")
        }
        return MuteRead(state: match.state, inCall: inCall, detail: match.detail)
    }
}

// MARK: - Services

/// A call service, in its desktop app or in a browser tab.
enum CallService: String, CaseIterable, Equatable, Sendable {
    case meet, zoom, discord, telegram, slack, telemost

    var name: String {
        switch self {
        case .meet: "Google Meet"
        case .zoom: "Zoom"
        case .discord: "Discord"
        case .telegram: "Telegram"
        case .slack: "Slack"
        case .telemost: "Telemost"
        }
    }

    /// Whether muting gives the mic back. Telegram's 1:1 calls do, in the app and on the web, so a released mic is
    /// its mute. Meet, Zoom, Discord, Slack and Telemost keep the mic while muted: for them a released mic means
    /// the person left (or is reconnecting), and mute is only read from their Mute button.
    var releasesMicOnMute: Bool { self == .telegram }

    /// Whether the page's title names the call: Meet's is the meeting's code ("Meet – abc-defg-hij"), so another
    /// meeting is another call. Discord, Slack and Telegram retitle the tab as you move around them mid-call, and
    /// Telemost and Zoom as the call starts and ends, so for them the service is all that tells calls apart.
    var pageNamesTheCall: Bool { self == .meet }

    /// The web client's labels, which the Electron apps share. Russian ones marked "guess" haven't been seen yet.
    var rules: MuteRules {
        switch self {
        case .meet:
            MuteRules(muted: ["Turn on microphone", "Включить микрофон"],
                      live: ["Turn off microphone", "Выключить микрофон"],
                      inCall: ["Leave call", "Покинуть видеовстречу"])
        case .zoom:
            // On the web: "join audio" until the person joins the meeting's audio, then "mute my microphone".
            MuteRules(muted: ["unmute my microphone", "Unmute"], live: ["mute my microphone", "Mute"],
                      inCall: ["Leave", "Leave meeting", "End", "Завершить"], notJoined: ["join audio"])
        case .discord:
            // The Russian client's mute switch is "Заглушить" (only its value says which way it is); "Откл. звук"
            // beside it is Deafen, not Mute. "Откл. микрофон", "Вкл. микрофон" and "Отключиться" are guesses.
            MuteRules(muted: ["Unmute", "Вкл. микрофон", "Включить микрофон"],
                      live: ["Mute", "Откл. микрофон", "Отключить микрофон"],
                      mutedWhenOn: ["Mute", "Заглушить", "Откл. микрофон", "Отключить микрофон"],
                      inCall: ["Disconnect", "Отключиться"])
        case .slack:
            MuteRules(muted: ["Unmute microphone", "Unmute mic"], live: ["Mute microphone", "Mute mic"],
                      liveWhenOn: ["Microphone"], inCall: ["Leave huddle"])
        case .telemost:
            MuteRules(muted: ["Включить микрофон", "Turn on microphone"],
                      live: ["Выключить микрофон", "Turn off microphone"],
                      inCall: ["Покинуть", "Покинуть встречу", "Leave", "Завершить звонок"])
        case .telegram:
            // Telegram Web's call bar says "Mute" whether or not the mic is muted: muting releases the mic instead.
            MuteRules(inCall: ["End"], noControl: "its Mute button doesn't change, a released mic is its mute")
        }
    }

    /// The service a web page is, from its title as the tab shows it (an unread mark like "(3) " or "• " ignored):
    /// "Meet – abc-defg-hij", "Zoom Meeting", "#general | Server | Discord", "Discord | Friends", "Telegram Web",
    /// "Идёт звонок · Яндекс Телемост".
    static func of(pageTitle: String) -> CallService? {
        let title = BrowserTabs.withoutUnreadMark(pageTitle).lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        func ends(_ name: String) -> Bool {
            title == name || ["| ", "- ", "– ", "— "].contains { title.hasSuffix(" " + $0 + name) }
        }
        func starts(_ name: String) -> Bool {
            title == name || [" | ", " - ", " – ", " — ", ": "].contains { title.hasPrefix(name + $0) }
        }
        if starts("meet") || title.contains("google meet") { return .meet }
        if title.contains("телемост") || title.contains("telemost") { return .telemost }
        if title.contains("zoom meeting") || title.hasPrefix("zoom ") || starts("zoom") || ends("zoom") { return .zoom }
        if starts("discord") || ends("discord") || title.contains("| discord") { return .discord }
        if title.hasPrefix("telegram") || ends("telegram") { return .telegram }
        if starts("slack") || ends("slack") || title.contains("huddle") { return .slack }
        return nil
    }
}

/// How a call app's mute can be read.
enum CallAppKind: Equatable, Sendable {
    /// Zoom's menu bar has Mute audio or Unmute audio in its Meeting menu.
    case zoomDesktop
    /// An Electron app: its web UI is only in the Accessibility tree once asked for with AXManualAccessibility.
    case electron(CallService)
    /// Telegram shows nothing to Accessibility; it gives the mic back while muted, which `CallDetector` sees.
    case telegramDesktop
    /// The call is in one of its tabs.
    case browser
    /// Nothing known: its controls are only dumped.
    case other

    static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.brave.Browser", "ru.yandex.desktop.yandex-browser", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    static func of(_ bundleID: String) -> CallAppKind {
        if browsers.contains(bundleID) { return .browser }
        switch bundleID {
        case "us.zoom.xos": return .zoomDesktop
        case "com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary": return .electron(.discord)
        case "com.tinyspeck.slackmacgap": return .electron(.slack)
        case "ru.yandex.desktop.telemost": return .electron(.telemost)
        case "ru.keepcoder.Telegram", "com.tdesktop.Telegram": return .telegramDesktop
        default: return .other
        }
    }

    /// The service a desktop app is: nil for a browser, whose tab says, and for an app nobody knows.
    var service: CallService? {
        switch self {
        case .zoomDesktop: .zoom
        case .electron(let service): service
        case .telegramDesktop: .telegram
        case .browser, .other: nil
        }
    }
}

// MARK: - Zoom

/// Zoom's Meeting menu: "Mute audio" while the mic is live, "Unmute audio" while it is muted, both disabled outside a
/// meeting. The Russian menu and item names are guesses.
enum ZoomMenu {
    static let menus: Set<String> = Set(["Meeting", "Конференция", "Встреча"].map(CallLabels.normalize))
    static let rules = MuteRules(muted: ["Unmute audio", "Включить звук"], live: ["Mute audio", "Выключить звук"])

    static func isMeetingMenu(_ title: String) -> Bool {
        menus.contains(CallLabels.normalize(title))
    }

    /// What the menu items say. In a meeting while one of the two is enabled; not, while the menu is there with
    /// neither; unknown without the menu.
    static func read(_ items: [CallControl]) -> MuteRead {
        let meeting = items.filter { $0.menu.map(isMeetingMenu) ?? false }
        guard !meeting.isEmpty else {
            return MuteRead(state: .unknown("no Meeting menu"), inCall: nil, detail: "\(items.count) menu items read")
        }
        var read = rules.read(meeting)
        read.inCall = read.state.isKnown
        if !read.state.isKnown { read.state = .unknown("no enabled Mute audio or Unmute audio") }
        return read
    }
}
