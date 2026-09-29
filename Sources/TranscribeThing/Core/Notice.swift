import Foundation

// MARK: - Notices (toasts and inline cards)

enum NoticeStyle: Sendable {
    case info, success, warning, error
}

enum NoticeLifetime: Sendable, Equatable {
    /// Nominal lifetime; the toast's countdown runs `ToastCountdown.speed` times faster, so `.seconds(10)` is
    /// on screen for 5 s.
    case seconds(Double)
    case sticky
}

enum NoticeActionKind: Sendable, Equatable {
    case openSettingsPane(SettingsPane)
    case openHub(HubSection)
    /// OpenRouter keys, credits and privacy pages.
    case openURL(URL)
    case download(EngineID)
    /// Retry the recording attached to the notice with the same engine.
    case retry
    case retryWith(EngineID)
    /// Switch the selected engine when there is no recording to retry.
    case selectEngine(EngineID)
    /// Undo a cancel: the dictation picks up again hands-free, its kept audio first.
    case undoCancel
    case copyText(String)
    case pasteText(String)
    case chooseMicrophone
    case useBuiltInMicrophone
    /// Open Software Update and install the newest release there, where its progress shows.
    case installUpdate
    case dismiss
}

struct NoticeAction: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var kind: NoticeActionKind
    var isPrimary: Bool

    init(id: UUID = UUID(), title: String, kind: NoticeActionKind, isPrimary: Bool = false) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isPrimary = isPrimary
    }
}

struct Notice: Identifiable, Equatable, Sendable {
    let id: UUID
    /// Posting a notice with the same key replaces the existing one in place.
    var dedupeKey: String
    var style: NoticeStyle
    /// SF Symbol name.
    var symbol: String
    var title: String
    var body: String?
    /// Non-nil renders the notice as a transcript card with selectable text.
    var transcript: String?
    /// At most two.
    var actions: [NoticeAction]
    var lifetime: NoticeLifetime
    var sound: SoundEffect?
    /// Recording the retry/undo actions refer to.
    var recordingID: UUID?

    init(
        id: UUID = UUID(),
        dedupeKey: String,
        style: NoticeStyle,
        symbol: String,
        title: String,
        body: String? = nil,
        transcript: String? = nil,
        actions: [NoticeAction] = [],
        lifetime: NoticeLifetime = .seconds(5),
        sound: SoundEffect? = nil,
        recordingID: UUID? = nil
    ) {
        self.id = id
        self.dedupeKey = dedupeKey
        self.style = style
        self.symbol = symbol
        self.title = title
        self.body = body
        self.transcript = transcript
        self.actions = Array(actions.prefix(2))
        self.lifetime = lifetime
        self.sound = sound
        self.recordingID = recordingID
    }

    var primaryAction: NoticeAction? { actions.first(where: \.isPrimary) }
}

extension Notice {
    static let shortcutUnavailableKey = "shortcut.unavailable"

    /// The event tap is down, so holding the shortcut does nothing. Sticky until the tap is back.
    /// `shortcut` is the push-to-talk hint ("fn").
    static func shortcutUnavailable(accessibility: PermissionState, likelyStale: Bool, shortcut: String) -> Notice {
        let title: String
        let body: String
        let fixTitle: String
        if accessibility != .granted && likelyStale {
            title = "macOS needs to trust \(Brand.name) again"
            body = "\(Brand.name) was updated, so \(shortcut) does nothing yet. Remove it from Accessibility, then add it back."
            fixTitle = "Open Settings"
        } else if accessibility != .granted {
            title = "\(Brand.name) can’t hear your shortcut"
            body = "Turn on Accessibility so \(shortcut) starts dictation and text pastes where you type."
            fixTitle = "Allow Access"
        } else {
            title = "\(Brand.name) can’t hear your shortcut"
            body = "macOS stopped sending key presses to \(Brand.name). Turn \(Brand.name) off and on again in Accessibility."
            fixTitle = "Open Settings"
        }
        return Notice(dedupeKey: shortcutUnavailableKey, style: .error, symbol: "keyboard", title: title, body: body,
                      actions: [NoticeAction(title: fixTitle, kind: .openSettingsPane(.accessibility), isPrimary: true),
                                NoticeAction(title: "Dismiss", kind: .dismiss)],
                      lifetime: .sticky)
    }
}

