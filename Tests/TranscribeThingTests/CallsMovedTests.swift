import Foundation
import Testing
@testable import TranscribeThing

// Calls moved to calls-thing: what this app still does about the old extension, and the call data it leaves for
// calls-thing to take. Everything runs on temporary folders and a throwaway defaults suite, never the real ones.

@Suite struct LegacyBrowserHostTests {
    /// The old extension starts the host with its origin; the app runs with none.
    @Test func aBrowserLaunchIsAnExtensionsOrigin() {
        #expect(LegacyBrowserHost.isBrowserLaunch(["chrome-extension://abcdefghijklmnopabcdefghijklmnop/"]))
        #expect(LegacyBrowserHost.isBrowserLaunch(["--parent-window=0", "chrome-extension://abc/"]))
        #expect(!LegacyBrowserHost.isBrowserLaunch([]))
        #expect(!LegacyBrowserHost.isBrowserLaunch(["--snapshots", "/tmp/x"]))
        #expect(!LegacyBrowserHost.isBrowserLaunch(["https://chrome-extension.example"]))
    }

    /// A temporary Application Support and a repository whose `.build` it names.
    private struct Folders {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-thing-legacy-host-\(UUID().uuidString)", isDirectory: true)
        var support: URL { root.appendingPathComponent("Application Support", isDirectory: true) }
        var build: URL { root.appendingPathComponent("repo/.build", isDirectory: true) }

        /// Writes a manifest of `name` into `browser`'s NativeMessagingHosts, naming `path`.
        @discardableResult
        func manifest(_ browser: String, path: String, name: String = LegacyBrowserHost.manifestName) throws -> URL {
            let folder = support.appendingPathComponent(browser, isDirectory: true)
                .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
            let object: [String: Any] = ["name": "dev.transcribe_thing.bridge", "path": path, "type": "stdio",
                                         "allowed_origins": ["chrome-extension://abc/"]]
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            return url
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// The manifest goes from every browser that has it, when it names this app: installed anywhere, or built in
    /// the repository.
    @Test func theAppsOwnManifestGoes() throws {
        let folders = Folders()
        defer { folders.remove() }
        let chrome = try folders.manifest("Google/Chrome",
                                          path: "/Applications/transcribe-thing.app/Contents/MacOS/transcribe-thing")
        let arc = try folders.manifest("Arc/User Data",
                                       path: "/Users/someone/Applications/transcribe-thing.app/Contents/MacOS/transcribe-thing")
        let edge = try folders.manifest("Microsoft Edge", path: folders.build.path + "/debug/transcribe-thing")
        let removed = LegacyBrowserHost.removeOldManifests(browserSupport: folders.support,
                                                           repositoryBuild: folders.build)
        #expect(Set(removed.map(\.lastPathComponent)) == [LegacyBrowserHost.manifestName])
        #expect(removed.count == 3)
        #expect(!folders.exists(chrome) && !folders.exists(arc) && !folders.exists(edge))
    }

    /// Anything that isn't this app's is left as it is: a manifest of the same name pointing elsewhere, another
    /// app's manifest (calls-thing's own), and one that can't be read.
    @Test func anythingElseStays() throws {
        let folders = Folders()
        defer { folders.remove() }
        let elsewhere = try folders.manifest("Google/Chrome", path: "/Applications/calls-thing.app/Contents/MacOS/calls-thing")
        let otherBuild = try folders.manifest("Vivaldi", path: "/Users/someone/elsewhere/.build/debug/transcribe-thing")
        let callsThing = try folders.manifest("Google/Chrome",
                                              path: "/Applications/transcribe-thing.app/Contents/MacOS/transcribe-thing",
                                              name: "dev.calls_thing.bridge.json")
        let brave = folders.support.appendingPathComponent("BraveSoftware/Brave-Browser/NativeMessagingHosts",
                                                           isDirectory: true)
        try FileManager.default.createDirectory(at: brave, withIntermediateDirectories: true)
        let unreadable = brave.appendingPathComponent(LegacyBrowserHost.manifestName)
        try Data("not json".utf8).write(to: unreadable)
        let removed = LegacyBrowserHost.removeOldManifests(browserSupport: folders.support,
                                                           repositoryBuild: folders.build)
        #expect(removed.isEmpty)
        #expect(folders.exists(elsewhere) && folders.exists(otherBuild) && folders.exists(callsThing)
                && folders.exists(unreadable))
    }

    /// No browser folders at all: nothing happens, nothing is made.
    @Test func noBrowsersNoChange() {
        let folders = Folders()
        defer { folders.remove() }
        #expect(LegacyBrowserHost.removeOldManifests(browserSupport: folders.support,
                                                     repositoryBuild: folders.build).isEmpty)
        #expect(!folders.exists(folders.root))
    }

    @Test func whatCountsAsThisApp() {
        let build = URL(fileURLWithPath: "/repo/.build", isDirectory: true)
        #expect(LegacyBrowserHost.isOurs(path: "/Applications/transcribe-thing.app/Contents/MacOS/transcribe-thing",
                                         repositoryBuild: build))
        #expect(LegacyBrowserHost.isOurs(path: "/repo/.build/arm64-apple-macosx/debug/transcribe-thing",
                                         repositoryBuild: build))
        #expect(!LegacyBrowserHost.isOurs(path: "/repo/.build", repositoryBuild: build))
        #expect(!LegacyBrowserHost.isOurs(path: "/repo/.builder/transcribe-thing", repositoryBuild: build))
        #expect(!LegacyBrowserHost.isOurs(path: "/Applications/transcribe-thing.app.old/x", repositoryBuild: build))
        #expect(!LegacyBrowserHost.isOurs(path: "/Applications/calls-thing.app/Contents/MacOS/calls-thing",
                                          repositoryBuild: build))
    }

    /// The repository this test was built from: its `.build`, where `swift build` puts the binary.
    @Test func theRepositorysBuildFolder() {
        let build = LegacyBrowserHost.repositoryBuild
        #expect(build.lastPathComponent == ".build")
        #expect(FileManager.default.fileExists(atPath: build.deletingLastPathComponent()
            .appendingPathComponent("Package.swift").path))
    }
}

@MainActor
@Suite struct CallSettingsLeftAloneTests {
    /// What builds with calls stored stays, untouched by a load and by changes to other settings: calls-thing copies
    /// it from here.
    @Test func callKeysSurviveALoad() throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        let exclusions = Data(#"[{"kind":"app","key":"com.apple.FaceTime","name":"FaceTime"}]"#.utf8)
        defaults.set("automatic", forKey: "tt.callRecording")
        defaults.set(exclusions, forKey: "tt.callExclusions")
        defaults.set(false, forKey: "tt.showsCallNotices")
        defaults.set("geminiFlash", forKey: "tt.callEngine")
        defaults.set(true, forKey: "tt.browserExtensionHintDismissed")

        let settings = AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() })
        settings.soundsEnabled = false
        _ = AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() })

        #expect(defaults.string(forKey: "tt.callRecording") == "automatic")
        #expect(defaults.data(forKey: "tt.callExclusions") == exclusions)
        #expect(defaults.object(forKey: "tt.showsCallNotices") as? Bool == false)
        #expect(defaults.string(forKey: "tt.callEngine") == "geminiFlash")
        #expect(defaults.object(forKey: "tt.browserExtensionHintDismissed") as? Bool == true)
    }
}
