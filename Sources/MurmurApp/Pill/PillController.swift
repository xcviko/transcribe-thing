import Foundation

// STUB (FOUNDATION): PILL owns the panel, positioning and visibility rules.
@MainActor
final class PillController {
    private let model: PillModel
    private let toasts: ToastCenter
    private let settings: AppSettings

    init(model: PillModel, toasts: ToastCenter, settings: AppSettings) {
        self.model = model
        self.toasts = toasts
        self.settings = settings
    }

    /// Creates the panel, observes settings/model/toasts and screen changes.
    func start() {}

    /// One-time post-onboarding bloom + tooltip.
    func showHello() {}
}
