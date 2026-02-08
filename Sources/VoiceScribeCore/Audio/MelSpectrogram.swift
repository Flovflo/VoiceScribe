import Foundation
import Accelerate

/// Computes Mel Spectrogram features from raw audio samples.
/// Matches the output of `librosa.feature.melspectrogram` used by Qwen3-ASR.
public final class MelSpectrogram {
    
    // MARK: - Configuration
    
    public struct Config: Sendable {
        public let sampleRate: Int
        public let nFFT: Int
        public let hopLength: Int
        public let nMels: Int
        public let fMin: Float
        public let fMax: Float?
        
        /// Default config matching Qwen3-ASR: 128-dim Fbank at 16kHz
        public static let qwen3ASR = Config(
            sampleRate: 16000,
            nFFT: 400,      // Match Qwen3-ASR preprocessor_config.json
            hopLength: 160, // 10ms hop at 16kHz
            nMels: 128,
            fMin: 0,
            fMax: 8000
        )
        
        public init(
            sampleRate: Int = 16000,
            nFFT: Int = 512,
            hopLength: Int = 160,
            nMels: Int = 128,
            fMin: Float = 0,
            fMax: Float? = nil
        ) {
            self.sampleRate = sampleRate
            self.nFFT = nFFT
            self.hopLength = hopLength
            self.nMels = nMels
            self.fMin = fMin
            self.fMax = fMax ?? Float(sampleRate) / 2.0
        }
    }
    
    // MARK: - Properties
    
    private let config: Config
    private let melFilterbank: [Float]
    private let fftSetup: FFTSetup
    private let window: [Float]
    private let log2n: vDSP_Length
    
    // MARK: - Initialization
    
