import Foundation

// Which apps and browser tabs are calls (`CallMonitor`). There's no list of call apps: any app whose processes hold
// the mic and play sound together for `CallDetector.Settings.confirmAfter` is a call, and a browser is one only
// while a tab says it records the mic (or is titled like a known call service). Known services (`CallAppKind`,
// `CallService`) only add what they can: mute followed, a nicer title. Two things are never calls: the apps below,
// and what the person excluded (`CallExclusion`, General → Calls).

/// Apps that record and play sound at once for work, and processes that aren't anybody's call: never followed.
enum CallDenylist {
    enum Reason: Equatable, Sendable {
        /// Records and plays at once for work: music, screen recording, audio routing, video editing.
        case work
        /// A system daemon (alert sounds, Core Audio itself); they usually report no bundle id at all.
        case system
        /// This app.
        case ownApp
    }

    struct Entry: Equatable, Sendable {
        var name: String
        var bundleID: String
        /// Also every bundle id that starts with `bundleID` and a dot or more: Ableton names each edition its own.
        var matchesPrefix = false
        var reason: Reason
    }

    /// The whole table, matched case-insensitively against the main app's bundle id (`CallApp.mainBundleID`, so
    /// helpers count as their app).
    static let entries: [Entry] = [
        Entry(name: "GarageBand", bundleID: "com.apple.garageband10", reason: .work),
        Entry(name: "Logic Pro", bundleID: "com.apple.logic10", reason: .work),
        Entry(name: "Ableton Live", bundleID: "com.ableton.live", matchesPrefix: true, reason: .work),
        Entry(name: "OBS", bundleID: "com.obsproject.obs-studio", reason: .work),
        Entry(name: "QuickTime Player", bundleID: "com.apple.QuickTimePlayerX", reason: .work),
        Entry(name: "Voice Memos", bundleID: "com.apple.VoiceMemos", reason: .work),
        Entry(name: "Simulator", bundleID: "com.apple.iphonesimulator", reason: .work),
        Entry(name: "Audio Hijack", bundleID: "com.rogueamoeba.audiohijack", reason: .work),
        Entry(name: "Loopback", bundleID: "com.rogueamoeba.Loopback", reason: .work),
        Entry(name: "Final Cut Pro", bundleID: "com.apple.FinalCut", reason: .work),
        Entry(name: "DaVinci Resolve", bundleID: "com.blackmagic-design.DaVinciResolve", matchesPrefix: true,
              reason: .work),
        Entry(name: "Audacity", bundleID: "org.audacityteam.audacity", reason: .work),
        Entry(name: Brand.name, bundleID: SingleInstance.bundleIdentifier, reason: .ownApp),
        Entry(name: "System sounds", bundleID: "com.apple.systemsoundserverd", reason: .system),
        Entry(name: "Core Audio", bundleID: "com.apple.audio.coreaudiod", reason: .system),
        Entry(name: "Core Audio", bundleID: "com.apple.coreaudiod", reason: .system),
        Entry(name: "System sounds", bundleID: "com.apple.audio.systemsoundserver-osx", reason: .system),
    ]

    /// The entry `bundleID` (a main app's) falls under, if any.
    static func entry(for bundleID: String) -> Entry? {
        let id = bundleID.lowercased()
        return entries.first { entry in
            let listed = entry.bundleID.lowercased()
            return id == listed || (entry.matchesPrefix && id.hasPrefix(listed + "."))
        }
    }

    /// Whether `app`'s mic and sound are never a call.
    static func denies(_ app: CallApp) -> Bool { entry(for: app.id) != nil }

    /// Whether `bundleID` is a system daemon's: not an app's call at all (`CallApp` leaves it out).
    static func isSystemProcess(_ bundleID: String) -> Bool { entry(for: bundleID)?.reason == .system }
}

