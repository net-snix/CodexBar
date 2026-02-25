import Foundation
import Testing
@testable import CodexBar

@Suite
struct UsageStoreRefreshCadenceTests {
    @Test
    func cadenceBoundaryDelayRoundsUpToNextBucket() {
        let now = Date(timeIntervalSince1970: 1234)
        let delay = UsageStore.secondsUntilNextCadenceBoundary(now: now, cadenceSeconds: 300)
        #expect(abs(delay - 266) < 0.001)
    }

    @Test
    func cadenceBoundaryDelayOnBoundaryUsesFullCadence() {
        let now = Date(timeIntervalSince1970: 1200)
        let delay = UsageStore.secondsUntilNextCadenceBoundary(now: now, cadenceSeconds: 300)
        #expect(abs(delay - 300) < 0.001)
    }

    @Test
    func tokenRefreshIntervalFollowsSelectedCadence() {
        let fiveMinutes = UsageStore.tokenRefreshIntervalSeconds(
            for: .fiveMinutes,
            fallbackSeconds: 3600)
        #expect(fiveMinutes == 300)

        let manual = UsageStore.tokenRefreshIntervalSeconds(
            for: .manual,
            fallbackSeconds: 3600)
        #expect(manual == 3600)
    }
}
