import SwiftUI
import AppKit
import VoiceScribeCore

@main
struct VoiceScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Window("VoiceScribe HUD", id: "hud-window") {
            GlassView()
                .frame(width: GlassView.hudWidth, height: GlassView.hudHeight)
                .background(Color.clear)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            // Disable default commands to avoid "New Window" options being easily accessible if not desired
            CommandGroup(replacing: .newItem) { }
        }
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
    static let hudWindowIdentifier = NSUserInterfaceItemIdentifier("VoiceScribeHUDWindow")

    var floatWindow: NSWindow?
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    var onboardingWindow: NSWindow?
    private var isToggleInFlight = false
    private var lastToggleUptime: TimeInterval = -Double.greatestFiniteMagnitude
    private let toggleCooldown: TimeInterval = 0.35
    
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep this menu-bar/HUD style app alive even when no standard window is visible.
        ProcessInfo.processInfo.disableAutomaticTermination("VoiceScribe background service")
        ProcessInfo.processInfo.disableSuddenTermination()
        
        setupStatusItem()
        
        // Register Option+Space
        HotKeyManager.shared.register(keyCode: 49, modifiers: 2048)
        HotKeyManager.shared.onTrigger = { [weak self] in
            self?.toggleApp()
        }

        // Wait for SwiftUI WindowGroup window, then attach HUD behavior to it.
        DispatchQueue.main.async { [weak self] in
            _ = self?.attachMainWindowIfNeeded()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func handleAppDidBecomeActive() {
        guard let window = attachMainWindowIfNeeded() else { return }
        collapseDuplicateHUDWindows(keeping: window)
        window.level = .floating
    }

    @discardableResult
    private func attachMainWindowIfNeeded() -> NSWindow? {
        if let existing = floatWindow {
            configureWindow(existing)
            return existing
        }

        let hudWindows = findHUDWindows()
        guard let window = hudWindows.first else { return nil }

        floatWindow = window
        configureWindow(window)
        collapseDuplicateHUDWindows(keeping: window)

        if !hasCompletedOnboarding {
            window.orderOut(nil)
            showOnboarding()
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        return window
    }

    private func findHUDWindows() -> [NSWindow] {
        let candidates = NSApplication.shared.windows.filter { window in
            window != onboardingWindow && window != settingsWindow
        }

        let identified = candidates.filter { $0.identifier == Self.hudWindowIdentifier }
        if !identified.isEmpty {
            return identified
        }

        let sized = candidates.filter { window in
            abs(window.frame.width - GlassView.hudWidth) < 2
                && abs(window.frame.height - GlassView.hudHeight) < 2
        }
        if !sized.isEmpty {
            return sized
        }

        return candidates
    }

    private func collapseDuplicateHUDWindows(keeping primary: NSWindow) {
        for window in findHUDWindows() where window != primary {
            window.orderOut(nil)
            window.close()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        ProcessInfo.processInfo.enableAutomaticTermination("VoiceScribe background service")
        ProcessInfo.processInfo.enableSuddenTermination()
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
        window.identifier = Self.hudWindowIdentifier
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
        window.setContentSize(NSSize(width: GlassView.hudWidth, height: GlassView.hudHeight))
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let x = (screenRect.width - GlassView.hudWidth) / 2
            let y = screenRect.height * 0.85
            window.setFrame(
                NSRect(x: x, y: y, width: GlassView.hudWidth, height: GlassView.hudHeight),
                display: true
            )
        }
    }
    
    @objc func toggleApp() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !isToggleInFlight else { return }
        guard (now - lastToggleUptime) >= toggleCooldown else { return }
        isToggleInFlight = true
        defer {
            isToggleInFlight = false
            lastToggleUptime = now
        }

        guard let window = attachMainWindowIfNeeded() else { return }
        collapseDuplicateHUDWindows(keeping: window)
        let appState = AppState.shared
        let recordingActive = appState.isRecording || appState.isStartingRecording

        if window.isVisible {
            if recordingActive {
                appState.toggleRecording()
            } else {
                window.orderOut(nil)
            }
        } else {
            if let screen = NSScreen.main {
                let screenRect = screen.visibleFrame
                let x = (screenRect.width - GlassView.hudWidth) / 2
                let y = screenRect.height * 0.85
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if !recordingActive {
                appState.toggleRecording()
            }
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let contentView = NSHostingView(rootView: SettingsView())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
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
    static let hudWidth: CGFloat = 460
    static let hudHeight: CGFloat = 88

    @ObservedObject var appState = AppState.shared
    
    private var accentColor: Color {
        if appState.isRecording {
            return .red
        }
        return appState.isReady ? .green : .orange
    }
    
    private var titleText: String {
        if appState.isRecording {
            return "Recording"
        }
        if appState.status.lowercased().contains("error") {
            return "Attention"
        }
        return "VoiceScribe"
    }

    private var clampedAudioLevel: CGFloat {
        max(0, min(1, CGFloat(appState.audioLevel)))
    }

    private var displayStatusText: String {
        var text = appState.status
            .replacingOccurrences(of: "🎤 ", with: "")
            .replacingOccurrences(of: "✅ ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("Ready:") {
            return "Ready"
        }
        if text.hasPrefix("Error:") {
            text = text.replacingOccurrences(of: "Error: ", with: "")
        }
        return text
    }
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.86))

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)

            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.2))
                        .frame(width: 28, height: 28)
                    Circle()
                        .fill(accentColor)
                        .frame(width: 9, height: 9)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(titleText.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))

                    Text(displayStatusText)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white.opacity(0.96))
                        .lineLimit(1)

                    if appState.status.contains("Loading") || appState.status.contains("Downloading") {
                        ProgressView(value: appState.downloadProgress)
                            .progressViewStyle(.linear)
                            .tint(accentColor)
                            .frame(width: 180)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 7) {
                    if appState.isRecording {
                        Text("REC")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(accentColor.opacity(0.96))

                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.14))
                            Capsule()
                                .fill(accentColor.opacity(0.95))
                                .frame(width: max(10, 76 * clampedAudioLevel))
                                .animation(.linear(duration: 0.08), value: clampedAudioLevel)
                        }
                        .frame(width: 76, height: 8)
                    } else {
                        Text("⌥ Space")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.14))
                            )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: Self.hudWidth, height: Self.hudHeight)
        .background(Color.clear)
        .onAppear {

            Task { await appState.initialize() }
        }
        .onChange(of: appState.transcript) { oldValue, newText in
            if !newText.isEmpty && !appState.isRecording {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    for window in NSApp.windows where window.identifier == AppDelegate.hudWindowIdentifier {
                        window.orderOut(nil)
                    }
                    appState.clearTranscript()
                }
            }
        }
    }
}
