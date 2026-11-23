import Foundation

/// Brief, silent notices above the pill about the call being recorded, so the person sees what the app notices:
/// "Call detected · Google Meet" (only when nothing is asked: the question says it otherwise), "You’re muted ·
/// Telegram" with how that was known, "Mute isn’t followed in FaceTime", "Can’t see mute while the Meet tab is in
/// the background", "Call ended · 24:37 · transcribing". One-row toasts that go by themselves in under 2 s, never with
/// a sound (`Notice.callStatus`).
///
/// `CallMonitor` hands it what it sees at every look (`observe`); this decides what's worth a notice. A mute shows
/// once it has held `muteSettle` (a flicker shows nothing), the first state known after the call starts included.
/// Mute not followed shows once a call; a background tab once per stretch in the background, and "followed again"
/// when it's back. While a dictation runs, nothing covers its pill: notices wait until it's over and then only the
/// latest one still fresh shows. General → Calls → Show call notices turns them all off.
@MainActor
final class CallNotices {
    /// How a mute was known.
    enum MuteSource: Equatable, Sendable {
        /// The call's Mute button (Meet, Discord, Slack, Telemost, Zoom on the web).
        case button
        /// Zoom's Meeting menu, in its desktop app.
        case zoomMenu
        /// The app let go of the mic (Telegram): its name.
        case micRelease(String)
        /// The browser extension, from inside the call's page.
        case page
    }

    /// What the monitor sees of the live call's mute at one look.
    struct MuteObservation: Equatable, Sendable {
        /// true muted, false not, nil unknown.
        var muted: Bool?
        var source: MuteSource?
        /// For a browser whose call tab is in the background: the tab's name ("Meet").
        var hiddenTab: String?
        /// The app's mute can't be read at all (no controls anyone knows).
        var unfollowable = false

        init(muted: Bool? = nil, source: MuteSource? = nil, hiddenTab: String? = nil, unfollowable: Bool = false) {
            self.muted = muted
            self.source = source
            self.hiddenTab = hiddenTab
            self.unfollowable = unfollowable
        }
    }

    enum Event: Equatable, Sendable {
        case detected(title: String)
        case mute(Bool, title: String, source: MuteSource)
        case muteNotFollowed(title: String)
        case muteHidden(tab: String)
        case muteBack
        case ended(seconds: TimeInterval, transcribing: Bool)
    }

    /// A mute must hold this long to show: Meet's button flickers as it's clicked, the mic as Telegram reconnects.
    static let muteSettle: TimeInterval = 1
    /// A tab must stay in the background this long: switching through it shows nothing.
    static let hiddenSettle: TimeInterval = 1.5
    /// How long after a call is confirmed its mute may still turn out readable, before "isn't followed" shows.
    static let notFollowedAfter: TimeInterval = 10
    /// A notice held back during a dictation that's older than this is dropped.
    static let staleAfter: TimeInterval = 20
    /// The call's state (noticed, ended) and its mute go in two slots, so one doesn't replace the other at once.
    nonisolated static let stateKey = "call.notice.state"
    nonisolated static let muteKey = "call.notice.mute"

    private let toasts: ToastCenter
    private let settings: AppSettings
    /// Whether a dictation is running, whose pill nothing may cover.
    var isDictating: () -> Bool
    /// Where mute changes go, as the log names them; a test's own log in tests.
    var log: DiagnosticLog = .shared

    /// The live call's id, while one is confirmed.
    private var call: UUID?
    private var confirmedAt: TimeInterval = 0
    private var shownMute: Bool?
    private var candidate: (muted: Bool, source: MuteSource, since: TimeInterval)?
    private var everKnown = false
    private var notFollowedShown = false
    private var hiddenSince: TimeInterval?
    private var hiddenShown = false
    /// Held back during a dictation, with when.
    private var waiting: [(event: Event, at: TimeInterval)] = []

    init(toasts: ToastCenter, settings: AppSettings, isDictating: @escaping () -> Bool = { false }) {
        self.toasts = toasts
        self.settings = settings
        self.isDictating = isDictating
    }

    // MARK: From the monitor

    /// The call is confirmed (asked about, or kept): its mute is followed from now on.
    func confirmed(_ id: UUID, at time: TimeInterval) {
        guard call != id else { return }
        call = id
        confirmedAt = time
        shownMute = nil
        candidate = nil
        everKnown = false
        notFollowedShown = false
        hiddenSince = nil
        hiddenShown = false
    }

    /// The call was confirmed and kept without a question (Automatic, or a call going on after a relaunch).
    func detected(title: String, at time: TimeInterval) {
        emit(.detected(title: title), at: time)
    }

