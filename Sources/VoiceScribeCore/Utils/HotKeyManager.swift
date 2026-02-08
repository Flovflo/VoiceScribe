import Carbon
import AppKit
import os.log

private let logger = Logger(subsystem: "com.voicescribe", category: "HotKey")

struct HotKeyTriggerGate {
    private(set) var lastTriggerUptime: TimeInterval = -Double.greatestFiniteMagnitude
    let cooldown: TimeInterval

    init(cooldown: TimeInterval = 0.35) {
        self.cooldown = cooldown
    }

    mutating func allowsTrigger(now: TimeInterval) -> Bool {
        if (now - lastTriggerUptime) < cooldown {
            return false
        }
        lastTriggerUptime = now
        return true
    }
}

struct HotKeyPressState {
    let cooldown: TimeInterval
    private(set) var isPressed: Bool = false
    private var gate: HotKeyTriggerGate

    init(cooldown: TimeInterval = 0.35) {
        self.cooldown = cooldown
        self.gate = HotKeyTriggerGate(cooldown: cooldown)
    }

    mutating func shouldTrigger(for kind: UInt32, now: TimeInterval) -> Bool {
        switch kind {
        case UInt32(kEventHotKeyPressed):
            guard !isPressed else { return false }
            isPressed = true
            return gate.allowsTrigger(now: now)
        case UInt32(kEventHotKeyReleased):
            isPressed = false
            return false
        default:
            return false
        }
    }

    mutating func reset() {
        isPressed = false
        gate = HotKeyTriggerGate(cooldown: cooldown)
    }
}

@MainActor
public class HotKeyManager {
    public static let shared = HotKeyManager()

    
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    public var onTrigger: (() -> Void)?
    private var pressState = HotKeyPressState()
    
    // Default: Option + Space
    // 49 = Space
    // 2048 = Option (cmdKey=256, shiftKey=512, optionKey=2048, controlKey=4096)
    
    public func register(keyCode: UInt32 = 49, modifiers: UInt32 = 2048) {
        unregister()
        
        let hotKeyID = EventHotKeyID(signature: 0x564F4943, id: 1) // "VOIC", 1
        
        var status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        
        if status != noErr {
            logger.error("Failed to register hotkey: \(status)")
            return
        }
        
        // Install event handlers for key press and release to avoid key-repeat retriggers.
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        
        status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return noErr }
                let kind = GetEventKind(event)
                DispatchQueue.main.async {
                    HotKeyManager.shared.handleHotKeyEvent(kind: kind)
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            nil,
            &eventHandler
        )
        
        if status != noErr {
            logger.error("Failed to install event handler: \(status)")
        } else {
            logger.info("HotKey registered (Code: \(keyCode), Mods: \(modifiers))")
        }
    }

    private func handleHotKeyEvent(kind: UInt32, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // Carbon can emit repeats while key is held; the state gate allows
        // only one trigger per press+release cycle and enforces cooldown.
        if pressState.shouldTrigger(for: kind, now: now) {
            onTrigger?()
        }
    }
    
    public func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        pressState.reset()
    }
}
