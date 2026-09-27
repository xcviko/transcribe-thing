import AVFAudio
import CoreAudio
import Foundation
import Testing
@testable import TranscribeThing

// Capture opens exactly the chosen device. Driven through `CaptureSession.Hardware` with a fake input and a fake
// device list: no microphone is opened here.

/// Stands in for `HALDeviceInput`: remembers which device ids it was asked to open and lets the test push audio
/// and change notifications.
private final class FakeInput: CaptureInput, @unchecked Sendable {
    private let lock = NSLock()
    private var deliver: (@Sendable (AVAudioPCMBuffer, TimeInterval) -> Void)?
    private var onChange: (@Sendable (CaptureInputChange) -> Void)?
    private var running = false
    private(set) var device: AudioDeviceID?
    var failure: CaptureFailure?

    func start(device: AudioDeviceID, deliver: @escaping @Sendable (AVAudioPCMBuffer, TimeInterval) -> Void,
               onChange: @escaping @Sendable (CaptureInputChange) -> Void) throws {
        if let failure { throw failure }
        lock.withLock {
            self.device = device
            self.deliver = deliver
            self.onChange = onChange
            running = true
        }
    }

    func stop() {
        lock.withLock {
            running = false
            deliver = nil
        }
    }

    var isRunning: Bool { lock.withLock { running } }

    func push(seconds: Double = 0.1, at time: TimeInterval) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = 0.3 * Float(sin(Double(i) * 0.04)) }
        buffer.frameLength = frames
        lock.withLock { deliver }?(buffer, time)
    }

    func change(_ change: CaptureInputChange) { lock.withLock { onChange }?(change) }
}

/// The HAL as the session sees it: a device list, the default input, and every input the session created.
private final class FakeHAL: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [CoreAudioHAL.InputRecord]
    private var defaultID: AudioDeviceID?
    private var created: [FakeInput] = []
    var nextFailure: CaptureFailure?

    init(records: [CoreAudioHAL.InputRecord], defaultID: AudioDeviceID?) {
        self.records = records
        self.defaultID = defaultID
    }

    var inputs: [FakeInput] { lock.withLock { created } }
    /// Every device id any input was opened on, in order.
    var opened: [AudioDeviceID] { inputs.compactMap(\.device) }

    func remove(_ id: AudioDeviceID) { lock.withLock { records.removeAll { $0.audioID == id } } }

    var hardware: CaptureSession.Hardware {
        CaptureSession.Hardware(
            inputRecords: { self.lock.withLock { self.records } },
            defaultInputID: { self.lock.withLock { self.defaultID } },
            isAlive: { id in self.lock.withLock { self.records.contains { $0.audioID == id } } },
            processInputDeviceIDs: { self.inputs.filter(\.isRunning).compactMap(\.device) },
            makeInput: {
                let input = FakeInput()
                self.lock.withLock {
                    input.failure = self.nextFailure
                    self.created.append(input)
                }
                return input
            })
    }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [CaptureSessionEvent] = []
    func record(_ event: CaptureSessionEvent) { lock.withLock { list.append(event) } }
    var names: [String] {
        lock.withLock { list }.map {
            switch $0 {
            case .firstBuffer: "firstBuffer"
            case .switchedDevice(let device): "switchedDevice(\(device.id))"
            case .deviceLost: "deviceLost"
            case .startFailed: "startFailed"
            case .noAudio: "noAudio"
            }
        }
    }
}

