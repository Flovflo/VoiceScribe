import XCTest
@testable import VoiceScribeCore
import MLX
import MLXNN

@MainActor
final class NativeEngineTests: XCTestCase {
    
    func testModelLoadingAndBasicInference() async throws {
        // 1. Setup Engine
        let engine = NativeASREngine()
        
        // 2. Load Model
        print("🚀 Starting Model Load...")
        await engine.loadModel()
        
        XCTAssertTrue(engine.isReady, "Engine should be ready after loading")
        XCTAssertNil(engine.lastError, "Engine should not have errors")
        
        // 3. Generate Synthetic Audio (1 sec sine wave at 16kHz)
        // 440Hz sine wave
        let sampleRate = 16000
        let duration = 1.0
        let samples = (0..<Int(Double(sampleRate) * duration)).map { i -> Float in
            let t = Double(i) / Double(sampleRate)
            return Float(sin(2 * .pi * 440.0 * t))
        }
        
        // 4. Transcribe
        print("🎙️ Starting Transcription...")
        do {
            let result = try await engine.transcribe(samples: samples, sampleRate: sampleRate)
            print("✅ Evaluation Result: \(result)")
            
            // We don't expect accurate transcription of a sine wave, but we expect it NOT to crash and return consistent string.
            // Qwen3-ASR might output garbage or nothing for sine wave, but the function should complete.
            XCTAssertNotNil(result)
        } catch {
            XCTFail("Transcription failed with error: \(error)")
        }
    }
}
