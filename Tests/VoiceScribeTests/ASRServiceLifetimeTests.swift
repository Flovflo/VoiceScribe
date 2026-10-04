import Foundation
import XCTest
@testable import VoiceScribeCore

final class ASRServiceLifetimeTests: XCTestCase {
    @MainActor
    func testServiceEventListenerDoesNotRetainService() async {
        var service: NativeASRService? = NativeASRService()
        weak let weakService = service
        // Give the listener a chance to enter its stream suspension.
        for _ in 0..<10 { await Task.yield() }
        service = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(weakService, "An idle event listener must allow the service to deinitialize")
    }
}

