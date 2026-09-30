import AVFAudio
import CoreAudio
import Foundation
import os

/// What `CueEngine` asks of the audio hardware. Every call arrives on the engine's queue, never the main thread.
/// `AVCueOutput` is the real one; tests substitute a fake, so nothing ever plays.
protocol CueOutput: AnyObject {
    /// The output must be rebuilt (the engine's configuration or the default output device changed). May be
    /// called on any thread; the engine hops to its queue. The output marks its graph stale before calling it, so
    /// a `start` that runs before the engine gets there already builds for the new device.
    var onChange: (() -> Void)? { get set }
    /// Started, and on the current device: false once a change made the graph stale.
    var isRunning: Bool { get }
    /// Reads the sound files and starts watching the default output; returns each loaded cue's length in seconds.
    func load() -> [SoundEffect: TimeInterval]
    /// Builds the graph for the current output device if there is none (or it went stale), then starts it.
    func start() throws
    /// Stops the device (AirPods leave their playback state) and keeps the graph for the next start.
    func stop()
    /// Drops the graph: the next `start` builds one for whatever device is the default then.
    func reset()
    /// Drops the graph if a change made it stale and no `start` has rebuilt it since; true when it dropped one.
    func resetIfStale() -> Bool
    /// Plays `effect` from its start, cutting off an earlier play of the same cue (other cues keep playing).
    /// False when it isn't loaded or the output isn't running.
    func play(_ effect: SoundEffect) -> Bool
}

/// Plays transcribe-thing's sound cues without ever touching audio on the main thread.
///
/// Starting an output is a blocking `AudioDeviceStart`: a few ms on the built-in speakers, up to ~300 ms while
/// AirPods wake their Bluetooth route. `AVAudioPlayer` did that on the main thread for every cue and froze the
/// pill each time. Here one persistent output lives on a private serial queue: callers only enqueue ("play X",
/// "warm up") and return at once. `warmUp()` at key-down gets the device running before the start cue 120 ms
/// later; the output stops `idleRelease` seconds after the last cue while no dictation holds it, so AirPods don't
/// stay in an active playback state.
///
/// Cues asked for while the output starts keep their timeline, moved by how long the start took: after AirPods
/// wake (~450 ms), fn then ⇥ still sounds as two cues, as far apart as the keys were. A key-feedback cue that would
/// sound more than `maxLateness` after it was asked for is dropped: it confirms a press or a paste the user has
/// long seen. Notice cues always play: their toast is still on screen and the sound is what draws the eye to it.
///
/// Threading: public methods are safe from any thread and never block; everything else runs on `queue`.
final class CueEngine: @unchecked Sendable {
    static let idleRelease: TimeInterval = 5
    static let maxLateness: TimeInterval = 1.5
    /// A start this long is a wake (AirPods); the built-in speakers start in a few ms and move nothing.
    static let slowStart: TimeInterval = 0.02
    /// Cues that are dropped rather than played more than `maxLateness` late.
    static let keyFeedback: Set<SoundEffect> = [.start, .stop, .lock, .paste, .cancel, .modelSwitch]

    private let queue = DispatchQueue(label: "dev.transcribe-thing.audio.cues", qos: .userInteractive)
    private let idleDelay: TimeInterval
    private let makeOutput: @Sendable () -> CueOutput
    /// Loaded cue lengths, read on the main actor for ducking.
    private let durations = OSAllocatedUnfairLock<[SoundEffect: TimeInterval]>(initialState: [:])

    // Queue state.
    private var output: CueOutput?
    /// A dictation is under way: the output stays up however long ago the last cue was.
    private var isHeld = false
    /// A cue or warm-up started the output and it hasn't idled out since. Only then does a device change start
    /// it again: a hold alone (a dictation with "Play sounds" off) never wakes AirPods.
    private var isUp = false
    private var idleTimer: DispatchWorkItem?
    /// The last start of the output (uptime ns): cues asked for before it was up move by its length.
    private var lastStart: (began: UInt64, readyAt: UInt64)?
    /// When the latest cue is due, so a cue never sounds before one asked for earlier.
    private var lastDue: UInt64 = 0

