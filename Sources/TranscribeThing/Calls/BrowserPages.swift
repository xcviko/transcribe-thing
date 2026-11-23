import Foundation

/// What the browser extension says about one browser's tabs (`BrowserBridge.pages(of:)`), from every profile of it
/// that has the extension, and what `CallDetector` makes of it: a `Window` like a read of the tab strip and the
/// Mute button gives, only surer. The extension sees the call from inside the page (its peer connections and the mic
/// track they send), so it knows which tab holds the call whichever tab is in front and however it's retitled, says
/// the mute where no Mute button can be read (a background tab, a page whose labels nobody knows), and knows the call
/// is over the moment its connections close.
///
/// A call no profile with the extension covers (one without it, or a page whose WebRTC it couldn't see) is left to
/// the Accessibility reads (`read` is nil), as before the extension.
struct BrowserPages: Equatable, Sendable {
    struct Page: Equatable, Sendable {
        /// The tab's id among every tab the app knows (`BrowserBridge.tabID`): per profile, never one the tab strip
        /// gives.
        var id: BrowserTabs.TabID
        var tab: BrowserProtocol.Tab

        var service: CallService? { CallService.of(host: tab.host) }

        /// What tells its call from another (`CallDetector.Tab.key`): the service, for Meet with the meeting's code
        /// from its address; another site by its host, since its title can change all call long.
        var key: String {
            guard let service else { return "site: " + tab.host.lowercased() }
            if service.pageNamesTheCall, let room = tab.room { return BrowserTabs.key(service: service, page: room) }
            return BrowserTabs.key(service: service, page: tab.title)
        }
    }

    /// The tabs with a call or the mic.
    var pages: [Page]
    /// Tabs whose call or mic ended, or that closed, while their profile is still connected.
    var ended: Set<BrowserTabs.TabID> = []
    /// Tabs playing sound.
    var audible: Set<BrowserTabs.TabID> = []

    /// One read from the extension: the window for the detector, and the report the monitor reads as it reads
    /// `CallMuteReader`'s.
    struct Read: Equatable, Sendable {
        var window: CallDetector.Window
        var report: CallMuteReader.Report
    }

    /// The call's tab, for a call that `following` (its tab as last read, `toldByPage` when that read came from the
    /// extension). The tab the extension told about stays the call's for as long as it has a call or the mic, and
    /// once it has neither (or closed) the call is over: another tab's call is its own, once this one has ended.
    /// Otherwise the tab in a call, with the mic first, then a known service.
    ///
    /// When no tab is in a call, nothing is known here (nil): the call is left to the Accessibility reads, as in a
    /// profile without the extension. A tab with only the mic may be a call whose connections the extension couldn't
    /// see (a page that made them where its hooks don't reach), which the tab strip still shows.
    func read(following: CallDetector.Tab?, toldByPage: Bool) -> Read? {
        let followedID = toldByPage ? following?.id : nil
        let candidates = pages.filter { $0.tab.inCall || $0.tab.micLive }
        func rank(_ page: Page) -> [Int] {
            [page.tab.micLive ? 0 : 1, page.service == nil ? 1 : 0, page.id.raw]
        }
        let followed = followedID.flatMap { id in candidates.first { $0.id == id } }
        let over = followedID.map { ended.contains($0) } ?? false
        let inCall = candidates.filter(\.tab.inCall)
        guard let page = followed ?? (over ? nil : inCall.min { rank($0).lexicographicallyPrecedes(rank($1)) })
        else {
            guard over else { return nil }
            // Its connections closed, or the tab did: the call is over now, whatever the mic does.
            let window = CallDetector.Window(tab: nil, muted: nil, inCall: false, fromPage: true)
            let report = CallMuteReader.Report(
                read: MuteRead(state: .unknown("the call's page left the call"), inCall: false, detail: "browser extension"),
                isBrowser: true, windowCount: 1, otherTabPlaysAudio: !audible.isEmpty, fromPage: true)
            return Read(window: window, report: report)
        }
        let others = candidates.filter { $0.id != page.id && $0.tab.micLive }.map(\.id)
        // A tab in a call counts as recording the mic, muted or not (Telegram lets go of it to mute).
        var tab = CallDetector.Tab(service: page.service, page: page.tab.title, recording: .mic, id: page.id,
                                   otherMicTabs: others)
        tab.key = page.key
        let muted = page.tab.inCall ? page.tab.muted : nil
        let window = CallDetector.Window(tab: tab, muted: muted, inCall: page.tab.inCall, fromPage: true)
        let state: MuteState = switch muted {
        case true?: .muted
        case false?: .live
        case nil: .unknown(page.tab.inCall ? "the page doesn't say" : "not in a call yet")
        }
        let callTab = BrowserTabs.CallTab(window: 0, tab: 0, windowTitle: nil, page: page.tab.title, recording: .mic,
                                          service: page.service, active: true, othersRecordMic: !others.isEmpty,
                                          id: page.id, otherMicTabs: others)
        let report = CallMuteReader.Report(
            read: MuteRead(state: state, inCall: page.tab.inCall, detail: "browser extension"), isBrowser: true,
            tab: callTab, windowCount: 1, otherTabPlaysAudio: !audible.subtracting([page.id]).isEmpty, fromPage: true)
        return Read(window: window, report: report)
    }
}
