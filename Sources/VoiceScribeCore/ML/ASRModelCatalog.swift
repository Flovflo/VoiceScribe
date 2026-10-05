import Foundation

public struct ASRModelOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let sizeLabel: String
    public let quantization: String
    public let recommended: Bool

    public init(
        id: String,
        title: String,
        sizeLabel: String,
        quantization: String,
        recommended: Bool = false
    ) {
        self.id = id
        self.title = title
        self.sizeLabel = sizeLabel
        self.quantization = quantization
        self.recommended = recommended
    }
}

public enum ASRModelCatalog {
    public static let defaultModelID = "mlx-community/Qwen3-ASR-1.7B-4bit"

    // Qwen3-ASR variants only. ForcedAligner models are excluded because
    // they are alignment models, not direct speech-to-text generation models.
    public static let supportedModels: [ASRModelOption] = [
        .init(id: "mlx-community/Qwen3-ASR-0.6B-4bit", title: "Qwen3-ASR 0.6B", sizeLabel: "0.71 GB", quantization: "4bit"),
        .init(id: "mlx-community/Qwen3-ASR-0.6B-5bit", title: "Qwen3-ASR 0.6B", sizeLabel: "0.78 GB", quantization: "5bit"),
        .init(id: "mlx-community/Qwen3-ASR-0.6B-6bit", title: "Qwen3-ASR 0.6B", sizeLabel: "0.86 GB", quantization: "6bit"),
        .init(id: "mlx-community/Qwen3-ASR-0.6B-8bit", title: "Qwen3-ASR 0.6B", sizeLabel: "1.01 GB", quantization: "8bit", recommended: true),
        .init(id: "mlx-community/Qwen3-ASR-0.6B-bf16", title: "Qwen3-ASR 0.6B", sizeLabel: "1.56 GB", quantization: "bf16"),
        .init(id: "mlx-community/Qwen3-ASR-1.7B-4bit", title: "Qwen3-ASR 1.7B", sizeLabel: "1.60 GB", quantization: "4bit", recommended: true),
        .init(id: "mlx-community/Qwen3-ASR-1.7B-5bit", title: "Qwen3-ASR 1.7B", sizeLabel: "1.82 GB", quantization: "5bit"),
        .init(id: "mlx-community/Qwen3-ASR-1.7B-6bit", title: "Qwen3-ASR 1.7B", sizeLabel: "2.03 GB", quantization: "6bit"),
        .init(id: "mlx-community/Qwen3-ASR-1.7B-8bit", title: "Qwen3-ASR 1.7B", sizeLabel: "2.46 GB", quantization: "8bit", recommended: true),
        .init(id: "mlx-community/Qwen3-ASR-1.7B-bf16", title: "Qwen3-ASR 1.7B", sizeLabel: "4.08 GB", quantization: "bf16")
    ]

    public static let quickChoices: [ASRModelOption] = supportedModels.filter {
        $0.id == "mlx-community/Qwen3-ASR-0.6B-8bit"
            || $0.id == defaultModelID
    }

    public static func isSupportedASRModel(_ modelID: String) -> Bool {
        supportedModels.contains { $0.id == modelID }
    }
}
