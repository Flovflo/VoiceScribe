# VoiceScribe Native MLX Notes

This document is the technical companion to the main README.

It explains what changed in the native MLX refactor, how the app is wired internally, how it was validated, and which limits are still open.

## Goals

- remove the Python ASR daemon entirely
- keep dictation UX unchanged
- run speech-to-text natively in Swift on Apple Silicon
- make packaging, debugging, and crash behavior much cleaner

## What Changed

VoiceScribe now uses a native Swift ASR pipeline:

- `NativeASREngine` loads Qwen3-ASR MLX model snapshots directly
- `AudioFeatureExtractor` computes Qwen3-compatible log-mel features in Swift
- `NativeASRService` publishes engine state to the UI
- `AppState` coordinates loading, recording, transcription, clipboard copy, and auto-paste

What was intentionally removed from the architecture:

- Python subprocess orchestration
- external ASR daemon lifecycle management
- cross-language logging and error translation
- Python runtime packaging concerns

## Why MLX Is A Good Fit

MLX is especially compelling here because VoiceScribe is a macOS-only dictation app for Apple Silicon.

Benefits in this project:

- Metal-backed tensor runtime without leaving the Apple stack
- one language runtime for UI, audio, and inference
- simpler release bundles
- simpler crash diagnosis because there is one process, not an app plus a sidecar service
- direct control over model validation, loading, tokenizer behavior, and fallback policy

This matters a lot for a utility app. A dictation app must feel boring, predictable, and always available.

## Architecture

### User flow

1. `Option + Space` triggers the hotkey manager.
2. `AppState` starts or stops recording.
3. `AudioRecorder` captures microphone audio and resamples it to 16 kHz mono.
4. `AudioFeatureExtractor` produces log-mel features.
5. `NativeASREngine` runs Qwen3-ASR locally with MLX.
6. The decoded transcript is cleaned.
7. The transcript is copied and pasted into the active application.

### Internal modules

| Module | Responsibility |
|---|---|
| `AudioRecorder` | microphone selection, permission handling, capture, resampling |
| `AudioFeatureExtractor` | log-mel feature extraction |
| `MLXMelSpectrogram` | GPU feature extraction path |
| `NativeASREngine` | model snapshot download, config validation, weight loading, inference |
| `Qwen3ASR` / `Qwen3Audio` / `Qwen2` | local model implementation |
| `NativeASRService` | UI-facing state wrapper |
| `AppState` | end-to-end dictation orchestration |
| `HotKeyManager` | hotkey registration and debounce |

## Reliability Hardening In This Pass

The recent hardening work focused on issues that make a desktop utility feel flaky.

### Fixed

- app crash on activation / AppKit callback path
- status-item and shortcut becoming unusable because the app process had crashed
- preferred microphone startup failure leaving the user stuck on `No audio`
- model-selection errors being swallowed instead of surfacing deterministically
- app shutdown leaving recorder or engine state dirty
- release test builds missing the hotkey test hook

### Behavioral changes

- AppKit entry points are now safely re-hopped to the main actor
- if a selected microphone fails, VoiceScribe retries with the system default microphone
- model-selection failures now reliably update `lastError` and `AppState.errorMessage`
- shutdown explicitly resets transient state

## Validation Matrix

The following validations were run during the refactor on April 3, 2026.

### Core build and tests

```bash
swift test
swift build -c release --arch arm64
```

Status:

- passed

### MLX feature validation

```bash
VOICESCRIBE_RUN_MLX_TESTS=1 swift test --filter AudioFeatureTests
```

Status:

- passed

Coverage:

- MLX feature extraction shape
- MLX vs CPU feature parity

### Real model load and inference

```bash
VOICESCRIBE_RUN_ASR_TESTS=1 swift test --filter NativeEngineTests/testModelLoadingAndBasicInference
```

Status:

- passed

### Real sample-audio transcription

French:

```bash
say -v Thomas "bonjour ceci est un test de transcription rapide" -o /tmp/voicescribe_fr.aiff
afconvert -f WAVE -d LEI16@16000 /tmp/voicescribe_fr.aiff /tmp/voicescribe_fr.wav
VOICESCRIBE_RUN_ASR_TESTS=1 \
VOICESCRIBE_TEST_AUDIO=/tmp/voicescribe_fr.wav \
VOICESCRIBE_EXPECT_KEYWORDS='bonjour,test' \
swift test --filter NativeEngineTests/testTranscriptionWithSampleAudio
```

English:

```bash
say -v Samantha "hello this is a fast speech transcription quality check" -o /tmp/voicescribe_en.aiff
afconvert -f WAVE -d LEI16@16000 /tmp/voicescribe_en.aiff /tmp/voicescribe_en.wav
VOICESCRIBE_RUN_ASR_TESTS=1 \
VOICESCRIBE_TEST_AUDIO=/tmp/voicescribe_en.wav \
VOICESCRIBE_EXPECT_KEYWORDS='hello,transcription' \
swift test --filter NativeEngineTests/testTranscriptionWithSampleAudio
```

Status:

- passed in both languages

## Performance Status

The project includes an explicit benchmark:

```bash
VOICESCRIBE_RUN_ASR_BENCH=1 swift test -c release --filter NativeEngineTests/testASRBenchmark
```

Current honest status:

- the benchmark is useful and should stay in the repository
- on the validation machine used in this pass, it did not yet meet the current `1000 ms` threshold
- measured release performance remained roughly around `1330 ms` for the synthetic 10-second benchmark clip

Interpretation:

- functional quality is validated
- MLX runtime is working correctly
- performance optimization is still an open engineering task

The app should not claim the stricter target until the benchmark gate is green.

## Packaging Notes

Use:

```bash
./package_app.sh
```

The packaging flow:

- builds the release binary
- bundles MLX metallib assets into the app
- generates `Info.plist`
- builds the app icon
- signs the bundle ad hoc by default

Installed app path:

- `/Applications/VoiceScribe.app`

## Known Limits

- the synthetic ASR benchmark gate is still above target
- first model load is naturally slower because weights must be downloaded and cached
- real-world latency depends on model size, microphone quality, and Apple Silicon generation

## Recommended Next Work

1. profile the release benchmark path with cached weights and warm kernels
2. reduce avoidable re-decode work in the benchmark path
3. measure chunking overhead on short vs long clips
4. add a repeatable release benchmark report artifact for every performance pass
