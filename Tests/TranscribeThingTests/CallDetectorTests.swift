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
        var steps: [Step] = []
        for tenth in stride(from: Int((from * 10).rounded()), through: Int((to * 10).rounded()), by: 5) {
            let time = Double(tenth) / 10
            let apps = CallApp.activity(processes.map { (CallApp(bundleID: $0.bundleID), $0.activity(at: time)) })
            let windows = reads[time].map { [Self.chrome: $0] } ?? [:]
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
