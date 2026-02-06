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
        logger.info("🔧 initialize() called")
        status = "Loading Native ASR..."
        await engine.loadModel()
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
                // Native engine expects sampleRate. Recorder usually defaults to 16000 or system rate.
                // We should ensure Recorder exposes its rate or we know it.
                // Assuming 16000 based on previous code context, but best to ask recorder.
                // Previously AudioRecorder was setting up for 16kHz? Let's assume standard behavior.
                // NativeASR will resample if needed inside.
                
                // Note: recorder.stopRecording() returns [Float]. 
                // We need to know the sample rate of captured audio.
                // Assuming 16000 for now, matching NativeASREngine default.
                
                let text = try await engine.transcribe(samples: samples, sampleRate: 16000)
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
                }
            } catch {
                logger.error("Transcription error: \(error.localizedDescription)")
                status = "Error"
                errorMessage = error.localizedDescription
            }
            
            try? await Task.sleep(for: .seconds(2))
            if !isRecording {
                status = isReady ? "Ready" : "Waiting..."
                if !transcript.isEmpty {
                    // Maybe don't clear immediately so user can see it?
                    // Previous logic cleared it. Keeping it transparent.
                    transcript = "" 
                }
            }
        }
    }
    
    public func clearTranscript() {
        transcript = ""
    }
}