@Suite struct PinnedCaptureTests {
    private static let builtIn = CoreAudioHAL.InputRecord(
        device: AudioInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn,
                                 isAvailable: true), audioID: 91)
    private static let airPods = CoreAudioHAL.InputRecord(
        device: AudioInputDevice(id: "airpods:input", name: "AirPods Pro", transport: .bluetooth, isAvailable: true),
        audioID: 120)

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func session(_ hal: FakeHAL, record: CoreAudioHAL.InputRecord, preferredUID: String?,
                         events: Events) -> CaptureSession {
        var options = CaptureSession.Options(preferredUID: preferredUID)
        options.firstBufferTimeout = 5
        return CaptureSession(device: record, options: options, meter: LevelMeter(), hardware: hal.hardware,
                              onEvent: { events.record($0) })
    }

    /// The user's case: AirPods are the macOS default, the built-in mic is picked. Only the built-in mic is opened,
    /// and it stays the only one across a format change (which used to re-resolve through the default).
    @Test func aPickedMicIsTheOnlyDeviceOpened() async throws {
        let hal = FakeHAL(records: [Self.builtIn, Self.airPods], defaultID: Self.airPods.audioID)
        let events = Events()
        let choice = try #require(InputDevicePolicy.choose(preferredUID: Self.builtIn.device.id,
                                                           defaultUID: Self.airPods.device.id,
                                                           devices: [Self.builtIn.device, Self.airPods.device]))
        #expect(choice == InputDeviceChoice(device: Self.builtIn.device, reason: .selected))

        let capture = session(hal, record: Self.builtIn, preferredUID: Self.builtIn.device.id, events: events)
        capture.start()
        try await waitUntil { hal.inputs.first?.isRunning == true }
        #expect(hal.opened == [Self.builtIn.audioID])

        let t0 = AudioClock.now()
        for k in 0..<3 { hal.inputs[0].push(at: t0 + Double(k) * 0.1) }
        #expect(events.names == ["firstBuffer"])
        #expect(capture.device == Self.builtIn.device)

        hal.inputs[0].change(.format)
        try await waitUntil { hal.inputs.count == 2 }
        try await waitUntil { hal.inputs.last?.isRunning == true }
        #expect(hal.opened == [Self.builtIn.audioID, Self.builtIn.audioID])
        #expect(!hal.inputs[0].isRunning, "the old input is stopped before the new one opens")
        #expect(!hal.opened.contains(Self.airPods.audioID))

        hal.inputs[1].push(at: t0 + 0.3)
        #expect(abs(capture.finishNow(discard: false).count - 6_400) <= 32, "audio keeps growing across the reopen")
        try await waitUntil { hal.inputs.last?.isRunning == false }
        #expect(!events.names.contains { $0.hasPrefix("switchedDevice") })
    }

    /// Alive-flag noise while the picked device still runs doesn't reopen anything.
    @Test func aSpuriousDeviceNotificationKeepsTheOpenInput() async throws {
        let hal = FakeHAL(records: [Self.builtIn, Self.airPods], defaultID: Self.airPods.audioID)
        let capture = session(hal, record: Self.builtIn, preferredUID: Self.builtIn.device.id, events: Events())
        capture.start()
        try await waitUntil { hal.inputs.first?.isRunning == true }
        hal.inputs[0].push(at: AudioClock.now())
        hal.inputs[0].change(.device)
        try await Task.sleep(for: .milliseconds(150))
        #expect(hal.opened == [Self.builtIn.audioID])
        _ = capture.finishNow(discard: true)
    }

    /// Automatic is the default input at start; once that device is gone, the new default takes over.
    @Test func automaticOpensTheDefaultAtStart() async throws {
        let hal = FakeHAL(records: [Self.builtIn, Self.airPods], defaultID: Self.airPods.audioID)
        let choice = try #require(InputDevicePolicy.choose(preferredUID: nil, defaultUID: Self.airPods.device.id,
                                                           devices: [Self.builtIn.device, Self.airPods.device]))
        #expect(choice == InputDeviceChoice(device: Self.airPods.device, reason: .systemDefault))
        let capture = session(hal, record: Self.airPods, preferredUID: nil, events: Events())
        capture.start()
        try await waitUntil { hal.inputs.first?.isRunning == true }
        #expect(hal.opened == [Self.airPods.audioID])
        _ = capture.finishNow(discard: true)
    }

    /// The picked mic unplugged mid-dictation: the existing fallback (default input, `.switchedDevice` so the
    /// recorder can say so) still applies.
    @Test func aPickedMicThatGoesAwayFallsBackToTheDefault() async throws {
        let usb = CoreAudioHAL.InputRecord(
            device: AudioInputDevice(id: "usb", name: "Shure MV7+", transport: .usb, isAvailable: true), audioID: 7)
        let hal = FakeHAL(records: [Self.builtIn, Self.airPods, usb], defaultID: Self.builtIn.audioID)
        let events = Events()
        let capture = session(hal, record: usb, preferredUID: usb.device.id, events: events)
        capture.start()
        try await waitUntil { hal.inputs.first?.isRunning == true }
        hal.inputs[0].push(at: AudioClock.now())
        hal.remove(usb.audioID)
        hal.inputs[0].change(.device)
        try await waitUntil { hal.inputs.count == 2 }
        #expect(hal.opened == [usb.audioID, Self.builtIn.audioID])
        try await waitUntil { events.names.count == 2 }
        #expect(events.names == ["firstBuffer", "switchedDevice(BuiltInMicrophoneDevice)"])
        _ = capture.finishNow(discard: true)
    }

    @Test func aDeviceThatWontOpenReportsStartFailed() async throws {
        let hal = FakeHAL(records: [Self.builtIn], defaultID: Self.builtIn.audioID)
        hal.nextFailure = .startFailed(NSError(domain: NSOSStatusErrorDomain, code: -1))
        let events = Events()
        let capture = session(hal, record: Self.builtIn, preferredUID: Self.builtIn.device.id, events: events)
        capture.start()
        try await waitUntil { !events.names.isEmpty }
        #expect(events.names == ["startFailed"])
        #expect(hal.inputs.count == 1)
        #expect(hal.opened.isEmpty)
    }

    @Test func theInputCheckFlagsTheDefaultOnlyWhenItIsAnotherDevice() {
        let builtIn = Self.builtIn.audioID, airPods = Self.airPods.audioID
        #expect(CaptureSession.inputIsolation(opened: builtIn, defaultInput: airPods, processInputs: [builtIn]) == .isolated)
        #expect(CaptureSession.inputIsolation(opened: builtIn, defaultInput: builtIn, processInputs: [builtIn]) == .isolated)
        #expect(CaptureSession.inputIsolation(opened: builtIn, defaultInput: airPods, processInputs: [builtIn, airPods])
            == .defaultAlsoOpen)
        #expect(CaptureSession.inputIsolation(opened: builtIn, defaultInput: airPods, processInputs: [builtIn, 7])
            == .othersOpen([7]))
        #expect(CaptureSession.inputIsolation(opened: builtIn, defaultInput: airPods, processInputs: []) == .unknown)
    }
}

