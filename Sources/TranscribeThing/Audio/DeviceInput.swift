import AVFAudio
import CoreAudio
import Foundation
import Synchronization

/// Why an open input asks its session to look again.
enum CaptureInputChange: Sendable, Equatable {
    /// The device's alive flag changed: reopen only if it really went away.
    case device
    /// The device's rate or channels changed under the open input: reopen to read the new format.
    case format
}

/// Where a capture session's audio comes from: exactly one device, opened by its HAL id. An implementation never
/// opens, binds or starts any other device (the system default input included). Driven from the session's control
/// queue.
protocol CaptureInput: AnyObject {
    /// Opens `device` and starts delivering buffers, in order on one background thread, each with the `AudioClock`
    /// time its first frame was captured. Throws `CaptureFailure`.
    func start(device: AudioDeviceID, deliver: @escaping @Sendable (AVAudioPCMBuffer, TimeInterval) -> Void,
               onChange: @escaping @Sendable (CaptureInputChange) -> Void) throws
    /// Stops IO; nothing is delivered once this returns.
    func stop()
    var isRunning: Bool { get }
}

/// Captures from one device through a HAL IOProc registered on that device's id.
///
/// Unlike `AVAudioEngine` (whose input node starts out on the system default input) or an AUHAL (created bound to
/// the default output), an IOProc involves no other device at any point: with AirPods as the macOS default, opening
/// the built-in mic never wakes their microphone, so they stay in their playback profile and nothing stutters.
///
/// The IO thread runs in realtime: it only copies each cycle into a preallocated `HALCaptureRing` slot and signals
/// `delivery`, with no allocation or lock. Fresh buffers, resampling, metering and locking all happen on `delivery`.
final class HALDeviceInput: CaptureInput, @unchecked Sendable {
    private let delivery = DispatchQueue(label: "dev.transcribe-thing.audio.capture.input", qos: .userInitiated)
    // Control-queue state.
    private var device = AudioDeviceID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var listeners: HALListenerSet?
    private var wakeup: DispatchSourceUserDataAdd?
    private(set) var isRunning = false
    /// Delivery-queue state: false once `stop` ran, so a late IO cycle never reaches the session.
    private var delivers = false

    func start(device: AudioDeviceID, deliver: @escaping @Sendable (AVAudioPCMBuffer, TimeInterval) -> Void,
               onChange: @escaping @Sendable (CaptureInputChange) -> Void) throws {
        guard let layout = HALInputLayout(device: device),
              let ring = HALCaptureRing(layout: layout, slotFrames: Self.bufferFrameSize(device))
        else { throw CaptureFailure.noFormat }

        // Listening before the device starts: starting a Bluetooth input can switch its profile, and so its rate,
        // while `AudioDeviceStart` blocks; a change that early must still reach the session.
        // Only a real change reopens: a notification that leaves the layout as it was (some devices post one as
        // IO starts) must not start a reopen loop.
        let formatChanged: @Sendable () -> Void = {
            if HALInputLayout(device: device) != layout { onChange(.format) }
        }
        let set = HALListenerSet(queue: delivery)
        set.add(device, kAudioDevicePropertyDeviceIsAlive) { onChange(.device) }
        set.add(device, kAudioDevicePropertyNominalSampleRate, handler: formatChanged)
        set.add(device, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput,
                handler: formatChanged)
        for stream in CoreAudioHAL.inputStreamIDs(device) {
            set.add(stream, kAudioStreamPropertyVirtualFormat, handler: formatChanged)
        }

        let wakeup = DispatchSource.makeUserDataAddSource(queue: delivery)
        wakeup.setEventHandler { [weak self] in
            guard let self, self.delivers else { return }
            ring.drain(deliver)
            let dropped = ring.takeDroppedCycles()
            if dropped > 0 { Log.audio.error("Capture dropped \(dropped) IO cycles: delivery fell behind") }
        }
        wakeup.activate()

        var procID: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, input, inputTime, _, _ in
            let time = inputTime.pointee
            let chunkStart = time.mFlags.contains(.hostTimeValid)
                ? AudioClock.seconds(hostTime: time.mHostTime)
                : AudioClock.now() - Double(layout.frameCount(input)) / layout.sampleRate
            if ring.write(input, chunkStart: chunkStart) { wakeup.add(data: 1) }
        }
        guard created == noErr, let procID else {
            set.invalidate()
            wakeup.cancel()
            throw CaptureFailure.cannotSelectDevice(created)
        }
        delivery.sync { delivers = true }
        let started = AudioDeviceStart(device, procID)
        guard started == noErr else {
            delivery.sync { delivers = false }
            set.invalidate()
            AudioDeviceDestroyIOProcID(device, procID)
            wakeup.cancel()
            throw CaptureFailure.startFailed(NSError(domain: NSOSStatusErrorDomain, code: Int(started)))
        }
        self.device = device
        self.procID = procID
        self.wakeup = wakeup
        listeners = set
        isRunning = true

