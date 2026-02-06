import Foundation
import MLX
import MLXNN
import Hub
import Tokenizers
import os.log

/// Native ASR Engine using MLX-Swift for on-device transcription.
/// Uses pre-converted models from mlx-community/Qwen3-ASR.
public actor NativeASREngine {

    public enum Event: Sendable {
        case status(String)
        case progress(Double)
        case ready(Bool)
        case cached(Bool)
        case error(String?)
    }

    // MARK: - Configuration

    public struct Config: Sendable {
        public let modelName: String
        public let maxTokens: Int
        public let temperature: Float

        public static let qwen3ASR_1_7B_8bit = Config(
            modelName: "mlx-community/Qwen3-ASR-1.7B-8bit",
            maxTokens: 448,
            temperature: 0.0
        )

        public init(modelName: String, maxTokens: Int = 448, temperature: Float = 0.0) {
            self.modelName = modelName
            self.maxTokens = maxTokens
            self.temperature = temperature
        }
    }

    // MARK: - Private Properties

    private static let logger = Logger(subsystem: "com.voicescribe", category: "NativeASREngine")

    private let featureExtractor: AudioFeatureExtractor
    private let config: Config
    private var modelName: String

    private var model: Qwen3ASR?
    private var tokenizer: (any Tokenizer)?
    private var promptEmbeds: MLXArray?

    private var isLoading = false
    private var isReady = false
    private var isModelCached = false

    private let eventsStream: AsyncStream<Event>
    private let eventsContinuation: AsyncStream<Event>.Continuation

    public nonisolated var events: AsyncStream<Event> { eventsStream }

    // MARK: - Initialization

    public init(config: Config = .qwen3ASR_1_7B_8bit) {
        self.config = config
        self.modelName = config.modelName
        self.featureExtractor = AudioFeatureExtractor()

        Device.setDefault(device: .gpu)

        var continuation: AsyncStream<Event>.Continuation!
        self.eventsStream = AsyncStream { cont in
            continuation = cont
        }
        self.eventsContinuation = continuation
    }

    // MARK: - Public API

    public func setModel(_ name: String) async {
        guard name != modelName else { return }
        modelName = name
        await shutdown()
        try? await loadModel()
    }

    public func loadModel() async throws {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        emit(.status("Loading model..."))
        emit(.progress(0.0))
        emit(.error(nil))
        emit(.ready(false))
        isModelCached = false
        emit(.cached(false))

        do {
            let hub = HubApi(downloadBase: try Self.cacheRoot())
            let repoId = modelName

            let progressHandler: (Progress, Double?) -> Void = { [weak self] progress, _ in
                Task { await self?.emit(.progress(progress.fractionCompleted)) }
            }

            emit(.status("Downloading model files..."))
            let modelDir = try await hub.snapshot(
                from: repoId,
                matching: [
                    "config.json",
                    "*.safetensors",
                    "tokenizer.json",
                    "tokenizer_config.json",
                    "vocab.json",
                    "merges.txt"
                ],
                progressHandler: progressHandler
            )

            isModelCached = true
            emit(.cached(true))

            emit(.status("Loading configuration..."))
            let configUrl = modelDir.appending(component: "config.json")
            let configData = try Data(contentsOf: configUrl)
            let currentConfig = try JSONDecoder().decode(Qwen3ASRConfigRaw.self, from: configData)

            emit(.status("Loading model weights..."))
            let weightFiles = try FileManager.default.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "safetensors" }
            guard !weightFiles.isEmpty else {
                throw ASRError.modelLoadFailed("No safetensors files found in \(modelDir.path)")
            }

            var weights: [String: MLXArray] = [:]
            for url in weightFiles {
                let arrays = try MLX.loadArrays(url: url)
                for (k, v) in arrays {
                    weights[k] = v
                }
            }

            emit(.status("Loading tokenizer..."))
            let tokenizer = try await AutoTokenizer.from(modelFolder: modelDir)
            self.tokenizer = tokenizer

            emit(.status("Building model architecture..."))
            let audioConf = Qwen3AudioConfiguration(
                dModel: currentConfig.thinker_config.audio_config.d_model,
                encoderLayers: currentConfig.thinker_config.audio_config.encoder_layers,
                encoderAttentionHeads: currentConfig.thinker_config.audio_config.encoder_attention_heads,
                encoderFfnDim: currentConfig.thinker_config.audio_config.encoder_ffn_dim,
                downsampleHiddenSize: currentConfig.thinker_config.audio_config.downsample_hidden_size,
                numMelBins: currentConfig.thinker_config.audio_config.num_mel_bins,
                outputDim: currentConfig.thinker_config.audio_config.output_dim
            )

            let textConfigData = try JSONEncoder().encode(currentConfig.thinker_config.text_config)
            let textConf = try JSONDecoder().decode(Qwen2Configuration.self, from: textConfigData)

            let model = Qwen3ASR(audioConfig: audioConf, textConfig: textConf)
            self.model = model

            emit(.status("Applying weights..."))
            var sanitizedWeights: [String: MLXArray] = [:]
            for (k, v) in weights {
                if k.hasPrefix("model.") {
                    let newKey = String(k.dropFirst(6))
                    sanitizedWeights[newKey] = v
                } else {
                    sanitizedWeights[k] = v
                }
            }

            let expectedKeys = Set(model.parameters().flattened().map { $0.0 })
            let actualKeys = Set(sanitizedWeights.keys)

            let missing = expectedKeys.subtracting(actualKeys)
            let extra = actualKeys.subtracting(expectedKeys)
            if !missing.isEmpty || !extra.isEmpty {
                let missingSample = missing.sorted().prefix(10).joined(separator: ", ")
                let extraSample = extra.sorted().prefix(10).joined(separator: ", ")
                let message = "Weight mismatch: missing=\(missing.count) extra=\(extra.count) missingSample=[\(missingSample)] extraSample=[\(extraSample)]"
                throw ASRError.modelLoadFailed(message)
            }

            let parameters = ModuleParameters.unflattened(sanitizedWeights)
            try model.update(parameters: parameters, verify: .none)
            MLX.eval(model.parameters())

            emit(.status("Preparing prompt..."))
            let prompt = "<|audio_bos|><|AUDIO|><|audio_eos|>Transcribe the speech to text."
            let promptTokens = tokenizer.encode(text: prompt)
            let promptEmbeds = model.languageModel.embed(MLXArray(promptTokens).reshaped(1, -1))
            self.promptEmbeds = promptEmbeds

            isReady = true
            emit(.ready(true))
            emit(.progress(1.0))
            emit(.status("Ready"))
        } catch {
            Self.logger.error("Model load error: \(error.localizedDescription)")
            isReady = false
            emit(.ready(false))
            emit(.error(error.localizedDescription))
            emit(.status("Error: \(error.localizedDescription)"))
            throw error
        }
    }

    public func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        guard isReady, let model, let tokenizer, let promptEmbeds else {
            throw ASRError.modelNotLoaded
        }

        emit(.status("Processing audio..."))

        let inputBatch = featureExtractor.extractFeaturesMLX(samples: samples, sampleRate: sampleRate)
        guard inputBatch.dim(0) > 0 else { throw ASRError.audioTooShort }

        emit(.status("Transcribing..."))

        let result = model.generate(
            promptEmbeds: promptEmbeds,
            audioFeatures: inputBatch,
            tokenizer: tokenizer,
            maxTokens: config.maxTokens
        )

        emit(.status("Ready"))
        return result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    public func transcribe(from url: URL) async throws -> String {
        let (samples, sampleRate) = try await featureExtractor.loadAudioFromURL(url)
        return try await transcribe(samples: samples, sampleRate: sampleRate)
    }

    public func shutdown() {
        model = nil
        tokenizer = nil
        promptEmbeds = nil
        isReady = false
        isModelCached = false
        emit(.ready(false))
        emit(.cached(false))
        emit(.status("Shutdown"))
    }

    // MARK: - Private Helpers

    private func emit(_ event: Event) {
        eventsContinuation.yield(event)
    }

    private static func cacheRoot() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let root = base.appending(path: "VoiceScribe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

// Helper structs for JSON Parsing
private struct Qwen3ASRConfigRaw: Decodable {
    let thinker_config: ThinkerConfig

    struct ThinkerConfig: Decodable {
        let audio_config: AudioConfig
        let text_config: Qwen2ConfigRaw
    }

    struct AudioConfig: Decodable {
        let d_model: Int
        let encoder_layers: Int
        let encoder_attention_heads: Int
        let encoder_ffn_dim: Int
        let downsample_hidden_size: Int
        let num_mel_bins: Int
        let output_dim: Int
    }
}

// Ensure Qwen2Configuration is available (it is public in Qwen2.swift)
typealias Qwen2ConfigRaw = Qwen2Configuration

enum ASRError: Error {
    case modelNotLoaded
    case audioTooShort
    case modelLoadFailed(String)
}

extension ASRError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Model not loaded"
        case .audioTooShort:
            return "Audio too short"
        case .modelLoadFailed(let reason):
            return "Model load failed: \(reason)"
        }
    }
}
