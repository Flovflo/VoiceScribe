//
//  Qwen2.swift
//  VoiceScribeCore
//
//  Local Qwen2 implementation for VoiceScribe native MLX runtime.
//

import Foundation
import MLX
import MLXNN

// MARK: - Helper Classes

@inline(__always)
private func applyRMSNorm(_ input: MLXArray, norm: RMSNorm) -> MLXArray {
    let x32 = input.asType(.float32)
    let featureAxis = x32.ndim - 1
    let variance = mean(square(x32), axis: featureAxis, keepDims: true)
    let normalized = x32 * rsqrt(variance + MLXArray(Float(norm.eps)))
    return normalized * norm.weight.asType(.float32)
}

public class QwenKVCache {
    var keys: MLXArray?
    var values: MLXArray?
    public var offset: Int = 0
    public let step = 256
    
    public init() {}
    
    public func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        let prev = offset
        
        // Initialize or expand cache if needed
        if self.keys == nil || (prev + keys.dim(2)) > self.keys!.dim(2) {
            let B = keys.dim(0)
            let nHeads = keys.dim(1)
            let kHeadDim = keys.dim(3)
            let vHeadDim = values.dim(3)
            
            // Allocate new size in steps
            let needed = prev + keys.dim(2)
            let newSize = ((needed + step - 1) / step) * step
            
            let kShape = [B, nHeads, newSize, kHeadDim]
            let vShape = [B, nHeads, newSize, vHeadDim]
            
            let newK = MLXArray.zeros(kShape, dtype: keys.dtype)
            let newV = MLXArray.zeros(vShape, dtype: values.dtype)
            
            if let oldK = self.keys, let oldV = self.values {
                // Copy existing data
                newK[.ellipsis, ..<prev, 0...] = oldK[.ellipsis, ..<prev, 0...]
                newV[.ellipsis, ..<prev, 0...] = oldV[.ellipsis, ..<prev, 0...]
            }
            
            self.keys = newK
            self.values = newV
        }
        
        // Update offset
        self.offset += keys.dim(2)
        
        // Write new data
        self.keys![.ellipsis, prev..<self.offset, 0...] = keys
        self.values![.ellipsis, prev..<self.offset, 0...] = values
        
        // Return valid slice
        return (
            self.keys![.ellipsis, ..<self.offset, 0...],
            self.values![.ellipsis, ..<self.offset, 0...]
        )
    }
}

// MARK: - Model Classes

class Qwen2Attention: Module {
    let args: Qwen2Configuration
    let scale: Float
    let headDim: Int

    @ModuleInfo(key: "q_proj") var wq: Linear
    @ModuleInfo(key: "k_proj") var wk: Linear
    @ModuleInfo(key: "v_proj") var wv: Linear
    @ModuleInfo(key: "o_proj") var wo: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    let invFreqData: [Float]
    let ropeScale: Float

    private func createAdditiveCausalMask(queryLen: Int, offset: Int) -> MLXArray {
        let rinds = expandedDimensions(MLXArray(Int32(0) ..< Int32(offset + queryLen)), axis: 0)
        let linds = expandedDimensions(MLXArray(Int32(offset) ..< Int32(offset + queryLen)), axis: 1)
        let blocked = (linds .< rinds).asType(.float32)
        return blocked * MLXArray(-1e9 as Float)
    }

