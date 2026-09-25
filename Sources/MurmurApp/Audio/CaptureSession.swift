import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation

/// What a capture session reports. Delivered on the session's control queue or the tap thread, never
/// on the main actor: owners hop themselves.
enum CaptureSessionEvent: Sendable {
    case firstBuffer
    case switchedDevice(AudioInputDevice)
    case deviceLost
    case startFailed(String)
    case noAudio(String)
}

/// One microphone capture: a fresh input-only `AVAudioEngine`, a tap that resamples to 16 kHz mono and
/// feeds the level meter, and self-healing across configuration changes, dead devices and stalls
/// (the recording keeps growing across engine rebuilds).
///
/// Threading: engine work runs on a private serial queue (Bluetooth starts can block for seconds);
/// the tap runs on AVAudioEngine's own thread and only holds `box`'s lock briefly; public methods are
/// safe from any thread. Nothing here is main-actor isolated, so no closure built here can trap when
/// CoreAudio calls it on its threads.
final class CaptureSession: @unchecked Sendable {
    struct Options: Sendable {
        var preferredUID: String?
        var preferBuiltInOverBluetooth = true
        /// false = level monitoring only (samples are discarded after metering).
        var keepsSamples = true
        var firstBufferTimeout: TimeInterval = 2.0
        var stallTimeout: TimeInterval = 1.5
        /// More rebuilds than this within `rebuildWindow` means the device is gone for good.
        var maxRebuilds = 5
        var rebuildWindow: TimeInterval = 15
    }

    let options: Options
    /// `AudioClock` time at which `start()` was requested.
    let startedAt: TimeInterval

    private let meter: LevelMeter?
    private let onEvent: @Sendable (CaptureSessionEvent) -> Void
    private let control = DispatchQueue(label: "dev.murmur.audio.capture", qos: .userInitiated)
    private let listenerQueue = DispatchQueue(label: "dev.murmur.audio.capture.listeners", qos: .userInitiated)
    private let box: CaptureBox

    // Control-queue state.
    private var initialRecord: CoreAudioHAL.InputRecord
    private var engine: AVAudioEngine?
    private var configObserver: (any NSObjectProtocol)?
    private var deviceListeners: HALListenerSet?
    private var watchdog: DispatchSourceTimer?
    private var isRunning = false
    private var lastRebuildAt: TimeInterval
    private var rebuildTimes: [TimeInterval] = []
    private var rebuildScheduled = false

    init(device: CoreAudioHAL.InputRecord, options: Options, meter: LevelMeter?,
         onEvent: @escaping @Sendable (CaptureSessionEvent) -> Void) {
        self.options = options
        self.meter = meter
        self.onEvent = onEvent
        self.initialRecord = device
        let now = AudioClock.now()
        self.startedAt = now
        self.lastRebuildAt = now
        self.box = CaptureBox(device: device.device, keepsSamples: options.keepsSamples)
    }

    // MARK: Public API (any thread)

    func start() {
        control.async { self.startOnQueue() }
        armStartTimeout()
    }

    /// Reports `.noAudio` if no buffer arrives within `firstBufferTimeout`. Timed on another queue: a
    /// Bluetooth engine start can block `control` past the deadline.
    func armStartTimeout() {
        listenerQueue.asyncAfter(deadline: .now() + options.firstBufferTimeout) { [weak self] in
            self?.checkFirstBuffer()
        }
    }

    var device: AudioInputDevice { box.withLock { $0.device } }

    /// Seconds of 16 kHz audio captured so far.
    var capturedDuration: TimeInterval {
        box.withLock { Double($0.samples.count) / Recording.sampleRate }
    }

    /// Stops appending immediately and returns everything captured (empty when `discard`).
    func finishNow(discard: Bool) -> [Float] {
        let (samples, pending) = box.withLock { state -> ([Float], (@Sendable ([Float]) -> Void)?) in
            let pending = state.tailCompletion
            state.tailCompletion = nil
            return (state.finalize(discard: discard), pending)
        }
        pending?(samples)
        control.async { self.shutdownOnQueue() }
        return samples
    }

