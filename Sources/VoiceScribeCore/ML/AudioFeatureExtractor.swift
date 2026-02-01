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
            return MLXArray(zeros: [1, 0, configuration.melBinCount])
        }

        var features = [Float](repeating: 0, count: frameCount * configuration.melBinCount)
        let epsilon: Float = 1e-6

        for frameIndex in 0..<frameCount {
            let start = frameIndex * configuration.hopLength
            let end = start + configuration.frameLength
            guard end <= samples.count else { break }

            let frame = Array(samples[start..<end])
            var rms: Float = 0
            vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))
            let logEnergy = log(max(rms, epsilon))

            let offset = frameIndex * configuration.melBinCount
            for melIndex in 0..<configuration.melBinCount {
                features[offset + melIndex] = logEnergy
            }
        }

        return MLXArray(features, shape: [1, frameCount, configuration.melBinCount])
    }
}
