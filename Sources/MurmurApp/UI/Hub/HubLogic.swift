import Foundation

// Pure, UI-free decisions behind the Hub pages (greeting, grouping, stats formatting, readiness, attention cards).
// Kept separate from the views so they can be unit-tested without rendering.

// MARK: - Greeting

enum HubGreeting {
    enum DayPart: Equatable { case morning, afternoon, evening }

    static func dayPart(for date: Date, calendar: Calendar = .current) -> DayPart {
        switch calendar.component(.hour, from: date) {
        case 5..<12: .morning
        case 12..<18: .afternoon
        default: .evening
        }
    }

    static func text(for date: Date, name: String?, calendar: Calendar = .current) -> String {
        let base = switch dayPart(for: date, calendar: calendar) {
        case .morning: "Good morning"
        case .afternoon: "Good afternoon"
        case .evening: "Good evening"
        }
        guard let name, !name.isEmpty else { return base }
        return "\(base), \(name)"
    }

    /// First word of the full name ("Sam Smith" → "Sam"); falls back to the capitalized account name.
    static func firstName(fullName: String, accountName: String) -> String? {
        if let first = fullName.split(whereSeparator: \.isWhitespace).first, !first.isEmpty {
            return String(first)
        }
        let account = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let initial = account.first else { return nil }
        return initial.uppercased() + account.dropFirst()
    }
}

// MARK: - History

struct HistoryDay: Identifiable, Equatable {
    /// Start of the day.
    let id: Date
    let title: String
    var entries: [TranscriptEntry]
}

enum HistoryGrouping {
    /// Newest day first, newest entry first within a day.
    static func days(_ entries: [TranscriptEntry], now: Date = Date(), calendar: Calendar = .current) -> [HistoryDay] {
        let sorted = entries.sorted { $0.createdAt > $1.createdAt }
        var days: [HistoryDay] = []
        for entry in sorted {
            let start = calendar.startOfDay(for: entry.createdAt)
            if let last = days.indices.last, days[last].id == start {
                days[last].entries.append(entry)
            } else {
                days.append(HistoryDay(id: start, title: Fmt.relativeDay(entry.createdAt, now: now, calendar: calendar),
                                       entries: [entry]))
            }
        }
        return days
    }

    /// Case- and diacritic-insensitive match on the transcript and the failure reason.
    static func filter(_ entries: [TranscriptEntry], query: String) -> [TranscriptEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return entries.filter { entry in
            entry.text.range(of: needle, options: options) != nil
                || (entry.errorMessage?.range(of: needle, options: options) != nil)
        }
    }
}

// MARK: - Stats

struct StatPart: Equatable {
    var value: String
    var unit: String

    /// Shown until there is enough data (average speed with no dictations yet).
    static let noValue = "–"
}

enum StatFormat {
    /// "45 s", "12 m", "1 h 12 m", "3 h".
    static func timeSaved(_ seconds: TimeInterval) -> [StatPart] {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
        if total == 0 { return [StatPart(value: "0", unit: "m")] }
        if total < 60 { return [StatPart(value: "\(total)", unit: "s")] }
        let minutes = total / 60
        if minutes < 60 { return [StatPart(value: "\(minutes)", unit: "m")] }
        let hours = minutes / 60, rest = minutes % 60
        var parts = [StatPart(value: Fmt.number(hours), unit: "h")]
        if rest > 0 { parts.append(StatPart(value: "\(rest)", unit: "m")) }
        return parts
    }

    /// Bar heights 0...1 for the 7-day sparkline, relative to the busiest day.
    static func sparkline(_ daily: [Int]) -> [Double] {
        let peak = daily.max() ?? 0
        guard peak > 0 else { return daily.map { _ in 0 } }
        return daily.map { Double($0) / Double(peak) }
    }
}

// MARK: - Engine readiness

enum EngineReadiness: Equatable {
    /// Can transcribe now (a downloaded local model loads on first use).
    case ready
    /// Downloading or optimizing: a dictation waits for it.
    case warming
    case needsDownload
    case needsKey
    case keyProblem(String)
    case failed(String)

    /// Picking it keeps dictation working.
    var isUsable: Bool {
        switch self {
        case .ready, .warming: true
        case .needsDownload, .needsKey, .keyProblem, .failed: false
        }
    }

    /// Suffix for disabled menu items: "Not downloaded", "Needs key".
    var unavailableReason: String? {
        switch self {
        case .ready, .warming: nil
        case .needsDownload: "Not downloaded"
        case .needsKey: "Needs key"
        case .keyProblem(let reason): reason
        case .failed: "Download failed"
        }
    }

