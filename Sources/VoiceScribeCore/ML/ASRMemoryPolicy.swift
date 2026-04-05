import Foundation
import MLX

enum ASRMemoryPolicy {
    private static let megabyte = 1_048_576
    private static let defaultCacheFloorMB = 128
    private static let defaultCacheCeilingMB = 512
    private static let fallbackCacheLimitMB = 256
    private static let defaultIdleUnloadSecondsValue: TimeInterval = 180

    static func cacheLimitBytes(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        recommendedWorkingSetBytes: Int? = GPU.maxRecommendedWorkingSetBytes()
    ) -> Int {
        if let override = parseMegabytes(environment["VOICESCRIBE_MLX_CACHE_LIMIT_MB"]) {
            return override * megabyte
        }

        guard let recommendedWorkingSetBytes, recommendedWorkingSetBytes > 0 else {
            return fallbackCacheLimitMB * megabyte
        }

        let derived = recommendedWorkingSetBytes / 32
        let floor = defaultCacheFloorMB * megabyte
        let ceiling = defaultCacheCeilingMB * megabyte
        return min(max(derived, floor), ceiling)
    }

    static func idleUnloadDelaySeconds(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval? {
        guard let rawValue = environment["VOICESCRIBE_IDLE_UNLOAD_SECONDS"] else {
            return defaultIdleUnloadSecondsValue
        }
        guard let seconds = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return defaultIdleUnloadSecondsValue
        }
        guard seconds > 0 else {
            return nil
        }
        return seconds
    }

    private static func parseMegabytes(_ rawValue: String?) -> Int? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= 0 else {
            return nil
        }
        return value
    }
}
