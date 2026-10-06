class Voicescribe < Formula
  desc "Invisible AI Stenographer for macOS (MLX-powered + Qwen3-ASR)"
  homepage "https://github.com/Flovflo/VoiceScribe"
  url "https://github.com/Flovflo/VoiceScribe/releases/download/v1.5.0/VoiceScribe-1.5.0-arm64.zip"
  sha256 "b79aa3ada73fcb5fc289b2ac0735b92b3afd6fcca86a87a77b7386f95b448f30"
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
