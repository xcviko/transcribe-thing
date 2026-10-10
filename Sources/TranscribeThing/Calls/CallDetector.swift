import Foundation

/// Pure call detector: fed what each app does with the mic and the speakers a couple of times a second, and what the
/// followed app's own window shows whenever that's read, it says when a call starts, when the person's mic is
/// released during it, and when it ends. Time is injected as monotonic seconds so tests can drive it.
///
/// A call is one app with mic and sound at once: a voice note records without playing, a video plays without
/// recording, and neither is a call. It is suspected the moment both are on (keep audio from `suspectedAt`), a call
/// once they've stayed on together for `confirmAfter`, and over once the app has been silent for `endAfter`, so
/// pauses, reconnects and leave chimes don't end or restart it.
///
/// A browser is one app to the HAL, whichever tab plays or records, so a browser's call is also its tab (`Tab`, from
/// `Window`): when the tab holding it is another service's, the call ends and that tab's is suspected. Meet,
/// Discord, Zoom, Slack and Telemost keep the mic while muted, so for them a released mic is leaving, over at once
/// when the window agrees (the tab stops recording or goes, the Leave button goes), and their mutes come from their
/// Mute button. Telegram releases the mic to mute, so for it a released mic is the mute.
///
/// One call at a time: another app with both is only followed once the call has gone silent, and then takes over,
/// ending it at its last audio, once it has had both for `confirmAfter`.
struct CallDetector: Equatable, Sendable {
    struct Settings: Equatable, Sendable {
        /// How long mic and sound must stay on together before it's a call: a voice note played back while recording
        /// another, or a short test, stays a suspicion and is dropped.
        var confirmAfter: TimeInterval = 20
        /// How long the app must have neither before the call is over.
        var endAfter: TimeInterval = 60
        /// A signal off for less than this hasn't gone off: devices switching, a stream restarting.
        var flicker: TimeInterval = 1.5
        /// A mic released this close to the end of the call is the app hanging up, its leave chime still playing,
        /// not the person muting: it's left out of `Call.mutes`. It's also as long as sound still counts as the
        /// call's after an app that keeps the mic while muted gives it back.
        var leaveTail: TimeInterval = 10
    }

    /// What one app is doing at a moment: recording from a mic, playing sound.
    struct Activity: Equatable, Sendable {
        var mic: Bool
        var sound: Bool
    }

    /// The browser tab a call is in, as the tab reader saw it. The HAL can't tell a browser's tabs apart; the tab
    /// strip can, so tabs with another `key` hold another call.
    struct Tab: Equatable, Sendable {
        /// `BrowserTabs.key`: the service, for Meet with its meeting; an unknown page by its title.
        var key: String
        var service: CallService?
        /// The page's title, without what the browser adds.
        var page: String
        /// What the tab says it records; nil when it was picked by its title alone.
        var recording: BrowserTabs.Recording?

        init(service: CallService?, page: String, recording: BrowserTabs.Recording? = nil) {
            key = BrowserTabs.key(service: service, page: page)
            self.service = service
            self.page = page
            self.recording = recording
        }

        init(_ tab: BrowserTabs.CallTab) {
            self.init(service: tab.service, page: tab.page, recording: tab.recording)
        }
    }

    /// One read of the followed app's own window, fed with the step it arrives in.
    struct Window: Equatable, Sendable {
        /// For a browser: the tab holding the call, nil when no tab records or is titled like one. Not used for
        /// other apps.
        var tab: Tab?
        /// What its Mute button says: true muted, false live, nil when it can't be read (a background tab).
        var muted: Bool?
        /// Whether it shows a Leave button; nil when its labels have none or it wasn't read.
        var inCall: Bool?

        init(tab: Tab? = nil, muted: Bool? = nil, inCall: Bool? = nil) {
            self.tab = tab
            self.muted = muted
            self.inCall = inCall
        }
    }