/// An app or a site the person said is never a call ("Never for …" on the question, General → Calls). Excluded
/// apps are never followed; an excluded site's tab is never recorded, in any browser.
struct CallExclusion: Codable, Equatable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case app, site
    }

    var kind: Kind
    /// An app's bundle id; a site's `CallExclusion.siteKey`.
    var key: String
    /// "FaceTime", "Google Meet", "ChatGPT".
    var name: String

    var id: String { "\(kind.rawValue):\(key)" }

    static func app(bundleID: String, name: String) -> CallExclusion {
        CallExclusion(kind: .app, key: bundleID, name: name)
    }

    /// A browser tab's site: a call service by the service (every Meet meeting, not just this one), any other page by
    /// `siteName(page:)`.
    static func site(service: CallService?, page: String) -> CallExclusion? {
        if let service { return CallExclusion(kind: .site, key: siteKey(service: service, page: page), name: service.name) }
        let name = siteName(page: page)
        guard !name.isEmpty else { return nil }
        return CallExclusion(kind: .site, key: siteKey(service: nil, page: page), name: name)
    }

    /// What a call is excluded by: its app, or for a browser its tab's site (the browser itself when no tab could be
    /// read). nil for a menu bar recording.
    static func of(bundleID: String?, appName: String, service: CallService?, pageTitle: String?,
                   manual: Bool = false) -> CallExclusion? {
        guard !manual, let bundleID else { return nil }
        if CallAppKind.of(bundleID) == .browser, service != nil || pageTitle?.isEmpty == false,
           let site = site(service: service, page: pageTitle ?? "") {
            return site
        }
        return app(bundleID: bundleID, name: appName)
    }

    static func of(_ info: CallMonitor.CallInfo) -> CallExclusion? {
        of(bundleID: info.bundleID, appName: info.appName, service: info.service, pageTitle: info.pageTitle,
           manual: info.manual)
    }

    static func of(_ record: CallRecord) -> CallExclusion? {
        of(bundleID: record.bundleID, appName: record.appName, service: record.service, pageTitle: record.pageTitle,
           manual: record.manual)
    }

    /// "service: meet" for a call service's tabs; "page: chatgpt" for any other site.
    static func siteKey(service: CallService?, page: String) -> String {
        if let service { return "service: \(service.rawValue)" }
        return "page: " + siteName(page: page).lowercased()
    }

    /// The site an unknown page is, from its title alone: the title up to its first separator (" - ", " – ", " — ",
    /// " | ", " · ", ": "), unread marks left out. Browsers don't let us read a tab's address, and sites put their name
    /// first ("ChatGPT", "Voice Recorder Online - Record your voice") about as often as last, so the first part is the
    /// one that stays put on a page that only ever shows one thing: a call or a recorder. A site that titles each page
    /// differently is excluded by that page's first part only.
    static func siteName(page: String) -> String {
        var title = Substring(BrowserTabs.withoutUnreadMark(page))
        for separator in [" - ", " – ", " — ", " | ", " · ", ": "] {
            if let range = title.range(of: separator) { title = title[..<range.lowerBound] }
        }
        return title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Whether this is the exclusion of `app`.
    func excludes(_ app: CallApp) -> Bool { kind == .app && key == app.id }

    /// Whether this is the exclusion of a browser tab with `service` and `page`.
    func excludes(service: CallService?, page: String) -> Bool {
        kind == .site && key == Self.siteKey(service: service, page: page)
    }

    /// The question's third answer: "Never for FaceTime", "Never for Google Meet", "Never for This Site".
    var actionTitle: String {
        switch kind {
        case .app: "Never for \(name)"
        case .site: key.hasPrefix("service: ") ? "Never for \(name)" : "Never for This Site"
        }
    }

    /// General → Calls' line under the name.
    var kindTitle: String {
        switch kind {
        case .app: "App"
        case .site: "Site, in any browser"
        }
    }
}

extension [CallExclusion] {
    func excludes(_ app: CallApp) -> Bool { contains { $0.excludes(app) } }

    func excludes(service: CallService?, page: String) -> Bool {
        contains { $0.excludes(service: service, page: page) }
    }
}