    public init(_ args: Qwen2Configuration) {
        self.args = args

        let dim = args.hiddenSize
        let heads = args.attentionHeads
        let kvHeads = args.kvHeads

        let headDim = args.hiddenSize / heads
        self.headDim = headDim
        self.scale = pow(Float(headDim), -0.5)

        _wq.wrappedValue = Linear(dim, heads * headDim, bias: false)
        _wk.wrappedValue = Linear(dim, kvHeads * headDim, bias: false)
        _wv.wrappedValue = Linear(dim, kvHeads * headDim, bias: false)
        _wo.wrappedValue = Linear(heads * headDim, dim, bias: false)
        _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)
        _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)

        let ropeScale: Float
        if let ropeScaling = args.ropeScaling, ropeScaling["type"] == .string("linear"),
            let factor = ropeScaling["factor"]
        {
            if let v = factor.asFloat() {
                ropeScale = 1 / v
            } else {
                ropeScale = 1
            }
        } else {
            ropeScale = 1
        }
        self.ropeScale = ropeScale
        let half = max(1, headDim / 2)
        let base = max(args.ropeTheta, 1)
        var inv = [Float]()
        inv.reserveCapacity(half)
        for i in 0..<half {
            inv.append(1.0 / pow(base, Float(i) / Float(half)))
        }
        self.invFreqData = inv
    }

    private func applyRotaryEmbedding(_ x: MLXArray, offset: Int) -> MLXArray {
        let sequenceLength = x.dim(2)
        if sequenceLength <= 0 || headDim < 2 {
            return x
        }

        var positions = MLXArray(Int32(offset) ..< Int32(offset + sequenceLength)).asType(.float32)
        if ropeScale != 1 {
            positions = positions * MLXArray(ropeScale)
        }

        let invFreq = MLXArray(invFreqData, [max(1, headDim / 2)]).asType(.float32)
        let freqs = positions.expandedDimensions(axis: 1) * invFreq.expandedDimensions(axis: 0)
        let emb = concatenated([freqs, freqs], axis: 1).asType(x.dtype)
        let cosEmb = cos(emb).expandedDimensions(axis: 0).expandedDimensions(axis: 0)
        let sinEmb = sin(emb).expandedDimensions(axis: 0).expandedDimensions(axis: 0)

        let half = headDim / 2
        let firstHalf = x[0..., 0..., 0..., ..<half]
        let secondHalf = x[0..., 0..., 0..., half...]
        let rotated = concatenated([(-secondHalf), firstHalf], axis: -1)
        return (x * cosEmb) + (rotated * sinEmb)
    }

    public func callAsFunction(
        _ x: MLXArray, mask: MLXArray?, cache: QwenKVCache?
    ) -> MLXArray {
        let (B, L) = (x.dim(0), x.dim(1))

        var queries = wq(x)
        var keys = wk(x)
        var values = wv(x)

        // prepare the queries, keys and values for the attention computation
        queries = queries.reshaped(B, L, args.attentionHeads, -1).transposed(0, 2, 1, 3)
        keys = keys.reshaped(B, L, args.kvHeads, -1).transposed(0, 2, 1, 3)
        values = values.reshaped(B, L, args.kvHeads, -1).transposed(0, 2, 1, 3)
        queries = applyRMSNorm(queries, norm: qNorm)
        keys = applyRMSNorm(keys, norm: kNorm)

        let offset: Int
        if let cache {
            offset = cache.offset
            let ropeQueries = applyRotaryEmbedding(queries, offset: offset)
            let ropeKeys = applyRotaryEmbedding(keys, offset: offset)
            if ProcessInfo.processInfo.environment["VOICESCRIBE_DEBUG_ROPE"] == "1",
               offset == 0,
               L > 1 {
                Qwen2Model.debugStats("rope.q.diff", abs(ropeQueries - queries))
                Qwen2Model.debugStats("rope.k.diff", abs(ropeKeys - keys))
            }
            queries = ropeQueries
            keys = ropeKeys
            (keys, values) = cache.update(keys: keys, values: values)
        } else {
            offset = 0
            let ropeQueries = applyRotaryEmbedding(queries, offset: 0)
            let ropeKeys = applyRotaryEmbedding(keys, offset: 0)
            if ProcessInfo.processInfo.environment["VOICESCRIBE_DEBUG_ROPE"] == "1" {
                Qwen2Model.debugStats("rope.q.diff", abs(ropeQueries - queries))
                Qwen2Model.debugStats("rope.k.diff", abs(ropeKeys - keys))
            }
            queries = ropeQueries
            keys = ropeKeys
        }

        var attentionKeys = keys
        var attentionValues = values
        if args.kvHeads != args.attentionHeads {
            let repeats = max(1, args.attentionHeads / args.kvHeads)
            attentionKeys = repeated(keys, count: repeats, axis: 1)
            attentionValues = repeated(values, count: repeats, axis: 1)
        }

        let attentionMask = createAdditiveCausalMask(queryLen: queries.dim(2), offset: offset)
            .asType(queries.dtype)
        let output = scaledDotProductAttention(
            queries: queries,
            keys: attentionKeys,
            values: attentionValues,
            scale: scale,
            mask: attentionMask
        )
            .transposed(0, 2, 1, 3)
            .reshaped(B, L, -1)

        return wo(output)
    }
}

class Qwen2MLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "down_proj") var down: Linear
    @ModuleInfo(key: "up_proj") var up: Linear

    public init(dimensions: Int, hiddenDimensions: Int) {
        _gate.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
        _down.wrappedValue = Linear(hiddenDimensions, dimensions, bias: false)
        _up.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        down(silu(gate(x)) * up(x))
    }
}

class Qwen2TransformerBlock: Module {
    @ModuleInfo(key: "self_attn") var attention: Qwen2Attention
    let mlp: Qwen2MLP

    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm
    private let layerIndex: Int

