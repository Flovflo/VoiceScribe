//
//  Qwen3ASR.swift
//  VoiceScribeCore
//
//  Top-level Qwen3-ASR Model
//

import Foundation
import MLX
import MLXNN
import Tokenizers 

public class Qwen3ASR: Module {
    @ModuleInfo(key: "audio_tower") var audioTower: Qwen3AudioEncoder
    @ModuleInfo(key: "language_model") var languageModel: Qwen2Model
    
    // State for prefill injection
    public var currentAudioFeatures: MLXArray?
    
    public init(audioConfig: Qwen3AudioConfiguration, textConfig: Qwen2Configuration) {
        _audioTower.wrappedValue = Qwen3AudioEncoder(config: audioConfig)
        _languageModel.wrappedValue = Qwen2Model(textConfig)
    }
    
    public func encodeAudio(_ features: MLXArray) -> MLXArray {
        audioTower(features)
    }

    // Manual prefill/decode logic matching Qwen3-ASR token/audio merge semantics.
    public func generate(
        audioFeatures: MLXArray,
        tokenizer: any Tokenizer,
        audioTokenID: Int,
        language: String?,
        context: String = "",
        maxTokens: Int = 448
    ) -> String {
        var audioEmbeds = encodeAudio(audioFeatures)
        if ProcessInfo.processInfo.environment["VOICESCRIBE_REPEAT_AUDIO_ENCODE"] == "1" {
            if ProcessInfo.processInfo.environment["VOICESCRIBE_DEBUG_AUDIO_WEIGHT_DRIFT"] == "1" {
                let before = audioTower.parameters().flattened().first {
                    $0.0 == "layers.0.self_attn.q_proj.weight"
                }?.1
                if let before {
                    let fp = before.asType(.float32).asArray(Float.self)
                    let meanAbs = fp.reduce(0) { $0 + abs($1) } / Float(max(fp.count, 1))
                    print("[Qwen3ASR] layer0.q_proj.before meanAbs=\(meanAbs)")
                }
            }
            MLX.eval(audioEmbeds)
            let firstFlat = audioEmbeds.asType(.float32).asArray(Float.self)
            let secondPass = encodeAudio(audioFeatures)
            MLX.eval(secondPass)
            if ProcessInfo.processInfo.environment["VOICESCRIBE_DEBUG_AUDIO_WEIGHT_DRIFT"] == "1" {
                let after = audioTower.parameters().flattened().first {
                    $0.0 == "layers.0.self_attn.q_proj.weight"
                }?.1
                if let after {
                    let fp = after.asType(.float32).asArray(Float.self)
                    let meanAbs = fp.reduce(0) { $0 + abs($1) } / Float(max(fp.count, 1))
                    print("[Qwen3ASR] layer0.q_proj.after meanAbs=\(meanAbs)")
                }
            }
            let secondFlat = secondPass.asType(.float32).asArray(Float.self)
            let count = min(firstFlat.count, secondFlat.count)
            if count > 0 {
                var totalDiff: Float = 0
                var maxDiff: Float = 0
                for i in 0..<count {
                    let diff = abs(firstFlat[i] - secondFlat[i])
                    totalDiff += diff
                    if diff > maxDiff { maxDiff = diff }
                }
                let meanDiff = totalDiff / Float(count)
                print("[Qwen3ASR] repeatAudioEncode meanDiff=\(meanDiff) maxDiff=\(maxDiff)")
            }
        }
        if audioEmbeds.ndim == 2 {
            audioEmbeds = audioEmbeds.expandedDimensions(axis: 0)
        }
        let audioTokenCount = max(1, audioEmbeds.dim(1))
        let debugASR = ProcessInfo.processInfo.environment["VOICESCRIBE_DEBUG_ASR"] == "1"
        let promptMode = ProcessInfo.processInfo.environment["VOICESCRIBE_PROMPT_MODE"]?.lowercased() ?? "manual"

        let promptTokens: [Int]
        if promptMode == "raw" {
            let rawPrompt = Self.buildPromptString(
                numAudioTokens: audioTokenCount,
                language: language,
                context: context
            )
            promptTokens = tokenizer.encode(text: rawPrompt, addSpecialTokens: false)
        } else {
            promptTokens = Self.buildPromptTokenIDs(
                numAudioTokens: audioTokenCount,
                language: language,
                context: context,
                tokenizer: tokenizer,
                audioTokenID: audioTokenID
            )
        }
        if debugASR {
            let promptAudioCount = promptTokens.reduce(into: 0) { partial, token in
                if token == audioTokenID {
                    partial += 1
                }
            }
            let audioArray = audioEmbeds.asArray(Float.self)
            let audioMeanAbs = audioArray.reduce(0.0) { $0 + abs($1) } / Float(max(audioArray.count, 1))
            let audioMaxAbs = audioArray.map { abs($0) }.max() ?? 0
            let promptPreview = tokenizer.decode(tokens: promptTokens, skipSpecialTokens: false)
            print("[Qwen3ASR] audioFeatures=\(audioFeatures.shape) audioEmbeds=\(audioEmbeds.shape) promptTokens=\(promptTokens.count) promptAudioTokens=\(promptAudioCount)")
            print("[Qwen3ASR] audioEmbedsMeanAbs=\(audioMeanAbs) audioEmbedsMaxAbs=\(audioMaxAbs)")
            print("[Qwen3ASR] promptTokenIDs=\(promptTokens)")
            print("[Qwen3ASR] promptDecoded=\(promptPreview.replacingOccurrences(of: "\n", with: "\\n"))")
        }
        let inputIDs = MLXArray(promptTokens).reshaped(1, -1)
        let baseEmbeddings = languageModel.embed(inputIDs)
        let zeroAudioEmbeds = ProcessInfo.processInfo.environment["VOICESCRIBE_ZERO_AUDIO_EMBEDS"] == "1"
        let audioScale: Float = {
            if let raw = ProcessInfo.processInfo.environment["VOICESCRIBE_AUDIO_EMBED_SCALE"],
               let value = Float(raw), value > 0 {
                return value
            }
            return 1.0
        }()
        let scaledAudioEmbeddings = audioScale == 1.0 ? audioEmbeds : (audioEmbeds * MLXArray(audioScale))
        let alignedAudioEmbeddings = (zeroAudioEmbeds ? MLXArray.zeros(audioEmbeds.shape, dtype: audioEmbeds.dtype) : scaledAudioEmbeddings)
            .asType(baseEmbeddings.dtype)
        let inputsEmbeds = Self.mergingAudioEmbeddings(
            tokenIDs: promptTokens,
            baseEmbeddings: baseEmbeddings,
            audioEmbeddings: alignedAudioEmbeddings,
            audioTokenID: audioTokenID
        )

        let numLayers = languageModel.model.layers.count
        let cache: [QwenKVCache] = (0..<numLayers).map { _ in QwenKVCache() }
        let useNoCache = ProcessInfo.processInfo.environment["VOICESCRIBE_NO_CACHE"] == "1"

        var runningEmbeds = inputsEmbeds
        var logits = languageModel.forwardWithEmbeddings(inputsEmbeds, cache: useNoCache ? nil : cache)

        let lastLogits = logits[0, -1, 0...]
        var nextToken = Self.selectNextToken(
            logits: lastLogits,
            hardExcluded: []
        )
        MLX.eval(logits)

        var generatedTokenIDs: [Int] = []
        generatedTokenIDs.reserveCapacity(maxTokens)
        let stopTokens = Set([tokenizer.eosTokenId, 151643, 151645].compactMap { $0 })
        let minTokensBeforeAllowingStop = 8
        if stopTokens.contains(nextToken) {
            let forced = Self.selectNextToken(
                logits: lastLogits,
                hardExcluded: stopTokens
            )
            if !stopTokens.contains(forced) {
                nextToken = forced
            }
        }
        var repeatedRun = 0
        var previousToken = -1

        for _ in 0..<maxTokens {
            // Let the model stop naturally as soon as it emits an end token.
            if stopTokens.contains(nextToken), generatedTokenIDs.count >= minTokensBeforeAllowingStop {
                break
            }

            generatedTokenIDs.append(nextToken)
            if nextToken == previousToken {
                repeatedRun += 1
            } else {
                repeatedRun = 1
            }
            previousToken = nextToken
            if repeatedRun >= 32 {
                break
            }

            if useNoCache {
                let nextInput = MLXArray([nextToken]).reshaped(1, 1)
                let nextEmbed = languageModel.embed(nextInput)
                runningEmbeds = MLX.concatenated([runningEmbeds, nextEmbed], axis: 1)
                logits = languageModel.forwardWithEmbeddings(runningEmbeds, cache: nil)
            } else {
                let nextInput = MLXArray([nextToken]).reshaped(1, 1)
                logits = languageModel(nextInput, cache: cache)
            }

            let nextLogits = logits[0, -1, 0...]
            nextToken = Self.selectNextToken(
                logits: nextLogits,
                hardExcluded: []
            )
            MLX.eval(logits)
        }

        if generatedTokenIDs.isEmpty {
            return ""
        }
        let decoded = tokenizer.decode(tokens: generatedTokenIDs, skipSpecialTokens: true)
        if debugASR {
            print("[Qwen3ASR] firstTokens=\(Array(generatedTokenIDs.prefix(24))) decoded=\(decoded)")
        }
        return decoded
    }

