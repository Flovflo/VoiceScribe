import XCTest
@testable import VoiceScribeCore

@MainActor
final class AudioFeatureTests: XCTestCase {
    
    // MARK: - MelSpectrogram Tests
    
    func testMelSpectrogramConfig() {
        let config = MelSpectrogram.Config.qwen3ASR
        
        XCTAssertEqual(config.sampleRate, 16000)
        XCTAssertEqual(config.nMels, 128)
        XCTAssertEqual(config.nFFT, 400)
        XCTAssertEqual(config.hopLength, 160)
    }
    
    func testMelSpectrogramCompute() {
        let melSpec = MelSpectrogram()
        
        // Generate 1 second of 440Hz sine wave at 16kHz
        let sampleRate = 16000
        let frequency: Float = 440.0
        let samples = (0..<sampleRate).map { i -> Float in
            sin(2.0 * .pi * frequency * Float(i) / Float(sampleRate))
        }
        
        let result = melSpec.compute(samples: samples)
        
        // Should have 128 mel bins
        XCTAssertEqual(result.count, 128, "Should have 128 mel bins")
        
        // Should have expected number of frames
        // Centered framing with reflect padding for `compute` path.
        let expectedFrames = 1 + samples.count / 160
        XCTAssertEqual(result[0].count, expectedFrames, "Should have expected frame count")
        
        // Values should be non-negative (power spectrum)
        for melBin in result {
            for value in melBin {
                XCTAssertGreaterThanOrEqual(value, 0, "Power values should be non-negative")
            }
        }
    }
    
    func testLogMelSpectrogram() {
        let melSpec = MelSpectrogram()
        
        // 0.5 seconds of audio
        let samples = [Float](repeating: 0.5, count: 8000)
        let logMel = melSpec.computeLogMel(samples: samples)
        
        XCTAssertEqual(logMel.count, 128, "Should have 128 mel bins")
        XCTAssertFalse(logMel.isEmpty, "Should produce output")
    }
    
    func testEmptyAudioHandling() {
        let melSpec = MelSpectrogram()
        
        let result = melSpec.compute(samples: [])
        XCTAssertTrue(result.isEmpty, "Empty audio should produce empty result")
    }
    
    func testShortAudioHandling() {
        let melSpec = MelSpectrogram()
        
        // Audio shorter than FFT window
        let shortSamples = [Float](repeating: 0.1, count: 100)
        let result = melSpec.compute(samples: shortSamples)

        // Centered framing + reflect padding should still produce valid features.
        XCTAssertEqual(result.count, 128, "Should keep mel bin count for short audio")
        XCTAssertFalse(result[0].isEmpty, "Short audio should still produce at least one frame")
    }
    
    // MARK: - AudioFeatureExtractor Tests
    
    func testFeatureExtractorInitialization() {
        let extractor = AudioFeatureExtractor()
        XCTAssertNotNil(extractor)
    }
    
    func testFeatureExtraction() {
        let extractor = AudioFeatureExtractor(backend: .cpu)
        
        // 1 second at 16kHz
        let samples = [Float](repeating: 0.3, count: 16000)
        let features = extractor.extractFeatures(samples: samples, sampleRate: 16000)
        
        XCTAssertEqual(features.count, 128, "Should have 128 mel bins")
        XCTAssertFalse(features[0].isEmpty, "Should have frames")
    }
    
    func testResamplingFrom48kHz() {
        let extractor = AudioFeatureExtractor(backend: .cpu)
        
        // 1 second at 48kHz (common microphone rate)
        let samples48k = [Float](repeating: 0.2, count: 48000)
        let features = extractor.extractFeatures(samples: samples48k, sampleRate: 48000)
        
        // Should produce output after resampling
        XCTAssertEqual(features.count, 128, "Should have 128 mel bins after resampling")
        XCTAssertFalse(features[0].isEmpty, "Should have frames after resampling")
    }
    
    func testFlatFeatures() {
        let extractor = AudioFeatureExtractor(backend: .cpu)
        
        let samples = [Float](repeating: 0.1, count: 8000) // 0.5s
        let flatFeatures = extractor.extractFlatFeatures(samples: samples, sampleRate: 16000)
        
        let shape = extractor.featureShape(samples: samples, sampleRate: 16000)
        let expectedSize = shape.nMels * shape.nFrames
        
        XCTAssertEqual(flatFeatures.count, expectedSize, "Flat features should match shape")
    }
    
    func testFeatureShape() {
        let extractor = AudioFeatureExtractor(backend: .cpu)
        
        let samples = [Float](repeating: 0.1, count: 16000) // 1 second
        let shape = extractor.featureShape(samples: samples, sampleRate: 16000)
        
        XCTAssertEqual(shape.nMels, 128)
        XCTAssertGreaterThan(shape.nFrames, 0)
    }
    
    // MARK: - Normalization Tests
    
    func testAudioNormalization() {
        let extractor = AudioFeatureExtractor(backend: .cpu)
        
        // Very quiet audio
        let quietSamples = [Float](repeating: 0.001, count: 16000)
        let featuresQuiet = extractor.extractFeatures(samples: quietSamples, sampleRate: 16000)
        
        // Very loud audio
        let loudSamples = [Float](repeating: 0.9, count: 16000)
        let featuresLoud = extractor.extractFeatures(samples: loudSamples, sampleRate: 16000)
        
        // Both should produce valid output (normalization handles different volumes)
        XCTAssertEqual(featuresQuiet.count, featuresLoud.count)
    }
    
    // MARK: - Edge Cases
    
