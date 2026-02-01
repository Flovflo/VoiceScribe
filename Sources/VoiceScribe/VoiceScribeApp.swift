import SwiftUI
import VoiceScribeCore
import os.log

private let logger = Logger(subsystem: "com.voicescribe", category: "App")

@main
struct VoiceScribeApp: App {
    @StateObject private var appState = AppState()
    
    init() {
        logger.info("VoiceScribeApp init")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(red: 0.1, green: 0.1, blue: 0.15),
                    Color(red: 0.05, green: 0.05, blue: 0.1)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            // Ambient light blobs
            GeometryReader { geo in
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 200, height: 200)
                    .blur(radius: 80)
                    .offset(x: geo.size.width * 0.6, y: -50)
                
                Circle()
                    .fill(Color.purple.opacity(0.1))
                    .frame(width: 150, height: 150)
                    .blur(radius: 60)
                    .offset(x: -50, y: geo.size.height * 0.7)
            }
            
            // Main content
            VStack(spacing: 24) {
                // Header
                Text("VoiceScribe")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, .white.opacity(0.7)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                
                // Status card
                StatusCard(status: appState.status, isReady: appState.isReady)
                
                // Record button
                RecordButton(
                    isRecording: appState.isRecording,
                    audioLevel: appState.audioLevel,
                    isReady: appState.isReady
                ) {
                    appState.toggleRecording()
                }
                
                // Transcript card
                if !appState.transcript.isEmpty {
                    TranscriptCard(text: appState.transcript) {
                        appState.copyToClipboard()
                    }
                }
            }
            .padding(32)
            .frame(width: 380)
        }
        .frame(minWidth: 380, minHeight: 400)
        .onAppear {
            Task {
                await appState.initialize()
            }
        }
    }
}

// MARK: - Liquid Glass Components

struct GlassCard<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
            .background(
                ZStack {
                    // Base glass
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.ultraThinMaterial)
                    
                    // Inner glow
                    RoundedRectangle(cornerRadius: 20)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.1),
                                    .clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    // Border highlight
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.3),
                                    .white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            )
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
    }
}

struct StatusCard: View {
    let status: String
    let isReady: Bool
    
    var body: some View {
        GlassCard {
            HStack(spacing: 12) {
                // Status indicator
                Circle()
                    .fill(isReady ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                    .shadow(color: isReady ? .green : .orange, radius: 4)
                
                Text(status)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }
}

struct RecordButton: View {
    let isRecording: Bool
    let audioLevel: Float
    let isReady: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            ZStack {
                // Outer glow when recording
                if isRecording {
                    Circle()
                        .fill(Color.red.opacity(0.3))
                        .frame(width: 100 + CGFloat(audioLevel) * 40, height: 100 + CGFloat(audioLevel) * 40)
                        .blur(radius: 20)
                }
                
                // Main button
                Circle()
                    .fill(
                        LinearGradient(
                            colors: isRecording 
                                ? [Color.red, Color.red.opacity(0.7)]
                                : [Color.blue, Color.blue.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.4), .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                    )
                    .shadow(color: isRecording ? .red.opacity(0.5) : .blue.opacity(0.5), radius: 15, y: 5)
                
                // Icon
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isReady)
        .opacity(isReady ? 1 : 0.5)
        .animation(.spring(response: 0.3), value: isRecording)
        .animation(.easeOut(duration: 0.1), value: audioLevel)
    }
}

struct TranscriptCard: View {
    let text: String
    let onCopy: () -> Void
    
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Transcription")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                    
                    Spacer()
                    
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                
                Text(text)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
            }
            .padding(20)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
