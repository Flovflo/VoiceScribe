class Voicescribe < Formula
  desc "Invisible AI Stenographer for macOS (MLX-powered + Qwen3-ASR)"
  homepage "https://github.com/Flovflo/VoiceScribe"
  url "https://github.com/Flovflo/VoiceScribe/releases/download/v1.1.0/VoiceScribe-v1.1.0.tar.gz"
  sha256 "5c048237a0c18cc6e6f9ba7374942491d48fa2230659132a9374ec610b4c9753"
  license "MIT"

  head "https://github.com/Flovflo/VoiceScribe.git", branch: "refactor/native-mlx"

  depends_on "python@3.11"

  def install
     if build.head?
        system "swift", "build", "-c", "release", "--arch", "arm64"
        system "./package_app.sh"
        prefix.install "VoiceScribe.app"
     else
        prefix.install "VoiceScribe.app"
     end
     
     bin.write_exec_script "#{prefix}/VoiceScribe.app/Contents/MacOS/VoiceScribe"
  end

  def caveats
    <<~EOS
      VoiceScribe v1.1 is installed! 
      
      To run it:
        open #{opt_prefix}/VoiceScribe.app
      
      REQUIRED Dependencies (run this):
        pip3 install git+https://github.com/Blaizzy/mlx-audio.git
        
      (Ensure python3 is in your path and has mlx-audio installed)
      
      Note: Grant Accessibility Access when prompted.
    EOS
  end
end
