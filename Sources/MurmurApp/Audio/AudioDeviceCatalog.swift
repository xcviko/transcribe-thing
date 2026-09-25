import Foundation
import Observation

// STUB (FOUNDATION): AUDIO replaces this with the CoreAudio-backed catalog.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    enum Transport: Sendable { case builtIn, usb, bluetooth, aggregate, virtual, other }

    /// CoreAudio device UID.
    let id: String
    let name: String
    let transport: Transport
    var isAvailable: Bool
}

@MainActor @Observable
final class AudioDeviceCatalog {
    private(set) var devices: [AudioInputDevice] = []
    private(set) var defaultDeviceUID: String?
    @ObservationIgnored var onDevicesChanged: (() -> Void)?

    init() {}

    /// Starts CoreAudio listeners for the device list and default input changes.
    func start() {}

    func device(uid: String?) -> AudioInputDevice? {
        guard let uid else { return nil }
        return devices.first { $0.id == uid }
    }

    static func preview() -> AudioDeviceCatalog {
        let catalog = AudioDeviceCatalog()
        catalog.devices = [
            AudioInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn, isAvailable: true),
            AudioInputDevice(id: "preview-airpods", name: "AirPods Pro", transport: .bluetooth, isAvailable: true),
            AudioInputDevice(id: "preview-usb", name: "Shure MV7+", transport: .usb, isAvailable: true),
        ]
        catalog.defaultDeviceUID = "BuiltInMicrophoneDevice"
        return catalog
    }
}
