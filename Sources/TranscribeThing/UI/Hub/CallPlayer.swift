import AVFoundation
import Observation

/// Plays a call's two tracks together, as it sounded: the mic's and the other side's, each its own track of one
/// composition, which the player mixes. Both start at the call's sample 0, so they stay in step. Loaded on the first
/// Play, not when the page opens. From that Play until the page closes (`stop`), it's the Mac's Now Playing
/// (`CallNowPlaying`): the play/pause key and Control Center pause and play it.
@MainActor @Observable
final class CallPlayer: NowPlayable {
    private(set) var isPlaying = false
    /// Seconds into the call.
    private(set) var currentTime: TimeInterval = 0
    /// The call's length: its longer track's, until the files say.
    private(set) var duration: TimeInterval
    /// Why it can't play: the files are gone or unreadable.
    private(set) var problem: String?

    @ObservationIgnored private let urls: [URL]
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var loading: Task<AVPlayer?, Never>?
    /// Seeks not done yet: the player's own clock still says where it was.
    @ObservationIgnored private var seeking = 0

    /// The call it plays.
    @ObservationIgnored let id: UUID
    /// What Now Playing shows for it.
    @ObservationIgnored let nowPlayingItem: NowPlayingItem
    /// The media controls it takes once it plays; none for a page's stand-in or a preview.
    @ObservationIgnored private let nowPlaying: CallNowPlaying?

    init(id: UUID, urls: [URL], duration: TimeInterval,
         item: NowPlayingItem = NowPlayingItem(title: "Call", artist: "", album: ""),
         nowPlaying: CallNowPlaying? = nil, position: TimeInterval = 0) {
        self.id = id
        currentTime = position
        self.urls = urls
        self.duration = duration
        self.nowPlayingItem = item
        self.nowPlaying = nowPlaying
    }

    var canPlay: Bool { !urls.isEmpty && problem == nil }

    /// Never played since the page opened: the waveform's first click plays.
    var isIdle: Bool { player == nil && loading == nil }

    /// Where it is this instant, from the player's own clock: what a playhead drawn every frame follows, between
    /// `currentTime`'s ten updates a second.
    var livePosition: TimeInterval {
        guard isPlaying, seeking == 0, let player else { return currentTime }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? min(max(0, seconds), duration) : currentTime
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        Task { @MainActor in
            guard let player = await load() else { return }
            if currentTime >= duration - 0.05 { await seek(player, to: 0) }
            player.play()
            isPlaying = true
            nowPlaying?.attach(self)
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        nowPlaying?.update(self)
    }

    /// Moves to `seconds` into the call; `play` starts it from there.
    func seek(to seconds: TimeInterval, play: Bool = false) {
        let target = min(max(0, seconds), duration)
        currentTime = target
        Task { @MainActor in
            guard let player = await load() else { return }
            await seek(player, to: target)
            if play {
                player.play()
                isPlaying = true
                nowPlaying?.attach(self)
            } else {
                nowPlaying?.update(self)
            }
        }
    }

    /// Stops and lets go of the files and of the media controls: the page closed, or shows another call.
    func stop() {
        pause()
        nowPlaying?.detach(self)
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        loading = nil
    }

    private func seek(_ player: AVPlayer, to seconds: TimeInterval) async {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        seeking += 1
        defer { seeking -= 1 }
        await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    private func load() async -> AVPlayer? {
        if let player { return player }
        if let loading { return await loading.value }
        let urls = urls
        let task = Task { @MainActor () -> AVPlayer? in
            do {
                let composition = try await Self.composition(of: urls)
                let item = AVPlayerItem(asset: composition)
                let player = AVPlayer(playerItem: item)
                let length = try await composition.load(.duration).seconds
                if length.isFinite, length > 0 { duration = length }
                observe(player, item: item)
                self.player = player
                return player
            } catch {
                problem = "The call’s audio couldn’t be read."
                Log.audio.error("Couldn’t play the call: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        loading = task
        return await task.value
    }

    private func observe(_ player: AVPlayer, item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.currentTime = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.currentTime = self.duration
                // Still Now Playing, paused at the end: the play/pause key plays it again from the start.
                self.nowPlaying?.update(self)
            }
        }
    }

    /// Each file's audio as its own track of one composition, all from 0.
    private static func composition(of urls: [URL]) async throws -> AVComposition {
        let composition = AVMutableComposition()
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let range = try await source.load(.timeRange)
            let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try track?.insertTimeRange(range, of: source, at: .zero)
        }
        guard !composition.tracks.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return composition
    }
}
