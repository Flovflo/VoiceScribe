class Voicescribe < Formula
  desc "Invisible AI Stenographer for macOS (MLX-powered)"
  homepage "https://github.com/Flovflo/VoiceScribe"
  head "https://github.com/Flovflo/VoiceScribe.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on "python@3.11"

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/VoiceScribe"
    
    # Install backend and resources
    (prefix/"backend").install "backend/transcribe_daemon.py"
    
    # Create wrapper script that sets up venv if needed
    (bin/"voicescribe-wrapper").write <<~EOS
      #!/bin/bash
      export PATH="#{HOMEBREW_PREFIX}/bin:$PATH"
      # Ensure python venv exists or use system? 
      # For Homebrew, we might rely on the user to have dependencies or vendor them.
      # Simplified for HEAD formula: assume user handles python deps or we install them.
      exec "#{bin}/VoiceScribe" "$@"
    EOS
  end

  def caveats
    <<~EOS
      VoiceScribe requires Python dependencies to run the MLX engine.
      Please run:
        pip3 install mlx-whisper
      
      Also grant Accessibility permissions to Terminal or the App to use Global Hotkeys.
    EOS
  end
end
