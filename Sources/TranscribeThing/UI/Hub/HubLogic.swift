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
    /// Words in the day's transcripts, for the header.
    var words = 0
}

enum HistoryGrouping {
    /// Newest day first, newest entry first within a day.
    static func days(_ entries: [TranscriptEntry], now: Date = Date(), calendar: Calendar = .current) -> [HistoryDay] {
        let sorted = entries.sorted { $0.createdAt > $1.createdAt }
        var days: [HistoryDay] = []
        for entry in sorted {
            let start = calendar.startOfDay(for: entry.createdAt)
            if days.last?.id != start {
                days.append(HistoryDay(id: start, title: Fmt.relativeDay(entry.createdAt, now: now, calendar: calendar),
                                       entries: []))
            }
            days[days.count - 1].entries.append(entry)
            days[days.count - 1].words += entry.wordCount
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

/// What went wrong with a local model in `.failed`, read from the error ModelStore kept for it.
enum ModelFailure: Equatable {
    case download, disk, load

    init(_ error: AppError?) {
        switch error {
        case .modelLoadFailed?: self = .load
        case .notEnoughDisk?: self = .disk
        default: self = .download
        }
    }

    /// "Download failed", "Not enough space", "Couldn’t load".
    var label: String {
        switch self {
        case .download: "Download failed"
        case .disk: "Not enough space"
        case .load: "Couldn’t load"
        }
    }
}

enum EngineReadiness: Equatable {
    /// Can transcribe now (a downloaded local model loads on first use).
    case ready
    /// Downloading or optimizing: a dictation waits for it.
    case warming
    case needsDownload
    case needsKey
    case keyProblem(String)
    /// A short reason: "Download failed", "Couldn’t load".
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
        case .keyProblem(let reason), .failed(let reason): reason
        }
    }

    /// `localError` is the error ModelStore kept for a failed local model.
    static func of(_ engine: EngineID, localState: LocalModelState, keyStatus: KeyStatus,
                   localError: AppError? = nil) -> EngineReadiness {
        if engine.isLocal {
            switch localState {
            case .ready, .installed: return .ready
            case .downloading, .preparing: return .warming
            case .notInstalled: return .needsDownload
            case .failed: return .failed(ModelFailure(localError).label)
            }
        }
        switch keyStatus {
        case .valid, .checking, .offline, .failed: return .ready
        case .missing: return .needsKey
        case .invalid: return .keyProblem("Key rejected")
        case .noCredit: return .keyProblem(keyStatus.isKeyLimitReached ? "Key limit reached" : "No credit")
        }
    }
}

// MARK: - Versions

/// A History row's Versions menu: the transcripts the recording already has (`versions`, the current one checked)
/// and what can still make another one (`actions`): each engine not used on it yet, and a clean-up of each Parakeet
/// version not cleaned up yet. A model never runs twice on the same recording. A failed or canceled dictation has
/// no versions, and every engine retries it, its own included. Unavailable actions stay listed, disabled, with the
/// reason; versions can always be switched to, even without the audio.
struct VersionsMenu: Equatable {
    /// Why an action can't run right now.
    enum Blocker: Equatable {
        /// The engine or the key isn't ready: "Needs key", "Key rejected", "Not downloaded" (`EngineReadiness`).
        case engine(String)
        case tooLongForGemini
        /// The audio is no longer kept (a clean-up needs only the text, so never this).
        case recordingGone
        /// Something is already running for this recording.
        case running(TranscriptVersionKind)
        /// Clean-up has no prompt to follow.
        case cleanupPromptEmpty

        var label: String {
            switch self {
            case .engine(let reason): reason
            case .tooLongForGemini: "Too long for Gemini"
            case .recordingGone: "Recording no longer kept"
            case .running: "Busy"
            case .cleanupPromptEmpty: "Needs a clean-up prompt"
            }
        }
    }

    struct Version: Equatable, Identifiable {
        var kind: TranscriptVersionKind
        /// "76 s · $0.07 · 17.7k thinking"; empty when nothing is known.
        var summary: String
        var isCurrent: Bool

        var id: TranscriptVersionKind { kind }
        /// "Gemini 3.8 Flash", "Parakeet v3 + Clean-up".
        var title: String { kind.displayName }
        /// The menu item: `title`, then `summary` set off by an em space: "Gemini 3.8 Flash  76 s · $0.07".
        var itemTitle: String { summary.isEmpty ? title : "\(title)\u{2003}\(summary)" }
    }