    public init(config: Config = .qwen3ASR) {
        self.config = config
        
        // Compute log2(nFFT) for FFT setup
        self.log2n = vDSP_Length(log2(Double(config.nFFT)))
        
        // Create Hann window
        self.window = Self.createHannWindow(size: config.nFFT)
        
        // Create mel filterbank matrix
        self.melFilterbank = Self.createMelFilterbank(
            nMels: config.nMels,
            nFFT: config.nFFT,
            sampleRate: config.sampleRate,
            fMin: config.fMin,
            fMax: config.fMax ?? Float(config.sampleRate) / 2.0
        )
        
        // Setup FFT - use power of 2 for vDSP_fft
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Failed to create FFT setup for size \(config.nFFT)")
        }
        self.fftSetup = setup
    }
    
    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }
    
    // MARK: - Public API
    
    /// Compute mel spectrogram from raw audio samples.
    /// - Parameter samples: Audio samples at configured sample rate
    /// - Returns: Mel spectrogram with shape [nMels, nFrames]
    public func compute(samples: [Float]) -> [[Float]] {
        let paddedSamples = Self.reflectPad(samples, pad: config.nFFT / 2)
        let nFrames = 1 + (paddedSamples.count - config.nFFT) / config.hopLength
        guard nFrames > 0 else { return [] }
        
        var melSpec = [[Float]](repeating: [Float](repeating: 0, count: nFrames), count: config.nMels)
        
        // Process each frame
        for frameIdx in 0..<nFrames {
            let start = frameIdx * config.hopLength
            let frame = Array(paddedSamples[start..<min(start + config.nFFT, paddedSamples.count)])
            
            // Pad if needed
            var paddedFrame = frame
            if paddedFrame.count < config.nFFT {
                paddedFrame.append(contentsOf: [Float](repeating: 0, count: config.nFFT - paddedFrame.count))
            }
            
            // Apply window
            var windowedFrame = [Float](repeating: 0, count: config.nFFT)
            vDSP_vmul(paddedFrame, 1, window, 1, &windowedFrame, 1, vDSP_Length(config.nFFT))
            
            // Compute FFT magnitude
            let powerSpectrum = computePowerSpectrum(frame: windowedFrame)
            
            // Apply mel filterbank
            let melEnergies = applyMelFilterbank(powerSpectrum: powerSpectrum)
            
            // Store in output
            for melIdx in 0..<config.nMels {
                melSpec[melIdx][frameIdx] = melEnergies[melIdx]
            }
        }
        
        return melSpec
    }
    
    /// Compute log mel spectrogram (more commonly used for ASR)
    public func computeLogMel(samples: [Float], minValue: Float = 1e-10) -> [[Float]] {
        var melSpec = compute(samples: samples)
        guard !melSpec.isEmpty else { return melSpec }

        // Match Hugging Face WhisperFeatureExtractor behavior: drop last frame.
        let frameCount = melSpec[0].count
        if frameCount > 1 {
            for i in 0..<melSpec.count {
                melSpec[i].removeLast()
            }
        }

        // Whisper-style log10 compression with dynamic range clipping.
        // This matches the feature extractor family used by Qwen3-ASR.
        var globalMax: Float = -.greatestFiniteMagnitude
        for i in 0..<melSpec.count {
            for j in 0..<melSpec[i].count {
                let value = max(melSpec[i][j], minValue)
                let log10Value = log10(value)
                melSpec[i][j] = log10Value
                if log10Value > globalMax {
                    globalMax = log10Value
                }
            }
        }

        let floorValue = globalMax - 8.0
        for i in 0..<melSpec.count {
            for j in 0..<melSpec[i].count {
                let clipped = max(melSpec[i][j], floorValue)
                melSpec[i][j] = (clipped + 4.0) / 4.0
            }
        }

        return melSpec
    }
    
    // MARK: - Private Helpers
    
    private func computePowerSpectrum(frame: [Float]) -> [Float] {
        let n = config.nFFT
        let halfN = n / 2

        // Fall back to a direct DFT for non power-of-two FFT sizes
        // (Qwen3-ASR uses n_fft=400).
        if n <= 0 || (n & (n - 1)) != 0 {
            var powerSpectrum = [Float](repeating: 0, count: halfN + 1)
            let invN = 1.0 / Float(n)
            for k in 0...halfN {
                var real: Float = 0
                var imag: Float = 0
                let base = -2.0 * Float.pi * Float(k) * invN
                for t in 0..<n {
                    let angle = base * Float(t)
                    let s = frame[t]
                    real += s * cos(angle)
                    imag += s * sin(angle)
                }
                powerSpectrum[k] = real * real + imag * imag
            }
            return powerSpectrum
        }
        
        // Prepare split complex format for in-place FFT
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress, let imagBase = imagPtr.baseAddress else { return }
                var splitComplex = DSPSplitComplex(realp: realBase, imagp: imagBase)

                // Convert real input to split complex (even/odd interleaving)
                frame.withUnsafeBufferPointer { framePtr in
                    guard let frameBase = framePtr.baseAddress else { return }
                    vDSP_ctoz(
                        UnsafePointer<DSPComplex>(OpaquePointer(frameBase)),
                        2,
                        &splitComplex,
                        1,
                        vDSP_Length(halfN)
                    )
                }

                // Perform in-place FFT
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
        
        // Compute power spectrum: |X|^2 = real^2 + imag^2
        var powerSpectrum = [Float](repeating: 0, count: halfN + 1)
        
        // DC component
        powerSpectrum[0] = realp[0] * realp[0]
        powerSpectrum[halfN] = imagp[0] * imagp[0]
        
        // Other frequency bins
        for i in 1..<halfN {
            powerSpectrum[i] = realp[i] * realp[i] + imagp[i] * imagp[i]
        }
        
        return powerSpectrum
    }
    
    private func applyMelFilterbank(powerSpectrum: [Float]) -> [Float] {
        let halfN = config.nFFT / 2 + 1
        var melEnergies = [Float](repeating: 0, count: config.nMels)
        
        // Matrix multiply: melEnergies = melFilterbank @ powerSpectrum
        // melFilterbank is [nMels, halfN], powerSpectrum is [halfN]
        for m in 0..<config.nMels {
            var sum: Float = 0
            let specLen = min(halfN, powerSpectrum.count)
            for k in 0..<specLen {
                sum += melFilterbank[m * halfN + k] * powerSpectrum[k]
            }
            melEnergies[m] = sum
        }
        
        return melEnergies
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
        // Slaney-style mel scale (librosa default with htk=false)
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
