import Foundation

public struct TokenDecoder: Sendable {
    private let idToToken: [Int: String]

    public init(tokenizerURL: URL) throws {
        let data = try Data(contentsOf: tokenizerURL)
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard
            let root = json as? [String: Any],
            let model = root["model"] as? [String: Any],
            let vocab = model["vocab"] as? [String: Any]
        else {
            throw TokenDecoderError.invalidTokenizer
        }

        var mapping: [Int: String] = [:]
        for (token, idValue) in vocab {
            if let id = idValue as? Int {
                mapping[id] = token
            } else if let id = idValue as? NSNumber {
                mapping[id.intValue] = token
            }
        }
        self.idToToken = mapping
    }

    public func decode(tokenIDs: [Int]) -> String {
        let tokens = tokenIDs.compactMap { idToToken[$0] }
        return tokens
            .map { $0.replacingOccurrences(of: "▁", with: " ") }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum TokenDecoderError: Error {
        case invalidTokenizer
    }
}