    static func of(_ engine: EngineID, localState: LocalModelState, keyStatus: KeyStatus) -> EngineReadiness {
        if engine.isLocal {
            switch localState {
            case .ready, .installed: return .ready
            case .downloading, .preparing: return .warming
            case .notInstalled: return .needsDownload
            case .failed(let message): return .failed(message)
            }
        }
        switch keyStatus {
        case .valid, .checking, .offline, .failed: return .ready
        case .missing: return .needsKey
        case .invalid: return .keyProblem("Key rejected")
        case .noCredit: return .keyProblem("No credit")
        }
    }
}

/// The sidebar footer chip: "Parakeet v3 · Ready", "Whisper Turbo · Optimizing…", "Gemini Flash · Key missing".
struct EngineSummary: Equatable {
    var name: String
    var status: String
    var tone: StatusTone

    static func chipName(_ engine: EngineID) -> String {
        switch engine {
        case .parakeet: "Parakeet v3"
        case .whisper: "Whisper Turbo"
        case .geminiFlash: "Gemini Flash"
        case .geminiPro: "Gemini Pro"
        }
    }

    static func make(engine: EngineID, localState: LocalModelState, keyStatus: KeyStatus) -> EngineSummary {
        let name = chipName(engine)
        if engine.isLocal {
            switch localState {
            case .ready, .installed: return EngineSummary(name: name, status: "Ready", tone: .positive)
            case .downloading(let p): return EngineSummary(name: name, status: "Downloading \(p.percent)%", tone: .progress)
            case .preparing: return EngineSummary(name: name, status: "Optimizing…", tone: .progress)
            case .notInstalled: return EngineSummary(name: name, status: "Not downloaded", tone: .negative)
            case .failed: return EngineSummary(name: name, status: "Download failed", tone: .negative)
            }
        }
        switch keyStatus {
        case .valid: return EngineSummary(name: name, status: "Ready", tone: .positive)
        case .checking: return EngineSummary(name: name, status: "Checking key…", tone: .progress)
        case .missing: return EngineSummary(name: name, status: "Key missing", tone: .negative)
        case .invalid: return EngineSummary(name: name, status: "Key rejected", tone: .negative)
        case .noCredit: return EngineSummary(name: name, status: "Out of credit", tone: .negative)
        case .offline: return EngineSummary(name: name, status: "Offline", tone: .warning)
        case .failed: return EngineSummary(name: name, status: "Couldn’t check key", tone: .warning)
        }
    }
}

// MARK: - Attention cards

struct AttentionItem: Identifiable, Equatable {
    enum Tone: Equatable { case error, warning, progress }

    enum Action: Equatable {
        case requestMicrophone
        case requestAccessibility
        case openPane(SettingsPane)
        case download(EngineID)
        case openModels
        case openURL(URL)
    }

    var id: String
    var tone: Tone
    var symbol: String
    var title: String
    var body: String
    var actionTitle: String?
    var action: Action?
    /// Shows a thin progress bar (model download).
    var progress: Double?
    /// Shows an indeterminate shimmer (first-time optimizing).
    var isIndeterminate = false
}

enum HubAttention {
    struct Input: Equatable {
        var microphone: PermissionState
        var accessibility: PermissionState
        var accessibilityLikelyStale: Bool
        var fnKeyUsage: FnKeyUsage
        var pushToTalkUsesFn: Bool
        var engine: EngineID
        var localState: LocalModelState
        var keyStatus: KeyStatus
    }