// MARK: - Destinations

enum SettingsPane: String, Sendable {
    case microphone, accessibility, inputMonitoring, keyboard, sound, storage

    /// System Settings deep link (verified anchors, macos-input.md §3.4).
    var url: URL {
        let raw: String = switch self {
        case .microphone: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .keyboard: "x-apple.systempreferences:com.apple.preference.keyboard"
        case .sound: "x-apple.systempreferences:com.apple.preference.sound?input"
        case .storage: "x-apple.systempreferences:com.apple.settings.Storage"
        }
        return URL(string: raw)!
    }
}

enum HubSection: String, CaseIterable, Sendable, Identifiable {
    case home, models, shortcuts, microphone, general
    /// A sub-page of General (no sidebar item of its own), like a pane inside System Settings.
    case softwareUpdate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .models: "Models"
        case .shortcuts: "Shortcuts"
        case .microphone: "Microphone"
        case .general: "General"
        case .softwareUpdate: "Software Update"
        }
    }

    var symbolName: String {
        switch self {
        case .home: "house"
        case .models: "square.stack.3d.up"
        case .shortcuts: "keyboard"
        case .microphone: "mic"
        case .general: "gearshape"
        case .softwareUpdate: "arrow.down.circle"
        }
    }
}

enum OpenRouterLinks {
    static let keys = URL(string: "https://openrouter.ai/settings/keys")!
    static let credits = URL(string: "https://openrouter.ai/settings/credits")!
    static let privacy = URL(string: "https://openrouter.ai/settings/privacy")!
}

// MARK: - Errors

enum AppError: Error, Equatable, Sendable {
    case microphonePermissionDenied
    case noMicrophone
    /// Engine start failure detail.
    case microphoneNotResponding(String)
    case microphoneDisconnected
    /// The whole recording was flat.
    case microphoneSilent
    case accessibilityMissing
    case modelNotDownloaded(EngineID)
    case modelDownloading(EngineID, Double)
    case modelPreparing(EngineID)
    case modelLoadFailed(EngineID, String)
    case downloadFailed(EngineID, String)
    case notEnoughDisk(needed: Int64, available: Int64)
    case openRouterMissingKey
    /// A key is stored, but the Keychain refused to hand it over (a denied or cancelled prompt).
    case openRouterKeyUnreadable
    case openRouterInvalidKey(String)
    case openRouterNoCredits(String)
    /// 402 from this key's own spending limit (the account may still have credit).
    case openRouterKeyLimit(String)
    case openRouterRateLimited(retryAfter: Double?)
    /// 404 / "No endpoints found": privacy, ZDR or allowed-provider settings.
    case openRouterNoRoute(String)
    case openRouterProviderUnavailable(String)
    /// 403, content_filter or refusal.
    case openRouterRefused(String)
    /// 400, 413, 422.
    case openRouterBadRequest(String)
    case openRouterServer(String)
    /// Gemini ran out of output tokens (a repetition loop, a cut-off ending, or reasoning that used them all);
    /// the partial text, empty when it wrote none.
    case openRouterTruncated(String)
    case timeout(EngineID)
    case offline
    /// Not a failure: the recording had no speech (too little voice for the recorder, or an engine that answered
    /// with no text). An info notice, never a history entry or a retry.
    case noSpeech
    case engineFailed(EngineID, String)
    case recordingTooLarge

