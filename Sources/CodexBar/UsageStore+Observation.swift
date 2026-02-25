import CodexBarCore
import Foundation
import Observation

// MARK: - Observation helpers

@MainActor
extension UsageStore {
    var statusItemObservationToken: Int {
        _ = self.snapshots
        _ = self.errors
        _ = self.lastSourceLabels
        _ = self.accountSnapshots
        _ = self.tokenSnapshots
        _ = self.tokenErrors
        _ = self.tokenRefreshInFlight
        _ = self.credits
        _ = self.lastCreditsError
        _ = self.openAIDashboard
        _ = self.lastOpenAIDashboardError
        _ = self.openAIDashboardRequiresLogin
        _ = self.openAIDashboardCookieImportStatus
        _ = self.versions
        _ = self.isRefreshing
        _ = self.refreshingProviders
        _ = self.statuses
        return 0
    }

    /// Backwards-compatible alias for existing call sites.
    var menuObservationToken: Int {
        self.statusItemObservationToken
    }

    var debugObservationToken: Int {
        _ = self.lastFetchAttempts
        _ = self.pathDebugInfo
        _ = self.probeLogs
        _ = self.openAIDashboardCookieImportDebugLog
        return 0
    }

    func observeSettingsChanges() {
        self.observeRefreshAffectingSettings()
        self.observeDisplayOnlySettings()
    }

    private func observeRefreshAffectingSettings() {
        withObservationTracking {
            _ = self.settings.refreshFrequency
            _ = self.settings.statusChecksEnabled
            _ = self.settings.costUsageEnabled
            _ = self.settings.configRevision
            for implementation in ProviderCatalog.all {
                implementation.observeSettings(self.settings)
            }
            _ = self.settings.tokenAccountsByProvider
            _ = self.settings.debugKeepCLISessionsAlive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeRefreshAffectingSettings()
                self.settingsRefreshTask?.cancel()
                self.settingsRefreshTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, !Task.isCancelled else { return }
                    self.invalidateProviderAvailabilityCache()
                    self.startTimer()
                    self.updateProviderRuntimes()
                    await self.refresh()
                }
            }
        }
    }

    private func observeDisplayOnlySettings() {
        withObservationTracking {
            _ = self.settings.sessionQuotaNotificationsEnabled
            _ = self.settings.usageBarsShowUsed
            _ = self.settings.codexSparkUsageEnabled
            _ = self.settings.randomBlinkEnabled
            _ = self.settings.showAllTokenAccountsInMenu
            _ = self.settings.mergeIcons
            _ = self.settings.selectedMenuProvider
            _ = self.settings.debugLoadingPattern
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeDisplayOnlySettings()
                self.persistWidgetSnapshot(reason: "settings-display")
            }
        }
    }
}

#if DEBUG
extension UsageStore {
    func _setSnapshotForTesting(_ snapshot: UsageSnapshot?, provider: UsageProvider) {
        self.snapshots[provider] = snapshot?.scoped(to: provider)
    }

    func _setTokenSnapshotForTesting(_ snapshot: CostUsageTokenSnapshot?, provider: UsageProvider) {
        self.tokenSnapshots[provider] = snapshot
    }

    func _setTokenErrorForTesting(_ error: String?, provider: UsageProvider) {
        self.tokenErrors[provider] = error
    }

    func _setErrorForTesting(_ error: String?, provider: UsageProvider) {
        self.errors[provider] = error
    }

    func _setProviderAvailabilityCacheTTLForTesting(_ ttl: TimeInterval) {
        self.providerAvailabilityCacheTTL = max(0, ttl)
        self.invalidateProviderAvailabilityCache()
    }

    func _invalidateProviderAvailabilityCacheForTesting() {
        self.invalidateProviderAvailabilityCache()
    }
}
#endif
