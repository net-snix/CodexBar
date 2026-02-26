import CodexBarCore
import Foundation

enum UsagePaceText {
    struct WeeklyDetail: Sendable {
        let leftLabel: String
        let rightLabel: String?
        let expectedUsedPercent: Double
        let stage: UsagePace.Stage
    }

    private static let minimumExpectedPercent: Double = 3

    static func weeklySummary(pace: UsagePace, now: Date = .init()) -> String {
        let detail = self.weeklyDetail(pace: pace, now: now)
        if let rightLabel = detail.rightLabel {
            return "Pace: \(detail.leftLabel) · \(rightLabel)"
        }
        return "Pace: \(detail.leftLabel)"
    }

    static func weeklySummary(
        provider: UsageProvider,
        window: RateWindow,
        now: Date = .init()) -> String?
    {
        guard let detail = weeklyDetail(
            provider: provider,
            window: window,
            now: now)
        else { return nil }
        if let rightLabel = detail.rightLabel {
            return "Pace: \(detail.leftLabel) · \(rightLabel)"
        }
        return "Pace: \(detail.leftLabel)"
    }

    static func weeklyDetail(
        pace: UsagePace,
        now: Date = .init()) -> WeeklyDetail
    {
        WeeklyDetail(
            leftLabel: self.detailLeftLabel(for: pace),
            rightLabel: self.detailRightLabel(for: pace, now: now),
            expectedUsedPercent: pace.expectedUsedPercent,
            stage: pace.stage)
    }

    static func weeklyDetail(
        provider: UsageProvider,
        window: RateWindow,
        now: Date = .init(),
        minimumExpectedPercent: Double = Self.minimumExpectedPercent) -> WeeklyDetail?
    {
        guard let pace = weeklyPace(
            provider: provider,
            window: window,
            now: now,
            minimumExpectedPercent: minimumExpectedPercent)
        else { return nil }
        return WeeklyDetail(
            leftLabel: Self.detailLeftLabel(for: pace),
            rightLabel: Self.detailRightLabel(for: pace, now: now),
            expectedUsedPercent: pace.expectedUsedPercent,
            stage: pace.stage)
    }

    private static func detailLeftLabel(for pace: UsagePace) -> String {
        let deltaValue = Int(abs(pace.deltaPercent).rounded())
        switch pace.stage {
        case .onTrack:
            return "On pace"
        case .slightlyAhead, .ahead, .farAhead:
            return "\(deltaValue)% in deficit"
        case .slightlyBehind, .behind, .farBehind:
            return "\(deltaValue)% in reserve"
        }
    }

    private static func detailRightLabel(for pace: UsagePace, now: Date) -> String? {
        let etaLabel: String?
        if pace.willLastToReset {
            etaLabel = "Lasts until reset"
        } else if let etaSeconds = pace.etaSeconds {
            let etaText = Self.durationText(seconds: etaSeconds, now: now)
            etaLabel = etaText == "now" ? "Runs out now" : "Runs out in \(etaText)"
        } else {
            etaLabel = nil
        }

        guard let runOutProbability = pace.runOutProbability else { return etaLabel }
        let roundedRisk = self.roundedRiskPercent(runOutProbability)
        let riskLabel = "≈ \(roundedRisk)% run-out risk"
        if let etaLabel {
            return "\(etaLabel) · \(riskLabel)"
        }
        return riskLabel
    }

    private static func durationText(seconds: TimeInterval, now: Date) -> String {
        let date = now.addingTimeInterval(seconds)
        let countdown = UsageFormatter.resetCountdownDescription(from: date, now: now)
        if countdown == "now" { return "now" }
        if countdown.hasPrefix("in ") { return String(countdown.dropFirst(3)) }
        return countdown
    }

    static func weeklyPace(
        provider: UsageProvider,
        window: RateWindow,
        now: Date,
        minimumExpectedPercent: Double = Self.minimumExpectedPercent) -> UsagePace?
    {
        guard provider == .codex || provider == .claude else { return nil }
        guard window.remainingPercent > 0 else { return nil }
        guard let pace = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 10080) else { return nil }
        guard pace.expectedUsedPercent >= minimumExpectedPercent else { return nil }
        return pace
    }

    private static func roundedRiskPercent(_ probability: Double) -> Int {
        let percent = Self.clamp(probability, lower: 0, upper: 1) * 100
        let rounded = (percent / 5).rounded() * 5
        return Int(rounded)
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(upper, max(lower, value))
    }
}
