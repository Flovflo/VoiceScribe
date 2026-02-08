import Foundation
@preconcurrency import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.voicescribe", category: "AudioRecorder")

public enum AudioRecorderError: Error, LocalizedError {
    case permissionDenied
    case engineSetupFailed(String)
    case engineStartFailed(Error)
    
    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission denied"
        case .engineSetupFailed(let reason):
            return "Audio setup failed: \(reason)"
        case .engineStartFailed(let error):
            return "Recording failed: \(error.localizedDescription)"
        }
    }
}

/// Non-isolated audio capture engine
/// This class is NOT MainActor and handles all audio thread callbacks safely
final class AudioCaptureEngine: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var sampleRate: Double = 48000
    private(set) var lastRMS: Float = 0
    private(set) var isCapturing = false
    
    func start() throws {
        lock.lock()
        samples.removeAll()
        lock.unlock()
        
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        
        guard format.sampleRate > 0 && format.channelCount > 0 else {
            throw AudioRecorderError.engineSetupFailed("No audio input")
        }
        
        sampleRate = format.sampleRate
        self.engine = engine
        
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handleBuffer(buffer)
        }
        
        try engine.start()
        isCapturing = true
    }
    
    private func handleBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        
        let newSamples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
        
        // Calculate RMS
        var sum: Float = 0
        for s in newSamples { sum += s * s }
        lastRMS = sqrt(sum / Float(count))
        
        lock.lock()
        samples.append(contentsOf: newSamples)
        lock.unlock()
    }
    
    func stop() -> [Float] {
        isCapturing = false
        
        if let engine = engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        
        lock.lock()
        let result = samples
        samples.removeAll()
        lock.unlock()
        
        return result
    }
}

@MainActor
public class AudioRecorder: ObservableObject {
    private let captureEngine = AudioCaptureEngine()
    private var levelTimer: Timer?
    
    @Published public var isRecording = false
    @Published public var audioLevel: Float = 0.0
    
    private let targetSampleRate: Double = 16000
    public var outputSampleRate: Int { Int(targetSampleRate) }
    
    public init() {
        logger.info("AudioRecorder initialized")
    }
    
    public func requestPermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
    
    public func startRecording() async throws {
        guard !isRecording else { return }
        
        let hasPermission = await requestPermission()
        guard hasPermission else {
            throw AudioRecorderError.permissionDenied
        }
        
        logger.info("Starting recording...")
        
        try captureEngine.start()
        isRecording = true
        
        // Poll audio level on main thread

        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.audioLevel = min(self.captureEngine.lastRMS * 3, 1.0)
            }
        }

        
        logger.info("Recording started")
    }
    
    public func stopRecording() -> [Float] {
        logger.info("Stopping recording...")
        
        levelTimer?.invalidate()
        levelTimer = nil
        
        let samples = captureEngine.stop()
        let sourceRate = captureEngine.sampleRate
        
        isRecording = false
        audioLevel = 0
        
        logger.info("Stopped with \(samples.count) samples at \(sourceRate)Hz")
        
        return resample(samples, from: sourceRate, to: targetSampleRate)
    }
    
    private func resample(_ inputSamples: [Float], from sourceRate: Double, to destinationRate: Double) -> [Float] {
        guard sourceRate > 0 && sourceRate != destinationRate else {
            return inputSamples
        }
        
        let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false)!
        let destFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: destinationRate, channels: 1, interleaved: false)!
        
        guard let converter = AVAudioConverter(from: sourceFormat, to: destFormat) else {
            logger.error("Failed to create audio converter")
            return []
        }
        
        let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(inputSamples.count))!
        inputBuffer.frameLength = AVAudioFrameCount(inputSamples.count)
        if let data = inputBuffer.floatChannelData {
            data[0].update(from: inputSamples, count: inputSamples.count)
        }
        
        let ratio = destinationRate / sourceRate
        let capacity = AVAudioFrameCount(Double(inputSamples.count) * ratio) + 100 // slightly larger buffer
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: destFormat, frameCapacity: capacity)!
        
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        if let error = error {
            logger.error("Audio conversion error: \(error.localizedDescription)")
            return []
        }
        
        guard let outputData = outputBuffer.floatChannelData else { return [] }
        let outputCount = Int(outputBuffer.frameLength)
        let outputSamples = Array(UnsafeBufferPointer(start: outputData[0], count: outputCount))
        
        logger.info("Resampled \(inputSamples.count) -> \(outputSamples.count) (CoreAudio High Quality)")
        return outputSamples
    }
}