    struct Action: Equatable, Identifiable {
        var kind: TranscriptVersionKind
        var blocker: Blocker?
        /// A clean-up names the text it tidies: the recording has more than one Parakeet version to clean up.
        var namesSource = false

        var id: TranscriptVersionKind { kind }
        var isEnabled: Bool { blocker == nil }
        /// "Gemini 3.1 Pro", "Clean Up", "Clean Up Parakeet v3 · Cloud".
        var name: String {
            switch kind {
            case .transcription(let engine): engine.displayName
            case .cleanup(let source): namesSource ? "Clean Up \(source.displayName)" : "Clean Up"
            }
        }
        /// `name`, with the reason when it can't run: "Gemini 3.1 Pro · Needs key".
        var title: String {
            blocker.map { "\(name) · \($0.label)" } ?? name
        }
    }

    /// A failed or canceled dictation: `actions` retry it.
    var isRetry: Bool
    /// "Versions" for a transcript, "Retry With" for a failed or canceled dictation.
    var title: String
    /// Oldest first.
    var versions: [Version]
    /// Engines in `EngineID` order, then clean-ups.
    var actions: [Action]
    /// What is running for the recording right now: "Transcribing with Gemini Flash…", "Cleaning up…".
    var runningTitle: String?

    static let versionsSectionTitle = "Versions"
    static let actionsSectionTitle = "Transcribe With"

    /// `running`: what is being made for this recording right now. `readiness`: each engine's (a clean-up needs the
    /// OpenRouter key like Gemini, so it goes by Gemini Flash's). `hasCleanupPrompt`: the clean-up prompt isn't empty.
    static func make(for entry: TranscriptEntry, running: TranscriptVersionKind?,
                     readiness: (EngineID) -> EngineReadiness, hasCleanupPrompt: Bool) -> VersionsMenu {
        let isRetry = entry.status != .success
        let hasAudio = entry.audioFileName != nil
        let versions = entry.versions.map {
            Version(kind: $0.kind, summary: $0.metadata.summary, isCurrent: $0.kind == entry.currentKind)
        }
        let busy = running.map(Blocker.running)
        var actions = EngineID.allCases.filter { isRetry || !entry.hasVersion(.transcription($0)) }.map { engine in
            let tooLong = engine.cloudAPI == .chatCompletions
                && !OpenRouterClient.fitsOneChatRequest(duration: entry.audioDuration)
            let blocker = busy ?? (hasAudio ? nil : .recordingGone)
                ?? readiness(engine).unavailableReason.map(Blocker.engine) ?? (tooLong ? .tooLongForGemini : nil)
            return Action(kind: .transcription(engine), blocker: blocker)
        }
        if !isRetry {
            for version in entry.versions {
                guard case .transcription(let source) = version.kind, CleanupModel.canClean(source),
                      !entry.hasVersion(.cleanup(of: source)) else { continue }
                let blocker = busy ?? (hasCleanupPrompt ? nil : .cleanupPromptEmpty)
                    ?? readiness(.geminiFlash).unavailableReason.map(Blocker.engine)
                actions.append(Action(kind: .cleanup(of: source), blocker: blocker))
            }
            let cleanups = actions.indices.filter { actions[$0].kind.isCleanup }
            if cleanups.count > 1 { for index in cleanups { actions[index].namesSource = true } }
        }
        let runningTitle = running.map { kind in
            kind.isCleanup ? "Cleaning up…" : "Transcribing with \(kind.engine.shortName)…"
        }
        return VersionsMenu(isRetry: isRetry, title: title(for: entry), versions: versions, actions: actions,
                            runningTitle: runningTitle)
    }

