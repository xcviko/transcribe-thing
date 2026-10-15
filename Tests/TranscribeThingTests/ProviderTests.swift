import Foundation
import Testing
@testable import TranscribeThing

// One provider for every cloud request (Models → API keys → Provider): OpenRouter or the custom endpoint. The choice
// from "Use for Gemini", routing that never crosses to the other, and readiness that follows the choice.

@MainActor
@Suite(.serialized) struct ProviderMigrationTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = NSTemporaryDirectory() + "transcribe-thing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: suite + ".plist")
        }
        try body(defaults)
    }

    /// An endpoint saved by an older build, its key `key` (none for nil), "Use for Gemini" as `useForGemini` (nil: never
    /// touched, on). Returns the provider the app settles on, and the defaults.
    private func provider(url: String? = "https://llm.example.com/v1", key: String?, useForGemini: Bool?,
                          _ check: (AppSettings, UserDefaults) -> Void = { _, _ in }) throws -> CloudProvider {
        var result = CloudProvider.openRouter
        try withDefaults { defaults in
            if let url { defaults.set(url, forKey: SettingsKey.vertexProxyURL.defaultsKey) }
            if let useForGemini { defaults.set(useForGemini, forKey: SettingsKey.vertexProxyEnabled.defaultsKey) }
            let settings = AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() })
            #expect(settings.providerNeedsMigration)
            _ = VertexProxyAccount(keyStore: .inMemory(key), settings: settings)
            result = settings.cloudProvider
            #expect(!settings.providerNeedsMigration)
            check(settings, defaults)
        }
        return result
    }

    @Test func anEndpointSetUpAndOnBecomesTheProvider() throws {
        #expect(try provider(key: ProxyFixture.key, useForGemini: nil) == .vertexProxy)
        let on = try provider(key: ProxyFixture.key, useForGemini: true) { _, defaults in
            #expect(defaults.string(forKey: SettingsKey.cloudProvider.defaultsKey) == "vertexProxy")
            #expect(defaults.bool(forKey: SettingsKey.vertexProxyEnabled.defaultsKey), "kept in step for older builds")
        }
        #expect(on == .vertexProxy)
    }

    @Test func everyoneElseGetsOpenRouter() throws {
        #expect(try provider(key: ProxyFixture.key, useForGemini: false) == .openRouter, "switched off")
        #expect(try provider(key: nil, useForGemini: true) == .openRouter, "no key: never set up")
        #expect(try provider(url: nil, key: ProxyFixture.key, useForGemini: true) == .openRouter, "no URL")
        let none = try provider(url: nil, key: nil, useForGemini: nil) { _, defaults in
            #expect(defaults.string(forKey: SettingsKey.cloudProvider.defaultsKey) == "openRouter")
            #expect(defaults.object(forKey: SettingsKey.vertexProxyEnabled.defaultsKey) as? Bool == false)
        }
        #expect(none == .openRouter)
    }

    /// Once stored, the choice is the user's: the old switch and the endpoint's state no longer decide it.
    @Test func aStoredProviderStays() throws {
        try withDefaults { defaults in
            defaults.set("vertexProxy", forKey: SettingsKey.cloudProvider.defaultsKey)
            defaults.set(false, forKey: SettingsKey.vertexProxyEnabled.defaultsKey)
            let settings = AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() })
            #expect(!settings.providerNeedsMigration)
            let proxy = VertexProxyAccount(keyStore: .inMemory(nil), settings: settings)
            #expect(settings.cloudProvider == .vertexProxy && proxy.routesGemini && !proxy.isConfigured)
            settings.cloudProvider = .openRouter
            let reloaded = AppSettings(defaults: defaults, microphoneProbe: { MicrophoneMigrationProbe() })
            _ = VertexProxyAccount(keyStore: .inMemory(ProxyFixture.key), settings: reloaded)
            #expect(reloaded.cloudProvider == .openRouter)
        }
        #expect(AppSettings.migratedCloudProvider(endpointConfigured: true, useForGemini: true) == .vertexProxy)
        #expect(AppSettings.migratedCloudProvider(endpointConfigured: true, useForGemini: false) == .openRouter)
        #expect(AppSettings.migratedCloudProvider(endpointConfigured: false, useForGemini: true) == .openRouter)
    }
}

