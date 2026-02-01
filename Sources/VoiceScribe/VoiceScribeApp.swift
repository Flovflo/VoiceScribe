import SwiftUI
import AppKit
import VoiceScribeCore

@main
struct VoiceScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {

        WindowGroup {
            GlassView()
                .edgesIgnoringSafeArea(.all)
        }



        .windowStyle(.hiddenTitleBar)
    }
}

// Custom window that accepts clicks even when borderless
class ClickableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    
    func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}


@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var floatWindow: ClickableWindow?
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    var onboardingWindow: NSWindow?
    
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Close any SwiftUI-created windows
        for window in NSApplication.shared.windows {
            window.close()
        }
        
        // Create our own clickable window
        let window = ClickableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        let hostingView = NSHostingView(rootView: GlassView())
        window.contentView = hostingView
        
        floatWindow = window
        configureWindow(window)
        
        // Show onboarding on first launch, otherwise show HUD
        if !hasCompletedOnboarding {
            showOnboarding()
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        
        setupStatusItem()
        
        // Register Option+Space
        HotKeyManager.shared.register(keyCode: 49, modifiers: 2048)
        HotKeyManager.shared.onTrigger = { [weak self] in
            self?.toggleApp()
        }
    }
    
    func showOnboarding() {
        if onboardingWindow == nil {
            let onboardingView = NSHostingView(rootView: OnboardingView())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 450),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.center()
            window.title = "Welcome to VoiceScribe"
            window.isReleasedWhenClosed = false
            window.contentView = onboardingView
            window.level = .floating
            window.hasShadow = true
            onboardingWindow = window
        }
        
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "VoiceScribe")
            button.toolTip = "VoiceScribe - Option+Space"
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show HUD & Record", action: #selector(toggleApp), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit VoiceScribe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    func configureWindow(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.borderless]
        window.level = .floating 
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.hasShadow = false
        window.acceptsMouseMovedEvents = true
        
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let x = (screenRect.width - 450) / 2
            let y = screenRect.height * 0.85
            window.setFrame(NSRect(x: x, y: y, width: 450, height: 80), display: true)
        }
    }
    
    @objc func toggleApp() {
        guard let window = floatWindow else { return }
        
        if window.isVisible {
            if AppState.shared.isRecording {
                AppState.shared.toggleRecording()
            } else {
                window.orderOut(nil)
            }
        } else {
            if let screen = NSScreen.main {
                let screenRect = screen.visibleFrame
                let x = (screenRect.width - 450) / 2
                let y = screenRect.height * 0.85
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            AppState.shared.toggleRecording()
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let contentView = NSHostingView(rootView: SettingsView())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 320),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.center()
            window.title = "VoiceScribe Settings"
            window.isReleasedWhenClosed = false
            window.contentView = contentView
            window.level = .floating // Keep settings on top
            settingsWindow = window
        }
        
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        HStack(spacing: 20) {
            // Left Status Indicator
            ZStack {
                if appState.isRecording {
                    Circle()
                        .stroke(Color.red.opacity(0.3), lineWidth: 4)
                        .scaleEffect(1.2 + CGFloat(appState.audioLevel) * 2.0)
                        .opacity(0.5 - Double(appState.audioLevel))
                    
                    Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                        .shadow(color: .red.opacity(0.5), radius: 4)
                } else {
                    Circle()
                        .fill(appState.isReady ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                }
            }
            .frame(width: 30, height: 30)
            
            // Textual Info
            VStack(alignment: .leading, spacing: 2) {
                if appState.isRecording {
                    Text("LISTENING")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.red.opacity(0.8))
                }
                
                Text(appState.status)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                if !appState.isRecording {
                    Text("Model: Qwen3-ASR (Native MLX)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                }
                
                if appState.status.contains("Loading") || appState.status.contains("Downloading") {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .scaleEffect(0.5, anchor: .leading)
                        .frame(height: 2)
                        .padding(.top, 4)
                }
            }
            
            Spacer()
            
            // Right Side: Visualizer or Controls
            if appState.isRecording {
                HStack(spacing: 3) {
                    ForEach(0..<12) { _ in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.8))
                            .frame(width: 3, height: 8 + CGFloat(appState.audioLevel) * 30 * CGFloat.random(in: 0.3...1.7))
                            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.5), value: appState.audioLevel)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    // Just show keyboard shortcut hint and CPU badge
                    Text("⌥ Space")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.1))
                        )
                    
                    Image(systemName: "cpu")
                        .font(.system(size: 12))
                        .foregroundColor(.green.opacity(0.8))
                        .help("Apple Silicon Optimized")
                }
            }
        }

        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        .frame(width: 450, height: 80)
        .onAppear {

            Task { await appState.initialize() }
        }
        .onChange(of: appState.transcript) { oldValue, newText in
            if !newText.isEmpty && !appState.isRecording {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    NSApp.windows.first?.orderOut(nil)
                    appState.clearTranscript()
                }
            }
        }
    }
}