    public init(_ args: Qwen2Configuration, layerIndex: Int) {
        self.layerIndex = layerIndex
        _attention.wrappedValue = Qwen2Attention(args)
        self.mlp = Qwen2MLP(dimensions: args.hiddenSize, hiddenDimensions: args.intermediateSize)
        _inputLayerNorm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize, eps: args.rmsNormEps)
        _postAttentionLayerNorm.wrappedValue = RMSNorm(
            dimensions: args.hiddenSize, eps: args.rmsNormEps)
    }

    public func callAsFunction(
        _ x: MLXArray, mask: MLXArray?, cache: QwenKVCache?
    ) -> MLXArray {
        let debugLayer0 = ProcessInfo.processInfo.environment["VOICESCRIBE_DEBUG_TEXT_LAYER0"] == "1" && layerIndex == 0
        let inputNorm = applyRMSNorm(x, norm: inputLayerNorm)
        if debugLayer0 {
            Qwen2Model.debugStats("layer0.input_ln", inputNorm)
        }

        var r = attention(inputNorm, mask: mask, cache: cache)
        if debugLayer0 {
            Qwen2Model.debugStats("layer0.attn", r)
        }
        let h = x + r
        if debugLayer0 {
            Qwen2Model.debugStats("layer0.after_attn_res", h)
        }

        let postAttnNorm = applyRMSNorm(h, norm: postAttentionLayerNorm)
        if debugLayer0 {
            Qwen2Model.debugStats("layer0.post_attn_ln", postAttnNorm)
        }
        r = mlp(postAttnNorm)
        if debugLayer0 {
            Qwen2Model.debugStats("layer0.mlp", r)
        }
        let out = h + r
        if debugLayer0 {
            Qwen2Model.debugStats("layer0.out", out)
        }
        return out
    }
}

public class Qwen2ModelInner: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding

    // Changed to internal (implicitly) to support internal type Qwen2TransformerBlock
    let layers: [Qwen2TransformerBlock]
    let norm: RMSNorm

    public init(_ args: Qwen2Configuration) {
        _embedTokens.wrappedValue = Embedding(
            embeddingCount: args.vocabularySize, dimensions: args.hiddenSize)

        self.layers = (0 ..< args.hiddenLayers)
            .map { index in
                Qwen2TransformerBlock(args, layerIndex: index)
            }
        self.norm = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [QwenKVCache]? = nil) -> MLXArray {
        var h = embedTokens(inputs)
        
        // Simplified mask creation relying on attention implementation or external mask
        // Here we create mask if needed.
        let mask = createAttentionMask(h: h, cache: cache?.first)

        for (i, layer) in layers.enumerated() {
            h = layer(h, mask: mask, cache: cache?[i])
        }

        return applyRMSNorm(h, norm: norm)
    }
}

public class Qwen2Model: Module {
    public let vocabularySize: Int
    public let kvHeads: [Int]

    public let model: Qwen2ModelInner
    let configuration: Qwen2Configuration

    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    public init(_ args: Qwen2Configuration) {
        self.configuration = args
        self.vocabularySize = args.vocabularySize
        self.kvHeads = (0 ..< args.hiddenLayers).map { _ in args.kvHeads }
        self.model = Qwen2ModelInner(args)

        if !args.tieWordEmbeddings {
            _lmHead.wrappedValue = Linear(args.hiddenSize, args.vocabularySize, bias: false)
        }
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [QwenKVCache]?) -> MLXArray {
        var out = model(inputs, cache: cache)
        if let lmHead {
            out = lmHead(out)
        } else {
            out = model.embedTokens.asLinear(out)
        }
        return out
    }
    
    public func embed(_ inputs: MLXArray) -> MLXArray {
        return model.embedTokens(inputs)
    }
    
    public func forwardWithEmbeddings(_ embeddings: MLXArray, cache: [QwenKVCache]? = nil) -> MLXArray {
        var h = embeddings
        let debugTextModel = ProcessInfo.processInfo.environment["VOICESCRIBE_DEBUG_TEXT_MODEL"] == "1"
        if debugTextModel {
            Self.debugStats("inputs_embeds", h)
        }
        let mask = createAttentionMask(h: h, cache: cache?.first)
    
        for (i, layer) in model.layers.enumerated() {
            h = layer(h, mask: mask, cache: cache?[i])
            if debugTextModel, i == 0 || i == model.layers.count - 1 {
                Self.debugStats("after_layer\(i)", h)
            }
        }
        
        h = applyRMSNorm(h, norm: model.norm)
        if debugTextModel {
            Self.debugStats("after_final_norm", h)
        }
        
        if let lmHead {
            let logits = lmHead(h)
            if debugTextModel {
                Self.debugStats("logits", logits)
                let lastLogits = logits[0, -1, 0...]
                let argmax = argMax(lastLogits).item(Int.self)
                print("[Qwen2Model] argmax_last=\(argmax)")
            }
            return logits
        } else {
            let logits = model.embedTokens.asLinear(h)
            if debugTextModel {
                Self.debugStats("logits", logits)
                let lastLogits = logits[0, -1, 0...]
                let argmax = argMax(lastLogits).item(Int.self)
                print("[Qwen2Model] argmax_last=\(argmax)")
            }
            return logits
        }
    }

