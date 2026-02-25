import Foundation

// MARK: - OpenAI web error messaging

extension UsageStore {
    static let openAIWebRefreshMultiplier: TimeInterval = 5

    func openAIWebRefreshIntervalSeconds() -> TimeInterval {
        let base = max(self.settings.refreshFrequency.seconds ?? 0, 120)
        return base * Self.openAIWebRefreshMultiplier
    }

    func requestOpenAIDashboardRefreshIfStale(reason: String) {
        guard self.isEnabled(.codex), self.settings.codexCookieSource.isEnabled else { return }
        let now = Date()
        let refreshInterval = self.openAIWebRefreshIntervalSeconds()
        let lastUpdatedAt = self.openAIDashboard?.updatedAt ?? self.lastOpenAIDashboardSnapshot?.updatedAt
        if let lastUpdatedAt, now.timeIntervalSince(lastUpdatedAt) < refreshInterval { return }
        let stamp = now.formatted(date: .abbreviated, time: .shortened)
        self.logOpenAIWeb("[\(stamp)] OpenAI web refresh request: \(reason)")
        guard self.openAIDashboardRefreshTask == nil else { return }
        self.openAIDashboardRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.openAIDashboardRefreshTask = nil }
            await self.refreshOpenAIDashboardIfNeeded(force: true)
        }
    }

    func codexAccountEmailForOpenAIDashboard() -> String? {
        let direct = self.snapshots[.codex]?.accountEmail(for: .codex)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct, !direct.isEmpty { return direct }
        self.refreshAccountInfoCacheIfNeeded()
        let fallback = self.accountInfo().email?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback, !fallback.isEmpty { return fallback }
        let cached = self.openAIDashboard?.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached, !cached.isEmpty { return cached }
        let imported = self.lastOpenAIDashboardCookieImportEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let imported, !imported.isEmpty { return imported }
        return nil
    }

    func openAIDashboardFriendlyError(
        body: String,
        targetEmail: String?,
        cookieImportStatus: String?) -> String?
    {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = cookieImportStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return [
                "OpenAI web dashboard returned an empty page.",
                "Sign in to chatgpt.com and update OpenAI cookies in Providers → Codex.",
            ].joined(separator: " ")
        }

        let lower = trimmed.lowercased()
        let looksLikePublicLanding = lower.contains("skip to content")
            && (lower.contains("about") || lower.contains("openai") || lower.contains("chatgpt"))
        let looksLoggedOut = lower.contains("sign in")
            || lower.contains("log in")
            || lower.contains("create account")
            || lower.contains("continue with google")
            || lower.contains("continue with apple")
            || lower.contains("continue with microsoft")

        guard looksLikePublicLanding || looksLoggedOut else { return nil }
        let emailLabel = targetEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetLabel = (emailLabel?.isEmpty == false) ? emailLabel! : "your OpenAI account"
        if let status, !status.isEmpty {
            if status.contains("cookies do not match Codex account")
                || status.localizedCaseInsensitiveContains("cookie import failed")
            {
                return [
                    status,
                    "Sign in to chatgpt.com as \(targetLabel), then update OpenAI cookies in Providers → Codex.",
                ].joined(separator: " ")
            }
        }
        return [
            "OpenAI web dashboard returned a public page (not signed in).",
            "Sign in to chatgpt.com as \(targetLabel), then update OpenAI cookies in Providers → Codex.",
        ].joined(separator: " ")
    }
}
