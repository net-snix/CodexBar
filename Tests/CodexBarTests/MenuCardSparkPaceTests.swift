import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite
struct MenuCardSparkPaceTests {
    @Test
    func sparkWeeklyPaceDetailShowsDuringFreshWindow() throws {
        let now = Date(timeIntervalSince1970: 0)
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: "codex@example.com",
            accountOrganization: nil,
            loginMethod: "Pro")
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            codexExtraUsage: CodexExtraUsageSnapshot(
                codeReviewRemainingPercent: nil,
                sparkRemainingPercent: nil,
                sparkFiveHourWindow: nil,
                sparkSevenDayWindow: RateWindow(
                    usedPercent: 0,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval((6 * 24 * 3600) + (23 * 3600)),
                    resetDescription: nil)),
            updatedAt: now,
            identity: identity)
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "codex@example.com", plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showCodexCodeReviewUsage: false,
            showCodexSparkUsage: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.metrics.contains { $0.id == "spark-7d" && $0.detailLeftText == "On pace" })
        #expect(model.metrics.contains { $0.id == "spark-7d" && $0.detailRightText == "Lasts until reset" })
    }
}
