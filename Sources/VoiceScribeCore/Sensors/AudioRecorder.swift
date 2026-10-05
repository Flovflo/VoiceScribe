import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import AudioToolbox
import Accelerate
import os.log

private let logger = Logger(subsystem: "com.voicescribe", category: "AudioRecorder")

private final class MicrophonePermissionRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        let result = lock.withLock { () -> Bool? in
            if let result { return result }
            self.continuation = continuation
            return nil as Bool?
        }
        if let result { continuation.resume(returning: result) }
    }

    func resolve(_ result: Bool) {
        let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard self.result == nil else { return nil as CheckedContinuation<Bool, Never>? }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }
}

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

private final class SelectedMicrophoneDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private weak var engine: AudioCaptureEngine?
    private let generation: UInt64

    init(engine: AudioCaptureEngine, generation: UInt64) {
        self.engine = engine
        self.generation = generation
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        engine?.handleSampleBuffer(sampleBuffer, generation: generation)
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
        if let selectedUID,
           !selectedUID.isEmpty,
           (availableUIDs.contains(selectedUID) || selectedUID == systemDefaultUID) {
            return [.specific(selectedUID)]
        }

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
    // AVAudioEngine lifecycle runs on one worker queue. The tap only touches
    // sample storage under `lock`, never the engine or the main actor.
    private let controlQueue = DispatchQueue(label: "com.voicescribe.audio-capture")
    private let callbackQueue = DispatchQueue(label: "com.voicescribe.audio-capture-buffers", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var captureSession: AVCaptureSession?
    private var captureDelegate: SelectedMicrophoneDelegate?
    private var samples: [Float] = []
    private let lock = NSLock()
    private var captureSampleRate: Double = 48000
    var sampleRate: Double { lock.withLock { captureSampleRate } }
    private var rms: Float = 0
    var lastRMS: Float {
        lock.withLock { rms }
    }
    private var hasReceivedBuffer = false
    private var captureGeneration: UInt64 = 0
    
    func start(preferredDeviceID: AudioDeviceID?) async throws {
        try Task.checkCancellation()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                controlQueue.async {
                    do {
                        try self.startOnControlQueue(preferredDeviceID: preferredDeviceID)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
        } catch {
            _ = stop()
            throw error
        }
    }

    private func startOnControlQueue(preferredDeviceID: AudioDeviceID?) throws {
        guard engine == nil, captureSession == nil else {
            throw AudioRecorderError.engineSetupFailed("Audio capture is already active")
        }
        let generation = lock.withLock {
            samples.removeAll(keepingCapacity: true)
            hasReceivedBuffer = false
            rms = 0
            captureGeneration &+= 1
            return captureGeneration
        }
        if let preferredDeviceID {
            try startSelectedMicrophone(preferredDeviceID, generation: generation)
            return
        }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        var tapInstalled = false
        do {
            let format = inputNode.outputFormat(forBus: 0)

            guard format.sampleRate > 0 && format.channelCount > 0 else {
                throw AudioRecorderError.engineSetupFailed("No audio input")
            }

            lock.withLock { captureSampleRate = format.sampleRate }

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                self?.handleBuffer(buffer, generation: generation)
            }
            tapInstalled = true

            try engine.start()
            self.engine = engine
        } catch {
            if tapInstalled { inputNode.removeTap(onBus: 0) }
            engine.stop()
            if let recorderError = error as? AudioRecorderError {
                throw recorderError
            }
            throw AudioRecorderError.engineStartFailed(error)
        }

    }

    private func startSelectedMicrophone(_ deviceID: AudioDeviceID, generation: UInt64) throws {
        guard let uid = AudioRecorder.deviceUID(for: deviceID),
              let device = AVCaptureDevice(uniqueID: uid), device.hasMediaType(.audio) else {
            throw AudioRecorderError.engineSetupFailed("Selected microphone is unavailable to native capture")
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false
        ]
        let delegate = SelectedMicrophoneDelegate(engine: self, generation: generation)
        output.setSampleBufferDelegate(delegate, queue: callbackQueue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw AudioRecorderError.engineSetupFailed("Selected microphone cannot be attached to capture session")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        guard session.isRunning else {
            session.stopRunning()
            throw AudioRecorderError.engineSetupFailed("Selected microphone capture did not start")
        }
        captureDelegate = delegate
        captureSession = session
    }

    func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, generation: UInt64) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: stream),
              format.commonFormat == .pcmFormatFloat32 else { return }
        var listSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil
        ) == noErr, listSize > 0 else { return }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list,
            bufferListSize: listSize, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &blockBuffer
        ) == noErr,
        let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) else { return }
        // Both wrappers borrow CoreMedia's sample storage for this callback only.
        withExtendedLifetime(blockBuffer) {
            handleBuffer(buffer, generation: generation)
        }
    }
    
    func handleBuffer(_ buffer: AVAudioPCMBuffer, generation: UInt64? = nil) {
        guard let channelData = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard count > 0, channels > 0 else { return }

        // Read the callback's borrowed storage directly for mono; only multichannel
        // input needs a temporary buffer. vDSP also handles interleaved strides.
        let stride = vDSP_Stride(buffer.stride)
        func append(_ pointer: UnsafePointer<Float>, stride: vDSP_Stride) {
            var level: Float = 0
            vDSP_rmsqv(pointer, stride, &level, vDSP_Length(count))
            lock.withLock {
                if let generation, generation != captureGeneration { return }
                captureSampleRate = buffer.format.sampleRate
                hasReceivedBuffer = true
                rms = level
                if stride == 1 {
                    samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: count))
                } else {
                    for frame in 0..<count { samples.append(pointer[frame * Int(stride)]) }
                }
            }
        }

        if channels == 1 {
            append(UnsafePointer(channelData[0]), stride: stride)
        } else {
            var mono = [Float](repeating: 0, count: count)
            mono.withUnsafeMutableBufferPointer { output in
                guard let destination = output.baseAddress else { return }
                for channel in 0..<channels {
                    vDSP_vadd(destination, 1, channelData[channel], stride,
                              destination, 1, vDSP_Length(count))
                }
                var gain = 1 / Float(channels)
                vDSP_vsmul(destination, 1, &gain, destination, 1, vDSP_Length(count))
                append(UnsafePointer(destination), stride: 1)
            }
        }
    }
    
    func stop() -> [Float] {
        // Finish the recording synchronously. A callback still mixing its
        // channels will fail the generation check before it can append samples.
        let result = lock.withLock {
            captureGeneration &+= 1
            let result = samples
            samples = []
            hasReceivedBuffer = false
            rms = 0
            return result
        }
        // Hardware teardown can block. Keep it on the lifecycle queue, where
        // it is ordered before any subsequent start without delaying the UI.
        controlQueue.async { [self] in
            if let engine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            engine = nil
            captureSession?.stopRunning()
            captureSession = nil
            captureDelegate = nil
        }
        return result
    }

    func waitForFirstBuffer(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled else { return false }
            if didReceiveBuffer() {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return false
            }
        }
        return !Task.isCancelled && didReceiveBuffer()
    }

    private func didReceiveBuffer() -> Bool {
        lock.lock()
        let result = hasReceivedBuffer
        lock.unlock()
        return result
    }

}

