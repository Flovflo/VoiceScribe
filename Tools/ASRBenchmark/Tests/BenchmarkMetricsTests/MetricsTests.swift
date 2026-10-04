import XCTest
@testable import BenchmarkMetrics
final class MetricsTests: XCTestCase {
    func testWordErrorRateUsesLevenshteinEditsAndIgnoresCasePunctuation() {
        XCTAssertEqual(Metrics.wordErrorRate(reference: "Bonjour, café!", hypothesis: "BONJOUR café."), 0)
        XCTAssertEqual(Metrics.wordErrorRate(reference: "one two three four", hypothesis: "one three five"), 0.5)
        XCTAssertEqual(Metrics.wordErrorRate(reference: "bonjour café", hypothesis: "bonjour cafe"), 0.5)
    }
    func testSilenceHasNoWordErrorRateDenominator() {
        XCTAssertNil(Metrics.wordErrorRate(reference: "", hypothesis: "hallucination"))
    }
}
