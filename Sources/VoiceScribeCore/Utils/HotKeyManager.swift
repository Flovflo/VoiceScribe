import Carbon
import AppKit
import os.log

private let logger = Logger(subsystem: "com.voicescribe", category: "HotKey")


@MainActor
public class HotKeyManager {
    public static let shared = HotKeyManager()

    
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    public var onTrigger: (() -> Void)?
    
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
        
        // Install event handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                // Using a closure to capture 'shared' is tricky with C-function pointers.
                // But since HotKeyManager is singleton, we can dispatch safely.
                DispatchQueue.main.async {
                    HotKeyManager.shared.onTrigger?()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        
        if status != noErr {
            logger.error("Failed to install event handler: \(status)")
        } else {
            logger.info("HotKey registered (Code: \(keyCode), Mods: \(modifiers))")
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
    }
}
