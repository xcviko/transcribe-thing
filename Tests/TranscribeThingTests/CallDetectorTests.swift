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

    /// Feeds the processes to `detector` every 0.5 s from `from` to `to`, at x.3 and x.8 like the log. Times are
    /// tenths divided by ten, so they equal the literals they are compared with.
    private func run(_ processes: [Process], from: Double = 0.3, to: Double,
                     detector: inout CallDetector) -> [Step] {
        var steps: [Step] = []
        for tenth in stride(from: Int((from * 10).rounded()), through: Int((to * 10).rounded()), by: 5) {
            let time = Double(tenth) / 10
            let apps = CallApp.activity(processes.map { (CallApp(bundleID: $0.bundleID), $0.activity(at: time)) })
            steps += detector.feed(apps, at: time).map { Step(time: time, event: $0) }
        }
        return steps
    }

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

    @Test func theFirstOfTwoCallsIsFollowed() {
        let steps = run([
            Process(bundleID: "com.hnc.Discord.helper.Renderer", mic: [20.3..<100.3], sound: [20.3..<100.3]),
            Process(bundleID: "ru.keepcoder.Telegram", mic: [10.3..<80.3], sound: [10.3..<80.3]),
        ], to: 300)
        #expect(started(steps).map(\.app) == [Self.telegram])
        #expect(calls(steps).map(\.app) == [Self.telegram], "Discord had both only while Telegram was followed")
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
