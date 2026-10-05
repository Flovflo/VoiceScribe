import Foundation
import XCTest
@testable import VoiceScribeCore

private actor SuspendedDirectoryLoader {
    private var pending: [CheckedContinuation<URL, Never>] = []
    private(set) var calls = 0

    func load() async -> URL {
        calls += 1
        if calls > 2 { return URL(fileURLWithPath: "/nonexistent-voicescribe-regression-model") }
        return await withCheckedContinuation { pending.append($0) }
    }

    func waitForCalls(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while calls < count {
            guard ContinuousClock.now < deadline else { throw ASRError.modelLoadFailed("Timed out waiting for loader call \(count), got \(calls)") }
            await Task.yield()
        }
    }

    func resumeFirst() {
        pending.removeFirst().resume(returning: URL(fileURLWithPath: "/nonexistent-voicescribe-regression-model"))
    }
}

final class ASRLifecycleTests: XCTestCase {
    func testShutdownInvalidatesSuspendedModelLoad() async throws {
        let loader = SuspendedDirectoryLoader()
        let engine = NativeASREngine(config: .qwen3ASR_1_7B_8bit, modelDirectoryLoader: { _, _ in
            await loader.load()
        })
        let loading = Task { try await engine.loadModel() }
        try await loader.waitForCalls(1)
        await engine.shutdown()
        await loader.resumeFirst()
        do {
            try await loading.value
            XCTFail("Shutdown must invalidate the suspended model load")
        } catch {
            XCTAssertTrue(error is CancellationError, "Stale load must stop before reading files or publishing errors: \(error)")
        }
    }

    func testOldLoadDoesNotClearReplacementLoadTask() async throws {
        let loader = SuspendedDirectoryLoader()
        let engine = NativeASREngine(config: .qwen3ASR_1_7B_8bit, modelDirectoryLoader: { _, _ in
            await loader.load()
        })
        let oldLoad = Task { try await engine.loadModel() }
        try await loader.waitForCalls(1)
        await engine.shutdown()
        let replacement = Task { try await engine.loadModel() }
        try await loader.waitForCalls(2)
        await loader.resumeFirst()
        _ = try? await oldLoad.value
        let joiningReplacement = Task { try await engine.loadModel() }
        for _ in 0..<100 { await Task.yield() }
        let calls = await loader.calls
        XCTAssertEqual(calls, 2, "New callers must join the replacement load instead of starting a third download")
        await loader.resumeFirst()
        _ = try? await replacement.value
        _ = try? await joiningReplacement.value
        await engine.shutdown()
    }
}

extension ASRLifecycleTests {
    func testCachedModelDoesNotRequireUnusedGenerationOrChatTemplateFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("models/test/model")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"] {
            try Data([1]).write(to: directory.appendingPathComponent(file))
        }
        XCTAssertEqual(NativeASREngine.cachedModelDirectory("test/model", root: root)?.path, directory.path)
        try Data().write(to: directory.appendingPathComponent("model.safetensors"))
        XCTAssertNil(NativeASREngine.cachedModelDirectory("test/model", root: root), "Empty interrupted weight download must not be treated as cached")
    }
}

extension ASRLifecycleTests {
    func testIncompleteWeightShardSetIsNotCached() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("models/test/model")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in ["config.json", "tokenizer.json", "tokenizer_config.json", "model-00001-of-00002.safetensors"] {
            try Data([1]).write(to: directory.appendingPathComponent(file))
        }
        XCTAssertNil(NativeASREngine.cachedModelDirectory("test/model", root: root))
        try Data([1]).write(to: directory.appendingPathComponent("model-00002-of-00002.safetensors"))
        XCTAssertEqual(NativeASREngine.cachedModelDirectory("test/model", root: root)?.path, directory.path)
    }
}

extension ASRLifecycleTests {
    @MainActor
    func testCancelledModelLoadDoesNotPublishServiceError() async throws {
        let loader = SuspendedDirectoryLoader()
        let engine = NativeASREngine(config: .qwen3ASR_1_7B_8bit, modelDirectoryLoader: { _, _ in await loader.load() })
        let service = NativeASRService(engine: engine)
        let loading = Task { try await service.loadModel() }
        try await loader.waitForCalls(1)
        await engine.shutdown()
        await loader.resumeFirst()
        _ = try? await loading.value
        XCTAssertNil(service.lastError, "Invalidated work must not overwrite UI error state")
    }
}
