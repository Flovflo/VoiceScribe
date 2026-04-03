import SwiftUI
import Combine
import AppKit
import os.log

private let logger = Logger(subsystem: "com.voicescribe", category: "AppState")

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
    public let engine = NativeASRService()
    
    private var cancellables = Set<AnyCancellable>()
    private var isInitializing = false
    private var stopRequestedWhileStarting = false
    
    public init() {
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

    public func initialize() async {
        guard !isInitializing else { return }
        guard !isReady else { return }
        isInitializing = true
        defer { isInitializing = false }

        logger.info("🔧 initialize() called")
        status = "Loading Native ASR..."
        errorMessage = nil
        let selectedModel = UserDefaults.standard.string(forKey: "selectedModel")
            ?? ASRModelCatalog.defaultModelID
        do {
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
        isStartingRecording = true
        stopRequestedWhileStarting = false
        
        Task {
            defer { isStartingRecording = false }
            do {
                logger.info("🎙️ Calling recorder.startRecording()...")
                try await recorder.startRecording()
                logger.info("🎙️ recorder.startRecording() succeeded!")
                isRecording = true
                status = "🎤 Recording..."
                errorMessage = nil

                if stopRequestedWhileStarting {
                    stopRequestedWhileStarting = false
                    stopRecordingAndTranscribe()
                }
            } catch {
                logger.error("🎙️ recorder.startRecording() FAILED: \(error.localizedDescription)")
                status = "Microphone Error"
                errorMessage = error.localizedDescription
                stopRequestedWhileStarting = false
            }
        }
    }
    
    private func stopRecordingAndTranscribe() {
        logger.info("🎙️ stopRecordingAndTranscribe() called")
        
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
        
        Task {
            logger.info("🎙️ Calling engine.transcribe()...")
            do {
                let text = try await engine.transcribe(
                    samples: samples,
                    sampleRate: recorder.outputSampleRate
                )
                logger.info("🎙️ Transcription result: \(text.prefix(50))...")
                transcript = text
                errorMessage = nil
                
                if !text.isEmpty {
                    // Copy to clipboard
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    
                    status = "✅ Copied"
                    
                    // Auto Paste
                    InputInjector.pasteFromClipboard()
                } else {
                    status = "No speech detected"
                }
            } catch {
                logger.error("Transcription error: \(error.localizedDescription)")
                if case ASRError.emptyTranscription = error {
                    status = "No speech detected"
                } else {
                    status = "Error"
                }
                errorMessage = error.localizedDescription
            }
            
            try? await Task.sleep(for: .seconds(2))
            if !isRecording {
                status = isReady ? "Ready" : "Waiting..."
            }
        }
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
}
