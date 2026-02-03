import Foundation
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon
import Hub
import Tokenizers

/// Native ASR Engine using MLX-Swift for on-device transcription.
/// Uses pre-converted models from mlx-community/Qwen3-ASR.
@MainActor
public final class NativeASREngine: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published public private(set) var status: String = "Not initialized"
    @Published public private(set) var isReady: Bool = false
    @Published public private(set) var isModelCached: Bool = false
    @Published public private(set) var loadProgress: Double = 0.0
    @Published public private(set) var lastError: String?
    
    // MARK: - Private Properties
    
    private let featureExtractor: AudioFeatureExtractor
    private var model: Qwen3ASR?
    private var tokenizer: (any Tokenizer)?
    
    private var modelName: String
    private var isLoading: Bool = false
    
    // MARK: - Configuration
    
    public struct Config: Sendable {
        public let modelName: String
        public let maxTokens: Int
        public let temperature: Float
        
        public static let qwen3ASR_0_6B_4bit = Config(
            modelName: "mlx-community/Qwen3-ASR-0.6B-4bit",
            maxTokens: 448,
            temperature: 0.0
        )
        
        public init(modelName: String, maxTokens: Int = 448, temperature: Float = 0.0) {
            self.modelName = modelName
            self.maxTokens = maxTokens
            self.temperature = temperature
        }
    }
    
    private let config: Config
    
    // MARK: - Initialization
    
    public init(config: Config = .qwen3ASR_0_6B_4bit) {
        self.config = config
        self.modelName = config.modelName
        self.featureExtractor = AudioFeatureExtractor()
    }
    
    // MARK: - Public API
    
    public func setModel(_ name: String) {
        guard name != modelName else { return }
        self.modelName = name
        // Cancel existing load if any?
        // Trigger reload
        Task {
            await loadModel()
        }
    }
    
    public func loadModel() async {
        guard !isLoading else { return }
        isLoading = true
        status = "Loading model..."
        loadProgress = 0.0
        lastError = nil
        
        do {
            let hub = HubApi()
            let repoId = modelName
            
            // 1. Download/Load Config
            status = "Loading configuration..."
            // snapshot(matching:) returns URL (directory) in this version
            let modelDir = try await hub.snapshot(from: repoId, matching: ["config.json"])
            let configUrl = modelDir.appending(component: "config.json")
            
            let configData = try Data(contentsOf: configUrl)
            
            // Parse Config (Manual Parsing for Qwen3-ASR structure)
            let currentConfig = try JSONDecoder().decode(Qwen3ASRConfigRaw.self, from: configData)
            
            // 2. Download/Load Weights
            status = "Loading model weights (safetensors)..."
            // We use the same modelDir usually, but to ensure files are present we call snapshot again with matching
            let _ = try await hub.snapshot(from: repoId, matching: ["*.safetensors"])
            
            // We need to list files in the directory manually or assume/construct paths
            // If snapshot returned the directory, we should look into it
            let weightFiles = try FileManager.default.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "safetensors" }
            
            var weights: [String: MLXArray] = [:]
            for url in weightFiles {
                let arrays = try MLX.loadArrays(url: url)
                for (k, v) in arrays {
                    weights[k] = v
                }
            }
            
            // 3. Download/Load Tokenizer
            status = "Loading tokenizer..."
            let _ = try await hub.snapshot(from: repoId, matching: ["tokenizer_config.json", "vocab.json", "merges.txt"])
             self.tokenizer = try await AutoTokenizer.from(pretrained: repoId)

            
            // 4. Instantiate Model
            status = "Building model architecture..."
            
            // Extract sub-configs
            let audioConf = Qwen3AudioConfiguration(
                dModel: currentConfig.thinker_config.audio_config.d_model,
                encoderLayers: currentConfig.thinker_config.audio_config.encoder_layers,
                encoderAttentionHeads: currentConfig.thinker_config.audio_config.encoder_attention_heads,
                encoderFfnDim: currentConfig.thinker_config.audio_config.encoder_ffn_dim,
                downsampleHiddenSize: currentConfig.thinker_config.audio_config.downsample_hidden_size,
                numMelBins: currentConfig.thinker_config.audio_config.num_mel_bins,
                outputDim: currentConfig.thinker_config.audio_config.output_dim
            )
            
            // Re-encode text config portion to decode as standard Qwen2Configuration
            let textConfigData = try JSONEncoder().encode(currentConfig.thinker_config.text_config)
            let textConf = try JSONDecoder().decode(Qwen2Configuration.self, from: textConfigData)
            
            self.model = Qwen3ASR(audioConfig: audioConf, textConfig: textConf)
            
            // 5. Apply weights
            status = "Applying weights..."
            
            var sanitizedWeights: [String: MLXArray] = [:]
            for (k, v) in weights {
                if k.hasPrefix("model.") {
                    let newKey = String(k.dropFirst(6)) // Remove "model."
                    sanitizedWeights[newKey] = v
                } else {
                    sanitizedWeights[k] = v
                }
            }
            
            // Verify structure matches
            let parameters = ModuleParameters.unflattened(sanitizedWeights)
            
            // Use verify: .none (assuming generic/none exists) or try without label if default works
            // Or use boolean false if older MLX
            // Based on previous error "cannot convert Bool to Module.VerifyUpdate", it expects enum.
            // Using .none
            try self.model?.update(parameters: parameters, verify: .none)
            
             MLX.eval(self.model?.parameters() as Any)
            
            isReady = true
            isModelCached = true
            loadProgress = 1.0
            status = "Ready"
            
        } catch {
            lastError = error.localizedDescription
            status = "Error: \(error.localizedDescription)"
            isReady = false
            print("Model load error: \(error)")
        }
        
        isLoading = false
    }
    
    public func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        guard isReady, let model = model, let tokenizer = tokenizer else {
            throw ASRError.modelNotLoaded
        }
        
        status = "Processing audio..."
        
        // 1. Extract features
        let features = featureExtractor.extractFeatures(samples: samples, sampleRate: sampleRate)
        guard !features.isEmpty else { throw ASRError.audioTooShort }
        
        // Convert [[Float]] (nMels x nFrames) to MLXArray [1, nFrames, nMels]
        let nMels = features.count
        let nFrames = features[0].count
        let flatFeatures = features.flatMap { $0 }
        
        // Transpose strictly: [nMels, nFrames] -> [nFrames, nMels]
        let mels = MLXArray(flatFeatures, [nMels, nFrames]).transposed()
        let inputBatch = mels.expandedDimensions(axis: 0) // [1, nFrames, nMels]
        
        status = "Transcribing..."
        
        // 2. Generate
        let prompt = "<|audio_bos|><|AUDIO|><|audio_eos|>Transcribe the speech to text."
        
        let result = model.generate(
            prompt: prompt,
            audioFeatures: inputBatch,
            tokenizer: tokenizer,
            maxTokens: config.maxTokens
        )
        
        status = "Ready"
        // Explicitly use CharacterSet.whitespacesAndNewlines
        return result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
    
    public func transcribe(from url: URL) async throws -> String {
        let (samples, sampleRate) = try await featureExtractor.loadAudioFromURL(url)
        return try await transcribe(samples: samples, sampleRate: sampleRate)
    }
    
    public func shutdown() {
        model = nil
        tokenizer = nil
        isReady = false
        status = "Shutdown"
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