    /// Re-running the same recording on the same engine could succeed.
    var isRetryable: Bool {
        switch self {
        case .microphoneDisconnected,
             .modelDownloading, .modelPreparing, .modelLoadFailed,
             .openRouterRateLimited, .openRouterProviderUnavailable, .openRouterServer, .openRouterTruncated,
             .timeout, .offline, .engineFailed:
            true
        case .microphonePermissionDenied, .noMicrophone, .microphoneNotResponding, .microphoneSilent,
             .accessibilityMissing, .modelNotDownloaded, .downloadFailed, .notEnoughDisk,
             .openRouterMissingKey, .openRouterKeyUnreadable, .openRouterInvalidKey, .openRouterNoCredits,
             .openRouterKeyLimit, .openRouterNoRoute, .openRouterRefused, .openRouterBadRequest, .noSpeech,
             .recordingTooLarge:
            false
        }
    }

    /// A brief OpenRouter or provider hiccup: the same request sent again a moment later can succeed.
    var isTransientCloudFailure: Bool {
        switch self {
        case .openRouterRateLimited, .openRouterProviderUnavailable, .openRouterServer: true
        default: false
        }
    }

    /// The key, the credit or the connection failed: every cloud model would fail the same way, so only the local
    /// model can take over.
    var stopsEveryCloudModel: Bool {
        switch self {
        case .openRouterMissingKey, .openRouterKeyUnreadable, .openRouterInvalidKey, .openRouterNoCredits,
             .openRouterKeyLimit, .offline:
            true
        default:
            false
        }
    }

    /// Another engine could transcribe the same recording (the failure is the engine's, not the audio's or the mic's).
    private var fallbackCanHelp: Bool {
        switch self {
        case .modelNotDownloaded, .modelDownloading, .modelPreparing, .modelLoadFailed,
             .openRouterMissingKey, .openRouterKeyUnreadable, .openRouterInvalidKey, .openRouterNoCredits,
             .openRouterKeyLimit, .openRouterRateLimited, .openRouterNoRoute, .openRouterProviderUnavailable,
             .openRouterRefused, .openRouterBadRequest, .openRouterServer, .openRouterTruncated, .timeout, .offline,
             .engineFailed, .recordingTooLarge:
            true
        case .microphonePermissionDenied, .noMicrophone, .microphoneNotResponding, .microphoneDisconnected,
             .microphoneSilent, .accessibilityMissing, .downloadFailed, .notEnoughDisk, .noSpeech:
            false
        }
    }

    /// Stable identifier of the case, used for dedupe keys and logs.
    var code: String {
        switch self {
        case .microphonePermissionDenied: "microphonePermissionDenied"
        case .noMicrophone: "noMicrophone"
        case .microphoneNotResponding: "microphoneNotResponding"
        case .microphoneDisconnected: "microphoneDisconnected"
        case .microphoneSilent: "microphoneSilent"
        case .accessibilityMissing: "accessibilityMissing"
        case .modelNotDownloaded(let e): "modelNotDownloaded.\(e.rawValue)"
        case .modelDownloading(let e, _): "modelDownloading.\(e.rawValue)"
        case .modelPreparing(let e): "modelPreparing.\(e.rawValue)"
        case .modelLoadFailed(let e, _): "modelLoadFailed.\(e.rawValue)"
        case .downloadFailed(let e, _): "downloadFailed.\(e.rawValue)"
        case .notEnoughDisk: "notEnoughDisk"
        case .openRouterMissingKey: "openRouterMissingKey"
        case .openRouterKeyUnreadable: "openRouterKeyUnreadable"
        case .openRouterInvalidKey: "openRouterInvalidKey"
        case .openRouterNoCredits: "openRouterNoCredits"
        case .openRouterKeyLimit: "openRouterKeyLimit"
        case .openRouterRateLimited: "openRouterRateLimited"
        case .openRouterNoRoute: "openRouterNoRoute"
        case .openRouterProviderUnavailable: "openRouterProviderUnavailable"
        case .openRouterRefused: "openRouterRefused"
        case .openRouterBadRequest: "openRouterBadRequest"
        case .openRouterServer: "openRouterServer"
        case .openRouterTruncated: "openRouterTruncated"
        case .timeout(let e): "timeout.\(e.rawValue)"
        case .offline: "offline"
        case .noSpeech: "noSpeech"
        case .engineFailed(let e, _): "engineFailed.\(e.rawValue)"
        case .recordingTooLarge: "recordingTooLarge"
        }
    }

