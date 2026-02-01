#!/usr/bin/env python3
"""VoiceScribe ASR - MLX-Whisper optimized for speed"""

import sys
import json
import os

def msg(t, **kw):
    print(json.dumps({"type": t, **kw}), flush=True)

def main():
    msg("status", state="loading", details="Loading MLX-Whisper...")
    
    import mlx_whisper
    
    # Use turbo model for max speed
    MODEL = "mlx-community/whisper-large-v3-turbo"
    
    # Warmup
    import tempfile, wave, numpy as np
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        wp = f.name
    with wave.open(wp, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(np.zeros(1600, dtype=np.int16).tobytes())
    mlx_whisper.transcribe(wp, path_or_hf_repo=MODEL)
    os.remove(wp)
    
    msg("ready", model=MODEL)
    
    for line in sys.stdin:
        line = line.strip()
        if not line: continue
        if line.upper() == "QUIT": break
        
        if not os.path.exists(line):
            msg("error", message=f"File not found: {line}")
            continue
        
        msg("status", state="transcribing", details="...")
        
        try:
            # No language forcing - auto detect
            result = mlx_whisper.transcribe(line, path_or_hf_repo=MODEL)
            msg("transcription", text=result.get("text", "").strip(), language=result.get("language", ""))
        except Exception as e:
            msg("error", message=str(e))

if __name__ == "__main__":
    main()
