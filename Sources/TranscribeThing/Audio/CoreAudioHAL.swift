import CoreAudio
import Foundation
import IOKit

/// Thin, thread-safe CoreAudio HAL queries. Callable from any thread; each call is a few IPC round
/// trips to coreaudiod (about 2 ms for a full device scan once the HAL client is warm).
enum CoreAudioHAL {
    /// An input-capable device with its volatile HAL id (valid until the device disappears).
    struct InputRecord: Sendable {
        var device: AudioInputDevice
        var audioID: AudioDeviceID
    }

    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    // MARK: Devices

    static func inputRecords() -> [InputRecord] {
        let lidClosed = isClamshellClosed()
        return allDeviceIDs().compactMap { makeInputRecord($0, lidClosed: lidClosed) }
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        guard read(systemObject, kAudioHardwarePropertyDefaultInputDevice, into: &id),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func defaultInputUID() -> String? {
        defaultInputDeviceID().flatMap { string($0, kAudioDevicePropertyDeviceUID) }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = propertyAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(systemObject, &address, UInt32(MemoryLayout<CFString>.size),
                                       uidPointer, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func uid(of id: AudioDeviceID) -> String? {
        string(id, kAudioDevicePropertyDeviceUID)
    }

    /// The Mac's own microphone (the lid's mic array rather than a headset on the combo jack), available or not.
    static func builtInMicrophoneUID() -> String? {
        let builtIn = allDeviceIDs().filter { id in
            var transport: UInt32 = 0
            return inputChannelCount(id) > 0 && read(id, kAudioDevicePropertyTransportType, into: &transport)
                && transport == kAudioDeviceTransportTypeBuiltIn
        }
        let uids = builtIn.compactMap { id in uid(of: id).map { (id, $0) } }
        return (uids.first { isInternalMicrophone($0.0, uid: $0.1) } ?? uids.first)?.1
    }

    /// Input streams of a device, in the order its IOProc receives their buffers.
    static func inputStreamIDs(_ id: AudioDeviceID) -> [AudioStreamID] {
        objectList(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
    }

    /// The input devices this process is doing IO with right now, as the HAL itself sees it: the check that
    /// capture opened only the device it meant to.
    static func processInputDeviceIDs() -> [AudioDeviceID] {
        var address = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address, UInt32(MemoryLayout<pid_t>.size), &pid,
                                                &size, &process)
        guard status == noErr, process != kAudioObjectUnknown else { return [] }
        return objectList(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
    }

    static func isAlive(_ id: AudioDeviceID) -> Bool {
        var alive: UInt32 = 0
        return read(id, kAudioDevicePropertyDeviceIsAlive, into: &alive) && alive != 0
    }

    static func name(of id: AudioDeviceID) -> String? {
        string(id, kAudioObjectPropertyName)
    }

    /// True when the ping of a UI sound can reach the microphone acoustically: the default output is the
    /// Mac's own speaker (not the headphone jack, not Bluetooth/USB/HDMI) and it is not muted.
    static func isDefaultOutputBuiltInSpeaker() -> Bool {
        var id = AudioDeviceID(kAudioObjectUnknown)
        guard read(systemObject, kAudioHardwarePropertyDefaultOutputDevice, into: &id),
              id != kAudioObjectUnknown else { return false }
        var transport: UInt32 = 0
        guard read(id, kAudioDevicePropertyTransportType, into: &transport),
              transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        var source: UInt32 = 0
        if read(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, into: &source),
           source == fourCC("hdpn") {
            return false
        }
        if let uid = string(id, kAudioDevicePropertyDeviceUID), uid.localizedCaseInsensitiveContains("headphone") {
            return false
        }
        var muted: UInt32 = 0
        if read(id, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, into: &muted), muted != 0 {
            return false
        }
        return true
    }

    /// MacBooks disconnect the built-in microphone in hardware while the lid is closed.
    static func isClamshellClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return false }
        return (value as? Bool) ?? false
    }

    // MARK: Record construction

    static func makeInputRecord(_ id: AudioDeviceID, lidClosed: Bool) -> InputRecord? {
        guard inputChannelCount(id) > 0 else { return nil }
        var hidden: UInt32 = 0
        if read(id, kAudioDevicePropertyIsHidden, into: &hidden), hidden != 0 { return nil }
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }

        var transportRaw: UInt32 = 0
        read(id, kAudioDevicePropertyTransportType, into: &transportRaw)
        let transport = transportKind(transportRaw)
        let name = string(id, kAudioObjectPropertyName) ?? "Microphone"

        var reason: String?
        if !isAlive(id) {
            reason = "Disconnected"
        } else if transport == .builtIn, lidClosed, isInternalMicrophone(id, uid: uid) {
            reason = "Lid is closed"
        } else if transport == .builtIn, !isInternalMicrophone(id, uid: uid), jackUnplugged(id) {
            reason = "Nothing plugged in"
        }
        let device = AudioInputDevice(id: uid, name: name, transport: transport, isAvailable: reason == nil,
                                      unavailableReason: reason)
        return InputRecord(device: device, audioID: id)
    }

    static func transportKind(_ raw: UInt32) -> AudioInputDevice.Transport {
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: .aggregate
        case kAudioDeviceTransportTypeVirtual: .virtual
        default: .other
        }
    }

    /// The laptop's own mic array (data source `imic`), as opposed to a headset on the combo jack.
    private static func isInternalMicrophone(_ id: AudioDeviceID, uid: String) -> Bool {
        var source: UInt32 = 0
        if read(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeInput, into: &source) {
            return source == fourCC("imic")
        }
        return uid.localizedCaseInsensitiveContains("microphone") && !uid.localizedCaseInsensitiveContains("headphone")
    }

    private static func jackUnplugged(_ id: AudioDeviceID) -> Bool {
        var connected: UInt32 = 1
        guard read(id, kAudioDevicePropertyJackIsConnected, scope: kAudioObjectPropertyScopeInput, into: &connected)
        else { return false }
        return connected == 0
    }

    // MARK: Low-level helpers

    static func allDeviceIDs() -> [AudioDeviceID] {
        objectList(systemObject, kAudioHardwarePropertyDevices)
    }

    static func objectList(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = propertyAddress(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func propertyAddress(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    @discardableResult
    static func read<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                         into value: inout T) -> Bool {
        var address = propertyAddress(selector, scope: scope)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) == noErr
        }
    }

    static func fourCC(_ code: String) -> UInt32 {
        code.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

/// Owns a set of HAL property listeners; removes them on `invalidate()` or deinit.
/// Listener blocks run on `queue` and never touch main-actor state directly.
final class HALListenerSet: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    @discardableResult
    func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             handler: @escaping @Sendable () -> Void) -> Bool {
        var address = CoreAudioHAL.propertyAddress(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return false }
        lock.withLock { registrations.append((object, address, block)) }
        return true
    }

    func invalidate() {
        let current = lock.withLock { () -> [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] in
            defer { registrations.removeAll() }
            return registrations
        }
        for (object, address, block) in current {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
    }

    deinit {
        invalidate()
    }
}
