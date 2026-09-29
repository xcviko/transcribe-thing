import AppKit
import CoreAudio
import Foundation
import Observation

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    enum Transport: Sendable { case builtIn, usb, bluetooth, aggregate, virtual, other }

    /// CoreAudio device UID (stable across reboots; persist this, never the numeric HAL id).
    let id: String
    let name: String
    let transport: Transport
    var isAvailable: Bool
    /// Short reason shown next to a dimmed device: "Lid is closed", "Disconnected", "Nothing plugged in".
    var unavailableReason: String? = nil

    var isBuiltIn: Bool { transport == .builtIn }
    var isBluetooth: Bool { transport == .bluetooth }
    /// Loopback drivers, meeting-app devices and the like: listed, but never picked automatically.
    var isVirtual: Bool { transport == .virtual }

    var symbolName: String {
        switch transport {
        case .builtIn:
            if name.localizedCaseInsensitiveContains("MacBook") { return "laptopcomputer" }
            if name.localizedCaseInsensitiveContains("iMac") || name.localizedCaseInsensitiveContains("Studio Display") {
                return "desktopcomputer"
            }
            return "mic"
        case .bluetooth:
            if name.localizedCaseInsensitiveContains("AirPods Max") { return "airpodsmax" }
            if name.localizedCaseInsensitiveContains("AirPods Pro") { return "airpodspro" }
            if name.localizedCaseInsensitiveContains("AirPods") { return "airpods" }
            return "headphones"
        case .usb, .other:
            if name.localizedCaseInsensitiveContains("iPhone") { return "iphone" }
            if name.localizedCaseInsensitiveContains("headset") || name.localizedCaseInsensitiveContains("headphone") {
                return "headphones"
            }
            return "mic"
        case .aggregate: return "square.stack.3d.up"
        case .virtual: return "waveform"
        }
    }

    var transportLabel: String {
        switch transport {
        case .builtIn: "Built-in"
        case .usb: "USB"
        case .bluetooth: "Bluetooth"
        case .aggregate: "Aggregate"
        case .virtual: "Virtual"
        case .other: "External"
        }
    }

    /// Display order: built-in first, then wired, wireless, and software devices last.
    fileprivate var sortRank: Int {
        switch transport {
        case .builtIn: 0
        case .usb: 1
        case .other: 2
        case .bluetooth: 3
        case .aggregate: 4
        case .virtual: 5
        }
    }
}

/// The device a dictation will use, and why.
struct InputDeviceChoice: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// The device the user picked.
        case selected
        /// Automatic: the system default input.
        case systemDefault
        /// The picked device (or the system default) is unavailable, so another one is used.
        case fallback(unavailableUID: String?)
    }

    var device: AudioInputDevice
    var reason: Reason
}

/// Pure device-selection policy (SPEC §5.2), shared by the recorder, the Microphone page and tests.
/// A picked mic that is present is always the answer, whatever the system default is; Automatic is the
/// system default (a Bluetooth one included). Capture then opens exactly the chosen device.
enum InputDevicePolicy {
    static func choose(preferredUID: String?, defaultUID: String?, devices: [AudioInputDevice]) -> InputDeviceChoice? {
        let available = devices.filter(\.isAvailable)

        if let preferredUID, let picked = available.first(where: { $0.id == preferredUID }) {
            return InputDeviceChoice(device: picked, reason: .selected)
        }
        let missedPreferred = preferredUID

        if let defaultUID, let def = available.first(where: { $0.id == defaultUID }), !def.isVirtual {
            return InputDeviceChoice(device: def, reason: missedPreferred.map { .fallback(unavailableUID: $0) }
                ?? .systemDefault)
        }

        let ranked = available
            .filter { !$0.isVirtual && $0.transport != .aggregate }
            .sorted { $0.sortRank < $1.sortRank }
        let fallback = ranked.first ?? available.first(where: { $0.transport == .aggregate })
        return fallback.map { InputDeviceChoice(device: $0, reason: .fallback(unavailableUID: missedPreferred ?? defaultUID)) }
    }

    /// Whether the picked mic `uid` stays picked with `devices` connected. Automatic (nil) always does, and so does
    /// any pick while the scan lists nothing (that says nothing about the pick). A listed device stays when it can
    /// record, or when it's the Mac's own: a closed lid or an empty jack comes back by itself. A device that is gone,
    /// or listed as disconnected, doesn't: the pick falls back to Automatic.
    static func keepsPick(_ uid: String?, devices: [AudioInputDevice]) -> Bool {
        guard let uid, !devices.isEmpty else { return true }
        guard let device = devices.first(where: { $0.id == uid }) else { return false }
        return device.isAvailable || device.isBuiltIn
    }

    /// A pick that fell back to Automatic comes back once its device is listed and can record again: AirPods back in
    /// the ears, a USB mic plugged in again, or a device that only flickered away.
    static func isBack(_ uid: String, devices: [AudioInputDevice]) -> Bool {
        devices.contains { $0.id == uid && $0.isAvailable }
    }
}

