import AppKit

/// Entry point, called from the executable's main.swift.
public enum TranscribeThingMain {
    /// NSApplication.delegate is weak: keep the delegate in a static, not a local.
    @MainActor private static var delegate: AppDelegate?

    /// `nonisolated` + `assumeIsolated` so a Swift 5 mode main.swift can call it (top-level code there
    /// isn't main-actor isolated). main.swift always runs on the main thread.
    public nonisolated static func run() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        MainActor.assumeIsolated {
            if arguments.contains("--snapshots") {
                exit(SnapshotRunner.run(arguments: arguments))
            }
            if EngineCLI.handles(arguments) {
                EngineCLI.run(arguments)
            }
            let app = NSApplication.shared
            let appDelegate = AppDelegate()
            delegate = appDelegate
            app.delegate = appDelegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}