// MARK: - Routing

@MainActor
@Suite struct ProviderRoutingTests {
    /// OpenRouter picked: nothing goes to the endpoint, however set up it is.
    @Test func openRouterPickedNeverReachesTheEndpoint() async throws {
        let (proxy, proxyHost) = ProxyFixture.proxy([ProxyFixture.answer("never")], enabled: false)
        let (service, openRouterHost) = ProxyFixture.service(
            openRouterReplies: [.stream(SSE.answer("<transcript>OpenRouter.</transcript>"))], proxy: proxy)
        #expect(proxy.isConfigured && !proxy.routesGemini)
        let result = try await service.transcribe(ProxyFixture.speech(), engine: .geminiFlash)
        #expect(result.text == "OpenRouter.")
        #expect(StubURLProtocol.registry.requests(for: proxyHost).isEmpty)
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).count == 1)
    }

    /// The endpoint picked but not set up: Gemini fails as the endpoint's, and nothing goes to OpenRouter, though
    /// its key works.
    @Test func anEndpointNotSetUpNeverFallsBackToOpenRouter() async throws {
        let settings = AppSettings.inMemory()
        settings.cloudProvider = .vertexProxy
        let proxy = VertexProxyAccount(keyStore: .inMemory(nil), settings: settings)
        let (service, openRouterHost) = ProxyFixture.service(openRouterReplies: [ProxyFixture.answer("never")],
                                                             proxy: proxy)
        #expect(proxy.routesGemini && !proxy.isConfigured)
        await #expect(throws: AppError.vertexProxy(.notSetUp)) {
            try await service.transcribe(ProxyFixture.speech(), engine: .geminiFlash)
        }
        let route = try #require(PolishSelectionModel.geminiFlash.route)
        await #expect(throws: AppError.vertexProxy(.notSetUp)) {
            try await service.polishText("text", route: route, prompt: "Polish.", timeout: 5)
        }
        let (client, _) = StubURLProtocol.client([])
        let account = OpenRouterAccount(keyStore: .inMemory(ProxyFixture.openRouterKey), client: client, debounce: .zero)
        let send = CallTranscriber.openRouter(client: client, account: account, proxy: proxy)
        let sendText = CallTranscriber.openRouterText(client: client, account: account, proxy: proxy)
        await #expect(throws: AppError.vertexProxy(.notSetUp)) { try await send(Data([1]), "x", 1, nil) }
        await #expect(throws: AppError.vertexProxy(.notSetUp)) { try await sendText("x", "y") }
        #expect(StubURLProtocol.registry.requests(for: openRouterHost).isEmpty)
        #expect(CloudRoute.provider(for: .geminiFlash, proxy: proxy) == .vertexProxy)
        #expect(CloudRoute.provider(for: .parakeet, proxy: proxy) == nil)
    }

    @Test func theNotSetUpNoticePointsAtModels() {
        let notice = AppError.vertexProxy(.notSetUp).notice(recordingID: UUID(), fallbackEngine: .parakeet,
                                                             engine: .geminiFlash)
        #expect(notice.title == "Your endpoint isn’t set up")
        #expect(notice.actions.first?.kind == .openHub(.models))
        #expect(DictationController.homeFailureReason(.vertexProxy(.notSetUp), making: .polish())
                == "Your endpoint isn’t set up. Add its base URL and API key in Models.")
    }
}

// MARK: - Readiness

