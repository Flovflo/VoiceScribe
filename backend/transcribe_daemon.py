#!/usr/bin/env python3
"""
VoiceScribe ASR Daemon
Handles model downloading, caching, and transcription via Qwen3-ASR
"""
import sys
import json
import os
from pathlib import Path

def send_message(msg_type: str, **kwargs):
    """Send a JSON message to stdout for Swift to parse"""
    message = {"type": msg_type, **kwargs}
    print(json.dumps(message), flush=True)

def get_cache_dir() -> Path:
    """Get the model cache directory"""
    # Check environment variable first (for custom paths)
    if custom_path := os.environ.get("VOICESCRIBE_MODEL_DIR"):
        return Path(custom_path)
    
    # Default: ~/Library/Application Support/VoiceScribe/models
    home = Path.home()
    cache_dir = home / "Library" / "Application Support" / "VoiceScribe" / "models"
    cache_dir.mkdir(parents=True, exist_ok=True)
    return cache_dir

def check_model_exists(cache_dir: Path, model_name: str) -> bool:
    """Check if model is already downloaded"""
    model_path = cache_dir / model_name.replace("/", "--")
    # Check for key files that indicate a complete download
    required_files = ["config.json", "model.safetensors"]
    if model_path.exists():
        existing_files = list(model_path.glob("*"))
        if any("safetensors" in f.name for f in existing_files):
            return True
    return False

def download_model(model_name: str, cache_dir: Path):
    """Download the model with progress reporting"""
    from huggingface_hub import snapshot_download
    from tqdm import tqdm
    
    send_message("download_start", model=model_name)
    
    local_dir = cache_dir / model_name.replace("/", "--")
    
    try:
        # Use snapshot_download for better control
        snapshot_download(
            repo_id=model_name,
            local_dir=str(local_dir),
            local_dir_use_symlinks=False,
        )
        send_message("download_complete", path=str(local_dir))
        return local_dir
    except Exception as e:
        send_message("download_error", error=str(e))
        return None

def main():
    import torch
    
    MODEL_NAME = "Qwen/Qwen3-ASR-1.7B"
    cache_dir = get_cache_dir()
    
    send_message("status", state="initializing", details="Checking model cache...")
    
    # Check if model exists
    model_exists = check_model_exists(cache_dir, MODEL_NAME)
    local_model_path = cache_dir / MODEL_NAME.replace("/", "--")
    
    if not model_exists:
        send_message("status", state="downloading", details="Model not found. Starting download...")
        result = download_model(MODEL_NAME, cache_dir)
        if result is None:
            send_message("fatal", message="Failed to download model")
            return
    else:
        send_message("status", state="cached", details="Model found in cache")
    
    # Load the model
    send_message("status", state="loading", details="Loading Qwen3-ASR into memory...")
    
    try:
        from qwen_asr import Qwen3ASRModel
        
        # Determine device
        if torch.backends.mps.is_available():
            device = "mps"
        elif torch.cuda.is_available():
            device = "cuda"
        else:
            device = "cpu"
        
        send_message("status", state="loading", details=f"Using device: {device}")
        
        # Load from local path if available, otherwise from HF
        model_source = str(local_model_path) if local_model_path.exists() else MODEL_NAME
        
        model = Qwen3ASRModel.from_pretrained(
            model_source,
            device_map=device if device != "mps" else "cpu",  # MPS not always supported
            dtype=torch.float32
        )
        
        send_message("ready")
        
    except Exception as e:
        send_message("fatal", message=f"Failed to load model: {e}")
        return
    
    # Main loop - wait for audio file paths on stdin
    while True:
        try:
            line = sys.stdin.readline()
            if not line:
                break
            
            audio_path = line.strip()
            if not audio_path:
                continue
            
            if audio_path == "QUIT":
                break
            
            send_message("status", state="transcribing", details="Processing audio...")
            
            try:
                results = model.transcribe(audio=audio_path)
                
                if results and len(results) > 0:
                    result = results[0]
                    send_message("transcription", 
                                text=result.text, 
                                language=getattr(result, 'language', 'unknown'))
                else:
                    send_message("transcription", text="", language="none")
                    
            except Exception as e:
                send_message("error", message=f"Transcription failed: {e}")
                
        except KeyboardInterrupt:
            break
        except Exception as e:
            send_message("error", message=f"Unexpected error: {e}")
    
    send_message("status", state="shutdown", details="Daemon stopping")

if __name__ == "__main__":
    main()