    struct Call: Equatable, Sendable {
        var app: CallApp
        /// For a browser: the tab the call is in, as last read; nil until it's read.
        var tab: Tab?
        /// When the app first had mic and sound together: where its recording begins.
        var startedAt: TimeInterval
        /// The last moment the app had mic or sound: the call's end once it's over.
        var lastAudioAt: TimeInterval
        /// When the person was muted: from the mic given back and taken again for Telegram, which releases it to
        /// mute; from the Mute button for the rest, which keep it.
        var mutes: [ClosedRange<TimeInterval>] = []
        /// Set while the mic is released: for Telegram, the mute that hasn't ended yet.
        var micReleasedAt: TimeInterval?
        /// Set while the Mute button shows muted: the mute that hasn't ended yet.
        var mutedSince: TimeInterval?

        var micReleased: Bool { micReleasedAt != nil }
        var duration: TimeInterval { lastAudioAt - startedAt }
        var isBrowser: Bool { CallAppKind.of(app.id) == .browser }
        /// The browser tab's service, or the desktop app's.
        var service: CallService? { tab?.service ?? CallAppKind.of(app.id).service }
        /// Whether a released mic is a mute: yes for Telegram; no for the services that keep the mic while muted;
        /// maybe, for one nobody knows, so it's counted as before.
        var micReleaseIsMute: Bool { service?.releasesMicOnMute ?? true }
    }

    enum Phase: Equatable, Sendable {
        case idle
        /// Mic and sound together for less than `confirmAfter`: a call not yet confirmed.
        case suspected(Call)
        case call(Call)
    }

    /// What changed in one step. Times are when it happened, which can be up to `flicker` before the step that
    /// noticed it (a signal is only off once it has stayed off).
    enum Event: Equatable, Sendable {
        case suspected(CallApp, at: TimeInterval)
        /// Mic and sound stopped being on together before `confirmAfter`: not a call.
        case dropped(CallApp, at: TimeInterval)
        case started(Call)
        case micReleased(CallApp, at: TimeInterval)
        case micBack(CallApp, at: TimeInterval)
        /// The call as it ended: `lastAudioAt` is its end.
        case ended(Call)
    }

    var settings: Settings
    private(set) var phase: Phase = .idle
    private var signals: [CallApp: Signals] = [:]
    /// While the call's app is silent: since when.
    private var quietSince: TimeInterval?
    /// What the followed call's window has shown.
    private var shown = Shown()
    /// Another app with mic and sound while the call is silent, and since when it counts.
    private var rival: (app: CallApp, since: TimeInterval)?

    init(settings: Settings = Settings()) {
        self.settings = settings
    }

    static func == (lhs: CallDetector, rhs: CallDetector) -> Bool {
        lhs.settings == rhs.settings && lhs.phase == rhs.phase && lhs.signals == rhs.signals
            && lhs.quietSince == rhs.quietSince && lhs.shown == rhs.shown && lhs.rival?.app == rhs.rival?.app
            && lhs.rival?.since == rhs.rival?.since
    }

    /// Where audio worth keeping begins: the suspicion's start, or the call's.
    var keepAudioFrom: TimeInterval? { followed?.startedAt }

    /// The confirmed call.
    var call: Call? {
        if case .call(let call) = phase { call } else { nil }
    }

    /// The call followed, suspected or confirmed: the app whose window is worth reading.
    var followed: Call? {
        switch phase {
        case .idle: nil
        case .suspected(let call), .call(let call): call
        }
    }

