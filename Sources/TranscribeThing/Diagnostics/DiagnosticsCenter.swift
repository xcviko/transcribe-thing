import Foundation
import Observation

/// What the diagnostic log says around the dictations: the launch (the app's version, macOS, the Mac), the settings
/// and every change to them, the permissions, the microphones by kind; and Export Logs…, which writes all of it to a
/// file to send. The composition root owns it; a preview's never starts.
@MainActor
final class DiagnosticsCenter {
    let log: DiagnosticLog
    private let settings: AppSettings
    private let keyStore: KeyFileStore
    private let account: OpenRouterAccount
    private let permissions: PermissionsCenter
    private let devices: AudioDeviceCatalog

    /// How long the settings stay put before their summary is written again: one line for a burst of changes (a
    /// shortcut being recorded, models being reordered).
    var settingsDebounce: Duration = .seconds(2)
    /// When an export is made, and the time zone its name and header say it in.
    var clock: () -> Date = { Date() }
    var timeZone: TimeZone = .current

    private var isStarted = false
    private var loggedSettings: DiagnosticSettingsSummary?
    private var settingsTask: Task<Void, Never>?
    private var loggedPermissions: [PermissionState]?
    private var loggedMicrophones: DiagnosticMicrophones?

    init(log: DiagnosticLog, settings: AppSettings, keyStore: KeyFileStore, account: OpenRouterAccount,
         permissions: PermissionsCenter, devices: AudioDeviceCatalog) {
        self.log = log
        self.settings = settings
        self.keyStore = keyStore
        self.account = account
        self.permissions = permissions
        self.devices = devices
    }

    /// The launch and settings lines, then a line whenever the settings, the permissions or the microphones change.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        log.event(.app, "app.launched", fields: DiagnosticSystemInfo.current().fields)
        let summary = currentSettings()
        loggedSettings = summary
        log.event(.settings, "settings", fields: summary.fields)
        observeSettings()
        observePermissions()
        observeMicrophones()
    }

    /// At quit: says so, and waits for the lines still being written.
    func stop() {
        guard isStarted else { return }
        log.event(.app, "app.quit")
        log.flush()
    }

    /// The settings as the log and the export's header show them.
    func currentSettings() -> DiagnosticSettingsSummary {
        DiagnosticSettingsSummary(settings: settings, keySaved: keyStore.hasFile)
    }

    // MARK: Export

    /// Writes the export (`DiagnosticExport`) into `folder` (the Desktop unless told otherwise) and returns its URL.
    /// The lines logged before the call are in it; the files are read and written off the main thread.
    func exportLogs(to folder: URL? = nil) async throws -> URL {
        let now = clock()
        let keySaved = keyStore.hasFile
        let header = DiagnosticExport.header(system: .current(), settings: currentSettings(), keySaved: keySaved,
                                             exportedAt: now, timeZone: timeZone, keptDays: log.limits.days)
        let folder = folder ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
        let url = folder.appendingPathComponent(DiagnosticExport.fileName(at: now, timeZone: timeZone),
                                                isDirectory: false)
        let log = log
        try await Task.detached(priority: .userInitiated) {
            let text = DiagnosticExport.contents(header: header, log: log.retainedText())
            try Data(text.utf8).write(to: url, options: .atomic)
        }.value
        return url
    }

    // MARK: Observing

    private func observeSettings() {
        withObservationTracking {
            _ = currentSettings()
            // A key saved or removed.
            _ = account.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.settingsChanged() }
        }
    }

    private func settingsChanged() {
        observeSettings()
        settingsTask?.cancel()
        let delay = settingsDebounce
        settingsTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let summary = self.currentSettings()
            guard summary != self.loggedSettings else { return }
            self.loggedSettings = summary
            self.log.event(.settings, "settings.changed", fields: summary.fields)
        }
    }

    /// Microphone and Accessibility, once the first check has landed and whenever either changes.
    private func observePermissions() {
        let state = withObservationTracking {
            permissions.hasLoaded ? [permissions.microphone, permissions.accessibility] : nil
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observePermissions() }
        }
        guard let state, state != loggedPermissions else { return }
        loggedPermissions = state
        log.event(.permissions, "permissions", ["microphone": state[0], "accessibility": state[1]])
    }

    /// The microphones by kind, whenever a scan finds them changed (from the first one that finds any).
    private func observeMicrophones() {
        let microphones = withObservationTracking {
            devices.devices.isEmpty && loggedMicrophones == nil ? nil
                : DiagnosticMicrophones(devices: devices.devices, defaultUID: devices.defaultDeviceUID,
                                        pickedUID: settings.microphoneUID)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeMicrophones() }
        }
        guard let microphones, microphones != loggedMicrophones else { return }
        loggedMicrophones = microphones
        log.event(.mic, "mic.devices", fields: microphones.fields)
    }
}