    /// `title` without making the rest of the menu.
    static func title(for entry: TranscriptEntry) -> String {
        entry.status == .success ? "Versions" : "Retry With"
    }
}

/// A History transcript's facts, for the tooltip on its engine badge and the version items of its Versions menu:
/// which model and provider made it, how hard it thought, its tokens, cost and timing. Lines with nothing known are
/// left out, so a local transcript says little and an old one only what older builds recorded.
enum VersionDetails {
    /// "Gemini 3.8 Flash · Google AI Studio", "Thinking: Low", "Tokens: 330 in (314 audio) · 72 out · 540 thinking",
    /// "Cost: $0.0021", "Took 2.6 s · model 2.2 s", "System prompt: none".
    static func lines(for version: TranscriptVersion) -> [String] {
        let m = version.metadata
        var lines: [String] = []
        lines.append(version.kind.displayName)
        if version.kind.isCleanup {
            lines.append("Cleaned up by \(CleanupModel.modelName)")
        }
        var source: [String] = []
        if let model = m.modelID, !model.isEmpty { source.append(model) }
        if let provider = m.provider, !provider.isEmpty { source.append("via \(provider)") }
        if !source.isEmpty { lines.append(source.joined(separator: " ")) }
        if let effort = m.reasoningEffort { lines.append("Thinking: \(effort.title)") }
        if let tokens = m.usage.flatMap(tokenLine) { lines.append("Tokens: \(tokens)") }
        if let cost = m.costUSD, cost > 0 { lines.append("Cost: \(Fmt.usd(cost))") }
        if let time = timeLine(m) { lines.append(time) }
        if let seconds = m.audioSeconds, seconds > 0 { lines.append("Audio billed: \(Fmt.seconds(seconds))") }
        if let used = m.usedSystemPrompt { lines.append(used ? "System prompt: yes" : "System prompt: none") }
        if let reason = m.finishReason, !reason.isEmpty, reason != "stop" { lines.append("Finished: \(reason)") }
        return lines
    }

    /// The tooltip: `lines` one per line.
    static func tooltip(for version: TranscriptVersion) -> String {
        lines(for: version).joined(separator: "\n")
    }

