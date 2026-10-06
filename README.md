# VoiceScribe

Native local AI dictation for macOS, powered by Qwen3-ASR and MLX.

Press `Option + Space`, speak, press it again, and VoiceScribe pastes clean text back into the app you are using.

VoiceScribe is built for people who want a real offline speech-to-text app for Mac, not a desktop shell hiding a Python daemon in the background.

<p align="center">
  <img src="assets/onboarding/readme-onboarding-welcome.png" alt="VoiceScribe onboarding welcome screen" width="760" />
</p>

## Onboarding

VoiceScribe now opens with a more polished first-run flow designed to feel closer to a native macOS product:

- a cinematic onboarding window that previews the HUD in context
- local model selection directly in the flow
- a simple shortcut handoff before the first real dictation
- local preparation explained before the app starts working in the background

<p align="center">
  <img src="assets/onboarding/readme-onboarding-welcome.png" alt="VoiceScribe onboarding welcome step" width="31%" />
  <img src="assets/onboarding/readme-onboarding-model.png" alt="VoiceScribe onboarding model selection step" width="31%" />
  <img src="assets/onboarding/readme-onboarding-shortcut.png" alt="VoiceScribe onboarding shortcut step" width="31%" />
</p>
<p align="center">
  <em>Speak anywhere • Choose your local model • Ready from a single shortcut</em>
</p>

The first launch can take longer because the selected Qwen3-ASR model is downloaded once and cached locally on your Mac.

## Dictation Flow

Once onboarding is complete, the app stays intentionally simple:

1. Press `Option + Space`
2. Speak normally
3. Press `Option + Space` again
4. VoiceScribe transcribes locally and pastes the result back into your current app

| Ready | Recording |
|---|---|
| ![VoiceScribe HUD ready](assets/readme-hud-ready.png) | ![VoiceScribe HUD recording](assets/readme-hud-recording.png) |

## Highlights

- Fully local speech-to-text for macOS on Apple Silicon
- Native Swift 6 + MLX runtime with Qwen3-ASR
- No cloud dependency, no Python daemon, no subprocess bridge
- One hotkey, one floating HUD, one fast dictation loop
- Automatic clipboard copy and paste injection
- Strong English and French dictation
- Native Liquid Glass on macOS 26+, with system materials on macOS 14/15
- Microphone selection scoped to VoiceScribe, without changing macOS's default input

## Why Native MLX

VoiceScribe uses a pure Swift + MLX pipeline for offline dictation on macOS.

That gives you:

- fewer moving parts
- better crash isolation
- simpler packaging
- direct Apple Silicon acceleration through Metal
- one native concurrency model across UI, audio, and inference

## Why Qwen3-ASR

Qwen3-ASR is the core reason VoiceScribe feels competitive as a local dictation app on Apple Silicon.

- fast enough for real short-form dictation workflows
- strong quality-to-latency balance in local use
- better multilingual behavior for English and French
- fewer weird artifacts than many offline speech-to-text stacks
- a good fit for MLX + Metal on Mac

## Supported Models

VoiceScribe supports `mlx-community/Qwen3-ASR` variants only.

Default model:

- `mlx-community/Qwen3-ASR-1.7B-4bit` (about 1.60 GB of weights)

Existing saved model choices are preserved. The 8-bit variant remains available in advanced settings (about 2.46 GB of weights). Runtime memory also includes activations and decoding buffers.

Voxtral Mini 4B Realtime 2602, Qwen3-ASR 1.7B 4-bit, and Parakeet TDT 0.6B v3 are evaluated separately using native Swift/MLX in [the reproducible benchmark tool](Tools/ASRBenchmark/README.md). These comparisons do not add another runtime backend to the app. See the [local results](Tools/ASRBenchmark/Results/REPORT.md) and [FR/EN research audit](docs/AUDIT_MACOS_ASR_2026-10-04.md) for measurements, sources, and corpus limitations.

## Install

Requirements:

- macOS 14+
- Apple Silicon
- microphone permission
- accessibility permission for automatic paste

Latest release:

- [Download VoiceScribe](https://github.com/Flovflo/VoiceScribe/releases/latest)

Build from source:

```bash
git clone https://github.com/Flovflo/VoiceScribe.git
cd VoiceScribe
swift build -c release --arch arm64
./package_app.sh
open VoiceScribe.app
```

Xcode's Metal Toolchain is required to compile MLX shaders. If Xcode reports that it is missing, install the component with `xcodebuild -downloadComponent MetalToolchain` and rebuild. The packaging script ships the Metal library produced by the same SwiftPM build.

## Validation

Fast suite:

```bash
swift test
```

Optional MLX validation:

```bash
VOICESCRIBE_RUN_MLX_TESTS=1 swift test --filter AudioFeatureTests
```

Optional real ASR validation:

```bash
VOICESCRIBE_RUN_ASR_TESTS=1 swift test --filter NativeEngineTests
```

To validate a known French or English speech fixture, provide a mono 16 kHz WAV and expected keywords:

```bash
VOICESCRIBE_RUN_ASR_TESTS=1 \
VOICESCRIBE_TEST_AUDIO=Tools/ASRBenchmark/Fixtures/fr.wav \
VOICESCRIBE_EXPECT_KEYWORDS=bonjour,transcription,français \
swift test --filter NativeEngineTests.testTranscriptionWithSampleAudio
```

`VOICESCRIBE_TEST_MODEL` and `VOICESCRIBE_TEST_MODEL_DIRECTORY` optionally select an existing local model snapshot. Hardware capture tests use `VOICESCRIBE_RUN_CAPTURE_TESTS=1` after microphone permission is already granted.

## Docs

- [Native MLX notes](docs/NATIVE_MLX_RELEASE.md)
- [`AGENTS.md`](AGENTS.md)

## License

MIT
