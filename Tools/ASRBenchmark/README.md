# Native MLX ASR benchmark

This separate evaluation package compares **only native Swift + MLX on the GPU**. It does not change VoiceScribe's runtime dependencies or select an app backend.

Models and weight SHA256 values are pinned in `Benchmark.swift`; transitive package versions are locked in `Package.resolved`. `mlx-audio-swift` is pinned to `8d86630ade569728aaea3dc1a29fc44e2efa719b`. The package currently requires a small recorded Swift 6 compatibility patch for non-Sendable captures in Parakeet's compiled closures. `build.sh` applies it idempotently to the separate SwiftPM checkout. It changes annotations/capture names, not model math. This tool runs each model serially and does not share it across tasks.

## Reproduce

From the VoiceScribe repository:

```sh
Tools/ASRBenchmark/build.sh
BENCHMARK_BIN="$(swift build -c release --package-path Tools/ASRBenchmark --scratch-path /tmp/voicescribe-benchmark-build --show-bin-path)/asr-benchmark"
"$BENCHMARK_BIN" --model all --prepare
for model in parakeet qwen voxtral; do
    "$BENCHMARK_BIN" --model "$model" --runs 3 --output "Tools/ASRBenchmark/Results/$model.json"
done
```

`--prepare` downloads immutable Hugging Face revisions and validates each weight file against its published LFS SHA256. `--model-root` overrides the evaluation cache; `--fixtures` overrides the corpus directory. Benchmarking also verifies the weight checksum before loading. No Python, CoreML, or subprocess inference is used. Run one model per process, without concurrent GPU inference, compilation, or heavy UI activity.

## Corpus and measurements

The two supplied fixtures are original synthesized phrases, generated on macOS with `say`: **Thomas** for French and **Samantha** for English. They were converted with `afconvert -f WAVE -d LEI16@16000` to mono 16 kHz PCM. French is 8.879 seconds; English is 9.261 seconds. The reference phrases are stored in the CLI source, and each output records the fixture SHA256.

Each model sees the same seven conditions: French and English clean, deterministic uniform white noise at 10 dB RMS SNR, three repetitions with half-second gaps (27.638/28.783 seconds), and ten seconds of digital silence. Noise uses seed 42, removes its mean, and is scaled to the exact SNR; no normalization or clipping follows. The long samples repeat the same phrase, so they test duration handling rather than vocabulary diversity.

The JSON report checkpoints after loading and every generation. It retains the first inference, one warmup for each subsequent condition, and three measured repetitions per condition. Timing uses a monotonic clock and GPU synchronization. It includes feature extraction, model inference, and text decoding from resident samples; it excludes audio file reading, model download, and checksum validation. Local load time includes tokenizer initialization and evaluating model weights. OS page caches are not flushed, so this is **local model load**, not a reboot-level cold-start measurement.

All models use greedy/default temperature 0, without language hints or VAD. Qwen and Voxtral use a 512-token limit. Parakeet uses the upstream default bfloat16 compute with stored float32 weights; its frame/symbol decoder does not consume the generic token limit. Every load and generation has a 180-second watchdog. Recoverable errors and watchdog timeouts become failed reports; a process crash leaves an incomplete `running` checkpoint, never a success. Individual empty transcripts, silence hallucinations, and token-limit hits retain their own status.

WER uses word-level Levenshtein distance, ignores case and punctuation, preserves accents, and splits apostrophes consistently. It is a ratio (0.1 = 10%), and may exceed 1. Silence has no WER denominator: emitted words and `silenceHallucination` indicate incorrect output. Raw transcripts remain available to inspect accents, punctuation, and language.

Memory is MLX's **peak active allocation**, reset per operation, including resident model weights. It is not total process RSS or every Metal/system allocation. The tool also reports active and cached MLX memory after each operation and applies a common 512 MiB cache limit. Upstream model implementations may clear their own cache.

This tiny synthetic corpus cannot establish a universally best recognizer. It excludes real microphone noise, diverse speakers/accents, spontaneous speech, names, specialist vocabulary, and streaming latency. A deployment decision needs a larger held-out corpus and actual dictation recordings. These runs test complete-clip transcription, including Voxtral's complete-clip API, not its streaming first-token latency.

## Verification

`build.sh` builds the release executable and runs four unit tests for WER normalization/edit distance and deterministic noise/SNR. CLI help, invalid model rejection, missing-fixture error persistence, and corrupted-weight checksum rejection are also checked during development. Models remain isolated from the app package.
