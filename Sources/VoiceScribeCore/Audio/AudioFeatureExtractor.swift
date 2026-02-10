import Foundation
import AVFoundation
import MLX
import os.log

/// Extracts audio features suitable for ASR models.
/// Handles resampling, normalization, and mel spectrogram computation.
public final class AudioFeatureExtractor {

    public enum Backend: Sendable {
        case cpu
        case mlx
    }

    public struct AudioChunk: Sendable {
        public let samples: [Float]
        public let offsetSeconds: Float

        public init(samples: [Float], offsetSeconds: Float) {
            self.samples = samples
            self.offsetSeconds = offsetSeconds
        }
    }

    // MARK: - Properties

    private let config: MelSpectrogram.Config
    private let melSpecCPU: MelSpectrogram
    private let targetSampleRate: Int
    private let backend: Backend
    private let useCPUDeviceForMLX: Bool
    private lazy var melSpecMLX: MLXMelSpectrogram = MLXMelSpectrogram(config: config)

    private static let logger = Logger(subsystem: "com.voicescribe", category: "AudioFeatureExtractor")

    // MARK: - Initialization

    /// Initialize with Qwen3-ASR compatible settings
    public init(config: MelSpectrogram.Config = .qwen3ASR, backend: Backend = .mlx) {
        self.config = config
        self.melSpecCPU = MelSpectrogram(config: config)
        self.targetSampleRate = config.sampleRate
        self.backend = backend
        let envDevice = ProcessInfo.processInfo.environment["VOICESCRIBE_MLX_DEVICE"]?.lowercased()
        self.useCPUDeviceForMLX = (envDevice == "cpu")
    }

    // MARK: - Public API

    /// Extract features from raw audio samples.
    /// - Parameters:
    ///   - samples: Raw audio samples (mono)
    ///   - sampleRate: Sample rate of input audio
    /// - Returns: Log mel spectrogram features [nMels, nFrames]
    public func extractFeatures(samples: [Float], sampleRate: Int) -> [[Float]] {
        switch backend {
        case .cpu:
            return extractFeaturesCPU(samples: samples, sampleRate: sampleRate)
        case .mlx:
            let mlx = extractFeaturesMLX(samples: samples, sampleRate: sampleRate)
            return Self.toCPUArray(mlx)
        }
    }

    /// Extract features from raw audio samples using MLX (GPU).
    /// - Returns: Log mel spectrogram features [1, nMels, nFrames]
    public func extractFeaturesMLX(samples: [Float], sampleRate: Int) -> MLXArray {
        let device: Device = useCPUDeviceForMLX ? .cpu : .gpu
        return Device.withDefaultDevice(device) {
            let resampled = resampleIfNeeded(samples: samples, sampleRate: sampleRate)
            guard !resampled.isEmpty else { return MLXArray.zeros([0, 0, 0]) }

            let mel = melSpecMLX.computeLogMel(samples: resampled)
            if mel.dim(0) == 0 {
                return MLXArray.zeros([0, 0, 0])
            }

            // MLXMelSpectrogram returns [nFrames, nMels].
            // Qwen3-ASR expects [batch, nMels, nFrames] at audio encoder input.
            let melTransposed = mel.transposed(1, 0)
            if ProcessInfo.processInfo.environment["VOICESCRIBE_DUMP_FEATURE_STATS"] == "1" {
                let flat = melTransposed.asArray(Float.self)
                let minValue = flat.min() ?? 0
                let maxValue = flat.max() ?? 0
                let meanValue = flat.reduce(0, +) / Float(max(flat.count, 1))
                print(
                    "[AudioFeatureExtractor] shape=[\(melTransposed.dim(0)), \(melTransposed.dim(1))] min=\(minValue) max=\(maxValue) mean=\(meanValue)"
                )
            }
            return melTransposed.expandedDimensions(axis: 0)
        }
    }

