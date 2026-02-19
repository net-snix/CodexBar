import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite
struct UsageStoreTokenAccountRefreshTests {
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
    func tokenAccountRefreshRunsConcurrently() async {
        let settings = Self.makeSettingsStore(suite: "UsageStoreTokenAccountRefreshTests-concurrency")
        let store = Self.makeUsageStore(settings: settings)
        settings.addTokenAccount(provider: .zai, label: "A", token: "token-a")
        settings.addTokenAccount(provider: .zai, label: "B", token: "token-b")
        settings.addTokenAccount(provider: .zai, label: "C", token: "token-c")
        let accounts = settings.tokenAccounts(for: .zai)
        let tracker = ConcurrencyTracker()

        await store.refreshTokenAccounts(provider: .zai, accounts: accounts) { account in
            tracker.begin()
            defer { tracker.end() }
            try? await Task.sleep(nanoseconds: 200_000_000)
            return Self.makeSuccessOutcome(
                provider: .zai,
                strategyID: "stub-\(account.label)",
                sourceLabel: account.label)
        }

        #expect(tracker.maxInFlight >= 2)
        #expect(store.accountSnapshots[.zai]?.count == 3)
    }

    @Test
    func selectedAccountOutcomeRemainsPrimary() async {
        let settings = Self.makeSettingsStore(suite: "UsageStoreTokenAccountRefreshTests-selected")
        let store = Self.makeUsageStore(settings: settings)
        settings.addTokenAccount(provider: .zai, label: "Primary", token: "token-1")
        settings.addTokenAccount(provider: .zai, label: "Selected", token: "token-2")
        settings.addTokenAccount(provider: .zai, label: "Third", token: "token-3")
        settings.setActiveTokenAccountIndex(1, for: .zai)
        let accounts = settings.tokenAccounts(for: .zai)
        let selected = settings.selectedTokenAccount(for: .zai)

        var outcomes: [UUID: ProviderFetchOutcome] = [:]
        for account in accounts {
            let sourceLabel = account.id == selected?.id ? "selected-source" : "other-source"
            outcomes[account.id] = Self.makeSuccessOutcome(
                provider: .zai,
                strategyID: "stub-\(account.label)",
                sourceLabel: sourceLabel)
        }

        await store.applyTokenAccountOutcomes(
            provider: .zai,
            accounts: accounts,
            effectiveSelected: selected,
            outcomes: outcomes)

        #expect(store.accountSnapshots[.zai]?.map(\.account.id) == accounts.map(\.id))
        #expect(store.lastSourceLabels[.zai] == "selected-source")
        #expect(store.snapshots[.zai]?.identity(for: .zai)?.accountEmail == "Selected")
    }

    private nonisolated static func makeSuccessOutcome(
        provider: UsageProvider,
        strategyID: String,
        sourceLabel: String) -> ProviderFetchOutcome
    {
        let usage = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let result = ProviderFetchResult(
            usage: usage.scoped(to: provider),
            credits: nil,
            dashboard: nil,
            sourceLabel: sourceLabel,
            strategyID: strategyID,
            strategyKind: .apiToken)
        let attempts = [
            ProviderFetchAttempt(
                strategyID: strategyID,
                kind: .apiToken,
                wasAvailable: true,
                errorDescription: nil),
        ]
        return ProviderFetchOutcome(result: .success(result), attempts: attempts)
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
