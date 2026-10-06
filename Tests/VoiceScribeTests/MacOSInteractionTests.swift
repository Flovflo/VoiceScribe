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

    @MainActor
    func testStopRequestedDuringStartupAllowsTheNextRecording() async throws {
        let gate = RecordingStartupGate()
        let native = NativeASREngine(config: .init(modelName: "unsupported-test-model"))
        let state = AppState(engine: NativeASRService(engine: native), recordingStarter: {
            await gate.start()
        })
        defer {
            state.shutdown()
            Task { await gate.resumeAll() }
        }
        state.toggleRecording()
        try await gate.waitForStarts(1)
        XCTAssertTrue(state.isStartingRecording)
        state.toggleRecording()
        await gate.resumeAll()
        for _ in 0..<500 {
            if !state.isStartingRecording { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(state.isStartingRecording, "Finishing startup must clear its flag before changing interaction epoch")
        XCTAssertFalse(state.isRecording, "A stop requested during startup must be honored")
        state.toggleRecording()
        try await gate.waitForStarts(2)
        let starts = await gate.startCount
        XCTAssertEqual(starts, 2)
    }
}

private actor RecordingStartupGate {
    private(set) var startCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func start() async {
        startCount += 1
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitForStarts(_ count: Int) async throws {
        for _ in 0..<500 {
            if startCount >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw RecordingStartupTimeout()
    }

    func resumeAll() {
        let pending = continuations
        continuations = []
        pending.forEach { $0.resume() }
    }
}

private struct RecordingStartupTimeout: Error {}

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