@MainActor
public class AudioRecorder: ObservableObject {
    private static let selectedInputDeviceDefaultsKey = "selectedInputDeviceUID"

    private let captureEngine = AudioCaptureEngine()
    private var levelTimer: Timer?
    private var isStarting = false
    private var startupGeneration: UInt64 = 0
    
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
        try Task.checkCancellation()
        guard !isRecording else { return }
        guard !isStarting else {
            throw AudioRecorderError.engineSetupFailed("Microphone startup is still in progress")
        }
        isStarting = true
        startupGeneration &+= 1
        let generation = startupGeneration
        defer { isStarting = false }
        
        let hasPermission = await requestPermission()
        try checkStartup(generation)
        guard hasPermission else {
            throw AudioRecorderError.permissionDenied
        }
        
        logger.info("Starting recording...")

        refreshInputDevices()
        do {
            try await startCaptureWithFallback(generation: generation)
            try checkStartup(generation)
        } catch {
            _ = captureEngine.stop()
            throw error
        }
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

    private func checkStartup(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == startupGeneration else { throw CancellationError() }
    }

    private func startCaptureWithFallback(generation: UInt64) async throws {
        let candidates = AudioInputRoutePlanner.orderedCandidates(
            selectedUID: selectedInputDeviceUID,
            systemDefaultUID: Self.defaultInputDeviceID().flatMap { Self.deviceUID(for: $0) },
            availableDevices: availableInputDevices
        )

        var lastError: Error?
        for candidate in candidates {
            try checkStartup(generation)
            do {
                try await attemptCaptureStart(using: candidate, generation: generation)
                logger.info("Microphone candidate \(self.logDescription(for: candidate), privacy: .public) selected")
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                logger.warning(
                    "Microphone candidate \(self.logDescription(for: candidate), privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        throw lastError ?? AudioRecorderError.engineSetupFailed("No working microphone input found")
    }

    private func attemptCaptureStart(using candidate: AudioInputRouteCandidate, generation: UInt64) async throws {
        let preferredDeviceID = try preferredDeviceID(for: candidate)
        do {
            try await captureEngine.start(preferredDeviceID: preferredDeviceID)
            try checkStartup(generation)
            let received = await captureEngine.waitForFirstBuffer(timeout: .milliseconds(700))
            try checkStartup(generation)
            guard received else {
                throw AudioRecorderError.engineSetupFailed("Microphone produced no audio buffers")
            }
        } catch {
            _ = captureEngine.stop()
            throw error
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
        let capture = finishCapture()
        return Self.resample(capture.samples, from: capture.rate, to: targetSampleRate)
    }

    /// Stops capture immediately; CPU resampling then runs away from the UI actor.
    public func stopRecordingAndResample() async -> [Float] {
        let capture = finishCapture()
        let targetRate = targetSampleRate
        return await Task.detached(priority: .userInitiated) {
            Self.resample(capture.samples, from: capture.rate, to: targetRate)
        }.value
    }

    private func finishCapture() -> (samples: [Float], rate: Double) {
        startupGeneration &+= 1
        logger.info("Stopping recording...")
        
        levelTimer?.invalidate()
        levelTimer = nil
        
        let samples = captureEngine.stop()
        let sourceRate = captureEngine.sampleRate
        
        isRecording = false
        audioLevel = 0
        
        logger.info("Stopped with \(samples.count) samples at \(sourceRate)Hz")
        
        return (samples, sourceRate)
    }
    
    nonisolated static func resample(_ inputSamples: [Float], from sourceRate: Double, to destinationRate: Double) -> [Float] {
        guard !inputSamples.isEmpty else { return [] }
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
        let state = MicrophonePermissionRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.install(continuation)
                if Task.isCancelled {
                    state.resolve(false)
                } else {
                    request { granted in state.resolve(granted) }
                }
            }
        } onCancel: {
            state.resolve(false)
        }
    }

    nonisolated private static func systemRequestMicrophonePermission(
        _ completion: @escaping @Sendable (Bool) -> Void
    ) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    nonisolated fileprivate static func deviceUID(for deviceID: AudioDeviceID) -> String? {
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
