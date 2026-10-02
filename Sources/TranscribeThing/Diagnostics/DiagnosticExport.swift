import Foundation

/// The file General → Troubleshooting → Export Logs… writes: a header that says which app, Mac and settings the log
/// comes from, then every line the log keeps, oldest first. Named for the minute it was made:
/// "transcribe-thing-logs-2026-10-02-1403.txt".
enum DiagnosticExport {
    static func fileName(at date: Date, timeZone: TimeZone = .current) -> String {
        "transcribe-thing-logs-\(DiagnosticTimeFormat(timeZone: timeZone).minute(date)).txt"
    }

    /// Ends with a blank line, ready for the log's lines.
    static func header(system: DiagnosticSystemInfo, settings: DiagnosticSettingsSummary, keySaved: Bool,
                       exportedAt date: Date, timeZone: TimeZone = .current, keptDays: Int) -> String {
        """
        transcribe-thing logs
        Exported: \(DiagnosticTimeFormat(timeZone: timeZone).timestamp(date))
        App: \(system.appVersion) (build \(system.build))
        macOS: \(system.macOS)
        Mac: \(system.macModel)
        OpenRouter key saved: \(keySaved ? "yes" : "no")
        Settings: \(settings.line)
        What follows: what the app did over the last \(keptDays) days, oldest first. Never your dictations, prompts, \
        audio, clipboard, key, window titles or the apps you paste into.


        """
    }

    /// The header, then the log's lines (or a word that there are none yet).
    static func contents(header: String, log: String) -> String {
        header + (log.isEmpty ? "(Nothing logged yet.)\n" : log)
    }
}
