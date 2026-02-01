import SwiftUI
import VoiceScribeCore

@main
struct VoiceScribeApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 16) {
            // Status
            HStack {
                Circle()
                    .fill(appState.isReady ? .green : .orange)
                    .frame(width: 8, height: 8)
                Text(appState.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            
            // Transcript
            if !appState.transcript.isEmpty {
                ScrollView {
                    Text(appState.transcript)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
            
            Spacer()
            
            // Record button
            Button(action: { appState.toggleRecording() }) {
                HStack {
                    Image(systemName: appState.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.title)
                    Text(appState.isRecording ? "Stop" : "Record")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!appState.isReady)
            
            // Audio level
            if appState.isRecording {
                ProgressView(value: Double(appState.audioLevel))
                    .tint(.red)
            }
        }
        .padding()
        .frame(width: 320, height: 280)
        .onAppear {
            Task { await appState.initialize() }
        }
    }
}
