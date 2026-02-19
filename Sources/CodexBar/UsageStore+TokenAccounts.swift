import CodexBarCore
import Foundation

struct TokenAccountUsageSnapshot: Identifiable, Sendable {
    let id: UUID
    let account: ProviderTokenAccount
    let snapshot: UsageSnapshot?
    let error: String?
    let sourceLabel: String?

    init(account: ProviderTokenAccount, snapshot: UsageSnapshot?, error: String?, sourceLabel: String?) {
        self.id = account.id
        self.account = account
        self.snapshot = snapshot
        self.error = error
        self.sourceLabel = sourceLabel
    }
}

extension UsageStore {
    func tokenAccounts(for provider: UsageProvider) -> [ProviderTokenAccount] {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return [] }
        return self.settings.tokenAccounts(for: provider)
    }

    func shouldFetchAllTokenAccounts(provider: UsageProvider, accounts: [ProviderTokenAccount]) -> Bool {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return false }
        return self.settings.showAllTokenAccountsInMenu && accounts.count > 1
    }

    func refreshTokenAccounts(provider: UsageProvider, accounts: [ProviderTokenAccount]) async {
        let selectedAccount = self.settings.selectedTokenAccount(for: provider)
        let limitedAccounts = self.limitedTokenAccounts(accounts, selected: selectedAccount)
        let effectiveSelected = selectedAccount ?? limitedAccounts.first
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let requests = limitedAccounts.map { account in
            TokenAccountFetchRequest(
                accountID: account.id,
                context: self.makeFetchContext(
                    provider: provider,
                    override: TokenAccountOverride(provider: provider, account: account)),
                descriptor: descriptor)
        }
        let outcomes = await Self.fetchAccountOutcomesConcurrently(requests: requests)
        await self.applyTokenAccountOutcomes(
            provider: provider,
            accounts: limitedAccounts,
            effectiveSelected: effectiveSelected,
            outcomes: outcomes)
    }

    func refreshTokenAccounts(
        provider: UsageProvider,
        accounts: [ProviderTokenAccount],
        fetchOutcomeForAccount: @escaping @Sendable (ProviderTokenAccount) async -> ProviderFetchOutcome) async
    {
        let selectedAccount = self.settings.selectedTokenAccount(for: provider)
        let limitedAccounts = self.limitedTokenAccounts(accounts, selected: selectedAccount)
        let effectiveSelected = selectedAccount ?? limitedAccounts.first
        let outcomes = await Self.fetchAccountOutcomesConcurrently(
            accounts: limitedAccounts,
            fetchOutcomeForAccount: fetchOutcomeForAccount)
        await self.applyTokenAccountOutcomes(
            provider: provider,
            accounts: limitedAccounts,
            effectiveSelected: effectiveSelected,
            outcomes: outcomes)
    }

    func applyTokenAccountOutcomes(
        provider: UsageProvider,
        accounts: [ProviderTokenAccount],
        effectiveSelected: ProviderTokenAccount?,
        outcomes: [UUID: ProviderFetchOutcome]) async
    {
        var snapshots: [TokenAccountUsageSnapshot] = []
        var selectedOutcome: ProviderFetchOutcome?
        var selectedSnapshot: UsageSnapshot?

        for account in accounts {
            let outcome = outcomes[account.id]
                ?? ProviderFetchOutcome(result: .failure(CancellationError()), attempts: [])
            let resolved = self.resolveAccountOutcome(outcome, provider: provider, account: account)
            snapshots.append(resolved.snapshot)
            if account.id == effectiveSelected?.id {
                selectedOutcome = outcome
                selectedSnapshot = resolved.usage
            }
        }

        self.accountSnapshots[provider] = snapshots

        if let selectedOutcome {
            await self.applySelectedOutcome(
                selectedOutcome,
                provider: provider,
                account: effectiveSelected,
                fallbackSnapshot: selectedSnapshot)
        }
    }

    func limitedTokenAccounts(
        _ accounts: [ProviderTokenAccount],
        selected: ProviderTokenAccount?) -> [ProviderTokenAccount]
    {
        let limit = 6
        if accounts.count <= limit { return accounts }
        var limited = Array(accounts.prefix(limit))
        if let selected, !limited.contains(where: { $0.id == selected.id }) {
            limited.removeLast()
            limited.append(selected)
        }
        return limited
    }

    private static func fetchAccountOutcomesConcurrently(requests: [TokenAccountFetchRequest]) async
        -> [UUID: ProviderFetchOutcome]
    {
        await withTaskGroup(
            of: (UUID, ProviderFetchOutcome).self,
            returning: [UUID: ProviderFetchOutcome].self)
        { group in
            for request in requests {
                group.addTask {
                    let outcome = await request.descriptor.fetchOutcome(context: request.context)
                    return (request.accountID, outcome)
                }
            }

            var outcomes: [UUID: ProviderFetchOutcome] = [:]
            outcomes.reserveCapacity(requests.count)
            for await (accountID, outcome) in group {
                outcomes[accountID] = outcome
            }
            return outcomes
        }
    }

    static func fetchAccountOutcomesConcurrently(
        accounts: [ProviderTokenAccount],
        fetchOutcomeForAccount: @escaping @Sendable (ProviderTokenAccount) async -> ProviderFetchOutcome)
        async -> [UUID: ProviderFetchOutcome]
    {
        await withTaskGroup(
            of: (UUID, ProviderFetchOutcome).self,
            returning: [UUID: ProviderFetchOutcome].self)
        { group in
            for account in accounts {
                group.addTask {
                    let outcome = await fetchOutcomeForAccount(account)
                    return (account.id, outcome)
                }
            }

            var outcomes: [UUID: ProviderFetchOutcome] = [:]
            outcomes.reserveCapacity(accounts.count)
            for await (accountID, outcome) in group {
                outcomes[accountID] = outcome
            }
            return outcomes
        }
    }

    func fetchOutcome(
        provider: UsageProvider,
        override: TokenAccountOverride?) async -> ProviderFetchOutcome
    {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
        let context = self.makeFetchContext(provider: provider, override: override)
        return await descriptor.fetchOutcome(context: context)
    }

    func makeFetchContext(provider: UsageProvider, override: TokenAccountOverride?) -> ProviderFetchContext {
        let sourceMode = self.sourceMode(for: provider)
        let snapshot = ProviderRegistry.makeSettingsSnapshot(settings: self.settings, tokenOverride: override)
        let env = ProviderRegistry.makeEnvironment(
            base: ProcessInfo.processInfo.environment,
            provider: provider,
            settings: self.settings,
            tokenOverride: override)
        let verbose = self.settings.isVerboseLoggingEnabled
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: verbose,
            env: env,
            settings: snapshot,
            fetcher: self.codexFetcher,
            claudeFetcher: self.claudeFetcher,
            browserDetection: self.browserDetection)
    }

    func sourceMode(for provider: UsageProvider) -> ProviderSourceMode {
        ProviderCatalog.implementation(for: provider)?
            .sourceMode(context: ProviderSourceModeContext(provider: provider, settings: self.settings))
            ?? .auto
    }

    private struct ResolvedAccountOutcome {
        let snapshot: TokenAccountUsageSnapshot
        let usage: UsageSnapshot?
    }

    private struct TokenAccountFetchRequest: Sendable {
        let accountID: UUID
        let context: ProviderFetchContext
        let descriptor: ProviderDescriptor
    }

    private func resolveAccountOutcome(
        _ outcome: ProviderFetchOutcome,
        provider: UsageProvider,
        account: ProviderTokenAccount) -> ResolvedAccountOutcome
    {
        switch outcome.result {
        case let .success(result):
            let scoped = result.usage.scoped(to: provider)
            let labeled = self.applyAccountLabel(scoped, provider: provider, account: account)
            let snapshot = TokenAccountUsageSnapshot(
                account: account,
                snapshot: labeled,
                error: nil,
                sourceLabel: result.sourceLabel)
            return ResolvedAccountOutcome(snapshot: snapshot, usage: labeled)
        case let .failure(error):
            let snapshot = TokenAccountUsageSnapshot(
                account: account,
                snapshot: nil,
                error: error.localizedDescription,
                sourceLabel: nil)
            return ResolvedAccountOutcome(snapshot: snapshot, usage: nil)
        }
    }

    func applySelectedOutcome(
        _ outcome: ProviderFetchOutcome,
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        fallbackSnapshot: UsageSnapshot?) async
    {
        await MainActor.run {
            self.lastFetchAttempts[provider] = outcome.attempts
        }
        switch outcome.result {
        case let .success(result):
            let scoped = result.usage.scoped(to: provider)
            let labeled: UsageSnapshot = if let account {
                self.applyAccountLabel(scoped, provider: provider, account: account)
            } else {
                scoped
            }
            await MainActor.run {
                self.handleSessionQuotaTransition(provider: provider, snapshot: labeled)
                self.snapshots[provider] = labeled
                self.lastSourceLabels[provider] = result.sourceLabel
                self.errors[provider] = nil
                self.failureGates[provider]?.recordSuccess()
            }
        case let .failure(error):
            await MainActor.run {
                let hadPriorData = self.snapshots[provider] != nil || fallbackSnapshot != nil
                let shouldSurface = self.failureGates[provider]?
                    .shouldSurfaceError(onFailureWithPriorData: hadPriorData) ?? true
                if shouldSurface {
                    self.errors[provider] = error.localizedDescription
                    self.snapshots.removeValue(forKey: provider)
                } else {
                    self.errors[provider] = nil
                }
            }
        }
    }

    func applyAccountLabel(
        _ snapshot: UsageSnapshot,
        provider: UsageProvider,
        account: ProviderTokenAccount) -> UsageSnapshot
    {
        let label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return snapshot }
        let existing = snapshot.identity(for: provider)
        let email = existing?.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEmail = (email?.isEmpty ?? true) ? label : email
        let identity = ProviderIdentitySnapshot(
            providerID: provider,
            accountEmail: resolvedEmail,
            accountOrganization: existing?.accountOrganization,
            loginMethod: existing?.loginMethod)
        return snapshot.withIdentity(identity)
    }
}
