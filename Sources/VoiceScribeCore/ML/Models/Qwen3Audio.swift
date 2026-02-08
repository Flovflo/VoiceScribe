//
//  Qwen3Audio.swift
//  VoiceScribeCore
//
//  Qwen3-ASR Audio Encoder implementation
//

import Foundation
import MLX
import MLXNN

public struct Qwen3AudioConfiguration: Codable, Sendable {
    public let dModel: Int
    public let encoderLayers: Int
    public let encoderAttentionHeads: Int
    public let encoderFfnDim: Int
    public let downsampleHiddenSize: Int
    public let numMelBins: Int
    public let maxSourcePositions: Int
    public let nWindow: Int
    public let nWindowInfer: Int
    public let convChunkSize: Int
    public let outputDim: Int // Added this to match usage
    
    enum CodingKeys: String, CodingKey {
        case dModel = "d_model"
        case encoderLayers = "encoder_layers"
        case encoderAttentionHeads = "encoder_attention_heads"
        case encoderFfnDim = "encoder_ffn_dim"
        case downsampleHiddenSize = "downsample_hidden_size"
        case numMelBins = "num_mel_bins"
        case maxSourcePositions = "max_source_positions"
        case nWindow = "n_window"
        case nWindowInfer = "n_window_infer"
        case convChunkSize = "conv_chunksize"
        case outputDim = "output_dim"
    }

    // Default configuration for 0.6B model
    public static let default0_6B = Qwen3AudioConfiguration(
        dModel: 896,
        encoderLayers: 18,
        encoderAttentionHeads: 14,
        encoderFfnDim: 3584,
        downsampleHiddenSize: 480,
        numMelBins: 128,
        maxSourcePositions: 1500,
        nWindow: 50,
        nWindowInfer: 800,
        convChunkSize: 500,
        outputDim: 1024
    )
}

private func createSinusoidalPositionEmbeddings(length: Int, channels: Int) -> [Float] {
    precondition(channels % 2 == 0, "Position embedding channels must be even")
    if channels < 2 || length <= 0 {
        return []
    }

    let half = channels / 2
    let denom = max(1, half - 1)
    let logTimescaleIncrement = log(10000.0) / Double(denom)

    var values = [Float]()
    values.reserveCapacity(length * channels)
    for position in 0..<length {
        for i in 0..<half {
            let invTimescale = exp(-Double(i) * logTimescaleIncrement)
            let scaled = Double(position) * invTimescale
            values.append(Float(sin(scaled)))
        }
        for i in 0..<half {
            let invTimescale = exp(-Double(i) * logTimescaleIncrement)
            let scaled = Double(position) * invTimescale
            values.append(Float(cos(scaled)))
        }
    }
    return values
}

class Qwen3AudioAttention: Module {
    let dim: Int
    let numHeads: Int
    let headDim: Int
    let scale: Float
    
    @ModuleInfo(key: "q_proj") var wq: Linear
    @ModuleInfo(key: "k_proj") var wk: Linear
    @ModuleInfo(key: "v_proj") var wv: Linear
    @ModuleInfo(key: "out_proj") var wo: Linear // Note: Qwen audio often uses out_proj vs o_proj
    
    init(dim: Int, numHeads: Int) {
        self.dim = dim
        self.numHeads = numHeads
        self.headDim = dim / numHeads
        self.scale = pow(Float(headDim), -0.5)
        
        _wq.wrappedValue = Linear(dim, dim, bias: true)
        _wk.wrappedValue = Linear(dim, dim, bias: true)
        _wv.wrappedValue = Linear(dim, dim, bias: true)
        _wo.wrappedValue = Linear(dim, dim, bias: true)
    }
    
