import Cocoa
import CoreGraphics
import os.log

private let logger = Logger(subsystem: "com.voicescribe", category: "InputInjector")

public class InputInjector {
    
    public static func pasteFromClipboard() {
        logger.info("Simulating Cmd+V...")
        
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Command key code = 55 (Left Cmd)
        // V key code = 9
        
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false)
        
        // Set flags for Cmd+V
        cmdDown?.flags = .maskCommand
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        cmdUp?.flags = .maskCommand // keep flag on release of V? usually safer to clear on cmdUp
        
        let loc = CGEventTapLocation.cghidEventTap
        
        cmdDown?.post(tap: loc)
        vDown?.post(tap: loc)
        vUp?.post(tap: loc)
        cmdUp?.post(tap: loc)
        
        logger.info("Cmd+V posted")
    }
}