    /// One look at every app with audio at `time` (an app left out has neither), and the followed app's window if
    /// it was read since the last look.
    mutating func feed(_ apps: [CallApp: Activity], windows: [CallApp: Window] = [:], at time: TimeInterval) -> [Event] {
        let followedApp = followed?.app
        for app in Set(signals.keys).union(apps.keys) {
            let activity = apps[app] ?? Activity(mic: false, sound: false)
            var signal = signals[app] ?? Signals()
            signal.mic.update(activity.mic, at: time, flicker: settings.flicker)
            signal.sound.update(activity.sound, at: time, flicker: settings.flicker)
            // The followed app keeps its entry while silent: when it went off is its call's end (or the rival's
            // suspicion's).
            signals[app] = signal.isIdle && app != followedApp && app != rival?.app ? nil : signal
        }
        var events: [Event] = []
        if let app = followedApp {
            let micNow = apps[app]?.mic == true
            if micNow { shown.hungUp = false }
            if let window = windows[app] { events += see(window, micNow: micNow, at: time) }
        }
        switch phase {
        case .idle:
            break
        case .suspected(var call):
            if signals[call.app]?.isBoth == true {
                if lasted(call.startedAt, time, settings.confirmAfter) {
                    call.lastAudioAt = time
                    phase = .call(call)
                    events.append(.started(call))
                }
            } else {
                events.append(.dropped(call.app, at: signals[call.app]?.offAt ?? time))
                forget()
            }
        case .call(var call):
            events += follow(&call, at: time)
            if shown.hungUp, signals[call.app]?.mic.isOn != true {
                events.append(.ended(end(&call, at: quietSince ?? time, how: .hungUp)))
                signals[call.app] = nil
            } else if let quietSince, lasted(quietSince, time, settings.endAfter) {
                events.append(.ended(end(&call, at: quietSince, how: .silent)))
                signals[call.app] = nil
            } else {
                phase = .call(call)
                events += challenge(call, at: time)
            }
        }
        // The app that has had both the longest goes first; one that had them while another was followed is
        // suspected from now, since nothing kept its audio before, unless it was already the call's rival.
        if phase == .idle, let pick = signals.compactMap({ app, signal in signal.bothSince.map { (since: $0, app: app) } })
            .min(by: { ($0.since, $0.app) < ($1.since, $1.app) }) {
            if let rival, rival.app == pick.app {
                phase = .suspected(Call(app: pick.app, startedAt: rival.since, lastAudioAt: time))
            } else {
                phase = .suspected(Call(app: pick.app, startedAt: time, lastAudioAt: time))
                events.append(.suspected(pick.app, at: time))
            }
        }
        if call == nil, let rival {
            if followed?.app != rival.app { events.append(.dropped(rival.app, at: time)) }
            self.rival = nil
        }
        return events
    }

    /// Stops following now: a call ends at once (at its last audio, or now if it still has some), a suspicion is
    /// dropped.
    mutating func stop(at time: TimeInterval) -> [Event] {
        var events: [Event] = []
        switch phase {
        case .idle:
            break
        case .suspected(let call):
            events.append(.dropped(call.app, at: time))
            forget()
        case .call(var call):
            if let rival { events.append(.dropped(rival.app, at: time)) }
            events.append(.ended(end(&call, at: quietSince ?? time, how: .stopped)))
            signals[call.app] = nil
        }
        rival = nil
        return events
    }

    // MARK: Steps

    /// Mutes, silences and the last audio of the call in progress.
    private mutating func follow(_ call: inout Call, at time: TimeInterval) -> [Event] {
        let signal = signals[call.app] ?? Signals()
        var events: [Event] = []
        var audible = signal.mic.isOn || signal.sound.isOn
        var quiet = [signal.mic.offAt, signal.sound.offAt].compactMap { $0 }.max() ?? time
        if !call.micReleaseIsMute, !signal.mic.isOn {
            // Meet, Discord and Zoom hold the mic all call long, muted or not. Once it's given back, only the sound
            // that goes straight on (the leave chime, up to `leaveTail`) is still the call's: sound after a silence
            // is another tab's, or a notification.
            let micOff = signal.mic.offAt ?? call.startedAt
            audible = signal.sound.isOn && quietSince == nil && !lasted(micOff, time, settings.leaveTail)
            if signal.sound.isOn { quiet = min(time, micOff + settings.leaveTail) }
        }
        if signal.mic.isOn, let releasedAt = call.micReleasedAt {
            let back = signal.mic.since ?? time
            if call.micReleaseIsMute { call.mutes.append(releasedAt...max(releasedAt, back)) }
            call.micReleasedAt = nil
            events.append(.micBack(call.app, at: back))
        } else if !signal.mic.isOn, audible, call.micReleasedAt == nil {
            let releasedAt = signal.mic.offAt ?? time
            call.micReleasedAt = releasedAt
            events.append(.micReleased(call.app, at: releasedAt))
        }
        if audible {
            quietSince = nil
            call.lastAudioAt = time
        } else if quietSince == nil {
            quietSince = quiet
            call.lastAudioAt = max(call.startedAt, quiet)
        }
        return events
    }

