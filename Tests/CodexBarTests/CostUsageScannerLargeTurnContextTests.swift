import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct CostUsageScannerLargeTurnContextTests {
    @Test
    func parseCodexFilePreservesModelFromLargeTurnContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codexbar-cost-usage-large-turn-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("session.jsonl", isDirectory: false)
        let timestamp = "2026-03-05T18:39:20.327Z"
        let largeInstructions = String(repeating: "x", count: 33000)

        let turnContext: [String: Any] = [
            "timestamp": timestamp,
            "type": "turn_context",
            "payload": [
                "turn_id": "turn-1",
                "model": "gpt-5.4",
                "user_instructions": largeInstructions,
            ],
        ]
        let tokenCount: [String: Any] = [
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 120,
                        "cached_input_tokens": 40,
                        "output_tokens": 9,
                    ],
                ],
            ],
        ]

        let lines = try [
            self.jsonLine(turnContext),
            self.jsonLine(tokenCount),
        ]
        let contents = lines.joined(separator: "\n") + "\n"
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let day = try #require(formatter.date(from: timestamp))
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let parsed = CostUsageScanner.parseCodexFile(fileURL: fileURL, range: range)

        #expect(parsed.days["2026-03-05"]?["gpt-5.4"]?[safe: 0] == 120)
        #expect(parsed.days["2026-03-05"]?["gpt-5.4"]?[safe: 1] == 40)
        #expect(parsed.days["2026-03-05"]?["gpt-5.4"]?[safe: 2] == 9)
        #expect(parsed.days["2026-03-05"]?["gpt-5"] == nil)
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw NSError(domain: "CostUsageScannerLargeTurnContextTests", code: 1)
        }
        return text
    }
}