    func callAsFunction(_ x: MLXArray, mask: MLXArray? = nil) -> MLXArray {
        let (B, L) = (x.dim(0), x.dim(1))

        let queries = contiguous(wq(x).reshaped(B, L, numHeads, headDim).transposed(0, 2, 1, 3))
        let keys = contiguous(wk(x).reshaped(B, L, numHeads, headDim).transposed(0, 2, 1, 3))
        let values = contiguous(wv(x).reshaped(B, L, numHeads, headDim).transposed(0, 2, 1, 3))
        if ProcessInfo.processInfo.environment["VOICESCRIBE_DEBUG_AUDIO_DTYPE"] == "1" {
            print(
                "[Qwen3AudioAttention] x=\(x.dtype) q=\(queries.dtype) k=\(keys.dtype) v=\(values.dtype)"
            )
        }
        
        let attentionMask = mask?.asType(queries.dtype)
        let output = scaledDotProductAttention(
            queries: queries,
            keys: keys,
            values: values,
            scale: scale,
            mask: attentionMask
        )
            .transposed(0, 2, 1, 3)
            .reshaped(B, L, dim)

        return wo(contiguous(output))
    }
}

class Qwen3AudioMLP: Module {
    @ModuleInfo(key: "fc1") var fc1: Linear
    @ModuleInfo(key: "fc2") var fc2: Linear
    
    init(dim: Int, hiddenDim: Int) {
        _fc1.wrappedValue = Linear(dim, hiddenDim)
        _fc2.wrappedValue = Linear(hiddenDim, dim)
    }
    
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        return fc2(gelu(fc1(x)))
    }
}

class Qwen3AudioEncoderLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: Qwen3AudioAttention
    @ModuleInfo(key: "fc1") var fc1: Linear // Check naming, usually it's MLP structure
    @ModuleInfo(key: "fc2") var fc2: Linear
    
    // Actually, let's use standard MLP structure if mapping is unclear.
    // Qwen-Audio uses: self_attn, self_attn_layer_norm, fc1, fc2, final_layer_norm
    
    @ModuleInfo(key: "self_attn_layer_norm") var norm1: LayerNorm
    @ModuleInfo(key: "final_layer_norm") var norm2: LayerNorm
    private let layerIndex: Int
    
    init(config: Qwen3AudioConfiguration, layerIndex: Int) {
        self.layerIndex = layerIndex
        _selfAttn.wrappedValue = Qwen3AudioAttention(dim: config.dModel, numHeads: config.encoderAttentionHeads)
        
        // MLP definition inline to match common audio encoder structure
        _fc1.wrappedValue = Linear(config.dModel, config.encoderFfnDim)
        _fc2.wrappedValue = Linear(config.encoderFfnDim, config.dModel)
        
        _norm1.wrappedValue = LayerNorm(dimensions: config.dModel)
        _norm2.wrappedValue = LayerNorm(dimensions: config.dModel)
    }

    private func applyLayerNorm(_ input: MLXArray, norm: LayerNorm) -> MLXArray {
        let x32 = input.asType(.float32)
        let featureAxis = x32.ndim - 1
        let meanValue = mean(x32, axis: featureAxis, keepDims: true)
        let variance = mean(square(x32 - meanValue), axis: featureAxis, keepDims: true)
        var output = (x32 - meanValue) * rsqrt(variance + MLXArray(Float(norm.eps)))
        if let weight = norm.weight {
            output = output * weight.asType(.float32)
        }
        if let bias = norm.bias {
            output = output + bias.asType(.float32)
        }
        return output
    }
    
    func callAsFunction(_ x: MLXArray, mask: MLXArray? = nil) -> MLXArray {
        let residual = x
        let normed1 = applyLayerNorm(x, norm: norm1)
        var hidden = selfAttn(normed1, mask: mask)
        if ProcessInfo.processInfo.environment["VOICESCRIBE_DEBUG_AUDIO_LAYER0"] == "1",
           layerIndex == 0 {
            Qwen3AudioEncoder.debugStats("layer0.norm1", normed1)
            Qwen3AudioEncoder.debugStats("layer0.attnOut", hidden)
        }
        hidden = residual + hidden
        if ProcessInfo.processInfo.environment["VOICESCRIBE_DEBUG_AUDIO_LAYER0"] == "1",
           layerIndex == 0 {
            Qwen3AudioEncoder.debugStats("layer0.afterAttnResidual", hidden)
        }
        
        let residual2 = hidden
        // MLP block
        let normed2 = applyLayerNorm(hidden, norm: norm2)
        var mlpOut = fc1(normed2)
        if ProcessInfo.processInfo.environment["VOICESCRIBE_DEBUG_AUDIO_LAYER0"] == "1",
           layerIndex == 0 {
            Qwen3AudioEncoder.debugStats("layer0.norm2", normed2)
            Qwen3AudioEncoder.debugStats("layer0.fc1", mlpOut)
        }
        mlpOut = gelu(mlpOut)
        if ProcessInfo.processInfo.environment["VOICESCRIBE_DEBUG_AUDIO_LAYER0"] == "1",
           layerIndex == 0 {
            Qwen3AudioEncoder.debugStats("layer0.gelu", mlpOut)
        }
        mlpOut = fc2(mlpOut)
        if ProcessInfo.processInfo.environment["VOICESCRIBE_DEBUG_AUDIO_LAYER0"] == "1",
           layerIndex == 0 {
            Qwen3AudioEncoder.debugStats("layer0.fc2", mlpOut)
        }
        return residual2 + mlpOut
    }
}