/// Live list of input devices. CoreAudio listeners run on a private queue; scans run off the main
/// thread (the first HAL query in a process takes ~100 ms) and publish on the main actor.
@MainActor @Observable
final class AudioDeviceCatalog {
    private(set) var devices: [AudioInputDevice] = []
    private(set) var defaultDeviceUID: String?
    @ObservationIgnored var onDevicesChanged: (() -> Void)?

    @ObservationIgnored private var listeners: HALListenerSet?
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var isPreview = false
    @ObservationIgnored private let scanQueue = DispatchQueue(label: "dev.transcribe-thing.audio.catalog", qos: .utility)

    init() {}

    var isStarted: Bool { listeners != nil }

    /// Starts CoreAudio listeners for the device list and default input changes.
    func start() {
        guard !isPreview, listeners == nil else { return }
        let set = HALListenerSet(queue: scanQueue)
        let notify = Self.makeChangeHandler(for: self)
        set.add(CoreAudioHAL.systemObject, kAudioHardwarePropertyDevices, handler: notify)
        set.add(CoreAudioHAL.systemObject, kAudioHardwarePropertyDefaultInputDevice, handler: notify)
        listeners = set
        // Closing or opening the lid reconfigures displays; the built-in mic's availability follows the lid.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in notify() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in notify() }
        refreshInBackground()
    }

    func stop() {
        listeners?.invalidate()
        listeners = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        screenObserver = nil
        wakeObserver = nil
    }

    /// Re-reads the device list synchronously.
    func refresh() {
        guard !isPreview else { return }
        scanGeneration += 1
        apply(Self.scan())
    }

    /// Re-reads the device list on a background queue and publishes the result on the main actor.
    func refreshInBackground() {
        guard !isPreview else { return }
        scanGeneration += 1
        Self.scan(on: scanQueue, for: self, generation: scanGeneration)
    }

    func device(uid: String?) -> AudioInputDevice? {
        guard let uid else { return nil }
        return devices.first { $0.id == uid }
    }

    var defaultDevice: AudioInputDevice? { device(uid: defaultDeviceUID) }

    var builtInDevice: AudioInputDevice? { devices.first(where: \.isBuiltIn) }

    /// What a dictation would use right now (for "Automatic · Currently: MacBook Pro Microphone").
    func resolve(preferredUID: String?) -> InputDeviceChoice? {
        InputDevicePolicy.choose(preferredUID: preferredUID, defaultUID: defaultDeviceUID, devices: devices)
    }

    static func preview() -> AudioDeviceCatalog {
        preview(devices: [
            AudioInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn, isAvailable: true),
            AudioInputDevice(id: "preview-airpods", name: "AirPods Pro", transport: .bluetooth, isAvailable: true),
            AudioInputDevice(id: "preview-usb", name: "Shure MV7+", transport: .usb, isAvailable: true),
        ], defaultUID: "BuiltInMicrophoneDevice")
    }

    static func preview(devices: [AudioInputDevice], defaultUID: String?) -> AudioDeviceCatalog {
        let catalog = AudioDeviceCatalog()
        catalog.isPreview = true
        catalog.devices = devices
        catalog.defaultDeviceUID = defaultUID
        return catalog
    }

    /// A preview catalog's devices change as a scan would report them (a mic unplugged, then back): tests.
    func previewScan(devices: [AudioInputDevice], defaultUID: String?) {
        guard isPreview else { return }
        apply(Snapshot(devices: devices, defaultUID: defaultUID))
    }

    // MARK: Private

    private struct Snapshot: Sendable {
        var devices: [AudioInputDevice]
        var defaultUID: String?
    }

    private func apply(_ snapshot: Snapshot) {
        guard snapshot.devices != devices || snapshot.defaultUID != defaultDeviceUID else { return }
        devices = snapshot.devices
        defaultDeviceUID = snapshot.defaultUID
        onDevicesChanged?()
    }

    private nonisolated static func scan() -> Snapshot {
        let list = CoreAudioHAL.inputRecords().map(\.device).sorted(by: displayOrder)
        return Snapshot(devices: list, defaultUID: CoreAudioHAL.defaultInputUID())
    }

    private nonisolated static func displayOrder(_ a: AudioInputDevice, _ b: AudioInputDevice) -> Bool {
        if a.sortRank != b.sortRank { return a.sortRank < b.sortRank }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    private nonisolated static func scan(on queue: DispatchQueue, for catalog: AudioDeviceCatalog, generation: Int) {
        queue.async { [weak catalog] in
            let snapshot = scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A newer scan was requested meanwhile; its result wins.
                    guard let catalog, catalog.scanGeneration == generation else { return }
                    catalog.apply(snapshot)
                }
            }
        }
    }

    /// Built outside main-actor code so the HAL listener queue never runs a main-actor-isolated closure.
    /// Bursts of HAL notifications (a Bluetooth device connecting fires several) coalesce into one scan.
    private nonisolated static func makeChangeHandler(for catalog: AudioDeviceCatalog) -> @Sendable () -> Void {
        { [weak catalog] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let catalog, !catalog.refreshScheduled else { return }
                    catalog.refreshScheduled = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        MainActor.assumeIsolated {
                            catalog.refreshScheduled = false
                            catalog.refreshInBackground()
                        }
                    }
                }
            }
        }
    }
}
