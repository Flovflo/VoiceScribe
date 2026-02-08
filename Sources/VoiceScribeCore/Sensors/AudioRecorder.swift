import Foundation
@preconcurrency import AVFoundation
import CoreAudio
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

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
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
    private var previousDefaultInputDeviceID: AudioDeviceID?
    
    func start(preferredDeviceID: AudioDeviceID?) throws {
        lock.lock()
        samples.removeAll()
        lock.unlock()

        if let preferredDeviceID {
            let currentDefault = Self.defaultInputDeviceID()
            if currentDefault != preferredDeviceID {
                guard Self.setDefaultInputDevice(preferredDeviceID) else {
                    throw AudioRecorderError.engineSetupFailed("Failed to switch to selected microphone")
                }
                previousDefaultInputDeviceID = currentDefault
            }
        } else {
            previousDefaultInputDeviceID = nil
        }
        
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
        
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.engine = nil
            throw AudioRecorderError.engineStartFailed(error)
        }
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

        if let previousDefaultInputDeviceID {
            _ = Self.setDefaultInputDevice(previousDefaultInputDeviceID)
            self.previousDefaultInputDeviceID = nil
        }
        
        lock.lock()
        let result = samples
        samples.removeAll()
        lock.unlock()
        
        return result
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr else { return nil }
        return deviceID
    }

    private static func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDeviceID = deviceID
        let dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            dataSize,
            &mutableDeviceID
        )
        return status == noErr
    }
}

@MainActor
public class AudioRecorder: ObservableObject {
    private static let selectedInputDeviceDefaultsKey = "selectedInputDeviceUID"

    private let captureEngine = AudioCaptureEngine()
    private var levelTimer: Timer?
    
    @Published public var isRecording = false
    @Published public var audioLevel: Float = 0.0
    @Published public private(set) var availableInputDevices: [AudioInputDevice] = []
    @Published public private(set) var selectedInputDeviceUID: String?
    
    private let targetSampleRate: Double = 16000
    public var outputSampleRate: Int { Int(targetSampleRate) }
    
    public init() {
        selectedInputDeviceUID = UserDefaults.standard.string(forKey: Self.selectedInputDeviceDefaultsKey)
        refreshInputDevices()
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

        let preferredDeviceID = selectedInputDeviceUID.flatMap(Self.audioDeviceID(forUID:))
        if selectedInputDeviceUID != nil && preferredDeviceID == nil {
            refreshInputDevices()
            throw AudioRecorderError.engineSetupFailed("Selected microphone is unavailable")
        }

        try captureEngine.start(preferredDeviceID: preferredDeviceID)
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

    public func refreshInputDevices() {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
            .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }
            .map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }

        availableInputDevices = devices

        if let selectedInputDeviceUID,
           !devices.contains(where: { $0.id == selectedInputDeviceUID }) {
            self.selectedInputDeviceUID = nil
            UserDefaults.standard.removeObject(forKey: Self.selectedInputDeviceDefaultsKey)
        }
    }

    public func setSelectedInputDevice(uid: String?) {
        if let uid, !uid.isEmpty {
            selectedInputDeviceUID = uid
            UserDefaults.standard.set(uid, forKey: Self.selectedInputDeviceDefaultsKey)
        } else {
            selectedInputDeviceUID = nil
            UserDefaults.standard.removeObject(forKey: Self.selectedInputDeviceDefaultsKey)
        }
    }

    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr else {
            return nil
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = Array<AudioDeviceID>(repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &devices) == noErr else {
            return nil
        }

        for deviceID in devices {
            if deviceUID(for: deviceID) == uid {
                return deviceID
            }
        }

        return nil
    }

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr else {
            return nil
        }
        return uid as String?
    }
}