    /// Keeps capturing until the audio covers `tail` seconds past now (taps deliver ~100 ms chunks, so
    /// this usually takes 150-250 ms), then finalizes and calls `completion` on a background thread.
    func finish(tail: TimeInterval, completion: @escaping @Sendable ([Float]) -> Void) {
        let until = AudioClock.now() + max(0, tail)
        let finishedEarly: [Float]? = box.withLock { state in
            guard state.phase == .capturing, state.isLive, tail > 0 else {
                return state.finalize(discard: false)
            }
            state.phase = .tail(until: until)
            state.tailCompletion = completion
            state.feedsMeter = false
            return nil
        }
        if let finishedEarly {
            completion(finishedEarly)
            control.async { self.shutdownOnQueue() }
            return
        }
        control.asyncAfter(deadline: .now() + tail + 0.35) { self.completeTailOnQueue() }
    }

    /// Attenuates captured audio between two `AudioClock` times (already captured or still to come).
    func duck(from start: TimeInterval, to end: TimeInterval, gain: Float) {
        guard end > start else { return }
        box.withLock { $0.addDuck(DuckWindow(start: start, end: end, gain: gain)) }
    }

    // MARK: Engine lifecycle (control queue)

    private func startOnQueue() {
        guard box.withLock({ $0.phase != .finished }) else { return }
        do {
            try buildEngine(on: initialRecord)
        } catch {
            let shouldReport = box.withLock { state -> Bool in
                guard state.phase != .finished else { return false }
                _ = state.finalize(discard: true)
                return true
            }
            if shouldReport { onEvent(.startFailed(Self.describe(error, device: initialRecord.device))) }
            return
        }
        // Stopped, canceled or timed out while a slow device was starting.
        guard box.withLock({ $0.phase != .finished }) else { return teardownEngineOnQueue() }
        isRunning = true
        startWatchdog()
    }

    private func checkFirstBuffer() {
        let timedOut: String? = box.withLock { state in
            guard state.phase != .finished, state.firstArrival == nil else { return nil }
            _ = state.finalize(discard: true)
            return state.device.name
        }
        guard let name = timedOut else { return }
        Log.audio.error("No audio from \(name, privacy: .public) within the start timeout")
        onEvent(.noAudio("No audio from \(name) after \(Int(options.firstBufferTimeout)) seconds"))
        control.async { self.shutdownOnQueue() }
    }

