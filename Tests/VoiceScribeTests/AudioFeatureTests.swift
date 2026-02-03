import XCTest
@testable import VoiceScribeCore

@MainActor
final class AudioFeatureTests: XCTestCase {
    
    // MARK: - MelSpectrogram Tests
    
    func testMelSpectrogramConfig() {
        let config = MelSpectrogram.Config.qwen3ASR
        
        XCTAssertEqual(config.sampleRate, 16000)
        XCTAssertEqual(config.nMels, 128)
        XCTAssertEqual(config.nFFT, 512)
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
        // nFrames = 1 + (samples - nFFT) / hopLength = 1 + (16000 - 512) / 160 = 97
        let expectedFrames = 1 + (samples.count - 512) / 160
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
        
        XCTAssertTrue(result.isEmpty, "Audio shorter than window should produce empty result")
    }
    
    // MARK: - AudioFeatureExtractor Tests
    
    func testFeatureExtractorInitialization() {
        let extractor = AudioFeatureExtractor()
        XCTAssertNotNil(extractor)
    }
    
    func testFeatureExtraction() {
        let extractor = AudioFeatureExtractor()
        
        // 1 second at 16kHz
        let samples = [Float](repeating: 0.3, count: 16000)
        let features = extractor.extractFeatures(samples: samples, sampleRate: 16000)
        
        XCTAssertEqual(features.count, 128, "Should have 128 mel bins")
        XCTAssertFalse(features[0].isEmpty, "Should have frames")
    }
    
    func testResamplingFrom48kHz() {
        let extractor = AudioFeatureExtractor()
        
        // 1 second at 48kHz (common microphone rate)
        let samples48k = [Float](repeating: 0.2, count: 48000)
        let features = extractor.extractFeatures(samples: samples48k, sampleRate: 48000)
        
        // Should produce output after resampling
        XCTAssertEqual(features.count, 128, "Should have 128 mel bins after resampling")
        XCTAssertFalse(features[0].isEmpty, "Should have frames after resampling")
    }
    
    func testFlatFeatures() {
        let extractor = AudioFeatureExtractor()
        
        let samples = [Float](repeating: 0.1, count: 8000) // 0.5s
        let flatFeatures = extractor.extractFlatFeatures(samples: samples, sampleRate: 16000)
        
        let shape = extractor.featureShape(samples: samples, sampleRate: 16000)
        let expectedSize = shape.nMels * shape.nFrames
        
        XCTAssertEqual(flatFeatures.count, expectedSize, "Flat features should match shape")
    }
    
    func testFeatureShape() {
        let extractor = AudioFeatureExtractor()
        
        let samples = [Float](repeating: 0.1, count: 16000) // 1 second
        let shape = extractor.featureShape(samples: samples, sampleRate: 16000)
        
        XCTAssertEqual(shape.nMels, 128)
        XCTAssertGreaterThan(shape.nFrames, 0)
    }
    
    // MARK: - Normalization Tests
    
    func testAudioNormalization() {
        let extractor = AudioFeatureExtractor()
        
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
        let extractor = AudioFeatureExtractor()
        
        // Just barely enough for one frame (nFFT = 400)
        let samples = [Float](repeating: 0.5, count: 400)
        let features = extractor.extractFeatures(samples: samples, sampleRate: 16000)
        
        XCTAssertEqual(features.count, 128)
        XCTAssertEqual(features[0].count, 1, "Should have exactly 1 frame")
    }
}
