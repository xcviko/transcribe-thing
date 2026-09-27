import Foundation
import Observation

/// Toasts anchored above the pill (wispr-ux §1.7): at most two, deduped by key, timed with a countdown that
/// pauses while the pointer is over the stack.
@MainActor @Observable
final class ToastCenter {
    static let maxVisible = 2
    /// After a hover ends, a toast keeps at least this long so it doesn't vanish under a leaving pointer.
    static let resumeGrace: TimeInterval = 1.5
    /// "Copied ✓" keeps the transcript card around at least this long (real seconds, not scaled by
    /// `ToastCountdown.speed`).
    static let afterCopyLifetime: TimeInterval = 2

    /// Newest last; at most two visible.
    private(set) var notices: [Notice] = []
    /// Countdown per notice id; sticky notices have none.
    private(set) var countdowns: [UUID: ToastCountdown] = [:]
    /// True while the pointer is over the toast stack.
    private(set) var isPaused = false

    @ObservationIgnored var onAction: ((Notice, NoticeAction) -> Void)?
    @ObservationIgnored var onSound: ((SoundEffect) -> Void)?

    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let schedulesExpiry: Bool
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    convenience init() {
        self.init(clock: { Date() }, schedulesExpiry: true)
    }

    /// `schedulesExpiry: false` leaves expiry to explicit `expire(now:)` calls (tests, frozen previews).
    init(clock: @escaping @MainActor () -> Date, schedulesExpiry: Bool) {
        self.clock = clock
        self.schedulesExpiry = schedulesExpiry
    }

    /// Frozen notices for snapshots: countdown rings stop at `fractionRemaining`, nothing expires.
    static func preview(_ notices: [Notice], fractionRemaining: Double = 0.64) -> ToastCenter {
        let center = ToastCenter(clock: { Date() }, schedulesExpiry: false)
        for notice in notices { center.post(notice) }
        for (id, countdown) in center.countdowns {
            center.countdowns[id] = ToastCountdown(total: countdown.total,
                                                   remaining: countdown.total * fractionRemaining, resumedAt: nil)
        }
        return center
    }

    // MARK: Posting

    /// Dedupes by `dedupeKey` (replaces in place) and plays `notice.sound` via `onSound`.
    func post(_ notice: Notice) {
        let now = clock()
        if let i = notices.firstIndex(where: { $0.dedupeKey == notice.dedupeKey }) {
            countdowns[notices[i].id] = nil
            notices[i] = notice
        } else {
            notices.append(notice)
            trimToCapacity()
        }
        countdowns[notice.id] = ToastCountdown(lifetime: notice.lifetime, now: now, paused: isPaused)
        if let sound = notice.sound { onSound?(sound) }
        rescheduleExpiry()
    }

    func dismiss(_ id: UUID) {
        guard notices.contains(where: { $0.id == id }) else { return }
        notices.removeAll { $0.id == id }
        countdowns[id] = nil
        rescheduleExpiry()
    }

    func dismiss(dedupeKey: String) {
        guard let notice = notices.first(where: { $0.dedupeKey == dedupeKey }) else { return }
        dismiss(notice.id)
    }

    func dismissAll() {
        notices.removeAll()
        countdowns.removeAll()
        rescheduleExpiry()
    }

    /// A button in a toast was clicked. Copy keeps the card (its button turns into "Copied"); everything else
    /// dismisses it after the action is handed to `onAction`.
    func perform(_ action: NoticeAction, on notice: Notice) {
        onAction?(notice, action)
        switch action.kind {
        case .copyText:
            extend(notice.id, toAtLeast: Self.afterCopyLifetime)
        default:
            dismiss(notice.id)
        }
    }

    // MARK: Timing

    /// Hovering the stack pauses every countdown; leaving resumes with a short grace.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        let now = clock()
        isPaused = paused
        for (id, countdown) in countdowns {
            countdowns[id] = paused ? countdown.paused(at: now) : countdown.resumed(at: now, grace: Self.resumeGrace)
        }
        rescheduleExpiry()
    }

    /// 1 = just posted, 0 = about to go. nil for sticky notices.
    func fractionRemaining(for id: UUID, at date: Date) -> Double? {
        countdowns[id]?.fraction(at: date)
    }

    /// Removes every notice whose countdown has run out by `now`.
    func expire(now: Date) {
        let due = notices.filter { notice in
            guard let countdown = countdowns[notice.id] else { return false }
            return countdown.remaining(at: now) <= 0.01
        }
        guard !due.isEmpty else {
            rescheduleExpiry()
            return
        }
        let ids = Set(due.map(\.id))
        notices.removeAll { ids.contains($0.id) }
        for id in ids { countdowns[id] = nil }
        rescheduleExpiry()
    }

    private func extend(_ id: UUID, toAtLeast seconds: TimeInterval) {
        guard let countdown = countdowns[id] else { return }
        let now = clock()
        if countdown.remaining(at: now) < seconds {
            countdowns[id] = ToastCountdown(total: max(countdown.total, seconds), remaining: seconds,
                                            resumedAt: isPaused ? nil : now)
            rescheduleExpiry()
        }
    }

    /// Keeps two: drops the oldest timed notice first, so sticky ones (permissions, missing mic) survive.
    private func trimToCapacity() {
        while notices.count > Self.maxVisible {
            let candidates = notices.dropLast()
            let index = candidates.firstIndex { $0.lifetime != .sticky } ?? notices.startIndex
            countdowns[notices[index].id] = nil
            notices.remove(at: index)
        }
    }

    private func rescheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard schedulesExpiry else { return }
        let deadlines = countdowns.values.compactMap(\.deadline)
        guard let next = deadlines.min() else { return }
        let delay = max(0.05, next.timeIntervalSince(clock()))
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.expire(now: self.clock())
        }
    }
}

/// Remaining lifetime of one toast; frozen while paused (`resumedAt == nil`).
struct ToastCountdown: Equatable, Sendable {
    /// Timed notices run their countdown this many times faster than their `NoticeLifetime`, so every toast,
    /// current or future, is on screen for `lifetime / speed` seconds.
    static let speed: Double = 2

    var total: TimeInterval
    /// Remaining as of `resumedAt` (running) or now (paused).
    var remaining: TimeInterval
    var resumedAt: Date?

    init(total: TimeInterval, remaining: TimeInterval, resumedAt: Date?) {
        self.total = max(total, 0.01)
        self.remaining = remaining
        self.resumedAt = resumedAt
    }

    init?(lifetime: NoticeLifetime, now: Date, paused: Bool) {
        guard case .seconds(let nominal) = lifetime else { return nil }
        let seconds = nominal / Self.speed
        self.init(total: seconds, remaining: seconds, resumedAt: paused ? nil : now)
    }

    func remaining(at date: Date) -> TimeInterval {
        guard let resumedAt else { return remaining }
        return max(0, remaining - date.timeIntervalSince(resumedAt))
    }

    func fraction(at date: Date) -> Double {
        min(1, max(0, remaining(at: date) / total))
    }

    var deadline: Date? { resumedAt.map { $0.addingTimeInterval(remaining) } }
    var isRunning: Bool { resumedAt != nil }

    func paused(at date: Date) -> ToastCountdown {
        ToastCountdown(total: total, remaining: remaining(at: date), resumedAt: nil)
    }

    func resumed(at date: Date, grace: TimeInterval) -> ToastCountdown {
        guard resumedAt == nil else { return self }
        return ToastCountdown(total: total, remaining: max(remaining, min(grace, total)), resumedAt: date)
    }
}
