import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.voicescribe", category: "AudioRecorder")

private final class ConverterInputState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasSuppliedInput = false
    let buffer: AVAudioPCMBuffer

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextBuffer() -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !hasSuppliedInput else { return nil }
        hasSuppliedInput = true
        return buffer
    }
}

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

enum AudioInputRouteCandidate: Equatable, Sendable {
    case systemDefault
    case specific(String)
}

struct AudioInputRoutePlanner {
    static func orderedCandidates(
        selectedUID: String?,
        systemDefaultUID: String?,
        availableDevices: [AudioInputDevice]
    ) -> [AudioInputRouteCandidate] {
        let availableUIDs = Set(availableDevices.map(\.id))
        var candidates: [AudioInputRouteCandidate] = []
        var seenSpecificUIDs = Set<String>()
        var includesSystemDefault = false

        func append(_ candidate: AudioInputRouteCandidate) {
            switch candidate {
            case .systemDefault:
                guard !includesSystemDefault else { return }
                includesSystemDefault = true
            case .specific(let uid):
                guard seenSpecificUIDs.insert(uid).inserted else { return }
            }
            candidates.append(candidate)
        }

        if let selectedUID,
           !selectedUID.isEmpty,
           (availableUIDs.contains(selectedUID) || selectedUID == systemDefaultUID) {
            append(.specific(selectedUID))
        }

        append(.systemDefault)

        if let systemDefaultUID, !systemDefaultUID.isEmpty {
            append(.specific(systemDefaultUID))
        }

        for device in availableDevices {
            append(.specific(device.id))
        }

        return candidates
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
    private var hasReceivedBuffer = false
    
    func start(preferredDeviceID: AudioDeviceID?) throws {
        lock.lock()
        samples.removeAll()
        hasReceivedBuffer = false
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
        do {
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
        } catch {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
            isCapturing = false
            if let previousDefaultInputDeviceID {
                _ = Self.setDefaultInputDevice(previousDefaultInputDeviceID)
                self.previousDefaultInputDeviceID = nil
            }
            if let recorderError = error as? AudioRecorderError {
                throw recorderError
            }
            throw AudioRecorderError.engineStartFailed(error)
        }

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
        hasReceivedBuffer = true
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

    func waitForFirstBuffer(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if didReceiveBuffer() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return didReceiveBuffer()
    }

    private func didReceiveBuffer() -> Bool {
        lock.lock()
        let result = hasReceivedBuffer
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
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await Self.bridgePermissionRequest(Self.systemRequestMicrophonePermission)
        @unknown default:
            return false
        }
    }
    
    public func startRecording() async throws {
        guard !isRecording else { return }
        
        let hasPermission = await requestPermission()
        guard hasPermission else {
            throw AudioRecorderError.permissionDenied
        }
        
        logger.info("Starting recording...")

        refreshInputDevices()
        try await startCaptureWithFallback()
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

    private func startCaptureWithFallback() async throws {
        let candidates = AudioInputRoutePlanner.orderedCandidates(
            selectedUID: selectedInputDeviceUID,
            systemDefaultUID: Self.defaultInputDeviceID().flatMap { Self.deviceUID(for: $0) },
            availableDevices: availableInputDevices
        )

        var lastError: Error?
        for candidate in candidates {
            do {
                try await attemptCaptureStart(using: candidate)
                return
            } catch {
                lastError = error
                logger.warning("Microphone candidate \(self.logDescription(for: candidate)) failed: \(error.localizedDescription)")
            }
        }

        throw lastError ?? AudioRecorderError.engineSetupFailed("No working microphone input found")
    }

    private func attemptCaptureStart(using candidate: AudioInputRouteCandidate) async throws {
        let preferredDeviceID = try preferredDeviceID(for: candidate)
        try captureEngine.start(preferredDeviceID: preferredDeviceID)

        guard await captureEngine.waitForFirstBuffer(timeout: .milliseconds(700)) else {
            _ = captureEngine.stop()
            throw AudioRecorderError.engineSetupFailed("Microphone produced no audio buffers")
        }
    }

    private func preferredDeviceID(for candidate: AudioInputRouteCandidate) throws -> AudioDeviceID? {
        switch candidate {
        case .systemDefault:
            return nil
        case .specific(let uid):
            guard let deviceID = Self.audioDeviceID(forUID: uid) else {
                throw AudioRecorderError.engineSetupFailed("Selected microphone is unavailable")
            }
            return deviceID
        }
    }

    private func logDescription(for candidate: AudioInputRouteCandidate) -> String {
        switch candidate {
        case .systemDefault:
            return "system-default"
        case .specific(let uid):
            let deviceName = availableInputDevices.first(where: { $0.id == uid })?.name ?? uid
            return "\"\(deviceName)\""
        }
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
        let inputState = ConverterInputState(buffer: inputBuffer)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            guard let nextBuffer = inputState.nextBuffer() else {
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return nextBuffer
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
        let devices = Self.allAudioDeviceIDs()
            .filter { Self.hasInputChannels(for: $0) }
            .compactMap { deviceID -> AudioInputDevice? in
                guard let uid = Self.deviceUID(for: deviceID),
                      let name = Self.deviceName(for: deviceID) else {
                    return nil
                }
                return AudioInputDevice(id: uid, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

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

    nonisolated private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        for deviceID in allAudioDeviceIDs() {
            if deviceUID(for: deviceID) == uid {
                return deviceID
            }
        }

        return nil
    }

    nonisolated private static func defaultInputDeviceID() -> AudioDeviceID? {
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

    nonisolated private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = Array<AudioDeviceID>(repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &devices) == noErr else {
            return []
        }

        return devices
    }

    nonisolated private static func hasInputChannels(for deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioBufferList>.size else {
            return false
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let bufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPointer) == noErr else {
            return false
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return bufferList.contains { $0.mNumberChannels > 0 }
    }

    nonisolated private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr else {
            return nil
        }
        return name as String?
    }

    nonisolated static func bridgePermissionRequest(
        _ request: @escaping @Sendable (@escaping @Sendable (Bool) -> Void) -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            request { granted in
                Task { @MainActor in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    nonisolated private static func systemRequestMicrophonePermission(
        _ completion: @escaping @Sendable (Bool) -> Void
    ) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    nonisolated private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
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
