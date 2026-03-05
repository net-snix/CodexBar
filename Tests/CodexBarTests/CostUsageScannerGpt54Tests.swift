import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct CostUsageScannerGpt54Tests {
    @Test
    func codexDailyReportSupportsGpt54Sessions() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 5)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "openai/gpt-5.4"
        let turnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": [
                "model": model,
            ],
        ]
        let tokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 1200,
                        "cached_input_tokens": 300,
                        "output_tokens": 90,
                    ],
                    "model": model,
                ],
            ],
        ]

        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "gpt-54-session.jsonl",
            contents: env.jsonl([turnContext, tokenCount]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(report.data.count == 1)
        #expect(report.data[0].modelsUsed == ["gpt-5.4"])
        #expect(report.data[0].totalTokens == 1290)
        #expect((report.data[0].costUSD ?? 0) > 0)
    }
}