// MARK: - HAL buffer layout

@Suite struct HALInputLayoutTests {
    private func float32(rate: Double = 48_000, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                    mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
                                    mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    /// Runs `body` with an AudioBufferList holding one interleaved buffer per stream.
    private func withList(_ streams: [[Float]], channels: [Int], _ body: (UnsafePointer<AudioBufferList>) -> Void) {
        let list = AudioBufferList.allocate(maximumBuffers: streams.count)
        defer { free(list.unsafeMutablePointer) }
        var storage = streams.map { data -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: data.count)
            p.initialize(from: data, count: data.count)
            return p
        }
        defer { storage.forEach { $0.deallocate() }; storage.removeAll() }
        for (i, data) in streams.enumerated() {
            list[i] = AudioBuffer(mNumberChannels: UInt32(channels[i]), mDataByteSize: UInt32(data.count * 4),
                                  mData: UnsafeMutableRawPointer(storage[i]))
        }
        body(list.unsafePointer)
    }

    @Test func interleavedStreamsBecomeSeparateChannels() throws {
        let layout = try #require(HALInputLayout(streams: [float32(channels: 1), float32(channels: 1)]))
        #expect(layout.format.channelCount == 2)
        #expect(layout.format.sampleRate == 48_000)
        #expect(!layout.format.isInterleaved)
        withList([[1, 2, 3], [10, 20, 30]], channels: [1, 1]) { list in
            let buffer = layout.buffer(copying: list)
            #expect(buffer?.frameLength == 3)
            let data = buffer!.floatChannelData!
            #expect([data[0][0], data[0][1], data[0][2]] == [1, 2, 3])
            #expect([data[1][0], data[1][1], data[1][2]] == [10, 20, 30])
        }
    }

