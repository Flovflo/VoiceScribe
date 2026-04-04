class Voicescribe < Formula
  desc "Invisible AI Stenographer for macOS (MLX-powered + Qwen3-ASR)"
  homepage "https://github.com/Flovflo/VoiceScribe"
  url "https://github.com/Flovflo/VoiceScribe/releases/download/v1.4.2/VoiceScribe-v1.4.2.tar.gz"
  sha256 "4555f5f6930c5a1a26caf1057ab33ecced20ce52fff783d176fc621eb78962ac"
  version "1.4.2"
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
      🎙️ VoiceScribe v1.4.2 is installed!

      To launch:
        open #{opt_prefix}/VoiceScribe.app
        # Or find it in Launchpad!

      PERMISSIONS:
        Grant Accessibility & Microphone access when prompted.

      HOTKEY: Option + Space to start/stop recording.
    EOS
  end
end
