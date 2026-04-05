import SwiftUI
import Combine
import AppKit
import os.log

private let logger = Logger(subsystem: "com.voicescribe", category: "AppState")

struct AsyncOperationEpoch {
    private var value: UInt64 = 0

    mutating func begin() -> UInt64 {
        value &+= 1
        return value
    }

    mutating func invalidate() {
        value &+= 1
    }

    func isCurrent(_ token: UInt64) -> Bool {
        token == value
    }
}

@MainActor
public class AppState: ObservableObject {
    public static let shared = AppState()
    
    // MARK: - Published State
    @Published public var transcript: String = ""
    @Published public var status: String = "Initializing..."
    @Published public var audioLevel: Float = 0.0
    @Published public var isRecording: Bool = false
    @Published public private(set) var isStartingRecording: Bool = false
    @Published public var isReady: Bool = false
    @Published public var isModelDownloading: Bool = false
    @Published public var downloadProgress: Double = 0.0
    @Published public var errorMessage: String?
    @Published public var availableInputDevices: [AudioInputDevice] = []
    @Published public var selectedInputDeviceUID: String?
    
    // MARK: - Services
    public let recorder = AudioRecorder()
    public let engine: NativeASRService
    
    private var cancellables = Set<AnyCancellable>()
    private var isInitializing = false
    private var stopRequestedWhileStarting = false
    private var interactionEpoch = AsyncOperationEpoch()
    private var recordingStartTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var statusResetTask: Task<Void, Never>?
    
    public init() {
        self.engine = Self.makeEngine()
        logger.info("🔧 AppState init")
        setupBindings()
        logger.info("🔧 AppState init complete")
    }
    
    private func setupBindings() {
        recorder.$audioLevel
            .receive(on: DispatchQueue.main)
            .assign(to: \.audioLevel, on: self)
            .store(in: &cancellables)

        recorder.$availableInputDevices
            .receive(on: DispatchQueue.main)
            .assign(to: \.availableInputDevices, on: self)
            .store(in: &cancellables)

        recorder.$selectedInputDeviceUID
            .receive(on: DispatchQueue.main)
            .assign(to: \.selectedInputDeviceUID, on: self)
            .store(in: &cancellables)
        
        engine.$status
            .receive(on: DispatchQueue.main)
            .assign(to: \.status, on: self)
            .store(in: &cancellables)
        
        engine.$isReady
            .receive(on: DispatchQueue.main)
            .assign(to: \.isReady, on: self)
            .store(in: &cancellables)
        
        // NativeEngine provides Double progress 0.0-1.0
        engine.$loadProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.downloadProgress = progress
                self?.isModelDownloading = progress < 1.0 && progress > 0.0
            }
            .store(in: &cancellables)
        
