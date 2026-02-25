import Foundation

extension UsageStore {
    nonisolated static func secondsUntilNextCadenceBoundary(
        now: Date = Date(),
        cadenceSeconds: TimeInterval) -> TimeInterval
    {
        let cadence = max(1, cadenceSeconds)
        let remainder = now.timeIntervalSince1970.truncatingRemainder(dividingBy: cadence)
        if abs(remainder) < 0.001 {
            return cadence
        }
        return max(0.001, cadence - remainder)
    }

    nonisolated static func tokenRefreshIntervalSeconds(
        for refreshFrequency: RefreshFrequency,
        fallbackSeconds: TimeInterval) -> TimeInterval
    {
        if let cadence = refreshFrequency.seconds {
            return max(60, cadence)
        }
        return fallbackSeconds
    }
}