    init(idleRelease: TimeInterval = CueEngine.idleRelease,
         makeOutput: @escaping @Sendable () -> CueOutput = { AVCueOutput() }) {
        self.idleDelay = idleRelease
        self.makeOutput = makeOutput
    }

    deinit {
        // Audio objects are released on the queue too.
        let output = output
        queue.async { _ = output }
    }

    // MARK: Public API (any thread, never blocks)

    /// Reads the sound files; the output itself starts only for the first cue or warm-up.
    func load() {
        queue.async { self.loadOnQueue() }
    }

    /// `requestedAt`: `DispatchTime` uptime in ns when the cue was asked for (lateness is measured from it).
    func play(_ effect: SoundEffect, requestedAt: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        queue.async { self.playOnQueue(effect, requestedAt: requestedAt) }
    }

    /// Starts the output ahead of a cue that is about to play.
    func warmUp() {
        queue.async { self.warmUpOnQueue() }
    }

    /// While held (a dictation records or waits for its text) the output never idles out.
    func setHeld(_ held: Bool) {
        queue.async { self.setHeldOnQueue(held) }
    }

    func duration(of effect: SoundEffect) -> TimeInterval? {
        durations.withLock { $0[effect] }
    }

    /// Waits for everything enqueued so far (tests).
    func flush() {
        queue.sync {}
    }

    // MARK: Queue

    private func loadOnQueue() {
        Self.checkOffMain("load")
        guard output == nil else { return }
        let output = makeOutput()
        output.onChange = { [weak self] in
            guard let self else { return }
            self.queue.async { self.outputChanged() }
        }
        self.output = output
        let loaded = output.load()
        durations.withLock { $0 = loaded }
    }

