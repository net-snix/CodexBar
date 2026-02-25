import CodexBarCore
import Foundation

extension UsageStore {
    /// Returns true when Codex appears to be a ChatGPT Pro account.
    /// Uses Codex-only identity sources: snapshot login method, OpenAI dashboard plan, then account fallback.
    func isCodexProSubscriber() -> Bool {
        Self.isCodexProPlan(self.codexPlanName())
    }

    /// Determines if a Codex plan string indicates ChatGPT Pro.
    nonisolated static func isCodexProPlan(_ plan: String?) -> Bool {
        guard let plan = plan?.trimmingCharacters(in: .whitespacesAndNewlines),
              !plan.isEmpty else { return false }

        let cleaned = UsageFormatter.cleanPlanName(plan).lowercased()
        let tokens = cleaned.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if tokens.contains(where: { $0 == "pro" }) { return true }
        if tokens.contains(where: { $0 == "spark" }) { return true }

        // Some sources serialize this without spaces.
        let compact = cleaned.replacingOccurrences(of: " ", with: "")
        return compact.contains("chatgptpro")
    }

    var codexSnapshot: UsageSnapshot? {
        self.snapshots[.codex]
    }

    var claudeSnapshot: UsageSnapshot? {
        self.snapshots[.claude]
    }

    var lastCodexError: String? {
        self.errors[.codex]
    }

    var lastClaudeError: String? {
        self.errors[.claude]
    }

    func error(for provider: UsageProvider) -> String? {
        self.errors[provider]
    }

    func status(for provider: UsageProvider) -> ProviderStatus? {
        guard self.statusChecksEnabled else { return nil }
        return self.statuses[provider]
    }

    func statusIndicator(for provider: UsageProvider) -> ProviderStatusIndicator {
        self.status(for: provider)?.indicator ?? .none
    }

    func accountInfo() -> AccountInfo {
        let now = Date()
        if let cached = self.cachedAccountInfo,
           let loadedAt = self.cachedAccountInfoLoadedAt
        {
            if now.timeIntervalSince(loadedAt) < self.accountInfoCacheTTL {
                return cached
            }
            self.refreshAccountInfoCacheIfNeeded()
            return cached
        }

        let info = self.codexFetcher.loadAccountInfo()
        self.cachedAccountInfo = info
        self.cachedAccountInfoLoadedAt = now
        return info
    }

    func refreshAccountInfoCacheIfNeeded(force: Bool = false) {
        let now = Date()
        if !force,
           let loadedAt = self.cachedAccountInfoLoadedAt,
           now.timeIntervalSince(loadedAt) < self.accountInfoCacheTTL
        {
            return
        }
        guard self.accountInfoRefreshTask == nil else { return }

        let fetcher = self.codexFetcher
        self.accountInfoRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.accountInfoRefreshTask = nil }
            let info = await Task.detached(priority: .utility) {
                fetcher.loadAccountInfo()
            }.value
            self.cachedAccountInfo = info
            self.cachedAccountInfoLoadedAt = Date()
        }
    }

    private func codexPlanName() -> String? {
        if let plan = self.snapshots[.codex]?.loginMethod(for: .codex)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plan.isEmpty
        {
            return plan
        }

        if let plan = self.openAIDashboard?.accountPlan?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plan.isEmpty
        {
            return plan
        }

        if let plan = self.accountInfo().plan?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plan.isEmpty
        {
            return plan
        }

        return nil
    }
}
