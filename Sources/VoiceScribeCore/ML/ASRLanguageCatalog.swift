import Foundation

public struct ASRLanguageOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let modelValue: String?

    public init(id: String, title: String, modelValue: String?) {
        self.id = id
        self.title = title
        self.modelValue = modelValue
    }
}

public enum ASRLanguageCatalog {
    public static let defaultsKey = "selectedTranscriptionLanguage"
    public static let defaultLanguageID = "auto"

    public static let options: [ASRLanguageOption] = [
        .init(id: defaultLanguageID, title: "Auto-detect (recommended)", modelValue: nil),
        .init(id: "Chinese", title: "Chinese", modelValue: "Chinese"),
        .init(id: "English", title: "English", modelValue: "English"),
        .init(id: "Cantonese", title: "Cantonese", modelValue: "Cantonese"),
        .init(id: "Arabic", title: "Arabic", modelValue: "Arabic"),
        .init(id: "German", title: "German", modelValue: "German"),
        .init(id: "French", title: "French", modelValue: "French"),
        .init(id: "Spanish", title: "Spanish", modelValue: "Spanish"),
        .init(id: "Portuguese", title: "Portuguese", modelValue: "Portuguese"),
        .init(id: "Indonesian", title: "Indonesian", modelValue: "Indonesian"),
        .init(id: "Italian", title: "Italian", modelValue: "Italian"),
        .init(id: "Korean", title: "Korean", modelValue: "Korean"),
        .init(id: "Russian", title: "Russian", modelValue: "Russian"),
        .init(id: "Thai", title: "Thai", modelValue: "Thai"),
        .init(id: "Vietnamese", title: "Vietnamese", modelValue: "Vietnamese"),
        .init(id: "Japanese", title: "Japanese", modelValue: "Japanese"),
        .init(id: "Turkish", title: "Turkish", modelValue: "Turkish"),
        .init(id: "Hindi", title: "Hindi", modelValue: "Hindi"),
        .init(id: "Malay", title: "Malay", modelValue: "Malay"),
        .init(id: "Dutch", title: "Dutch", modelValue: "Dutch"),
        .init(id: "Swedish", title: "Swedish", modelValue: "Swedish"),
        .init(id: "Danish", title: "Danish", modelValue: "Danish"),
        .init(id: "Finnish", title: "Finnish", modelValue: "Finnish"),
        .init(id: "Polish", title: "Polish", modelValue: "Polish"),
        .init(id: "Czech", title: "Czech", modelValue: "Czech"),
        .init(id: "Filipino", title: "Filipino", modelValue: "Filipino"),
        .init(id: "Persian", title: "Persian", modelValue: "Persian"),
        .init(id: "Greek", title: "Greek", modelValue: "Greek"),
        .init(id: "Romanian", title: "Romanian", modelValue: "Romanian"),
        .init(id: "Hungarian", title: "Hungarian", modelValue: "Hungarian"),
        .init(id: "Macedonian", title: "Macedonian", modelValue: "Macedonian")
    ]

    public static func normalizedLanguageID(_ id: String?) -> String {
        guard let id, options.contains(where: { $0.id == id }) else {
            return defaultLanguageID
        }
        return id
    }

    public static func modelLanguage(for id: String?) -> String? {
        let normalizedID = normalizedLanguageID(id)
        return options.first(where: { $0.id == normalizedID })?.modelValue
    }

    static func isSupportedModelLanguage(_ language: String) -> Bool {
        options.contains(where: { $0.modelValue == language })
    }
}
