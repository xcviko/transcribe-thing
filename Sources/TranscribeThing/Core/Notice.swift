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
    /// Undo of fn D adding `word`, the dictionary going from `before` to `after`: the word goes, and a spelling it
    /// replaced or a word it pushed out comes back (`UserDictionary.undoAdding`).
    case undoDictionaryAdd(String, before: UserDictionary, after: UserDictionary)
    /// The text, the model that wrote it and how it was dictated, whose General → Pasting rules the paste follows
    /// (no model: as written).
    case pasteText(String, by: ModelChoice?, in: DictationMachine.Mode)
    case chooseMicrophone
    case useBuiltInMicrophone
    /// Open Software Update and install the newest release there, where its progress shows.
    case installUpdate
    /// "Transcribe your call?": Yes keeps the call (`CallMonitor.keep(callID:)`), No deletes its recording, Never for …
    /// deletes it too and never notices that app's or site's calls again (`CallMonitor.never(callID:)`).
    case keepCall(UUID)
    case discardCall(UUID)
    case neverForCall(UUID)
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
    /// A small second line under the title of a one-row toast (a call notice's "From the Mute button"); unlike
    /// `body`, it keeps the toast a single compact pill.
    var detail: String?
    /// Non-nil renders the notice as a transcript card with selectable text.
    var transcript: String?
    /// At most two.
    var actions: [NoticeAction]
    /// A rarer answer, as a small link beside the buttons (under them when it doesn't fit): Never for ….
    var link: NoticeAction?
    var lifetime: NoticeLifetime
    var sound: SoundEffect?
    /// Recording the retry/undo actions refer to.
    var recordingID: UUID?
    /// A transcript card whose keys are ↩ and Esc (Polish Selection's): it says so where other cards point to the
    /// paste shortcut.
    var takesCardKeys = false

    init(
        id: UUID = UUID(),
        dedupeKey: String,
        style: NoticeStyle,
        symbol: String,
        title: String,
        body: String? = nil,
        detail: String? = nil,
        transcript: String? = nil,
        actions: [NoticeAction] = [],
        link: NoticeAction? = nil,
        lifetime: NoticeLifetime = .seconds(5),
        sound: SoundEffect? = nil,
        recordingID: UUID? = nil,
        takesCardKeys: Bool = false
    ) {
        self.id = id
        self.dedupeKey = dedupeKey
        self.style = style
        self.symbol = symbol
        self.title = title
        self.body = body
        self.detail = detail
        self.transcript = transcript
        self.actions = Array(actions.prefix(2))
        self.link = link
        self.lifetime = lifetime
        self.sound = sound
        self.recordingID = recordingID
        self.takesCardKeys = takesCardKeys
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

extension Notice {
    static func callQuestionKey(_ id: UUID) -> String { "call.ask.\(id.uuidString)" }

    /// A call is being recorded: transcribe it? Sticky until answered, or until the call is gone without an answer
    /// mattering (dropped, deleted). An unanswered call that ends waits in the Calls tab, with a badge, and so does
    /// this. Closed without an answer, the call waits there too. `never` is the third answer's title
    /// (`CallExclusion.actionTitle`: "Never for FaceTime", "Never for This Site"), when the call can be excluded.
    static func transcribeCall(_ id: UUID, service: String, never: String? = nil) -> Notice {
        Notice(dedupeKey: callQuestionKey(id), style: .info, symbol: "phone.badge.waveform",
               title: "Transcribe your call in \(service)?",
               body: callQuestionBody,
               actions: [NoticeAction(title: "Transcribe", kind: .keepCall(id), isPrimary: true),
                         NoticeAction(title: "Don’t Keep", kind: .discardCall(id))],
               link: never.map { NoticeAction(title: $0, kind: .neverForCall(id)) },
               lifetime: .sticky)
    }

    static let callQuestionBody = "It’s being recorded. Don’t Keep deletes the recording; without an answer, it "
        + "waits in Calls."
}

// MARK: - Destinations

enum SettingsPane: String, Sendable {
    case microphone, accessibility, inputMonitoring, keyboard, sound, storage
    /// Screen & System Audio Recording, whose System Audio Recording Only lets a call's other side be recorded.
    case systemAudio

    /// System Settings deep link (verified anchors, macos-input.md §3.4).
    var url: URL {
        let raw: String = switch self {
        case .microphone: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .keyboard: "x-apple.systempreferences:com.apple.preference.keyboard"
        case .sound: "x-apple.systempreferences:com.apple.preference.sound?input"
        case .storage: "x-apple.systempreferences:com.apple.settings.Storage"
        case .systemAudio: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
        return URL(string: raw)!
    }
}

enum HubSection: String, CaseIterable, Sendable, Identifiable {
    case home, calls, models, shortcuts, dictionary, microphone, general
    /// A sub-page of General (no sidebar item of its own), like a pane inside System Settings.
    case softwareUpdate
    /// One call, the one `WindowCoordinator.openCallID` names: a sub-page of Calls.
    case callDetail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .calls: "Calls"
        case .models: "Models"
        case .shortcuts: "Shortcuts"
        case .dictionary: "Dictionary"
        case .microphone: "Microphone"
        case .general: "General"
        case .softwareUpdate: "Software Update"
        case .callDetail: "Call"
        }
    }

    var symbolName: String {
        switch self {
        case .home: "house"
        case .calls, .callDetail: "phone"
        case .models: "square.stack.3d.up"
        case .shortcuts: "keyboard"
        case .dictionary: "character.book.closed"
        case .microphone: "mic"
        case .general: "gearshape"
        case .softwareUpdate: "arrow.down.circle"
        }
    }

    /// Pages reached from another one, with a Back button, and no sidebar item of their own.
    var isSubPage: Bool { self == .softwareUpdate || self == .callDetail }
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
    /// A key file is there, but it couldn't be read.
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
    /// OpenRouter can't be reached: no network, or one that goes nowhere (a VPN that stopped).
    case offline
    /// The provider serves no requests from where the user is (Google's "User location is not supported"): a VPN
    /// that went off.
    case regionBlocked
    /// OpenRouter's firewall (Cloudflare) turned the connection away before OpenRouter saw the request: a 403
    /// `{"success": false, "error": "Access denied by security policy."}`, usually for a VPN's address.
    case connectionBlocked
    /// Not a failure: the recording had no speech (too little voice for the recorder, or an engine that answered
    /// with no text). An info notice, never a history entry or a retry.
    case noSpeech
    case engineFailed(EngineID, String)
    case recordingTooLarge
    /// A Gemini request through the user's OpenAI-compatible endpoint failed in a way only the endpoint can
    /// (`VertexProxyFailure`).
    /// What any service says the same way (a cut-off answer, a refusal by the model, a timeout) keeps its own case.
    case vertexProxy(VertexProxyFailure)

    /// Re-running the same recording on the same engine could succeed.
    var isRetryable: Bool {
        switch self {
        case .microphoneDisconnected,
             .modelDownloading, .modelPreparing, .modelLoadFailed,
             .openRouterRateLimited, .openRouterProviderUnavailable, .openRouterServer, .openRouterTruncated,
             .timeout, .offline, .regionBlocked, .connectionBlocked, .engineFailed:
            true
        case .vertexProxy(let failure):
            switch failure {
            case .unreachable, .rateLimited, .unavailable: true
            case .keyUnreadable, .keyRejected, .spendLimit, .forbidden, .badRequest, .tooLarge: false
            }
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
        case .vertexProxy(let failure): failure.isTransient
        default: false
        }
    }

    /// The key, the credit or the connection failed: every cloud model would fail the same way, so only the local
    /// model can take over. Never the user's endpoint's: cloud Parakeet still goes through OpenRouter.
    var stopsEveryCloudModel: Bool {
        switch self {
        case .openRouterMissingKey, .openRouterKeyUnreadable, .openRouterInvalidKey, .openRouterNoCredits,
             .openRouterKeyLimit, .offline, .connectionBlocked:
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
             .regionBlocked, .connectionBlocked, .engineFailed, .recordingTooLarge, .vertexProxy:
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
        case .regionBlocked: "regionBlocked"
        case .connectionBlocked: "connectionBlocked"
        case .noSpeech: "noSpeech"
        case .engineFailed(let e, _): "engineFailed.\(e.rawValue)"
        case .recordingTooLarge: "recordingTooLarge"
        case .vertexProxy(let failure): "vertexProxy.\(failure.code)"
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
        case .vertexProxy(let failure):
            failure.detail
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

        // Retry is always the same model, wherever another one could have helped too: switching models for this
        // recording is the user's call, from History (Transcribe With).
        let canRetry = hasAudio && (isRetryable || fallbackCanHelp) && self != .recordingTooLarge
            && self != .vertexProxy(.tooLarge)
        let retryTitle = if case .microphoneDisconnected = self { "Transcribe It" } else { "Retry" }
        let switchEngine: (String, NoticeActionKind)? = if !hasAudio, copy.offersSwitch, let fallback {
            ("Use \(fallback.shortName)", .selectEngine(fallback))
        } else { nil }

        func addRetry() { if canRetry { add(retryTitle, .retry) } }
        func addFallbacks() {
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
        let offersRetry = actions.contains { $0.kind == .retry }
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
                        body: "The key saved on this Mac couldn’t be read. Paste it again.",
                        fixes: [Fix(title: "Update Key", kind: .openHub(.models))],
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
                        title: "No connection",
                        body: "Couldn’t reach OpenRouter. Check your internet or VPN.",
                        order: .fallbackFirst, offersSwitch: true)
        case .connectionBlocked:
            return Copy(symbol: "shield.slash",
                        title: "OpenRouter blocked the connection",
                        body: "Its firewall turned away your network’s address, often a VPN’s. Try another VPN server.",
                        order: .fallbackFirst, offersSwitch: true)
        case .regionBlocked:
            return Copy(symbol: "globe",
                        title: "\(cloud.service) isn’t available in your region",
                        body: "Turn on your VPN and try again.",
                        order: .fallbackFirst, offersSwitch: true)
        case .noSpeech:
            return Copy(style: .info, symbol: "waveform",
                        title: "No speech detected",
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
        case .vertexProxy(let failure):
            return Self.copy(for: failure)
        }
    }

    /// The OpenAI-compatible endpoint's failures: each says "your endpoint", and a fix points to Models, where its
    /// section is (nothing can be fixed on openrouter.ai).
    private static func copy(for failure: VertexProxyFailure) -> Copy {
        let models = Fix(title: "Open Models", kind: .openHub(.models))
        switch failure {
        case .keyUnreadable:
            return Copy(symbol: "key.fill",
                        title: "\(Brand.name) can’t read your endpoint’s API key",
                        body: "The key saved on this Mac couldn’t be read. Paste it again in Models.",
                        fixes: [Fix(title: "Update Key", kind: .openHub(.models))],
                        order: .fixFirst, offersSwitch: true)
        case .keyRejected:
            return Copy(symbol: "key.fill",
                        title: "Your endpoint rejected the API key",
                        body: "It may have been revoked or mistyped. Check it in Models.",
                        fixes: [Fix(title: "Update Key", kind: .openHub(.models))],
                        order: .fixFirst, offersSwitch: true)
        case .spendLimit:
            return Copy(symbol: "creditcard",
                        title: "Your endpoint hit a spend limit",
                        body: "Raise the limit or add credit where your endpoint is run, or switch Gemini back to "
                            + "OpenRouter in Models.",
                        fixes: [models],
                        order: .fixFirst, offersSwitch: true)
        case .unreachable:
            return Copy(symbol: "wifi.slash",
                        title: "Can’t reach your endpoint",
                        body: "Check your connection and the endpoint’s base URL in Models.",
                        fixes: [models],
                        order: .fallbackFirst, offersSwitch: true)
        case .rateLimited(let retryAfter):
            let wait = retryAfter.map { $0 >= 1 ? "Try again in about \(Int($0.rounded(.up))) s." : nil } ?? nil
            return Copy(symbol: "hourglass",
                        title: "Gemini is busy on your endpoint",
                        body: wait ?? "It had no capacity for this. Wait a few seconds and try again.")
        case .forbidden(let message):
            return Copy(symbol: "hand.raised.fill",
                        title: "Your endpoint refused the request",
                        body: oneLine(message) ?? "Check the account and the billing behind your endpoint.",
                        order: .fallbackFirst, offersSwitch: true)
        case .unavailable:
            return Copy(symbol: "icloud.slash",
                        title: "Your endpoint ran into a problem",
                        body: "This is usually temporary. Try again in a moment.")
        case .badRequest(let message):
            return Copy(title: "Your endpoint couldn’t process this",
                        body: oneLine(message) ?? "It rejected the request.",
                        order: .fallbackFirst)
        case .tooLarge:
            return Copy(symbol: "waveform.badge.exclamationmark",
                        title: "Too large to send to your endpoint",
                        body: "Your endpoint refused this recording as too large. "
                            + "\(EngineID.parakeet.displayName) on this Mac takes any length.",
                        order: .fallbackFirst)
        }
    }
}
