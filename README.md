# VoiceScribe 🎙️

**The Invisible AI Stenographer for macOS**

![macOS](https://img.shields.io/badge/macOS-14.0+-000000?style=flat&logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-M1%2FM2%2FM3%2FM4-green)
![License](https://img.shields.io/badge/license-MIT-blue)

VoiceScribe is a native, ultra-fast, on-device speech-to-text tool for macOS. Powered by **MLX** and **Qwen3-ASR**, it runs entirely on your Apple Silicon chip—no data ever leaves your device.

---

## ✨ Features

- **100% Local** — All processing happens on your Mac
- **Privacy First** — No data leaves your device, ever
- **Ultra-Fast** — Optimized for Apple Silicon with MLX
- **Invisible UX** — Minimal floating HUD, keyboard-driven
- **Auto-Type** — Transcribed text is typed automatically

---

## 🚀 Quick Install

### Via Homebrew (Recommended)

```bash
brew tap Flovflo/voicescribe
brew install voicescribe
```

### Manual Install

```bash
git clone https://github.com/Flovflo/VoiceScribe.git
cd VoiceScribe
./install.sh
```

---

## ⌨️ Usage

| Action | Shortcut |
|--------|----------|
| Start/Stop Recording | `⌥ Option` + `Space` |

1. Press **⌥ Space** anywhere on your Mac
2. Speak when you see the floating HUD
3. Press **⌥ Space** again to stop
4. Text is automatically typed at your cursor!

---

## 🧠 Models

VoiceScribe supports multiple Qwen3-ASR models:

| Model | Size | Speed | Accuracy |
|-------|------|-------|----------|
| Qwen3-ASR-0.6B | ~600MB | ⚡ Fast | Good |
| Qwen3-ASR-1.7B | ~1.7GB | Normal | ✓ Better |

Models are downloaded automatically on first use and cached locally in `~/.cache/huggingface/`.

---

## 🛠️ Requirements

- **macOS 14.0+** (Sonoma or later)
- **Apple Silicon** (M1/M2/M3/M4)
- **Python 3.11+** with:
  - `mlx`
  - `mlx-audio`

### Install Python Dependencies

```bash
pip install mlx mlx-audio huggingface_hub
```

---

## 📦 Project Structure

```
VoiceScribe/
├── Sources/
│   ├── VoiceScribe/          # Main app (SwiftUI)
│   │   ├── VoiceScribeApp.swift
│   │   ├── OnboardingView.swift
│   │   └── SettingsView.swift
│   └── VoiceScribeCore/      # Core library
│       ├── ML/               # ASR Service
│       ├── Sensors/          # Audio recording
│       └── Utils/            # Hotkey, input injection
├── backend/
│   └── transcribe_daemon.py  # Python ASR engine
├── Formula/
│   └── voicescribe.rb        # Homebrew formula
└── Package.swift
```

---

## 🔐 Privacy

VoiceScribe is designed with privacy as the core principle:

- ✅ All audio processing happens locally on your Mac
- ✅ No network requests for transcription
- ✅ No telemetry or analytics
- ✅ Audio is never saved to disk (processed in memory)
- ✅ You own your data

---

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

---

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.

---

<p align="center">
  <sub>Built with ❤️ for Apple Silicon</sub>
</p>
