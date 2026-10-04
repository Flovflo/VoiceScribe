import XCTest
import AppKit
@testable import VoiceScribe

@MainActor
final class HUDWindowTests: XCTestCase {
    func testHUDPlacementIncludesSecondaryScreenOrigin() {
        let origin = AppDelegate.hudOrigin(in: NSRect(x: -1920, y: 120, width: 1920, height: 1080))
        XCTAssertEqual(origin.x, -1190, accuracy: 0.01)
        XCTAssertEqual(origin.y, 963.2, accuracy: 0.01)
    }

    func testHUDDoesNotTakeKeyboardFocusFromDictationTarget() {
        let panel = ClickableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 88),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        let delegate = AppDelegate()
        delegate.configureWindow(panel)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        panel.close()
    }

    func testConfiguringExistingHUDPreservesItsUserPosition() {
        let panel = ClickableWindow(
            contentRect: NSRect(x: 110, y: 220, width: 460, height: 88),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        panel.identifier = AppDelegate.hudWindowIdentifier
        panel.isReleasedWhenClosed = false
        let delegate = AppDelegate()
        delegate.configureWindow(panel)
        XCTAssertEqual(panel.frame.origin, NSPoint(x: 110, y: 220))
        panel.close()
    }
}