    private func playOnQueue(_ effect: SoundEffect, requestedAt: UInt64) {
        Self.checkOffMain("play")
        guard output != nil else { return }
        defer { scheduleRelease() }
        guard ensureRunning() else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        var due = requestedAt
        if let lastStart, requestedAt < lastStart.readyAt,
           Double(lastStart.readyAt - lastStart.began) >= Self.slowStart * 1e9 {
            // It waited for the wake: it keeps its place after the cues before it.
            due &+= lastStart.readyAt - lastStart.began
        }
        due = max(due, now, lastDue)
        let late = Double(due - min(requestedAt, due)) / 1e6
        if late > Self.maxLateness * 1000, Self.keyFeedback.contains(effect) {
            Log.app.debug("Cue \(effect.rawValue, privacy: .public) dropped: \(Int(late)) ms late")
            return
        }
        lastDue = due
        guard due > now else { return playNow(effect, requestedAt: requestedAt) }
        queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: due)) { [weak self] in
            self?.playNow(effect, requestedAt: requestedAt)
        }
    }

    private func playNow(_ effect: SoundEffect, requestedAt: UInt64) {
        guard let output, ensureRunning() else { return }
        guard output.play(effect) else {
            Log.app.error("Cue \(effect.rawValue, privacy: .public) couldn't play")
            return
        }
        Log.app.debug("Cue \(effect.rawValue, privacy: .public) played \(Self.milliseconds(since: requestedAt)) ms after it was asked for")
    }

    private func warmUpOnQueue() {
        Self.checkOffMain("warmUp")
        guard output != nil else { return }
        let requestedAt = DispatchTime.now().uptimeNanoseconds
        let wasRunning = output?.isRunning == true
        if ensureRunning(), !wasRunning {
            Log.app.debug("Cue output warmed up in \(Self.milliseconds(since: requestedAt)) ms")
        }
        scheduleRelease()
    }

    private func setHeldOnQueue(_ held: Bool) {
        Self.checkOffMain("setHeld")
        guard held != isHeld else { return }
        isHeld = held
        scheduleRelease()
    }

    /// Starts the output if it isn't running; a start that fails drops the graph and tries once more on a fresh
    /// one (the old one may be bound to a device that is gone). Failures are logged, never thrown.
    @discardableResult
    private func ensureRunning() -> Bool {
        guard let output else { return false }
        if output.isRunning { return true }
        let began = DispatchTime.now().uptimeNanoseconds
        for attempt in 1...2 {
            do {
                try output.start()
                lastStart = (began, DispatchTime.now().uptimeNanoseconds)
                isUp = true
                return true
            } catch {
                Log.app.error("Cue output didn't start (attempt \(attempt)): \(error.localizedDescription, privacy: .public)")
                output.reset()
            }
        }
        isUp = false
        return false
    }

    /// (Re)arms the idle release; a held output has none.
    private func scheduleRelease() {
        idleTimer?.cancel()
        idleTimer = nil
        guard !isHeld else { return }
        let item = DispatchWorkItem { [weak self] in self?.releaseIfIdle() }
        idleTimer = item
        queue.asyncAfter(deadline: .now() + idleDelay, execute: item)
    }

    private func releaseIfIdle() {
        Self.checkOffMain("releaseIfIdle")
        idleTimer = nil
        guard !isHeld else { return }
        isUp = false
        guard let output, output.isRunning else { return }
        output.stop()
        Log.app.debug("Cue output stopped after \(self.idleDelay) s idle")
    }

    /// AirPods connected or left, the route changed format: rebuild for the new default output, right away if a
    /// cue or warm-up had it up, else at the next cue. A cue that got here first already started on a fresh
    /// graph; dropping that one would cut it off.
    private func outputChanged() {
        Self.checkOffMain("outputChanged")
        guard let output, output.resetIfStale() else { return }
        Log.app.debug("Cue output rebuilt after a device change")
        if isUp { ensureRunning() }
    }

    private static func milliseconds(since start: UInt64) -> Int {
        let now = DispatchTime.now().uptimeNanoseconds
        return now > start ? Int((now - start) / 1_000_000) : 0
    }

    /// Audio work on the main thread is the stall this type exists to avoid.
    static func checkOffMain(_ function: String) {
        guard Thread.isMainThread else { return }
        Log.app.fault("Cue engine \(function, privacy: .public) ran on the main thread")
        assertionFailure("Cue engine \(function) ran on the main thread")
    }
}

// MARK: - AVAudioEngine output

enum CueOutputError: LocalizedError {
    case noOutputDevice

    var errorDescription: String? { "No output device" }
}

/// The real cue output: one `AVAudioEngine` (output only: its input node is never touched, so it can't open a
/// mic) with a player node per cue into the main mixer, which lets different cues overlap as before. The Switch
/// model tick has a few nodes, taken in turn, so ticks at the keyboard's autorepeat ring over each other. The cues
/// are read once into buffers, then converted to the output's sample rate each time the graph is built.
/// Confined to `CueEngine`'s queue.
final class AVCueOutput: CueOutput {
    var onChange: (() -> Void)?