    /// Most blocking first: microphone, accessibility, the selected model or key, then the fn key setting.
    static func items(_ input: Input) -> [AttentionItem] {
        var items: [AttentionItem] = []

        switch input.microphone {
        case .granted:
            break
        case .denied:
            items.append(AttentionItem(
                id: "microphone", tone: .error, symbol: "mic.slash.fill", title: "Murmur can’t hear you",
                body: "Microphone access is off. Turn it on in System Settings.",
                actionTitle: "Open Settings", action: .openPane(.microphone)))
        case .notDetermined:
            items.append(AttentionItem(
                id: "microphone", tone: .warning, symbol: "mic.fill", title: "Murmur needs your microphone",
                body: "Allow access so Murmur can hear you while you hold the key.",
                actionTitle: "Allow", action: .requestMicrophone))
        }

        if input.accessibility != .granted {
            if input.accessibilityLikelyStale {
                items.append(AttentionItem(
                    id: "accessibility", tone: .warning, symbol: "accessibility", title: "macOS needs to trust Murmur again",
                    body: "Murmur was updated. Remove it from Accessibility, then add it back.",
                    actionTitle: "Open Settings", action: .openPane(.accessibility)))
            } else {
                items.append(AttentionItem(
                    id: "accessibility", tone: .warning, symbol: "accessibility", title: "Murmur can’t paste yet",
                    body: "Accessibility is off, so transcripts go to the clipboard instead.",
                    actionTitle: "Fix", action: .requestAccessibility))
            }
        }

        let name = input.engine.displayName
        if input.engine.isLocal {
            switch input.localState {
            case .ready, .installed:
                break
            case .notInstalled:
                let size = input.engine.approxDownloadBytes.map { " (\(Fmt.bytes($0)))" } ?? ""
                items.append(AttentionItem(
                    id: "model", tone: .error, symbol: "arrow.down.circle", title: "\(name) isn’t downloaded yet",
                    body: "Download it\(size) to start dictating, or pick another model.",
                    actionTitle: "Download", action: .download(input.engine)))
            case .downloading(let progress):
                let eta = progress.secondsRemaining.map { sentence(Fmt.eta($0)) }
                items.append(AttentionItem(
                    id: "model", tone: .progress, symbol: "arrow.down.circle", title: "\(name) is downloading · \(progress.percent)%",
                    body: eta ?? "You can dictate as soon as it’s ready.",
                    actionTitle: "View", action: .openModels, progress: progress.fraction))
            case .preparing:
                items.append(AttentionItem(
                    id: "model", tone: .progress, symbol: "cpu", title: "Getting \(input.engine.shortName) ready",
                    body: "Optimizing for your Mac. This can take a few minutes after installing or updating.",
                    actionTitle: "View", action: .openModels, isIndeterminate: true))
            case .failed(let message):
                items.append(AttentionItem(
                    id: "model", tone: .error, symbol: "exclamationmark.triangle.fill", title: "\(name) didn’t finish downloading",
                    body: message.isEmpty ? "Something went wrong. Try again." : message,
                    actionTitle: "Retry", action: .download(input.engine)))
            }
        } else {
            switch input.keyStatus {
            case .valid, .checking, .offline, .failed:
                break
            case .missing:
                items.append(AttentionItem(
                    id: "key", tone: .error, symbol: "key.fill", title: "Add your OpenRouter key",
                    body: "\(input.engine.shortName) needs a key to transcribe.",
                    actionTitle: "Add key", action: .openModels))
            case .invalid:
                items.append(AttentionItem(
                    id: "key", tone: .error, symbol: "key.fill", title: "Your OpenRouter key stopped working",
                    body: "It may be revoked or mistyped.",
                    actionTitle: "Update key", action: .openModels))
            case .noCredit:
                items.append(AttentionItem(
                    id: "key", tone: .error, symbol: "creditcard", title: "Out of OpenRouter credit",
                    body: "Add credit to keep using Gemini.",
                    actionTitle: "Add credit", action: .openURL(OpenRouterLinks.credits)))
            }
        }

        if input.pushToTalkUsesFn, case .other(let feature) = input.fnKeyUsage {
            items.append(AttentionItem(
                id: "fnKey", tone: .warning, symbol: "globe", title: "The fn key opens \(feature)",
                body: "Set “Press fn key to” to “Do Nothing” so holding it only talks to Murmur.",
                actionTitle: "Open Keyboard Settings", action: .openPane(.keyboard)))
        }
        return items
    }

    /// "about 30 s left" → "About 30 s left."
    static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst() + "."
    }
}

// MARK: - Choices

struct WhisperLanguage: Hashable, Sendable {
    var code: String
    var name: String

    static let all: [WhisperLanguage] = [
        .init(code: "en", name: "English"), .init(code: "ru", name: "Russian"), .init(code: "uk", name: "Ukrainian"),
        .init(code: "de", name: "German"), .init(code: "fr", name: "French"), .init(code: "es", name: "Spanish"),
        .init(code: "it", name: "Italian"), .init(code: "pt", name: "Portuguese"), .init(code: "nl", name: "Dutch"),
        .init(code: "pl", name: "Polish"), .init(code: "cs", name: "Czech"), .init(code: "sv", name: "Swedish"),
        .init(code: "tr", name: "Turkish"), .init(code: "ar", name: "Arabic"), .init(code: "hi", name: "Hindi"),
        .init(code: "ja", name: "Japanese"), .init(code: "ko", name: "Korean"), .init(code: "zh", name: "Chinese"),
    ]

    static func name(for code: String?) -> String {
        guard let code else { return "Automatic" }
        return all.first { $0.code == code }?.name ?? code.uppercased()
    }
}

enum RetentionChoice {
    /// Days of audio kept for failed or canceled dictations; 0 = don't keep.
    static let days = [0, 1, 7, 14, 30]

    static func label(_ days: Int) -> String {
        switch days {
        case 0: "Don’t keep"
        case 1: "1 day"
        default: "\(days) days"
        }
    }
}
