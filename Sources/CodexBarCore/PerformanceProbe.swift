import Foundation

/// Lightweight, opt-in perf probe.
/// Enable with `CODEXBAR_PROFILE_PERF=1`.
public enum PerformanceProbe {
    public struct Token: Sendable {
        let name: String
        let startedAtNs: UInt64
        let metadata: [String: String]
    }

    private static let logger = CodexBarLog.logger(LogCategories.performance)

    public static let isEnabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        let raw = (env["CODEXBAR_PROFILE_PERF"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }()

    public static func begin(_ name: String, metadata: [String: String] = [:]) -> Token? {
        guard self.isEnabled else { return nil }
        return Token(name: name, startedAtNs: DispatchTime.now().uptimeNanoseconds, metadata: metadata)
    }

    public static func end(_ token: Token?, metadata: [String: String] = [:]) {
        guard let token else { return }
        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - token.startedAtNs) / 1_000_000.0
        var merged = token.metadata
        for (key, value) in metadata {
            merged[key] = value
        }
        merged["event"] = "duration"
        merged["name"] = token.name
        merged["duration_ms"] = String(format: "%.3f", durationMs)
        self.logger.info("{\"event\":\"duration\"}", metadata: merged)
    }

    public static func count(_ name: String, by delta: Int64 = 1, metadata: [String: String] = [:]) {
        guard self.isEnabled else { return }
        var merged = metadata
        merged["event"] = "counter"
        merged["name"] = name
        merged["delta"] = "\(delta)"
        self.logger.info("{\"event\":\"counter\"}", metadata: merged)
    }
}
