import Darwin
import Foundation
import Security

/// Why an update didn't install. Every case but `.cancelled` offers the release page instead.
enum UpdateInstallError: Error, Equatable, Sendable {
    /// The release has no zip to install.
    case noInstallableAsset
    /// The code that pins updates (the running app) is ad-hoc signed or unsigned: nothing could satisfy it.
    case adHocSigned
    /// Gatekeeper runs the app from a randomized read-only copy (App Translocation).
    case translocated
    /// The folder holding the app can't be written to.
    case notWritable(String)
    case targetMissing(String)
    case downloadFailed(String)
    case badArchive(String)
    case wrongBundle(String?)
    case wrongVersion(expected: String, found: String?)
    case signatureMismatch(String)
    case installFailed(String)
    case cancelled

    /// The explanation under "Couldn’t install the update".
    var message: String {
        switch self {
        case .noInstallableAsset:
            "This release has no app to install from here. Its GitHub page has the download."
        case .adHocSigned:
            "This copy can’t update itself. Download the new version from GitHub."
        case .translocated:
            "macOS is running \(Brand.name) from a temporary copy, so it can’t replace itself. Move it to Applications and open it from there, or download the new version from GitHub."
        case .notWritable(let folder):
            "\(Brand.name) can’t write to \(folder). Download the new version from GitHub and replace it yourself."
        case .targetMissing:
            "\(Brand.name) couldn’t find itself on disk. Download the new version from GitHub."
        case .downloadFailed(let detail):
            "The download didn’t finish. \(detail)"
        case .badArchive:
            "The download doesn’t contain \(Brand.name), so nothing was installed."
        case .wrongBundle:
            "The download isn’t \(Brand.name), so it wasn’t installed."
        case .wrongVersion(let expected, let found):
            "The download is version \(found ?? "unknown"), not \(expected), so it wasn’t installed."
        case .signatureMismatch:
            "The download isn’t signed by \(Brand.name)’s developer, so it wasn’t installed."
        case .installFailed(let detail):
            "\(Brand.name) couldn’t replace itself. \(detail)"
        case .cancelled:
            "The update was canceled."
        }
    }

    /// Trying again could work (a dropped download, a busy disk); otherwise only the release page helps.
    var isRetryable: Bool {
        switch self {
        case .downloadFailed, .badArchive, .installFailed, .cancelled: true
        case .noInstallableAsset, .adHocSigned, .translocated, .notWritable, .targetMissing, .wrongBundle,
             .wrongVersion, .signatureMismatch:
            false
        }
    }

    /// Technical detail for logs and the CLI.
    var detail: String? {
        switch self {
        case .notWritable(let s), .targetMissing(let s), .downloadFailed(let s), .badArchive(let s),
             .signatureMismatch(let s), .installFailed(let s):
            s
        case .wrongBundle(let id): id
        default: nil
        }
    }
}

/// A downloaded, unpacked and verified app, waiting in a work folder to replace the installed one.
struct PreparedUpdate: Equatable, Sendable {
    var release: Release
    var app: URL
    var workDirectory: URL
}

/// transcribe-thing's own update flow, in the spirit of Sparkle: pick the release's zip, download it, unpack it,
/// check it is the same app at the promised version signed by the same developer, then swap it in atomically.
/// Every side effect goes through `Operations`, so tests run the flow on fakes and temporary folders.
struct UpdateInstaller: Sendable {
    static let appName = "transcribe-thing.app"
    /// What the download is saved as inside the work folder.
    static let archiveName = "update.zip"

    enum Step: Equatable, Sendable {
        case downloading(received: Int64, total: Int64?)
        case unpacking
        case verifying
    }

    struct Operations: Sendable {
        var download: @Sendable (_ from: URL, _ to: URL, _ progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> Void
        var unzip: @Sendable (_ archive: URL, _ destination: URL) throws -> Void
        /// The code whose designated requirement new versions must satisfy is ad-hoc signed or unsigned.
        var requirementSourceIsAdHoc: @Sendable () -> Bool
        /// Throws unless `app` is validly signed and satisfies that designated requirement.
        var verifySignature: @Sendable (_ app: URL) throws -> Void
        var stripQuarantine: @Sendable (_ app: URL) throws -> Void
        var isWritable: @Sendable (_ directory: URL) -> Bool
        var replace: @Sendable (_ target: URL, _ newApp: URL) throws -> Void
    }

