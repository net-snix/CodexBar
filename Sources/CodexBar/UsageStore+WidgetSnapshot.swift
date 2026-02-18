import CodexBarCore
import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

extension UsageStore {
    func persistWidgetSnapshot(reason: String) {
        let snapshot = self.makeWidgetSnapshot()
        let signature = Self.widgetSnapshotSignature(snapshot)
        let now = Date()
        let shouldReload = self.shouldReloadWidgetTimelines(signature: signature, now: now)
        Task.detached(priority: .utility) {
            WidgetSnapshotStore.save(snapshot)
            #if canImport(WidgetKit)
            if shouldReload {
                await MainActor.run {
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
            #endif
        }
    }

    private func makeWidgetSnapshot() -> WidgetSnapshot {
        let enabledProviders = self.enabledProviders()
        let entries = enabledProviders.compactMap { provider in
            self.makeWidgetEntry(for: provider)
        }
        return WidgetSnapshot(entries: entries, enabledProviders: enabledProviders, generatedAt: Date())
    }

    private func makeWidgetEntry(for provider: UsageProvider) -> WidgetSnapshot.ProviderEntry? {
        guard let snapshot = self.snapshots[provider] else { return nil }

        let tokenSnapshot = self.tokenSnapshots[provider]
        let dailyUsage = tokenSnapshot?.daily.map { entry in
            WidgetSnapshot.DailyUsagePoint(
                dayKey: entry.date,
                totalTokens: entry.totalTokens,
                costUSD: entry.costUSD)
        } ?? []

        let tokenUsage = Self.widgetTokenUsageSummary(from: tokenSnapshot)
        let creditsRemaining = provider == .codex ? self.credits?.remaining : nil
        let codeReviewRemaining = provider == .codex ? self.openAIDashboard?.codeReviewRemainingPercent : nil

        return WidgetSnapshot.ProviderEntry(
            provider: provider,
            updatedAt: snapshot.updatedAt,
            primary: snapshot.primary,
            secondary: snapshot.secondary,
            tertiary: snapshot.tertiary,
            creditsRemaining: creditsRemaining,
            codeReviewRemainingPercent: codeReviewRemaining,
            tokenUsage: tokenUsage,
            dailyUsage: dailyUsage)
    }

    private nonisolated static func widgetTokenUsageSummary(
        from snapshot: CostUsageTokenSnapshot?) -> WidgetSnapshot.TokenUsageSummary?
    {
        guard let snapshot else { return nil }
        let fallbackTokens = snapshot.daily.compactMap(\.totalTokens).reduce(0, +)
        let monthTokensValue = snapshot.last30DaysTokens ?? (fallbackTokens > 0 ? fallbackTokens : nil)
        return WidgetSnapshot.TokenUsageSummary(
            sessionCostUSD: snapshot.sessionCostUSD,
            sessionTokens: snapshot.sessionTokens,
            last30DaysCostUSD: snapshot.last30DaysCostUSD,
            last30DaysTokens: monthTokensValue)
    }

    private func shouldReloadWidgetTimelines(signature: String, now: Date) -> Bool {
        guard signature != self.lastWidgetSnapshotSignature else { return false }
        if let lastReloadAt = self.lastWidgetTimelineReloadAt,
           now.timeIntervalSince(lastReloadAt) < self.widgetTimelineReloadMinimumInterval
        {
            return false
        }
        self.lastWidgetSnapshotSignature = signature
        self.lastWidgetTimelineReloadAt = now
        return true
    }

    private nonisolated static func widgetSnapshotSignature(_ snapshot: WidgetSnapshot) -> String {
        let enabled = snapshot.enabledProviders.map(\.rawValue).joined(separator: ",")
        let entries = snapshot.entries
            .sorted { $0.provider.rawValue < $1.provider.rawValue }
            .map(Self.widgetEntrySignature)
            .joined(separator: "|")
        return "\(enabled)#\(entries)"
    }

    private nonisolated static func widgetEntrySignature(_ entry: WidgetSnapshot.ProviderEntry) -> String {
        let primary = Self.widgetWindowSignature(entry.primary)
        let secondary = Self.widgetWindowSignature(entry.secondary)
        let tertiary = Self.widgetWindowSignature(entry.tertiary)
        let tokenUsage: String = {
            guard let usage = entry.tokenUsage else { return "-" }
            return [
                Self.widgetDouble(usage.sessionCostUSD),
                Self.widgetInt(usage.sessionTokens),
                Self.widgetDouble(usage.last30DaysCostUSD),
                Self.widgetInt(usage.last30DaysTokens),
            ].joined(separator: ",")
        }()
        let daily = entry.dailyUsage.map { point in
            "\(point.dayKey):\(Self.widgetInt(point.totalTokens)):\(Self.widgetDouble(point.costUSD))"
        }.joined(separator: ";")
        return [
            entry.provider.rawValue,
            primary,
            secondary,
            tertiary,
            Self.widgetDouble(entry.creditsRemaining),
            Self.widgetDouble(entry.codeReviewRemainingPercent),
            tokenUsage,
            daily,
        ].joined(separator: "|")
    }

    private nonisolated static func widgetWindowSignature(_ window: RateWindow?) -> String {
        guard let window else { return "-" }
        return [
            Self.widgetDouble(window.usedPercent),
            "\(window.windowMinutes ?? -1)",
            Self.widgetDouble(window.resetsAt?.timeIntervalSince1970),
        ].joined(separator: ",")
    }

    private nonisolated static func widgetDouble(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.4f", value)
    }

    private nonisolated static func widgetInt(_ value: Int?) -> String {
        guard let value else { return "-" }
        return "\(value)"
    }
}
