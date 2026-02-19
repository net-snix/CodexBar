import Foundation
import SweetCookieKit
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeWebAPIFetcherSessionKeyCacheTests {
    @Test("Session key scan cache should reuse success within TTL")
    func sessionKeyScanCacheReusesSuccessWithinTTL() throws {
        ClaudeWebAPIFetcher._resetSessionKeyInfoCacheForTesting()
        ClaudeWebAPIFetcher._setSessionKeyInfoCacheTTLForTesting(30)
        defer { ClaudeWebAPIFetcher._resetSessionKeyInfoCacheForTesting() }

        var loaderCalls = 0
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let first = try ClaudeWebAPIFetcher._extractSessionKeyInfoForTesting(
            installedBrowsers: [.safari],
            now: now,
            sourceLoader: { _ in
                loaderCalls += 1
                return [
                    .init(
                        sourceLabel: "Safari",
                        cookies: [(name: "sessionKey", value: "sk-ant-first")]),
                ]
            })
        let second = try ClaudeWebAPIFetcher._extractSessionKeyInfoForTesting(
            installedBrowsers: [.safari],
            now: now.addingTimeInterval(1),
            sourceLoader: { _ in
                loaderCalls += 1
                return [
                    .init(
                        sourceLabel: "Safari",
                        cookies: [(name: "sessionKey", value: "sk-ant-second")]),
                ]
            })

        #expect(first.key == "sk-ant-first")
        #expect(second.key == "sk-ant-first")
        #expect(loaderCalls == 1)
    }

    @Test("Session key scan cache should expire after TTL")
    func sessionKeyScanCacheExpiresAfterTTL() throws {
        ClaudeWebAPIFetcher._resetSessionKeyInfoCacheForTesting()
        ClaudeWebAPIFetcher._setSessionKeyInfoCacheTTLForTesting(1)
        defer { ClaudeWebAPIFetcher._resetSessionKeyInfoCacheForTesting() }

        var loaderCalls = 0
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        _ = try ClaudeWebAPIFetcher._extractSessionKeyInfoForTesting(
            installedBrowsers: [.safari],
            now: now,
            sourceLoader: { _ in
                loaderCalls += 1
                return [
                    .init(
                        sourceLabel: "Safari",
                        cookies: [(name: "sessionKey", value: "sk-ant-first")]),
                ]
            })

        let second = try ClaudeWebAPIFetcher._extractSessionKeyInfoForTesting(
            installedBrowsers: [.safari],
            now: now.addingTimeInterval(2),
            sourceLoader: { _ in
                loaderCalls += 1
                return [
                    .init(
                        sourceLabel: "Safari",
                        cookies: [(name: "sessionKey", value: "sk-ant-second")]),
                ]
            })

        #expect(second.key == "sk-ant-second")
        #expect(loaderCalls == 2)
    }

    @Test("Session key scan cache should throttle repeated no-key misses")
    func sessionKeyScanCacheThrottlesRepeatedMisses() {
        ClaudeWebAPIFetcher._resetSessionKeyInfoCacheForTesting()
        ClaudeWebAPIFetcher._setSessionKeyInfoCacheTTLForTesting(30)
        defer { ClaudeWebAPIFetcher._resetSessionKeyInfoCacheForTesting() }

        var loaderCalls = 0
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        self.expectNoSessionKeyFound {
            _ = try ClaudeWebAPIFetcher._extractSessionKeyInfoForTesting(
                installedBrowsers: [.safari],
                now: now,
                sourceLoader: { _ in
                    loaderCalls += 1
                    return [
                        .init(
                            sourceLabel: "Safari",
                            cookies: [(name: "notSessionKey", value: "value")]),
                    ]
                })
        }

        self.expectNoSessionKeyFound {
            _ = try ClaudeWebAPIFetcher._extractSessionKeyInfoForTesting(
                installedBrowsers: [.safari],
                now: now.addingTimeInterval(1),
                sourceLoader: { _ in
                    loaderCalls += 1
                    return [
                        .init(
                            sourceLabel: "Safari",
                            cookies: [(name: "sessionKey", value: "sk-ant-late")]),
                    ]
                })
        }

        #expect(loaderCalls == 1)
    }

    private func expectNoSessionKeyFound(_ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected FetchError.noSessionKeyFound")
        } catch let error as ClaudeWebAPIFetcher.FetchError {
            guard case .noSessionKeyFound = error else {
                Issue.record("Unexpected FetchError: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