    private func buildEngine(on record: CoreAudioHAL.InputRecord) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Only redirect the input unit when the device isn't already the system default.
        if record.audioID != CoreAudioHAL.defaultInputDeviceID() {
            guard let unit = input.audioUnit else { throw CaptureFailure.cannotSelectDevice(noErr) }
            var id = record.audioID
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw CaptureFailure.cannotSelectDevice(status) }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureFailure.noFormat }

        // `format: nil` taps whatever the hardware delivers; the resampler adapts to each buffer's format.
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil, block: makeTapBlock())
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureFailure.startFailed(error as NSError)
        }
        self.engine = engine
        box.withLock {
            $0.device = record.device
            $0.isLive = true
        }
        observe(engine, deviceID: record.audioID)
    }

    private func teardownEngineOnQueue() {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        deviceListeners?.invalidate()
        deviceListeners = nil
    }

    private func shutdownOnQueue() {
        isRunning = false
        watchdog?.cancel()
        watchdog = nil
        teardownEngineOnQueue()
    }

    private func observe(_ engine: AVAudioEngine, deviceID: AudioDeviceID) {
        // Posted after the engine has already stopped itself (format change, AirPods profile switch...).
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.scheduleRebuild()
        }
        let listeners = HALListenerSet(queue: listenerQueue)
        listeners.add(deviceID, kAudioDevicePropertyDeviceIsAlive) { [weak self] in
            self?.scheduleRebuild()
        }
        deviceListeners = listeners
    }

    /// Coalesces bursts of change notifications into one rebuild.
    private func scheduleRebuild() {
        control.async {
            guard self.isRunning, !self.rebuildScheduled else { return }
            self.rebuildScheduled = true
            self.control.asyncAfter(deadline: .now() + 0.05) {
                self.rebuildScheduled = false
                self.rebuildOnQueue(force: false)
            }
        }
    }

    /// Rebuilds the engine on the device the policy picks now and keeps appending to the same recording.
    /// Unforced rebuilds (notifications) are skipped while the engine still runs on a live device, so
    /// spurious notifications and default-device changes never interrupt a dictation.
    private func rebuildOnQueue(force: Bool) {
        guard isRunning, box.withLock({ $0.phase != .finished }) else { return }
        if !force, let engine, engine.isRunning,
           let id = CoreAudioHAL.deviceID(forUID: box.withLock({ $0.device.id })), CoreAudioHAL.isAlive(id) {
            return
        }
        let now = AudioClock.now()
        rebuildTimes = rebuildTimes.filter { now - $0 < options.rebuildWindow } + [now]
        guard rebuildTimes.count <= options.maxRebuilds else { return loseDevice() }

        let previous = box.withLock { $0.device }
        teardownEngineOnQueue()
        lastRebuildAt = now

        let records = CoreAudioHAL.inputRecords()
        guard let choice = InputDevicePolicy.choose(preferredUID: options.preferredUID,
                                                    defaultUID: CoreAudioHAL.defaultInputUID(),
                                                    devices: records.map(\.device),
                                                    preferBuiltInOverBluetooth: options.preferBuiltInOverBluetooth),
              let record = records.first(where: { $0.device.id == choice.device.id })
        else { return loseDevice() }

        do {
            try buildEngine(on: record)
            Log.audio.info("Capture rebuilt on \(record.device.name, privacy: .public)")
            if record.device.id != previous.id { onEvent(.switchedDevice(record.device)) }
        } catch {
            Log.audio.error("Capture rebuild failed: \(String(describing: error), privacy: .public)")
            box.withLock { $0.isLive = false }
            // Usually transient while a route settles; retry until the rebuild budget runs out.
            control.asyncAfter(deadline: .now() + 0.3) { self.rebuildOnQueue(force: true) }
        }
    }

    private func loseDevice() {
        Log.audio.error("Capture lost its device")
        watchdog?.cancel()
        watchdog = nil
        teardownEngineOnQueue()
        isRunning = false
        let pending = box.withLock { state -> ((@Sendable ([Float]) -> Void), [Float])? in
            state.isLive = false
            guard let completion = state.tailCompletion else { return nil }
            state.tailCompletion = nil
            return (completion, state.finalize(discard: false))
        }
        if let (completion, samples) = pending { completion(samples) }
        onEvent(.deviceLost)
    }

    private func completeTailOnQueue() {
        let pending = box.withLock { state -> ((@Sendable ([Float]) -> Void), [Float])? in
            guard case .tail = state.phase, let completion = state.tailCompletion else { return nil }
            state.tailCompletion = nil
            return (completion, state.finalize(discard: false))
        }
        guard let (completion, samples) = pending else { return }
        completion(samples)
        shutdownOnQueue()
    }

    /// Detects a device that never delivers audio (start timeout) or stops delivering it (stall).
    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        timer.resume()
        watchdog = timer
    }

    private func watchdogTick() {
        guard isRunning else { return }
        let (phase, lastArrival) = box.withLock { ($0.phase, $0.lastArrival) }
        // Before the first buffer, `checkFirstBuffer` owns the timeout.
        guard phase != .finished, let lastArrival else { return }
        let silentFor = AudioClock.now() - max(lastArrival, lastRebuildAt)
        if silentFor > options.stallTimeout {
            Log.audio.info("Capture stalled for \(silentFor, format: .fixed(precision: 2)) s; rebuilding")
            rebuildOnQueue(force: true)
        }
    }

    // MARK: Tap (AVAudioEngine's thread)

    private func makeTapBlock() -> AVAudioNodeTapBlock {
        { [weak self] buffer, when in
            let rate = buffer.format.sampleRate
            guard let self, buffer.frameLength > 0, rate > 0 else { return }
            let arrival = AudioClock.now()
            let chunkStart = when.isHostTimeValid
                ? AudioClock.seconds(hostTime: when.hostTime)
                : arrival - Double(buffer.frameLength) / rate
            self.receive(buffer, chunkStart: chunkStart, arrival: arrival)
        }
    }

    /// Everything the tap does with one buffer (callable directly with synthetic buffers).
    func receive(_ buffer: AVAudioPCMBuffer, chunkStart: TimeInterval, arrival: TimeInterval) {
        let outcome = box.withLock { state in
            state.ingest(buffer, chunkStart: chunkStart, arrival: arrival)
        }
        if outcome.isFirstBuffer { onEvent(.firstBuffer) }
        if let meter, !outcome.levels.isEmpty {
            for point in outcome.levels { meter.ingest(rmsDBFS: point.db, at: point.time) }
        }
        if let completion = outcome.tailCompletion {
            completion(outcome.finalSamples)
            control.async { self.shutdownOnQueue() }
        }
    }

    private static func describe(_ error: any Error, device: AudioInputDevice) -> String {
        switch error {
        case CaptureFailure.cannotSelectDevice(let status): "Couldn't select \(device.name) (\(status))"
        case CaptureFailure.noFormat: "\(device.name) reported no audio format"
        case CaptureFailure.startFailed(let underlying): "\(device.name) didn't start (\(underlying.code))"
        default: "\(device.name): \(error.localizedDescription)"
        }
    }
}