public class Qwen3AudioEncoder: Module {
    @ModuleInfo(key: "conv2d1") var conv2d1: Conv2d
    @ModuleInfo(key: "conv2d2") var conv2d2: Conv2d
    @ModuleInfo(key: "conv2d3") var conv2d3: Conv2d
    @ModuleInfo(key: "conv_out") var convOut: Linear

    fileprivate let layers: [Qwen3AudioEncoderLayer]
    private let config: Qwen3AudioConfiguration
    private let positionalEmbeddingData: [Float]
    private let positionalEmbeddingLength: Int
    private let positionalEmbeddingChannels: Int
    @ModuleInfo(key: "ln_post") var lnPost: LayerNorm
    @ModuleInfo(key: "proj1") var proj1: Linear
    @ModuleInfo(key: "proj2") var proj2: Linear
    
    public init(config: Qwen3AudioConfiguration) {
        self.config = config
        // Input is [batch, time, mel] then expanded to [batch, time, mel, 1].
        _conv2d1.wrappedValue = Conv2d(
            inputChannels: 1,
            outputChannels: config.downsampleHiddenSize,
            kernelSize: [3, 3],
            stride: [2, 2],
            padding: 1,
            bias: true
        )

        _conv2d2.wrappedValue = Conv2d(
            inputChannels: config.downsampleHiddenSize,
            outputChannels: config.downsampleHiddenSize,
            kernelSize: [3, 3],
            stride: [2, 2],
            padding: 1,
            bias: true
        )

        _conv2d3.wrappedValue = Conv2d(
            inputChannels: config.downsampleHiddenSize,
            outputChannels: config.downsampleHiddenSize,
            kernelSize: [3, 3],
            stride: [2, 2],
            padding: 1,
            bias: true
        )

        // 128 mel bins -> 16 after three stride-2 convolutions (padding=1, kernel=3).
        _convOut.wrappedValue = Linear(16 * config.downsampleHiddenSize, config.dModel, bias: false)

        self.positionalEmbeddingLength = config.maxSourcePositions
        self.positionalEmbeddingChannels = config.dModel
        self.positionalEmbeddingData = createSinusoidalPositionEmbeddings(
            length: config.maxSourcePositions,
            channels: config.dModel
        )
        _lnPost.wrappedValue = LayerNorm(dimensions: config.dModel)
        _proj1.wrappedValue = Linear(config.dModel, config.dModel, bias: true)
        _proj2.wrappedValue = Linear(config.dModel, config.outputDim, bias: true)

        self.layers = (0..<config.encoderLayers).map { index in
            Qwen3AudioEncoderLayer(config: config, layerIndex: index)
        }
    }

    fileprivate static func debugStats(_ label: String, _ value: MLXArray) {
        guard ProcessInfo.processInfo.environment["VOICESCRIBE_DEBUG_AUDIO_ENCODER"] == "1" else { return }
        let flat = value.asType(.float32).asArray(Float.self)
        let meanAbs = flat.reduce(0) { $0 + abs($1) } / Float(max(flat.count, 1))
        let mean = flat.reduce(0, +) / Float(max(flat.count, 1))
        let maxAbs = flat.map { abs($0) }.max() ?? 0
        print("[Qwen3AudioEncoder] \(label) shape=\(value.shape) meanAbs=\(meanAbs) mean=\(mean) maxAbs=\(maxAbs)")
    }