    /// Technical detail carried by the case (never shown as a title).
    var detail: String? {
        switch self {
        case .microphoneNotResponding(let s), .modelLoadFailed(_, let s), .downloadFailed(_, let s),
             .openRouterInvalidKey(let s), .openRouterNoCredits(let s), .openRouterKeyLimit(let s), .openRouterNoRoute(let s),
             .openRouterProviderUnavailable(let s), .openRouterRefused(let s), .openRouterBadRequest(let s),
             .openRouterServer(let s), .engineFailed(_, let s):
            s.isEmpty ? nil : s
        default:
            nil
        }
    }
}

extension AppError: LocalizedError {
    var errorDescription: String? {
        let n = notice(recordingID: nil, fallbackEngine: nil)
        guard let body = n.body, !body.isEmpty else { return n.title }
        return "\(n.title). \(body)"
    }
}

extension AppError {
    /// Canonical copy per the error catalog (wispr-ux.md §5.9, adapted).
    /// `recordingID` non-nil means the audio is retained, which enables Retry and Retry-with actions.
    /// `fallbackEngine` is a ready engine other than the failing one. `engine` is the engine the error came
    /// from: OpenRouter errors name it ("Parakeet v3 · Cloud is rate-limited"), and say "Gemini" without it.
    func notice(recordingID: UUID?, fallbackEngine: EngineID?, engine: EngineID? = nil) -> Notice {
        let copy = self.copy(for: engine)
        let hasAudio = recordingID != nil
        let fallback = fallbackEngine.flatMap { $0 == failingEngine ? nil : $0 }

        var actions: [NoticeAction] = []
        func add(_ title: String, _ kind: NoticeActionKind) {
            guard actions.count < 2, !actions.contains(where: { $0.kind == kind }) else { return }
            actions.append(NoticeAction(title: title, kind: kind, isPrimary: actions.isEmpty))
        }

        let canRetry = hasAudio && isRetryable
        let retryTitle = if case .microphoneDisconnected = self { "Transcribe It" } else { "Retry" }
        let retryWith: (String, NoticeActionKind)? = if hasAudio, fallbackCanHelp, let fallback {
            ("Retry with \(fallback.shortName)", .retryWith(fallback))
        } else { nil }
        let switchEngine: (String, NoticeActionKind)? = if !hasAudio, copy.offersSwitch, let fallback {
            ("Use \(fallback.shortName)", .selectEngine(fallback))
        } else { nil }

        func addRetry() { if canRetry { add(retryTitle, .retry) } }
        func addFallbacks() {
            if let retryWith { add(retryWith.0, retryWith.1) }
            if let switchEngine { add(switchEngine.0, switchEngine.1) }
        }

        switch copy.order {
        case .retryFirst:
            addRetry()
            addFallbacks()
            copy.fixes.forEach { add($0.title, $0.kind) }
        case .fallbackFirst:
            addFallbacks()
            addRetry()
            copy.fixes.forEach { add($0.title, $0.kind) }
        case .fixFirst:
            if let first = copy.fixes.first { add(first.title, first.kind) }
            addFallbacks()
            addRetry()
            copy.fixes.dropFirst().forEach { add($0.title, $0.kind) }
        }

        var body = copy.body
        let offersRetry = actions.contains { if case .retry = $0.kind { true } else if case .retryWith = $0.kind { true } else { false } }
        if offersRetry && !(body ?? "").contains("recording is saved") {
            body = [body, "Your recording is saved."].compactMap { $0 }.joined(separator: " ")
        }

        let lifetime: NoticeLifetime = copy.sticky ? .sticky
            : copy.seconds.map { .seconds($0) }
            ?? .seconds(actions.isEmpty ? 5 : (copy.style == .error ? 10 : 8))

        return Notice(
            dedupeKey: "error.\(code)",
            style: copy.style,
            symbol: copy.symbol,
            title: copy.title,
            body: body,
            transcript: partialTranscript,
            actions: actions,
            lifetime: lifetime,
            sound: copy.sound,
            recordingID: recordingID
        )
    }

