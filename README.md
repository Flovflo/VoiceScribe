# VoiceScribe

<div align="center">

### The local voice-to-text app for Mac: fast, private, native.

*Press one shortcut, speak, and text appears directly at your cursor.*

![macOS](https://img.shields.io/badge/macOS-14.0+-000000?style=for-the-badge&logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-Optimized-green?style=for-the-badge)
![Privacy](https://img.shields.io/badge/Privacy-100%25_Local-blue?style=for-the-badge)
![License](https://img.shields.io/badge/license-MIT-purple?style=for-the-badge)

</div>

---

## Why install VoiceScribe

VoiceScribe is designed for real daily dictation with minimal friction:

- One shortcut: `Option + Space`
- Floating HUD while recording
- Automatic text injection at the cursor
- 100% local ASR with native Swift + MLX
- No Python runtime and no external daemon

---

## VoiceScribe vs Superwhisper

Superwhisper is a strong product. VoiceScribe is built for users who specifically want a fully native Swift + MLX ASR pipeline with direct control over Qwen3-ASR variants.

| Point | VoiceScribe | Superwhisper |
|------|-------------|--------------|
| Inference stack | Native Swift 6 + `MLX` / `MLXNN` | Depends on app and configuration |
| Model family | `mlx-community/Qwen3-ASR` (0.6B/1.7B, 4bit->bf16) | Depends on selected provider/model |
| Privacy mode | Fully local transcription | Varies by mode |
| Developer transparency | Open source, auditable pipeline | Product-specific |
| Dictation workflow | Built-in hotkey + auto-paste | Product-specific |

### Why Qwen3-ASR matters

VoiceScribe uses Qwen3-ASR on MLX. On Apple Silicon, this combination is especially strong for:

- fast speech
- multilingual dictation (especially EN/FR)
- reduced degraded outputs (token artifacts and repetitions)

The result is cleaner text and a better real-time speak-to-type workflow.

---

## Performance profile

Native local architecture:

- Engine: `NativeASREngine` (Swift actor)
- Audio features: mel/log-mel extraction in Swift (`AudioFeatureExtractor`)
- GPU path: MLX by default (CPU fallback via environment variable)
- Model cache: `~/Library/Caches/VoiceScribe/models/`

Target profile (hardware/model dependent):

- fast cold start after model download
- sub-second inference for short dictation segments
- no Python bridge overhead

---

## Installation

### Requirements

- macOS 14+
- Apple Silicon (M1/M2/M3/M4)
- Metal Toolchain available

### Download

- Releases: [https://github.com/Flovflo/VoiceScribe/releases](https://github.com/Flovflo/VoiceScribe/releases)

### Build from source

```bash
git clone https://github.com/Flovflo/VoiceScribe.git
cd VoiceScribe

swift build -c release
./bundle_app.sh
open VoiceScribe.app
```

If needed:

```bash
xcodebuild -downloadComponent MetalToolchain
```

On first launch, VoiceScribe downloads the selected Qwen3-ASR model snapshot from Hugging Face.

---

## Usage

`Option + Space`

1. Press once to start recording.
2. Speak.
3. Press again to stop.
4. VoiceScribe transcribes and injects text at your cursor.

---

## Supported models

Supported ASR variants (Qwen3-ASR only):

- `mlx-community/Qwen3-ASR-0.6B-{4bit,5bit,6bit,8bit,bf16}`
- `mlx-community/Qwen3-ASR-1.7B-{4bit,5bit,6bit,8bit,bf16}`

Default model:

- `mlx-community/Qwen3-ASR-1.7B-8bit`

---

## Privacy

Your voice data stays on your machine during transcription.

- no required cloud API
- no telemetry pipeline in the core transcription path
- open-source codebase for auditability

---

## Pricing

Free.

---

## Development and validation

Core stack:

- Swift 6
- SwiftUI + AppKit
- MLX Swift (`MLX`, `MLXNN`)
- Hugging Face `swift-transformers` (tokenizer runtime)

Validation commands:

```bash
swift test
VOICESCRIBE_RUN_MLX_TESTS=1 swift test --filter AudioFeatureTests
VOICESCRIBE_RUN_ASR_TESTS=1 swift test --filter NativeEngineTests
```

Optional ASR benchmark:

```bash
VOICESCRIBE_RUN_ASR_BENCH=1 swift test --filter NativeEngineTests/testASRBenchmark
```

Native MLX migration notes:

- `docs/NATIVE_MLX_RELEASE.md`

---

## License

MIT
