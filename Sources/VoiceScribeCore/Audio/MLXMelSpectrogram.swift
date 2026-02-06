import Foundation
import MLX

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
    public func computeLogMel(array: MLXArray, minValue: Float = 1e-10) -> MLXArray {
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

        // Log scale
        let clipped = maximum(mel, MLXArray(minValue))
        return log(clipped)
    }

    // MARK: - Static Helpers

    private static func createHannWindow(size: Int) -> [Float] {
        var window = [Float](repeating: 0, count: size)
        let count = Float(size)
        for i in 0..<size {
            window[i] = 0.5 - 0.5 * cos(2.0 * .pi * Float(i) / count)
        }
        return window
    }

    private static func hzToMel(_ hz: Float) -> Float {
        return 2595.0 * log10(1.0 + hz / 700.0)
    }

    private static func melToHz(_ mel: Float) -> Float {
        return 700.0 * (pow(10.0, mel / 2595.0) - 1.0)
    }

    private static func createMelFilterbank(
        nMels: Int,
        nFFT: Int,
        sampleRate: Int,
        fMin: Float,
        fMax: Float
    ) -> [Float] {
        let halfN = nFFT / 2 + 1
        var filterbank = [Float](repeating: 0, count: nMels * halfN)

        let melMin = hzToMel(fMin)
        let melMax = hzToMel(fMax)

        var melPoints = [Float](repeating: 0, count: nMels + 2)
        for i in 0..<(nMels + 2) {
            melPoints[i] = melMin + Float(i) * (melMax - melMin) / Float(nMels + 1)
        }

        let hzPoints = melPoints.map { melToHz($0) }
        let binPoints = hzPoints.map { hz -> Int in
            Int(round(Float(nFFT + 1) * hz / Float(sampleRate)))
        }

        for m in 0..<nMels {
            let left = binPoints[m]
            let center = binPoints[m + 1]
            let right = binPoints[m + 2]

            for k in left..<center {
                if k >= 0 && k < halfN && center > left {
                    filterbank[m * halfN + k] = Float(k - left) / Float(center - left)
                }
            }

            for k in center..<right {
                if k >= 0 && k < halfN && right > center {
                    filterbank[m * halfN + k] = Float(right - k) / Float(right - center)
                }
            }
        }

        return filterbank
    }
}