    /// The files as read (the processing format of each WAV).
    private var sources: [SoundEffect: AVAudioPCMBuffer] = [:]
    private var engine: AVAudioEngine?
    private var players: [SoundEffect: [AVAudioPlayerNode]] = [:]
    /// The node each cue plays on next (its voices in turn).
    private var nextVoice: [SoundEffect: Int] = [:]
    private var buffers: [SoundEffect: AVAudioPCMBuffer] = [:]
    private var configurationObserver: NSObjectProtocol?
    private var outputListener: AudioObjectPropertyListenerBlock?
    /// Set on the notifying thread the moment the device changes, read on the queue.
    private let isStale = OSAllocatedUnfairLock(initialState: false)

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    deinit {
        if let outputListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, nil, outputListener)
        }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    /// Running on the current device: a stale graph counts as stopped, so the next cue rebuilds before it plays.
    var isRunning: Bool { engine?.isRunning == true && !isStale.withLock { $0 } }

    func load() -> [SoundEffect: TimeInterval] {
        CueEngine.checkOffMain("AVCueOutput.load")
        var durations: [SoundEffect: TimeInterval] = [:]
        for effect in SoundEffect.allCases {
            guard let url = AppResources.url(effect.fileName, ext: SoundEffect.fileExtension, subdirectory: "Sounds") else {
                Log.app.error("Missing sound \(effect.rawValue, privacy: .public).wav")
                continue
            }
            do {
                let file = try AVAudioFile(forReading: url)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length)) else { continue }
                try file.read(into: buffer)
                sources[effect] = buffer
                durations[effect] = Double(file.length) / file.fileFormat.sampleRate
            } catch {
                Log.app.error("Couldn't load sound \(effect.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        observeDefaultOutput()
        return durations
    }

    func start() throws {
        CueEngine.checkOffMain("AVCueOutput.start")
        // The engine stops itself on a configuration change; restarting that graph would play on the old format.
        _ = resetIfStale()
        let engine = try engine ?? build()
        if !engine.isRunning { try engine.start() }
    }

    func stop() {
        CueEngine.checkOffMain("AVCueOutput.stop")
        for player in players.values.joined() { player.stop() }
        engine?.stop()
    }

    func reset() {
        CueEngine.checkOffMain("AVCueOutput.reset")
        stop()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        players = [:]
        nextVoice = [:]
        buffers = [:]
        engine = nil
    }

    func resetIfStale() -> Bool {
        let wasStale = isStale.withLock { stale in
            defer { stale = false }
            return stale
        }
        if wasStale { reset() }
        return wasStale
    }

    private func changed() {
        isStale.withLock { $0 = true }
        onChange?()
    }

    /// Nodes per cue: one restarts a cue still sounding; the Switch model tick, held down at the keyboard's
    /// autorepeat (as fast as every 30 ms, the tick lasts 70 ms), gets enough to let every tick ring out.
    static func voices(for effect: SoundEffect) -> Int {
        effect == .modelSwitch ? 6 : 1
    }

    func play(_ effect: SoundEffect) -> Bool {
        guard let engine, engine.isRunning, let voices = players[effect], !voices.isEmpty,
              let buffer = buffers[effect] else { return false }
        let index = nextVoice[effect, default: 0] % voices.count
        nextVoice[effect] = index + 1
        let player = voices[index]
        // `.interrupts` restarts this node if it is still sounding; the other nodes keep theirs.
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
        return true
    }

    private func build() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard rate > 0 else { throw CueOutputError.noOutputDevice }
        for (effect, source) in sources {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: source.format.channelCount),
                  let buffer = Self.convert(source, to: format) else {
                Log.app.error("Couldn't convert sound \(effect.rawValue, privacy: .public) to \(rate) Hz")
                continue
            }
            players[effect] = (0..<Self.voices(for: effect)).map { _ in
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                return player
            }
            buffers[effect] = buffer
        }
        engine.prepare()
        // The engine stops itself when the output's format changes (AirPods switching to their headset profile).
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.changed() }
        self.engine = engine
        return engine
    }

    /// An engine stays bound to the device that was default when it was built (AirPods connecting, switching to a
    /// display's speakers), so rebuild when the default output changes. CoreAudio calls the block on its own
    /// thread; `onChange` hops to the engine's queue.
    private func observeDefaultOutput() {
        guard outputListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, nil, block)
        if status == noErr { outputListener = block }
    }

    /// `source` resampled (and converted) to `format`; the same buffer when it already matches.
    static func convert(_ source: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if source.format == format { return source }
        guard let converter = AVAudioConverter(from: source.format, to: format) else { return nil }
        let ratio = format.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount((Double(source.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let fed = OSAllocatedUnfairLock(initialState: false)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            let isFirst = fed.withLock { done in
                defer { done = true }
                return !done
            }
            inputStatus.pointee = isFirst ? .haveData : .endOfStream
            return isFirst ? source : nil
        }
        guard status != .error, error == nil else { return nil }
        return output
    }
}