        // Every buffer is stamped with `layout`: if the device changed format between reading it and starting
        // (whether or not a listener saw it), reopen with the new one.
        if HALInputLayout(device: device) != layout {
            Log.audio.info("Capture input changed format while starting; reopening")
            delivery.async(execute: formatChanged)
        }
    }

    func stop() {
        listeners?.invalidate()
        listeners = nil
        delivery.sync { delivers = false }
        if let procID {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
        }
        wakeup?.cancel()
        wakeup = nil
        procID = nil
        isRunning = false
    }

    /// A safety net only (the session always calls `stop`); no `delivery.sync` here, since the last reference can
    /// go away on `delivery` itself.
    deinit {
        listeners?.invalidate()
        if let procID {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
        }
        wakeup?.cancel()
    }

    /// Frames per IO cycle the device runs at now (a slot's size; longer cycles span several slots).
    private static func bufferFrameSize(_ device: AudioDeviceID) -> Int {
        var frames: UInt32 = 0
        guard CoreAudioHAL.read(device, kAudioDevicePropertyBufferFrameSize, into: &frames), frames > 0 else { return 512 }
        return Int(frames)
    }
}

/// Preallocated slots between the realtime IO thread (the one producer) and `delivery` (the one consumer). A write
/// only copies samples and publishes an index, with no allocation or lock; `drain` turns each slot into a fresh
/// buffer for the session, which may keep it.
final class HALCaptureRing: @unchecked Sendable {
    let layout: HALInputLayout
    let slotFrames: Int
    let slotCount: Int
    /// Per slot, one pointer per channel into `samples`.
    private let channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let samples: UnsafeMutablePointer<Float>
    private let frames: UnsafeMutablePointer<Int>
    private let times: UnsafeMutablePointer<TimeInterval>
    /// Slots written and slots drained since the start; the ring holds `written - drained` of them.
    private let written = Atomic<Int>(0)
    private let drained = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)

    /// `slotFrames` is clamped to 64...4096, and there are enough slots for about a second of audio (64 at least),
    /// so `delivery` can stall that long before cycles are dropped.
    init?(layout: HALInputLayout, slotFrames: Int, slotCount: Int? = nil) {
        let slotFrames = min(max(slotFrames, 64), 4_096)
        let count = slotCount ?? max(64, Int((layout.format.sampleRate / Double(slotFrames)).rounded(.up)))
        guard count > 0 else { return nil }
        self.layout = layout
        self.slotFrames = slotFrames
        self.slotCount = count
        let channelCount = Int(layout.format.channelCount)
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: count * channelCount * slotFrames)
        samples.initialize(repeating: 0, count: count * channelCount * slotFrames)
        self.samples = samples
        channels = .allocate(capacity: count * channelCount)
        channels.initialize(from: (0..<(count * channelCount)).map { samples + $0 * slotFrames },
                            count: count * channelCount)
        frames = .allocate(capacity: count)
        frames.initialize(repeating: 0, count: count)
        times = .allocate(capacity: count)
        times.initialize(repeating: 0, count: count)
    }

    deinit {
        samples.deallocate()
        channels.deallocate()
        frames.deallocate()
        times.deallocate()
    }

    /// IO thread. Copies one cycle, split across slots when it is longer than one; `chunkStart` is when its first
    /// frame was captured. False when nothing was written; a full ring (`delivery` a second behind) drops the rest
    /// of the cycle and counts it.
    @discardableResult
    func write(_ input: UnsafePointer<AudioBufferList>, chunkStart: TimeInterval) -> Bool {
        let total = layout.frameCount(input)
        guard total > 0 else { return false }
        let channelCount = layout.channelCount
        var index = written.load(ordering: .relaxed)
        var offset = 0
        while offset < total {
            guard index - drained.load(ordering: .acquiring) < slotCount else {
                dropped.add(1, ordering: .relaxed)
                break
            }
            let slot = index % slotCount
            let count = min(slotFrames, total - offset)
            layout.copy(input, from: offset, count: count,
                        into: UnsafeBufferPointer(start: channels + slot * channelCount, count: channelCount))
            frames[slot] = count
            times[slot] = chunkStart + Double(offset) / layout.sampleRate
            index += 1
            written.store(index, ordering: .releasing)
            offset += count
        }
        return offset > 0
    }

    /// Delivery queue: every slot written so far, oldest first, as a fresh buffer with its capture time.
    func drain(_ body: (AVAudioPCMBuffer, TimeInterval) -> Void) {
        let channelCount = Int(layout.format.channelCount)
        var index = drained.load(ordering: .relaxed)
        let end = written.load(ordering: .acquiring)
        while index < end {
            let slot = index % slotCount
            let count = frames[slot]
            let time = times[slot]
            let buffer = AVAudioPCMBuffer(pcmFormat: layout.format, frameCapacity: AVAudioFrameCount(count))
            if let buffer, let out = buffer.floatChannelData {
                for c in 0..<channelCount {
                    out[c].update(from: channels[slot * channelCount + c], count: count)
                }
                buffer.frameLength = AVAudioFrameCount(count)
            }
            index += 1
            drained.store(index, ordering: .releasing)
            if let buffer { body(buffer, time) }
        }
    }

    /// Cycles (or parts of cycles) dropped on a full ring since the last call.
    func takeDroppedCycles() -> Int {
        dropped.exchange(0, ordering: .relaxed)
    }
}