    /// The installed app the update replaces.
    var target: URL
    /// What the download's CFBundleIdentifier must be.
    var bundleIdentifier: String
    var operations: Operations
    /// Parent of the per-update work folders.
    var workRoot: URL = FileManager.default.temporaryDirectory

    /// Everything that can be refused before downloading: no zip, a copy that can't be replaced, an ad-hoc
    /// signature nothing could match.
    func preflight(_ release: Release) throws -> ReleaseAsset {
        guard let asset = release.installableAsset else { throw UpdateInstallError.noInstallableAsset }
        if target.path.contains("/AppTranslocation/") { throw UpdateInstallError.translocated }
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw UpdateInstallError.targetMissing(target.path)
        }
        let folder = target.deletingLastPathComponent()
        guard operations.isWritable(folder) else { throw UpdateInstallError.notWritable(folder.path) }
        if operations.requirementSourceIsAdHoc() { throw UpdateInstallError.adHocSigned }
        return asset
    }

    /// Downloads, unpacks and verifies `release`. The work folder is removed on failure; on success the caller
    /// installs or discards the result.
    func prepare(_ release: Release, progress: @escaping @Sendable (Step) -> Void) async throws -> PreparedUpdate {
        let asset = try preflight(release)
        let work = workRoot.appendingPathComponent("transcribe-thing-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            // A fixed name: the feed's asset name never becomes a path.
            let archive = work.appendingPathComponent(Self.archiveName, isDirectory: false)
            progress(.downloading(received: 0, total: asset.size > 0 ? asset.size : nil))
            do {
                try await operations.download(asset.url, archive) { received, total in
                    progress(.downloading(received: received, total: total ?? (asset.size > 0 ? asset.size : nil)))
                }
            } catch is CancellationError {
                throw UpdateInstallError.cancelled
            } catch let error as UpdateInstallError {
                throw error
            } catch let error as URLError where error.code == .cancelled {
                throw UpdateInstallError.cancelled
            } catch {
                throw UpdateInstallError.downloadFailed(error.localizedDescription)
            }
            try Task.checkCancellation()
            if asset.size > 0, let size = Self.fileSize(archive), size != asset.size {
                throw UpdateInstallError.downloadFailed("Got \(Fmt.bytes(size)) of \(Fmt.bytes(asset.size)).")
            }

            progress(.unpacking)
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
                try operations.unzip(archive, unpacked)
            } catch {
                throw UpdateInstallError.badArchive(error.localizedDescription)
            }
            let app = try Self.singleApp(in: unpacked)

            progress(.verifying)
            try verify(app, version: release.version)
            try Task.checkCancellation()
            do {
                try operations.stripQuarantine(app)
            } catch {
                throw UpdateInstallError.installFailed("Couldn’t clear the download’s quarantine flag: \(error.localizedDescription)")
            }
            return PreparedUpdate(release: release, app: app, workDirectory: work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            if error is CancellationError { throw UpdateInstallError.cancelled }
            throw error
        }
    }

    /// Swaps the verified app in for `target`, then removes the work folder.
    func install(_ prepared: PreparedUpdate) throws {
        defer { discard(prepared) }
        do {
            try operations.replace(target, prepared.app)
        } catch {
            throw UpdateInstallError.installFailed(error.localizedDescription)
        }
    }

    func discard(_ prepared: PreparedUpdate) {
        try? FileManager.default.removeItem(at: prepared.workDirectory)
    }

