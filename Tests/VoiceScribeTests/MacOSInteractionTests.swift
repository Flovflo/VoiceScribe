import XCTest
import Foundation
import Combine
@testable import VoiceScribeCore

final class MacOSInteractionTests: XCTestCase {
    @MainActor
    func testAppStateIsReleasedAfterItsOwnerReleasesIt() {
        weak var releasedState: AppState?
        do {
            let state = AppState()
            releasedState = state
        }
        XCTAssertNil(releasedState, "Publisher bindings must not retain their owner")
    }

    @MainActor
    func testShutdownPreventsCancelledInitializationFromPublishingAnError() async throws {
        let suspended = InitializationDirectoryGate()
        let native = NativeASREngine(config: .qwen3ASR_1_7B_8bit, modelDirectoryLoader: { _, _ in
            await suspended.directory()
        })
        let state = AppState(engine: NativeASRService(engine: native))
        var statuses: [String] = []
        let observation = state.$status.sink { statuses.append($0) }
        defer { observation.cancel() }
        let initializing = Task { await state.initialize() }
        for _ in 0..<1000 {
            if await suspended.isWaiting { break }
            await Task.yield()
        }
        guard await suspended.isWaiting else {
            initializing.cancel()
            XCTFail("Initialization did not reach the model loader")
            return
        }
        state.shutdown()
        await native.shutdown()
        await suspended.resume()
        await initializing.value
        // Drain Combine's queued shutdown events before evaluating the UI state.
        await Task.yield()
        XCTAssertNil(state.errorMessage)
        XCTAssertNotEqual(state.status, "Model Error")
        XCTAssertFalse(statuses.contains("Model Error"), "Cancelled startup must not flash an error after shutdown")
    }
}

private actor InitializationDirectoryGate {
    private var continuation: CheckedContinuation<URL, Never>?
    var isWaiting: Bool { continuation != nil }

    func directory() async -> URL {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume(returning: URL(fileURLWithPath: "/missing-cancelled-model"))
        continuation = nil
    }
}
