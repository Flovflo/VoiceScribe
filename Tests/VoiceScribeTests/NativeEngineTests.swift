import XCTest
import Foundation
@testable import VoiceScribeCore

final class NativeEngineTests: XCTestCase {

    func testModelLoadingAndBasicInference() async throws {
        guard ProcessInfo.processInfo.environment["VOICESCRIBE_RUN_ASR_TESTS"] == "1" else {
            throw XCTSkip("Set VOICESCRIBE_RUN_ASR_TESTS=1 to run ASR integration tests.")
        }

        let engine = NativeASREngine()

        print("🚀 Starting Model Load...")
        try await engine.loadModel()

        // Generate synthetic audio (1 sec sine wave at 16kHz)
        let sampleRate = 16000
        let duration = 1.0
        let samples = (0..<Int(Double(sampleRate) * duration)).map { i -> Float in
            let t = Double(i) / Double(sampleRate)
            return Float(sin(2 * .pi * 440.0 * t))
        }

        print("🎙️ Starting Transcription...")
        let result = try await engine.transcribe(samples: samples, sampleRate: sampleRate)
        XCTAssertNotNil(result as String?)
    }

    func testTranscriptionWithSampleAudio() async throws {
        guard ProcessInfo.processInfo.environment["VOICESCRIBE_RUN_ASR_TESTS"] == "1" else {
            throw XCTSkip("Set VOICESCRIBE_RUN_ASR_TESTS=1 to run ASR integration tests.")
        }

        guard let audioPath = ProcessInfo.processInfo.environment["VOICESCRIBE_TEST_AUDIO"] else {
            throw XCTSkip("Set VOICESCRIBE_TEST_AUDIO to a WAV file to run sample transcription.")
        }

        let engine = NativeASREngine()
        try await engine.loadModel()

        let url = URL(fileURLWithPath: audioPath)
        let text = try await engine.transcribe(from: url)
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testASRBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["VOICESCRIBE_RUN_ASR_BENCH"] == "1" else {
            throw XCTSkip("Set VOICESCRIBE_RUN_ASR_BENCH=1 to run ASR benchmarks.")
        }

        let engine = NativeASREngine()
        try await engine.loadModel()

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
        XCTAssertLessThan(elapsedMs, 500.0)
    }
}
