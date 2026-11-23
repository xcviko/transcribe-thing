import Foundation
import MediaPlayer

/// A call's recording, as macOS shows it in Control Center's Now Playing: the call's title, where it ran, and when.
struct NowPlayingItem: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String

    /// "Google Meet · Meet – abc-defg-hij", by "Google Chrome", from "Thursday, October 9 at 2:10 PM"; a call its
    /// summary titled is "Friday release and long files", by "Google Meet in Google Chrome".
    @MainActor static func of(_ call: CallRecord) -> NowPlayingItem {
        NowPlayingItem(title: CallFormat.title(call),
                       artist: CallFormat.origin(call) ?? (call.manual ? "Your mic and all sound" : call.appName),
                       album: CallFormat.date(call.startedAt))
    }
}

/// What the system's media controls ask for: the play/pause key (F8 on Apple keyboards), headphone buttons, Control
/// Center's Now Playing.
enum MediaCommand: Equatable, Sendable {
    case play, pause, toggle
    /// Control Center's scrubber: to this many seconds in.
    case seek(TimeInterval)
    /// Skip forward (positive) or back (negative) this many seconds.
    case skip(TimeInterval)
}

/// Something that plays and can be paused from the media controls: the call page's `CallPlayer`, a fake in tests.
@MainActor protocol NowPlayable: AnyObject {
    var nowPlayingItem: NowPlayingItem { get }
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    func play()
    func pause()
    func seek(to seconds: TimeInterval, play: Bool)
}

/// The system's side: `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter`, a fake in tests.
@MainActor protocol MediaControls: AnyObject {
    /// The media commands go to `handler` from now on (true: done), skips by `skipInterval` seconds.
    func register(skipInterval: TimeInterval, _ handler: @escaping @MainActor (MediaCommand) -> Bool)
    /// No command comes here any more: the play/pause key goes back to whatever played before.
    func unregister()
    /// What Now Playing shows (nil: nothing) and whether it plays.
    func publish(_ info: [String: Any]?, state: MPNowPlayingPlaybackState)
}

/// Makes the call page's player the Mac's Now Playing while it has audio loaded: the play/pause key, headphone
/// buttons and Control Center pause it, play it, scrub it and skip 15 seconds. It takes them from the first Play
/// until the page closes (`detach`), paused or not, so the key resumes what was paused; then it lets go, and the key
/// is Music's again. Dictation's cues never come here: they are not a player, and only this class publishes anything.
///
/// macOS picks the Now Playing app among those that publish info with a playback state and handle the commands:
/// all three are done on each play. The Hub's window makes the app a regular one while a call is open.
@MainActor
final class CallNowPlaying {
    static let skipInterval: TimeInterval = 15

    /// The real controls, shared by every call page (there is one Hub window).
    static let shared = CallNowPlaying(controls: SystemMediaControls())

    private let controls: MediaControls
    /// The player the commands go to, while one has played.
    private(set) weak var owner: (any NowPlayable)?
    /// The commands come here: from the first attach until a release, even if the owner went away meanwhile.
    private(set) var isHolding = false

    init(controls: MediaControls) {
        self.controls = controls
    }

    /// `player` started playing: it takes the media controls (from another call's player, if one had them).
    func attach(_ player: any NowPlayable) {
        if owner !== player || !isHolding {
            owner = player
            isHolding = true
            controls.register(skipInterval: Self.skipInterval) { [weak self] command in
                guard let self, let owner = self.owner else { return false }
                Self.perform(command, on: owner)
                return true
            }
        }
        update(player)
    }

    /// `player` played, paused, moved or ended: Now Playing says so, if it's the one with the controls.
    func update(_ player: any NowPlayable) {
        guard owner === player else { return }
        controls.publish(Self.info(player.nowPlayingItem, duration: player.duration, elapsed: player.currentTime,
                                   isPlaying: player.isPlaying),
                         state: player.isPlaying ? .playing : .paused)
    }

    /// `player`'s page closed (or showed another call): the controls are let go, Now Playing is cleared.
    func detach(_ player: any NowPlayable) {
        guard owner === player else { return }
        release()
    }

    /// Lets go whatever player has the controls (or had them, and went away without closing): the Hub's window closed.
    func release() {
        guard isHolding else { return }
        isHolding = false
        owner = nil
        controls.unregister()
        controls.publish(nil, state: .stopped)
    }

    /// What a command does to the player.
    static func perform(_ command: MediaCommand, on player: any NowPlayable) {
        switch command {
        case .play:
            if !player.isPlaying { player.play() }
        case .pause:
            if player.isPlaying { player.pause() }
        case .toggle:
            player.isPlaying ? player.pause() : player.play()
        case .seek(let seconds):
            player.seek(to: seconds, play: player.isPlaying)
        case .skip(let seconds):
            player.seek(to: player.currentTime + seconds, play: player.isPlaying)
        }
    }

    /// Now Playing's info: title, app, date, length, where it is and whether it moves (the system counts the time
    /// on from the rate, so it's published only when that changes).
    static func info(_ item: NowPlayingItem, duration: TimeInterval, elapsed: TimeInterval,
                     isPlaying: Bool) -> [String: Any] {
        [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artist,
            MPMediaItemPropertyAlbumTitle: item.album,
            MPMediaItemPropertyPlaybackDuration: NSNumber(value: max(0, duration)),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: NSNumber(value: min(max(0, elapsed), max(0, duration))),
            MPNowPlayingInfoPropertyPlaybackRate: NSNumber(value: isPlaying ? 1.0 : 0.0),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: NSNumber(value: 1.0),
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue),
        ]
    }
}

/// `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter`, for real.
@MainActor
final class SystemMediaControls: MediaControls {
    private var targets: [(MPRemoteCommand, Any)] = []

    func register(skipInterval: TimeInterval, _ handler: @escaping @MainActor (MediaCommand) -> Bool) {
        unregister()
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        let commands: [(MPRemoteCommand, @Sendable (MPRemoteCommandEvent) -> MediaCommand?)] = [
            (center.playCommand, { _ in .play }),
            (center.pauseCommand, { _ in .pause }),
            (center.togglePlayPauseCommand, { _ in .toggle }),
            (center.changePlaybackPositionCommand, { event in
                (event as? MPChangePlaybackPositionCommandEvent).map { .seek($0.positionTime) }
            }),
            (center.skipForwardCommand, { event in
                .skip((event as? MPSkipIntervalCommandEvent)?.interval ?? skipInterval)
            }),
            (center.skipBackwardCommand, { event in
                .skip(-((event as? MPSkipIntervalCommandEvent)?.interval ?? skipInterval))
            }),
        ]
        for (command, translate) in commands {
            command.isEnabled = true
            let token = command.addTarget { event in
                guard let media = translate(event) else { return .commandFailed }
                // The center calls on the main thread; should it ever not, the command still gets there.
                if Thread.isMainThread {
                    return MainActor.assumeIsolated { handler(media) } ? .success : .noActionableNowPlayingItem
                }
                DispatchQueue.main.async { _ = handler(media) }
                return .success
            }
            targets.append((command, token))
        }
    }

    func unregister() {
        for (command, token) in targets {
            command.removeTarget(token)
            command.isEnabled = false
        }
        targets.removeAll()
    }

    func publish(_ info: [String: Any]?, state: MPNowPlayingPlaybackState) {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = state
    }
}