    /// "330 in (314 audio) · 72 out · 540 thinking"; nil when nothing was counted.
    static func tokenLine(_ usage: TokenUsage) -> String? {
        var parts: [String] = []
        if let prompt = usage.promptTokens {
            let audio = usage.audioTokens.flatMap { $0 > 0 ? " (\(Fmt.tokens($0)) audio)" : nil } ?? ""
            parts.append("\(Fmt.tokens(prompt)) in\(audio)")
        }
        if let output = usage.outputTokens { parts.append("\(Fmt.tokens(output)) out") }
        if let reasoning = usage.reasoningTokens, reasoning > 0 { parts.append("\(Fmt.tokens(reasoning)) thinking") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Took 76 s · first word 3.1 s · model 70 s": the wall clock on this Mac, then what only the server or a
    /// stream can tell. OpenRouter's `latency` stays out: what it measures is unverified.
    private static func timeLine(_ m: TranscriptMetadata) -> String? {
        var parts: [String] = []
        if let time = m.processingTime { parts.append("Took \(Fmt.seconds(time))") }
        if let ttft = m.timeToFirstToken { parts.append("first word \(Fmt.seconds(ttft))") }
        if let generation = m.generationTime { parts.append("model \(Fmt.seconds(generation))") }
        guard !parts.isEmpty else { return nil }
        var line = parts.joined(separator: " · ")
        if m.processingTime == nil { line = line.prefix(1).uppercased() + line.dropFirst() }
        return line
    }
}

/// The sidebar footer chip for the main model: "Parakeet v3 · Ready", "Parakeet v3 · Optimizing…",
/// "Parakeet v3 · Cloud · Needs key".
struct EngineSummary: Equatable {
    var name: String
    var status: String
    var tone: StatusTone

    static func make(engine: EngineID, localState: LocalModelState, keyStatus: KeyStatus,
                     localError: AppError? = nil) -> EngineSummary {
        let name = engine.shortName
        if engine.isLocal {
            switch localState {
            case .ready, .installed: return EngineSummary(name: name, status: "Ready", tone: .positive)
            case .downloading(let p): return EngineSummary(name: name, status: "Downloading \(p.percent)%", tone: .progress)
            case .preparing: return EngineSummary(name: name, status: "Optimizing…", tone: .progress)
            case .notInstalled: return EngineSummary(name: name, status: "Not downloaded", tone: .negative)
            case .failed: return EngineSummary(name: name, status: ModelFailure(localError).label, tone: .negative)
            }
        }
        switch keyStatus {
        case .valid: return EngineSummary(name: name, status: "Ready", tone: .positive)
        case .checking: return EngineSummary(name: name, status: "Checking key…", tone: .progress)
        case .missing: return EngineSummary(name: name, status: "Needs key", tone: .negative)
        case .invalid: return EngineSummary(name: name, status: "Key rejected", tone: .negative)
        case .noCredit:
            return EngineSummary(name: name, status: keyStatus.isKeyLimitReached ? "Key limit reached" : "Out of credit",
                                 tone: .negative)
        case .offline: return EngineSummary(name: name, status: "Offline", tone: .warning)
        case .failed: return EngineSummary(name: name, status: "Couldn’t check key", tone: .warning)
        }
    }
}

/// Who serves a cloud model, as the Models page says it: "Served by Together.", or "… only." for Gemini, whose
/// requests are pinned to Google AI Studio. nil for the local model.
enum ProviderNote {
    static func text(_ engine: EngineID) -> String? {
        guard let provider = engine.provider else { return nil }
        return engine.cloudAPI == .chatCompletions ? "Served by \(provider) only." : "Served by \(provider)."
    }
}

// MARK: - Extra models

/// What the Models page says about the extra models: the Switch model shortcut steps through the ones switched on,
/// for one dictation at a time.
enum ExtraModels {
    enum Status: Equatable {
        /// The shortcut switches between the main model and the enabled extra models.
        case ready(Shortcut)
        /// Every extra model is off: the shortcut isn't intercepted, even while dictating.
        case noneEnabled(Shortcut?)
        /// Switch model has no shortcut, so nothing switches.
        case unbound
    }

    static func status(binding: Shortcut?, enabled: [EngineID]) -> Status {
        guard !enabled.isEmpty else { return .noneEnabled(binding) }
        guard let binding, !binding.isEmpty else { return .unbound }
        return .ready(binding)
    }

    /// One line under the "Extra models" heading, with the user's own binding: "Press fn ⇥ while dictating to use
    /// one for that dictation."
    static func explanation(_ status: Status) -> String {
        switch status {
        case .ready(let binding):
            "Press \(binding.compactDescription) while dictating to use one for that dictation."
        case .noneEnabled(let binding?) where !binding.isEmpty:
            "Turn one on to use it when you press \(binding.compactDescription) while dictating."
        case .noneEnabled:
            "Turn one on and give Switch model a shortcut to use it while dictating."
        case .unbound:
            "Switch model has no shortcut yet. Set one to use these while dictating."
        }
    }

    /// `enabled` with `engine` switched on or off, in the order the shortcut steps through them.
    static func setting(_ engine: EngineID, on: Bool, in enabled: [EngineID]) -> [EngineID] {
        let others = enabled.filter { $0 != engine }
        return AppSettings.normalizedSwitchEngines(on ? others + [engine] : others)
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
        /// The error ModelStore kept for a failed local model.
        var localError: AppError? = nil
        /// The shortcut's event tap has stayed down (it can while Accessibility still reads as granted).
        var shortcutUnavailable = false
    }

    /// Most blocking first: microphone, accessibility, the selected model or key, then the fn key setting.
    static func items(_ input: Input) -> [AttentionItem] {
        var items: [AttentionItem] = []

        switch input.microphone {
        case .granted:
            break
        case .denied:
            items.append(AttentionItem(
                id: "microphone", tone: .error, symbol: "mic.slash.fill", title: "\(Brand.name) can’t hear you",
                body: "Microphone access is off. Turn it on in System Settings.",
                actionTitle: "Open Settings", action: .openPane(.microphone)))
        case .notDetermined:
            items.append(AttentionItem(
                id: "microphone", tone: .warning, symbol: "mic.fill", title: "\(Brand.name) needs your microphone",
                body: "Allow access so \(Brand.name) can hear you while you hold the key.",
                actionTitle: "Allow", action: .requestMicrophone))
        }

        // Without Accessibility there is no event tap: the shortcut does nothing, not just the paste.
        let shortcut = input.pushToTalkUsesFn ? "fn" : "your shortcut"
        if input.accessibility != .granted {
            if input.accessibilityLikelyStale {
                items.append(AttentionItem(
                    id: "accessibility", tone: .error, symbol: "accessibility", title: "macOS needs to trust \(Brand.name) again",
                    body: "\(Brand.name) was updated, so \(shortcut) does nothing yet. Remove it from Accessibility, then add it back.",
                    actionTitle: "Open Settings", action: .openPane(.accessibility)))
            } else {
                items.append(AttentionItem(
                    id: "accessibility", tone: .error, symbol: "accessibility", title: "\(Brand.name) can’t hear your shortcut",
                    body: "Turn on Accessibility so \(shortcut) works and text pastes where you type.",
                    actionTitle: "Fix", action: .requestAccessibility))
            }
        } else if input.shortcutUnavailable {
            items.append(AttentionItem(
                id: "accessibility", tone: .error, symbol: "keyboard", title: "\(Brand.name) can’t hear your shortcut",
                body: "macOS stopped sending key presses to \(Brand.name). Turn \(Brand.name) off and on again in Accessibility.",
                actionTitle: "Open Settings", action: .openPane(.accessibility)))
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
                    body: "Optimizing for your Mac. This takes about half a minute after installing or updating.",
                    actionTitle: "View", action: .openModels, isIndeterminate: true))
            case .failed(let message):
                let title = ModelFailure(input.localError) == .load ? "Couldn’t load \(name)" : "\(name) didn’t finish downloading"
                items.append(AttentionItem(
                    id: "model", tone: .error, symbol: "exclamationmark.triangle.fill", title: title,
                    body: message.isEmpty ? "Something went wrong. Try again." : message,
                    actionTitle: "Retry", action: .download(input.engine)))
            }
        } else {
            // Same naming as the OpenRouter notices: "Gemini" for either Gemini, the model for cloud speech.
            let service = input.engine.cloudAPI == .transcriptions ? input.engine.shortName : "Gemini"
            switch input.keyStatus {
            case .valid, .checking, .offline, .failed:
                break
            case .missing:
                items.append(AttentionItem(
                    id: "key", tone: .error, symbol: "key.fill", title: "Add your OpenRouter key",
                    body: "\(input.engine.shortName) needs a key to transcribe.",
                    actionTitle: "Add Key", action: .openModels))
            case .invalid:
                items.append(AttentionItem(
                    id: "key", tone: .error, symbol: "key.fill", title: "Your OpenRouter key stopped working",
                    body: "It may be revoked or mistyped.",
                    actionTitle: "Update Key", action: .openModels))
            case .noCredit where input.keyStatus.isKeyLimitReached:
                items.append(AttentionItem(
                    id: "key", tone: .error, symbol: "creditcard", title: "Your OpenRouter key hit its limit",
                    body: "This key has a spending limit, and it’s used up. Raise it to keep using \(service).",
                    actionTitle: "Raise Limit", action: .openURL(OpenRouterLinks.keys)))
            case .noCredit:
                items.append(AttentionItem(
                    id: "key", tone: .error, symbol: "creditcard", title: "Out of OpenRouter credit",
                    body: "Add credit to keep using \(service).",
                    actionTitle: "Add Credit", action: .openURL(OpenRouterLinks.credits)))
            }
        }