enum CaptureFailure: Error {
    case cannotSelectDevice(OSStatus)
    case noFormat
    case startFailed(NSError)
}

struct DuckWindow: Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var gain: Float
    /// Short linear ramps so the attenuation itself doesn't click.
    static let ramp: TimeInterval = 0.005

    func gain(at time: TimeInterval) -> Float {
        if time <= start - Self.ramp || time >= end + Self.ramp { return 1 }
        if time >= start, time <= end { return gain }
        let distance = time < start ? start - time : time - end
        let f = Float(distance / Self.ramp)
        return gain + (1 - gain) * f
    }
}

// MARK: - Lock-protected capture state

/// NSLock box rather than `Mutex`: region isolation refuses to move the non-Sendable tap buffer into a
/// Mutex's `inout sending` state.
final class CaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state: CaptureState

    init(device: AudioInputDevice, keepsSamples: Bool) {
        state = CaptureState(device: device, keepsSamples: keepsSamples)
    }

    func withLock<R>(_ body: (inout CaptureState) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

struct CaptureState {
    enum Phase: Equatable {
        case capturing
        /// Stop requested: keep appending until audio reaches `until`, then finalize.
        case tail(until: TimeInterval)
        case finished
    }

    struct IngestOutcome {
        var isFirstBuffer = false
        var levels: [(time: TimeInterval, db: Float)] = []
        var tailCompletion: (@Sendable ([Float]) -> Void)?
        var finalSamples: [Float] = []
    }

    static let outputRate = Recording.sampleRate
    static let levelWindow = Int(Recording.sampleRate / 100)

    var device: AudioInputDevice
    let keepsSamples: Bool
    var phase: Phase = .capturing
    /// An engine is delivering (or starting to deliver) audio.
    var isLive = true
    var feedsMeter = true
    var samples: [Float] = []
    var resampler = StreamingResampler(targetSampleRate: Recording.sampleRate)
    var firstArrival: TimeInterval?
    var lastArrival: TimeInterval?
    var tailCompletion: (@Sendable ([Float]) -> Void)?
    /// Output frames produced since the session began (monitoring discards them, this keeps counting).
    private(set) var totalFrames = 0
    private var ducks: [DuckWindow] = []
    /// Starts of continuous stretches of capture: (global output frame, capture time). Output frame `g`
    /// was captured at `anchor.time + (g - anchor.index) / 16 kHz` for the latest anchor at or before `g`.
    private var anchors = AudioRing<(index: Int, time: TimeInterval)>(capacity: 64)
    private var expectedChunkStart: TimeInterval?
    private var levelSum: Float = 0
    private var levelCount = 0

    init(device: AudioInputDevice, keepsSamples: Bool) {
        self.device = device
        self.keepsSamples = keepsSamples
        if keepsSamples { samples.reserveCapacity(Int(Self.outputRate) * 60) }
    }

    /// Global frame index of `samples[0]`.
    private var samplesBase: Int { totalFrames - samples.count }

    mutating func ingest(_ buffer: AVAudioPCMBuffer, chunkStart: TimeInterval, arrival: TimeInterval) -> IngestOutcome {
        var outcome = IngestOutcome()
        guard phase != .finished else { return outcome }
        if firstArrival == nil {
            firstArrival = arrival
            outcome.isFirstBuffer = true
        }
        lastArrival = arrival

        let rate = buffer.format.sampleRate
        var input: AVAudioPCMBuffer? = buffer
        var reachedTail = false
        if case .tail(let until) = phase, chunkStart + Double(buffer.frameLength) / rate >= until {
            reachedTail = true
            let keep = AVAudioFrameCount(max(0, min(Double(buffer.frameLength), ((until - chunkStart) * rate).rounded())))
            input = keep > 0 ? Self.prefix(of: buffer, frames: keep) : nil
        }

        let firstNew = totalFrames
        if let input {
            // A new device format ends the previous stretch: drain it before timing the new one.
            let formatChanged = !resampler.isConfigured(for: input.format)
            if formatChanged { appendOutput { try $0.flush(into: &$1) } }
            if formatChanged || expectedChunkStart.map({ abs(chunkStart - $0) > 0.004 }) ?? true {
                anchors.append((totalFrames, chunkStart))
            }
            expectedChunkStart = chunkStart + Double(input.frameLength) / rate
            appendOutput { try $0.process(input, into: &$1) }
        }

        if totalFrames > firstNew {
            let range = firstNew..<totalFrames
            for window in ducks where overlaps(window, range) { apply(window, globalRange: range) }
            let chunkTime = time(ofFrame: firstNew)
            ducks.removeAll { $0.end + 1 < chunkTime }
            if feedsMeter { outcome.levels = meterPoints(globalRange: range) }
        }
        if !keepsSamples { samples.removeAll(keepingCapacity: true) }

        if reachedTail {
            outcome.tailCompletion = tailCompletion
            tailCompletion = nil
            outcome.finalSamples = finalize(discard: false)
        }
        return outcome
    }

    /// Flushes the converter and hands over the samples; the state accepts no more audio afterwards.
    mutating func finalize(discard: Bool) -> [Float] {
        guard phase != .finished else { return [] }
        phase = .finished
        isLive = false
        if !discard, keepsSamples { appendOutput { try $0.flush(into: &$1) } }
        resampler.reset()
        let result = discard || !keepsSamples ? [] : samples
        samples = []
        ducks.removeAll()
        anchors.removeAll()
        return result
    }

    mutating func addDuck(_ window: DuckWindow) {
        guard phase != .finished else { return }
        ducks.append(window)
        // The sound may already be in captured audio (the caller was late): duck retroactively.
        if keepsSamples, !samples.isEmpty { apply(window, globalRange: samplesBase..<totalFrames) }
    }

    /// Capture time of global output frame `frame`.
    func time(ofFrame frame: Int) -> TimeInterval {
        guard anchors.count > 0 else { return 0 }
        var anchor = anchors[0]
        for k in stride(from: anchors.count - 1, through: 0, by: -1) where anchors[k].index <= frame {
            anchor = anchors[k]
            break
        }
        return anchor.time + Double(frame - anchor.index) / Self.outputRate
    }

    // MARK: Private

    private mutating func appendOutput(_ body: (StreamingResampler, inout [Float]) throws -> Void) {
        let before = samples.count
        do {
            try body(resampler, &samples)
        } catch {
            Log.audio.error("Dropped an audio chunk the converter rejected")
        }
        totalFrames += samples.count - before
    }

    private func overlaps(_ window: DuckWindow, _ range: Range<Int>) -> Bool {
        window.start - DuckWindow.ramp < time(ofFrame: range.upperBound)
            && window.end + DuckWindow.ramp > time(ofFrame: range.lowerBound)
    }

    /// Touches only the frames the window covers, segment by segment.
    private mutating func apply(_ window: DuckWindow, globalRange: Range<Int>) {
        let base = samplesBase
        let rate = Self.outputRate
        for k in 0..<anchors.count {
            let anchor = anchors[k]
            let segmentEnd = k + 1 < anchors.count ? anchors[k + 1].index : totalFrames
            let first = anchor.index + Int(((window.start - DuckWindow.ramp - anchor.time) * rate).rounded(.down))
            let last = anchor.index + Int(((window.end + DuckWindow.ramp - anchor.time) * rate).rounded(.up))
            let lower = max(first, anchor.index, globalRange.lowerBound, base)
            let upper = min(last, segmentEnd, globalRange.upperBound)
            guard lower < upper else { continue }
            for frame in lower..<upper {
                let gain = window.gain(at: anchor.time + Double(frame - anchor.index) / rate)
                if gain < 1 { samples[frame - base] *= gain }
            }
        }
    }

    /// RMS per 10 ms of output audio, carried across chunk boundaries, stamped with capture time.
    private mutating func meterPoints(globalRange: Range<Int>) -> [(time: TimeInterval, db: Float)] {
        var points: [(time: TimeInterval, db: Float)] = []
        points.reserveCapacity(globalRange.count / Self.levelWindow + 1)
        let base = samplesBase
        for frame in globalRange {
            let x = samples[frame - base]
            levelSum += x * x
            levelCount += 1
            if levelCount == Self.levelWindow {
                let rms = (levelSum / Float(levelCount)).squareRoot()
                points.append((time(ofFrame: frame + 1), rms > 1e-8 ? 20 * log10(rms) : -160))
                levelSum = 0
                levelCount = 0
            }
        }
        return points
    }

    /// A copy of the first `frames` frames (the tap's own buffer is not ours to shorten).
    static func prefix(of buffer: AVAudioPCMBuffer, frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        frames < buffer.frameLength ? buffer.copyFrames(0..<frames) : buffer
    }
}
