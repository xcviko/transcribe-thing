import SwiftUI

/// Input device choice with a live level on the active row, the Bluetooth hint and the built-in preference.
struct MicrophonePage: View {
    @Environment(HubContext.self) private var hub
    @Environment(AppSettings.self) private var settings
    @Environment(AudioDeviceCatalog.self) private var devices
    @Environment(PermissionsCenter.self) private var permissions
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        @Bindable var settings = settings
        HubPage("Microphone", subtitle: "Pick the mic Murmur listens to.") {
            if permissions.microphone != .granted {
                Callout(.error, symbol: "mic.slash.fill",
                        text: "Microphone access is off, so Murmur can’t hear anything yet.") {
                    Button(permissions.microphone == .notDetermined ? "Allow" : "Open Settings") {
                        if permissions.microphone == .notDetermined {
                            let permissions = permissions
                            Task { _ = await permissions.requestMicrophone() }
                        } else {
                            permissions.open(.microphone)
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
                }
            }
            HubGroup("Input", footer: meterFooter) {
                if devices.devices.isEmpty {
                    noDevices
                } else {
                    SettingsGroup {
                        automaticRow
                        ForEach(devices.devices) { device in
                            deviceRow(device)
                        }
                    }
                }
            }
            if effectiveDevice?.transport == .bluetooth {
                Callout(.warning, symbol: "airpods",
                        text: "Bluetooth mics start slower and can drop the first words. Wired or built-in mics are more accurate.") {
                    if let builtIn = builtInDevice {
                        Button("Use Built-in Mic") {
                            withAnimation(Theme.Motion.snappy) { settings.microphoneUID = builtIn.id }
                        }
                        .buttonStyle(SecondaryButtonStyle(size: .small))
                    }
                }
                .transition(.opacity)
            }
            HubGroup("Bluetooth") {
                SettingsGroup {
                    SettingsRow(title: "Use the built-in mic even when AirPods are connected",
                                subtitle: "Your AirPods keep playing audio. The built-in mic starts faster and catches more words.",
                                systemImage: "laptopcomputer", iconTint: .inkSecondary) {
                        Toggle("", isOn: $settings.preferBuiltInMicOverBluetooth)
                            .toggleStyle(.murmurSwitch)
                            .labelsHidden()
                    }
                }
            }
        }
        .animation(Theme.Motion.fade, value: effectiveDevice?.id)
        .onAppear { updateMonitor() }
        .onDisappear { hub.microphoneMonitor.stop() }
        .onChange(of: monitorKey) { updateMonitor() }
    }

    // MARK: Live meter

    /// While dictating, the selected row shows dictation's own meter; otherwise a monitoring-only capture
    /// (nothing kept) runs while this page is visible in an active window, so the orange mic indicator
    /// never lingers behind other apps.
    private var isDictating: Bool { hub.dictation.activity == .recording }

    private var selectedMeter: (meter: LevelMeter, isLive: Bool) {
        if isDictating { return (hub.levelMeter, true) }
        return (hub.microphoneMonitor.meter, hub.microphoneMonitor.isRunning)
    }

    private struct MonitorKey: Equatable {
        var uid: String?
        var preferBuiltIn: Bool
        var shouldRun: Bool
    }

    private var monitorKey: MonitorKey {
        MonitorKey(uid: settings.microphoneUID, preferBuiltIn: settings.preferBuiltInMicOverBluetooth,
                   shouldRun: appearsActive && !isDictating && permissions.microphone == .granted)
    }

    private func updateMonitor() {
        let key = monitorKey
        let monitor = hub.microphoneMonitor
        guard !hub.isPreview else { return }
        if key.shouldRun {
            monitor.start(deviceUID: key.uid, preferBuiltInOverBluetooth: key.preferBuiltIn)
        } else {
            monitor.stop()
        }
    }

    private var meterFooter: String {
        switch hub.microphoneMonitor.problem {
        case .microphoneDisconnected?:
            return "This mic disconnected. Pick another one above."
        case .microphoneNotResponding?:
            return "This mic isn’t sending any sound. Try another one, or check Sound settings."
        default:
            return "Speak to see the level. Murmur doesn’t keep this audio."
        }
    }

    // MARK: Rows

    private var automaticRow: some View {
        let isSelected = settings.microphoneUID == nil
        let current = devices.device(uid: devices.defaultDeviceUID)?.name
        return MicrophoneRow(
            symbol: "arrow.triangle.branch",
            title: "Automatic",
            subtitle: current.map { "Follows macOS · now \($0)" } ?? "Follows macOS",
            isSelected: isSelected,
            isAvailable: true,
            meter: isSelected ? selectedMeter : nil
        ) {
            withAnimation(Theme.Motion.snappy) { settings.microphoneUID = nil }
        }
    }

    private func deviceRow(_ device: AudioInputDevice) -> some View {
        let isSelected = settings.microphoneUID == device.id
        // Which device macOS picks is already on the Automatic row just above.
        let subtitle = device.isAvailable ? device.transportLabel : (device.unavailableReason ?? "Disconnected")
        return MicrophoneRow(
            symbol: device.symbolName,
            title: device.name,
            subtitle: subtitle,
            isSelected: isSelected,
            isAvailable: device.isAvailable,
            meter: isSelected ? selectedMeter : nil
        ) {
            withAnimation(Theme.Motion.snappy) { settings.microphoneUID = device.id }
        }
    }

    private var noDevices: some View {
        Card {
            HStack(spacing: 12) {
                IconTile(symbol: "mic.slash", tint: .inkSecondary, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No microphone found")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.ink)
                    Text("Connect a mic or check Sound settings.")
                        .typeface(.callout)
                        .foregroundStyle(.inkSecondary)
                }
                Spacer()
                Button("Sound Settings") { permissions.open(.sound) }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
            }
        }
    }

    // MARK: Resolution

    /// The device dictation will actually use: the saved one if present, else the system default.
    private var effectiveDevice: AudioInputDevice? {
        if let uid = settings.microphoneUID, let device = devices.device(uid: uid), device.isAvailable {
            return device
        }
        return devices.device(uid: devices.defaultDeviceUID)
    }

    private var builtInDevice: AudioInputDevice? {
        devices.devices.first { $0.transport == .builtIn && $0.isAvailable }
    }
}

private struct MicrophoneRow: View {
    var symbol: String
    var title: String
    var subtitle: String
    var isSelected: Bool
    var isAvailable: Bool
    var meter: (meter: LevelMeter, isLive: Bool)?
    var select: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            RadioDot(isOn: isSelected)
            IconTile(symbol: symbol, tint: isSelected ? .accent : .inkSecondary, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .typeface(.callout)
                    .foregroundStyle(isAvailable ? Color.inkSecondary : Color.inkTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let meter, isAvailable {
                LevelBars(meter: meter.meter, isLive: meter.isLive)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 10)
        .frame(minHeight: 54)
        .background { RowHighlight(isSelected: isSelected, isHovering: hovering && isAvailable) }
        .opacity(isAvailable ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture { if isAvailable { select() } }
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