    /// Text that came back but wasn't pasted, shown in the notice so it can still be copied.
    private var partialTranscript: String? {
        if case .openRouterTruncated(let text) = self, !text.isEmpty { text } else { nil }
    }

    private var failingEngine: EngineID? {
        switch self {
        case .modelNotDownloaded(let e), .modelDownloading(let e, _), .modelPreparing(let e),
             .modelLoadFailed(let e, _), .downloadFailed(let e, _), .timeout(let e), .engineFailed(let e, _):
            e
        case .openRouterMissingKey, .openRouterKeyUnreadable, .openRouterInvalidKey, .openRouterNoCredits,
             .openRouterKeyLimit, .openRouterRateLimited, .openRouterNoRoute, .openRouterProviderUnavailable,
             .openRouterRefused, .openRouterBadRequest, .openRouterServer, .openRouterTruncated, .recordingTooLarge:
            nil
        default:
            nil
        }
    }

    private struct Fix { let title: String; let kind: NoticeActionKind }
    private enum Order { case retryFirst, fallbackFirst, fixFirst }

    private struct Copy {
        var style: NoticeStyle = .error
        var symbol: String = "exclamationmark.triangle.fill"
        var title: String
        var body: String?
        var fixes: [Fix] = []
        var order: Order = .retryFirst
        var sound: SoundEffect? = .error
        var sticky = false
        var seconds: Double?
        /// Offer "Use <fallback>" when there is no recording to retry.
        var offersSwitch = false
    }

    private static func oneLine(_ message: String, limit: Int = 110) -> String? {
        let flat = message.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return nil }
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// What OpenRouter copy calls the service: "Gemini" (also when the engine is unknown), or the cloud speech
    /// model ("Parakeet v3 · Cloud").
    private struct CloudName {
        let service: String
        let isSpeech: Bool

        init(_ engine: EngineID?) {
            if let engine, engine.cloudAPI == .transcriptions {
                service = engine.shortName
                isSpeech = true
            } else {
                service = "Gemini"
                isSpeech = false
            }
        }
    }

