class Voicescribe < Formula
  desc "Invisible AI Stenographer for macOS (MLX-powered + Qwen3-ASR)"
  homepage "https://github.com/Flovflo/VoiceScribe"
  url "https://github.com/Flovflo/VoiceScribe/releases/download/v1.5.0/VoiceScribe-1.5.0-arm64.zip"
  sha256 "d2e70a8e8a94de1391110e0662f42a42f8d38c9ed6180bf2cfcc4e610b403486"
  version "1.5.0"
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
      🎙️ VoiceScribe v1.5.0 is installed!

      To launch:
        open #{opt_prefix}/VoiceScribe.app
        # Or find it in Launchpad!

      PERMISSIONS:
        Grant Accessibility & Microphone access when prompted.

      HOTKEY: Option + Space to start/stop recording.
    EOS
  end
end
