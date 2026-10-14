import Foundation
import Testing
@testable import TranscribeThing

// The browser extension as General, onboarding's calls step and the Calls tab show it: each browser's state and
// what its row says, the steps after Install, and when the Calls tab points to it.

@MainActor
private func browser(_ id: String, _ family: BrowserExtension.Family = .chromium) -> BrowserExtension.Browser {
    BrowserExtension.Browser(id: id, name: id, family: family, appURL: URL(fileURLWithPath: "/Applications/\(id).app"))
}

@MainActor
private func connection(_ browserID: String, _ index: Int = 1) -> BrowserExtension.Connection {
    BrowserExtension.Connection(id: "\(browserID)-\(index)", browserID: browserID, version: "0.1.0", lastSeen: Date())
}

private func call(_ bundleID: String?, minutesAgo: Double, manual: Bool = false) -> CallRecord {
    CallRecord(id: UUID(), startedAt: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60), appName: "App",
               bundleID: bundleID, manual: manual, status: .done)
}

@MainActor
@Suite struct BrowserExtensionCopyTests {
    @Test func firefoxAndSafariAreComingLaterWhateverTheySay() {
        #expect(BrowserExtensionCopy.state(of: browser("org.mozilla.firefox", .firefox), profiles: 0) == .comingLater)
        #expect(BrowserExtensionCopy.state(of: browser("com.apple.Safari", .safari), profiles: 2) == .comingLater)
    }

    @Test func chromiumIsInstalledOncePerProfileThatConnected() {
        let chrome = browser("com.google.Chrome")
        #expect(BrowserExtensionCopy.state(of: chrome, profiles: 0) == .notInstalled)
        #expect(BrowserExtensionCopy.state(of: chrome, profiles: 3) == .connected(profiles: 3))
    }

    @Test func statusCountsProfiles() {
        #expect(BrowserExtensionCopy.status(.notInstalled) == "Not installed")
        #expect(BrowserExtensionCopy.status(.comingLater) == "Coming later")
        #expect(BrowserExtensionCopy.status(.connected(profiles: 1)) == "Connected in 1 profile")
        #expect(BrowserExtensionCopy.status(.connected(profiles: 2)) == "Connected in 2 profiles")
    }

    @Test func onboardingRowsSayWhatWaitsOrHowManyProfiles() {
        #expect(CallsStep.rowDetail(.notInstalled, installing: false) == nil)
        #expect(CallsStep.rowDetail(.notInstalled, installing: true) == "Waiting for it to connect…")
        #expect(CallsStep.rowDetail(.connected(profiles: 1), installing: true) == nil)
        #expect(CallsStep.rowDetail(.connected(profiles: 2), installing: false) == "In 2 profiles")
        #expect(CallsStep.rowDetail(.comingLater, installing: true) == nil)
    }

    @Test func stepsEndWithEveryProfile() {
        #expect(BrowserExtensionCopy.steps.count == 3)
        #expect(BrowserExtensionCopy.steps.last?.contains("each profile") == true)
    }

    /// The Calls tab's note: the newest call in a Chromium browser on this Mac, while no profile anywhere has it.
    @Test func callsHintFollowsTheNewestBrowserCall() {
        let chrome = browser("com.google.Chrome"), arc = browser("company.thebrowser.Browser")
        let safari = browser("com.apple.Safari", .safari)
        let calls = [call("com.google.Chrome", minutesAgo: 90), call("company.thebrowser.Browser", minutesAgo: 30),
                     call("ru.keepcoder.Telegram", minutesAgo: 5), call(nil, minutesAgo: 1, manual: true)]
        #expect(BrowserExtensionCopy.hintBrowser(calls: calls, browsers: [chrome, arc, safari], connections: []) == arc)
        #expect(BrowserExtensionCopy.hintBrowser(calls: calls, browsers: [chrome, safari], connections: []) == chrome)
        // Safari's calls don't point to an extension it can't take yet.
        #expect(BrowserExtensionCopy.hintBrowser(calls: [call("com.apple.Safari", minutesAgo: 1)],
                                                 browsers: [chrome, safari], connections: []) == nil)
        // One connected profile anywhere: the note has done its job.
        #expect(BrowserExtensionCopy.hintBrowser(calls: calls, browsers: [chrome, arc],
                                                 connections: [connection(chrome.id)]) == nil)
        #expect(BrowserExtensionCopy.hintBrowser(calls: [call("ru.keepcoder.Telegram", minutesAgo: 1)],
                                                 browsers: [chrome], connections: []) == nil)
    }

    @Test func copyHasNoDashes() {
        for text in [BrowserExtensionCopy.settingsFooter, BrowserExtensionCopy.whatItDoes, BrowserExtensionCopy.noBrowsers,
                     BrowserExtensionCopy.callsHint(browser: "Arc")] + BrowserExtensionCopy.steps {
            #expect(!text.contains("—") && !text.contains("–"), "\(text)")
        }
    }
}

@MainActor
@Suite struct CallsStepModelTests {
    private func makeModel(_ ext: BrowserExtension) -> OnboardingModel {
        let env = AppEnvironment.preview()
        env.settings.onboardingCompleted = false
        env.settings.onboardingStep = OnboardingStep.calls.rawValue
        var ctx = OnboardingContext(env: env)
        ctx.browserExtension = ext
        return OnboardingModel(context: ctx)
    }

    @Test func callsStepNeverBlocks() {
        let model = makeModel(.preview(browsers: []))
        #expect(model.step == .calls)
        #expect(model.canContinue)
        model.primaryAction()
        #expect(model.step == .done)
    }

    @Test func installPutsTheBrowserOnTheStageUntilAnother() {
        let chrome = browser("com.google.Chrome"), arc = browser("company.thebrowser.Browser")
        let model = makeModel(.preview(browsers: [chrome, arc]))
        #expect(model.installingBrowser == nil)
        model.installExtension(chrome)
        #expect(model.installingBrowsers == [chrome.id])
        #expect(model.installingBrowser == chrome)
        model.installExtension(arc)
        #expect(model.installingBrowsers == [chrome.id, arc.id])
        #expect(model.installingBrowser == arc)
    }

    @Test func modeLinesSayWhatEachModeDoes() {
        #expect(CallsStep.modeLine(.ask).contains("asked"))
        #expect(CallsStep.modeLine(.automatic) == "Every call is recorded and transcribed.")
        #expect(CallsStep.modeLine(.off).contains("aren’t noticed"))
    }
}
