class Voicescribe < Formula
  desc "Invisible AI Stenographer for macOS (MLX-powered + Qwen3-ASR)"
  homepage "https://github.com/Flovflo/VoiceScribe"
  url "https://github.com/Flovflo/VoiceScribe/releases/download/v1.4.5/VoiceScribe-1.4.5.zip"
  sha256 "9620482d07bde790edb76ede780f5f833be2cd6821f86b1acbeeccbae81b03c2"
  version "1.4.5"
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
      🎙️ VoiceScribe v1.4.5 is installed!

      To launch:
        open #{opt_prefix}/VoiceScribe.app
        # Or find it in Launchpad!

      PERMISSIONS:
        Grant Accessibility & Microphone access when prompted.

      HOTKEY: Option + Space to start/stop recording.
    EOS
  end
end
