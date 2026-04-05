import XCTest
@testable import VoiceScribeCore

final class ASRLanguageCatalogTests: XCTestCase {
    func testDefaultsToAutoForUnknownStoredIdentifier() {
        XCTAssertEqual(
            ASRLanguageCatalog.normalizedLanguageID("Klingon"),
            ASRLanguageCatalog.defaultLanguageID
        )
        XCTAssertNil(ASRLanguageCatalog.modelLanguage(for: "Klingon"))
    }

    func testResolvesForcedLanguageForSupportedIdentifier() {
        XCTAssertEqual(ASRLanguageCatalog.modelLanguage(for: "French"), "French")
        XCTAssertEqual(ASRLanguageCatalog.normalizedLanguageID("French"), "French")
    }

    func testAutoSelectionMapsToNilModelLanguage() {
        XCTAssertNil(ASRLanguageCatalog.modelLanguage(for: ASRLanguageCatalog.defaultLanguageID))
    }

    func testAutoAttemptOrderKeepsDetectionAndFallbacks() {
        XCTAssertEqual(
            NativeASREngine.languageAttemptOrder(preferredLanguage: nil),
            [nil, "French", "English"]
        )
    }

    func testForcedLanguageAttemptOrderDoesNotOverrideUserChoice() {
        XCTAssertEqual(
            NativeASREngine.languageAttemptOrder(preferredLanguage: "German"),
            ["German"]
        )
    }
}
