import Foundation
import Testing
@testable import TranscribeThing

// Noticing calls from which apps use the mic and play sound (`CallApp`, `CallDetector`). The scenarios are a real
// `--audio-watch` log from this Mac: what each process did, looked at every 0.5 s.

@Suite struct CallDetectorTests {
    /// One process as the HAL shows it: its bundle id and when it had the mic and the speakers, as [on, off).
    private struct Process {
        var bundleID: String?
        var mic: [Range<Double>] = []
        var sound: [Range<Double>] = []

        func activity(at time: Double) -> CallDetector.Activity {
            CallDetector.Activity(mic: mic.contains { $0.contains(time) }, sound: sound.contains { $0.contains(time) })
        }
    }

    /// An event and the step that reported it.
    private struct Step: Equatable {
        var time: Double
        var event: CallDetector.Event
    }

    private static let telegram = CallApp(bundleID: "ru.keepcoder.Telegram")!
    private static let chrome = CallApp(bundleID: "com.google.Chrome")!
    private static let discord = CallApp(bundleID: "com.hnc.Discord")!

    /// Feeds the processes to `detector` every 0.5 s from `from` to `to`, at x.3 and x.8 like the log (or x.1 and
    /// x.6), with each of Chrome's window `reads` at its look. Times are tenths divided by ten, so they equal the
    /// literals they are compared with.
    private func run(_ processes: [Process], reads: [Double: CallDetector.Window] = [:], from: Double = 0.3,
                     to: Double, detector: inout CallDetector) -> [Step] {
        run(processes, from: from, to: to, detector: &detector) { time, _ in reads[time] }
    }

    /// The same, with Chrome's windows at each look in `strips` read the way the app reads them: the call tab picked
    /// by `BrowserTabs.callTab`, following the detector's call.
    private func run(_ processes: [Process], strips: [Double: [BrowserTabs.Window]], from: Double, to: Double,
                     detector: inout CallDetector) -> [Step] {
        run(processes, from: from, to: to, detector: &detector) { time, detector in
            strips[time].map { windows in
                CallDetector.Window(tab: BrowserTabs.callTab(in: windows, following: detector.following)
                    .map(CallDetector.Tab.init))
            }
        }
    }

    private func run(_ processes: [Process], from: Double, to: Double, detector: inout CallDetector,
                     read: (Double, CallDetector) -> CallDetector.Window?) -> [Step] {
        var steps: [Step] = []
        for tenth in stride(from: Int((from * 10).rounded()), through: Int((to * 10).rounded()), by: 5) {
            let time = Double(tenth) / 10
            let apps = CallApp.activity(processes.map { (CallApp(bundleID: $0.bundleID), $0.activity(at: time)) })
            let windows = read(time, detector).map { [Self.chrome: $0] } ?? [:]
            steps += detector.feed(apps, windows: windows, at: time).map { Step(time: time, event: $0) }
        }
        return steps
    }

    /// A read of Chrome finding the call in a tab titled `page` (that records, if `recording`), its Mute button
    /// showing `muted` and its Leave button `inCall`.
    private static func read(_ service: CallService?, _ page: String, recording: BrowserTabs.Recording? = nil,
                             muted: Bool? = nil, inCall: Bool? = nil) -> CallDetector.Window {
        CallDetector.Window(tab: CallDetector.Tab(service: service, page: page, recording: recording), muted: muted,
                            inCall: inCall)
    }

    /// A read of Chrome finding no tab that records or is titled like a call.
    private static let noCallTab = CallDetector.Window()

    private func run(_ processes: [Process], to: Double) -> [Step] {
        var detector = CallDetector()
        return run(processes, to: to, detector: &detector)
    }

    private func calls(_ steps: [Step]) -> [CallDetector.Call] {
        steps.compactMap { if case .ended(let call) = $0.event { call } else { nil } }
    }

    private func started(_ steps: [Step]) -> [CallDetector.Call] {
        steps.compactMap { if case .started(let call) = $0.event { call } else { nil } }
    }

    // MARK: Scenarios

    /// Recording a voice note holds the mic with nothing playing; listening back plays with no mic.
    @Test func aTelegramVoiceNoteIsNotACall() {
        let steps = run([Process(bundleID: "ru.keepcoder.Telegram", mic: [55.8..<66.8],
                                 sound: [70.3..<71.3, 73.3..<74.3, 76.3..<94.3, 96.3..<100.3])], to: 200)
        #expect(steps.isEmpty)
    }

