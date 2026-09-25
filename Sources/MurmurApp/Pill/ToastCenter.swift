import Foundation
import Observation

// STUB (FOUNDATION): PILL owns timing, hover pause and presentation.
@MainActor @Observable
final class ToastCenter {
    /// Newest last; at most two are visible.
    private(set) var notices: [Notice] = []
    @ObservationIgnored var onAction: ((Notice, NoticeAction) -> Void)?
    @ObservationIgnored var onSound: ((SoundEffect) -> Void)?

    init() {}

    /// Dedupes by `dedupeKey` (replaces in place) and plays `notice.sound` via `onSound`.
    func post(_ notice: Notice) {
        if let i = notices.firstIndex(where: { $0.dedupeKey == notice.dedupeKey }) {
            notices[i] = notice
        } else {
            notices.append(notice)
        }
        if let sound = notice.sound { onSound?(sound) }
    }

    func dismiss(_ id: UUID) {
        notices.removeAll { $0.id == id }
    }
}
