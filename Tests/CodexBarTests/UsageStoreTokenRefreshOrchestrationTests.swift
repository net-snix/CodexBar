import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite
struct UsageStoreTokenRefreshOrchestrationTests {
    private final class ConcurrencyTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var inFlight: Int = 0
        private(set) var maxInFlight: Int = 0

        func begin() {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.inFlight += 1
            self.maxInFlight = max(self.maxInFlight, self.inFlight)
        }

        func end() {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.inFlight = max(0, self.inFlight - 1)
        }
    }

    @Test
    func tokenRefreshPassRunsProvidersConcurrently() async {
        let settings = Self.makeSettingsStore(suite: "UsageStoreTokenRefreshOrchestrationTests-concurrency")
        let store = Self.makeUsageStore(settings: settings)
        let tracker = ConcurrencyTracker()

        await store.runTokenRefreshPass(
            providers: [.codex, .claude, .vertexai],
            force: false)
        { _, _ in
            tracker.begin()
            defer { tracker.end() }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        #expect(tracker.maxInFlight >= 2)
    }

    @Test
    func prioritizedTokenRefreshProvidersSortsByStaleness() {
        let settings = Self.makeSettingsStore(suite: "UsageStoreTokenRefreshOrchestrationTests-priority")
        let store = Self.makeUsageStore(settings: settings)

        let now = Date()
        store.lastTokenFetchAt[.codex] = now
        store.lastTokenFetchAt[.claude] = now.addingTimeInterval(-120)
        store.lastTokenFetchAt[.vertexai] = nil

        let providers = store.sortTokenRefreshProvidersByStaleness([.codex, .claude, .vertexai])
        #expect(providers == [.vertexai, .claude, .codex])
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.refreshFrequency = .manual
        return settings
    }

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
    }
}
