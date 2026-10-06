import Foundation

public enum Metrics {
    /// Case and punctuation insensitive; accents remain meaningful. Apostrophes
    /// split words consistently in the reference and hypothesis.
    public static func words(_ text: String) -> [String] {
        text.precomposedStringWithCanonicalMapping.lowercased()
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    public static func wordErrorRate(reference: String, hypothesis: String) -> Double? {
        let expected = words(reference), actual = words(hypothesis)
        guard !expected.isEmpty else { return nil }
        var previous = Array(0...actual.count)
        for (i, word) in expected.enumerated() {
            var current = [i + 1]
            for (j, candidate) in actual.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1,
                                   previous[j] + (word == candidate ? 0 : 1)))
            }
            previous = current
        }
        return Double(previous[actual.count]) / Double(expected.count)
    }
}
