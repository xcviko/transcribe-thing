import AVFoundation
import Foundation
import MediaPlayer
import Testing
@testable import TranscribeThing

// A call's recording on its page as the Mac's Now Playing: what Control Center shows, what the play/pause key and the
// other media commands do to the player, and that the controls are let go when the page closes.

/// The system's media controls, as recorded calls.
@MainActor
private final class FakeControls: MediaControls {
    var handler: (@MainActor (MediaCommand) -> Bool)?
    var registrations = 0
    var unregistrations = 0
    var skipInterval: TimeInterval?
    var info: [String: Any]?
    var state: MPNowPlayingPlaybackState = .unknown
    var publishes = 0

    var isRegistered: Bool { handler != nil }

    func register(skipInterval: TimeInterval, _ handler: @escaping @MainActor (MediaCommand) -> Bool) {
        registrations += 1
        self.skipInterval = skipInterval
        self.handler = handler
    }

    func unregister() {
        unregistrations += 1
        handler = nil
    }

    func publish(_ info: [String: Any]?, state: MPNowPlayingPlaybackState) {
        publishes += 1
        self.info = info
        self.state = state
    }

    /// The play/pause key, Control Center: as the system would send it.
    @discardableResult func send(_ command: MediaCommand) -> Bool { handler?(command) ?? false }

    var title: String? { info?[MPMediaItemPropertyTitle] as? String }
    var elapsed: Double? { (info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue }
    var rate: Double? { (info?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue }
}

/// A player that does what it's told at once.
@MainActor
private final class FakePlayer: NowPlayable {
    let nowPlayingItem: NowPlayingItem
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 600
    var calls: [String] = []
    weak var center: CallNowPlaying?

    init(_ title: String = "Telegram", center: CallNowPlaying? = nil) {
        nowPlayingItem = NowPlayingItem(title: title, artist: "Telegram", album: "Friday, October 9 at 3:00 PM")
        self.center = center
    }

    func play() {
        calls.append("play")
        isPlaying = true
        center?.attach(self)
    }

    func pause() {
        calls.append("pause")
        isPlaying = false
        center?.update(self)
    }

    func seek(to seconds: TimeInterval, play: Bool) {
        calls.append("seek \(Int(seconds)) \(play ? "playing" : "paused")")
        currentTime = min(max(0, seconds), duration)
        if play { isPlaying = true }
        center?.update(self)
    }
}

@MainActor @Suite struct CallNowPlayingTests {
    @Test func infoSaysWhatPlaysAndWhere() {
        let item = NowPlayingItem(title: "Google Meet · Meet – abc-defg-hij", artist: "Google Chrome",
                                  album: "Friday, October 9 at 3:00 PM")
        let info = CallNowPlaying.info(item, duration: 1834, elapsed: 62.5, isPlaying: true)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Google Meet · Meet – abc-defg-hij")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Google Chrome")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Friday, October 9 at 3:00 PM")
        #expect((info[MPMediaItemPropertyPlaybackDuration] as? NSNumber)?.doubleValue == 1834)
        #expect((info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue == 62.5)
        #expect((info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue == 1)
        #expect((info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? NSNumber)?.doubleValue == 1)
        #expect((info[MPNowPlayingInfoPropertyMediaType] as? NSNumber)?.uintValue
                    == MPNowPlayingInfoMediaType.audio.rawValue)

        // Paused: the rate is 0, so the system doesn't count the time on. The time never runs past the end.
        let paused = CallNowPlaying.info(item, duration: 100, elapsed: 130, isPlaying: false)
        #expect((paused[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue == 0)
        #expect((paused[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue == 100)
    }

