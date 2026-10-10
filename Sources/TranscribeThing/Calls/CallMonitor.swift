import CoreAudio
import Foundation
import Observation

/// An answer to "Transcribe your call?": Transcribe, Don't Keep, Never for ….
enum CallAnswer: Equatable, Sendable {
    case keep, discard, never
}

/// One call being recorded: its journal (`CallJournal`) and the sources of its two tracks.
@MainActor
final class CallRecorder {
    let id: UUID
    /// `AudioClock` time of the call's sample 0.
    let origin: TimeInterval
    private let journal: CallJournal
    private let sources: [CallJournal.Track: any CallTrackSource]

    init(journal: CallJournal, info: CallJournal.Info, origin: TimeInterval,
         sources: [CallJournal.Track: any CallTrackSource]) {
        id = info.id
        self.origin = origin
        self.journal = journal
        self.sources = sources
        journal.begin(info, origin: origin, sources: sources)
    }

    func update(_ change: @escaping @Sendable (inout CallJournal.Info) -> Void) {
        journal.update(id, change)
    }

    /// The call app's processes now: the tap takes them in.
    func retarget(_ processes: [AudioObjectID]) {
        sources[.remote]?.retarget(processes)
    }

    /// Stops recording; returns the journal's last word on the call, once its files are closed.
    func finish() async -> CallJournal.Info? {
        await journal.end(id)
    }

    /// Stops recording and deletes everything recorded.
    func discard() {
        journal.discard(id)
    }
}

/// Notices calls and records them (SPEC: call recording v1). While `settings.callRecording` isn't `.off` it looks at
/// the HAL twice a second (`CallWatch`, as the `--audio-watch` probe does): any app with mic and sound at once (save
/// `CallDenylist`'s and the person's `CallExclusion`s) starts a recording at once (`.suspected`), so the call's start
/// isn't lost; once `CallDetector` confirms the call, `.ask` asks "Transcribe your call in <service>?" (`.asking`,
/// `onAsk`) and `.automatic` keeps it (`.recording`). A suspicion that drops, No, or Never for ... deletes what was
/// recorded. A kept call that ends goes to the Calls store (`CallStore.adopt`) and is transcribed
/// (`CallTranscriber`); one that ends unanswered waits there as `.unconfirmed`. A browser counts only once a tab says
/// it records the mic, or is titled like a known service (`BrowserTabs.callTab`); when none of its windows can be
/// read (no Accessibility), it counts as a whole, like any app.
///
/// The menu bar's Start Call Recording records the mic and everything the Mac plays, whatever the setting, mute not
/// followed; during a noticed call it just keeps that call. Dictation is never touched: it has its own capture.
@MainActor @Observable
final class CallMonitor {
    /// What's known about the live call.
    struct CallInfo: Equatable, Sendable {
        var id: UUID
        /// "Telegram", "Google Chrome", "FaceTime", "All sound" for a manual recording.
        var appName: String
        var bundleID: String?
        /// Known for a known call app at once, for a browser once its tab is read; nil for any other app or site.
        var service: CallService?
        /// For a browser: the call tab's page.
        var pageTitle: String?
        var startedAt: Date
        /// When the person was muted so far, in seconds from the call's start.
        var mutes: [CallInterval] = []
        /// Whether mute can be followed at all for this call.
        var muteKnown = false
        var manual = false

        /// "Google Meet", "Telegram", "ChatGPT" (a site no service is known for, by its page), "FaceTime", "All sound".
        var title: String { service?.name ?? pageTitle.flatMap { $0.isEmpty ? nil : $0 } ?? appName }
    }

    enum State: Equatable, Sendable {
        case idle
        /// Mic and sound together, not yet a confirmed call: recording, nothing asked.
        case suspected(CallInfo)
        /// A confirmed call, recording, the question open.
        case asking(CallInfo)
        /// Kept: recording, then transcribed when it ends.
        case recording(CallInfo)
        /// Its files are being closed and encoded.
        case ending
    }