    /// A multichannel interface keeps its first two inputs.
    @Test func wideInterfacesKeepTheFirstTwoInputs() throws {
        let layout = try #require(HALInputLayout(streams: [float32(channels: 4)]))
        #expect(layout.format.channelCount == 2)
        // Frames (1,-1,7,7), (2,-2,7,7), (3,-3,7,7).
        withList([[1, -1, 7, 7, 2, -2, 7, 7, 3, -3, 7, 7]], channels: [4]) { list in
            let buffer = layout.buffer(copying: list)
            #expect(buffer?.frameLength == 3)
            let data = buffer!.floatChannelData!
            #expect([data[0][0], data[0][1], data[0][2]] == [1, 2, 3])
            #expect([data[1][0], data[1][1], data[1][2]] == [-1, -2, -3])
        }
    }

    /// Buffers are stamped with the layout read before the device started: a rate or channel change means reopen.
    @Test func layoutsCompareByRateAndChannels() throws {
        let mono48 = try #require(HALInputLayout(streams: [float32(channels: 1)]))
        #expect(mono48 == HALInputLayout(streams: [float32(channels: 1)]))
        #expect(mono48 != HALInputLayout(streams: [float32(rate: 24_000, channels: 1)]))
        #expect(mono48 != HALInputLayout(streams: [float32(channels: 2)]))
        #expect(mono48.sampleRate == 48_000)
        #expect(mono48.channelCount == 1)
    }

    // MARK: Ring between the IO thread and delivery