    private func applyLayerNorm(_ input: MLXArray, norm: LayerNorm) -> MLXArray {
        let x32 = input.asType(.float32)
        let featureAxis = x32.ndim - 1
        let meanValue = mean(x32, axis: featureAxis, keepDims: true)
        let variance = mean(square(x32 - meanValue), axis: featureAxis, keepDims: true)
        var output = (x32 - meanValue) * rsqrt(variance + MLXArray(Float(norm.eps)))
        if let weight = norm.weight {
            output = output * weight.asType(.float32)
        }
        if let bias = norm.bias {
            output = output + bias.asType(.float32)
        }
        return output
    }
    
    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        // x: [batch, mel_bins, time]
        let batchSize = x.dim(0)
        let timeLen = x.dim(2)
        let sampleLengths = [Int](repeating: timeLen, count: batchSize)
        let disableChunking = ProcessInfo.processInfo.environment["VOICESCRIBE_AUDIO_NO_CHUNK"] == "1"
        let chunkSize = disableChunking ? max(1, timeLen) : max(1, config.nWindow * 2)

        var chunkSpecs: [(sample: Int, start: Int, length: Int)] = []
        var chunkLengths = [Int]()
        for sample in 0..<batchSize {
            let total = sampleLengths[sample]
            let chunkCount = max(1, Int(ceil(Double(total) / Double(chunkSize))))
            for c in 0..<chunkCount {
                let start = c * chunkSize
                let remaining = max(0, total - start)
                let length = (c == chunkCount - 1) ? max(1, min(chunkSize, remaining == 0 ? chunkSize : remaining)) : chunkSize
                chunkSpecs.append((sample: sample, start: start, length: length))
                chunkLengths.append(length)
            }
        }

        let maxChunkLen = chunkLengths.max() ?? chunkSize
        var paddedChunks = [MLXArray]()
        paddedChunks.reserveCapacity(chunkSpecs.count)
        for spec in chunkSpecs {
            let end = min(timeLen, spec.start + spec.length)
            var chunk = x[spec.sample, 0..., spec.start..<end]
            let currentLen = chunk.dim(1)
            if currentLen < maxChunkLen {
                chunk = padded(chunk, widths: [[0, 0], [0, maxChunkLen - currentLen]])
            }
            paddedChunks.append(chunk)
        }

        var chunkedInput = MLX.stacked(paddedChunks, axis: 0)
        if ProcessInfo.processInfo.environment["VOICESCRIBE_MATERIALIZE_AUDIO_CHUNKS"] == "1" {
            MLX.eval(chunkedInput)
            let materialized = chunkedInput.asArray(Float.self)
            chunkedInput = MLXArray(materialized, chunkedInput.shape)
        }
        Self.debugStats("chunkedInput", chunkedInput)
        var hidden = chunkedInput.expandedDimensions(axis: 3)
        hidden = gelu(conv2d1(hidden))
        hidden = gelu(conv2d2(hidden))
        hidden = gelu(conv2d3(hidden))
        Self.debugStats("afterConv", hidden)

        let b = hidden.dim(0)
        let f = hidden.dim(1)
        let t = hidden.dim(2)
        let c = hidden.dim(3)
        hidden = hidden.transposed(0, 2, 3, 1).reshaped(b, t, c * f)
        hidden = convOut(hidden)
        Self.debugStats("afterConvOut", hidden)

        let positionalEmbedding = MLXArray(
            positionalEmbeddingData,
            [positionalEmbeddingLength, positionalEmbeddingChannels]
        )
        let maxPos = min(t, positionalEmbeddingLength)
        if maxPos > 0 {
            hidden = hidden + positionalEmbedding[..<maxPos, 0...].expandedDimensions(axis: 0)
        }
        Self.debugStats("afterPos", hidden)

        let chunkLengthsAfterCNN = Self.getFeatExtractOutputLengths(chunkLengths)
        let maxLenAfterCNN = chunkLengthsAfterCNN.max() ?? hidden.dim(1)
        var hiddenList = [MLXArray]()
        hiddenList.reserveCapacity(hidden.dim(0))
        for i in 0..<hidden.dim(0) {
            let validLen = max(1, min(chunkLengthsAfterCNN[i], hidden.dim(1)))
            hiddenList.append(hidden[i, ..<validLen, 0...])
        }
        var hiddenStates = contiguous(MLX.concatenated(hiddenList, axis: 0))

