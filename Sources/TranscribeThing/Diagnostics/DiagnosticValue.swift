import Foundation

/// A value an event of the diagnostic log carries (`DiagnosticLog.event`): a code, a number, an id or an enum. Never
/// free text from the user: a transcript, a prompt, a name. Turned into its text where the event is logged, so it
/// never crosses threads.
protocol DiagnosticValue {
    /// How the value reads on the line (`DiagnosticLog.quoted` adds quotes where it needs them).
    var diagnosticText: String { get }
}

extension String: DiagnosticValue {
    var diagnosticText: String { self }
}

extension Int: DiagnosticValue {
    var diagnosticText: String { String(self) }
}

extension Double: DiagnosticValue {
    /// At most two decimals, without trailing zeros: 4.2, 0.35, 12.
    var diagnosticText: String {
        guard isFinite else { return String(describing: self) }
        let rounded = (self * 100).rounded() / 100
        let text = String(describing: rounded)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}

extension Bool: DiagnosticValue {
    var diagnosticText: String { self ? "yes" : "no" }
}

extension EngineID: DiagnosticValue {
    var diagnosticText: String { rawValue }
}

extension ModelChoice: DiagnosticValue {
    var diagnosticText: String { rawValue }
}

extension PillMode: DiagnosticValue {
    var diagnosticText: String { rawValue }
}

extension AppError: DiagnosticValue {
    var diagnosticText: String { code }
}

extension DictationMachine.Mode: DiagnosticValue {
    var diagnosticText: String {
        switch self {
        case .pushToTalk: "pushToTalk"
        case .handsFree: "handsFree"
        }
    }
}

extension PermissionState: DiagnosticValue {
    var diagnosticText: String {
        switch self {
        case .granted: "granted"
        case .denied: "denied"
        case .notDetermined: "notDetermined"
        }
    }
}

/// A microphone by its kind only, never its name: "builtIn", "bluetooth", "usb".
extension AudioInputDevice.Transport: DiagnosticValue {
    var diagnosticText: String {
        switch self {
        case .builtIn: "builtIn"
        case .usb: "usb"
        case .bluetooth: "bluetooth"
        case .aggregate: "aggregate"
        case .virtual: "virtual"
        case .other: "other"
        }
    }
}

/// How a paste went, by its case: never which app or field it went to.
extension InsertionOutcome: DiagnosticValue {
    var diagnosticText: String {
        switch self {
        case .pasted: "pasted"
        case .passwordField: "passwordField"
        case .accessibilityMissing: "accessibilityMissing"
        case .failed: "failed"
        }
    }
}

extension UpdateCheckError: DiagnosticValue {
    var diagnosticText: String {
        switch self {
        case .offline: "offline"
        case .rateLimited: "rateLimited"
        case .notFound: "notFound"
        case .http(let status): "http.\(status)"
        case .unreadable: "unreadable"
        case .failed: "failed"
        }
    }
}

extension UpdateInstallError: DiagnosticValue {
    var diagnosticText: String {
        switch self {
        case .noInstallableAsset: "noInstallableAsset"
        case .adHocSigned: "adHocSigned"
        case .translocated: "translocated"
        case .notWritable: "notWritable"
        case .targetMissing: "targetMissing"
        case .downloadFailed: "downloadFailed"
        case .badArchive: "badArchive"
        case .wrongBundle: "wrongBundle"
        case .wrongVersion: "wrongVersion"
        case .signatureMismatch: "signatureMismatch"
        case .installFailed: "installFailed"
        case .cancelled: "cancelled"
        }
    }
}

/// Any error by its domain and code, which say what failed without its message: "NSURLErrorDomain -1009".
struct DiagnosticErrorCode: DiagnosticValue {
    let diagnosticText: String

    init(_ error: any Error) {
        if let error = error as? AppError {
            diagnosticText = error.code
        } else {
            let ns = error as NSError
            diagnosticText = "\(ns.domain) \(ns.code)"
        }
    }
}
