# VoiceScribe

**On-device speech-to-text for macOS** — A native Swift/SwiftUI application that captures your voice and transcribes it locally using the Qwen3-ASR model. No cloud services, complete privacy.

![macOS](https://img.shields.io/badge/macOS-14.0+-blue)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Features

- 🎤 **One-click recording** — Press the microphone button, speak, press again
- 🔒 **100% on-device** — All processing happens locally, no data leaves your Mac
- 📋 **Auto-copy to clipboard** — Transcription is automatically copied when done
- 🚀 **Fast transcription** — Uses Qwen3-ASR-1.7B optimized for Apple Silicon
- 🎯 **Simple UI** — Minimal, elegant interface that stays out of your way

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon Mac (M1/M2/M3)
- ~5 GB disk space for the model (downloaded on first run)
- Python 3.11+ with venv

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/yourusername/VoiceScribe.git
cd VoiceScribe
```

### 2. Set up Python environment

```bash
python3 -m venv venv
source venv/bin/activate
pip install torch torchaudio transformers huggingface_hub
```

### 3. Build and run

```bash
swift build
.build/debug/VoiceScribe
```

The first run will download the Qwen3-ASR model (~4.5 GB). This only happens once.

### 4. Package as .app (optional)

```bash
./package_app.sh
```

This creates `VoiceScribe.app` that you can move to `/Applications`.

## Usage

1. **Launch the app** — Wait for "Ready" status (model loading takes ~10-30s)
2. **Click the microphone** — Blue circle, starts recording
3. **Speak** — The level meter shows audio input
4. **Click again** — Stops recording, transcription starts
5. **Done!** — Text appears and is copied to clipboard

## Architecture

```
VoiceScribe/
├── Sources/
│   ├── VoiceScribe/           # SwiftUI app
│   │   └── VoiceScribeApp.swift
│   └── VoiceScribeCore/       # Core logic
│       ├── AppState.swift     # App state management
│       ├── ML/
│       │   ├── ASRModel.swift         # Transcription coordinator
│       │   └── PythonASRService.swift # Python daemon manager
│       └── Sensors/
│           └── AudioRecorder.swift    # Audio capture
├── backend/
│   └── transcribe_daemon.py   # Python ASR daemon
├── Package.swift
└── package_app.sh
```

### How it works

1. **Swift frontend** captures audio using `AVAudioEngine`
2. Audio is resampled to 16kHz and saved as WAV
3. **Python daemon** (running in background) loads Qwen3-ASR model
4. Swift sends file path to Python via stdin pipe
5. Python transcribes and returns JSON result via stdout
6. Swift displays result and copies to clipboard

## Model

Uses [Qwen3-ASR-1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) from Alibaba Cloud:
- 1.7 billion parameters
- Supports 20+ languages
- Optimized for on-device inference
- Cached in `~/Library/Application Support/VoiceScribe/models/`

## License

MIT License — see [LICENSE](LICENSE) for details.

## Credits

- [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) by Alibaba Cloud
- Built with SwiftUI and Python
