import XCTest
@testable import BenchmarkMetrics
final class AudioConditionsTests: XCTestCase {
    func testNoiseIsDeterministicAndHasRequestedSignalToNoiseRatio() {
        let input = (0..<16_000).map { Float(sin(Double($0) * 0.1)) * 0.1 }
        let noisy = AudioConditions.addingNoise(input, snrDB: 10)
        XCTAssertEqual(noisy, AudioConditions.addingNoise(input, snrDB: 10))
        let signalPower = input.reduce(0.0) { $0 + Double($1 * $1) }
        let noisePower = zip(input, noisy).reduce(0.0) { $0 + pow(Double($1.1 - $1.0), 2) }
        XCTAssertEqual(10 * log10(signalPower / noisePower), 10, accuracy: 0.001)
        XCTAssertEqual(noisy.count, input.count)
    }
    func testNoisePreservesEmptyAndSilentInput() {
        XCTAssertEqual(AudioConditions.addingNoise([], snrDB: 10), [])
        XCTAssertEqual(AudioConditions.addingNoise([0, 0], snrDB: 10), [0, 0])
    }
}
