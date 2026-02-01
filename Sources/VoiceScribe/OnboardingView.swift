import SwiftUI
import VoiceScribeCore

struct OnboardingView: View {
    @ObservedObject var appState = AppState.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("selectedModel") private var selectedModel = "mlx-community/Qwen3-ASR-1.7B-8bit"
    
    @State private var currentStep = 0
    @State private var isDownloading = false
    @State private var downloadComplete = false
    
    let models = [
        ("Fast", "0.6B", "Quick transcription", "mlx-community/Qwen3-ASR-0.6B-8bit"),
        ("Accurate", "1.7B", "Better accuracy", "mlx-community/Qwen3-ASR-1.7B-8bit")
    ]
    
    var body: some View {
        ZStack {
            // Dark glass background
            Color.black.opacity(0.85)
            
            VStack(spacing: 0) {
                // Step content
                Group {
                    switch currentStep {
                    case 0:
                        welcomeStep
                    case 1:
                        modelStep
                    case 2:
                        downloadStep
                    case 3:
                        instructionsStep
                    default:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Bottom navigation
                bottomNav
            }
        }
        .frame(width: 440, height: 520)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .onAppear {
            // Start engine in background
            Task {
                await appState.initialize()
            }
        }
    }
    
    // MARK: - Welcome Step
    
    private var welcomeStep: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Icon
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "waveform")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(.white.opacity(0.9))
            }
            
            VStack(spacing: 12) {
                Text("VoiceScribe")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)
                
