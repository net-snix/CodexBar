import CodexBarCore
import Testing
@testable import CodexBar

@Suite
struct UsageBreakdownChartMenuViewTests {
    @Test
    func normalizesServiceNamesForDisplay() {
        #expect(UsageBreakdownChartMenuView.displayServiceName("Unknown") == "Other")
        #expect(UsageBreakdownChartMenuView.displayServiceName("  sdk  ") == "SDK")
        #expect(UsageBreakdownChartMenuView.displayServiceName("desktop app") == "Desktop App")
        #expect(UsageBreakdownChartMenuView.displayServiceName("CLI") == "CLI")
    }

    @Test
    func usesRequestedServicePalette() {
        let desktop = UsageBreakdownChartMenuView.serviceRGB(for: "Desktop App")
        let sdk = UsageBreakdownChartMenuView.serviceRGB(for: "SDK")
        let cli = UsageBreakdownChartMenuView.serviceRGB(for: "CLI")
        let other = UsageBreakdownChartMenuView.serviceRGB(for: "Unknown")

        #expect(Self.isApprox(desktop?.red, 0.88))
        #expect(Self.isApprox(desktop?.green, 0.24))
        #expect(Self.isApprox(desktop?.blue, 0.22))

        #expect(Self.isApprox(sdk?.red, 0.35))
        #expect(Self.isApprox(sdk?.green, 0.43))
        #expect(Self.isApprox(sdk?.blue, 0.27))

        #expect(Self.isApprox(cli?.red, 0.92))
        #expect(Self.isApprox(cli?.green, 0.40))
        #expect(Self.isApprox(cli?.blue, 0.69))

        #expect(Self.isApprox(other?.red, 0.57))
        #expect(Self.isApprox(other?.green, 0.57))
        #expect(Self.isApprox(other?.blue, 0.60))
    }

    @Test
    func computesServiceSharesAsPercentages() {
        let day = OpenAIDashboardDailyBreakdown(
            day: "2026-02-26",
            services: [
                OpenAIDashboardServiceUsage(service: "Desktop App", creditsUsed: 70),
                OpenAIDashboardServiceUsage(service: "CLI", creditsUsed: 20),
                OpenAIDashboardServiceUsage(service: "Unknown", creditsUsed: 5),
                OpenAIDashboardServiceUsage(service: "Other", creditsUsed: 5),
            ],
            totalCreditsUsed: 100)

        let shares = UsageBreakdownChartMenuView.normalizedServiceShares(for: day)
        let byService = Dictionary(uniqueKeysWithValues: shares.map { ($0.service, $0.percent) })

        #expect(Self.isApprox(byService["Desktop App"], 70))
        #expect(Self.isApprox(byService["CLI"], 20))
        #expect(Self.isApprox(byService["Other"], 10))
    }

    private static func isApprox(_ lhs: Double?, _ rhs: Double, epsilon: Double = 0.0001) -> Bool {
        guard let lhs else { return false }
        return abs(lhs - rhs) < epsilon
    }
}
