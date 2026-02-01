class Voicescribe < Formula
  desc "Invisible AI Stenographer for macOS (MLX-powered + Qwen3-ASR)"
  homepage "https://github.com/Flovflo/VoiceScribe"
  url "https://github.com/Flovflo/VoiceScribe/releases/download/v1.2.0/VoiceScribe-v1.2.0.tar.gz"
  sha256 "8f58ab5b6a61696d86b88d7ee77f72518c0e81efff4529ca5593b0e9b1231219"
  version "1.2.0"
  license "MIT"

  depends_on :macos
  depends_on arch: :arm64

  def install
    prefix.install "VoiceScribe.app"
    bin.write_exec_script "#{prefix}/VoiceScribe.app/Contents/MacOS/VoiceScribe"
  end

  def post_install
    # Link app to /Applications for easy access
    system "ln", "-sf", "#{prefix}/VoiceScribe.app", "/Applications/VoiceScribe.app"
  end

  def caveats
    <<~EOS
      🎙️ VoiceScribe v1.2.0 is installed!

      To launch:
        open #{opt_prefix}/VoiceScribe.app
        # Or find it in Launchpad!

      REQUIRED - Install Python dependencies:
        pip3 install git+https://github.com/Blaizzy/mlx-audio.git

      PERMISSIONS:
        Grant Accessibility & Microphone access when prompted.

      HOTKEY: Option + Space to start/stop recording.
    EOS
  end
end
