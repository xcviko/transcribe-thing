import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TranscribeThing

#if DEBUG
/// Home builds only the History rows in view, however long a day is: a whole day used to be built as one card.
@Suite @MainActor struct HomeHistoryLazinessTests {
    @Test func buildsOnlyTheRowsInView() {
        let env = AppEnvironment.preview()
        let context = HubContext(env: env)
        let now = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: Date())!
        context.fixedNow = now
        // 150 dictations a minute apart, all today.
        context.history = .preview(entries: HomeScrollBenchmark.entries(150, every: 60, before: now))
        env.windows.hubSection = .home
        HistoryRenderCounts.reset()
        let hosting = NSHostingView(rootView: HubView(context: context).appTheme().frame(width: 980, height: 760))
        hosting.frame = NSRect(x: 0, y: 0, width: 980, height: 760)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        hosting.layoutSubtreeIfNeeded()
        #expect(HistoryRenderCounts.rows > 0)
        #expect(HistoryRenderCounts.rows < 30, "a 760 pt window shows about 6 rows")
        #expect(HistoryRenderCounts.versionsMenus == 0, "a Versions menu is made when it opens")
    }
}

/// Opt-in scroll probe for Home: `HOME_SCROLL_BENCH=1 swift test --filter HomeScrollBenchmark` (or `=150` for one
/// size). Hosts the Hub on Home with a long synthetic history in an offscreen window, scrolls down in 30 pt steps
/// (about a trackpad frame) and prints what each step cost SwiftUI (update and layout), how many steps missed a
/// 120 Hz or 60 Hz frame, how many row bodies ran, and what an offscreen render of the window costs.
/// `HOME_SCROLL_TRACE=1` prints every step.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HOME_SCROLL_BENCH"] != nil), .serialized)
@MainActor struct HomeScrollBenchmark {
    nonisolated static let counts: [Int] = {
        guard let count = ProcessInfo.processInfo.environment["HOME_SCROLL_BENCH"].flatMap(Int.init), count > 1 else {
            return [150, 1000]
        }
        return [count]
    }()

    @Test(arguments: counts) func scrollThroughHistory(count: Int) throws {
        let env = AppEnvironment.preview()
        let context = HubContext(env: env)
        context.history = .preview(entries: Self.entries(count))
        env.windows.hubSection = .home
        let size = CGSize(width: 980, height: 760)
        /// Main-thread CPU time: sleeping until the next timer or frame doesn't count.
        func cpu() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

        HistoryRenderCounts.reset()
        let firstStart = cpu()
        let hosting = NSHostingView(rootView: HubView(context: context).appTheme().frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }

        /// Lays out and lets a run loop pass apply what the scroll changed; its CPU time in ms.
        func update() -> Double {
            let start = cpu()
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            hosting.layoutSubtreeIfNeeded()
            return Double(cpu() - start) / 1e6
        }
        _ = update()
        let first = Double(cpu() - firstStart) / 1e6
        let firstRows = HistoryRenderCounts.rows
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        let clock = ContinuousClock()
        func render() -> Double { ms(clock.measure { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }) }

        let scrollView = try #require(Self.firstScrollView(in: hosting))
        HistoryRenderCounts.reset()
        var updates: [Double] = [], renders: [Double] = []
        var y: CGFloat = 0
        while y < 12_000, let document = scrollView.documentView,
              y < document.frame.height - scrollView.contentView.bounds.height {
            y += 30
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            let before = HistoryRenderCounts.rows
            updates.append(update())
            if ProcessInfo.processInfo.environment["HOME_SCROLL_TRACE"] != nil {
                print(String(format: "[trace] y %.0f: %.2f ms, %d rows", y, updates.last!, HistoryRenderCounts.rows - before))
            }
            if updates.count % 25 == 0 { renders.append(render()) }
        }
        func stats(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "mean %.2f ms, p90 %.2f ms, p99 %.1f ms, max %.1f ms",
                          values.reduce(0, +) / Double(max(1, values.count)),
                          sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.9)],
                          sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.99)], sorted.last ?? 0)
        }
        let census = Census(hosting)
        print(String(format: "[home-scroll] %d entries: first layout %.0f ms (%d row bodies); scrolled %.0f pt in %d steps",
                     count, first, firstRows, y, updates.count))
        print(String(format: "[home-scroll]   update+layout: %@; total %.0f ms; %d steps > 8.3 ms, %d > 16.7 ms",
                     stats(updates), updates.reduce(0, +), updates.filter { $0 > 8.33 }.count,
                     updates.filter { $0 > 16.7 }.count))
        print("[home-scroll]   row bodies while scrolling: \(HistoryRenderCounts.rows), "
              + "versions menus built: \(HistoryRenderCounts.versionsMenus)")
        print("[home-scroll]   offscreen render: \(stats(renders))")
        print("[home-scroll]   views at the end: \(census.views), focus rings \(census.focusRings)")
    }

    /// Every AppKit view under the page, and SwiftUI's focus-ring platform views among them.
    struct Census {
        var views = 0, focusRings = 0

        init(_ root: NSView) {
            func walk(_ view: NSView) {
                views += 1
                if String(describing: type(of: view)).contains("FocusRing") { focusRings += 1 }
                view.subviews.forEach(walk)
            }
            walk(root)
        }
    }

    /// `count` entries made from the preview fixtures, one every `interval` (40 minutes) going back from `now`.
    static func entries(_ count: Int, every interval: TimeInterval = 40 * 60, before now: Date = Date()) -> [TranscriptEntry] {
        let templates = PreviewFixtures.history()
        return (0..<count).map { i in
            let t = templates[i % templates.count]
            return TranscriptEntry(createdAt: now.addingTimeInterval(-Double(i) * interval - 60), engine: t.engine,
                                   status: t.status, audioDuration: t.audioDuration, voicedSeconds: t.voicedSeconds,
                                   errorMessage: t.errorMessage, audioFileName: t.audioFileName, versions: t.versions,
                                   current: t.currentKind)
        }
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = firstScrollView(in: sub) { return found } }
        return nil
    }

    private func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
#endif
