import os

/// Unified logging. Never log transcript text at `.info` or above; use `.debug` with `privacy: .private`.
enum Log {
    static let subsystem = "dev.transcribe-thing.app"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let engine = Logger(subsystem: subsystem, category: "engine")
    static let net = Logger(subsystem: subsystem, category: "net")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