    /// One read of the followed app's window: a browser's call tab (taken on, updated, or another call's), the Mute
    /// button, the Leave button. `micNow` is whether the app records at this look, before any smoothing.
    private mutating func see(_ window: Window, micNow: Bool, at time: TimeInterval) -> [Event] {
        guard var call = followed else { return [] }
        if call.isBrowser {
            guard let tab = window.tab else {
                // No tab records or is titled like a call: with the mic off too, it was hung up.
                if !micNow { shown.hungUp = true }
                return []
            }
            if let current = call.tab, current.key != tab.key {
                // While the mic is on and no tab says it records, the one titled like a call needn't be the one
                // with the mic, so it says nothing (and neither do its buttons).
                guard tab.recording != nil || !micNow else { return [] }
                return switchTab(to: tab, at: time)
            }
            call.tab = tab
            // Meet and the like record all call long, muted or not: their tab not recording, the mic off, is gone.
            if !micNow, !call.micReleaseIsMute, tab.recording?.hasMic != true { shown.hungUp = true }
        }
        if let muted = window.muted {
            if muted, call.mutedSince == nil {
                call.mutedSince = time
            } else if !muted, let since = call.mutedSince {
                call.mutes.append(since...max(since, time))
                call.mutedSince = nil
            }
        }
        if let inCall = window.inCall {
            if inCall { shown.leave = true } else if shown.leave, !micNow { shown.hungUp = true }
        }
        switch phase {
        case .idle: break
        case .suspected: phase = .suspected(call)
        case .call: phase = .call(call)
        }
        return []
    }

    /// The followed browser's call tab now holds another call: the call ends at its last audio (a suspicion is
    /// dropped), and the new tab's is suspected from now if the browser has mic and sound.
    private mutating func switchTab(to tab: Tab, at time: TimeInterval) -> [Event] {
        var events: [Event] = []
        let app: CallApp
        switch phase {
        case .idle:
            return []
        case .suspected(let call):
            app = call.app
            events.append(.dropped(app, at: time))
            forget()
        case .call(var call):
            app = call.app
            events.append(.ended(end(&call, at: quietSince ?? time, how: .hungUp)))
        }
        var signal = signals[app] ?? Signals()
        signal.restart(at: time)
        signals[app] = signal.isIdle ? nil : signal
        if signal.isBoth {
            phase = .suspected(Call(app: app, tab: tab, startedAt: time, lastAudioAt: time))
            events.append(.suspected(app, at: time))
        }
        return events
    }

    /// While the call is silent, another app with mic and sound is suspected, and once it has had both for
    /// `confirmAfter` it takes over: you aren't on two calls, though the silent one may wait `endAfter` to end.
    private mutating func challenge(_ call: Call, at time: TimeInterval) -> [Event] {
        var events: [Event] = []
        let candidate = quietSince.flatMap { quiet in
            signals.filter { $0.key != call.app }
                .compactMap { app, signal in signal.bothSince.map { (app: app, since: max($0, quiet)) } }
                .min { ($0.since, $0.app) < ($1.since, $1.app) }
        }
        if let rival, rival.app != candidate?.app {
            events.append(.dropped(rival.app, at: signals[rival.app]?.offAt ?? time))
            self.rival = nil
        }
        guard let candidate else { return events }
        if rival == nil {
            rival = candidate
            events.append(.suspected(candidate.app, at: candidate.since))
        }
        guard let rival, lasted(rival.since, time, settings.confirmAfter) else { return events }
        var old = call
        events.append(.ended(end(&old, at: quietSince ?? time, how: .silent)))
        signals[old.app] = nil
        let new = Call(app: rival.app, startedAt: rival.since, lastAudioAt: time)
        phase = .call(new)
        self.rival = nil
        events.append(.started(new))
        return events
    }