        if input.pushToTalkUsesFn, case .other(let feature) = input.fnKeyUsage {
            items.append(AttentionItem(
                id: "fnKey", tone: .warning, symbol: "globe", title: "The fn key opens \(feature)",
                body: "Set “Press fn key to” to “Do Nothing” so holding it only talks to \(Brand.name).",
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

    /// Days of audio kept for successful dictations (Transcribe Again); 0 = off.
    static let transcribeAgainDays = [0, 1, 7]

    static func transcribeAgainLabel(_ days: Int) -> String {
        days == 0 ? "Off" : label(days)
    }
}

// MARK: - Sidebar

extension HubSection {
    /// Sidebar pages, top to bottom. ⌘1…⌘N follow this order.
    static let sidebar: [HubSection] = [.home, .models, .shortcuts, .microphone, .general]

    /// The digit of the ⌘-shortcut that opens this page ("1" for Home), or nil when it has no sidebar item.
    var shortcutDigit: Character? {
        HubSection.sidebar.firstIndex(of: self).map { Character(String($0 + 1)) }
    }

    /// The sidebar item that reads as selected on this page: itself, or General for Software Update.
    var sidebarItem: HubSection {
        switch self {
        case .softwareUpdate: .general
        case .home, .models, .shortcuts, .microphone, .general: self
        }
    }
}

// MARK: - Pill

enum PillCaption {
    /// The line under "Show the pill" in General: what the chosen mode does.
    static func text(_ mode: PillMode) -> String {
        switch mode {
        case .always: "A slim bar waits at the bottom of the screen."
        case .whileDictating: "Appears when you start talking, then steps aside."
        case .never: "Nothing on screen while you dictate. Notices still appear."
        }
    }
}
