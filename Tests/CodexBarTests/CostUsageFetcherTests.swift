import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct CostUsageFetcherTests {
    private final class LoaderRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var providers: [UsageProvider] = []
        private(set) var filters: [String] = []

        func record(provider: UsageProvider, filter: CostUsageScanner.ClaudeLogProviderFilter) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.providers.append(provider)
            self.filters.append(Self.filterLabel(filter))
        }

        var callCount: Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.providers.count
        }

        private static func filterLabel(_ filter: CostUsageScanner.ClaudeLogProviderFilter) -> String {
            switch filter {
            case .all:
                "all"
            case .vertexAIOnly:
                "vertexAIOnly"
            case .excludeVertexAI:
                "excludeVertexAI"
            }
        }
    }

    @Test
    func vertexFallbackSkipsDuplicateScanWhenEffectiveFilterMatches() async throws {
        let recorder = LoaderRecorder()
        let fetcher = CostUsageFetcher { provider, _, _, _, options in
            recorder.record(provider: provider, filter: options.claudeLogProviderFilter)
            return CostUsageDailyReport(data: [], summary: nil)
        }

        _ = try await fetcher.loadTokenSnapshot(
            provider: .vertexai,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            forceRefresh: true,
            allowVertexClaudeFallback: false)

        #expect(recorder.callCount == 1)
        #expect(recorder.providers.first == .vertexai)
        #expect(recorder.filters.first == "vertexAIOnly")
    }

    @Test
    func effectiveFilterMapsVertexAllToVertexOnly() {
        let mapped = CostUsageFetcher.effectiveClaudeLogProviderFilter(provider: .vertexai, requested: .all)
        switch mapped {
        case .vertexAIOnly:
            #expect(true)
        case .all, .excludeVertexAI:
            Issue.record("Expected .vertexAIOnly, got \(mapped)")
        }
    }
}