    /// One look at the live call's mute.
    func observe(_ seen: MuteObservation, title: String, at time: TimeInterval) {
        guard call != nil else { return }
        if let tab = seen.hiddenTab {
            candidate = nil
            let since = hiddenSince ?? time
            hiddenSince = since
            if !hiddenShown, time - since >= Self.hiddenSettle {
                hiddenShown = true
                emit(.muteHidden(tab: tab), at: time)
            }
            return
        }
        hiddenSince = nil
        if hiddenShown, seen.muted != nil {
            hiddenShown = false
            emit(.muteBack, at: time)
        }
        guard let muted = seen.muted, let source = seen.source else {
            candidate = nil
            let due = seen.unfollowable || time - confirmedAt >= Self.notFollowedAfter
            if !everKnown, !notFollowedShown, due {
                notFollowedShown = true
                emit(.muteNotFollowed(title: title), at: time)
            }
            return
        }
        everKnown = true
        guard muted != shownMute else {
            candidate = nil
            return
        }
        guard let pending = candidate, pending.muted == muted else {
            candidate = (muted, source, time)
            return
        }
        guard time - pending.since >= Self.muteSettle else { return }
        candidate = nil
        shownMute = muted
        log.event(.calls, "call.mute", ["call": call.map(CallTranscriber.shortID), "muted": muted,
                                        "source": Self.code(source)])
        emit(.mute(muted, title: title, source: source), at: time)
    }

    /// The call ended and went to the store: `seconds` long, transcribed now or not.
    func ended(seconds: TimeInterval, transcribing: Bool, at time: TimeInterval) {
        call = nil
        candidate = nil
        emit(.ended(seconds: seconds, transcribing: transcribing), at: time)
    }

    /// The call is gone without ending as a call (discarded, not a call after all): nothing more about it.
    func dropped() {
        call = nil
        candidate = nil
        waiting.removeAll()
    }

    /// Every look: what waited for a dictation to end shows once it has.
    func tick(at time: TimeInterval) {
        guard !waiting.isEmpty, !isDictating() else { return }
        let fresh = waiting.filter { time - $0.at <= Self.staleAfter }
        waiting.removeAll()
        guard settings.showsCallNotices else { return }
        // Only the latest of each slot: the rest is what was, not what is.
        for key in [Self.stateKey, Self.muteKey] {
            if let last = fresh.last(where: { Self.key(of: $0.event) == key }) { post(last.event) }
        }
    }

    // MARK: Showing

    private func emit(_ event: Event, at time: TimeInterval) {
        guard settings.showsCallNotices else { return }
        if isDictating() {
            waiting.append((event, time))
            return
        }
        post(event)
    }

    /// Into its slot, never pushing out a notice of another kind: with the stack full of others, it's skipped.
    private func post(_ event: Event) {
        let notice = Notice.callStatus(event)
        let replaces = toasts.notices.contains { $0.dedupeKey == notice.dedupeKey }
        guard replaces || toasts.notices.count < ToastCenter.maxVisible else { return }
        toasts.post(notice)
    }

    nonisolated static func key(of event: Event) -> String {
        switch event {
        case .detected, .ended: stateKey
        case .mute, .muteNotFollowed, .muteHidden, .muteBack: muteKey
        }
    }

    private static func code(_ source: MuteSource) -> String {
        switch source {
        case .button: "button"
        case .zoomMenu: "zoomMenu"
        case .micRelease: "micRelease"
        case .page: "page"
        }
    }

    /// "Meet" for Google Meet's tab, the service's name for the rest.
    static func tabName(_ service: CallService?) -> String {
        guard let service else { return "call’s" }
        return service == .meet ? "Meet" : service.name
    }
}

extension Notice {
    /// One of the call's brief notices (`CallNotices`): a single row, silent, about 1.8 s on screen.
    static func callStatus(_ event: CallNotices.Event) -> Notice {
        let title: String
        var detail: String?
        var symbol = "phone"
        switch event {
        case .detected(let name):
            title = "Call detected · \(name)"
        case .mute(let muted, let name, let source):
            title = muted ? "You’re muted · \(name)" : "You’re unmuted · \(name)"
            symbol = muted ? "mic.slash" : "mic"
            detail = switch source {
            case .button: "From the Mute button"
            case .zoomMenu: "From Zoom’s Meeting menu"
            case .micRelease(let app): muted ? "\(app) let go of the mic" : "\(app) took the mic again"
            case .page: "From the browser extension"
            }
        case .muteNotFollowed(let name):
            title = "Mute isn’t followed in \(name)"
            symbol = "mic.badge.xmark"
        case .muteHidden(let tab):
            title = "Can’t see mute while the \(tab) tab is in the background"
            symbol = "mic.badge.xmark"
        case .muteBack:
            title = "Mute is followed again"
            symbol = "mic"
        case .ended(let seconds, let transcribing):
            title = "Call ended · \(CallPrompts.clock(seconds))" + (transcribing ? " · transcribing" : "")
            symbol = "phone.down"
        }
        return Notice(dedupeKey: CallNotices.key(of: event), style: .info, symbol: symbol, title: title,
                      detail: detail, lifetime: .seconds(3.6), sound: nil)
    }
}