                Text("Local AI transcription for your Mac")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.5))
            }
            
            // Features
            VStack(spacing: 16) {
                featureRow(icon: "cpu", text: "Powered by Apple Silicon")
                featureRow(icon: "lock.fill", text: "100% private, runs locally")
                featureRow(icon: "bolt.fill", text: "Real-time transcription")
            }
            .padding(.top, 20)
            
            Spacer()
        }
        .padding(.horizontal, 48)
    }
    
    // MARK: - Model Step
    
    private var modelStep: some View {
        VStack(spacing: 32) {
            Spacer()
            
            VStack(spacing: 12) {
                Text("Choose Model")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
                
                Text("Select based on your preference")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
            }
            
            // Model options
            VStack(spacing: 12) {
                ForEach(models, id: \.3) { model in
                    modelRow(
                        title: model.0,
                        size: model.1,
                        desc: model.2,
                        id: model.3,
                        isSelected: selectedModel == model.3
                    )
                }
            }
            .padding(.horizontal, 32)
            
            Spacer()
        }
        .padding(.horizontal, 48)
    }
    
    // MARK: - Download Step
    
    private var downloadStep: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Icon with animation
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 80, height: 80)
                
                if appState.isReady && !appState.isModelDownloading {
                    Image(systemName: "checkmark")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundColor(.green.opacity(0.9))
                } else {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                }
            }
            
            VStack(spacing: 12) {
                Text(downloadTitle)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
                
                Text(statusText)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            
            // Progress info
            if !appState.downloadProgress.isEmpty {
                Text(appState.downloadProgress)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.05))
                    )
            }
            
            // Model info
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("Model:")
                        .foregroundColor(.white.opacity(0.4))
                    Text(selectedModel.components(separatedBy: "/").last ?? selectedModel)
                        .foregroundColor(.white.opacity(0.6))
                }
                .font(.system(size: 11))
                
                if appState.nativeEngine.isModelCached && !appState.isModelDownloading {
                    Text("✓ Cached locally")
                        .font(.system(size: 10))
                        .foregroundColor(.green.opacity(0.6))
                }
            }
            .padding(.top, 16)
            
            Spacer()
        }
        .padding(.horizontal, 48)
        .onAppear {
            // Set the model when entering this step
            appState.nativeEngine.setModel(selectedModel)
        }
        .onChange(of: appState.isReady) { oldValue, newValue in
            // Auto-advance when model becomes ready
            if newValue && currentStep == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentStep = 3
                    }
                }
            }
        }
    }
    
    private var downloadTitle: String {
        if appState.isReady {
            return "Model Ready"
        } else if appState.isModelDownloading {
            return "Downloading..."
        } else if appState.nativeEngine.isModelCached {
            return "Loading Model"
        } else {
            return "Preparing Model"
        }
    }
    
    private var statusText: String {
        if appState.isReady {
            return "Model loaded and ready to use"
        } else if appState.isModelDownloading {
            return "Downloading model files..."
        } else if appState.status.contains("Loading") {
            return "Loading model into memory..."
        } else {
            return appState.status
        }
    }
    
    // MARK: - Instructions Step
    
    private var instructionsStep: some View {
        VStack(spacing: 32) {
            Spacer()
            
            VStack(spacing: 12) {
                Text("How to Use")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
                
                Text("Simple keyboard shortcut")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
            }
            
            // Shortcut display
            VStack(spacing: 24) {
                HStack(spacing: 8) {
                    keyboardKey("⌥")
                    Text("+")
                        .foregroundColor(.white.opacity(0.3))
                    keyboardKey("Space")
                }
                
                VStack(spacing: 8) {
                    Text("Press to start/stop recording")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.6))
                    
                    Text("Text will be typed automatically")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.35))
                }
            }
            .padding(.top, 8)
            
            // Steps
            VStack(alignment: .leading, spacing: 14) {
                stepRow(num: "1", text: "Press ⌥ Space anywhere")
                stepRow(num: "2", text: "Speak when HUD appears")
                stepRow(num: "3", text: "Press ⌥ Space again to stop")
            }
            .padding(.top, 16)
            
            Spacer()
        }
        .padding(.horizontal, 48)
    }
    
    // MARK: - Bottom Navigation
    
    private var bottomNav: some View {
        HStack {
            // Progress dots
            HStack(spacing: 6) {
                ForEach(0..<4) { i in
                    Circle()
                        .fill(currentStep == i ? Color.white.opacity(0.9) : Color.white.opacity(0.2))
                        .frame(width: 6, height: 6)
                }
            }
            
            Spacer()
            
            // Navigation buttons
            HStack(spacing: 12) {
                if currentStep > 0 && currentStep != 2 {
                    Button(action: { withAnimation(.easeInOut(duration: 0.2)) { currentStep -= 1 } }) {
                        Text("Back")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
                
                Button(action: handleNext) {
                    Text(nextButtonText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(nextButtonEnabled ? .white : .white.opacity(0.3))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(nextButtonEnabled ? 0.15 : 0.05))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!nextButtonEnabled)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .background(Color.white.opacity(0.02))
    }
    
    private var nextButtonText: String {
        switch currentStep {
        case 2:
            return appState.isReady ? "Continue" : "Loading..."
        case 3:
            return "Get Started"
        default:
            return "Continue"
        }
    }
    
    private var nextButtonEnabled: Bool {
        if currentStep == 2 {
            return appState.isReady
        }
        return true
    }
    
    private func handleNext() {
        if currentStep < 3 {
            withAnimation(.easeInOut(duration: 0.2)) { currentStep += 1 }
        } else {
            completeOnboarding()
        }
    }
    
    // MARK: - Helper Views
    
    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 20)
            
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.6))
            
            Spacer()
        }
    }
    
    private func modelRow(title: String, size: String, desc: String, id: String, isSelected: Bool) -> some View {
        Button(action: { selectedModel = id }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                        
                        Text(size)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.3))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white.opacity(0.05))
                            )
                    }
                    
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                }
                
                Spacer()
                
                Circle()
                    .fill(isSelected ? Color.white.opacity(0.9) : Color.clear)
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(isSelected ? 0.9 : 0.2), lineWidth: 1.5)
                    )
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(isSelected ? 0.08 : 0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(isSelected ? 0.15 : 0.05), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
    
    private func keyboardKey(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.8))
            .frame(minWidth: 44, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                    )
            )
    }
    
    private func stepRow(num: String, text: String) -> some View {
        HStack(spacing: 14) {
            Text(num)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.05))
                )
            
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.5))
        }
    }
    
    // MARK: - Actions
    
    private func completeOnboarding() {
        hasCompletedOnboarding = true
        
        // Close onboarding window via NSApp
        DispatchQueue.main.async {
            // Find and close the onboarding window
            for window in NSApplication.shared.windows {
                if window.title == "Welcome to VoiceScribe" {
                    window.close()
                    break
                }
            }
            
            // Show the main HUD
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.floatWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