    private func copy(for engine: EngineID?) -> Copy {
        let cloud = CloudName(engine)
        switch self {
        case .microphonePermissionDenied:
            return Copy(symbol: "mic.slash.fill",
                        title: "\(Brand.name) can’t hear you",
                        body: "Microphone access is off. Turn it on in System Settings.",
                        fixes: [Fix(title: "Open Settings", kind: .openSettingsPane(.microphone)),
                                Fix(title: "Dismiss", kind: .dismiss)],
                        order: .fixFirst, sticky: true)
        case .noMicrophone:
            return Copy(symbol: "mic.badge.xmark",
                        title: "No microphone found",
                        body: "Connect a mic or check your Sound settings.",
                        fixes: [Fix(title: "Sound Settings", kind: .openSettingsPane(.sound))],
                        order: .fixFirst)
        case .microphoneNotResponding:
            return Copy(symbol: "mic.badge.xmark",
                        title: "Microphone isn’t responding",
                        body: "Try again, or pick another mic.",
                        fixes: [Fix(title: "Choose Mic", kind: .chooseMicrophone),
                                Fix(title: "Dismiss", kind: .dismiss)],
                        order: .fixFirst)
        case .microphoneDisconnected:
            return Copy(symbol: "mic.slash.fill",
                        title: "Microphone disconnected",
                        body: "\(Brand.name) kept what you said up to that point.",
                        fixes: [Fix(title: "Choose Mic", kind: .chooseMicrophone)])
        case .microphoneSilent:
            return Copy(symbol: "waveform.slash",
                        title: "Didn’t hear anything",
                        body: "Your mic may be muted, or the wrong one is selected.",
                        fixes: [Fix(title: "Choose Mic", kind: .chooseMicrophone)],
                        order: .fixFirst, seconds: 8)
        case .accessibilityMissing:
            return Copy(style: .warning, symbol: "accessibility",
                        title: "Couldn’t paste",
                        body: "\(Brand.name) needs Accessibility access to paste.",
                        fixes: [Fix(title: "Allow Access", kind: .openSettingsPane(.accessibility))],
                        order: .fixFirst, sound: .alert, seconds: 20)
        case .modelNotDownloaded(let e):
            let size = e.approxDownloadBytes.map { " (about \(Fmt.bytes($0)))" } ?? ""
            return Copy(symbol: "arrow.down.circle",
                        title: "\(e.displayName) isn’t downloaded yet",
                        body: "Download it\(size) or pick another model.",
                        fixes: [Fix(title: "Download", kind: .download(e)),
                                Fix(title: "Models", kind: .openHub(.models))],
                        order: .fixFirst, offersSwitch: true)
        case .modelDownloading(let e, let fraction):
            let pct = DownloadProgress(fraction: fraction).percent
            return Copy(style: .info, symbol: "arrow.down.circle",
                        title: "Still downloading \(e.shortName) · \(pct)%",
                        body: "\(Brand.name) will transcribe this as soon as it’s ready.",
                        order: .fallbackFirst, sound: nil, seconds: 8, offersSwitch: true)
        case .modelPreparing(let e):
            return Copy(style: .info, symbol: "hourglass",
                        title: "Getting \(e.shortName) ready…",
                        body: "The first run on this Mac takes a moment.",
                        order: .fallbackFirst, sound: nil, seconds: 6)
        case .modelLoadFailed(let e, _):
            return Copy(title: "Couldn’t load \(e.displayName)",
                        body: "The model files may be damaged. Downloading it again usually fixes this.",
                        fixes: [Fix(title: "Models", kind: .openHub(.models))],
                        offersSwitch: true)
        case .downloadFailed(let e, _):
            return Copy(symbol: "icloud.slash",
                        title: "Download didn’t finish",
                        body: "\(e.displayName) couldn’t be downloaded. Check your connection and try again.",
                        fixes: [Fix(title: "Try Again", kind: .download(e)),
                                Fix(title: "Models", kind: .openHub(.models))],
                        order: .fixFirst)
        case .notEnoughDisk(let needed, let available):
            return Copy(symbol: "internaldrive",
                        title: "Not enough space",
                        body: "This model needs \(Fmt.bytes(needed)). \(Fmt.bytes(available)) is free.",
                        fixes: [Fix(title: "Manage Storage", kind: .openSettingsPane(.storage)),
                                Fix(title: "Choose Model", kind: .openHub(.models))],
                        order: .fixFirst)
        case .openRouterMissingKey:
            return Copy(symbol: "key.fill",
                        title: "Add your OpenRouter key",
                        body: "\(cloud.service) needs a key to transcribe.",
                        fixes: [Fix(title: "Add Key", kind: .openHub(.models))],
                        order: .fixFirst, offersSwitch: true)
        case .openRouterKeyUnreadable:
            return Copy(symbol: "key.fill",
                        title: "\(Brand.name) can’t read your OpenRouter key",
                        body: "macOS didn’t let \(Brand.name) open it in the Keychain. Check the key again and choose Always Allow.",
                        fixes: [Fix(title: "Check Key", kind: .openHub(.models))],
                        order: .fixFirst, offersSwitch: true)
        case .openRouterInvalidKey:
            return Copy(symbol: "key.fill",
                        title: "Your OpenRouter key was rejected",
                        body: "It may have been revoked or mistyped.",
                        fixes: [Fix(title: "Update Key", kind: .openHub(.models))],
                        order: .fixFirst, offersSwitch: true)
        case .openRouterNoCredits:
            return Copy(symbol: "creditcard",
                        title: "Out of OpenRouter credit",
                        body: "Add credit to keep using \(cloud.service).",
                        fixes: [Fix(title: "Add Credit", kind: .openURL(OpenRouterLinks.credits))],
                        order: .fixFirst, offersSwitch: true)
        case .openRouterKeyLimit:
            return Copy(symbol: "creditcard",
                        title: "Your OpenRouter key hit its limit",
                        body: "This key has a spending limit, and it’s used up. Raise it to keep using \(cloud.service).",
                        fixes: [Fix(title: "Raise Limit", kind: .openURL(OpenRouterLinks.keys))],
                        order: .fixFirst, offersSwitch: true)
        case .openRouterRateLimited(let retryAfter):
            let wait = retryAfter.map { $0 >= 1 ? "Try again in about \(Int($0.rounded(.up))) s." : nil } ?? nil
            return Copy(symbol: "hourglass",
                        title: "\(cloud.service) is rate-limited",
                        body: wait ?? "Wait a few seconds and try again.")
        case .openRouterNoRoute:
            return Copy(symbol: "lock.shield",
                        title: "\(cloud.service) isn’t available for your key",
                        body: cloud.isSpeech
                            ? "OpenRouter found no provider your settings allow. Check your privacy and provider settings."
                            : "OpenRouter found no Google AI Studio route. Check your privacy and provider settings.",
                        fixes: [Fix(title: "Open Settings", kind: .openURL(OpenRouterLinks.privacy))],
                        order: .fixFirst, offersSwitch: true)
        case .openRouterProviderUnavailable:
            return Copy(symbol: "icloud.slash",
                        title: cloud.isSpeech ? "\(cloud.service) is unavailable" : "Google AI Studio is unavailable",
                        body: cloud.isSpeech ? "OpenRouter couldn’t reach its provider right now."
                            : "OpenRouter couldn’t reach Gemini right now.")
        case .openRouterRefused(let message):
            return Copy(symbol: "hand.raised.fill",
                        title: "\(cloud.service) refused this request",
                        body: Self.oneLine(message) ?? "The provider declined to transcribe this recording.",
                        order: .fallbackFirst)
        case .openRouterBadRequest(let message):
            return Copy(title: "\(cloud.service) couldn’t process this recording",
                        body: Self.oneLine(message) ?? "OpenRouter rejected the request.",
                        order: .fallbackFirst)
        case .openRouterServer:
            return Copy(symbol: "icloud.slash",
                        title: "OpenRouter ran into a problem",
                        body: "This is usually temporary. Try again in a moment.")
        case .openRouterTruncated:
            return Copy(style: .warning, symbol: "text.badge.xmark",
                        title: "\(cloud.service) stopped before finishing",
                        body: partialTranscript == nil ? "It ran out of room before writing any text."
                            : "The text may be cut off or repeat itself, so it wasn’t pasted.",
                        fixes: partialTranscript.map { [Fix(title: "Copy", kind: .copyText($0))] } ?? [],
                        sound: .alert)
        case .timeout(let e):
            let body = switch e.cloudAPI {
            case nil: "The model didn’t finish in time."
            case .chatCompletions: "Gemini didn’t answer in time."
            case .transcriptions: "OpenRouter didn’t answer in time."
            }
            return Copy(symbol: "hourglass", title: "\(e.shortName) took too long", body: body)
        case .offline:
            return Copy(symbol: "wifi.slash",
                        title: "You’re offline",
                        body: "\(cloud.service) needs the internet.",
                        order: .fallbackFirst, offersSwitch: true)
        case .noSpeech:
            return Copy(style: .info, symbol: "waveform",
                        title: "No speech detected",
                        body: "Hold the key while you talk.",
                        sound: nil, seconds: 4)
        case .engineFailed(let e, _):
            return Copy(title: "Couldn’t transcribe",
                        body: "\(e.displayName) ran into a problem.",
                        fixes: [Fix(title: "Try Another Model", kind: .openHub(.models))])
        case .recordingTooLarge:
            return Copy(symbol: "waveform.badge.exclamationmark",
                        title: "Too large to send to OpenRouter",
                        body: "OpenRouter refused this recording as too large. "
                            + "\(EngineID.parakeet.displayName) on this Mac takes any length.",
                        order: .fallbackFirst)
        }
    }
}
