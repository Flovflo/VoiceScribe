import SwiftUI
import VoiceScribeCore
import os.log

private let logger = Logger(subsystem: "com.voicescribe", category: "App")

@main
struct VoiceScribeApp: App {
    @StateObject private var appState = AppState()
    
    init() {
        logger.info("🚀 VoiceScribeApp init")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task {
                    logger.info("🚀 Running async init task")
                    await appState.initialize()
                    logger.info("🚀 Init complete")
                }
                .onDisappear {
                    logger.info("🚀 Window disappearing")
                    appState.shutdown()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            Divider()
            
            VStack(spacing: 20) {
                StatusView()
                RecordButton()
                TranscriptView()
            }
            .padding(20)
        }
        .frame(width: 380, height: 480)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            logger.info("📱 ContentView appeared")
        }
    }
}

// MARK: - Header

struct HeaderView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        HStack {
            Image(systemName: "waveform.circle.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            
            Text("VoiceScribe")
                .font(.headline)
            
            Spacer()
            
            Circle()
                .fill(appState.isReady ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Status View

struct StatusView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 8) {
            Text(appState.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            
            if appState.isModelDownloading {
                ProgressView()
                    .scaleEffect(0.8)
                Text(appState.downloadProgress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            if let error = appState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
            }
        }
    }
}

// MARK: - Record Button

struct RecordButton: View {
    @EnvironmentObject var appState: AppState
    @State private var isPulsing = false
    
    private let logger = Logger(subsystem: "com.voicescribe", category: "RecordButton")
    
    var body: some View {
        Button {
            logger.info("🎤 Record button tapped, isRecording=\(appState.isRecording)")
            appState.toggleRecording()
        } label: {
            ZStack {
                if appState.isRecording {
                    Circle()
                        .fill(Color.red.opacity(0.3))
                        .frame(width: 100, height: 100)
                        .scaleEffect(isPulsing ? 1.2 : 1.0)
                        .opacity(isPulsing ? 0 : 0.5)
                }
                
                Circle()
                    .fill(appState.isRecording ? Color.red : (appState.isReady ? Color.blue : Color.gray))
                    .frame(width: 80, height: 80)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                
                Image(systemName: appState.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(!appState.isReady && !appState.isRecording)
        .onChange(of: appState.isRecording) { _, isRecording in
            if isRecording {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            } else {
                isPulsing = false
            }
        }
        
        if appState.isRecording {
            HStack(spacing: 3) {
                ForEach(0..<12, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i < 8 ? Color.green : (i < 10 ? Color.yellow : Color.red))
                        .frame(width: 6, height: 4 + CGFloat(i) * 1.5)
                }
            }
            .frame(height: 30)
        }
    }
}

// MARK: - Transcript View

struct TranscriptView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transcription")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                if !appState.transcript.isEmpty {
                    Button {
                        appState.copyToClipboard()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        appState.clearTranscript()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            
            ScrollView {
                Text(appState.transcript.isEmpty ? "Press the button and speak..." : appState.transcript)
                    .font(.body)
                    .foregroundStyle(appState.transcript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 150)
            .padding(12)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
