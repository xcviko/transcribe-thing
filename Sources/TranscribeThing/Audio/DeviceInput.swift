import AVFAudio
import CoreAudio
import Foundation

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
/// The IO thread only copies each cycle into a fresh buffer; resampling, metering and locking happen on `delivery`.
final class HALDeviceInput: CaptureInput, @unchecked Sendable {
    private let delivery = DispatchQueue(label: "dev.transcribe-thing.audio.capture.input", qos: .userInitiated)
    // Control-queue state.
    private var device = AudioDeviceID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var listeners: HALListenerSet?
    private(set) var isRunning = false
    /// Delivery-queue state: false once `stop` ran, so a late IO cycle never reaches the session.
    private var delivers = false

    func start(device: AudioDeviceID, deliver: @escaping @Sendable (AVAudioPCMBuffer, TimeInterval) -> Void,
               onChange: @escaping @Sendable (CaptureInputChange) -> Void) throws {
        guard let layout = HALInputLayout(device: device) else { throw CaptureFailure.noFormat }
        let delivery = delivery
        var procID: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { [weak self] _, input, inputTime, _, _ in
            guard let buffer = layout.buffer(copying: input) else { return }
            let time = inputTime.pointee
            let chunkStart = time.mFlags.contains(.hostTimeValid)
                ? AudioClock.seconds(hostTime: time.mHostTime)
                : AudioClock.now() - Double(buffer.frameLength) / layout.format.sampleRate
            delivery.async {
                guard let self, self.delivers else { return }
                deliver(buffer, chunkStart)
            }
        }
        guard created == noErr, let procID else { throw CaptureFailure.cannotSelectDevice(created) }
        delivery.sync { delivers = true }
        let started = AudioDeviceStart(device, procID)
        guard started == noErr else {
            delivery.sync { delivers = false }
            AudioDeviceDestroyIOProcID(device, procID)
            throw CaptureFailure.startFailed(NSError(domain: NSOSStatusErrorDomain, code: Int(started)))
        }
        self.device = device
        self.procID = procID
        isRunning = true

        let set = HALListenerSet(queue: delivery)
        set.add(device, kAudioDevicePropertyDeviceIsAlive) { onChange(.device) }
        set.add(device, kAudioDevicePropertyNominalSampleRate) { onChange(.format) }
        set.add(device, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput) { onChange(.format) }
        listeners = set
    }

    func stop() {
        listeners?.invalidate()
        listeners = nil
        delivery.sync { delivers = false }
        if let procID {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
        }
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
    }
}

/// The Float32 channels an input device delivers each IO cycle, and the non-interleaved buffer they are copied into
/// (mono or stereo at the device's rate, the formats the engine tap delivered: `StreamingResampler` mixes them down
/// as before).
struct HALInputLayout: @unchecked Sendable {
    let format: AVAudioFormat

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
    }

    /// One IO cycle's input (one interleaved buffer per stream) as a fresh non-interleaved buffer. Runs on the IO
    /// thread.
    func buffer(copying input: UnsafePointer<AudioBufferList>) -> AVAudioPCMBuffer? {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let frames = list.lazy
            .filter { $0.mNumberChannels > 0 && $0.mData != nil }
            .map { Int($0.mDataByteSize) / (MemoryLayout<Float>.size * Int($0.mNumberChannels)) }
            .min() ?? 0
        let channelCount = Int(format.channelCount)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData else { return nil }
        var channel = 0
        for source in list where source.mNumberChannels > 0 {
            let stride = Int(source.mNumberChannels)
            guard let data = source.mData?.assumingMemoryBound(to: Float.self) else {
                channel += stride
                continue
            }
            for c in 0..<stride where channel + c < channelCount {
                let destination = out[channel + c]
                for f in 0..<frames { destination[f] = data[f * stride + c] }
            }
            channel += stride
        }
        // Channels a cycle didn't carry (a stream switched off) stay silent rather than uninitialized.
        while channel < channelCount {
            out[channel].update(repeating: 0, count: frames)
            channel += 1
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }
}
