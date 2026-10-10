import Foundation

/// Pure call detector: fed what each app does with the mic and the speakers a couple of times a second, it says when a
/// call starts, when the person's mic is released during it, and when it ends. Time is injected as monotonic seconds
/// so tests can drive it.
///
/// A call is one app with mic and sound at once: a voice note records without playing, a video plays without
/// recording, and neither is a call. It is suspected the moment both are on (keep audio from `suspectedAt`), a call
/// once they've stayed on together for `confirmAfter`, and over once the app has been silent for `endAfter`, so
/// pauses, reconnects and leave chimes don't end or restart it. Only one call at a time; a second app doing the same
/// meanwhile is not followed.
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
        /// not the person muting: it's left out of `Call.mutes`.
        var leaveTail: TimeInterval = 10
    }

    /// What one app is doing at a moment: recording from a mic, playing sound.
    struct Activity: Equatable, Sendable {
        var mic: Bool
        var sound: Bool
    }

    struct Call: Equatable, Sendable {
        var app: CallApp
        /// When the app first had mic and sound together: where its recording begins.
        var startedAt: TimeInterval
        /// The last moment the app had mic or sound: the call's end once it's over.
        var lastAudioAt: TimeInterval
        /// When the app gave the mic back while sound went on, and when it took it again. Telegram releases the mic
        /// while muted; Meet and Discord keep it, so their mutes aren't seen.
        var mutes: [ClosedRange<TimeInterval>] = []
        /// Set while the mic is released: the mute that hasn't ended yet.
        var micReleasedAt: TimeInterval?

        var micReleased: Bool { micReleasedAt != nil }
        var duration: TimeInterval { lastAudioAt - startedAt }
    }

    enum Phase: Equatable, Sendable {
        case idle
        case suspected(CallApp, since: TimeInterval)
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

    init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Where audio worth keeping begins: the suspicion's start, or the call's.
    var keepAudioFrom: TimeInterval? {
        switch phase {
        case .idle: nil
        case .suspected(_, let since): since
        case .call(let call): call.startedAt
        }
    }

    var call: Call? {
        if case .call(let call) = phase { call } else { nil }
    }

    private var followedApp: CallApp? {
        switch phase {
        case .idle: nil
        case .suspected(let app, _): app
        case .call(let call): call.app
        }
    }

    /// One look at every app with audio at `time`; an app left out has neither.
    mutating func feed(_ apps: [CallApp: Activity], at time: TimeInterval) -> [Event] {
        let followed = followedApp
        for app in Set(signals.keys).union(apps.keys) {
            let activity = apps[app] ?? Activity(mic: false, sound: false)
            var signal = signals[app] ?? Signals()
            signal.mic.update(activity.mic, at: time, flicker: settings.flicker)
            signal.sound.update(activity.sound, at: time, flicker: settings.flicker)
            // The followed app keeps its entry while silent: when it went off is its call's end.
            signals[app] = signal.isIdle && app != followed ? nil : signal
        }
        var events: [Event] = []
        switch phase {
        case .idle:
            break
        case .suspected(let app, let since):
            if signals[app]?.isBoth == true {
                if lasted(since, time, settings.confirmAfter) {
                    let call = Call(app: app, startedAt: since, lastAudioAt: time)
                    phase = .call(call)
                    events.append(.started(call))
                }
            } else {
                let at = signals[app]?.offAt ?? time
                phase = .idle
                events.append(.dropped(app, at: at))
            }
        case .call(var call):
            events += follow(&call, at: time)
            if let quietSince, lasted(quietSince, time, settings.endAfter) {
                events.append(.ended(end(&call, at: quietSince, hungUp: true)))
                phase = .idle
            } else {
                phase = .call(call)
            }
        }
        // The app that has had both the longest goes first; one that had them while another was followed is
        // suspected from now, since nothing kept its audio before.
        if phase == .idle, let app = signals.compactMap({ app, signal in signal.bothSince.map { (since: $0, app: app) } })
            .min(by: { ($0.since, $0.app) < ($1.since, $1.app) })?.app {
            phase = .suspected(app, since: time)
            events.append(.suspected(app, at: time))
        }
        return events
    }

    /// Stops following now: a call ends at once (at its last audio, or now if it still has some), a suspicion is
    /// dropped.
    mutating func stop(at time: TimeInterval) -> [Event] {
        defer { phase = .idle; quietSince = nil }
        switch phase {
        case .idle:
            return []
        case .suspected(let app, _):
            return [.dropped(app, at: time)]
        case .call(var call):
            return [.ended(end(&call, at: quietSince ?? time, hungUp: false))]
        }
    }

    // MARK: Steps

    /// Mutes, silences and the last audio of the call in progress.
    private mutating func follow(_ call: inout Call, at time: TimeInterval) -> [Event] {
        let signal = signals[call.app] ?? Signals()
        var events: [Event] = []
        if signal.mic.isOn, let releasedAt = call.micReleasedAt {
            let back = signal.mic.since ?? time
            call.mutes.append(releasedAt...max(releasedAt, back))
            call.micReleasedAt = nil
            events.append(.micBack(call.app, at: back))
        } else if !signal.mic.isOn, signal.sound.isOn, call.micReleasedAt == nil {
            let releasedAt = signal.mic.offAt ?? time
            call.micReleasedAt = releasedAt
            events.append(.micReleased(call.app, at: releasedAt))
        }
        if signal.mic.isOn || signal.sound.isOn {
            quietSince = nil
            call.lastAudioAt = time
        } else if quietSince == nil {
            let quiet = [signal.mic.offAt, signal.sound.offAt].compactMap { $0 }.max() ?? time
            quietSince = quiet
            call.lastAudioAt = max(call.startedAt, quiet)
        }
        return events
    }

    /// Closes the call at `end`. When it went silent by itself (`hungUp`), a mic released in its last `leaveTail`
    /// seconds was the app leaving, not a mute.
    private mutating func end(_ call: inout Call, at end: TimeInterval, hungUp: Bool) -> Call {
        call.lastAudioAt = max(call.startedAt, end)
        if let releasedAt = call.micReleasedAt {
            if !hungUp || lasted(releasedAt, call.lastAudioAt, settings.leaveTail) {
                call.mutes.append(releasedAt...max(releasedAt, call.lastAudioAt))
            }
            call.micReleasedAt = nil
        }
        signals[call.app] = nil
        quietSince = nil
        return call
    }
}

// MARK: - Signals

extension CallDetector {
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
    }
}

/// Whether `from` to `to` is at least `span`, give or take a microsecond: 197.3 - 177.3 is 19.999999999999972.
private func lasted(_ from: TimeInterval, _ to: TimeInterval, _ span: TimeInterval) -> Bool {
    to - from >= span - 1e-6
}
