# VoiceScribe 🔮

**The Invisible AI Stenographer for macOS.**





VoiceScribe is a native, ultra-fast, on-device speech-to-text tool designed for macOS users who want privacy and speed. Powered by Apple's **MLX** framework and the **Qwen3-ASR** model, it runs locally on your Apple Silicon chip—no data ever leaves your device.

![macOS](https://img.shields.io/badge/macOS-14.0+-000000?style=flat&logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-M1%2FM2%2FM3-green)
![Privacy](https://img.shields.io/badge/Privacy-100%25_Local-blue)
![License](https://img.shields.io/badge/License-MIT-purple)

## Features

- **🔮 Liquid Glass HUD**: A transparent, floating HUD centered at the top of your screen that stays out of your way.
- **🛰️ Menu Bar Control**: Invisible by default, accessible via a permanent menu bar icon.
- **⚙️ Model Selection**: Choose between **Qwen3-ASR-0.6B** (Fast) and **1.7B** (Accurate) variants.
- **⚡️ Native MLX Engine**: Optimized for M-series chips using Apple's latest machine learning framework.
- **⌨️ Auto-Paste**: Transcribed text acts like magic—it's automatically typed into your active app (Notes, VS Code, Browser...).
- **🎹 Global Hotkey**: Press `Option + Space` anywhere to start/stop recording.
- **🔒 100% Private**: Runs offline. Zero cloud dependency.

## Installation

### Option 1: Homebrew (Recommended)

```bash
brew tap Flovflo/voicescribe https://github.com/Flovflo/VoiceScribe
brew install --HEAD voicescribe
```

### Option 2: Build from Source

Requirements: macOS 14+, Python 3.11+, and an Apple Silicon Mac.

1.  **Clone the repo**
    ```bash
    git clone https://github.com/Flovflo/VoiceScribe.git
    cd VoiceScribe
    ```

2.  **Setup Python Environment** (for the MLX engine)
    ```bash
    python3 -m venv venv
    source venv/bin/activate
    pip install git+https://github.com/Blaizzy/mlx-audio.git
    ```

3.  **Build & Run**
    ```bash
    swift build -c release
    ./package_app.sh
    open VoiceScribe.app
    ```

## Usage

1.  **Launch VoiceScribe**.
2.  Grant **Accessibility Permissions** when asked (needed for Global Hotkeys and Auto-Paste).
3.  Place your cursor in any text field.
4.  Press **`Option + Space`**.
5.  Speak when you see the HUD wave.
6.  Press **`Option + Space`** again to finish.
7.  ✨ The text appears magically!
8.  **Settings**: Click the slider icon 🎛️ in the HUD or use the Menu Bar icon to change models.

## Architecture

VoiceScribe combines a native Swift/SwiftUI interface with a highly optimized Python backend:

- **Frontend**: SwiftUI + AppKit (Floating Window, Status Bar Item, Global Hotkeys).
- **Backend**: Python + `mlx-audio` (Apple MLX Framework + Qwen3).
- **Communication**: Unix Pipes (stdin/stdout) for zero-latency control.

## Credits

- **Model**: Qwen3-ASR (0.6B / 1.7B) via `mlx-audio`
- **Engine**: [Apple MLX](https://github.com/ml-explore/mlx)
- **Design**: Inspired by macOS "Liquid Glass" aesthetics.


## License

MIT License. Copyright (c) 2026 Florian.
