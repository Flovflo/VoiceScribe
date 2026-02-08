import Foundation
import MLX
import Accelerate

/// GPU-accelerated mel spectrogram using MLX.
/// Computes log-mel features compatible with Qwen3-ASR.
public final class MLXMelSpectrogram {
    public let config: MelSpectrogram.Config
    private let melFilterbank: MLXArray
    private let window: MLXArray

    public init(config: MelSpectrogram.Config = .qwen3ASR) {
        self.config = config

        let window = Self.createHannWindow(size: config.nFFT)
        self.window = MLXArray(window)

        let halfN = config.nFFT / 2 + 1
        let filterbank = Self.createMelFilterbank(
            nMels: config.nMels,
            nFFT: config.nFFT,
            sampleRate: config.sampleRate,
            fMin: config.fMin,
            fMax: config.fMax ?? Float(config.sampleRate) / 2.0
        )
        self.melFilterbank = MLXArray(filterbank, [config.nMels, halfN])
    }

    /// Compute log mel spectrogram on GPU.
    /// - Returns: [nFrames, nMels]
    public func computeLogMel(samples: [Float], minValue: Float = 1e-10) -> MLXArray {
        let paddedSamples = Self.reflectPad(samples, pad: config.nFFT / 2)
        return computeLogMelFromPaddedArray(array: MLXArray(paddedSamples), minValue: minValue)
    }

    private func computeLogMelFromPaddedArray(array: MLXArray, minValue: Float = 1e-10) -> MLXArray {
        let nFFT = config.nFFT
        let hop = config.hopLength
        let sampleCount = array.shape.first ?? 0

        guard sampleCount >= nFFT else {
            return MLXArray.zeros([0, config.nMels])
        }

        let nFrames = 1 + (sampleCount - nFFT) / hop
        guard nFrames > 0 else {
            return MLXArray.zeros([0, config.nMels])
        }

        // Frame via asStrided: [nFrames, nFFT]
        let frames = asStrided(array, [nFrames, nFFT], strides: [hop, 1])

        // Apply Hann window
        let windowed = frames * window

        // FFT -> power spectrum
        let fft = MLXFFT.rfft(windowed, n: nFFT, axis: 1)
        let real = fft.realPart()
        let imag = fft.imaginaryPart()
        let power = real * real + imag * imag

        // Mel filterbank: [nFrames, nMels]
        let mel = matmul(power, melFilterbank.transposed())

        // Whisper-style log10 compression with dynamic range clipping.
        let clipped = maximum(mel, MLXArray(minValue))
        let log10Mel = log(clipped) / MLXArray(log(10.0) as Float)
        let maxValue = MLX.max(log10Mel)
        let floorValue = maxValue - MLXArray(8.0 as Float)
        let clippedLog = maximum(log10Mel, floorValue)
        let normalized = (clippedLog + MLXArray(4.0 as Float)) / MLXArray(4.0 as Float)
        // Match Hugging Face WhisperFeatureExtractor behavior: drop the last frame.
        let frameCount = normalized.dim(0)
        if frameCount > 1 {
            return normalized[..<(frameCount - 1), 0...]
        }
        return normalized
    }

    // MARK: - Static Helpers

    private static func createHannWindow(size: Int) -> [Float] {
        guard size > 0 else { return [] }
        let twoPi = 2.0 * Float.pi
        var window = [Float](repeating: 0, count: size)
        // Match transformers.audio_utils.window_function("hann", periodic=True)
        for n in 0..<size {
            window[n] = 0.5 - 0.5 * cos(twoPi * Float(n) / Float(size))
        }
        return window
    }

    private static func hzToMel(_ hz: Float) -> Float {
        let fSp: Float = 200.0 / 3.0
        let minLogHz: Float = 1000.0
        let minLogMel: Float = minLogHz / fSp
        let logStep: Float = log(6.4) / 27.0
        if hz < minLogHz {
            return hz / fSp
        }
        return minLogMel + log(hz / minLogHz) / logStep
    }

    private static func melToHz(_ mel: Float) -> Float {
        let fSp: Float = 200.0 / 3.0
        let minLogHz: Float = 1000.0
        let minLogMel: Float = minLogHz / fSp
        let logStep: Float = log(6.4) / 27.0
        if mel < minLogMel {
            return mel * fSp
        }
        return minLogHz * exp(logStep * (mel - minLogMel))
    }

    private static func createMelFilterbank(
        nMels: Int,
        nFFT: Int,
        sampleRate: Int,
        fMin: Float,
        fMax: Float
    ) -> [Float] {
        let halfN = nFFT / 2 + 1
        guard nMels > 0, halfN > 0 else { return [] }

        let melMin = hzToMel(fMin)
        let melMax = hzToMel(fMax)

        var melPoints = [Float](repeating: 0, count: nMels + 2)
        for i in 0..<(nMels + 2) {
            melPoints[i] = melMin + (Float(i) / Float(nMels + 1)) * (melMax - melMin)
        }
        let hzPoints = melPoints.map(melToHz)

        var fftFreqs = [Float](repeating: 0, count: halfN)
        for i in 0..<halfN {
            fftFreqs[i] = Float(i) * Float(sampleRate) / Float(nFFT)
        }

        var filterbank = [Float](repeating: 0, count: nMels * halfN)
        for m in 0..<nMels {
            let fLeft = hzPoints[m]
            let fCenter = hzPoints[m + 1]
            let fRight = hzPoints[m + 2]

            let denomLeft = max(fCenter - fLeft, 1e-10)
            let denomRight = max(fRight - fCenter, 1e-10)
            let enorm = 2.0 / max(fRight - fLeft, 1e-10)

            for k in 0..<halfN {
                let freq = fftFreqs[k]
                let up = (freq - fLeft) / denomLeft
                let down = (fRight - freq) / denomRight
                let tri = max(0.0, min(up, down))
                filterbank[m * halfN + k] = tri * enorm
            }
        }

        return filterbank
    }

    private static func reflectPad(_ samples: [Float], pad: Int) -> [Float] {
        guard pad > 0, !samples.isEmpty else { return samples }
        if samples.count == 1 {
            return [Float](repeating: samples[0], count: pad) + samples + [Float](repeating: samples[0], count: pad)
        }

        let last = samples.count - 1
        var prefix = [Float](repeating: 0, count: pad)
        var suffix = [Float](repeating: 0, count: pad)

        for i in 0..<pad {
            let leftIndex = min(pad - i, last)
            prefix[i] = samples[leftIndex]

            let rightIndex = max(last - 1 - i, 0)
            suffix[i] = samples[rightIndex]
        }

        return prefix + samples + suffix
    }
}
