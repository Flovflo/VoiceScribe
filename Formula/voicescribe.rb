class Voicescribe < Formula
  desc "Invisible AI Stenographer for macOS (MLX-powered)"
  homepage "https://github.com/Flovflo/VoiceScribe"
  url "https://github.com/Flovflo/VoiceScribe/releases/download/v1.0.0/VoiceScribe-v1.0.0.tar.gz"
  sha256 "572c191d5f0aeb0dde876ee56341ccdab97dc2ae546ca84ccde38df40817cf72"
  license "MIT"

  head "https://github.com/Flovflo/VoiceScribe.git", branch: "main"

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
      VoiceScribe is installed! 
      
      To run it:
        open #{opt_prefix}/VoiceScribe.app
      
      Dependencies:
        pip3 install mlx-whisper (ensure python3 is in your PATH)
        
      Note: Grant Accessibility Access when prompted.
    EOS
  end
end