    func testMinimalAudio() {
        let extractor = AudioFeatureExtractor(backend: .cpu)
        
        // With centered framing + reflect padding, then last frame drop: 400 samples -> 2 frames.
        let samples = [Float](repeating: 0.5, count: 400)
        let features = extractor.extractFeatures(samples: samples, sampleRate: 16000)
        
        XCTAssertEqual(features.count, 128)
        XCTAssertEqual(features[0].count, 2, "Should have exactly 2 frames")
    }

    func testChunkingKeepsShortAudioAsSingleChunk() {
        let extractor = AudioFeatureExtractor(backend: .cpu)
        let sampleRate = 16_000
        let samples = [Float](repeating: 0.2, count: sampleRate * 3) // 3s

        let chunks = extractor.splitIntoChunks(
            samples: samples,
            sampleRate: sampleRate,
            chunkDuration: 10.0
        )

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].offsetSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(chunks[0].samples.count, samples.count)
    }

    func testChunkingSplitsLongAudio() {
        let extractor = AudioFeatureExtractor(backend: .cpu)
        let sampleRate = 16_000
        let durationSeconds = 26
        let samples = [Float](repeating: 0.15, count: sampleRate * durationSeconds)

        let chunks = extractor.splitIntoChunks(
            samples: samples,
            sampleRate: sampleRate,
            chunkDuration: 10.0,
            minChunkDuration: 1.0
        )

        XCTAssertGreaterThan(chunks.count, 2, "Long audio should be split into multiple chunks")
        XCTAssertEqual(chunks[0].offsetSeconds, 0, accuracy: 0.001)

        for i in 1..<chunks.count {
            XCTAssertGreaterThan(
                chunks[i].offsetSeconds,
                chunks[i - 1].offsetSeconds,
                "Chunk offsets should be strictly increasing"
            )
        }
    }

    // MARK: - MLX GPU Tests

    func testMLXFeatureExtractionShape() throws {
        try requireMLXFeatureTestPrerequisites()
        let extractor = AudioFeatureExtractor(backend: .mlx)
        let samples = [Float](repeating: 0.3, count: 16000)

        let mlx = extractor.extractFeaturesMLX(samples: samples, sampleRate: 16000)

        XCTAssertEqual(mlx.dim(0), 1, "Batch dimension should be 1")
        XCTAssertEqual(mlx.dim(1), 128, "Should have 128 mel bins")
        XCTAssertGreaterThan(mlx.dim(2), 0, "Should have frames")
    }

    func testMLXvsAccelerateParity() throws {
        try requireMLXFeatureTestPrerequisites()
        let cpuExtractor = AudioFeatureExtractor(backend: .cpu)
        let mlxExtractor = AudioFeatureExtractor(backend: .mlx)

        // Use a deterministic multi-tone signal that better represents speech-like energy
        // than a flat waveform and avoids floor-dominated comparisons.
        let sampleRate: Float = 16_000
        let samples = (0..<16_000).map { i -> Float in
            let t = Float(i) / sampleRate
            let s1 = 0.60 * sin(2 * .pi * 220 * t)
            let s2 = 0.30 * sin(2 * .pi * 440 * t)
            let s3 = 0.10 * sin(2 * .pi * 880 * t)
            return s1 + s2 + s3
        }

        let cpuFeatures = cpuExtractor.extractFeatures(samples: samples, sampleRate: 16000)
        let mlx = mlxExtractor.extractFeaturesMLX(samples: samples, sampleRate: 16000)

        let mlxFlat = mlx.squeezed(axis: 0).asArray(Float.self)
        let cpuFlat = cpuFeatures.flatMap { $0 }
        XCTAssertEqual(cpuFlat.count, mlxFlat.count)

        var diffs = [Float]()
        diffs.reserveCapacity(min(cpuFlat.count, mlxFlat.count))
        for i in 0..<min(cpuFlat.count, mlxFlat.count) {
            diffs.append(abs(cpuFlat[i] - mlxFlat[i]))
        }

        let maxDiff = diffs.max() ?? 0
        let meanDiff = diffs.reduce(0, +) / Float(max(diffs.count, 1))
        let sorted = diffs.sorted()
        let p95Index = min(sorted.count - 1, Int(Float(sorted.count - 1) * 0.95))
        let p95Diff = sorted.isEmpty ? 0 : sorted[p95Index]

        let cosine = cosineSimilarity(cpuFlat, mlxFlat)
        XCTAssertGreaterThan(cosine, 0.97, "Cosine similarity too low: \(cosine)")
        XCTAssertLessThan(meanDiff, 0.2, "Mean diff too high: \(meanDiff)")
        XCTAssertLessThan(p95Diff, 0.6, "P95 diff too high: \(p95Diff)")
        XCTAssertLessThan(maxDiff, 2.0, "Max diff too high: \(maxDiff)")
    }
}

// MARK: - Helpers

private func requireMLXFeatureTestPrerequisites() throws {
    guard ProcessInfo.processInfo.environment["VOICESCRIBE_RUN_MLX_TESTS"] == "1" else {
        throw XCTSkip("Set VOICESCRIBE_RUN_MLX_TESTS=1 to run MLX feature tests.")
    }
    _ = try ensureMLXRuntimeMetallibAvailable()
}

private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    let count = min(a.count, b.count)
    guard count > 0 else { return 0 }

    var dot: Float = 0
    var normA: Float = 0
    var normB: Float = 0
    for i in 0..<count {
        dot += a[i] * b[i]
        normA += a[i] * a[i]
        normB += b[i] * b[i]
    }

    let denom = sqrt(normA * normB)
    guard denom > 1e-8 else { return 0 }
    return dot / denom
}
