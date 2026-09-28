import Foundation
import Testing
@testable import TranscribeThing

/// Home's hover waits out scrolling: rows passing under a resting pointer don't light up one after another.
@Suite @MainActor struct ScrollHoverGateTests {
    @MainActor private final class Row {
        var shown: [Bool] = []
        var id: ObjectIdentifier { ObjectIdentifier(self) }
        func hover(_ inside: Bool, through gate: ScrollHoverGate) {
            gate.hover(id, inside: inside) { self.shown.append($0) }
        }
    }

    @Test func hoverIsImmediateWhileThePageStandsStill() {
        let gate = ScrollHoverGate()
        let row = Row()
        row.hover(true, through: gate)
        row.hover(false, through: gate)
        #expect(row.shown == [true, false])
    }

    @Test func onlyTheRowUnderThePointerLightsUpOnceScrollingStops() {
        let gate = ScrollHoverGate()
        let passed = Row(), resting = Row()
        gate.scrolled()
        passed.hover(true, through: gate)
        passed.hover(false, through: gate)
        resting.hover(true, through: gate)
        #expect(resting.shown.isEmpty, "nothing lights up while the page moves")
        gate.settle()
        #expect(passed.shown == [false], "a row that slid by is only told it isn't hovered")
        #expect(resting.shown == [true])
    }

    @Test func aRowLitWhenScrollingStartsGoesDarkAsItSlidesAway() {
        let gate = ScrollHoverGate()
        let row = Row()
        row.hover(true, through: gate)
        gate.scrolled()
        row.hover(false, through: gate)
        #expect(row.shown == [true, false])
        gate.settle()
        #expect(row.shown == [true, false])
    }

    @Test func settlesOnItsOwnOnceThePageStopsMoving() async throws {
        let gate = ScrollHoverGate(settleDelay: .milliseconds(20))
        let row = Row()
        gate.scrolled()
        row.hover(true, through: gate)
        #expect(gate.isScrolling)
        let deadline = ContinuousClock.now + .seconds(5)
        while gate.isScrolling, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!gate.isScrolling)
        #expect(row.shown == [true])
    }
}
