import SwiftUI
import AppKit
import VoiceScribeCore

@main
struct VoiceScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            GlassView()
                .environmentObject(AppState.shared)
                .edgesIgnoringSafeArea(.all)
                .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow))
        }

        .windowStyle(.hiddenTitleBar)
        
        Settings {
            SettingsView()
        }
    }
}



@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var floatWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep dock icon for now, easy to quit
        
        if let window = NSApplication.shared.windows.first {
            floatWindow = window
            configureWindow(window)
        }
        
        // Register Option+Space (Default)
        // Note: Accessibility permissions needed for key events
        HotKeyManager.shared.register(keyCode: 49, modifiers: 2048) // Option + Space
        HotKeyManager.shared.onTrigger = { [weak self] in
            self?.toggleApp()
        }
    }
    
    func configureWindow(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.styleMask = [.borderless, .nonactivatingPanel] 
        window.level = .floating 
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.hasShadow = false
        
        // Center top
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let windowRect = window.frame
            let x = (screenRect.width - windowRect.width) / 2
            let y = (screenRect.height - windowRect.height) / 2 + screenRect.height * 0.15
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
    
    func toggleApp() {
        guard let window = floatWindow else { return }
        
        if window.isVisible {
            // Check if recording
            if AppState.shared.isRecording {
                AppState.shared.toggleRecording()
            } else {
                window.orderOut(nil)
            }
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            AppState.shared.toggleRecording()
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 24
        view.layer?.masksToBounds = true
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct GlassView: View {
    @ObservedObject var appState = AppState.shared
    
    var body: some View {
        HStack(spacing: 16) {
            // Indicator
            ZStack {
                Circle()
                    .fill(appState.isRecording ? Color.red : Color.secondary.opacity(0.5))
                    .frame(width: 14, height: 14)
                
                if appState.isRecording {
                    Circle()
                        .stroke(Color.red.opacity(0.6), lineWidth: 2)
                        .frame(width: 24, height: 24)
                        .scaleEffect(appState.audioLevel > 0.05 ? 1.3 : 1.0)
                        .opacity(appState.audioLevel > 0.05 ? 0.0 : 1.0)
                        .animation(.easeOut(duration: 0.8).repeatForever(autoreverses: false), value: appState.audioLevel)
                }
            }
            .frame(width: 24, height: 24)
            
            if appState.isRecording {
                Text("Listening...")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            } else {
                Text(appState.status)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
            }
            
            Spacer()
            
            // Visualizer
            if appState.isRecording {
                HStack(spacing: 3) {
                    ForEach(0..<8) { _ in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.8))
                            .frame(width: 4, height: 10 + CGFloat(appState.audioLevel) * 25 * CGFloat.random(in: 0.5...1.5))
                            .animation(.easeOut(duration: 0.1), value: appState.audioLevel)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color.black.opacity(0.1))
        .cornerRadius(30)
        .overlay(
            RoundedRectangle(cornerRadius: 30)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.3), .white.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ), lineWidth: 1
                )
        )
        .frame(width: 320)
        .onAppear {
            Task { await appState.initialize() }
        }
        .onChange(of: appState.transcript) { oldValue, newText in
            if !newText.isEmpty && !appState.isRecording {
                // Hide window after short delay to show "Copied" status
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    NSApp.windows.first?.orderOut(nil)
                    appState.clearTranscript()
                }
            }
        }
    }
}