    /// Ringing, picking up, muting (Telegram gives the mic back meanwhile), unmuting, hanging up.
    @Test func aTelegramCallWithAMute() throws {
        let telegram = Process(bundleID: "ru.keepcoder.Telegram", mic: [177.3..<208.8, 230.3..<235.3],
                               sound: [167.3..<235.3])
        var detector = CallDetector()
        var steps = run([telegram], from: 150.3, to: 290, detector: &detector)
        #expect(steps.map(\.event) == [
            .suspected(Self.telegram, at: 177.3),
            .started(CallDetector.Call(app: Self.telegram, startedAt: 177.3, lastAudioAt: 197.3)),
            .micReleased(Self.telegram, at: 208.8),
            .micBack(Self.telegram, at: 230.3),
        ])
        #expect(steps.map(\.time) == [177.3, 197.3, 210.3, 230.3], "a release counts once it has lasted 1.5 s")
        #expect(detector.call?.lastAudioAt == 235.3, "still the call while within the 60 s grace")

        steps = run([telegram], from: 290.3, to: 400, detector: &detector)
        let call = try #require(calls(steps).first)
        #expect(steps.count == 1 && steps[0].time == 295.3)
        #expect(call.app == Self.telegram && call.startedAt == 177.3 && call.lastAudioAt == 235.3)
        #expect(call.mutes == [208.8...230.3])
        #expect(!call.micReleased)
        #expect(detector.phase == .idle)
    }

    /// Whether the call's app has let go of the mic, for the recording to let go of it too: while Telegram is muted,
    /// once off for 1.5 s; again once it hangs up, until the call is over. Not while it has the mic, nor after.
    @Test func theCallAppLettingGoOfTheMicIsKnown() {
        let telegram = Process(bundleID: "ru.keepcoder.Telegram", mic: [177.3..<208.8, 230.3..<235.3],
                               sound: [167.3..<235.3])
        var detector = CallDetector()
        func letGo(from: Double, to: Double) -> Bool {
            _ = run([telegram], from: from, to: to, detector: &detector)
            return detector.callLetGoOfMic
        }
        #expect(!letGo(from: 150.3, to: 197.3) && detector.call != nil)
        #expect(!letGo(from: 197.8, to: 209.8), "off for 1 s: may be a device switching")
        #expect(letGo(from: 210.3, to: 210.3))
        #expect(letGo(from: 210.8, to: 229.8))
        #expect(!letGo(from: 230.3, to: 230.3), "taken again at the first look that sees it")
        #expect(!letGo(from: 230.8, to: 236.3))
        #expect(letGo(from: 236.8, to: 236.8), "hung up: mic and sound off, the call not over yet")
        #expect(letGo(from: 237.3, to: 290.3))
        #expect(!letGo(from: 290.8, to: 300) && detector.call == nil)

        // Meet keeps the mic while muted by its button: never let go.
        var meet = CallDetector()
        let chrome = Process(bundleID: "com.google.Chrome.helper", mic: [10.3..<100.3], sound: [10.3..<100.3])
        let reads = Dictionary(uniqueKeysWithValues: stride(from: 403, through: 903, by: 10).map {
            (Double($0) / 10, Self.read(.meet, "Meet – abc-defg-hij", recording: .cameraAndMic, muted: true))
        })
        var always = true
        for tenth in stride(from: 3, through: 995, by: 5) {
            let time = Double(tenth) / 10
            _ = run([chrome], reads: reads, from: time, to: time, detector: &meet)
            if meet.call != nil, meet.callLetGoOfMic { always = false }
        }
        #expect(always)
        #expect(meet.call?.mutedSince != nil, "muted by its button all along")
    }

    /// Meet in Chrome keeps the mic while muted, so no mute shows; its leave chime plays after the mic closes and
    /// is neither a mute nor a second call. Chrome played a video earlier with no mic.
    @Test func aMeetCallInChrome() throws {
        let helper = Process(bundleID: "com.google.Chrome.helper", mic: [259.7..<300.3],
                             sound: [100.3..<200.3, 258.3..<300.3, 300.7..<302.2])
        let steps = run([helper], to: 500)
        #expect(started(steps).count == 1)
        let call = try #require(calls(steps).first)
        #expect(calls(steps).count == 1)
        #expect(call.app == Self.chrome && call.startedAt == 259.8 && call.lastAudioAt == 302.3)
        #expect(call.mutes.isEmpty, "the mic closing as the chime plays is leaving, not muting")
        #expect(steps.filter { if case .suspected = $0.event { true } else { false } }.count == 1)
    }

    /// Discord plays through one helper and records and plays through its renderer: one app, one call.
    @Test func aDiscordCallAcrossTwoHelpers() throws {
        let steps = run([
            Process(bundleID: "com.hnc.Discord.helper", sound: [307.2..<322.3, 331.8..<335.3]),
            Process(bundleID: "com.hnc.Discord.helper.Renderer", mic: [308.3..<331.8], sound: [308.3..<331.8]),
        ], to: 500)
        #expect(started(steps).count == 1)
        let call = try #require(calls(steps).first)
        #expect(calls(steps).count == 1)
        #expect(call.app == Self.discord && call.startedAt == 308.3 && call.lastAudioAt == 335.3)
        #expect(call.mutes.isEmpty)
    }

    @Test func systemSoundsAndOurOwnDictationAreIgnored() {
        let steps = run([
            Process(bundleID: nil, mic: [10.3..<60.3], sound: [10.3..<60.3]),
            Process(bundleID: "com.apple.systemsoundserverd", sound: [70.3..<73.3]),
            Process(bundleID: "dev.transcribe-thing.app", mic: [80.3..<130.3], sound: [80.3..<130.3]),
        ], to: 300)
        #expect(steps.isEmpty)
    }

    @Test func chromePlayingWithoutAMicIsNothing() {
        #expect(run([Process(bundleID: "com.google.Chrome.helper", sound: [0.3..<600.3])], to: 700).isEmpty)
    }

    // MARK: Rules

    /// A second or so without the mic or the sound changes nothing, before the call or during it.
    @Test func briefFlickersAreSmoothedOver() throws {
        let steps = run([Process(bundleID: "ru.keepcoder.Telegram", mic: [10.3..<20.3, 21.3..<50.3, 51.3..<80.3],
                                 sound: [10.3..<15.3, 16.3..<80.3])], to: 200)
        #expect(started(steps).map(\.startedAt) == [10.3], "confirmed 20 s after it began, despite the gaps")
        #expect(steps.allSatisfy { if case .micReleased = $0.event { false } else { true } })
        #expect(try #require(calls(steps).first).mutes.isEmpty)
    }

    /// Mic and sound together for less than `confirmAfter`: suspected, then dropped.
    @Test func aShortOverlapIsDropped() {
        let steps = run([Process(bundleID: "ru.keepcoder.Telegram", mic: [10.3..<25.3], sound: [10.3..<40.3])], to: 100)
        #expect(steps.map(\.event) == [.suspected(Self.telegram, at: 10.3), .dropped(Self.telegram, at: 25.3)])
    }

    /// Silence shorter than `endAfter` is a pause; longer, and the next one is a new call.
    @Test func aPauseKeepsTheCallAndALongSilenceEndsIt() {
        let paused = run([Process(bundleID: "ru.keepcoder.Telegram", mic: [10.3..<40.3, 80.3..<120.3],
                                  sound: [10.3..<40.3, 80.3..<120.3])], to: 300)
        #expect(started(paused).count == 1 && calls(paused).map(\.lastAudioAt) == [120.3])

        let apart = run([Process(bundleID: "ru.keepcoder.Telegram", mic: [10.3..<40.3, 110.3..<140.3],
                                 sound: [10.3..<40.3, 110.3..<140.3])], to: 300)
        #expect(calls(apart).map { $0.startedAt...$0.lastAudioAt } == [10.3...40.3, 110.3...140.3])
    }

    @Test func stoppingEndsTheCallAtOnce() throws {
        var detector = CallDetector()
        _ = run([Process(bundleID: "ru.keepcoder.Telegram", mic: [10.3..<60.3], sound: [10.3..<60.3])], to: 45,
                detector: &detector)
        let events = detector.stop(at: 45.2)
        #expect(events == [.ended(CallDetector.Call(app: Self.telegram, startedAt: 10.3, lastAudioAt: 45.2))])
        #expect(detector.phase == .idle)
    }

    /// While a mute is open, stopping keeps it to the end.
    @Test func stoppingWhileMutedKeepsTheMute() throws {
        var detector = CallDetector()
        _ = run([Process(bundleID: "ru.keepcoder.Telegram", mic: [10.3..<40.3], sound: [10.3..<60.3])], to: 45,
                detector: &detector)
        #expect(detector.call?.micReleased == true)
        let call = try #require(calls(detector.stop(at: 45.2).map { Step(time: 45.2, event: $0) }).first)
        #expect(call.mutes == [40.3...45.2])
    }

    /// Discord's call overlaps Telegram's: Telegram's is followed until it goes silent, then Discord's takes over
    /// from there, without waiting out Telegram's 60 s.
    @Test func theFirstOfTwoCallsIsFollowedThenTheOtherTakesOver() {
        let steps = run([
            Process(bundleID: "com.hnc.Discord.helper.Renderer", mic: [20.3..<130.3], sound: [20.3..<130.3]),
            Process(bundleID: "ru.keepcoder.Telegram", mic: [10.3..<80.3], sound: [10.3..<80.3]),
        ], to: 300)
        #expect(started(steps).map(\.app) == [Self.telegram, Self.discord])
        #expect(calls(steps).map { $0.startedAt...$0.lastAudioAt } == [10.3...80.3, 80.3...130.3])
        #expect(steps.filter { $0.time == 100.3 }.map(\.event) == [
            .ended(CallDetector.Call(app: Self.telegram, startedAt: 10.3, lastAudioAt: 80.3)),
            .started(CallDetector.Call(app: Self.discord, startedAt: 80.3, lastAudioAt: 100.3)),
        ], "20 s after Telegram went silent")
    }

    // MARK: Browser tabs and taking over

    /// The log's Chrome: a Meet call muted twice, left; Discord's voice channel joined from another tab and left;
    /// a Zoom meeting joined, muted once, left as the Zoom tab closed. The HAL sees one Chrome with the mic on three
    /// times and sound from 546.6 to 686.1 without a break; the tabs say whose each is. Discord's stay was 16 s, so
    /// calls are confirmed after 10 s here.
    @Test func meetThenDiscordThenZoomInOneChromeAreThreeCalls() throws {
        let chrome = Process(bundleID: "com.google.Chrome.helper",
                             mic: [512.6..<539.1, 554.6..<556.6, 557.6..<570.1, 662.6..<663.1, 663.6..<685.1],
                             sound: [511.1..<541.1, 546.6..<686.1])
        let meet = "Meet – gkz-omip-mob", discord = "Discord | #основной | Сервер package.json"
        let zoom = "Zoom Meeting Matvey Litvin"
        let reads: [Double: CallDetector.Window] = [
            513.6: Self.read(.meet, meet, recording: .cameraAndMic, muted: false, inCall: false),
            518.6: Self.read(.meet, meet, recording: .mic, muted: true, inCall: false),
            520.1: Self.read(.meet, meet, recording: .mic, muted: false, inCall: false),
            521.6: Self.read(.meet, meet, recording: .mic, muted: false, inCall: true),
            530.1: Self.read(.meet, meet, recording: .mic, muted: true, inCall: true),
            532.6: Self.read(.meet, meet, recording: .mic),  // switched to another tab: no buttons to read
            535.6: Self.read(.meet, meet, recording: .mic, muted: true, inCall: true),
            // Left: the Meet tab is still there, but no longer records.
            541.1: Self.read(.meet, meet),
            549.1: Self.read(.discord, "Discord"),
            551.6: Self.read(.discord, "Discord | Друзья"),
            // Joining the voice channel; the Meet tab shows "Permission requested" meanwhile.
            556.6: Self.read(.discord, discord),
            558.1: Self.read(.discord, discord, recording: .mic, muted: false, inCall: true),
            563.6: Self.read(.discord, discord, recording: .mic),
            567.6: Self.read(.discord, discord, recording: .mic, muted: false, inCall: true),
            572.1: Self.read(.discord, discord, muted: false, inCall: false),
            589.6: Self.read(.zoom, "Войти в систему | Zoom"),
            649.6: Self.read(.zoom, "Zoom"),
            // "Permission requested" takes the recording mark's place in Zoom's title, so it's found by its title.
            656.6: Self.read(.zoom, zoom, inCall: true),
            665.6: Self.read(.zoom, zoom, inCall: true),
            668.6: Self.read(.zoom, zoom, muted: false, inCall: true),
            673.6: Self.read(.zoom, zoom, recording: .mic),
            676.6: Self.read(.zoom, zoom, muted: true, inCall: true),
            683.1: Self.read(.zoom, zoom, muted: false, inCall: true),
            // The Zoom tab closed: the Discord tab in front is the call tab now.
            685.6: Self.read(.discord, discord),
        ]
        var detector = CallDetector(settings: CallDetector.Settings(confirmAfter: 10))
        let steps = run([chrome], reads: reads, from: 500.1, to: 800, detector: &detector)

        let ended = calls(steps)
        #expect(ended.map { $0.tab?.service } == [.meet, .discord, .zoom])
        #expect(ended.map { $0.startedAt...$0.lastAudioAt } == [512.6...541.1, 554.6...572.1, 662.6...685.6])
        #expect(ended.map(\.mutes) == [[518.6...520.1, 530.1...539.1], [], [676.6...683.1]],
                "Meet's and Zoom's mutes from their buttons, the second Meet one until leaving; none from leaving")
        #expect(started(steps).map { $0.tab?.page } == [meet, discord, zoom])
        #expect(steps.filter { if case .micBack = $0.event { true } else { false } }.isEmpty,
                "the mic coming back for Discord and Zoom is their own call, not Meet's")
        #expect(steps.filter { $0.time == 541.1 }.map(\.event) == [.ended(ended[0])], "Meet left: over at once")
        #expect(steps.filter { $0.time == 685.6 }.map(\.event) == [.ended(ended[2])], "Zoom's tab gone: over at once")
        #expect(detector.phase == .idle)

        // With the usual 20 s, Discord's 16 s in the voice channel stays a suspicion, and still no mute.
        var usual = CallDetector()
        let usualSteps = run([chrome], reads: reads, from: 500.1, to: 800, detector: &usual)
        #expect(calls(usualSteps).map { $0.tab?.service } == [.meet, .zoom])
        #expect(usualSteps.map(\.event).contains(.dropped(Self.chrome, at: 570.1)))
        #expect(calls(usualSteps).map(\.mutes) == [[518.6...520.1, 530.1...539.1], [676.6...683.1]])
    }

    /// The log's Chrome again: a Telemost call muted twice and hung up; then a Telegram Web call, muted by releasing
    /// the mic (Telegram's way), hung up, its tab closed. Telegram's call was short, so calls are confirmed after
    /// 5 s here.
    @Test func aTelemostCallThenATelegramWebCallMutedByReleasingTheMic() throws {
        let chrome = Process(bundleID: "com.google.Chrome.helper", mic: [907.1..<929.6, 958.1..<965.6, 970.6..<974.1],
                             sound: [904.1..<904.6, 905.6..<931.1, 949.6..<974.1, 974.6..<975.6])
        let telemost = "Идёт звонок · Яндекс Телемост"
        let reads: [Double: CallDetector.Window] = [
            907.6: Self.read(.telemost, telemost, recording: .cameraAndMic, muted: false, inCall: true),
            911.6: Self.read(.telemost, telemost, recording: .cameraAndMic, muted: true, inCall: true),
            918.6: Self.read(.telemost, telemost, recording: .cameraAndMic, muted: false, inCall: true),
            924.6: Self.read(.telemost, telemost, recording: .cameraAndMic, muted: true, inCall: true),
            926.1: Self.read(.telemost, telemost, recording: .cameraAndMic),
            929.1: Self.read(.telemost, telemost, recording: .cameraAndMic, muted: true, inCall: true),
            // Hung up: the page is Telemost's home, no Leave button.
            930.1: Self.read(.telemost, "Яндекс Телемост", inCall: false),
            933.1: Self.noCallTab,
            936.6: Self.read(.telegram, "Telegram Web"),
            959.6: Self.read(.telegram, "Telegram Web", recording: .mic, inCall: true),
            // Muted: Telegram released the mic, so the tab no longer records; it's in the background meanwhile.
            968.6: Self.read(.telegram, "Telegram Web"),
            971.6: Self.read(.telegram, "Telegram Web", recording: .mic, inCall: true),
            975.1: Self.read(.telegram, "Telegram Web"),
            978.1: Self.noCallTab,
        ]
        var detector = CallDetector(settings: CallDetector.Settings(confirmAfter: 5))
        let steps = run([chrome], reads: reads, from: 900.1, to: 1100, detector: &detector)

        let ended = calls(steps)
        #expect(ended.map { $0.tab?.service } == [.telemost, .telegram])
        #expect(ended.map { $0.startedAt...$0.lastAudioAt } == [907.1...931.1, 958.1...975.6])
        #expect(ended.map(\.mutes) == [[911.6...918.6, 924.6...929.6], [965.6...970.6]])
        #expect(steps.filter { $0.time == 931.1 }.map(\.event) == [.micReleased(Self.chrome, at: 929.6), .ended(ended[0])],
                "Telemost hung up: its tab stopped recording and its Leave button went")
        #expect(steps.filter { $0.time > 964 }.map(\.event) == [
            .micReleased(Self.chrome, at: 965.6), .micBack(Self.chrome, at: 970.6),
            .micReleased(Self.chrome, at: 974.1), .ended(ended[1]),
        ])
        #expect(steps.last?.time == 978.1, "over as the tab went, without waiting 60 s; the last release was hanging up")
    }

    /// Chrome's Telegram Web call from the log, its tab left open, so it waits out its 60 s; meanwhile the Telegram
    /// app makes a call. The app's real call had mic and sound together for 4.5 s, not enough to be one; a longer
    /// one takes over, ending Chrome's at its last audio.
    @Test func aCallInAnotherAppTakesOverFromOneWaitingToEnd() throws {
        let chrome = Process(bundleID: "com.google.Chrome.helper", mic: [958.1..<965.6, 970.6..<974.1],
                             sound: [949.6..<974.1, 974.6..<975.6])
        let reads: [Double: CallDetector.Window] = [
            959.6: Self.read(.telegram, "Telegram Web", recording: .mic, inCall: true),
            968.6: Self.read(.telegram, "Telegram Web"),
            971.6: Self.read(.telegram, "Telegram Web", recording: .mic, inCall: true),
            975.1: Self.read(.telegram, "Telegram Web"),
        ]
        func detector() -> CallDetector {
            var detector = CallDetector(settings: CallDetector.Settings(confirmAfter: 5))
            _ = run([chrome], reads: reads, from: 950.1, to: 980, detector: &detector)
            #expect(detector.call?.app == Self.chrome && detector.call?.lastAudioAt == 975.6)
            detector.settings.confirmAfter = 20
            return detector
        }

        var real = detector()
        let telegramApp = Process(bundleID: "ru.keepcoder.Telegram", mic: [988.6..<993.1, 997.6..<999.1],
                                  sound: [981.1..<999.1])
        let realSteps = run([chrome, telegramApp], from: 980.1, to: 1100, detector: &real)
        let waited = try #require(calls(realSteps).first)
        #expect(realSteps.map(\.event) == [
            .suspected(Self.telegram, at: 988.6), .dropped(Self.telegram, at: 993.1),
            .suspected(Self.telegram, at: 997.6), .dropped(Self.telegram, at: 999.1), .ended(waited),
        ])
        #expect(realSteps.last?.time == 1035.6 && calls(realSteps).first?.lastAudioAt == 975.6)

        var longer = detector()
        let longerCall = Process(bundleID: "ru.keepcoder.Telegram", mic: [988.6..<1030.1], sound: [981.1..<1031.1])
        let steps = run([chrome, longerCall], from: 980.1, to: 1100, detector: &longer)
        let chromeCall = try #require(calls(steps).first)
        #expect(chromeCall.app == Self.chrome && chromeCall.startedAt == 958.1 && chromeCall.lastAudioAt == 975.6)
        #expect(chromeCall.mutes == [965.6...970.6], "the release as it hung up isn't a mute")
        #expect(steps.filter { $0.time == 1008.6 }.map(\.event) == [
            .ended(chromeCall), .started(CallDetector.Call(app: Self.telegram, startedAt: 988.6, lastAudioAt: 1008.6)),
        ])
        #expect(calls(steps).map(\.app) == [Self.chrome, Self.telegram])
        #expect(calls(steps).last.map { $0.startedAt...$0.lastAudioAt } == 988.6...1031.1)
    }

    /// While the mic is on and no tab says it records, a tab of another service titled like a call (the one you
    /// switched to) doesn't end the call; one that records does.
    @Test func onlyARecordingTabTakesTheCallFromAnotherWhileTheMicIsOn() throws {
        let chrome = Process(bundleID: "com.google.Chrome.helper", mic: [10.1..<100.1], sound: [10.1..<100.1])
        let reads: [Double: CallDetector.Window] = [
            11.1: Self.read(.meet, "Meet – abc-defg-hij", recording: .mic, muted: false),
            40.1: Self.read(.discord, "Discord | Friends", muted: true),
            50.1: Self.read(.zoom, "Zoom Meeting", recording: .mic),
        ]
        var detector = CallDetector()
        let steps = run([chrome], reads: reads, from: 10.1, to: 200, detector: &detector)
        let meet = try #require(calls(steps).first)
        #expect(meet.tab?.service == .meet && meet.startedAt == 10.1 && meet.lastAudioAt == 50.1)
        #expect(meet.mutes.isEmpty, "the Discord tab's Mute button isn't Meet's")
        #expect(steps.filter { $0.time == 50.1 }.map(\.event) == [.ended(meet), .suspected(Self.chrome, at: 50.1)])
        #expect(started(steps).map { $0.tab?.service } == [.meet, .zoom])
        #expect(calls(steps).last.map { $0.startedAt...$0.lastAudioAt } == 50.1...100.1)
    }

    /// Discord retitles its tab as you move around it mid-call: still the one call. Muted on its button, it stays
    /// muted through a read that can't see the button (a background tab) until one shows it live.
    @Test func theSameServicesTabKeepsTheCallWhateverItsTitleSays() throws {
        let chrome = Process(bundleID: "com.google.Chrome.helper", mic: [10.1..<100.1], sound: [10.1..<102.1])
        let reads: [Double: CallDetector.Window] = [
            11.1: Self.read(.discord, "Discord | #general | Server", recording: .mic, muted: false, inCall: true),
            30.1: Self.read(.discord, "Discord | #general | Server", recording: .mic, muted: true, inCall: true),
            35.1: Self.read(.discord, "Discord | Friends", recording: .mic),
            40.1: Self.read(.discord, "Discord | Friends", muted: false, inCall: true),
        ]
        var detector = CallDetector()
        let steps = run([chrome], reads: reads, from: 10.1, to: 200, detector: &detector)
        let call = try #require(calls(steps).first)
        #expect(calls(steps).count == 1 && call.tab?.page == "Discord | Friends")
        #expect(call.mutes == [30.1...40.1])
        #expect(call.lastAudioAt == 102.1, "the leave chime after Discord gives the mic back is still the call's")
    }

    /// A read of Chrome with one window whose only tab is titled `title` as Chrome shows it, found the way the
    /// reader finds it (`BrowserTabs.callTab`).
    private static func tabRead(_ title: String, muted: Bool? = nil, inCall: Bool? = nil) -> CallDetector.Window {
        let windows = [BrowserTabs.Window(title: nil, tabs: [BrowserTabs.Tab(title: title, selected: true)])]
        return CallDetector.Window(tab: BrowserTabs.callTab(in: windows).map(CallDetector.Tab.init), muted: muted,
                                   inCall: inCall)
    }

    /// The log of 2026-10-12: a Slack huddle in Chrome, the person muted all along, switching channels as it went.
    /// A tab-renaming extension adds " [Main] 🏠" to Slack's titles. It was split into a call per channel, its mic
    /// recorded while muted; it's one call of 21 minutes, muted from its first second.
    @Test func aSlackHuddleThroughChannelSwitchesIsOneCallMutedThroughout() throws {
        let chrome = Process(bundleID: "com.google.Chrome.helper", mic: [24.8..<1300.3], sound: [24.8..<1300.3])
        let mark = " - Microphone recording"
        let reads: [Double: CallDetector.Window] = [
            25.3: Self.tabRead("Huddles - V-Soft - Slack" + mark, muted: true, inCall: true),
            42.3: Self.tabRead("general (Channel) - V-Soft - Slack [Main] 🏠" + mark, muted: true, inCall: true),
            300.3: Self.tabRead("(1) general (Channel) - V-Soft - Slack [Main] 🏠" + mark, muted: true),
            934.8: Self.tabRead("Jira (DM) - V-Soft - Slack [Main] 🏠" + mark, muted: true, inCall: true),
            1023.3: Self.tabRead("Matvey Litvin (DM) - V-Soft - Slack [Main] 🏠" + mark, muted: true, inCall: true),
        ]
        #expect(reads.values.allSatisfy { $0.tab?.service == .slack && $0.tab?.key == "slack" })
        var detector = CallDetector()
        let steps = run([chrome], reads: reads, from: 0.3, to: 1500, detector: &detector)
        let call = try #require(calls(steps).first)
        #expect(steps.map(\.event) == [.suspected(Self.chrome, at: 24.8), .started(try #require(started(steps).first)),
                                       .ended(call)])
        #expect(call.startedAt == 24.8 && call.lastAudioAt == 1300.3)
        #expect(call.tab?.service == .slack)
        #expect(call.mutes == [24.8...1300.3], "muted at the first read, a moment after it began: muted from its start")

        // Had Slack not been recognized, the retitled tab would still be one call.
        let unknown: [Double: CallDetector.Window] = [
            25.3: Self.read(nil, "general (Channel) - V-Soft", recording: .mic),
            300.3: Self.read(nil, "Jira (DM) - V-Soft", recording: .mic),
            934.8: Self.read(nil, "Matvey Litvin (DM) - V-Soft", recording: .mic),
        ]
        var other = CallDetector()
        let otherSteps = run([chrome], reads: unknown, from: 0.3, to: 1500, detector: &other)
        #expect(calls(otherSteps).map { $0.startedAt...$0.lastAudioAt } == [24.8...1300.3])
        #expect(calls(otherSteps).first?.tab?.page == "Matvey Litvin (DM) - V-Soft", "the detector follows the latest")
    }

    /// While the mic stays on, a recording tab with another title is the same call unless it can't be: another
    /// known service, another Meet meeting, a tab that recorded beside the call's, or the mic off in between.
    @Test func aRetitledTabIsTheSameCallOnlyWhileTheMicStaysOn() throws {
        func pages(_ mic: [Range<Double>], _ reads: [Double: CallDetector.Window]) -> [[String?]] {
            var detector = CallDetector()
            let steps = run([Process(bundleID: "com.google.Chrome.helper", mic: mic, sound: [10.1..<150.1])],
                            reads: reads, from: 10.1, to: 300, detector: &detector)
            return calls(steps).map { [$0.tab?.page, $0.tab?.service?.rawValue] }
        }
        let a = Self.read(nil, "Call A", recording: .mic), b = Self.read(nil, "Call B", recording: .mic)
        #expect(pages([10.1..<150.1], [11.1: a, 57.1: b]) == [["Call B", nil]])
        #expect(pages([10.1..<50.1, 51.1..<150.1], [11.1: a, 57.1: b]) == [["Call B", nil]], "a 1 s gap is a flicker")
        #expect(pages([10.1..<50.1, 55.1..<150.1], [11.1: a, 57.1: b]) == [["Call A", nil], ["Call B", nil]],
                "the mic off for 5 s before the new tab records: a new call")

        // Another tab recorded the mic beside the call's: once the call's stops, the other's is its own call.
        var beside = a
        beside.tab?.othersRecordMic = true
        #expect(pages([10.1..<150.1], [11.1: beside, 57.1: b]) == [["Call A", nil], ["Call B", nil]])

        // Known services: another one, or another Meet meeting, is another call; Meet's title around the same code,
        // or a title that doesn't say the service, is the same one.
        let meet = Self.read(.meet, "Meet – abc-defg-hij", recording: .mic)
        #expect(pages([10.1..<150.1], [11.1: meet, 57.1: Self.read(.meet, "Meet – xyz-abcd-efg", recording: .mic)]).count == 2)
        #expect(pages([10.1..<150.1], [11.1: meet, 57.1: Self.read(.meet, "Meet – abc-defg-hij 🎧", recording: .mic)]).count == 1)
        #expect(pages([10.1..<150.1], [11.1: meet, 57.1: Self.read(.zoom, "Zoom Meeting", recording: .mic)]).count == 2)
        #expect(pages([10.1..<150.1], [11.1: Self.read(.slack, "Huddles - V-Soft - Slack", recording: .mic),
                                       57.1: Self.read(nil, "Loading…", recording: .mic)]) == [["Loading…", "slack"]])
        #expect(pages([10.1..<150.1], [11.1: a, 57.1: Self.read(.slack, "Huddles - Acme - Slack", recording: .mic)])
            == [["Huddles - Acme - Slack", "slack"]], "a page found to be a service is still its call")
    }

    /// A read of Chrome finding the call in tab `id` titled `page`, the tabs `others` recording the mic beside it.
    private static func read(_ service: CallService?, _ page: String, tab id: Int, recording: BrowserTabs.Recording? = .mic,
                             others: [Int] = [], muted: Bool? = nil) -> CallDetector.Window {
        CallDetector.Window(tab: CallDetector.Tab(service: service, page: page, recording: recording,
                                                  id: BrowserTabs.TabID(id), otherMicTabs: others.map(BrowserTabs.TabID.init)),
                            muted: muted)
    }

    /// The case of 2026-10-13: a Telemost call in one Chrome tab ends at 300 s while another Telemost call has
    /// begun in a background tab at 290 s. Both tabs are titled "Идёт звонок · Яндекс Телемост", and the second
    /// took the mic before the first let it go, so the mic never went off. They were one call; they're two, the
    /// first ending where its tab was last seen, the second beginning where its tab was first seen recording.
    @Test func twoTelemostCallsInTwoTabsAreTwoCallsThoughTheMicNeverWentOff() throws {
        let chrome = Process(bundleID: "com.google.Chrome.helper", mic: [0.3..<600.3], sound: [0.3..<600.3])
        let telemost = "Идёт звонок · Яндекс Телемост"
        var reads: [Double: CallDetector.Window] = [:]
        // Read every 12 s here (every 1 to 3 s in the app), in tenths so the times equal the steps'.
        for tenth in stride(from: 13, through: 2893, by: 120) {
            reads[Double(tenth) / 10] = Self.read(.telemost, telemost, tab: 1, recording: .cameraAndMic)
        }
        reads[290.3] = Self.read(.telemost, telemost, tab: 1, recording: .cameraAndMic, others: [2])
        reads[293.3] = Self.read(.telemost, telemost, tab: 1, recording: .cameraAndMic, others: [2])
        reads[299.3] = Self.read(.telemost, telemost, tab: 1, recording: .cameraAndMic, others: [2])
        for tenth in stride(from: 3023, through: 5993, by: 120) {
            reads[Double(tenth) / 10] = Self.read(.telemost, telemost, tab: 2)
        }
        var detector = CallDetector()
        let steps = run([chrome], reads: reads, from: 0.3, to: 700, detector: &detector)

        let ended = calls(steps)
        #expect(ended.map { $0.startedAt...$0.lastAudioAt } == [0.3...299.3, 290.3...600.3])
        #expect(ended.map { $0.tab?.id } == [BrowserTabs.TabID(1), BrowserTabs.TabID(2)])
        #expect(ended.map { $0.tab?.page } == [telemost, telemost])
        let second = try #require(started(steps).last)
        #expect(steps.filter { $0.time == 302.3 }.map(\.event) == [.ended(ended[0]), .suspected(Self.chrome, at: 290.3)])
        #expect(steps.filter { $0.time == 310.3 }.map(\.event) == [.started(second)], "confirmed 20 s after it began")

        // Without ids (Safari, or tabs read without their strip) the titles can't tell them apart: one call, as before.
        var titles = reads
        for (time, read) in reads {
            titles[time] = Self.read(.telemost, telemost, recording: read.tab?.recording)
        }
        var old = CallDetector()
        let oneCall = calls(run([chrome], reads: titles, from: 0.3, to: 700, detector: &old))
        #expect(oneCall.map { $0.startedAt...$0.lastAudioAt } == [0.3...600.3])
    }

    /// Slack retitles its tab with every channel you open mid-huddle: the same tab is the same call, as by its
    /// title. A Meet tab that joins another meeting is another call, and so is a Meet meeting in another tab.
    @Test func theSameTabIsTheSameCallWhateverItsTitleUnlessItsAnotherMeeting() throws {
        func spans(_ reads: [Double: CallDetector.Window]) -> [ClosedRange<Double>] {
            var detector = CallDetector()
            let steps = run([Process(bundleID: "com.google.Chrome.helper", mic: [10.1..<150.1], sound: [10.1..<150.1])],
                            reads: reads, from: 10.1, to: 300, detector: &detector)
            return calls(steps).map { $0.startedAt...$0.lastAudioAt }
        }
        #expect(spans([
            11.1: Self.read(.slack, "general (Channel) - V-Soft - Slack", tab: 7),
            40.1: Self.read(.slack, "Jira (DM) - V-Soft - Slack", tab: 7, others: [8]),
            70.1: Self.read(nil, "Loading…", tab: 7),
            100.1: Self.read(.slack, "Matvey Litvin (DM) - V-Soft - Slack", tab: 7),
        ]) == [10.1...150.1], "another tab recording beside it changes nothing while the call's tab goes on")

        let meet = Self.read(.meet, "Meet – abc-defg-hij", tab: 3)
        #expect(spans([11.1: meet, 57.1: Self.read(.meet, "Meet – xyz-abcd-efg", tab: 3)]) == [10.1...57.1, 57.1...150.1])
        #expect(spans([11.1: meet, 57.1: Self.read(.meet, "Meet – abc-defg-hij 🎧", tab: 3)]) == [10.1...150.1])
        #expect(spans([11.1: meet, 57.1: Self.read(.meet, "Meet – xyz-abcd-efg", tab: 4)]) == [10.1...52.1, 57.1...150.1],
                "another tab: the second call from now, never seen before; the first ended where its tab was last seen, but reads this far apart say they stalled: 5 s back at most")
    }

    /// Two tabs record the mic at once: the call followed stays its tab's; once that tab stops, the other's call
    /// begins where it was first seen, whatever the mic did. Without ids, it begins when it takes over.
    @Test func whenTheCallsTabStopsTheOtherRecordingTabIsANewCallFromWhenItWasSeen() throws {
        let chrome = Process(bundleID: "com.google.Chrome.helper", mic: [10.1..<200.1], sound: [10.1..<200.1])
        let reads: [Double: CallDetector.Window] = [
            11.1: Self.read(nil, "Call A", tab: 1),
            50.1: Self.read(nil, "Call A", tab: 1, others: [2]),
            80.1: Self.read(nil, "Call A", tab: 1, others: [2]),
            87.1: Self.read(nil, "Call A", tab: 1, others: [2]),
            // Tab 1 still there, no longer recording: the reader picks the tab that records.
            90.1: Self.read(nil, "Call B", tab: 2),
        ]
        var detector = CallDetector()
        let steps = run([chrome], reads: reads, from: 10.1, to: 400, detector: &detector)
        let ended = calls(steps)
        #expect(ended.map { $0.startedAt...$0.lastAudioAt } == [10.1...87.1, 50.1...200.1])
        #expect(ended.map { $0.tab?.page } == ["Call A", "Call B"])
        #expect(steps.filter { $0.time == 90.1 }.map(\.event)
            == [.ended(ended[0]), .suspected(Self.chrome, at: 50.1), .started(try #require(started(steps).last))],
                "it has had mic and sound for 40 s: a call at once")

        // A tab the call's never saw beside it: from when it takes over.
        let unseen: [Double: CallDetector.Window] = [11.1: Self.read(nil, "Call A", tab: 1), 90.1: Self.read(nil, "Call B", tab: 2)]
        var other = CallDetector()
        #expect(calls(run([chrome], reads: unseen, from: 10.1, to: 400, detector: &other)).map { $0.startedAt...$0.lastAudioAt }
            == [10.1...85.1, 90.1...200.1])
    }

    /// The case of 2026-10-16: a Telemost call in Chrome, muted after a while. As the person left its tab, the tab
    /// strip showed it as another tab three times in half a minute (Chrome gave it a new element, so a new id): the
    /// call was ended each time and the "new" one asked about. It's one call that moved, each time to a tab that
    /// never recorded beside it, its mute going on through the moves.
    @Test func aTabThatTakesOverWithoutEverRecordingBesideIsTheCallMoving() throws {
        let chrome = Process(bundleID: "com.google.Chrome.helper", mic: [10.1..<600.1], sound: [10.1..<600.1])
        let telemost = "Идёт звонок · Яндекс Телемост"
        var reads: [Double: CallDetector.Window] = [:]
        // Read every 3 s, in tenths so the times equal the steps': its tab is #1, then #2 at 470.1, #3 at 497.1 and
        // #4 from 503.1.
        for tenth in stride(from: 111, through: 5991, by: 30) {
            let time = Double(tenth) / 10
            let tab = time < 470 ? 1 : time < 496 ? 2 : time < 502 ? 3 : 4
            reads[time] = Self.read(.telemost, telemost, tab: tab, recording: .cameraAndMic, muted: time >= 410)
        }
        var detector = CallDetector()
        let steps = run([chrome], reads: reads, from: 10.1, to: 700, detector: &detector)
        let call = try #require(calls(steps).first)
        #expect(steps.map(\.event) == [.suspected(Self.chrome, at: 10.1), .started(try #require(started(steps).first)),
                                       .ended(call)])
        #expect(call.startedAt == 10.1 && call.lastAudioAt == 600.1)
        #expect(call.tab?.id == BrowserTabs.TabID(4), "followed to the tab it's in now")
        #expect(call.mutes == [410.1...600.1])

        // Had the second tab been seen recording beside the first, even once, it would be another call (2026-10-13).
        var beside = reads
        beside[467.1] = Self.read(.telemost, telemost, tab: 1, recording: .cameraAndMic, others: [2], muted: true)
        var other = CallDetector()
        let besideSteps = run([chrome], reads: beside, from: 10.1, to: 700, detector: &other)
        #expect(calls(besideSteps).map { $0.startedAt...$0.lastAudioAt } == [10.1...467.1, 467.1...600.1])
        #expect(calls(besideSteps).map { $0.tab?.id } == [BrowserTabs.TabID(1), BrowserTabs.TabID(4)],
                "the second call moves on its own from tab 2")
    }

    /// The call's tab closed and the person rejoined in a new tab, the mic let go for a moment as they did: the same
    /// call, in its new tab. Left for good (the mic off for longer than a flicker, no call tab in the window), it was
    /// over at once, and the new tab's is a new call.
    @Test func rejoiningInANewTabOnceTheOldOneClosedIsTheSameCall() throws {
        let telemost = "Идёт звонок · Яндекс Телемост"
        func spans(mic: [Range<Double>]) -> [ClosedRange<Double>] {
            let reads: [Double: CallDetector.Window] = [
                11.1: Self.read(.telemost, telemost, tab: 1),
                50.1: Self.read(.telemost, telemost, tab: 1),
                // The tab closed: no call tab.
                51.6: Self.noCallTab,
                53.1: Self.noCallTab,
                56.1: Self.read(.telemost, telemost, tab: 2),
                80.1: Self.read(.telemost, telemost, tab: 2),
            ]
            var detector = CallDetector()
            let steps = run([Process(bundleID: "com.google.Chrome.helper", mic: mic, sound: [10.1..<150.1])],
                            reads: reads, from: 10.1, to: 300, detector: &detector)
            return calls(steps).map { $0.startedAt...$0.lastAudioAt }
        }
        #expect(spans(mic: [10.1..<51.1, 52.1..<150.1]) == [10.1...150.1])
        #expect(spans(mic: [10.1..<51.1, 55.1..<150.1]) == [10.1...52.6, 55.1...150.1])
    }

    /// Chrome's picture-in-picture window of a call, opened as the person leaves its tab: a window without a tab strip
    /// titled like the call's tab, here with its recording mark too. It's the call's own: it neither takes the call
    /// from its tab nor counts as another tab recording; when the tab gets a new id meanwhile, the call moves to the
    /// tab, not the window; read alone (the strip not shown), it keeps the call's tab for the next read to look for.
    @Test func aPictureInPictureWindowIsTheCallsOwn() throws {
        let chrome = Process(bundleID: "com.google.Chrome.helper", mic: [10.1..<150.1], sound: [10.1..<150.1])
        let telemost = "Идёт звонок · Яндекс Телемост", mark = " - Camera and microphone recording"
        func strip(_ call: Int, front: Bool) -> BrowserTabs.Window {
            BrowserTabs.Window(title: front ? telemost : "Inbox - Gmail", tabs: [
                BrowserTabs.Tab(title: telemost + mark, selected: front, id: BrowserTabs.TabID(call)),
                BrowserTabs.Tab(title: "Inbox - Gmail", selected: !front, id: BrowserTabs.TabID(2)),
            ])
        }
        let pip = BrowserTabs.Window(title: telemost, tabs: [.stripless(telemost + mark)])
        let strips: [Double: [BrowserTabs.Window]] = [
            11.1: [strip(1, front: true)],
            // Its tab left: its picture in picture is the window in front.
            40.1: [strip(1, front: false), pip],
            // Its tab has a new id.
            60.1: [strip(3, front: false), pip],
            // The strip not shown: windows without one only.
            70.1: [BrowserTabs.Window(title: "Inbox - Gmail", tabs: [.stripless("Inbox - Gmail")]), pip],
            90.1: [strip(3, front: true)],
        ]
        let key = BrowserTabs.key(service: .telemost, page: telemost)
        let leftStrip = try #require(strips[40.1])
        let left = try #require(BrowserTabs.callTab(in: leftStrip, following: .init(key: key, id: .init(1))))
        #expect(left.id == BrowserTabs.TabID(1) && !left.othersRecordMic, "the window isn't another tab recording")

        var detector = CallDetector()
        var steps = run([chrome], strips: strips, from: 10.1, to: 50.1, detector: &detector)
        #expect(detector.followed?.tab?.id == BrowserTabs.TabID(1), "its tab, not its window in front")
        steps += run([chrome], strips: strips, from: 50.6, to: 65.1, detector: &detector)
        #expect(detector.followed?.tab?.id == BrowserTabs.TabID(3), "moved to its tab's new id, not to the window")
        steps += run([chrome], strips: strips, from: 65.6, to: 75.1, detector: &detector)
        #expect(detector.followed?.tab?.id == BrowserTabs.TabID(3) && detector.following?.id == BrowserTabs.TabID(3),
                "the window alone: still its tab's call")
        steps += run([chrome], strips: strips, from: 75.6, to: 300, detector: &detector)
        let call = try #require(calls(steps).first)
        #expect(calls(steps).count == 1 && call.startedAt == 10.1 && call.lastAudioAt == 150.1)
        #expect(call.tab?.id == BrowserTabs.TabID(3))
        #expect(steps.filter { if case .suspected = $0.event { true } else { false } }.count == 1)
    }

    /// Two Telemost calls side by side, as on 2026-10-13, and the first one's tab gets a new id meanwhile: the first
    /// call moves to it, the tab that recorded beside it being the other call's, though it's the one in front. Once
    /// the first stops, the other is its own call, from when it was first seen.
    @Test func aTabThatRecordedBesideTheCallIsAnotherCallWhenTheCallsTabChangesItsID() throws {
        let chrome = Process(bundleID: "com.google.Chrome.helper", mic: [10.1..<150.1], sound: [10.1..<150.1])
        let telemost = "Идёт звонок · Яндекс Телемост"
        func strip(_ tabs: [(id: Int, recording: Bool)]) -> [BrowserTabs.Window] {
            [BrowserTabs.Window(title: telemost, tabs: tabs.enumerated().map { index, tab in
                BrowserTabs.Tab(title: telemost + (tab.recording ? " - Microphone recording" : ""),
                                selected: index == tabs.count - 1, id: BrowserTabs.TabID(tab.id))
            })]
        }
        let strips: [Double: [BrowserTabs.Window]] = [
            11.1: strip([(1, true)]),
            40.1: strip([(1, true), (2, true)]),
            60.1: strip([(3, true), (2, true)]),
            70.1: strip([(3, true), (2, true)]),
            79.1: strip([(3, true), (2, true)]),
            80.1: strip([(3, false), (2, true)]),
            100.1: strip([(3, false), (2, true)]),
        ]
        var detector = CallDetector()
        let steps = run([chrome], strips: strips, from: 10.1, to: 300, detector: &detector)
        let ended = calls(steps)
        #expect(ended.map { $0.startedAt...$0.lastAudioAt } == [10.1...79.1, 40.1...150.1])
        #expect(ended.map { $0.tab?.id } == [BrowserTabs.TabID(3), BrowserTabs.TabID(2)])
    }

    /// A tab taking over without ever recording beside the call is the call moving only if it's of the same call:
    /// another service's, or another Meet meeting's, is another call; the same meeting's is the call moving.
    @Test func aTabOfAnotherServiceOrMeetingIsAnotherCallEvenWithoutOverlap() throws {
        func spans(_ reads: [Double: CallDetector.Window]) -> [ClosedRange<Double>] {
            var detector = CallDetector()
            let steps = run([Process(bundleID: "com.google.Chrome.helper", mic: [10.1..<150.1], sound: [10.1..<150.1])],
                            reads: reads, from: 10.1, to: 300, detector: &detector)
            return calls(steps).map { $0.startedAt...$0.lastAudioAt }
        }
        let telemost = Self.read(.telemost, "Идёт звонок · Яндекс Телемост", tab: 1)
        #expect(spans([11.1: telemost, 55.1: telemost, 57.1: Self.read(.zoom, "Zoom Meeting", tab: 2)])
            == [10.1...55.1, 57.1...150.1])
        let meet = Self.read(.meet, "Meet – abc-defg-hij", tab: 3)
        #expect(spans([11.1: meet, 55.1: meet, 57.1: Self.read(.meet, "Meet – xyz-abcd-efg", tab: 4)])
            == [10.1...55.1, 57.1...150.1])
        #expect(spans([11.1: meet, 55.1: meet, 57.1: Self.read(.meet, "Meet – abc-defg-hij", tab: 4)]) == [10.1...150.1],
                "the same meeting in another tab: the call moved")
        #expect(spans([11.1: Self.read(nil, "Call A", tab: 5), 57.1: Self.read(nil, "Call A", tab: 6)]) == [10.1...150.1],
                "a page no service is known for, by its title")
    }

    /// A mute first seen half a minute or more into the call (its tab was in the background until then) counts from
    /// when it was seen, not from the start.
    @Test func aMuteFirstSeenLateCountsFromThen() throws {
        let chrome = Process(bundleID: "com.google.Chrome.helper", mic: [10.1..<100.1], sound: [10.1..<100.1])
        let reads: [Double: CallDetector.Window] = [
            11.1: Self.read(.slack, "Huddles - Acme - Slack", recording: .mic),
            50.1: Self.read(.slack, "Huddles - Acme - Slack", recording: .mic, muted: true),
            60.1: Self.read(.slack, "Huddles - Acme - Slack", recording: .mic, muted: false),
        ]
        var detector = CallDetector()
        let call = try #require(calls(run([chrome], reads: reads, from: 10.1, to: 300, detector: &detector)).first)
        #expect(call.mutes == [50.1...60.1])
    }

    /// Discord keeps the mic while muted: once it's given back, sound after a silence is a notification, not the
    /// call coming back, and it ends 60 s after the chime.
    @Test func soundAfterAppsThatKeepTheMicLetItGoIsntTheirCall() throws {
        let steps = run([
            Process(bundleID: "com.hnc.Discord.helper.Renderer", mic: [10.3..<60.3], sound: [10.3..<62.3, 80.3..<81.3]),
        ], to: 300)
        let call = try #require(calls(steps).first)
        #expect(call.lastAudioAt == 62.3 && call.mutes.isEmpty)
        #expect(steps.last?.time == 122.3)
    }

    /// With no tab read (no Accessibility permission) a browser's call is followed as before: the app alone.
    @Test func withoutTabsABrowsersCallIsTheApp() throws {
        let steps = run([Process(bundleID: "com.google.Chrome.helper", mic: [10.3..<40.3, 50.3..<80.3],
                                 sound: [10.3..<80.3])], to: 300)
        let call = try #require(calls(steps).first)
        #expect(calls(steps).count == 1 && call.tab == nil)
        #expect(call.mutes == [40.3...50.3], "a service nobody knows might release the mic to mute")
    }

    /// The suspicion's start is where a recorder keeps audio from.
    @Test func audioIsKeptFromTheSuspicion() {
        var detector = CallDetector()
        _ = run([Process(bundleID: "ru.keepcoder.Telegram", mic: [10.3..<60.3], sound: [5.3..<60.3])], to: 12,
                detector: &detector)
        #expect(detector.keepAudioFrom == 10.3)
        _ = run([Process(bundleID: "ru.keepcoder.Telegram", mic: [10.3..<60.3], sound: [5.3..<60.3])], from: 12.3,
                to: 40, detector: &detector)
        #expect(detector.call != nil && detector.keepAudioFrom == 10.3)
    }

    // MARK: Grouping

    @Test func helpersBelongToTheirApp() {
        #expect(CallApp.mainBundleID(of: "com.google.Chrome.helper") == "com.google.Chrome")
        #expect(CallApp.mainBundleID(of: "com.google.Chrome.helper.Renderer") == "com.google.Chrome")
        #expect(CallApp.mainBundleID(of: "com.google.Chrome.helper.GPU") == "com.google.Chrome")
        #expect(CallApp.mainBundleID(of: "com.google.Chrome.helper.Plugin") == "com.google.Chrome")
        #expect(CallApp.mainBundleID(of: "com.hnc.Discord.helper.Renderer") == "com.hnc.Discord")
        #expect(CallApp.mainBundleID(of: "com.tinyspeck.slackmacgap.helper") == "com.tinyspeck.slackmacgap")
        #expect(CallApp.mainBundleID(of: "ru.keepcoder.Telegram") == "ru.keepcoder.Telegram")
        #expect(CallApp.mainBundleID(of: "us.zoom.xos") == "us.zoom.xos")
        #expect(CallApp.mainBundleID(of: "com.helper.app") == "com.helper.app", "the app's own name stays")
    }

    @Test func theOwnerAppWinsOverTheProcess() {
        #expect(CallApp(bundleID: "com.apple.WebKit.GPU", ownerBundleID: "com.apple.Safari")?.id == "com.apple.Safari")
        #expect(CallApp(bundleID: nil, ownerBundleID: "com.google.Chrome.helper")?.id == "com.google.Chrome")
        #expect(CallApp(bundleID: "com.hnc.Discord.helper")?.id == "com.hnc.Discord")
    }

    @Test func daemonsAndWeAreNotApps() {
        #expect(CallApp(bundleID: nil) == nil)
        #expect(CallApp(bundleID: "com.apple.systemsoundserverd") == nil)
        #expect(CallApp(bundleID: "com.apple.CoreSpeech") == nil, "macOS listening for speech is not a call")
        #expect(CallApp(bundleID: "dev.transcribe-thing.app") == nil)
        #expect(CallApp(bundleID: nil, ownerBundleID: "dev.transcribe-thing.app") == nil)
        #expect(CallApp(bundleID: "dev.transcribe-thing.app", ownerBundleID: "com.apple.Terminal") == nil)
    }

    @Test func helpersAddUpToTheirApp() {
        let apps = CallApp.activity([
            (CallApp(bundleID: "com.hnc.Discord.helper"), CallDetector.Activity(mic: false, sound: true)),
            (CallApp(bundleID: "com.hnc.Discord.helper.Renderer"), CallDetector.Activity(mic: true, sound: false)),
            (CallApp(bundleID: nil), CallDetector.Activity(mic: true, sound: true)),
        ])
        #expect(apps == [Self.discord: CallDetector.Activity(mic: true, sound: true)])
    }
}