    private static func mergingAudioEmbeddings(
        tokenIDs: [Int],
        baseEmbeddings: MLXArray,
        audioEmbeddings: MLXArray,
        audioTokenID: Int
    ) -> MLXArray {
        let audioTokenPositions: [Int] = tokenIDs.enumerated().compactMap { index, token in
            token == audioTokenID ? index : nil
        }
        guard !audioTokenPositions.isEmpty else {
            return baseEmbeddings
        }

        let replacements = min(audioTokenPositions.count, audioEmbeddings.dim(1))
        let seqLen = baseEmbeddings.dim(1)
        let hiddenSize = baseEmbeddings.dim(2)
        let flatBase = baseEmbeddings.reshaped(seqLen, hiddenSize)

        var rows = [MLXArray]()
        rows.reserveCapacity(seqLen)
        var nextAudio = 0
        for tokenIndex in 0..<seqLen {
            if nextAudio < replacements && tokenIndex == audioTokenPositions[nextAudio] {
                rows.append(audioEmbeddings[0, nextAudio, 0...].expandedDimensions(axis: 0))
                nextAudio += 1
            } else {
                rows.append(flatBase[tokenIndex, 0...].expandedDimensions(axis: 0))
            }
        }

        let mergedFlat = MLX.concatenated(rows, axis: 0)
        return mergedFlat.reshaped(1, seqLen, hiddenSize)
    }

