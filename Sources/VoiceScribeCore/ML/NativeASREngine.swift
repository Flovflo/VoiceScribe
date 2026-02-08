import Foundation
import MLX
import MLXNN
import Hub
import Tokenizers
import os.log

/// Native ASR Engine using MLX-Swift for on-device transcription.
/// Uses pre-converted models from mlx-community/Qwen3-ASR.
public actor NativeASREngine {
    private static let requiredModelID = ASRModelCatalog.defaultModelID

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
        public let forcedLanguage: String?
        public let context: String

        public static let qwen3ASR_1_7B_8bit = Config(
            modelName: requiredModelID,
            maxTokens: 256,
            temperature: 0.0,
            forcedLanguage: nil,
            context: ""
        )

        public init(
            modelName: String,
            maxTokens: Int = 448,
            temperature: Float = 0.0,
            forcedLanguage: String? = nil,
            context: String = ""
        ) {
            self.modelName = modelName
            self.maxTokens = maxTokens
            self.temperature = temperature
            self.forcedLanguage = forcedLanguage
            self.context = context
        }
    }

    // MARK: - Private Properties

    private static let logger = Logger(subsystem: "com.voicescribe", category: "NativeASREngine")

    private let featureExtractor: AudioFeatureExtractor
    private let config: Config
    private var modelName: String
    private let useCPUDevice: Bool

    private var model: Qwen3ASR?
    private var tokenizer: (any Tokenizer)?
    private var audioTokenID: Int = 151676

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
        let featureBackend: AudioFeatureExtractor.Backend = {
            let value = ProcessInfo.processInfo.environment["VOICESCRIBE_FEATURE_BACKEND"]?.lowercased()
            if value == "cpu" { return .cpu }
            return .mlx
        }()
        self.featureExtractor = AudioFeatureExtractor(backend: featureBackend)
        let envDevice = ProcessInfo.processInfo.environment["VOICESCRIBE_MLX_DEVICE"]?.lowercased()
        self.useCPUDevice = (envDevice == "cpu")

        var continuation: AsyncStream<Event>.Continuation!
        self.eventsStream = AsyncStream { cont in
            continuation = cont
        }
        self.eventsContinuation = continuation
    }

    // MARK: - Public API

    public func setModel(_ name: String) async {
        guard name != modelName else { return }
        guard Self.isAllowedModel(name) else {
            emit(.error(ASRError.unsupportedModel(name).localizedDescription))
            emit(.status("Error: \(ASRError.unsupportedModel(name).localizedDescription)"))
            return
        }
        modelName = name
        shutdown()
        try? await loadModel()
    }

    public func loadModel() async throws {
        guard Self.isAllowedModel(modelName) else {
            throw ASRError.unsupportedModel(modelName)
        }
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

            let continuation = eventsContinuation
            let progressHandler: @Sendable (Progress, Double?) -> Void = { progress, _ in
                continuation.yield(.progress(progress.fractionCompleted))
            }

            emit(.status("Downloading model files..."))
            let modelDir = try await hub.snapshot(
                from: repoId,
                matching: [
                    "config.json",
                    "generation_config.json",
                    "preprocessor_config.json",
                    "chat_template.json",
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
            guard currentConfig.model_type == "qwen3_asr" else {
                throw ASRError.modelLoadFailed("Unexpected model_type '\(currentConfig.model_type)'")
            }
            let architectures = Set(currentConfig.architectures)
            guard architectures.contains("Qwen3ASRForConditionalGeneration") else {
                throw ASRError.modelLoadFailed("Unexpected architectures: \(architectures.sorted().joined(separator: ", "))")
            }
            audioTokenID = currentConfig.thinker_config.audio_token_id

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
            try Self.ensureTokenizerJSONIfNeeded(in: modelDir)
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
                maxSourcePositions: currentConfig.thinker_config.audio_config.max_source_positions,
                nWindow: currentConfig.thinker_config.audio_config.n_window,
                nWindowInfer: currentConfig.thinker_config.audio_config.n_window_infer,
                convChunkSize: currentConfig.thinker_config.audio_config.conv_chunksize,
                outputDim: currentConfig.thinker_config.audio_config.output_dim
            )

            let textConfigData = try JSONEncoder().encode(currentConfig.thinker_config.text_config)
            let textConf = try JSONDecoder().decode(Qwen2Configuration.self, from: textConfigData)

            let model = Qwen3ASR(audioConfig: audioConf, textConfig: textConf)

            if let q = currentConfig.quantization ?? currentConfig.quantization_config {
                let quantMode: QuantizationMode = (q.mode?.lowercased() == "mxfp4") ? .mxfp4 : .affine
                quantize(
                    model: model,
                    filter: { path, _ in path.hasPrefix("language_model.") },
                    apply: { layer, _, _, _ in
                        quantizeSingle(layer: layer, groupSize: q.group_size, bits: q.bits, mode: quantMode)
                    }
                )
            }

            self.model = model

            emit(.status("Applying weights..."))
            var sanitizedWeights: [String: MLXArray] = [:]
            for (k, v) in weights {
                if k.hasPrefix("model.") {
                    let newKey = "language_model.\(k)"
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

            var shapeMismatches = [String]()
            for (name, expectedValue) in model.parameters().flattened() {
                guard let actualValue = sanitizedWeights[name] else { continue }
                if expectedValue.shape != actualValue.shape {
                    shapeMismatches.append("\(name): expected \(expectedValue.shape) got \(actualValue.shape)")
                }
            }
            if !shapeMismatches.isEmpty {
                let sample = shapeMismatches.prefix(10).joined(separator: ", ")
                throw ASRError.modelLoadFailed(
                    "Weight shape mismatch count=\(shapeMismatches.count) sample=[\(sample)]"
                )
            }

            let parameters = ModuleParameters.unflattened(sanitizedWeights)
            let device: Device = useCPUDevice ? .cpu : .gpu
            try Device.withDefaultDevice(device) {
                try model.update(parameters: parameters, verify: .none)
                MLX.eval(model.parameters())
            }

            if ProcessInfo.processInfo.environment["VOICESCRIBE_DEBUG_WEIGHTS"] == "1" {
                let flatParams = model.parameters().flattened()
                for name in [
                    "audio_tower.conv2d1.weight",
                    "audio_tower.layers.0.self_attn.q_proj.weight",
                    "audio_tower.layers.0.self_attn.out_proj.weight",
                    "audio_tower.layers.0.self_attn_layer_norm.weight",
                    "audio_tower.layers.0.self_attn_layer_norm.bias",
                    "audio_tower.layers.0.final_layer_norm.weight",
                    "audio_tower.layers.0.final_layer_norm.bias",
                    "audio_tower.layers.0.fc1.weight",
                    "audio_tower.layers.0.fc2.weight",
                    "audio_tower.layers.5.self_attn.q_proj.weight",
                    "audio_tower.layers.23.self_attn.q_proj.weight",
                    "audio_tower.ln_post.weight",
                    "audio_tower.ln_post.bias",
                    "audio_tower.proj1.weight",
                    "audio_tower.proj2.weight"
                ] {
                    if let value = flatParams.first(where: { $0.0 == name })?.1 {
                        let fp = value.asType(.float32).asArray(Float.self)
                        let meanAbs = fp.reduce(0) { $0 + abs($1) } / Float(max(fp.count, 1))
                        let mean = fp.reduce(0, +) / Float(max(fp.count, 1))
                        print("[NativeASREngine] \(name) shape=\(value.shape) dtype=\(value.dtype) meanAbs=\(meanAbs) mean=\(mean)")
                    }
                }
            }

            isReady = true
            emit(.ready(true))
            emit(.progress(1.0))
            emit(.status("Ready: \(repoId) @ \(modelDir.path)"))
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
        guard isReady, let model, let tokenizer else {
            throw ASRError.modelNotLoaded
        }

        emit(.status("Processing audio..."))

        var inputBatch = featureExtractor.extractFeaturesMLX(samples: samples, sampleRate: sampleRate)
        if ProcessInfo.processInfo.environment["VOICESCRIBE_MATERIALIZE_FEATURES"] == "1" {
            MLX.eval(inputBatch)
            let materialized = inputBatch.asArray(Float.self)
            inputBatch = MLXArray(materialized, inputBatch.shape)
        }
        guard inputBatch.dim(0) > 0 else { throw ASRError.audioTooShort }

        let preferredLanguage = config.forcedLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let statusLabel = (preferredLanguage?.isEmpty == false) ? preferredLanguage! : "auto"
        emit(.status("Transcribing (\(statusLabel))..."))
        
        let device: Device = useCPUDevice ? .cpu : .gpu
        var triedLanguages = Set<String>()
        let debugASR = ProcessInfo.processInfo.environment["VOICESCRIBE_DEBUG_ASR"] == "1"

        func runOnce(language: String?) -> (raw: String, cleaned: String) {
            let raw = Device.withDefaultDevice(device) {
                model.generate(
                    audioFeatures: inputBatch,
                    tokenizer: tokenizer,
                    audioTokenID: audioTokenID,
                    language: language,
                    context: config.context,
                    maxTokens: config.maxTokens
                )
            }
            let parsed = Self.parseASROutput(raw: raw, forcedLanguage: language)
            let cleaned = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if debugASR {
                let compactRaw = raw.replacingOccurrences(of: "\n", with: "\\n")
                let languageLabel = language?.isEmpty == false ? language! : "auto"
                print("[NativeASREngine] attempt language=\(languageLabel) raw=\(compactRaw) cleaned=\(cleaned)")
            }
            return (raw, cleaned)
        }

        var attempt = runOnce(language: preferredLanguage?.isEmpty == false ? preferredLanguage : nil)
        if let preferredLanguage, !preferredLanguage.isEmpty {
            triedLanguages.insert(preferredLanguage.lowercased())
        } else {
            triedLanguages.insert("auto")
        }
        if attempt.cleaned.isEmpty {
            for fallback in ["French", "English"] {
                let key = fallback.lowercased()
                if triedLanguages.contains(key) {
                    continue
                }
                triedLanguages.insert(key)
                let retry = runOnce(language: fallback)
                if !retry.cleaned.isEmpty {
                    attempt = retry
                    break
                }
                if attempt.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    attempt = retry
                }
            }
        }

        emit(.status("Ready"))
        guard !attempt.cleaned.isEmpty else {
            if !attempt.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ASRError.emptyTranscriptionRaw(String(attempt.raw.prefix(200)))
            }
            throw ASRError.emptyTranscription
        }
        return attempt.cleaned
    }

    public func transcribe(from url: URL) async throws -> String {
        let (samples, sampleRate) = try featureExtractor.loadAudioFromURL(url)
        return try await transcribe(samples: samples, sampleRate: sampleRate)
    }

    public func shutdown() {
        model = nil
        tokenizer = nil
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
        let root = base
            .appending(path: "VoiceScribe", directoryHint: .isDirectory)
            .appending(path: "models", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func isAllowedModel(_ name: String) -> Bool {
        ASRModelCatalog.isSupportedASRModel(name)
    }

    private static func ensureTokenizerJSONIfNeeded(in modelDir: URL) throws {
        let tokenizerJSONURL = modelDir.appending(path: "tokenizer.json")
        if FileManager.default.fileExists(atPath: tokenizerJSONURL.path) {
            return
        }

        let vocabURL = modelDir.appending(path: "vocab.json")
        let mergesURL = modelDir.appending(path: "merges.txt")
        let tokenizerConfigURL = modelDir.appending(path: "tokenizer_config.json")

        guard FileManager.default.fileExists(atPath: vocabURL.path),
              FileManager.default.fileExists(atPath: mergesURL.path),
              FileManager.default.fileExists(atPath: tokenizerConfigURL.path) else {
            throw ASRError.modelLoadFailed("Missing tokenizer files: expected tokenizer.json or vocab/merges/tokenizer_config in \(modelDir.path)")
        }

        let vocabData = try Data(contentsOf: vocabURL)
        let vocabJSON = try JSONSerialization.jsonObject(with: vocabData, options: [])
        guard let vocab = vocabJSON as? [String: Int] else {
            throw ASRError.modelLoadFailed("Invalid vocab.json format")
        }

        let mergesText = try String(contentsOf: mergesURL, encoding: .utf8)
        let merges: [String] = mergesText
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        let tokenizerConfigData = try Data(contentsOf: tokenizerConfigURL)
        let tokenizerConfigAny = try JSONSerialization.jsonObject(with: tokenizerConfigData, options: [])
        guard let tokenizerConfig = tokenizerConfigAny as? [String: Any] else {
            throw ASRError.modelLoadFailed("Invalid tokenizer_config.json format")
        }

        let addPrefixSpace = (tokenizerConfig["add_prefix_space"] as? Bool) ?? false
        let unkToken = Self.extractTokenContent(tokenizerConfig["unk_token"]) ?? "<|endoftext|>"

        let addedTokensDecoder = (tokenizerConfig["added_tokens_decoder"] as? [String: Any]) ?? [:]
        let addedTokens: [[String: Any]] = addedTokensDecoder
            .compactMap { key, value -> (Int, [String: Any])? in
                guard let id = Int(key), let tokenInfo = value as? [String: Any] else { return nil }
                guard let content = tokenInfo["content"] as? String else { return nil }
                return (id, [
                    "id": id,
                    "content": content,
                    "single_word": (tokenInfo["single_word"] as? Bool) ?? false,
                    "lstrip": (tokenInfo["lstrip"] as? Bool) ?? false,
                    "rstrip": (tokenInfo["rstrip"] as? Bool) ?? false,
                    "normalized": (tokenInfo["normalized"] as? Bool) ?? false,
                    "special": (tokenInfo["special"] as? Bool) ?? false
                ])
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)

        let synthesizedTokenizer: [String: Any] = [
            "version": "1.0",
            "truncation": NSNull(),
            "padding": NSNull(),
            "added_tokens": addedTokens,
            "normalizer": ["type": "NFC"],
            "pre_tokenizer": [
                "type": "ByteLevel",
                "add_prefix_space": addPrefixSpace,
                "trim_offsets": true,
                "use_regex": true
            ],
            "decoder": [
                "type": "ByteLevel",
                "add_prefix_space": addPrefixSpace,
                "trim_offsets": true,
                "use_regex": true
            ],
            "model": [
                "type": "BPE",
                "vocab": vocab,
                "merges": merges,
                "continuing_subword_prefix": "",
                "end_of_word_suffix": "",
                "fuse_unk": false,
                "unk_token": unkToken
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: synthesizedTokenizer, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: tokenizerJSONURL, options: .atomic)
    }

    private static func extractTokenContent(_ tokenField: Any?) -> String? {
        if let token = tokenField as? String {
            return token
        }
        if let dict = tokenField as? [String: Any] {
            return dict["content"] as? String
        }
        return nil
    }

    private static func parseASROutput(raw: String, forcedLanguage: String?) -> (language: String, text: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", "") }

        let asrTag = "<asr_text>"
        if let range = trimmed.range(of: asrTag) {
            let meta = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let text = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = meta.lowercased()
            if lower.contains("language none") {
                return ("", text)
            }

            var language = ""
            for line in meta.split(whereSeparator: \.isNewline) {
                let current = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let lowerCurrent = current.lowercased()
                if lowerCurrent.hasPrefix("language ") {
                    language = String(current.dropFirst("language ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            if language.isEmpty, let forcedLanguage {
                language = forcedLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return (language, text)
        }

        // Fallback: no tag, treat the full decoded content as text.
        let lowerTrimmed = trimmed.lowercased()
        if lowerTrimmed.hasPrefix("language ") && !lowerTrimmed.contains("<asr_text>") {
            var candidate = trimmed
            let pattern = #"(?i)^language\s+[^\n]+?\s*"#
            while true {
                guard let range = candidate.range(of: pattern, options: .regularExpression) else {
                    break
                }
                candidate.removeSubrange(range)
                candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.lowercased().hasPrefix("language ") {
                    break
                }
            }

            let strippedSpecials = candidate.replacingOccurrences(
                of: #"<\|[^|]+?\|>"#,
                with: "",
                options: .regularExpression
            )
            let text = strippedSpecials.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                return ("", "")
            }
            let fallbackLanguage = forcedLanguage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (fallbackLanguage, text)
        }
        let fallbackLanguage = forcedLanguage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (fallbackLanguage, trimmed)
    }
}

// Helper structs for JSON Parsing
private struct Qwen3ASRConfigRaw: Decodable {
    let model_type: String
    let architectures: [String]
    let thinker_config: ThinkerConfig
    let quantization: QuantizationConfig?
    let quantization_config: QuantizationConfig?

    struct ThinkerConfig: Decodable {
        let audio_token_id: Int
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
        let max_source_positions: Int
        let n_window: Int
        let n_window_infer: Int
        let conv_chunksize: Int
        let output_dim: Int
    }

    struct QuantizationConfig: Decodable {
        let group_size: Int
        let bits: Int
        let mode: String?
    }
}

// Ensure Qwen2Configuration is available (it is public in Qwen2.swift)
typealias Qwen2ConfigRaw = Qwen2Configuration

enum ASRError: Error {
    case modelNotLoaded
    case audioTooShort
    case emptyTranscription
    case emptyTranscriptionRaw(String)
    case unsupportedModel(String)
    case modelLoadFailed(String)
}

extension ASRError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Model not loaded"
        case .audioTooShort:
            return "Audio too short"
        case .emptyTranscription:
            return "No speech detected"
        case .emptyTranscriptionRaw(let raw):
            return "No speech detected (raw model output: \(raw))"
        case .unsupportedModel(let model):
            return "Unsupported model '\(model)'. Select one of the Qwen3-ASR variants in Settings > Advanced."
        case .modelLoadFailed(let reason):
            return "Model load failed: \(reason)"
        }
    }
}
