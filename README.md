# VoiceScribe 🎙️

<div align="center">

### **The Fastest Local Voice-to-Text for Mac**

*Speak. Type. Instantly.*

![macOS](https://img.shields.io/badge/macOS-14.0+-000000?style=for-the-badge&logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-Optimized-green?style=for-the-badge)
![Privacy](https://img.shields.io/badge/Privacy-100%25_Local-blue?style=for-the-badge)
![License](https://img.shields.io/badge/license-MIT-purple?style=for-the-badge)

</div>

---

## 🚀 Why VoiceScribe?

| Feature | VoiceScribe | Cloud Services | OpenAI Whisper |
|---------|-------------|----------------|----------------|
| **Privacy** | ✅ 100% Local | ❌ Uploads audio | ✅ Can run locally |
| **Speed** | ⚡ Real-time | 🐢 Network latency | 🐢 Slower |
| **Cost** | 💚 Free forever | 💸 $0.006/min+ | 💚 Free |
| **Accuracy (WER)** | **2.8%** | ~3-5% | ~4.2% |
| **Apple Silicon** | ✅ **Native Swift + MLX** | ❌ No | ⚠️ Via PyTorch |
| **Auto-Type** | ✅ Built-in | ❌ Copy/paste | ❌ Manual |
| **Dependencies** | ✅ **Zero** (No Python) | ❌ Complex | ❌ Python env |

---

## ⚡ Performance

Powered by **Qwen3-ASR** and Apple's **MLX** framework, running entirely natively in Swift.

- **Engine**: Pure Swift Implementation (No Python bridge)
- **Model**: Qwen3-ASR (0.6B / 1.7B)
- **Latnecy**: Sub-0.5s response time on M1/M2/M3 chips
- **Memory**: Optimized tensor operations via `mlx-swift`

---

## 📦 Installation

### 1. Requirements

- **macOS 14.0+** (Sonoma or later)
- **Apple Silicon** (M1/M2/M3/M4)
- **Metal Toolchain** (Required for GPU shaders)

### 2. Install

```bash
# 1. Clone
git clone https://github.com/Flovflo/VoiceScribe.git
cd VoiceScribe

# 2. Build App
./bundle_app.sh

# 3. Running for the first time
# IMPORTANT: You must install Metal Toolchain first if you haven't!
xcodebuild -downloadComponent MetalToolchain

# 4. Launch
open VoiceScribe.app
```

> **Note**: On first launch, the app will automatically download the selected model (~1.2GB) from HuggingFace to `~/.cache/huggingface`.

---

## 🎯 Usage

```
⌥ Option + Space
```

1. **Press** anywhere on your Mac
2. **Speak** when you see the floating HUD
3. **Press again** to stop
4. ✨ Text types automatically at your cursor

---

## 🧠 Models

| Model | Size | Speed | Best For |
|-------|------|-------|----------|
| **Qwen3-ASR-0.6B** | 600MB | ⚡⚡⚡ | Quick notes, casual use |
| **Qwen3-ASR-1.7B** | 1.7GB | ⚡⚡ | Professional accuracy |

*Switch models instantly in app settings.*

---

## 🔐 Privacy-First Architecture

<div align="center">

```
🎤 Your Voice → 🖥️ Your Mac → 📝 Your Text
                    ↓
            Never leaves your device
```

</div>

- ✅ **Zero network requests** for transcription
- ✅ **No telemetry** — we don't track anything
- ✅ **Audio in memory only** — never saved to disk
- ✅ **Open source** — verify it yourself

---

## 🛠️ Development

Built with:
- **Language**: Swift 6
- **ML Framework**: [MLX Swift](https://github.com/ml-explore/mlx-swift)
- **Inference**: [Qwen3-ASR](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit)
- **UI**: SwiftUI + AppKit

### Build from source

```bash
swift build -c release
```

---

## 📄 License

MIT License — Use it however you want.