        engine.$lastError
            .receive(on: DispatchQueue.main)
            .assign(to: \.errorMessage, on: self)
            .store(in: &cancellables)
    }
    
    // MARK: - Lifecycle

    public func initialize(modelID: String? = nil) async {
        guard !isInitializing else { return }
        guard !isReady else { return }
        isInitializing = true
        defer { isInitializing = false }

        logger.info("🔧 initialize() called")
        let selectedModel = modelID
            ?? UserDefaults.standard.string(forKey: "selectedModel")
            ?? ASRModelCatalog.defaultModelID
        status = NativeASREngine.hasCachedModelFiles(selectedModel)
            ? "Loading local speech model..."
            : "Preparing speech model download..."
        errorMessage = nil
        do {
            await engine.setPreferredLanguageAndWait(Self.storedPreferredLanguage())
            if selectedModel == ASRModelCatalog.defaultModelID {
                try await engine.loadModel()
            } else {
                try await engine.setModelAndWait(selectedModel)
            }
        } catch {
            status = "Model Error"
            errorMessage = error.localizedDescription
        }
        logger.info("🔧 initialize() complete")
    }

    public func shutdown() {
        logger.info("🔧 shutdown() called")
        invalidatePendingInteractionWork()
        if recorder.isRecording {
            _ = recorder.stopRecording()
        }
        stopRequestedWhileStarting = false
        isStartingRecording = false
        isRecording = false
        audioLevel = 0.0
        isModelDownloading = false
        downloadProgress = 0.0
        errorMessage = nil
        status = "Shutdown"
        engine.shutdown()
    }

    private static func makeEngine() -> NativeASRService {
        NativeASRService(
            config: .init(
                modelName: ASRModelCatalog.defaultModelID,
                maxTokens: 256,
                temperature: 0.0,
                forcedLanguage: storedPreferredLanguage()
            )
        )
    }

    private static func storedPreferredLanguage() -> String? {
        ASRLanguageCatalog.modelLanguage(
            for: UserDefaults.standard.string(forKey: ASRLanguageCatalog.defaultsKey)
        )
    }
    
    // MARK: - Recording
    
    public func toggleRecording() {
        logger.info("🎙️ toggleRecording() called, isRecording=\(self.isRecording)")
        
        if isRecording {
            stopRecordingAndTranscribe()
        } else if isStartingRecording {
            // User pressed hotkey again while start is in-flight.
            stopRequestedWhileStarting = true
        } else {
            startRecording()
        }
    }
    
    private func startRecording() {
        logger.info("🎙️ startRecording() called")
        guard !isStartingRecording else { return }
        transcriptionTask?.cancel()
        transcriptionTask = nil
        statusResetTask?.cancel()
        statusResetTask = nil
        isStartingRecording = true
        stopRequestedWhileStarting = false
        let epoch = interactionEpoch.begin()

        let task = Task { [self] in
            defer { isStartingRecording = false }
            do {
                logger.info("🎙️ Calling recorder.startRecording()...")
                try await recorder.startRecording()
                guard interactionEpoch.isCurrent(epoch) else {
                    if recorder.isRecording {
                        _ = recorder.stopRecording()
                    }
                    return
                }
                logger.info("🎙️ recorder.startRecording() succeeded!")
                isRecording = true
                status = "🎤 Recording..."
                errorMessage = nil

                if stopRequestedWhileStarting {
                    stopRequestedWhileStarting = false
                    stopRecordingAndTranscribe()
                }
                recordingStartTask = nil
            } catch {
                guard interactionEpoch.isCurrent(epoch) else {
                    recordingStartTask = nil
                    return
                }
                logger.error("🎙️ recorder.startRecording() FAILED: \(error.localizedDescription)")
                status = "Microphone Error"
                errorMessage = error.localizedDescription
                stopRequestedWhileStarting = false
                recordingStartTask = nil
            }
        }
        recordingStartTask = task
    }
    
    private func stopRecordingAndTranscribe() {
        logger.info("🎙️ stopRecordingAndTranscribe() called")
        let epoch = interactionEpoch.begin()
        recordingStartTask?.cancel()
        recordingStartTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        statusResetTask?.cancel()
        statusResetTask = nil

        let samples = recorder.stopRecording()
        isRecording = false
        status = "Processing..."
        errorMessage = nil
        transcript = ""
        
        logger.info("🎙️ Got \(samples.count) samples")
        
        guard !samples.isEmpty else {
            status = "No audio"
            return
        }

        let sampleRate = recorder.outputSampleRate
        let task = Task { [self] in
            logger.info("🎙️ Calling engine.transcribe()...")
            do {
                let text = try await engine.transcribe(
                    samples: samples,
                    sampleRate: sampleRate
                )
                guard interactionEpoch.isCurrent(epoch) else {
                    transcriptionTask = nil
                    return
                }
                logger.info("🎙️ Transcription result: \(text.prefix(50))...")
                transcript = text
                errorMessage = nil
                
                if !text.isEmpty {
                    // Copy to clipboard
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    
                    status = "✅ Copied"
                    
                    if AppDistribution.supportsAutomaticPaste {
                        InputInjector.pasteFromClipboard()
                    }
                } else {
                    status = "No speech detected"
                }
            } catch {
                guard interactionEpoch.isCurrent(epoch) else {
                    transcriptionTask = nil
                    return
                }
                logger.error("Transcription error: \(error.localizedDescription)")
                if case ASRError.emptyTranscription = error {
                    status = "No speech detected"
                } else {
                    status = "Error"
                }
                errorMessage = error.localizedDescription
            }

            transcriptionTask = nil
            scheduleStatusReset(for: epoch)
        }
        transcriptionTask = task
    }
    
    public func clearTranscript() {
        transcript = ""
    }

    public func refreshInputDevices() {
        recorder.refreshInputDevices()
    }

    public func setPreferredInputDevice(uid: String?) {
        recorder.setSelectedInputDevice(uid: uid)
    }

    private func scheduleStatusReset(for epoch: UInt64) {
        statusResetTask?.cancel()
        statusResetTask = Task { [self] in
            try? await Task.sleep(for: .seconds(2))
            guard interactionEpoch.isCurrent(epoch) else {
                statusResetTask = nil
                return
            }
            if !isRecording {
                status = isReady ? "Ready" : "Waiting..."
            }
            statusResetTask = nil
        }
    }

    private func invalidatePendingInteractionWork() {
        interactionEpoch.invalidate()
        recordingStartTask?.cancel()
        recordingStartTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        statusResetTask?.cancel()
        statusResetTask = nil
    }
}