    /// Extract features and flatten to 1D array for model input.
    /// - Parameters:
    ///   - samples: Raw audio samples
    ///   - sampleRate: Sample rate of input
    /// - Returns: Flattened features [nMels * nFrames]
    public func extractFlatFeatures(samples: [Float], sampleRate: Int) -> [Float] {
        let features = extractFeatures(samples: samples, sampleRate: sampleRate)
        return features.flatMap { $0 }
    }

    /// Get feature dimensions.
    /// - Parameter samples: Audio samples
    /// - Parameter sampleRate: Sample rate
    /// - Returns: (nMels, nFrames)
    public func featureShape(samples: [Float], sampleRate: Int) -> (nMels: Int, nFrames: Int) {
        let features = extractFeatures(samples: samples, sampleRate: sampleRate)
        guard !features.isEmpty else { return (0, 0) }
        return (features.count, features[0].count)
    }

    /// Split long audio into chunks near low-energy boundaries.
    /// Returns a single chunk for short recordings.
    public func splitIntoChunks(
        samples: [Float],
        sampleRate: Int,
        chunkDuration: Float,
        minChunkDuration: Float = 1.0,
        searchExpandSeconds: Float = 2.0,
        minWindowMs: Float = 100.0
    ) -> [AudioChunk] {
        guard sampleRate > 0, !samples.isEmpty, chunkDuration > 0 else {
            return [AudioChunk(samples: samples, offsetSeconds: 0)]
        }

        let totalSamples = samples.count
        let maxChunkSamples = max(1, Int(Float(sampleRate) * chunkDuration))
        if totalSamples <= maxChunkSamples {
            return [AudioChunk(samples: samples, offsetSeconds: 0)]
        }

        let searchSamples = max(1, Int(Float(sampleRate) * searchExpandSeconds))
        let windowSize = max(1, Int(Float(sampleRate) * (minWindowMs / 1000.0)))
        let minChunkSamples = max(1, Int(Float(sampleRate) * minChunkDuration))

        var chunks: [AudioChunk] = []
        chunks.reserveCapacity(max(1, totalSamples / maxChunkSamples + 1))

        var start = 0
        while start < totalSamples {
            let naturalEnd = min(totalSamples, start + maxChunkSamples)
            if naturalEnd >= totalSamples {
                var finalSamples = Array(samples[start..<totalSamples])
                if finalSamples.count < minChunkSamples {
                    finalSamples.append(contentsOf: repeatElement(0, count: minChunkSamples - finalSamples.count))
                }
                let offset = Float(start) / Float(sampleRate)
                chunks.append(AudioChunk(samples: finalSamples, offsetSeconds: offset))
                break
            }

            let searchStart = max(start, naturalEnd - searchSamples)
            let searchEnd = min(totalSamples, naturalEnd + searchSamples)
            let searchRegion = Array(samples[searchStart..<searchEnd])

            var cut = naturalEnd
            if searchRegion.count > windowSize {
                var windowEnergy: Float = 0
                for i in 0..<windowSize {
                    let v = searchRegion[i]
                    windowEnergy += v * v
                }

                let invWindow = 1.0 / Float(windowSize)
                let energyLength = searchRegion.count - windowSize + 1
                var minEnergy = windowEnergy * invWindow
                var minIndex = 0

                if energyLength > 1 {
                    for i in 1..<energyLength {
                        let old = searchRegion[i - 1]
                        let new = searchRegion[i + windowSize - 1]
                        windowEnergy += new * new - old * old
                        let e = windowEnergy * invWindow
                        if e < minEnergy {
                            minEnergy = e
                            minIndex = i
                        }
                    }
                }

                cut = searchStart + minIndex + (windowSize / 2)
            }

            cut = max(cut, start + sampleRate)
            cut = min(cut, totalSamples)

            var chunkSamples = Array(samples[start..<cut])
            if chunkSamples.count < minChunkSamples {
                chunkSamples.append(contentsOf: repeatElement(0, count: minChunkSamples - chunkSamples.count))
            }
            let offset = Float(start) / Float(sampleRate)
            chunks.append(AudioChunk(samples: chunkSamples, offsetSeconds: offset))
            start = cut
        }

        if chunks.isEmpty {
            return [AudioChunk(samples: samples, offsetSeconds: 0)]
        }
        return chunks
    }

