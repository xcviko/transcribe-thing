import Foundation

// STUB (FOUNDATION): ENGINES owns this file (`--transcribe`, `--model-status`, SPEC §2).
enum EngineCLI {
    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains("--transcribe") || arguments.contains("--model-status")
    }

    /// Runs the CLI mode and exits the process.
    @MainActor
    static func run(_ arguments: [String]) -> Never {
        FileHandle.standardError.write(Data("Engine CLI isn't available in this build yet.\n".utf8))
        exit(2)
    }
}
