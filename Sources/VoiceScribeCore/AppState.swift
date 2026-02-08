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
    @Published public var isReady: Bool = false
    @Published public var isModelDownloading: Bool = false
    @Published public var downloadProgress: Double = 0.0
    @Published public var errorMessage: String?
    
    // MARK: - Services
    public let recorder = AudioRecorder()
    public let engine = NativeASRService()
    
    private var cancellables = Set<AnyCancellable>()
    private var isInitializing = false
    
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
        await engine.loadModel()
        if !isReady, let lastError = engine.lastError {
            status = "Model Error"
            errorMessage = lastError
        }
        logger.info("🔧 initialize() complete")
    }

    public func shutdown() {
        logger.info("🔧 shutdown() called")
        engine.shutdown()
    }
    
    // MARK: - Recording
    
    public func toggleRecording() {
        logger.info("🎙️ toggleRecording() called, isRecording=\(self.isRecording)")
        
        if isRecording {
            stopRecordingAndTranscribe()
        } else {
            startRecording()
        }
    }
    
    private func startRecording() {
        logger.info("🎙️ startRecording() called")
        
        Task {
            do {
                logger.info("🎙️ Calling recorder.startRecording()...")
                try await recorder.startRecording()
                logger.info("🎙️ recorder.startRecording() succeeded!")
                isRecording = true
                status = "🎤 Recording..."
                errorMessage = nil
            } catch {
                logger.error("🎙️ recorder.startRecording() FAILED: \(error.localizedDescription)")
                status = "Microphone Error"
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func stopRecordingAndTranscribe() {
        logger.info("🎙️ stopRecordingAndTranscribe() called")
        
        let samples = recorder.stopRecording()
        isRecording = false
        status = "Processing..."
        
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
}