/// The Float32 channels an input device delivers each IO cycle, and the non-interleaved buffer they are copied into
/// (mono or stereo at the device's rate, the formats the engine tap delivered: `StreamingResampler` mixes them down
/// as before).
struct HALInputLayout: Equatable, @unchecked Sendable {
    let format: AVAudioFormat
    /// `format`'s rate and channels as plain values, for the IO thread (no Objective-C there).
    let sampleRate: Double
    let channelCount: Int

    /// Reads the device's input streams; nil when there are none or one isn't 32-bit float (a device another app
    /// holds in hog mode with an integer format, say).
    init?(device: AudioDeviceID) {
        var formats: [AudioStreamBasicDescription] = []
        for stream in CoreAudioHAL.inputStreamIDs(device) {
            var asbd = AudioStreamBasicDescription()
            guard CoreAudioHAL.read(stream, kAudioStreamPropertyVirtualFormat, into: &asbd) else { return nil }
            formats.append(asbd)
        }
        self.init(streams: formats)
    }

    init?(streams: [AudioStreamBasicDescription]) {
        guard let rate = streams.first?.mSampleRate, rate > 0,
              streams.allSatisfy({ $0.mFormatID == kAudioFormatLinearPCM && $0.mBitsPerChannel == 32
                  && $0.mFormatFlags & kAudioFormatFlagIsFloat != 0 })
        else { return nil }
        // Wider interfaces keep their first two inputs, where a mic almost always sits: the converter can't mix a
        // discrete multichannel layout down to mono, and averaging many mostly silent channels would bury the voice.
        let channels = min(2, streams.reduce(0) { $0 + Int($1.mChannelsPerFrame) })
        guard channels > 0, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                                       channels: AVAudioChannelCount(channels), interleaved: false)
        else { return nil }
        self.format = format
        sampleRate = rate
        channelCount = channels
    }

    /// Same rate and channels: buffers stamped with one describe the other's audio correctly.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sampleRate == rhs.sampleRate && lhs.channelCount == rhs.channelCount
    }

    /// Frames in one IO cycle's input (the shortest stream's). Realtime-safe.
    func frameCount(_ input: UnsafePointer<AudioBufferList>) -> Int {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var frames = Int.max
        for source in list where source.mNumberChannels > 0 && source.mData != nil {
            frames = min(frames, Int(source.mDataByteSize) / (MemoryLayout<Float>.size * Int(source.mNumberChannels)))
        }
        return frames == .max ? 0 : frames
    }

    /// Deinterleaves frames `start..<start+count` of one IO cycle (one interleaved buffer per stream) into
    /// `destination`, one pointer per channel. Realtime-safe: no allocation, no Objective-C.
    func copy(_ input: UnsafePointer<AudioBufferList>, from start: Int, count: Int,
              into destination: UnsafeBufferPointer<UnsafeMutablePointer<Float>>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let channelCount = destination.count
        var channel = 0
        for source in list where source.mNumberChannels > 0 {
            let stride = Int(source.mNumberChannels)
            guard let data = source.mData?.assumingMemoryBound(to: Float.self) else {
                channel += stride
                continue
            }
            for c in 0..<stride where channel + c < channelCount {
                let out = destination[channel + c]
                for f in 0..<count { out[f] = data[(start + f) * stride + c] }
            }
            channel += stride
        }
        // Channels a cycle didn't carry (a stream switched off) stay silent rather than stale.
        while channel < channelCount {
            destination[channel].update(repeating: 0, count: count)
            channel += 1
        }
    }

    /// One IO cycle's input as a fresh non-interleaved buffer (allocates: not for the IO thread).
    func buffer(copying input: UnsafePointer<AudioBufferList>) -> AVAudioPCMBuffer? {
        let frames = frameCount(input)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData else { return nil }
        copy(input, from: 0, count: frames,
             into: UnsafeBufferPointer(start: out, count: Int(format.channelCount)))
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }
}
