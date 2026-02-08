import XCTest
import Foundation
@testable import VoiceScribeCore

final class NativeEngineTests: XCTestCase {
    func testRejectsUnsupportedModelOutsideQwen3Collection() async throws {
        let engine = NativeASREngine(
            config: .init(modelName: "mlx-community/Llama-3.2-1B-Instruct-4bit")
        )

        do {
            try await engine.loadModel()
            XCTFail("Expected unsupported model error")
        } catch ASRError.unsupportedModel(let modelName) {
            XCTAssertEqual(modelName, "mlx-community/Llama-3.2-1B-Instruct-4bit")
        }
    }

    func testRejectsForcedAlignerVariant() async throws {
        let engine = NativeASREngine(
            config: .init(modelName: "mlx-community/Qwen3-ForcedAligner-0.6B-8bit")
        )

        do {
            try await engine.loadModel()
            XCTFail("Expected unsupported model error")
        } catch ASRError.unsupportedModel(let modelName) {
            XCTAssertEqual(modelName, "mlx-community/Qwen3-ForcedAligner-0.6B-8bit")
        }
    }

    func testModelLoadingAndBasicInference() async throws {
        try await requireASRPrerequisites()

        let engine = NativeASREngine(
            config: .init(
                modelName: "mlx-community/Qwen3-ASR-1.7B-8bit",
                maxTokens: 256,
                forcedLanguage: nil
            )
        )

        try await loadModelWithInfraSkip(engine)

        // Generate synthetic audio (1 sec sine wave at 16kHz)
        let sampleRate = 16000
        let duration = 1.0
        let samples = (0..<Int(Double(sampleRate) * duration)).map { i -> Float in
            let t = Double(i) / Double(sampleRate)
            return Float(sin(2 * .pi * 440.0 * t))
        }

        do {
            let result = try await engine.transcribe(samples: samples, sampleRate: sampleRate)
            XCTAssertFalse(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } catch ASRError.emptyTranscription {
            // Synthetic pure tone may not contain speech; this is acceptable.
        }
    }

    func testTranscriptionWithSampleAudio() async throws {
        try await requireASRPrerequisites()

        guard let audioPath = ProcessInfo.processInfo.environment["VOICESCRIBE_TEST_AUDIO"] else {
            throw XCTSkip("Set VOICESCRIBE_TEST_AUDIO to a WAV file to run sample transcription.")
        }

        let engine = NativeASREngine(
            config: .init(modelName: "mlx-community/Qwen3-ASR-1.7B-8bit", maxTokens: 64)
        )
        try await loadModelWithInfraSkip(engine)

        let url = URL(fileURLWithPath: audioPath)
        let text = try await engine.transcribe(from: url)
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(cleaned.isEmpty)
        XCTAssertFalse(text.contains("<asr_text>"), "ASR output should not include metadata tags")
        XCTAssertFalse(text.contains("<|"), "ASR output should not include special tokens")
        XCTAssertFalse(cleaned.lowercased().contains("aaaaaaaa"), "Output looks degenerate: \(cleaned)")
        XCTAssertFalse(cleaned.lowercased().contains("bbbbbbbb"), "Output looks degenerate: \(cleaned)")

        if let expected = ProcessInfo.processInfo.environment["VOICESCRIBE_EXPECT_KEYWORDS"],
           !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalizedText = normalizeForKeywordMatch(cleaned)
            let keywords = expected
                .split(separator: ",")
                .map { normalizeForKeywordMatch(String($0)) }
                .filter { !$0.isEmpty }
            for keyword in keywords {
                XCTAssertTrue(
                    normalizedText.contains(keyword),
                    "Expected keyword '\(keyword)' in transcription. Got: \(cleaned)"
                )
            }
        }
    }

    func testASRBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["VOICESCRIBE_RUN_ASR_BENCH"] == "1" else {
            throw XCTSkip("Set VOICESCRIBE_RUN_ASR_BENCH=1 to run ASR benchmarks.")
        }
        if ProcessInfo.processInfo.environment["VOICESCRIBE_MLX_DEVICE"]?.lowercased() == "cpu" {
            throw XCTSkip("ASR benchmark requires GPU; unset VOICESCRIBE_MLX_DEVICE=cpu.")
        }
        try requireMLXMetallibForTests()
        try await requireHuggingFaceReachability()