    private enum Ending {
        /// Silent for `endAfter`, or another app's call took over.
        case silent
        /// The window said so, or its tab is another call's: a mic still released was leaving, not muting.
        case hungUp
        /// `stop`: a mic still released is a mute that lasted to the end.
        case stopped
    }

    /// Closes the call at `end`. When it went silent by itself, a mic released in its last `leaveTail` seconds was
    /// the app leaving, not a mute; a Mute button still on lasts until the mic was given back.
    private mutating func end(_ call: inout Call, at end: TimeInterval, how: Ending) -> Call {
        call.lastAudioAt = max(call.startedAt, end)
        if let since = call.mutedSince {
            let until = call.micReleaseIsMute ? call.lastAudioAt : min(call.micReleasedAt ?? call.lastAudioAt, call.lastAudioAt)
            call.mutes.append(since...max(since, until))
            call.mutedSince = nil
        }
        if let releasedAt = call.micReleasedAt {
            let mute = switch how {
            case .silent: lasted(releasedAt, call.lastAudioAt, settings.leaveTail)
            case .hungUp: false
            case .stopped: true
            }
            if mute, call.micReleaseIsMute { call.mutes.append(releasedAt...max(releasedAt, call.lastAudioAt)) }
            call.micReleasedAt = nil
        }
        call.mutes.sort { $0.lowerBound < $1.lowerBound }
        forget()
        return call
    }

    /// Back to following nothing.
    private mutating func forget() {
        phase = .idle
        quietSince = nil
        shown = Shown()
    }
}

// MARK: - Signals

extension CallDetector {
    /// What the followed call's window has shown.
    private struct Shown: Equatable, Sendable {
        /// A Leave button was there during the call.
        var leave = false
        /// With the mic off, a read said the call is gone: no call tab, a Meet-like tab no longer recording, the
        /// Leave button gone. Undone by the mic coming back.
        var hungUp = false
    }

    /// One app's mic and sound, each with flickers shorter than `Settings.flicker` smoothed over.
    private struct Signals: Equatable, Sendable {
        var mic = Signal()
        var sound = Signal()

        var isBoth: Bool { mic.isOn && sound.isOn }
        /// Since when both have been on, while they are.
        var bothSince: TimeInterval? {
            guard let mic = mic.since, let sound = sound.since else { return nil }
            return max(mic, sound)
        }
        var isIdle: Bool { mic.isIdle && sound.isIdle }
        /// When the later of the two went off, if either did.
        var offAt: TimeInterval? { [mic.offAt, sound.offAt].compactMap { $0 }.max() }

        mutating func restart(at time: TimeInterval) {
            mic.restart(at: time)
            sound.restart(at: time)
        }
    }

    /// A signal that is on from the first look that sees it on until it has been seen off for `flicker` seconds; it
    /// then went off at the first look that saw it off.
    private struct Signal: Equatable, Sendable {
        /// When it came on, while it is on.
        private(set) var since: TimeInterval?
        /// Seen off since then, while it is still counted on.
        private var pendingOff: TimeInterval?
        /// When it last went off.
        private(set) var offAt: TimeInterval?

        var isOn: Bool { since != nil }
        var isIdle: Bool { since == nil }

        mutating func update(_ on: Bool, at time: TimeInterval, flicker: TimeInterval) {
            if on {
                if since == nil { since = time }
                pendingOff = nil
            } else if since != nil {
                let off = pendingOff ?? time
                pendingOff = off
                if lasted(off, time, flicker) {
                    since = nil
                    pendingOff = nil
                    offAt = off
                }
            }
        }

        /// As if it had been seen first at `time`, for a new call in the same app: on since then if it's on, off
        /// from then if it's going off.
        mutating func restart(at time: TimeInterval) {
            guard since != nil else { return }
            if pendingOff != nil {
                since = nil
                pendingOff = nil
                offAt = time
            } else {
                since = time
            }
        }
    }
}

/// Whether `from` to `to` is at least `span`, give or take a microsecond: 197.3 - 177.3 is 19.999999999999972.
private func lasted(_ from: TimeInterval, _ to: TimeInterval, _ span: TimeInterval) -> Bool {
    to - from >= span - 1e-6
}
