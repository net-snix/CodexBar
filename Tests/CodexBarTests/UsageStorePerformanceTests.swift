import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct UsageStorePerformanceTests {
    @Test
    func providerAvailabilityCacheInvalidation() throws {
        let suite = "UsageStorePerformanceTests-provider-cache"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: StubZaiTokenStore(token: nil),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        guard UsageProvider.allCases.contains(.zai) else { return }
        let metadata = try #require(ProviderRegistry.shared.metadata[.zai])
        settings.setProviderEnabled(provider: .zai, metadata: metadata, enabled: true)
        settings.zaiAPIToken = ""
        store._setProviderAvailabilityCacheTTLForTesting(60)
        store._invalidateProviderAvailabilityCacheForTesting()

        #expect(store.isProviderAvailable(.zai) == false)

        settings.zaiAPIToken = "zai-live-token"
        // Cached stale result should still be false until cache invalidates.
        #expect(store.isProviderAvailable(.zai) == false)

        store._invalidateProviderAvailabilityCacheForTesting()
        #expect(store.isProviderAvailable(.zai) == true)
    }

    @Test
    func enabledProvidersCacheBenchmark() throws {
        let suite = "UsageStorePerformanceTests-enabled-providers"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: StubZaiTokenStore(token: "zai-live-token"),
            syntheticTokenStore: StubSyntheticTokenStore(token: "synthetic-live-token"))
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        guard UsageProvider.allCases.contains(.zai),
              UsageProvider.allCases.contains(.synthetic)
        else { return }

        let metadata = ProviderRegistry.shared.metadata
        if let zai = metadata[.zai] {
            settings.setProviderEnabled(provider: .zai, metadata: zai, enabled: true)
        }
        if let synthetic = metadata[.synthetic] {
            settings.setProviderEnabled(provider: .synthetic, metadata: synthetic, enabled: true)
        }

        let iterations = 4000
        store._setProviderAvailabilityCacheTTLForTesting(0)
        let uncachedMs = Self.measureMilliseconds {
            for _ in 0..<iterations {
                _ = store.enabledProviders()
            }
        }

        store._setProviderAvailabilityCacheTTLForTesting(60)
        _ = store.enabledProviders()
        let cachedMs = Self.measureMilliseconds {
            for _ in 0..<iterations {
                _ = store.enabledProviders()
            }
        }

        print("""
        {"benchmark":"enabled_providers","iterations":\(iterations),"uncached_ms":\(String(
            format: "%.3f",
            uncachedMs)),"cached_ms":\(String(format: "%.3f", cachedMs))}
        """)
        #expect(cachedMs < uncachedMs)
    }

    @Test
    func widgetSnapshotSignatureDedupe() throws {
        let suite = "UsageStorePerformanceTests-widget"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        let metadata = try #require(ProviderRegistry.shared.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: now, resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .codex)

        store.persistWidgetSnapshot(reason: "test-1")
        let first = store.lastPersistedWidgetSnapshotSignature
        store.persistWidgetSnapshot(reason: "test-2")
        let second = store.lastPersistedWidgetSnapshotSignature

        #expect(first != nil)
        #expect(first == second)

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 55, windowMinutes: 300, resetsAt: now, resetDescription: nil),
                secondary: nil,
                updatedAt: now.addingTimeInterval(1)),
            provider: .codex)
        store.persistWidgetSnapshot(reason: "test-3")
        let third = store.lastPersistedWidgetSnapshotSignature
        #expect(third != second)
    }

    private static func measureMilliseconds(_ block: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        block()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000.0
    }
}

private struct StubZaiTokenStore: ZaiTokenStoring {
    var token: String?

    func loadToken() throws -> String? {
        self.token
    }

    func storeToken(_: String?) throws {}
}

private struct StubSyntheticTokenStore: SyntheticTokenStoring {
    var token: String?

    func loadToken() throws -> String? {
        self.token
    }

    func storeToken(_: String?) throws {}
}
