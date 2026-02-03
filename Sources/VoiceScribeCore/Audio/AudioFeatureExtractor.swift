import Foundation
import Accelerate
import AVFoundation

/// Extracts audio features suitable for ASR models.
/// Handles resampling, normalization, and mel spectrogram computation.
@MainActor
public final class AudioFeatureExtractor {
    
    // MARK: - Properties
    
    private let melSpec: MelSpectrogram
    private let targetSampleRate: Int
    
    // MARK: - Initialization
    
    /// Initialize with Qwen3-ASR compatible settings
    public init(config: MelSpectrogram.Config = .qwen3ASR) {
        self.melSpec = MelSpectrogram(config: config)
        self.targetSampleRate = config.sampleRate
    }
    
    // MARK: - Public API
    
    /// Extract features from raw audio samples.
    /// - Parameters:
    ///   - samples: Raw audio samples (mono)
    ///   - sampleRate: Sample rate of input audio
    /// - Returns: Log mel spectrogram features [nMels, nFrames]
    public func extractFeatures(samples: [Float], sampleRate: Int) -> [[Float]] {
        // Resample if needed
        let resampled: [Float]
        if sampleRate != targetSampleRate {
            resampled = resample(samples: samples, fromRate: sampleRate, toRate: targetSampleRate)
        } else {
            resampled = samples
        }
        
        // Normalize audio
        let normalized = normalize(samples: resampled)
        
        // Compute log mel spectrogram
        return melSpec.computeLogMel(samples: normalized)
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
    
    /// Normalize audio to [-1, 1] range.
    private func normalize(samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        
        var maxVal: Float = 0
        vDSP_maxmgv(samples, 1, &maxVal, vDSP_Length(samples.count))
        
        guard maxVal > 0 else { return samples }
        
        var normalized = [Float](repeating: 0, count: samples.count)
        var scale = 1.0 / maxVal
        vDSP_vsmul(samples, 1, &scale, &normalized, 1, vDSP_Length(samples.count))
        
        return normalized
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
    public func extractFeatures(from url: URL) async throws -> [[Float]] {
        let (samples, sampleRate) = try await loadAudioFromURL(url)
        return extractFeatures(samples: samples, sampleRate: sampleRate)
    }
    
    /// Load audio file and return samples with sample rate.
    public func loadAudioFromURL(_ url: URL) async throws -> (samples: [Float], sampleRate: Int) {
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