@MainActor
@Suite struct ProviderReadinessTests {
    /// The endpoint picked but not set up: Gemini needs the endpoint, whatever OpenRouter's key says.
    @Test func geminiNeedsTheEndpointWhenItsPickedButNotSetUp() {
        let settings = AppSettings.inMemory()
        settings.cloudProvider = .vertexProxy
        let proxy = VertexProxyAccount(keyStore: .inMemory(nil), settings: settings)
        let account = OpenRouterAccount.preview(status: .valid(KeyInfo()))
        for engine in EngineID.geminiEngines {
            let key = CloudRoute.keyStatus(for: engine, account: account, proxy: proxy)
            #expect(key == .missing)
            let readiness = EngineReadiness.of(engine, localState: .ready, keyStatus: key,
                                               provider: CloudRoute.provider(for: engine, proxy: proxy))
            #expect(readiness == .needsEndpoint && readiness.unavailableReason == "Needs endpoint")
            #expect(EngineSummary.make(engine: engine, localState: .ready, keyStatus: key, provider: .vertexProxy).status
                    == "Needs endpoint")
        }
        #expect(EngineReadiness.of(.geminiFlash, localState: .ready, keyStatus: .missing, provider: .openRouter)
                == .needsKey)
        #expect(EngineReadiness.of(.parakeet, localState: .ready, keyStatus: .missing, provider: nil) == .ready)
    }

    /// OpenRouter picked: its key decides, whatever the endpoint's state.
    @Test func openRouterPickedFollowsItsKey() {
        let (proxy, _) = ProxyFixture.proxy(enabled: false)
        let missing = OpenRouterAccount.preview(status: .missing)
        let key = CloudRoute.keyStatus(for: .geminiFlash, account: missing, proxy: proxy)
        #expect(key == .missing)
        #expect(EngineReadiness.of(.geminiFlash, localState: .ready, keyStatus: key,
                                   provider: CloudRoute.provider(for: .geminiFlash, proxy: proxy)) == .needsKey)
    }

    @Test func homeAsksToSetUpTheEndpoint() throws {
        let input = HubAttention.Input(microphone: .granted, accessibility: .granted, accessibilityLikelyStale: false,
                                       fnKeyUsage: .doNothing, pushToTalkUsesFn: true, engine: .geminiFlash,
                                       localState: .ready, keyStatus: .missing, provider: .vertexProxy)
        let item = try #require(HubAttention.items(input).first { $0.id == "key" })
        #expect(item.title == "Set up your endpoint" && item.actionTitle == "Set Up" && item.action == .openModels)
        var openRouter = input
        openRouter.provider = .openRouter
        #expect(HubAttention.items(openRouter).first { $0.id == "key" }?.title == "Add your OpenRouter key")
    }

    /// A dictation on Gemini with the endpoint picked and not set up is refused before it records, though OpenRouter's
    /// key works.
    @Test func aDictationIsRefusedBeforeRecording() throws {
        let proxySettings = AppSettings.inMemory()
        proxySettings.cloudProvider = .vertexProxy
        let proxy = VertexProxyAccount(keyStore: .inMemory(nil), settings: proxySettings)
        let h = DictationControllerTests.make(keyStatus: .valid(KeyInfo()), proxy: proxy)
        h.settings.lineup.main = .gemini
        h.controller.send(.handsFreeToggle)
        #expect(h.recorder.starts == 0)
        #expect(h.controller.machine.capture == .idle)
        let notice = try #require(h.toasts.notices.first)
        #expect(notice.title == "Your endpoint isn’t set up")
    }

    @Test func thePickerOffersBothAndTheFooterSaysTheOtherStays() {
        #expect(CloudProvider.allCases.map(\.name) == ["OpenRouter", "Custom endpoint"])
        #expect(APIKeysGroup.footer(.openRouter).contains("Your endpoint’s URL and key stay saved"))
        #expect(APIKeysGroup.footer(.vertexProxy).contains("Your OpenRouter key stays saved"))
    }
}