    fileprivate static func debugStats(_ label: String, _ value: MLXArray) {
        let flat = value.asType(.float32).asArray(Float.self)
        let meanAbs = flat.reduce(0) { $0 + abs($1) } / Float(max(flat.count, 1))
        let mean = flat.reduce(0, +) / Float(max(flat.count, 1))
        let maxAbs = flat.map { abs($0) }.max() ?? 0
        print("[Qwen2Model] \(label) shape=\(value.shape) meanAbs=\(meanAbs) mean=\(mean) maxAbs=\(maxAbs)")
    }
}

// MARK: - Utilities

func createAttentionMask(h: MLXArray, cache: QwenKVCache?) -> MLXArray? {
    let t = h.dim(1)
    if t > 0 {
        let offset = cache?.offset ?? 0
        let rinds = expandedDimensions(MLXArray(Int32(0) ..< Int32(offset + t)), axis: 0)
        let linds = expandedDimensions(MLXArray(Int32(offset) ..< Int32(offset + t)), axis: 1)
        let blocked = (linds .< rinds).asType(.float32)
        return blocked * MLXArray(-1e9 as Float)
    }
    return nil
}

// MARK: - Configuration

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Float)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let x = try? container.decode(String.self) {
            self = .string(x)
            return
        }
        if let x = try? container.decode(Float.self) {
            self = .number(x)
            return
        }
        if let x = try? container.decode(Bool.self) {
            self = .bool(x)
            return
        }
        if let x = try? container.decode([JSONValue].self) {
            self = .array(x)
            return
        }
        if let x = try? container.decode([String: JSONValue].self) {
            self = .object(x)
            return
        }
        if container.decodeNil() {
            self = .null
            return
        }
        throw DecodingError.typeMismatch(
            JSONValue.self,
            DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "Wrong type for JSONValue"))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let x): try container.encode(x)
        case .number(let x): try container.encode(x)
        case .bool(let x): try container.encode(x)
        case .array(let x): try container.encode(x)
        case .object(let x): try container.encode(x)
        case .null: try container.encodeNil()
        }
    }
    
    public func asFloat() -> Float? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Float(s)
        default: return nil
        }
    }
}

public struct Qwen2Configuration: Codable, Sendable {
    var hiddenSize: Int
    var hiddenLayers: Int
    var intermediateSize: Int
    var attentionHeads: Int
    var rmsNormEps: Float
    var vocabularySize: Int
    var kvHeads: Int
    var ropeTheta: Float = 1_000_000
    var ropeTraditional: Bool = false
    var ropeScaling: [String: JSONValue]? = nil
    var tieWordEmbeddings = false

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case hiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case attentionHeads = "num_attention_heads"
        case rmsNormEps = "rms_norm_eps"
        case vocabularySize = "vocab_size"
        case kvHeads = "num_key_value_heads"
        case ropeTheta = "rope_theta"
        case ropeTraditional = "rope_traditional"
        case ropeScaling = "rope_scaling"
        case tieWordEmbeddings = "tie_word_embeddings"
    }
    
    public init(hiddenSize: Int, hiddenLayers: Int, intermediateSize: Int, attentionHeads: Int, rmsNormEps: Float, vocabularySize: Int, kvHeads: Int) {
        self.hiddenSize = hiddenSize
        self.hiddenLayers = hiddenLayers
        self.intermediateSize = intermediateSize
        self.attentionHeads = attentionHeads
        self.rmsNormEps = rmsNormEps
        self.vocabularySize = vocabularySize
        self.kvHeads = kvHeads
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.hiddenSize = try container.decode(Int.self, forKey: .hiddenSize)
        self.hiddenLayers = try container.decode(Int.self, forKey: .hiddenLayers)
        self.intermediateSize = try container.decode(Int.self, forKey: .intermediateSize)
        self.attentionHeads = try container.decode(Int.self, forKey: .attentionHeads)
        self.rmsNormEps = try container.decode(Float.self, forKey: .rmsNormEps)
        self.vocabularySize = try container.decode(Int.self, forKey: .vocabularySize)
        self.kvHeads = try container.decode(Int.self, forKey: .kvHeads)
        self.ropeTheta = try container.decodeIfPresent(Float.self, forKey: .ropeTheta) ?? 1_000_000
        self.ropeTraditional = try container.decodeIfPresent(Bool.self, forKey: .ropeTraditional) ?? false
        self.ropeScaling = try container.decodeIfPresent([String: JSONValue].self, forKey: .ropeScaling)
        self.tieWordEmbeddings = try container.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? false
    }
}
