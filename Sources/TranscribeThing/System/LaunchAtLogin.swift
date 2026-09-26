import Foundation
import Observation
import os
import ServiceManagement

struct LaunchAtLoginError: LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

/// "Open at login" through `SMAppService.mainApp`.
@MainActor @Observable
final class LaunchAtLogin {
    enum Status: Equatable, Sendable {
        case enabled
        case disabled
        /// Registered, but the user has to allow it in System Settings ▸ General ▸ Login Items.
        case requiresApproval
    }

    private(set) var status: Status

    /// Registered (including "waiting for approval", so the switch reflects what the user chose).
    var isEnabled: Bool { status != .disabled }
    var requiresApproval: Bool { status == .requiresApproval }

    @ObservationIgnored private let isPreview: Bool

    init() {
        isPreview = false
        status = Self.readStatus()
    }

    private init(previewStatus: Status) {
        isPreview = true
        status = previewStatus
    }

    static func preview() -> LaunchAtLogin {
        LaunchAtLogin(previewStatus: .disabled)
    }

    static func preview(status: Status) -> LaunchAtLogin {
        LaunchAtLogin(previewStatus: status)
    }

    func refresh() {
        guard !isPreview else { return }
        let current = Self.readStatus()
        if status != current { status = current }
    }

    func set(_ on: Bool) throws {
        if isPreview {
            status = on ? .enabled : .disabled
            return
        }
        let service = SMAppService.mainApp
        do {
            if on {
                if service.status != .enabled { try service.register() }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            refresh()
            Log.app.error("Login item \(on ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw LaunchAtLoginError(message: on
                ? "\(Brand.name) couldn’t add itself to your login items. Try again from the Applications folder."
                : "\(Brand.name) couldn’t remove itself from your login items. You can remove it in System Settings.")
        }
        refresh()
        if on, status == .requiresApproval { openLoginItemsSettings() }
    }

    func openLoginItemsSettings() {
        guard !isPreview else { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func readStatus() -> Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered, .notFound: .disabled
        @unknown default: .disabled
        }
    }
}
