import XCTest
@testable import VoiceScribeCore

final class MacOSInteractionTests: XCTestCase {
    @MainActor
    func testAppStateIsReleasedAfterItsOwnerReleasesIt() {
        weak var releasedState: AppState?
        do {
            let state = AppState()
            releasedState = state
        }
        XCTAssertNil(releasedState, "Publisher bindings must not retain their owner")
    }
}
