import XCTest
@testable import VoiceScribeCore

final class ASRGenerationTests: XCTestCase {
    func testInitialEOSProducesNoTextAndNoDecodePass() throws {
        var passes = 0
        let tokens = try Qwen3ASR.decodeTokens(initialToken: 3, stopTokens: [3], maxTokens: 32) { _ in
            passes += 1
            return 1
        }
        XCTAssertTrue(tokens.isEmpty)
        XCTAssertEqual(passes, 0)
    }

    func testShortTranscriptionStopsAtEOSWithoutMinimumLength() throws {
        var passes = 0
        let tokens = try Qwen3ASR.decodeTokens(initialToken: 7, stopTokens: [3], maxTokens: 32) { _ in
            passes += 1
            return 3
        }
        XCTAssertEqual(tokens, [7])
        XCTAssertEqual(passes, 1)
    }

    func testTokenLimitDoesNotComputeDiscardedNextToken() throws {
        var passes = 0
        let tokens = try Qwen3ASR.decodeTokens(initialToken: 7, stopTokens: [3], maxTokens: 1) { _ in
            passes += 1
            return 8
        }
        XCTAssertEqual(tokens, [7])
        XCTAssertEqual(passes, 0)
    }

    func testCancelledGenerationDoesNotExecuteDecode() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try Qwen3ASR.decodeTokens(initialToken: 7, stopTokens: [3], maxTokens: 32) { _ in 3 }
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled generation must throw CancellationError")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