    /// Everything the monitor asks of the system, replaceable in tests.
    struct Dependencies {
        var sensors: CallWatch.Sensors
        /// Monotonic seconds, the clock of the detector and of the tracks' stamps (`AudioClock`).
        var clock: () -> TimeInterval
        var now: () -> Date
        /// The two tracks of a new recording: the mic, and a tap of `target`.
        var makeSources: @MainActor (TapTarget) -> [CallJournal.Track: any CallTrackSource]
        /// The app's name as it shows.
        var appName: @MainActor (CallApp) -> String

        /// The real HAL, Accessibility, mic and taps; the mic dictation would pick.
        static func live(settings: AppSettings) -> Dependencies {
            Dependencies(
                sensors: .live(), clock: { AudioClock.now() }, now: { Date() },
                makeSources: { [weak settings] target in
                    [.mic: MicTrackSource(preferredUID: settings?.microphoneUID), .remote: ProcessTapSource(target: target)]
                },
                appName: { $0.name })
        }
    }

    /// How long a browser has, once recording, for a tab to say it holds the call; after that it's left alone (or,
    /// when none of its windows could be read, taken as a whole).
    static let classifyWithin: TimeInterval = 10
    static let pollInterval: TimeInterval = 0.5
    static let manualName = "All sound"

    private(set) var state: State = .idle
    /// Looking for calls (the setting isn't `.off`).
    private(set) var isWatching = false

    /// A call to ask about: show "Transcribe your call in \(info.title)?" with Yes (`keep(callID:)`), No
    /// (`discard(callID:)`) and Never for ... (`never(callID:)`).
    @ObservationIgnored var onAsk: ((CallInfo) -> Void)?
    /// The question about this call is answered or moot: hide it.
    @ObservationIgnored var onAnswered: ((UUID) -> Void)?
    /// Where events go (what was noticed, asked, answered, how a call ended; never a page's title): a test's own log
    /// in tests.
    @ObservationIgnored var log: DiagnosticLog = .shared
    /// The brief notices about the live call (noticed, muted, ended); none without it.
    @ObservationIgnored var notices: CallNotices?
    /// The time of the last look, on the detector's clock.
    @ObservationIgnored private var lastTime: TimeInterval = 0

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let store: CallStore
    @ObservationIgnored private let transcriber: CallTranscriber
    @ObservationIgnored private let deps: Dependencies
    @ObservationIgnored private let watch: CallWatch
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var live: Live?
    /// An app (or browser) whose current call isn't recorded: discarded, stopped, excluded, or a browser with no call
    /// tab. Until the detector drops or ends it.
    @ObservationIgnored private var ignored: CallApp?
    @ObservationIgnored private var endings: [UUID: Task<Void, Never>] = [:]

    private struct Live {
        var recorder: CallRecorder
        var info: CallInfo
        /// nil for a manual recording.
        var app: CallApp?
        var consent: CallJournal.Consent
        /// The detector has confirmed the call (asked or kept once the browser's tab says what it is).
        var confirmed = false
        /// A browser whose call tab is found (or taken as a whole, its windows unreadable); true for any other app.
        var classified: Bool
        /// For a browser: some read of its windows found at least one, so its tabs can tell.
        var tabsRead = false
        var otherAudio: [CallInterval] = []
        var otherAudioSince: TimeInterval?
        var tapProcesses: [AudioObjectID]
        var origin: TimeInterval { recorder.origin }
    }

    init(settings: AppSettings, store: CallStore, transcriber: CallTranscriber, dependencies: Dependencies) {
        self.settings = settings
        self.store = store
        self.transcriber = transcriber
        deps = dependencies
        watch = CallWatch(sensors: dependencies.sensors)
        // GarageBand, OBS or an app the person excluded is never followed: it would stand in the way of a real call.
        watch.includes = { [weak settings] app in
            !CallDenylist.denies(app) && !(settings?.callExclusions.excludes(app) ?? false)
        }
        // Only the apps whose controls are known have their windows read: the rest have nothing to tell.
        watch.readsWindow = { CallAppKind.of($0.id) != .other }
    }

