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
            nFFT: 512,      // Power of 2 for FFT efficiency (32ms window)
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
        let nFrames = 1 + (samples.count - config.nFFT) / config.hopLength
        guard nFrames > 0 else { return [] }
        
        var melSpec = [[Float]](repeating: [Float](repeating: 0, count: nFrames), count: config.nMels)
        
        // Process each frame
        for frameIdx in 0..<nFrames {
            let start = frameIdx * config.hopLength
            let frame = Array(samples[start..<min(start + config.nFFT, samples.count)])
            
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
        
        // Apply log
        for i in 0..<melSpec.count {
            for j in 0..<melSpec[i].count {
                melSpec[i][j] = log(max(melSpec[i][j], minValue))
            }
        }
        
        return melSpec
    }
    
    // MARK: - Private Helpers
    
    private func computePowerSpectrum(frame: [Float]) -> [Float] {
        let n = config.nFFT
        let halfN = n / 2
        
        // Prepare split complex format for in-place FFT
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        
        // Convert real input to split complex (even/odd interleaving)
        frame.withUnsafeBufferPointer { framePtr in
            var splitComplex = DSPSplitComplex(realp: &realp, imagp: &imagp)
            vDSP_ctoz(
                UnsafePointer<DSPComplex>(OpaquePointer(framePtr.baseAddress!)),
                2,
                &splitComplex,
                1,
                vDSP_Length(halfN)
            )
        }
        
        // Perform in-place FFT
        var splitComplex = DSPSplitComplex(realp: &realp, imagp: &imagp)
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
        
        // Compute power spectrum: |X|^2 = real^2 + imag^2
        var powerSpectrum = [Float](repeating: 0, count: halfN + 1)
        
        // DC component (realp[0] contains DC, imagp[0] contains Nyquist)
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
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
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
        
        // Mel scale boundaries
        let melMin = hzToMel(fMin)
        let melMax = hzToMel(fMax)
        
        // nMels + 2 points for triangular filters
        var melPoints = [Float](repeating: 0, count: nMels + 2)
        for i in 0..<(nMels + 2) {
            melPoints[i] = melMin + Float(i) * (melMax - melMin) / Float(nMels + 1)
        }
        
        // Convert mel points back to Hz
        let hzPoints = melPoints.map { melToHz($0) }
        
        // Convert Hz points to FFT bin indices
        let binPoints = hzPoints.map { hz -> Int in
            Int(round(Float(nFFT + 1) * hz / Float(sampleRate)))
        }
        
        // Create triangular filters
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
