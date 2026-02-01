#!/usr/bin/env python3
"""
VoiceScribe ASR Daemon - MLX-Whisper Backend

Uses MLX-Whisper for fast, native Apple Silicon inference.
Communicates with Swift app via stdin/stdout JSON messages.
"""

import sys
import json
import os
from pathlib import Path

def send_message(msg_type: str, **kwargs):
    """Send JSON message to Swift."""
    msg = {"type": msg_type, **kwargs}
    print(json.dumps(msg), flush=True)

def main():
    send_message("status", state="initializing", details="Loading MLX-Whisper...")
    
    try:
        import mlx_whisper
    except ImportError as e:
        send_message("fatal", message=f"mlx-whisper not installed: {e}")
        sys.exit(1)
    
    # Use whisper-large-v3-turbo for best speed/accuracy balance
    MODEL_ID = "mlx-community/whisper-large-v3-turbo"
    
    send_message("status", state="loading", details=f"Loading {MODEL_ID}...")
    
    # Warm up the model with a silent transcription
    # This downloads and caches the model if needed
    try:
        # Create a tiny silent audio file for warmup
        import numpy as np
        warmup_path = "/tmp/voicescribe_warmup.wav"
        
        # 0.1 second of silence at 16kHz
        silence = np.zeros(1600, dtype=np.float32)
        
        # Write minimal WAV
        import wave
        with wave.open(warmup_path, 'wb') as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(16000)
            wf.writeframes((silence * 32767).astype(np.int16).tobytes())
        
        # Warmup transcription (downloads model on first run)
        _ = mlx_whisper.transcribe(warmup_path, path_or_hf_repo=MODEL_ID)
        os.remove(warmup_path)
        
        send_message("ready", model=MODEL_ID)
    except Exception as e:
        send_message("fatal", message=f"Failed to load model: {e}")
        sys.exit(1)
    
    # Main loop - read audio file paths from stdin
    for line in sys.stdin:
        line = line.strip()
        
        if not line:
            continue
        
        if line.upper() == "QUIT":
            send_message("status", state="shutdown", details="Goodbye")
            break
        
        # Treat as audio file path
        audio_path = line
        
        if not os.path.exists(audio_path):
            send_message("error", message=f"File not found: {audio_path}")
            continue
        
        send_message("status", state="transcribing", details="Processing audio...")
        
        try:
            # MLX-Whisper transcription
            result = mlx_whisper.transcribe(
                audio_path,
                path_or_hf_repo=MODEL_ID,
                language="en",  # Auto-detect if None
                verbose=False
            )
            
            text = result.get("text", "").strip()
            language = result.get("language", "")
            
            send_message("transcription", text=text, language=language)
            
        except Exception as e:
            send_message("error", message=f"Transcription failed: {e}")

if __name__ == "__main__":
    main()
