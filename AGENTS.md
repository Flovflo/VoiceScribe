# VoiceScribe – AGENTS.md (Codex CLI Guide)

## 🎯 MISSION: Full Native MLX Refactoring

You are tasked with **refactoring VoiceScribe** from a hybrid Swift+Python architecture to a **pure Swift + MLX-Swift** native implementation. The goal is to eliminate the external Python ASR daemon entirely and perform all inference directly in Swift using Apple's MLX framework.

---

## 📋 CRITICAL OBJECTIVES

1. **REMOVE all Python dependencies**:
   - Delete `PythonASRService.swift` (manages Python subprocess).
   - Remove the bundled `transcribe_daemon.py` resource.
   - Remove any reference to `mlx-lm`, `mlx-whisper`, or any Python tooling.

2. **IMPLEMENT native MLX-Swift ASR**:
   - Create a new `NativeASREngine.swift` that loads and runs an ASR model directly using `MLX` and `MLXNN`.
   - Target model: **Qwen3-ASR** (quantized 4-bit or 8-bit MLX format from Hugging Face / mlx-community).
   - The inference pipeline should:
     1. Accept raw `[Float]` audio samples (16kHz mono).
     2. Convert to Mel-spectrogram features (or the format expected by the model).
     3. Run encoder + decoder passes on MLX.
     4. Output transcribed text.

3. **OPTIMIZE for Apple Silicon (M-series)**:
   - Use `MLX` GPU-accelerated ops wherever possible.
   - Minimize memory copies between CPU and GPU.
   - Use `@Sendable` and Swift concurrency correctly for audio processing.
   - Profile and remove any hot-spots.

4. **KEEP the existing UX**:
   - The floating HUD, hotkey trigger (Option+Space), recording, and text injection must remain unchanged.
   - Only the backend (ASR pipeline) is being replaced.

---

## 🗂️ FILES TO MODIFY/CREATE

### DELETE
- `Sources/VoiceScribeCore/ML/PythonASRService.swift`
- `backend/transcribe_daemon.py` (if still referenced)

### CREATE
- `Sources/VoiceScribeCore/ML/NativeASREngine.swift`
  - Actor-based, inherits the `PythonASRService` public interface for compatibility.
  - Loads MLX model using `MLX.load()`.
  - Implements `transcribe(samples: [Float]) async -> String`.

- `Sources/VoiceScribeCore/ML/AudioFeatureExtractor.swift`
  - Converts raw audio samples to log-mel spectrogram (or Qwen3-ASR expected features).
  - Use Accelerate framework for FFT if needed (or pure MLX).

- `Sources/VoiceScribeCore/ML/TokenDecoder.swift` (optional, if not bundled with model)
  - Maps model output token IDs to strings using the bundled tokenizer.

### MODIFY
- `Sources/VoiceScribeCore/AppState.swift`
  - Replace `PythonASRService` with `NativeASREngine`.
  - Remove all Python subprocess logic.

- `Sources/VoiceScribeCore/ML/ASRModel.swift`
  - Simplify: no longer needs to write WAV files or call Python. Directly pass samples to `NativeASREngine`.

- `Package.swift`
  - Add `mlx-swift-nn` dependency if needed for model layers:
    ```swift
    .package(url: "https://github.com/ml-explore/mlx-swift-nn", from: "0.10.0")
    ```

---

## ⚡ PERFORMANCE REQUIREMENTS

| Metric              | Target                                  |
|---------------------|-----------------------------------------|
| Cold start          | < 3 seconds (model loading)             |
| Inference latency   | < 500ms for 10 seconds of audio         |
| Memory footprint    | < 1GB for 4-bit model                   |
| CPU usage           | Offload 100% to GPU via MLX             |

---

## 🧪 TESTING PLAN

1. **Unit Tests** (`VoiceScribeTests`):
   - `testAudioFeatureExtraction`: Verify spectrogram shape and dtype.
   - `testModelLoading`: Ensure model weights load without error.
   - `testTranscription`: End-to-end with a known audio sample.

2. **Integration Test**:
   - Record 5 seconds of speech via `AudioRecorder`.
   - Pass to `NativeASREngine.transcribe()`.
   - Assert output is non-empty and plausible English/French text.

3. **Benchmark**:
   - Log inference time per transcription.
   - Assert meets < 500ms target.

---

## 🔒 CONSTRAINTS

- **DO NOT** use any Python, subprocess, or shell calls.
- **DO NOT** use `mlx-whisper` (Python library). Use pure `mlx-swift`.
- **DO NOT** break the existing UI or hotkey behavior.
- **DO** use Swift 6 strict concurrency (`Sendable`, `actor`, `@MainActor`).
- **DO** handle model download gracefully (show progress in UI).

---

## 📦 MODEL DETAILS

- **Model ID**: `mlx-community/Qwen3-ASR-1.7B-4bit` (or 8-bit variant)
- **Format**: Safetensors + MLX config
- **Download**: On first launch, download from Hugging Face Hub to `~/Library/Caches/VoiceScribe/models/`.
- **Tokenizer**: `tokenizer.json` bundled with model weights.

---

## 🚀 BRANCH & WORKFLOW

1. Create a new branch: `refactor/native-mlx`
2. Commit incrementally:
   - `chore: remove Python ASR service`
   - `feat: add NativeASREngine with MLX model loading`
   - `feat: implement mel-spectrogram extraction`
   - `feat: wire up end-to-end transcription`
   - `perf: optimize GPU memory and inference latency`
   - `test: add unit tests for ASR pipeline`
3. Run `swift build -c release --arch arm64` and ensure no warnings.
4. Run `swift test` and ensure all tests pass.
5. Open PR back to `main`.

---

## ✅ ACCEPTANCE CRITERIA

- [ ] App builds with `swift build -c release` with zero warnings.
- [ ] App runs without any Python runtime or dependencies.
- [ ] Transcription works end-to-end for English and French audio.
- [ ] Inference completes in < 500ms for 10s audio clip.
- [ ] All tests pass.
- [ ] No regressions in UX (HUD, hotkey, clipboard, paste).
