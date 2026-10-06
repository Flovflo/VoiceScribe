import XCTest
import MLX
import MLXNN
@testable import VoiceScribeCore

final class ASRKernelParityTests: XCTestCase {
    override func setUpWithError() throws {
        try ensureMLXRuntimeMetallibAvailable()
    }

    func testAudioEmbeddingMergePreservesAllNonAudioTokens() {
        let base = MLXArray(Array(0..<24).map(Float.init), [1, 6, 4])
        let audio = MLXArray(Array(100..<108).map(Float.init), [1, 2, 4])
        for tokens in [[1, 9, 9, 2, 3, 4], [1, 9, 2, 9, 3, 4], [1, 9, 9, 9, 3, 4], [1, 2, 3, 4, 5, 6]] {
            let actual = Qwen3ASR.mergingAudioEmbeddings(tokenIDs: tokens, baseEmbeddings: base, audioEmbeddings: audio, audioTokenID: 9)
            var expected = Array(0..<24).map(Float.init)
            var index = 0
            for (position, token) in tokens.enumerated() where token == 9 && index < 2 {
                expected.replaceSubrange(position * 4..<position * 4 + 4, with: Array(100 + index * 4..<104 + index * 4).map(Float.init))
                index += 1
            }
            XCTAssertEqual(actual.shape, base.shape)
            XCTAssertEqual(actual.dtype, base.dtype)
            XCTAssertEqual(actual.asArray(Float.self), expected)
        }
    }

    func testFusedFloat32RMSNormMatchesReferenceAcrossInputDtypes() {
        let values = (0..<512).map { Float(sin(Double($0) * 0.31) * 3) }
        let weight = MLXArray((0..<128).map { Float($0 + 1) / 128 })
        for dtype: DType in [.float32, .float16, .bfloat16] {
            let input = MLXArray(values, [1, 2, 2, 128]).asType(dtype)
            let x32 = input.asType(.float32)
            let reference = x32 * rsqrt(mean(square(x32), axis: -1, keepDims: true) + MLXArray(Float(1e-6))) * weight
            let norm = RMSNorm(dimensions: 128, eps: 1e-6)
            norm.update(parameters: ModuleParameters.unflattened(["weight": weight]))
            let fused = applyRMSNorm(input, norm: norm)
            XCTAssertEqual(fused.dtype, .float32)
            XCTAssertLessThanOrEqual(abs(fused - reference).max().item(Float.self), 2e-6)
        }
    }

    func testFusedFloat32RotaryEmbeddingMatchesReferenceAtCachedOffsets() {
        let dimensions = 128
        for length in [1, 31] { for offset in [0, 256, 4096] { for scale: Float in [1, 0.5] {
            let input = MLXArray((0..<(2 * length * dimensions)).map { Float(sin(Double($0) * 0.17)) }, [1, 2, length, dimensions])
            let frequencies = MLXArray((0..<64).map { 1 / pow(Float(1_000_000), Float($0) / 64) })
            let positions = MLXArray(Int32(offset)..<Int32(offset + length)).asType(.float32) * scale
            let angles = positions.expandedDimensions(axis: 1) * frequencies.expandedDimensions(axis: 0)
            let duplicated = concatenated([angles, angles], axis: 1).reshaped(1, 1, length, dimensions)
            let rotated = concatenated([-input[.ellipsis, 64...], input[.ellipsis, ..<64]], axis: -1)
            let reference = input * cos(duplicated) + rotated * sin(duplicated)
            var config = Qwen2Configuration(hiddenSize: dimensions, hiddenLayers: 0, intermediateSize: 256, attentionHeads: 1, rmsNormEps: 1e-6, vocabularySize: 16, kvHeads: 1)
            if scale != 1 { config.ropeScaling = ["type": .string("linear"), "factor": .number(1 / scale)] }
            let fused = Qwen2Attention(config).applyRotaryEmbedding(input, offset: offset)
            XCTAssertEqual(fused.dtype, .float32)
            // RoPE uses exp2(log2(base)) and Metal fast trig; the independent
            // reference uses pow and separate trig operations. Their Float32
            // phase rounding grows with the cached position. Keep the short-
            // sequence bound and allow two epsilon units per scaled position.
            let maxPosition = Float(offset + length - 1) * scale
            let tolerance = max(Float(0.0005), 2 * Float.ulpOfOne * maxPosition)
            XCTAssertLessThanOrEqual(abs(fused - reference).max().item(Float.self), tolerance, "offset=\(offset) length=\(length) scale=\(scale)")
        } } }
    }
}

extension ASRKernelParityTests {
    func testKernelMicrobenchmarks() throws {
        guard ProcessInfo.processInfo.environment["VOICESCRIBE_RUN_KERNEL_BENCH"] == "1" else {
            throw XCTSkip("Set VOICESCRIBE_RUN_KERNEL_BENCH=1 for isolated kernel timings")
        }
        func milliseconds(_ operation: () -> MLXArray) -> Double {
            for _ in 0..<5 { MLX.eval(operation()) }
            let start = ContinuousClock.now
            for _ in 0..<100 { MLX.eval(operation()) }
            let duration = ContinuousClock.now - start
            return (Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15) / 100
        }
        let input = MLXArray((0..<(600 * 2048)).map { Float($0 % 41) / 41 }, [1, 600, 2048])
        let norm = RMSNorm(dimensions: 2048, eps: 1e-6)
        MLX.eval(input, norm.weight)
        let referenceMS = milliseconds {
            input * rsqrt(mean(square(input), axis: -1, keepDims: true) + MLXArray(Float(1e-6))) * norm.weight
        }
        let fusedMS = milliseconds { applyRMSNorm(input, norm: norm) }
        print("[ASRKernelBench] RMSNorm shape=\(input.shape) reference_ms=\(referenceMS) fused_ms=\(fusedMS) ratio=\(referenceMS / fusedMS)")
        let base = MLXArray.zeros([1, 320, 2048])
        let audio = MLXArray.ones([1, 300, 2048])
        let tokens = Array(repeating: 1, count: 10) + Array(repeating: 9, count: 300) + Array(repeating: 1, count: 10)
        MLX.eval(base, audio)
        let scatterMS = milliseconds {
            let flat = base.reshaped(320, 2048)
            for i in 0..<300 { flat[10 + i, 0...] = audio[0, i, 0...] }
            return flat.reshaped(1, 320, 2048)
        }
        let concatMS = milliseconds {
            Qwen3ASR.mergingAudioEmbeddings(tokenIDs: tokens, baseEmbeddings: base, audioEmbeddings: audio, audioTokenID: 9)
        }
        print("[ASRKernelBench] AudioMerge pads=300 scatter_ms=\(scatterMS) concat_ms=\(concatMS) ratio=\(scatterMS / concatMS)")
    }
}