    // MARK: - Audio Processing

    /// Resample audio using linear interpolation.
    private func resample(samples: [Float], fromRate sourceRate: Int, toRate targetRate: Int) -> [Float] {
        guard sourceRate > 0 && targetRate > 0 else { return samples }
        guard sourceRate != targetRate else { return samples }

        let ratio = Double(sourceRate) / Double(targetRate)
        let outputCount = Int(Double(samples.count) / ratio)
        guard outputCount > 0 else { return [] }

        var resampled = [Float](repeating: 0, count: outputCount)

        for i in 0..<outputCount {
            let srcIndex = Double(i) * ratio
            let srcIndexInt = Int(srcIndex)
            let fraction = Float(srcIndex - Double(srcIndexInt))

            if srcIndexInt + 1 < samples.count {
                resampled[i] = samples[srcIndexInt] * (1 - fraction) + samples[srcIndexInt + 1] * fraction
            } else if srcIndexInt < samples.count {
                resampled[i] = samples[srcIndexInt]
            }
        }

        return resampled
    }

    private func resampleIfNeeded(samples: [Float], sampleRate: Int) -> [Float] {
        guard sampleRate > 0 else { return samples }
        guard sampleRate != targetSampleRate else { return samples }
        Self.logger.warning("Resampling from \(sampleRate)Hz to \(self.targetSampleRate)Hz")
        return resample(samples: samples, fromRate: sampleRate, toRate: targetSampleRate)
    }

    private func extractFeaturesCPU(samples: [Float], sampleRate: Int) -> [[Float]] {
        let resampled = resampleIfNeeded(samples: samples, sampleRate: sampleRate)
        return melSpecCPU.computeLogMel(samples: resampled)
    }

    private static func toCPUArray(_ mlx: MLXArray) -> [[Float]] {
        if mlx.ndim != 3 {
            return []
        }
        let mels = mlx.dim(1)
        let frames = mlx.dim(2)
        let flat = mlx.asArray(Float.self)
        if flat.count != frames * mels {
            return []
        }

        var output = [[Float]](repeating: [Float](repeating: 0, count: frames), count: mels)
        for m in 0..<mels {
            for f in 0..<frames {
                output[m][f] = flat[m * frames + f]
            }
        }
        return output
    }

    /// Apply pre-emphasis filter to boost high frequencies.
    /// Commonly used in ASR: y[n] = x[n] - coeff * x[n-1]
    public func applyPreEmphasis(samples: [Float], coefficient: Float = 0.97) -> [Float] {
        guard samples.count > 1 else { return samples }

        var output = [Float](repeating: 0, count: samples.count)
        output[0] = samples[0]

        for i in 1..<samples.count {
            output[i] = samples[i] - coefficient * samples[i - 1]
        }

        return output
    }
}

// MARK: - Convenience Extensions

extension AudioFeatureExtractor {

    /// Extract features from audio file URL.
    public func extractFeatures(from url: URL) throws -> [[Float]] {
        let (samples, sampleRate) = try loadAudioFromURL(url)
        return extractFeatures(samples: samples, sampleRate: sampleRate)
    }

    /// Load audio file and return samples with sample rate.
    public func loadAudioFromURL(_ url: URL) throws -> (samples: [Float], sampleRate: Int) {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let frameCount = UInt32(audioFile.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioError.bufferCreationFailed
        }

        try audioFile.read(into: buffer)

        guard let channelData = buffer.floatChannelData?[0] else {
            throw AudioError.noAudioData
        }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
        let sampleRate = Int(format.sampleRate)

        return (samples, sampleRate)
    }
}

// MARK: - Errors

public enum AudioError: Error, LocalizedError {
    case bufferCreationFailed
    case noAudioData
    case invalidSampleRate

    public var errorDescription: String? {
        switch self {
        case .bufferCreationFailed:
            return "Failed to create audio buffer"
        case .noAudioData:
            return "No audio data in file"
        case .invalidSampleRate:
            return "Invalid sample rate"
        }
    }
}
