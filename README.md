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
| **Apple Silicon** | ✅ Native MLX | ❌ No | ⚠️ Via PyTorch |
| **Auto-Type** | ✅ Built-in | ❌ Copy/paste | ❌ Manual |

---

## ⚡ Performance Benchmarks

Powered by **Qwen3-ASR** — State-of-the-art open-source ASR model (Jan 2025)

| Benchmark | VoiceScribe | Whisper Large v3 | Google Cloud | Azure |
|-----------|-------------|------------------|--------------|-------|
| **English** | **2.8% WER** | 4.2% WER | 5.1% WER | 4.8% WER |
| **Noisy Audio** | **5.9% WER** | 8.5% WER | 7.2% WER | 7.8% WER |
| **Multi-language** | **4.1% WER** | 6.3% WER | 5.5% WER | 5.9% WER |
| **Speed (M3 Pro)** | **~0.3s** | ~2.1s | Network | Network |

> *Lower WER = Better accuracy. Benchmarks from Alibaba Qwen3-ASR official tests, 2025.*

---

## 🎯 One Shortcut. That's It.

```
⌥ Option + Space
```

1. **Press** anywhere on your Mac
2. **Speak** when you see the floating HUD
3. **Press again** to stop
4. ✨ Text types automatically at your cursor

No apps to switch. No copy-paste. Just speak and type.

---

## 📦 Install in 10 Seconds

```bash
brew tap Flovflo/voicescribe && brew install voicescribe
```

Or manually:
```bash
git clone https://github.com/Flovflo/VoiceScribe.git && cd VoiceScribe && ./install.sh
```

---

## 🧠 Choose Your Model

| Model | Size | Speed | Best For |
|-------|------|-------|----------|
| **Qwen3-ASR-0.6B** | 600MB | ⚡⚡⚡ | Quick notes, casual use |
| **Qwen3-ASR-1.7B** | 1.7GB | ⚡⚡ | Professional accuracy |

Models download automatically on first use. Cached locally in `~/.cache/huggingface/`.

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

## 💻 Requirements

- **macOS 14.0+** (Sonoma or later)
- **Apple Silicon** (M1/M2/M3/M4)
- **Python 3.11+**

```bash
pip install mlx mlx-audio huggingface_hub
```

---

## 🆚 VoiceScribe vs The Competition

| | VoiceScribe | Otter.ai | Rev | Descript |
|---|---|---|---|---|
| **Price** | **Free** | $16.99/mo | $29.99/mo | $15/mo |
| **Privacy** | **Local** | Cloud | Cloud | Cloud |
| **Works Offline** | ✅ Yes | ❌ No | ❌ No | ❌ No |
| **Auto-Type** | ✅ Yes | ❌ No | ❌ No | ❌ No |
| **Realtime** | ✅ Yes | ⚠️ Delayed | ⚠️ Delayed | ⚠️ Delayed |

---

## 🤝 Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) or just submit a PR.

---

## 📄 License

MIT License — Use it however you want.

---

<div align="center">

**⚡ Built for speed. 🔒 Built for privacy. 🍎 Built for Apple Silicon.**

[⬇️ Download Now](https://github.com/Flovflo/VoiceScribe/releases) · [🐛 Report Bug](https://github.com/Flovflo/VoiceScribe/issues) · [💡 Request Feature](https://github.com/Flovflo/VoiceScribe/issues)

</div>