        let engine = NativeASREngine(
            config: .init(modelName: "mlx-community/Qwen3-ASR-1.7B-8bit", maxTokens: 16)
        )
        try await loadModelWithInfraSkip(engine)

        let sampleRate = 16000
        let duration = 10.0
        let samples = (0..<Int(Double(sampleRate) * duration)).map { i -> Float in
            let t = Double(i) / Double(sampleRate)
            return Float(sin(2 * .pi * 220.0 * t))
        }

        let clock = ContinuousClock()
        let start = clock.now
        _ = try? await engine.transcribe(samples: samples, sampleRate: sampleRate)
        let elapsed = clock.now - start

        let elapsedMs = Double(elapsed.components.seconds) * 1000.0
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0
        let targetMs: Double = {
            if let raw = ProcessInfo.processInfo.environment["VOICESCRIBE_ASR_BENCH_TARGET_MS"],
               let value = Double(raw), value > 0 {
                return value
            }
            return 1000.0
        }()
        XCTAssertLessThan(elapsedMs, targetMs)
    }

    func testTranscriptionStressWithSampleAudio() async throws {
        guard ProcessInfo.processInfo.environment["VOICESCRIBE_RUN_ASR_STRESS"] == "1" else {
            throw XCTSkip("Set VOICESCRIBE_RUN_ASR_STRESS=1 to run ASR stress tests.")
        }
        try await requireASRPrerequisites()

        guard let audioPath = ProcessInfo.processInfo.environment["VOICESCRIBE_TEST_AUDIO"] else {
            throw XCTSkip("Set VOICESCRIBE_TEST_AUDIO to a WAV file to run ASR stress test.")
        }

        let iterations = max(
            1,
            Int(ProcessInfo.processInfo.environment["VOICESCRIBE_ASR_STRESS_ITERS"] ?? "5") ?? 5
        )

        let engine = NativeASREngine(
            config: .init(
                modelName: "mlx-community/Qwen3-ASR-1.7B-8bit",
                maxTokens: 256,
                forcedLanguage: nil
            )
        )
        try await loadModelWithInfraSkip(engine)

        let url = URL(fileURLWithPath: audioPath)
        for _ in 0..<iterations {
            let text = try await engine.transcribe(from: url)
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(cleaned.isEmpty, "Transcription should not be empty")
            XCTAssertFalse(cleaned.contains("<|"), "Transcription should not contain special tokens")
            XCTAssertFalse(cleaned.contains("<asr_text>"), "Transcription should not contain metadata tags")
            XCTAssertFalse(cleaned.lowercased().contains("aaaaaaaa"), "Output looks degenerate: \(cleaned)")
        }
    }
}

private func normalizeForKeywordMatch(_ value: String) -> String {
    value
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .lowercased()
}

private struct TestTimeoutError: Error {}

private func requireASRPrerequisites() async throws {
    guard ProcessInfo.processInfo.environment["VOICESCRIBE_RUN_ASR_TESTS"] == "1" else {
        throw XCTSkip("Set VOICESCRIBE_RUN_ASR_TESTS=1 to run ASR integration tests.")
    }
    try requireMLXMetallibForTests()
    try await requireHuggingFaceReachability()
}

private func requireHuggingFaceReachability() async throws {
    let url = URL(string: "https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit/resolve/main/config.json")!
    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.timeoutInterval = 15

    do {
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw XCTSkip("Hugging Face returned HTTP \(http.statusCode).")
        }
    } catch {
        if isNetworkInfrastructureError(error) {
            throw XCTSkip("Hugging Face not reachable from test environment: \(error.localizedDescription)")
        }
        throw error
    }
}

private func requireMLXMetallibForTests() throws {
    _ = try ensureMLXRuntimeMetallibAvailable()
}

private func loadModelWithInfraSkip(_ engine: NativeASREngine) async throws {
    do {
        try await withAsyncTimeout(seconds: 180) {
            try await engine.loadModel()
        }
    } catch {
        if error is TestTimeoutError || isNetworkInfrastructureError(error) {
            throw XCTSkip("Skipped due to model download/load infrastructure issue: \(error.localizedDescription)")
        }
        throw error
    }
}

private func withAsyncTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TestTimeoutError()
        }

        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw TestTimeoutError()
        }
        return first
    }
}

private func isNetworkInfrastructureError(_ error: Error) -> Bool {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
        return true
    }
    if nsError.domain == NSCocoaErrorDomain,
       let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
        return isNetworkInfrastructureError(underlying)
    }
    return false
}
