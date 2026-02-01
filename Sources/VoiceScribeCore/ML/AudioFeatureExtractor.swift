import Accelerate
import Foundation
import MLX

public struct AudioFeatureExtractor: Sendable {
    public struct Configuration: Sendable {
        public let sampleRate: Int
        public let melBinCount: Int
        public let frameLength: Int
        public let hopLength: Int

        public init(
            sampleRate: Int = 16_000,
            melBinCount: Int = 80,
            frameLength: Int = 400,
            hopLength: Int = 160
        ) {
            self.sampleRate = sampleRate
            self.melBinCount = melBinCount
            self.frameLength = frameLength
            self.hopLength = hopLength
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func frameCount(sampleCount: Int) -> Int {
        guard sampleCount >= configuration.frameLength else {
            return 0
        }
        return 1 + (sampleCount - configuration.frameLength) / configuration.hopLength
    }

    public func logMelSpectrogram(samples: [Float]) -> MLXArray {
        let frameCount = frameCount(sampleCount: samples.count)
        guard frameCount > 0 else {
            return MLXArray.zeros([1, 0, configuration.melBinCount])
        }

        let nFft = configuration.frameLength
        let hopLength = configuration.hopLength
        let nMels = configuration.melBinCount
        let sampleRate = Float(configuration.sampleRate)

        // 1. Setup FFT
        let log2n = vDSP_Length(log2(Float(nFft)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Failed to create FFT setup")
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // 2. Prepare Window (Hann)
        var window = [Float](repeating: 0, count: nFft)
        vDSP_hann_window(&window, vDSP_Length(nFft), Int32(vDSP_HANN_DENORM))

        // 3. Prepare Mel Filterbank
        // Note: Simple linear-mel filterbank generation
        let filters = createMelFilters(sampleRate: sampleRate, nFft: nFft, nMels: nMels)
        
        var allMelEnergies = [Float](repeating: 0, count: frameCount * nMels)

        // 4. Process Frames
        for i in 0..<frameCount {
            let start = i * hopLength
            let end = start + nFft
            guard end <= samples.count else { break }

            // Apply Window
            var frame = Array(samples[start..<end])
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(nFft))

            // FFT
            var real = [Float](repeating: 0, count: nFft/2)
            var imag = [Float](repeating: 0, count: nFft/2)
            
            real.withUnsafeMutableBufferPointer { realPtr in
                imag.withUnsafeMutableBufferPointer { imagPtr in
                    var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    
                    frame.withUnsafeBufferPointer { ptr in
                        ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nFft/2) {
                            vDSP_ctoz($0, 2, &splitComplex, 1, vDSP_Length(nFft/2))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    
                    // Magnitude Squared (Power Spectrum)
                    var magnitudes = [Float](repeating: 0, count: nFft/2)
                    vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(nFft/2))
                    
                    // Apply Mel Filters
                     let frameOffset = i * nMels
                    for m in 0..<nMels {
                        var melEnergy: Float = 0
                        vDSP_dotpr(magnitudes, 1, filters[m], 1, &melEnergy, vDSP_Length(nFft/2))
                        allMelEnergies[frameOffset + m] = log10(max(melEnergy, 1e-10))
                    }
                }
            }
        }
        
        return MLXArray(allMelEnergies).reshaped([1, frameCount, nMels])
    }

    private func createMelFilters(sampleRate: Float, nFft: Int, nMels: Int) -> [[Float]] {
        let fMin: Float = 0
        let fMax: Float = sampleRate / 2
        
        func hzToMel(_ hz: Float) -> Float { return 2595 * log10(1 + hz / 700) }
        func melToHz(_ mel: Float) -> Float { return 700 * (pow(10, mel / 2595) - 1) }

        let melMin = hzToMel(fMin)
        let melMax = hzToMel(fMax)
        let melPoints = (0...nMels+1).map { i -> Float in
            let mel = melMin + (melMax - melMin) * Float(i) / Float(nMels + 1)
            return melToHz(mel)
        }
        
        let bins = melPoints.map { floor(($0 / sampleRate) * Float(nFft)) }
        var filters = [[Float]]()

        for m in 1...nMels {
            var filter = [Float](repeating: 0, count: nFft/2)
            let start = Int(bins[m-1])
            let center = Int(bins[m])
            let end = Int(bins[m+1])
            
            for k in start..<center {
                filter[k] = (Float(k) - bins[m-1]) / (bins[m] - bins[m-1])
            }
            for k in center..<end {
                filter[k] = (bins[m+1] - Float(k)) / (bins[m+1] - bins[m])
            }
            filters.append(filter)
        }
        return filters
    }
}
