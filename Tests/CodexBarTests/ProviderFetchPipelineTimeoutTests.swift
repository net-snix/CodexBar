import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct ProviderFetchPipelineTimeoutTests {
    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    private struct SlowStrategy: ProviderFetchStrategy {
        let id: String
        let kind: ProviderFetchKind = .apiToken
        let sleepNanoseconds: UInt64
        let fallbackOnTimeout: Bool

        func isAvailable(_: ProviderFetchContext) async -> Bool {
            true
        }

        func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
            try await Task.sleep(nanoseconds: self.sleepNanoseconds)
            let usage = UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date())
            return self.makeResult(usage: usage, sourceLabel: "slow")
        }

        func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
            guard self.fallbackOnTimeout else { return false }
            guard case .strategyTimedOut = (error as? ProviderFetchError) else { return false }
            return true
        }
    }

    private struct FastStrategy: ProviderFetchStrategy {
        let id: String
        let kind: ProviderFetchKind = .apiToken

        func isAvailable(_: ProviderFetchContext) async -> Bool {
            true
        }

        func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
            let usage = UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date())
            return self.makeResult(usage: usage, sourceLabel: "fast")
        }

        func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
            false
        }
    }

    private func makeContext() -> ProviderFetchContext {
        let env: [String: String] = [:]
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    @Test
    func timeoutFallsBackToNextStrategyWhenAllowed() async throws {
        let context = self.makeContext()
        let pipeline = ProviderFetchPipeline(strategyTimeout: 0.05) { _ in
            [
                SlowStrategy(id: "slow", sleepNanoseconds: 300_000_000, fallbackOnTimeout: true),
                FastStrategy(id: "fast"),
            ]
        }

        let outcome = await pipeline.fetch(context: context, provider: .codex)
        let result = try outcome.result.get()

        #expect(result.strategyID == "fast")
        #expect(outcome.attempts.count == 2)
        #expect(outcome.attempts[0].strategyID == "slow")
        #expect(outcome.attempts[0].errorDescription?.contains("timed out") == true)
        #expect(outcome.attempts[1].strategyID == "fast")
    }

    @Test
    func timeoutWithoutFallbackReturnsFailure() async throws {
        let context = self.makeContext()
        let pipeline = ProviderFetchPipeline(strategyTimeout: 0.05) { _ in
            [SlowStrategy(id: "slow", sleepNanoseconds: 300_000_000, fallbackOnTimeout: false)]
        }

        let outcome = await pipeline.fetch(context: context, provider: .codex)
        do {
            _ = try outcome.result.get()
            Issue.record("Expected timeout failure")
        } catch {
            let providerError = try #require(error as? ProviderFetchError)
            guard case let .strategyTimedOut(strategyID, seconds) = providerError else {
                Issue.record("Expected strategy timeout error, got \(providerError)")
                return
            }
            #expect(strategyID == "slow")
            #expect(seconds == 1)
        }

        #expect(outcome.attempts.count == 1)
        #expect(outcome.attempts[0].strategyID == "slow")
        #expect(outcome.attempts[0].errorDescription?.contains("timed out") == true)
    }
}
