import Foundation
import Observation

/// Live input level outside dictation, for the Microphone page (only the selected row meters).
/// Runs a monitoring-only capture: nothing is kept. Start it when the page appears, stop it when it
/// disappears; the orange mic indicator is on meanwhile.
@MainActor @Observable
final class MicrophoneMonitor {
    @ObservationIgnored let meter: LevelMeter
    private(set) var isRunning = false
    private(set) var deviceName: String?
    private(set) var problem: AppError?

    @ObservationIgnored private var session: CaptureSession?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isPreview = false

    init(meter: LevelMeter = LevelMeter()) {
        self.meter = meter
    }

    static func preview(level: Float = 0.45, deviceName: String = "MacBook Pro Microphone") -> MicrophoneMonitor {
        let monitor = MicrophoneMonitor(meter: .preview(level: level))
        monitor.isPreview = true
        monitor.isRunning = true
        monitor.deviceName = deviceName
        return monitor
    }

    /// `deviceUID` nil = what dictation would use automatically.
    func start(deviceUID: String?, preferBuiltInOverBluetooth: Bool = true) {
        guard !isPreview else { return }
        stop()
        problem = nil
        guard AudioRecorder.isMicrophoneAuthorized else {
            problem = .microphonePermissionDenied
            return
        }
        let records = CoreAudioHAL.inputRecords()
        guard let choice = InputDevicePolicy.choose(preferredUID: deviceUID, defaultUID: CoreAudioHAL.defaultInputUID(),
                                                    devices: records.map(\.device),
                                                    preferBuiltInOverBluetooth: preferBuiltInOverBluetooth),
              let record = records.first(where: { $0.device.id == choice.device.id })
        else {
            problem = .noMicrophone
            return
        }
        generation += 1
        meter.reset()
        var options = CaptureSession.Options(preferredUID: deviceUID, preferBuiltInOverBluetooth: preferBuiltInOverBluetooth)
        options.keepsSamples = false
        options.firstBufferTimeout = 4
        let session = CaptureSession(device: record, options: options, meter: meter,
                                     onEvent: Self.makeEventHandler(for: self, generation: generation))
        self.session = session
        deviceName = record.device.name
        isRunning = true
        session.start()
    }

    func stop() {
        guard !isPreview else { return }
        generation += 1
        if let session { _ = session.finishNow(discard: true) }
        session = nil
        isRunning = false
        meter.reset()
    }

    private func handle(_ event: CaptureSessionEvent, generation: Int) {
        guard generation == self.generation, let session else { return }
        switch event {
        case .firstBuffer:
            break
        case .switchedDevice(let device):
            deviceName = device.name
        case .deviceLost:
            _ = session.finishNow(discard: true)
            self.session = nil
            isRunning = false
            problem = .microphoneDisconnected
        case .startFailed(let detail), .noAudio(let detail):
            _ = session.finishNow(discard: true)
            self.session = nil
            isRunning = false
            problem = .microphoneNotResponding(detail)
        }
    }

    private nonisolated static func makeEventHandler(for monitor: MicrophoneMonitor,
                                                     generation: Int) -> @Sendable (CaptureSessionEvent) -> Void {
        { [weak monitor] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { monitor?.handle(event, generation: generation) }
            }
        }
    }
}