    private func drain(_ ring: HALCaptureRing) -> [(samples: [Float], time: TimeInterval)] {
        var out: [(samples: [Float], time: TimeInterval)] = []
        ring.drain { buffer, time in
            let data = buffer.floatChannelData![0]
            out.append((Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))), time))
        }
        return out
    }

    @Test func ringDeliversCyclesInOrderWithTheirCaptureTimes() throws {
        let layout = try #require(HALInputLayout(streams: [float32(channels: 2)]))
        let ring = try #require(HALCaptureRing(layout: layout, slotFrames: 64, slotCount: 4))
        withList([[1, -1, 2, -2, 3, -3]], channels: [2]) { #expect(ring.write($0, chunkStart: 1.0)) }
        withList([[4, -4, 5, -5]], channels: [2]) { #expect(ring.write($0, chunkStart: 2.0)) }
        var cycles: [([Float], [Float], TimeInterval)] = []
        ring.drain { buffer, time in
            let data = buffer.floatChannelData!
            let n = Int(buffer.frameLength)
            #expect(buffer.format.channelCount == 2)
            cycles.append((Array(UnsafeBufferPointer(start: data[0], count: n)),
                           Array(UnsafeBufferPointer(start: data[1], count: n)), time))
        }
        #expect(cycles.map(\.0) == [[1, 2, 3], [4, 5]])
        #expect(cycles.map(\.1) == [[-1, -2, -3], [-4, -5]])
        #expect(cycles.map(\.2) == [1.0, 2.0])
        #expect(drain(ring).isEmpty, "a drained slot is delivered once")
    }

    /// A cycle longer than a slot spans several, each stamped where its first frame falls.
    @Test func longCyclesSpanSlots() throws {
        let layout = try #require(HALInputLayout(streams: [float32(channels: 1)]))
        let ring = try #require(HALCaptureRing(layout: layout, slotFrames: 64, slotCount: 8))
        let samples = (0..<150).map(Float.init)
        withList([samples], channels: [1]) { #expect(ring.write($0, chunkStart: 10)) }
        let slots = drain(ring)
        #expect(slots.map(\.samples.count) == [64, 64, 22])
        #expect(slots.flatMap(\.samples) == samples)
        let expectedTimes: [TimeInterval] = [10, 10 + 64.0 / 48_000, 10 + 128.0 / 48_000]
        #expect(slots.map(\.time) == expectedTimes)
    }

    /// A stalled delivery queue drops (and counts) cycles instead of overwriting ones not yet delivered.
    @Test func aFullRingDropsNewCyclesAndCountsThem() throws {
        let layout = try #require(HALInputLayout(streams: [float32(channels: 1)]))
        let ring = try #require(HALCaptureRing(layout: layout, slotFrames: 64, slotCount: 2))
        for value: Float in [1, 2] {
            withList([[value, value]], channels: [1]) { #expect(ring.write($0, chunkStart: Double(value))) }
        }
        withList([[3, 3]], channels: [1]) { #expect(!ring.write($0, chunkStart: 3)) }
        #expect(ring.takeDroppedCycles() == 1)
        #expect(ring.takeDroppedCycles() == 0)
        #expect(drain(ring).map(\.samples) == [[1, 1], [2, 2]])
        withList([[4, 4]], channels: [1]) { #expect(ring.write($0, chunkStart: 4)) }
        #expect(drain(ring).map(\.samples) == [[4, 4]])
    }

    /// The session may keep delivered buffers (the undo-resume prefix): reusing a slot must not change them.
    @Test func deliveredBuffersAreCopiesOfTheirSlot() throws {
        let layout = try #require(HALInputLayout(streams: [float32(channels: 1)]))
        let ring = try #require(HALCaptureRing(layout: layout, slotFrames: 64, slotCount: 1))
        var kept: [AVAudioPCMBuffer] = []
        withList([[7, 7]], channels: [1]) { ring.write($0, chunkStart: 0) }
        ring.drain { buffer, _ in kept.append(buffer) }
        withList([[9, 9]], channels: [1]) { ring.write($0, chunkStart: 1) }
        ring.drain { buffer, _ in kept.append(buffer) }
        #expect(kept.map { $0.floatChannelData![0][0] } == [7, 9])
    }

    /// About a second of slack at any IO size, and slot sizes stay sane.
    @Test func ringSizingCoversASecond() throws {
        let layout = try #require(HALInputLayout(streams: [float32(channels: 1)]))
        for frames in [16, 128, 480, 4_096, 100_000] {
            let ring = try #require(HALCaptureRing(layout: layout, slotFrames: frames))
            #expect((64...4_096).contains(ring.slotFrames))
            #expect(ring.slotCount * ring.slotFrames >= 48_000)
            #expect(ring.slotCount >= 64)
        }
    }

    @Test func onlyFloatStreamsAreAccepted() {
        var integer = float32(channels: 2)
        integer.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        integer.mBitsPerChannel = 16
        #expect(HALInputLayout(streams: [integer]) == nil)
        #expect(HALInputLayout(streams: []) == nil)
        #expect(HALInputLayout(streams: [float32(rate: 0, channels: 1)]) == nil)
    }

    /// Mono and stereo mics keep the formats the engine tap delivered; wider interfaces still reach 16 kHz mono.
    @Test(arguments: [1, 2, 4])
    func everyChannelCountResamplesToMono(_ channels: Int) throws {
        let layout = try #require(HALInputLayout(streams: [float32(channels: UInt32(channels))]))
        let frames = 4_800
        let interleaved = (0..<frames).flatMap { f in
            (0..<channels).map { _ in 0.25 * Float(sin(Double(f) * 2 * .pi * 440 / 48_000)) }
        }
        var output: [Float] = []
        let resampler = StreamingResampler()
        withList([interleaved], channels: [channels]) { list in
            guard let buffer = layout.buffer(copying: list) else { return }
            try? resampler.process(buffer, into: &output)
        }
        try resampler.flush(into: &output)
        #expect(abs(output.count - 1_600) <= 16)
        let peak = output.map(abs).max() ?? 0
        #expect(peak > 0.1, "\(channels) channels came through at \(peak)")
    }
}