    private static func buildPromptTokenIDs(
        numAudioTokens: Int,
        language: String?,
        context: String,
        tokenizer: any Tokenizer,
        audioTokenID: Int
    ) -> [Int] {
        let systemText = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prefix = "<|im_start|>system\n\(systemText)<|im_end|>\n<|im_start|>user\n<|audio_start|>"
        let suffix: String
        if normalizedLanguage.isEmpty {
            suffix = "<|audio_end|><|im_end|>\n<|im_start|>assistant\n"
        } else {
            suffix = "<|audio_end|><|im_end|>\n<|im_start|>assistant\nlanguage \(normalizedLanguage)<asr_text>"
        }

        let prefixIDs = tokenizer.encode(text: prefix, addSpecialTokens: false)
        let suffixIDs = tokenizer.encode(text: suffix, addSpecialTokens: false)
        let audioIDs = Array(repeating: audioTokenID, count: max(1, numAudioTokens))

        var tokens = [Int]()
        tokens.reserveCapacity(prefixIDs.count + audioIDs.count + suffixIDs.count)
        tokens.append(contentsOf: prefixIDs)
        tokens.append(contentsOf: audioIDs)
        tokens.append(contentsOf: suffixIDs)
        return tokens
    }

    private static func buildPromptString(
        numAudioTokens: Int,
        language: String?,
        context: String
    ) -> String {
        let systemText = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let audioPads = String(repeating: "<|audio_pad|>", count: max(1, numAudioTokens))
        let base =
            "<|im_start|>system\n\(systemText)<|im_end|>\n" +
            "<|im_start|>user\n<|audio_start|>\(audioPads)<|audio_end|><|im_end|>\n" +
            "<|im_start|>assistant\n"
        if normalizedLanguage.isEmpty {
            return base
        }
        return base + "language \(normalizedLanguage)<asr_text>"
    }

    private static func selectNextToken(
        logits: MLXArray,
        hardExcluded: Set<Int>
    ) -> Int {
        let values = logits.asArray(Float.self)
        var bestIndex = 0
        var bestValue = -Float.greatestFiniteMagnitude
        for (index, value) in values.enumerated() where !hardExcluded.contains(index) {
            if value > bestValue {
                bestValue = value
                bestIndex = index
            }
        }
        return bestIndex
    }
}