    /// Same app, the promised version, and a signature the installed app's designated requirement accepts.
    func verify(_ app: URL, version: AppVersion) throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        let identifier = info?["CFBundleIdentifier"] as? String
        guard identifier == bundleIdentifier else { throw UpdateInstallError.wrongBundle(identifier) }
        let found = info?["CFBundleShortVersionString"] as? String
        guard let found, AppVersion(found) == version else {
            throw UpdateInstallError.wrongVersion(expected: version.description, found: found)
        }
        do {
            try operations.verifySignature(app)
        } catch let error as UpdateInstallError {
            throw error
        } catch {
            throw UpdateInstallError.signatureMismatch(error.localizedDescription)
        }
    }

    /// The zip must hold exactly one transcribe-thing.app (at its top level, or one folder down), and it must be a
    /// real folder: a symlink would be verified through its target but installed as the link itself.
    static func singleApp(in folder: URL) throws -> URL {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        var found: [URL] = []
        let top = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        for item in top where item.lastPathComponent != "__MACOSX" {
            if item.lastPathComponent == appName {
                found.append(item)
            } else if isRealFolder(item), item.pathExtension != "app" {
                let inner = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: keys)) ?? []
                found += inner.filter { $0.lastPathComponent == appName }
            }
        }
        guard found.count == 1 else {
            throw UpdateInstallError.badArchive(found.isEmpty ? "No \(appName) in the archive."
                                                              : "\(found.count) copies of \(appName) in the archive.")
        }
        guard isRealFolder(found[0]) else {
            throw UpdateInstallError.badArchive("\(appName) in the archive is a symbolic link or not a folder.")
        }
        return found[0]
    }

    /// A directory that isn't a symbolic link (to one or to anything else).
    private static func isRealFolder(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isSymbolicLink != true && values.isDirectory == true
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

// MARK: - Live operations

extension UpdateInstaller {
    /// The real flow: `requirement` is the code updates must match (the running app, or another copy for the CLI).
    static func live(target: URL, bundleIdentifier: String, requirement: CodeSignature.Source) -> UpdateInstaller {
        UpdateInstaller(target: target, bundleIdentifier: bundleIdentifier, operations: Operations(
            download: { url, destination, progress in
                try await UpdateDownload.run(from: url, to: destination, progress: progress)
            },
            unzip: { archive, destination in try Ditto.extract(archive, to: destination) },
            requirementSourceIsAdHoc: { CodeSignature.isAdHocOrUnsigned(requirement) },
            verifySignature: { app in try CodeSignature.verify(app, satisfies: requirement) },
            stripQuarantine: { app in try Quarantine.strip(app) },
            isWritable: { folder in FileManager.default.isWritableFile(atPath: folder.path) },
            replace: { target, newApp in try AtomicReplace.replace(target, with: newApp) }))
    }
}

/// `/usr/bin/ditto -x -k`, which keeps the symlinks, permissions and extended attributes a signed app needs.
enum Ditto {
    struct Failure: LocalizedError {
        var status: Int32
        var output: String
        var errorDescription: String? { output.isEmpty ? "ditto exited with status \(status)." : output }
    }

    static func extract(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(status: process.terminationStatus,
                          output: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// Removes com.apple.quarantine from an app and everything inside it (a zip downloaded by a browser passes it on).
enum Quarantine {
    static let attribute = "com.apple.quarantine"

    static func strip(_ url: URL) throws {
        try strip(path: url.path)
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: []) else { return }
        for case let item as URL in walker {
            try strip(path: item.path)
        }
    }

    private static func strip(path: String) throws {
        guard removexattr(path, attribute, XATTR_NOFOLLOW) != 0 else { return }
        let code = errno
        guard code != ENOATTR else { return }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
}

/// Replaces an app bundle in one step on its own volume: the new copy is staged in a replacement folder next to
/// it (`itemReplacementDirectory`), then swapped in with `replaceItemAt`, so a failure leaves the old app intact.
enum AtomicReplace {
    static func replace(_ target: URL, with newApp: URL) throws {
        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(target.lastPathComponent, isDirectory: true)
        try fm.moveItem(at: newApp, to: staged)
        _ = try fm.replaceItemAt(target, withItemAt: staged, backupItemName: nil, options: [])
    }
}

// MARK: - Code signature

/// The check that stands in for Sparkle's EdDSA signature: releases are signed with the owner's "transcribe-thing
/// Developer" certificate, so the installed app's designated requirement (its identifier and that certificate's
/// leaf hash) accepts only builds signed with the same private key, and macOS keeps Accessibility and Microphone
/// grants across updates for the same reason.
enum CodeSignature {
    enum Source: Sendable, Equatable {
        /// The running process (in-app updates).
        case runningApp
        /// Another copy on disk (`--install-update --requirement-from`).
        case app(URL)
    }

    struct Failure: LocalizedError {
        var status: OSStatus
        var context: String
        var errorDescription: String? {
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "\(context): \(text)"
        }
    }

    static func staticCode(_ source: Source) throws -> SecStaticCode {
        switch source {
        case .runningApp:
            var code: SecCode?
            var status = SecCodeCopySelf([], &code)
            guard status == errSecSuccess, let code else { throw Failure(status: status, context: "Reading this app’s signature") }
            var staticCode: SecStaticCode?
            status = SecCodeCopyStaticCode(code, [], &staticCode)
            guard status == errSecSuccess, let staticCode else { throw Failure(status: status, context: "Reading this app’s signature") }
            return staticCode
        case .app(let url):
            return try staticCode(at: url)
        }
    }

    static func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw Failure(status: status, context: "Reading \(url.lastPathComponent)") }
        return code
    }

    static func designatedRequirement(_ source: Source) throws -> SecRequirement {
        let code = try staticCode(source)
        var requirement: SecRequirement?
        let status = SecCodeCopyDesignatedRequirement(code, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw Failure(status: status, context: "Reading the designated requirement")
        }
        return requirement
    }

    /// `identifier "dev.transcribe-thing.app" and certificate leaf = H"…"`
    static func text(of requirement: SecRequirement) -> String? {
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }

    /// Ad-hoc ("-") or no signature at all: its requirement is a cdhash no other build can match.
    static func isAdHocOrUnsigned(_ source: Source) -> Bool {
        guard let code = try? staticCode(source) else { return true }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any]
        else { return true }
        guard dictionary[kSecCodeInfoIdentifier as String] != nil else { return true }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }

    /// Valid on every architecture, strictly, nested code included, and satisfying `source`'s designated requirement.
    static func verify(_ app: URL, satisfies source: Source) throws {
        let requirement = try designatedRequirement(source)
        let code = try staticCode(at: app)
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        guard status == errSecSuccess else {
            // The CFError's description is a bare "OSStatus error -67050"; Security's own message says why.
            var reason = Failure(status: status, context: "Checking the signature").localizedDescription
            if let cfError = error?.takeRetainedValue() {
                let info = cfError as Error as NSError
                if let extra = info.localizedFailureReason ?? (info.userInfo[kSecCFErrorRequirementSyntax as String] as? String) {
                    reason += " (\(extra))"
                }
            }
            throw UpdateInstallError.signatureMismatch(reason)
        }
    }
}

// MARK: - Download

/// One download with byte progress (URLSession's async API reports none), cancellable through the task.
/// file:// URLs are copied, for QA feeds.
enum UpdateDownload {
    static func run(from url: URL, to destination: URL,
                    progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        if url.isFileURL {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            try FileManager.default.copyItem(at: url, to: destination)
            progress(size ?? 0, size)
            return
        }
        let delegate = Delegate(destination: destination, progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let task = session.downloadTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let progress: @Sendable (Int64, Int64?) -> Void
        private let lock = NSLock()
        private var _continuation: CheckedContinuation<Void, Error>?
        private var moveError: Error?

        init(destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
            self.destination = destination
            self.progress = progress
        }

        var continuation: CheckedContinuation<Void, Error>? {
            get { lock.withLock { _continuation } }
            set { lock.withLock { _continuation = newValue } }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The file is gone once this returns: move it now.
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                moveError = UpdateInstallError.downloadFailed("GitHub answered with HTTP \(http.statusCode).")
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                moveError = error
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                defer { _continuation = nil }
                return _continuation
            }
            if let error = error ?? moveError {
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume()
            }
        }
    }
}

// MARK: - Relaunch

enum Relauncher {
    /// A detached shell waits for this process to exit, then opens `app`. The PID and path are arguments ($1, $2),
    /// never part of the script text.
    static func spawn(opening app: URL, afterExitOf pid: pid_t = ProcessInfo.processInfo.processIdentifier) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "transcribe-thing-relaunch", String(pid), app.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static let script = #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open "$2""#
}
