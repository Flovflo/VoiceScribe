import XCTest
@testable import VoiceScribeCore

final class ASRMemoryPolicyTests: XCTestCase {
    func testCacheLimitUsesEnvironmentOverride() {
        let bytes = ASRMemoryPolicy.cacheLimitBytes(
            environment: ["VOICESCRIBE_MLX_CACHE_LIMIT_MB": "64"],
            recommendedWorkingSetBytes: 8 * 1_048_576 * 1_024
        )

        XCTAssertEqual(bytes, 64 * 1_048_576)
    }

    func testCacheLimitClampsLargeWorkingSet() {
        let bytes = ASRMemoryPolicy.cacheLimitBytes(
            environment: [:],
            recommendedWorkingSetBytes: 64 * 1_048_576 * 1_024
        )

        XCTAssertEqual(bytes, 512 * 1_048_576)
    }

    func testCacheLimitClampsSmallWorkingSet() {
        let bytes = ASRMemoryPolicy.cacheLimitBytes(
            environment: [:],
            recommendedWorkingSetBytes: 2 * 1_048_576 * 1_024
        )

        XCTAssertEqual(bytes, 128 * 1_048_576)
    }

    func testInvalidCacheOverrideFallsBackToDerivedValue() {
        let bytes = ASRMemoryPolicy.cacheLimitBytes(
            environment: ["VOICESCRIBE_MLX_CACHE_LIMIT_MB": "oops"],
            recommendedWorkingSetBytes: 16 * 1_048_576 * 1_024
        )

        XCTAssertEqual(bytes, 512 * 1_048_576)
    }

    func testIdleUnloadDelayDefaultsToDisabled() {
        XCTAssertNil(ASRMemoryPolicy.idleUnloadDelaySeconds(environment: [:]))
    }

    func testIdleUnloadDelayCanBeDisabled() {
        XCTAssertNil(
            ASRMemoryPolicy.idleUnloadDelaySeconds(
                environment: ["VOICESCRIBE_IDLE_UNLOAD_SECONDS": "0"]
            )
        )
    }

    func testIdleUnloadDelayUsesEnvironmentOverride() {
        XCTAssertEqual(
            ASRMemoryPolicy.idleUnloadDelaySeconds(
                environment: ["VOICESCRIBE_IDLE_UNLOAD_SECONDS": "45"]
            ),
            45
        )
    }

    func testInvalidIdleUnloadDelayFallsBackToDisabled() {
        XCTAssertNil(
            ASRMemoryPolicy.idleUnloadDelaySeconds(
                environment: ["VOICESCRIBE_IDLE_UNLOAD_SECONDS": "oops"]
            )
        )
    }
}
