import AppKit
import SwiftUI

/// `transcribe-thing --snapshots <outDir> [--only <prefix>] [--appearance light|dark]`
/// Renders every catalog entry offscreen to `<outDir>/<name>-<appearance>.png` at 2x and prints each path.
/// No services start and no permissions are touched.
@MainActor
enum SnapshotRunner {
    static func run(arguments: [String]) -> Int32 {
        guard let outPath = value(after: "--snapshots", in: arguments) else {
            printError("Usage: transcribe-thing --snapshots <outDir> [--only <prefix>] [--appearance light|dark]")
            return 64
        }
        let only = value(after: "--only", in: arguments)
        let appearances: [(label: String, name: NSAppearance.Name)]
        switch value(after: "--appearance", in: arguments) {
        case nil: appearances = [("light", .aqua), ("dark", .darkAqua)]
        case "light": appearances = [("light", .aqua)]
        case "dark": appearances = [("dark", .darkAqua)]
        case let other?:
            printError("Unknown appearance “\(other)”. Use light or dark.")
            return 64
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let outDir = URL(fileURLWithPath: outPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            printError("Couldn't create \(outDir.path): \(error.localizedDescription)")
            return 73
        }

        let entries = SnapshotCatalog.all.filter { entry in only.map { entry.name.hasPrefix($0) } ?? true }
        guard !entries.isEmpty else {
            printError("No snapshots match\(only.map { " “\($0)”" } ?? "").")
            return 1
        }

        var failures = 0
        for entry in entries {
            for appearance in appearances {
                let url = outDir.appendingPathComponent("\(entry.name)-\(appearance.label).png")
                let ok = autoreleasepool { () -> Bool in
                    guard let named = NSAppearance(named: appearance.name),
                          let png = render(entry, appearance: named) else { return false }
                    do {
                        try png.write(to: url, options: .atomic)
                        return true
                    } catch {
                        printError("Couldn't write \(url.path): \(error.localizedDescription)")
                        return false
                    }
                }
                if ok {
                    print(url.path)
                } else {
                    failures += 1
                    printError("Failed to render \(entry.name) (\(appearance.label)).")
                }
            }
        }
        return failures == 0 ? 0 : 1
    }

    /// Offscreen window + hosting view → `cacheDisplay` into a 2x bitmap. A fresh preview environment per
    /// render keeps entries independent.
    static func render(_ entry: SnapshotEntry, appearance: NSAppearance, scale: CGFloat = 2) -> Data? {
        let env = AppEnvironment.preview()
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let rect = NSRect(origin: .zero, size: entry.size)
        let root = entry.make(env)
            .appTheme()
            .frame(width: entry.size.width, height: entry.size.height)
            .environment(\.colorScheme, isDark ? .dark : .light)
            .environment(\.controlActiveState, .key)

        let hosting = NSHostingView(rootView: root)
        hosting.frame = rect
        hosting.appearance = appearance

        let window = SnapshotWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = hosting

        // Let SwiftUI settle: first layout, onAppear, state set in tasks.
        for _ in 0..<4 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((entry.size.width * scale).rounded()),
            pixelsHigh: Int((entry.size.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            // Draw straight into sRGB so viewers that ignore embedded profiles still show the true token colors.
            .retagging(with: .sRGB)
        else { return nil }
        rep.size = entry.size

        appearance.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        window.contentView = nil
        window.close()
        return rep.representation(using: .png, properties: [:])
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
        let value = arguments[i + 1]
        return value.hasPrefix("--") ? nil : value
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Renders controls in their active (key window) appearance, like a focused transcribe-thing window.
private final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