    /// The live call, whatever its state.
    var current: CallInfo? {
        switch state {
        case .suspected(let info), .asking(let info), .recording(let info): info
        case .idle, .ending: nil
        }
    }

    /// Recording now, a call noticed or a manual one.
    var isRecording: Bool { current != nil }

    // MARK: Watching

    /// Starts looking for calls, twice a second.
    func start() {
        guard !isWatching else { return }
        isWatching = true
        poll()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops looking. A noticed call being recorded ends: kept if it was kept, otherwise deleted. A manual recording
    /// goes on.
    func stop() {
        guard isWatching else { return }
        isWatching = false
        timer?.invalidate()
        timer = nil
        _ = watch.stop(at: deps.clock())
        ignored = nil
        guard let live, live.app != nil else { return }
        if live.consent == .kept { end(live, status: .transcribing) } else { discardLive(ignore: false) }
    }

    /// One look: the HAL now, what the detector makes of it, the live call brought up to date. The timer's job; tests
    /// call it with their own time.
    func poll(at time: TimeInterval? = nil) {
        let time = time ?? deps.clock()
        lastTime = time
        handle(watch.poll(at: time), at: time)
        follow(at: time)
        notices?.tick(at: time)
    }

    // MARK: Answers (the UI's)

    /// Yes: the live call is kept (transcribed when it ends).
    func keep() {
        keepLive(how: "keep")
    }

    /// The live call kept: answered Yes (`how` "keep"), by the Automatic setting, from the menu bar, or as the
    /// continuation of a call the app quit recording.
    private func keepLive(how: String) {
        guard var live, live.consent != .kept else { return }
        if how == "keep" {
            logEvent("call.answered", live, ["answer": "keep"])
        } else {
            logEvent("call.kept", live, ["reason": how])
        }
        live.consent = .kept
        live.confirmed = true
        self.live = live
        if !live.info.manual { notices?.confirmed(live.info.id, at: lastTime) }
        live.recorder.update { $0.consent = .kept }
        store.upsert(record(of: live, status: .recording))
        state = .recording(live.info)
        onAnswered?(live.info.id)
    }

    /// Yes, about a call by id: the live one, or one that ended unanswered (`.unconfirmed`), which is transcribed now.
    func keep(callID: UUID) {
        if live?.info.id == callID { return keep() }
        guard let call = store.call(id: callID), call.status == .unconfirmed else { return }
        log.event(.calls, "call.answered", ["call": CallTranscriber.shortID(callID), "answer": "keep", "late": true])
        onAnswered?(callID)
        transcriber.transcribe(callID)
    }

    /// No: the live call's recording is deleted, and that call isn't recorded again.
    func discard() {
        guard let live else { return }
        logEvent("call.answered", live, ["answer": "discard"])
        discardLive()
    }

    /// No, about a call by id: the live one, or one that ended unanswered, deleted with its audio.
    func discard(callID: UUID) {
        drop(callID: callID, answer: "discard")
    }

    /// No or Never for ..., about the live call or one that ended unanswered.
    private func drop(callID: UUID, answer: String) {
        if let live, live.info.id == callID {
            logEvent("call.answered", live, ["answer": answer])
            return discardLive()
        }
        guard store.call(id: callID)?.status == .unconfirmed else { return }
        log.event(.calls, "call.answered", ["call": CallTranscriber.shortID(callID), "answer": answer, "late": true])
        onAnswered?(callID)
        store.delete(callID)
    }

    /// The question's answer, from its toast.
    func answer(_ answer: CallAnswer, callID: UUID) {
        switch answer {
        case .keep: keep(callID: callID)
        case .discard: discard(callID: callID)
        case .never: never(callID: callID)
        }
    }

    /// Never for ...: the call is deleted, as with No, and its app (or, in a browser, its site) is never noticed again
    /// (`AppSettings.callExclusions`). Works on the live call and on one that ended unanswered.
    func never(callID: UUID) {
        let exclusion: CallExclusion?
        if let live, live.info.id == callID {
            exclusion = CallExclusion.of(live.info)
        } else if let call = store.call(id: callID), call.status == .unconfirmed {
            exclusion = CallExclusion.of(call)
        } else {
            return
        }
        if let exclusion {
            settings.excludeFromCalls(exclusion)
            Log.audio.info("Calls in \(exclusion.name, privacy: .public) are excluded from now on")
        }
        drop(callID: callID, answer: "never")
    }

    /// Start Call Recording: during a noticed call, keeps it; otherwise records the mic and everything the Mac plays.
    func startManual() {
        if live != nil { return keep() }
        guard let journal = store.journal else { return }
        let id = UUID()
        let info = CallInfo(id: id, appName: Self.manualName, startedAt: deps.now(), manual: true)
        var journalInfo = CallJournal.Info(id: id, startedAt: info.startedAt, appName: info.appName, manual: true,
                                           consent: .kept)
        journalInfo.muteKnown = false
        let recorder = CallRecorder(journal: journal, info: journalInfo, origin: deps.clock(),
                                    sources: deps.makeSources(.everythingButThisApp))
        let live = Live(recorder: recorder, info: info, app: nil, consent: .kept, confirmed: true, classified: true,
                        tapProcesses: [])
        self.live = live
        // The call the detector follows now, if any, is this recording's.
        ignored = watch.detector.followed?.app
        store.upsert(record(of: live, status: .recording))
        state = .recording(info)
        logEvent("call.manual", live)
    }

    /// Stop Call Recording: ends the live recording, kept and transcribed, or deleted. That call isn't recorded again.
    func stop(keep: Bool) {
        guard let live else { return }
        if let app = live.app ?? watch.detector.followed?.app { ignored = app }
        guard keep else {
            logEvent("call.answered", live, ["answer": "discard", "from": "menu"])
            return discardLive()
        }
        if live.consent != .kept { keepLive(how: "menu") }
        guard let kept = self.live else { return }
        end(kept, status: .transcribing)
    }

    /// The store deleted calls: one being recorded stops and goes.
    func removed(_ ids: [UUID]) {
        guard let live, ids.contains(live.info.id) else { return }
        if let app = live.app { ignored = app }
        live.recorder.discard()
        self.live = nil
        state = .idle
        notices?.dropped()
    }

    /// Returns once every ended call is in the store: tests.
    func waitForEndings() async {
        while let task = endings.values.first { await task.value }
    }

    // MARK: Events

    private func handle(_ events: [CallDetector.Event], at time: TimeInterval) {
        for event in events {
            switch event {
            case .suspected(let app, _):
                guard live == nil, mayRecord(app) else { continue }
                begin(app, at: time)
            case .dropped(let app, _):
                if ignored == app { ignored = nil }
                guard let live, live.app == app else { continue }
                logEvent("call.dropped", live, ["reason": "notACall"])
                if live.consent == .kept { end(live, status: .transcribing) } else { discardLive(ignore: false) }
            case .started(let call):
                if live == nil, mayRecord(call.app) { begin(call.app, at: time) }
                guard var live, live.app == call.app else { continue }
                live.confirmed = true
                self.live = live
                logEvent("call.started", live, ["classified": live.classified])
                if live.classified { confirm() }
            case .ended(let call):
                if ignored == call.app { ignored = nil }
                guard var live, live.app == call.app else { continue }
                live.info.mutes = intervals(call.mutes, origin: live.origin)
                self.live = live
                let mutes = live.info.mutes
                live.recorder.update { $0.mutes = mutes }
                switch live.consent {
                case .kept: end(live, status: .transcribing)
                case .asking:
                    logEvent("call.answered", live, ["answer": "unanswered"])
                    end(live, status: .unconfirmed)
                case .suspected:
                    logEvent("call.dropped", live, ["reason": "endedUnconfirmed"])
                    discardLive(ignore: false)
                }
            case .micReleased, .micBack:
                break
            }
        }
    }

    private func mayRecord(_ app: CallApp) -> Bool {
        settings.callRecording != .off && ignored != app && store.journal != nil && !CallDenylist.denies(app)
            && !settings.callExclusions.excludes(app)
    }

    private static func isBrowser(_ app: CallApp) -> Bool { CallAppKind.of(app.id) == .browser }

    /// Starts recording `app`'s call: its mic and a tap of all its processes.
    private func begin(_ app: CallApp, at time: TimeInterval) {
        guard let journal = store.journal else { return }
        let kind = CallAppKind.of(app.id)
        let info = CallInfo(id: UUID(), appName: deps.appName(app), bundleID: app.id, service: kind.service,
                            startedAt: deps.now(), muteKnown: kind.service?.releasesMicOnMute == true)
        var journalInfo = CallJournal.Info(id: info.id, startedAt: info.startedAt, appName: info.appName,
                                           bundleID: app.id, service: info.service, consent: .suspected)
        journalInfo.muteKnown = info.muteKnown
        let processes = watch.processes[app] ?? []
        let recorder = CallRecorder(journal: journal, info: journalInfo, origin: time,
                                    sources: deps.makeSources(.processes(processes)))
        // A browser waits for its call tab, unless its windows can't be read at all: then it's any app.
        let classified = !Self.isBrowser(app) || !deps.sensors.canReadWindows()
        let suspected = Live(recorder: recorder, info: info, app: app, consent: .suspected, classified: classified,
                             tapProcesses: processes)
        live = suspected
        state = .suspected(info)
        Log.audio.info("Recording a possible call in \(info.appName, privacy: .public)")
        logEvent("call.suspected", suspected, ["muteKnown": info.muteKnown])
    }

    /// The call is confirmed and known: ask about it, or keep it.
    private func confirm() {
        guard var live, live.consent == .suspected else { return }
        if settings.callRecording == .automatic {
            notices?.detected(title: live.info.title, at: lastTime)
            return keepLive(how: "automatic")
        }
        // The app was quit (or reinstalled) during this call, which the person kept: it goes on kept, and is joined
        // onto what was recorded before once it ends (`CallStore.adopt`).
        if let earlier = store.interruptedCall(continuedBy: live.info.bundleID, service: live.info.service,
                                               pageTitle: live.info.pageTitle, manual: live.info.manual,
                                               startedAt: live.info.startedAt) {
            logEvent("call.continues", live, ["earlier": CallTranscriber.shortID(earlier.id)])
            notices?.detected(title: live.info.title, at: lastTime)
            return keepLive(how: "continuation")
        }
        live.consent = .asking
        self.live = live
        live.recorder.update { $0.consent = .asking }
        state = .asking(live.info)
        notices?.confirmed(live.info.id, at: lastTime)
        logEvent("call.asked", live)
        onAsk?(live.info)
    }

    // MARK: Following

    /// The live call brought up to date from the detector and the window reads: mutes, a browser's tab, other tabs'
    /// sound, the app's processes for the tap.
    private func follow(at time: TimeInterval) {
        guard var live, let app = live.app else { return }
        let before = live
        if let followed = watch.detector.followed, followed.app == app {
            var mutes = followed.mutes
            if let since = followed.mutedSince { mutes.append(since...max(since, time)) }
            if followed.micReleaseIsMute, let since = followed.micReleasedAt { mutes.append(since...max(since, time)) }
            live.info.mutes = intervals(mutes, origin: live.origin)
            if let tab = followed.tab, Self.isBrowser(app) {
                if settings.callExclusions.excludes(service: tab.service, page: tab.page) {
                    Log.audio.info("Not recorded: the call's site is excluded")
                    logEvent("call.dropped", live, ["reason": "excluded"])
                    return discardLive()
                }
                // A tab using the mic, any site; or one titled like a call service (Safari and Firefox mark nothing).
                if tab.service != nil || tab.recording?.hasMic == true {
                    live.info.service = tab.service
                    live.info.pageTitle = tab.page
                    live.classified = true
                }
            }
        }
        if Self.isBrowser(app), (watch.lastRead?.windowCount ?? 0) > 0 { live.tabsRead = true }
        if !live.classified, time - live.origin >= Self.classifyWithin {
            guard !live.tabsRead else {
                Log.audio.info("Not a call: no tab in the browser uses the microphone")
                logEvent("call.dropped", live, ["reason": "noCallTab"])
                return discardLive()
            }
            // None of its windows could be read: the browser is taken as a whole, like any app.
            Log.audio.info("No browser window could be read: recording the whole browser")
            live.classified = true
        }
        live.info.muteKnown = live.info.service?.releasesMicOnMute == true || watch.muteEverKnown
        if Self.isBrowser(app), let read = watch.lastRead {
            if read.otherTabPlaysAudio, live.otherAudioSince == nil {
                live.otherAudioSince = time
            } else if !read.otherTabPlaysAudio, let since = live.otherAudioSince {
                live.otherAudio.append(CallInterval(start: max(0, since - live.origin), end: time - live.origin))
                live.otherAudioSince = nil
            }
        }
        let processes = watch.processes[app] ?? []
        if !processes.isEmpty, processes != live.tapProcesses {
            live.tapProcesses = processes
            live.recorder.retarget(processes)
        }
        self.live = live
        if live.consent != .suspected { notices?.observe(muteObservation(of: live), title: live.info.title, at: time) }
        guard live.info != before.info || live.otherAudio != before.otherAudio
                || live.otherAudioSince != before.otherAudioSince else { return }
        let info = live.info
        let other = otherAudio(of: live, at: time)
        live.recorder.update {
            $0.mutes = info.mutes
            $0.muteKnown = info.muteKnown
            $0.service = info.service
            $0.pageTitle = info.pageTitle
            $0.otherBrowserAudio = other
        }
        switch state {
        case .suspected: state = .suspected(info)
        case .asking: state = .asking(info)
        case .recording: state = .recording(info)
        case .idle, .ending: break
        }
        if live.confirmed, live.classified, !before.classified { confirm() }
    }

    // MARK: Ending

    /// The recording stops; its call goes to the store as `status` (`.transcribing` is transcribed then).
    private func end(_ live: Live, status: CallStatus) {
        self.live = nil
        state = .ending
        let fallback = journalInfo(of: live)
        let other = otherAudio(of: live, at: deps.clock())
        let id = live.info.id
        let endedAt = deps.now()
        if status != .unconfirmed { onAnswered?(id) }
        endings[id] = Task { [weak self] in
            guard let self else { return }
            var info = await live.recorder.finish() ?? fallback
            info.otherBrowserAudio = other
            info.mutes = live.info.mutes
            let record = await self.store.adopt(info, status: status, endedAt: endedAt)
            let tapProblem: String? = record.remoteProblem.map { $0 == CallStore.silentTapMessage ? "silent" : "other" }
            self.log.event(.calls, "call.ended", [
                "call": CallTranscriber.shortID(id), "status": status.rawValue,
                "joinedOnto": record.id == id ? nil : CallTranscriber.shortID(record.id),
                "seconds": record.duration, "mic": record.micFile == nil ? nil : record.micSeconds,
                "remote": record.remoteFile == nil ? nil : record.remoteSeconds,
                "mutes": info.mutes.count, "muteKnown": info.muteKnown, "tapProblem": tapProblem,
                "micProblem": info.micProblem == nil ? nil : true,
            ])
            self.notices?.ended(seconds: record.duration, transcribing: status == .transcribing, at: self.lastTime)
            // A continuation joined onto the call the app quit recording: that one is transcribed, whole.
            if status == .transcribing { self.transcriber.transcribe(record.id) }
            self.endings[id] = nil
            if self.state == .ending { self.state = .idle }
            Log.audio.info("Call recording ended (\(status.rawValue, privacy: .public))")
        }
    }

    /// The live recording and everything it recorded go; its call isn't recorded again (unless it was a suspicion
    /// that just dropped: then there's nothing to ignore).
    private func discardLive(ignore: Bool = true) {
        guard let live else { return }
        if ignore, let app = live.app { ignored = app }
        live.recorder.discard()
        self.live = nil
        state = .idle
        notices?.dropped()
        if store.call(id: live.info.id) != nil { store.delete(live.info.id) }
        onAnswered?(live.info.id)
    }

    // MARK: Helpers

    /// What can be seen of the live call's mute now, and how: Telegram's mic, the Mute button, Zoom's menu; a
    /// browser tab in the background; an app nobody knows the controls of.
    private func muteObservation(of live: Live) -> CallNotices.MuteObservation {
        guard let app = live.app else { return .init() }
        let kind = CallAppKind.of(app.id)
        let followed = watch.detector.followed.flatMap { $0.app == app ? $0 : nil }
        let service = live.info.service ?? followed?.service
        if let service, service.releasesMicOnMute {
            guard let followed else { return .init() }
            return .init(muted: followed.micReleasedAt != nil, source: .micRelease(service.name))
        }
        if kind == .other { return .init(unfollowable: true) }
        guard let read = watch.lastRead else { return .init() }
        switch read.read.state {
        case .muted: return .init(muted: true, source: kind == .zoomDesktop ? .zoomMenu : .button)
        case .live: return .init(muted: false, source: kind == .zoomDesktop ? .zoomMenu : .button)
        case .unknown(let reason):
            if reason == CallMuteReader.tabNotActive { return .init(hiddenTab: CallNotices.tabName(service)) }
            // A site no service is known for: nobody knows its controls.
            return .init(unfollowable: kind == .browser && service == nil && read.tab != nil)
        }
    }

    /// An event about the live call: its id, app and service (never a page's title), then `fields`.
    private func logEvent(_ name: String, _ live: Live, _ fields: KeyValuePairs<String, (any DiagnosticValue)?> = [:]) {
        var all = [DiagnosticField("call", CallTranscriber.shortID(live.info.id)),
                   DiagnosticField("app", live.info.manual ? "manual" : (live.info.bundleID ?? "unknown"))]
        if let service = live.info.service { all.append(DiagnosticField("service", service.rawValue)) }
        all += fields.compactMap { key, value in value.map { DiagnosticField(key, $0.diagnosticText) } }
        log.event(.calls, name, fields: all)
    }

    private func intervals(_ ranges: [ClosedRange<TimeInterval>], origin: TimeInterval) -> [CallInterval] {
        ranges.compactMap { range in
            let end = range.upperBound - origin
            guard end > 0 else { return nil }
            return CallInterval(start: max(0, range.lowerBound - origin), end: end)
        }
    }

    private func otherAudio(of live: Live, at time: TimeInterval) -> [CallInterval] {
        live.otherAudio + (live.otherAudioSince.map { [CallInterval(start: max(0, $0 - live.origin), end: time - live.origin)] } ?? [])
    }

    private func journalInfo(of live: Live) -> CallJournal.Info {
        var info = CallJournal.Info(id: live.info.id, startedAt: live.info.startedAt, appName: live.info.appName,
                                    bundleID: live.info.bundleID, service: live.info.service,
                                    pageTitle: live.info.pageTitle, manual: live.info.manual, consent: live.consent)
        info.mutes = live.info.mutes
        info.muteKnown = live.info.muteKnown
        return info
    }

    private func record(of live: Live, status: CallStatus) -> CallRecord {
        var record = journalInfo(of: live).record(status: status)
        record.otherBrowserAudio = live.otherAudio
        return record
    }
}
