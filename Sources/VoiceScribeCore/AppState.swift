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
    @Published public var downloadProgress: String = ""
    @Published public var errorMessage: String?
    
    // MARK: - Services
    public let recorder = AudioRecorder()
    public let pythonService = PythonASRService()
    public let asrModel: ASRModel
    
    private var cancellables = Set<AnyCancellable>()
    
    public init() {
        logger.info("🔧 AppState init")
        self.asrModel = ASRModel(service: pythonService)
        setupBindings()
        logger.info("🔧 AppState init complete")
    }
    
    private func setupBindings() {
        recorder.$audioLevel
            .receive(on: DispatchQueue.main)
            .assign(to: \.audioLevel, on: self)
            .store(in: &cancellables)
        
        pythonService.$status
            .receive(on: DispatchQueue.main)
            .assign(to: \.status, on: self)
            .store(in: &cancellables)
        
        pythonService.$isReady
            .receive(on: DispatchQueue.main)
            .assign(to: \.isReady, on: self)
            .store(in: &cancellables)
        
        pythonService.$downloadProgress
            .receive(on: DispatchQueue.main)
            .map { !$0.isEmpty }
            .assign(to: \.isModelDownloading, on: self)
            .store(in: &cancellables)
        
        pythonService.$downloadProgress
            .receive(on: DispatchQueue.main)
            .assign(to: \.downloadProgress, on: self)
            .store(in: &cancellables)
        
        pythonService.$lastError
            .receive(on: DispatchQueue.main)
            .assign(to: \.errorMessage, on: self)
            .store(in: &cancellables)
    }
    
    // MARK: - Lifecycle
    

    public func initialize() async {
        logger.info("🔧 initialize() called")
        status = "Starting ASR Engine..."
        await pythonService.startEngine()
        
        // Sync model preference
        let savedModel = UserDefaults.standard.string(forKey: "selectedModel") ?? "mlx-community/Qwen3-ASR-1.7B-8bit"
        if savedModel != "mlx-community/Qwen3-ASR-1.7B-8bit" { // Optimization: Python defaults to 1.7B, only send if different or force it
             pythonService.setModel(savedModel)
        }
        
        logger.info("🔧 initialize() complete")
    }

    
    public func shutdown() {
        logger.info("🔧 shutdown() called")
        pythonService.stopEngine()
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
            logger.info("🎙️ Calling asrModel.transcribe()...")
            let text = await asrModel.transcribe(samples: samples)
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
                
                // Hide window logic should be handled by View/Delegate observing this state
            }
            
            try? await Task.sleep(for: .seconds(2))
            if !isRecording {
                status = isReady ? "Ready" : "Waiting..."
                if !text.isEmpty {
                    transcript = "" // Clear for next time
                }
            }
        }
    }
    
    public func clearTranscript() {
        transcript = ""
    }
}
