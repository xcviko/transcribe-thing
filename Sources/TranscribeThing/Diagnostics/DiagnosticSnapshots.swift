import Foundation

/// Which app and Mac a log comes from: the launch line and the export's header.
struct DiagnosticSystemInfo: Equatable, Sendable {
    /// "0.3.4"; "dev" for the bare binary, which has no Info.plist.
    var appVersion: String
    /// "57"; "-" for the bare binary.
    var build: String
    /// "26.0.1 (Build 25A362)".
    var macOS: String
    /// The model identifier (`sysctl hw.model`): "Mac16,1".
    var macModel: String

    static func current() -> DiagnosticSystemInfo {
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return DiagnosticSystemInfo(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "dev",
            build: info?["CFBundleVersion"] as? String ?? "-",
            macOS: os.hasPrefix("Version ") ? String(os.dropFirst("Version ".count)) : os,
            macModel: sysctlString("hw.model") ?? "unknown")
    }

    var fields: [DiagnosticField] {
        [DiagnosticField("version", appVersion), DiagnosticField("build", build), DiagnosticField("macos", macOS),
         DiagnosticField("mac", macModel)]
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let text = String(decoding: bytes, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}

/// The settings someone reading a log needs to make sense of a dictation, as codes and shortcuts' display text.
/// Whether an OpenRouter key is saved, never the key; no microphone names.
struct DiagnosticSettingsSummary: Equatable, Sendable {
    var fields: [DiagnosticField]

    init(fields: [DiagnosticField]) {
        self.fields = fields
    }

    @MainActor
    init(settings: AppSettings, keySaved: Bool) {
        let steps = settings.lineup.steps
        var fields = [
            DiagnosticField("main", settings.lineup.main.rawValue),
            DiagnosticField("steps", steps.isEmpty ? "none" : steps.map(\.rawValue).joined(separator: ",")),
            DiagnosticField("parakeet", settings.parakeetEngine.isLocal ? "local" : "cloud"),
            DiagnosticField("handsFreeModel", settings.handsFreeChoice?.rawValue ?? "main"),
        ]
        for action in ShortcutAction.allCases {
            fields.append(DiagnosticField("shortcut.\(action.rawValue)",
                                          settings.shortcuts[action]?.compactDescription ?? "none"))
        }
        fields += [
            DiagnosticField("pill", settings.pillMode.rawValue),
            DiagnosticField("sounds", settings.soundsEnabled ? "on" : "off"),
            DiagnosticField("doublePress", settings.doublePressForHandsFree ? "on" : "off"),
            DiagnosticField("keySaved", keySaved ? "yes" : "no"),
        ]
        self.fields = fields
    }

    /// "main=parakeet steps=cleanup,gemini …", as a log line has it.
    var line: String {
        fields.map { "\($0.key)=\(DiagnosticLog.quoted($0.value))" }.joined(separator: " ")
    }
}

/// The microphones by kind, never by name: which kinds can record, which can't right now (a closed lid), which one
/// macOS uses, and the user's pick (Automatic, or its kind; "missing" while it's gone).
struct DiagnosticMicrophones: Equatable, Sendable {
    var fields: [DiagnosticField]

    init(devices: [AudioInputDevice], defaultUID: String?, pickedUID: String?) {
        func kinds(_ list: [AudioInputDevice]) -> String {
            list.isEmpty ? "none" : list.map(\.transport.diagnosticText).joined(separator: ",")
        }
        let unavailable = devices.filter { !$0.isAvailable }
        var fields = [DiagnosticField("inputs", kinds(devices.filter(\.isAvailable)))]
        if !unavailable.isEmpty { fields.append(DiagnosticField("unavailable", kinds(unavailable))) }
        let byID = { (uid: String?) in uid.flatMap { uid in devices.first { $0.id == uid } } }
        fields.append(DiagnosticField("default", byID(defaultUID)?.transport.diagnosticText ?? "none"))
        let picked = pickedUID.map { byID($0)?.transport.diagnosticText ?? "missing" } ?? "automatic"
        fields.append(DiagnosticField("picked", picked))
        self.fields = fields
    }
}