    @Test func itemOfACall() {
        let started = Date(timeIntervalSince1970: 1_791_550_000)
        let meet = CallRecord(id: UUID(), startedAt: started, appName: "Google Chrome", bundleID: "com.google.Chrome",
                              service: .meet, pageTitle: "Meet – abc-defg-hij", status: .done)
        #expect(NowPlayingItem.of(meet) == NowPlayingItem(title: "Google Meet · Meet – abc-defg-hij",
                                                          artist: "Google Chrome", album: CallFormat.date(started)))
        let manual = CallRecord(id: UUID(), startedAt: started, appName: CallMonitor.manualName, manual: true,
                                status: .done)
        #expect(NowPlayingItem.of(manual).title == "Menu bar recording")
        #expect(NowPlayingItem.of(manual).artist == "Your mic and all sound")
        // Titled by its summary: the title, by where it happened.
        var titled = meet
        titled.summary = CallSummary(title: "Friday release and long files")
        #expect(NowPlayingItem.of(titled) == NowPlayingItem(title: "Friday release and long files",
                                                            artist: "Google Meet in Google Chrome",
                                                            album: CallFormat.date(started)))
    }

    @Test func commandsMoveThePlayer() {
        let player = FakePlayer()
        player.currentTime = 100
        CallNowPlaying.perform(.toggle, on: player)
        #expect(player.isPlaying)
        CallNowPlaying.perform(.play, on: player)  // already playing: nothing
        CallNowPlaying.perform(.skip(15), on: player)
        CallNowPlaying.perform(.skip(-15), on: player)
        CallNowPlaying.perform(.seek(300), on: player)
        CallNowPlaying.perform(.toggle, on: player)
        #expect(!player.isPlaying)
        CallNowPlaying.perform(.pause, on: player)  // already paused: nothing
        CallNowPlaying.perform(.seek(20), on: player)
        CallNowPlaying.perform(.play, on: player)
        #expect(player.calls == ["play", "seek 115 playing", "seek 100 playing", "seek 300 playing", "pause",
                                 "seek 20 paused", "play"])
    }

    /// Nothing is held before the first Play; from then on the key pauses and resumes the call, paused or not, until
    /// the page closes; then nothing is held again.
    @Test func controlsAreHeldFromPlayUntilThePageCloses() {
        let controls = FakeControls()
        let center = CallNowPlaying(controls: controls)
        let player = FakePlayer(center: center)
        #expect(!controls.isRegistered)
        #expect(controls.publishes == 0)

        player.play()
        #expect(controls.isRegistered)
        #expect(controls.skipInterval == 15)
        #expect(controls.state == .playing)
        #expect(controls.title == "Telegram")
        #expect(controls.rate == 1)

        // F8: paused, still Now Playing, so F8 again plays it.
        #expect(controls.send(.toggle))
        #expect(!player.isPlaying)
        #expect(controls.state == .paused)
        #expect(controls.rate == 0)
        #expect(controls.isRegistered)
        #expect(controls.send(.toggle))
        #expect(player.isPlaying)
        #expect(controls.state == .playing)
        #expect(controls.registrations == 1)

        // Control Center's scrubber.
        #expect(controls.send(.seek(42)))
        #expect(controls.elapsed == 42)

        // The page closes.
        center.detach(player)
        #expect(!controls.isRegistered)
        #expect(controls.info == nil)
        #expect(controls.state == .stopped)
        #expect(!controls.send(.toggle))
        // Closing the window afterwards changes nothing more.
        center.release()
        #expect(controls.unregistrations == 1)
    }

    /// Another call's page takes over; the old page closing late doesn't take the controls from it.
    @Test func anotherCallTakesOver() {
        let controls = FakeControls()
        let center = CallNowPlaying(controls: controls)
        let first = FakePlayer("Telegram", center: center)
        let second = FakePlayer("Zoom", center: center)
        first.play()
        second.play()
        #expect(controls.title == "Zoom")
        // The first one's updates no longer reach Now Playing.
        let publishes = controls.publishes
        first.pause()
        #expect(controls.publishes == publishes)
        center.detach(first)
        #expect(controls.isRegistered)
        #expect(controls.send(.pause))
        #expect(!second.isPlaying)
        #expect(first.calls == ["play", "pause"])
        // The window closes: let go.
        center.release()
        #expect(!controls.isRegistered)
        #expect(controls.info == nil)
    }

    /// A player that went away (its page dropped without closing) takes nothing with it: commands say so.
    @Test func aPlayerThatWentAwayHandlesNothing() {
        let controls = FakeControls()
        let center = CallNowPlaying(controls: controls)
        do {
            let player = FakePlayer(center: center)
            player.play()
        }
        #expect(center.owner == nil)
        #expect(!controls.send(.toggle))
        // The window closes: the key is let go all the same.
        center.release()
        #expect(!controls.isRegistered)
        #expect(controls.info == nil)
    }
}

/// The real player with real audio (a second of silence): it takes the controls when it plays, and lets go when the
/// page closes.
@MainActor @Suite struct CallPlayerNowPlayingTests {
    @Test func playPauseAndClose() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("call-now-playing-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mic.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let controls = FakeControls()
        let center = CallNowPlaying(controls: controls)
        let item = NowPlayingItem(title: "Telegram", artist: "Telegram", album: "Today")
        let player = CallPlayer(id: UUID(), urls: [url], duration: 1, item: item, nowPlaying: center)
        player.play()
        try await waitUntil { controls.state == .playing }
        #expect(controls.isRegistered)
        #expect(controls.title == "Telegram")

        controls.send(.toggle)
        #expect(!player.isPlaying)
        #expect(controls.state == .paused)

        player.stop()
        #expect(!controls.isRegistered)
        #expect(controls.info == nil)
        #expect(controls.state == .stopped)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
