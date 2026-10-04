import SwiftUI
import AppKit
import VoiceScribeCore

@main
struct VoiceScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

// A dictation overlay must leave the keyboard focus in the destination app.
class ClickableWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}


@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static let hudWindowIdentifier = NSUserInterfaceItemIdentifier("VoiceScribeHUDWindow")
    static let onboardingWindowIdentifier = NSUserInterfaceItemIdentifier("VoiceScribeOnboardingWindow")

    var floatWindow: NSWindow?
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    var onboardingWindow: NSWindow?
    private var isToggleInFlight = false
    private var lastToggleUptime: TimeInterval = -Double.greatestFiniteMagnitude
    private let toggleCooldown: TimeInterval = 0.35
    private var didBecomeActiveObserver: NSObjectProtocol?
    
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep this menu-bar/HUD style app alive even when no standard window is visible.
        ProcessInfo.processInfo.disableAutomaticTermination("VoiceScribe background service")
        ProcessInfo.processInfo.disableSuddenTermination()
        finishLaunchingOnMain()
    }

    @MainActor
    private func finishLaunchingOnMain() {
        setupStatusItem()

        // Register Option+Space
        HotKeyManager.shared.register(keyCode: 49, modifiers: 2048)
        HotKeyManager.shared.onTrigger = { [weak self] in
            Task { @MainActor [weak self] in
                self?.toggleApp()
            }
        }

        // Own one nonactivating HUD panel, independent of SwiftUI settings windows.
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = self.attachMainWindowIfNeeded()
        }

        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppDidBecomeActive()
            }
        }
    }

    @MainActor
    private func handleAppDidBecomeActive() {
        guard let window = attachMainWindowIfNeeded() else { return }
        collapseDuplicateHUDWindows(keeping: window)
        window.level = .floating
    }

    @MainActor
    @discardableResult
    private func attachMainWindowIfNeeded() -> NSWindow? {
        if let existing = floatWindow {
            return existing
        }

        let window = ClickableWindow(
            contentRect: NSRect(x: 0, y: 0, width: GlassView.hudWidth, height: GlassView.hudHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.contentView = NSHostingView(rootView: GlassView())

        floatWindow = window
        configureWindow(window)
        collapseDuplicateHUDWindows(keeping: window)

        if !hasCompletedOnboarding {
            window.orderOut(nil)
            showOnboarding()
        } else {
            window.orderFrontRegardless()
        }
        return window
    }

    @MainActor
    private func findHUDWindows() -> [NSWindow] {
        let excludedWindowIDs = Set(
            [onboardingWindow, settingsWindow]
                .compactMap { $0 }
                .map(ObjectIdentifier.init)
        )

        return NSApplication.shared.windows.filter {
            !excludedWindowIDs.contains(ObjectIdentifier($0))
                && $0.identifier == Self.hudWindowIdentifier
        }
    }

    @MainActor
    private func collapseDuplicateHUDWindows(keeping primary: NSWindow) {
        for window in findHUDWindows() where window !== primary {
            window.orderOut(nil)
            window.close()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
            self.didBecomeActiveObserver = nil
        }
        AppState.shared.shutdown()
        ProcessInfo.processInfo.enableAutomaticTermination("VoiceScribe background service")
        ProcessInfo.processInfo.enableSuddenTermination()
    }
    
    @MainActor
    func showOnboarding() {
        if onboardingWindow == nil {
            let onboardingView = NSHostingView(
                rootView: OnboardingView(
                    finishOnboarding: { [weak self] in
                        self?.completeOnboarding()
                    }
                )
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.center()
            window.title = "Welcome to VoiceScribe"
            window.identifier = Self.onboardingWindowIdentifier
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.contentView = onboardingView
            window.level = .floating
            window.hasShadow = true
            onboardingWindow = window
        }
        
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    func completeOnboarding() {
        hasCompletedOnboarding = true
        dismissOnboardingWindows()

        Task { await AppState.shared.initialize() }

        if let window = attachMainWindowIfNeeded() {
            window.orderFrontRegardless()
        } else {
            floatWindow?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func dismissOnboardingWindows() {
        let candidates = NSApp.windows.filter {
            $0 === onboardingWindow
                || $0.identifier == Self.onboardingWindowIdentifier
                || $0.title == "Welcome to VoiceScribe"
        }

        for window in candidates {
            window.orderOut(nil)
            window.close()
        }

        onboardingWindow = nil
    }
    
    @MainActor
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "VoiceScribe")
            button.toolTip = "VoiceScribe - Option+Space"
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show HUD & Record", action: #selector(toggleAppAction(_:)), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettingsAction(_:)), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Privacy Policy", action: #selector(openPrivacyPolicyAction(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Support", action: #selector(openSupportAction(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit VoiceScribe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    @MainActor
    func configureWindow(_ window: NSWindow) {
        let isNewHUD = window.identifier != Self.hudWindowIdentifier
        window.identifier = Self.hudWindowIdentifier
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.borderless, .nonactivatingPanel]
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

        if isNewHUD, let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let origin = Self.hudOrigin(in: screenRect)
            window.setFrame(
                NSRect(origin: origin, size: NSSize(width: GlassView.hudWidth, height: GlassView.hudHeight)),
                display: true
            )
        }
    }

    static func hudOrigin(in screenRect: NSRect) -> NSPoint {
        NSPoint(
            x: screenRect.midX - GlassView.hudWidth / 2,
            y: screenRect.minY + max(0, screenRect.height - GlassView.hudHeight) * 0.85
        )
    }

    @objc private func toggleAppAction(_ sender: Any?) {
        toggleApp()
    }

    @MainActor
    func toggleApp() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !isToggleInFlight else { return }
        guard (now - lastToggleUptime) >= toggleCooldown else { return }
        isToggleInFlight = true
        defer {
            isToggleInFlight = false
            lastToggleUptime = now
        }

        guard let window = attachMainWindowIfNeeded() else { return }
        guard hasCompletedOnboarding else {
            showOnboarding()
            return
        }
        collapseDuplicateHUDWindows(keeping: window)
        let appState = AppState.shared
        let action = HotKeyTogglePolicy().action(windowVisible: window.isVisible)
        if action == .showHUDThenToggleRecording {
            if let screen = NSScreen.main {
                let screenRect = screen.visibleFrame
                window.setFrameOrigin(Self.hudOrigin(in: screenRect))
            }
            window.orderFrontRegardless()
        }

        // Hotkey semantic: always toggle recording state (start/stop),
        // never hide the HUD while idle.
        appState.toggleRecording()
    }

    @objc private func openSettingsAction(_ sender: Any?) {
        openSettings()
    }

    @objc private func openPrivacyPolicyAction(_ sender: Any?) {
        NSWorkspace.shared.open(AppLinks.privacyPolicy)
    }

    @objc private func openSupportAction(_ sender: Any?) {
        NSWorkspace.shared.open(AppLinks.support)
    }

    @MainActor
    func openSettings() {
        if settingsWindow == nil {
            let contentView = NSHostingView(rootView: SettingsView())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
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

    @ObservedObject private var appState = AppState.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var transcriptAutoHideTask: Task<Void, Never>?
    
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
            startInitializationIfNeeded()
        }
        .onChange(of: hasCompletedOnboarding) { _, newValue in
            guard newValue else { return }
            startInitializationIfNeeded()
        }
        .onChange(of: appState.transcript) { oldValue, newText in
            transcriptAutoHideTask?.cancel()
            guard !newText.isEmpty, !appState.isRecording else {
                transcriptAutoHideTask = nil
                return
            }

            transcriptAutoHideTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled,
                      !appState.isRecording,
                      appState.transcript == newText else {
                    transcriptAutoHideTask = nil
                    return
                }

                for window in NSApp.windows where window.identifier == AppDelegate.hudWindowIdentifier {
                    window.orderOut(nil)
                }
                appState.clearTranscript()
                transcriptAutoHideTask = nil
            }
        }
        .onDisappear {
            transcriptAutoHideTask?.cancel()
            transcriptAutoHideTask = nil
        }
    }

    private func startInitializationIfNeeded() {
        guard hasCompletedOnboarding else { return }
        Task { await appState.initialize() }
    }
}
