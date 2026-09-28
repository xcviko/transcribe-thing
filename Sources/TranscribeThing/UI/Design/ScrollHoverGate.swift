import SwiftUI

/// Hover waits out scrolling, as in a browser. While a page moves under a resting pointer, every row it passes
/// lit up and built its actions in turn, which is what made Home stutter under the pointer. With a gate, nothing
/// lights up until the page has stood still for `settleDelay`, and then only what the pointer rests on.
/// Leaving counts at once, so a row lit when scrolling starts goes dark as it slides away.
@MainActor
final class ScrollHoverGate {
    nonisolated static let settleDelay: Duration = .milliseconds(100)

    private(set) var isScrolling = false
    /// The last hover that came in while scrolling and hasn't left since: what the pointer is over.
    private var pending: (id: ObjectIdentifier, apply: () -> Void)?
    private var lastScroll = ContinuousClock.now
    private var settling: Task<Void, Never>?
    private let delay: Duration

    init(settleDelay: Duration = ScrollHoverGate.settleDelay) {
        delay = settleDelay
    }

    /// The page moved (called for every step, so it only notes the time).
    func scrolled() {
        lastScroll = .now
        isScrolling = true
        guard settling == nil else { return }
        settling = Task { [weak self] in
            while let due = self?.settleTime, ContinuousClock.now < due {
                do { try await Task.sleep(until: due) } catch { return }
            }
            self?.settle()
        }
    }

    /// The pointer entered (`inside`) or left the view `id`; `apply` shows it, now or once scrolling stops.
    func hover(_ id: ObjectIdentifier, inside: Bool, apply: @escaping (Bool) -> Void) {
        if inside, isScrolling {
            pending = (id, { apply(true) })
            return
        }
        if !inside, pending?.id == id { pending = nil }
        apply(inside)
    }

    /// The page stands still: the view under the pointer lights up.
    func settle() {
        settling?.cancel()
        settling = nil
        isScrolling = false
        let hover = pending
        pending = nil
        hover?.apply()
    }

    private var settleTime: ContinuousClock.Instant { lastScroll + delay }
}

extension EnvironmentValues {
    /// The gate of the scrolling page around a view, if it has one (Home).
    @Entry var scrollHoverGate: ScrollHoverGate?
}

extension View {
    /// `onHover` that waits out scrolling on a page with a `ScrollHoverGate`, and is plain `onHover` elsewhere.
    func onSettledHover(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(SettledHover(action: action))
    }
}

private struct SettledHover: ViewModifier {
    var action: (Bool) -> Void
    @Environment(\.scrollHoverGate) private var gate
    /// What the view was last told, so the gate's rows that are never lit don't get told "not hovered" as they
    /// slide out from under the pointer. A reference: noting it redraws nothing.
    @State private var shown = Shown()

    func body(content: Content) -> some View {
        content.onHover { inside in
            guard let gate else { return action(inside) }
            let shown = shown
            gate.hover(ObjectIdentifier(shown), inside: inside) { value in
                guard shown.value != value else { return }
                shown.value = value
                action(value)
            }
        }
    }

    private final class Shown {
        var value = false
    }
}