        let sampleLengthsAfterCNN = Self.getFeatExtractOutputLengths(sampleLengths)
        let scale = max(1, config.nWindowInfer / max(1, config.nWindow * 2))
        let windowAfterCNN = max(1, maxLenAfterCNN * scale)
        var cuChunkLens = [0]
        for len in sampleLengthsAfterCNN {
            let full = len / windowAfterCNN
            if full > 0 {
                cuChunkLens.append(contentsOf: [Int](repeating: windowAfterCNN, count: full))
            }
            let rem = len % windowAfterCNN
            if rem > 0 {
                cuChunkLens.append(rem)
            }
        }
        if cuChunkLens.count == 1 {
            cuChunkLens.append(hiddenStates.dim(0))
        }
        var cuSeqlens = [Int]()
        cuSeqlens.reserveCapacity(cuChunkLens.count + 1)
        var running = 0
        cuSeqlens.append(0)
        for len in cuChunkLens.dropFirst() {
            running += len
            cuSeqlens.append(min(running, hiddenStates.dim(0)))
        }

        let disableMask = ProcessInfo.processInfo.environment["VOICESCRIBE_AUDIO_NO_MASK"] == "1"
        let attentionMask: MLXArray? = disableMask
            ? nil
            : Self.createBlockAttentionMask(seqLen: hiddenStates.dim(0), cuSeqlens: cuSeqlens)
                .expandedDimensions(axis: 0)
                .expandedDimensions(axis: 0)
        hiddenStates = contiguous(hiddenStates.expandedDimensions(axis: 0))
        Self.debugStats("beforeTransformer", hiddenStates)
        for (layerIndex, layer) in layers.enumerated() {
            hiddenStates = layer(hiddenStates, mask: attentionMask)
            MLX.eval(hiddenStates)
            if layerIndex == 0 || layerIndex == layers.count - 1 {
                Self.debugStats("afterLayer\(layerIndex)", hiddenStates)
            }
        }
        Self.debugStats("afterTransformer", hiddenStates)

        hiddenStates = hiddenStates[0, 0..., 0...]
        hiddenStates = applyLayerNorm(hiddenStates, norm: lnPost)
        hiddenStates = gelu(proj1(hiddenStates))
        hiddenStates = proj2(hiddenStates)
        Self.debugStats("afterProj", hiddenStates)
        return hiddenStates
    }

    private static func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        precondition(divisor > 0, "divisor must be > 0")
        if value >= 0 {
            return value / divisor
        }
        return -(((-value) + divisor - 1) / divisor)
    }

    private static func getFeatExtractOutputLengths(_ inputLengths: [Int]) -> [Int] {
        inputLengths.map { length in
            let inputLengthsLeave = length % 100
            let featLengths = floorDiv(inputLengthsLeave - 1, 2) + 1
            return floorDiv(floorDiv(featLengths - 1, 2) + 1 - 1, 2) + 1 + floorDiv(length, 100) * 13
        }
    }

    private static func createBlockAttentionMask(seqLen: Int, cuSeqlens: [Int]) -> MLXArray {
        if seqLen <= 0 {
            return MLXArray.zeros([0, 0], dtype: .float32)
        }
        var values = [Float](repeating: -1e9, count: seqLen * seqLen)
        if cuSeqlens.count < 2 {
            for i in 0..<seqLen {
                let rowBase = i * seqLen
                for j in 0..<seqLen {
                    values[rowBase + j] = 0
                }
            }
            return MLXArray(values, [seqLen, seqLen])
        }

        for i in 0..<(cuSeqlens.count - 1) {
            let start = max(0, min(cuSeqlens[i], seqLen))
            let end = max(start, min(cuSeqlens[i + 1], seqLen))
            if start < end {
                for row in start..<end {
                    let rowBase = row * seqLen
                    for col in start..<end {
                        values[rowBase + col] = 0
                    }
                }
            }
        }
        return MLXArray(values, [seqLen, seqLen])
    }
}
