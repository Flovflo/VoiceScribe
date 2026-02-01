
import sys
import json
import os
import time
import logging

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

def send_message(msg_type, **kwargs):
    message = {"type": msg_type}
    message.update(kwargs)
    print(json.dumps(message), flush=True)

try:
    import mlx.core as mx
    from mlx_audio.stt import load
    from huggingface_hub import snapshot_download, HfFileSystem
except ImportError:
    send_message("fatal", message="Missing dependencies. Please run: pip install git+https://github.com/Blaizzy/mlx-audio.git huggingface_hub")
    sys.exit(1)

# Default model
DEFAULT_MODEL = "mlx-community/Qwen3-ASR-1.7B-8bit"
current_model = None
model_instance = None

def is_model_cached(model_name):
    """Check if model is already downloaded in HuggingFace cache."""
    try:
        cache_dir = os.path.expanduser("~/.cache/huggingface/hub")
        # Convert model name to cache folder format
        # e.g., "mlx-community/Qwen3-ASR-1.7B-8bit" -> "models--mlx-community--Qwen3-ASR-1.7B-8bit"
        cache_folder = f"models--{model_name.replace('/', '--')}"
        model_cache_path = os.path.join(cache_dir, cache_folder)
        
        if os.path.exists(model_cache_path):
            # Check if there are snapshot folders (indicates complete download)
            snapshots_path = os.path.join(model_cache_path, "snapshots")
            if os.path.exists(snapshots_path) and os.listdir(snapshots_path):
                return True
        return False
    except Exception:
        return False

def load_model(model_name=DEFAULT_MODEL):
    global current_model, model_instance
    
    if current_model == model_name and model_instance is not None:
        return
    
    try:
        short_name = model_name.split('/')[-1]
        
        # Check if model is already cached
        if is_model_cached(model_name):
            send_message("status", state="loading", details=f"Loading {short_name} (cached)")
        else:
            send_message("status", state="downloading", details=f"Downloading {short_name}...")
            send_message("download_progress", progress=0, model=short_name)
        
        # Load model (this will download if needed)
        model_instance = load(model_name)
        current_model = model_name
        
        send_message("download_progress", progress=100, model=short_name)
        send_message("ready", model=model_name, message=f"Ready ({short_name})")
        
    except Exception as e:
        send_message("error", message=f"Failed to load model {model_name}: {str(e)}")
        current_model = None
        model_instance = None

def transcribe(audio_path, language=None):
    global model_instance
    if model_instance is None:
        load_model()
    
    if model_instance is None:
        return # Failed to load
        
    if not os.path.exists(audio_path):
        send_message("error", message=f"File not found: {audio_path}")
        return

    try:
        send_message("status", state="transcribing")
        start_time = time.time()
        
        kwargs = {}
        if language:
            kwargs["language"] = language
        
        result = model_instance.generate(audio_path, **kwargs)
        
        duration = time.time() - start_time
        text = result.text.strip()
        
        send_message("transcription", text=text, language=language or "auto", duration=duration)
        
    except Exception as e:
        send_message("error", message=f"Transcription failed: {str(e)}")

def check_model_status(model_name):
    """Check and report if a model is cached without loading it."""
    short_name = model_name.split('/')[-1]
    cached = is_model_cached(model_name)
    send_message("model_status", model=model_name, cached=cached, short_name=short_name)

def main():
    send_message("status", state="initializing", details="Starting Qwen3-ASR Engine")
    
    # Pre-load default model
    load_model(DEFAULT_MODEL)
    
    # Main loop
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
            
        if line == "QUIT":
            break
            
        # Check for commands
        if line.startswith("LOAD_MODEL:"):
            new_model = line.split(":", 1)[1].strip()
            load_model(new_model)
            continue
        
        if line.startswith("CHECK_MODEL:"):
            model_to_check = line.split(":", 1)[1].strip()
            check_model_status(model_to_check)
            continue
            
        # Otherwise interpret as audio path
        audio_path = line
        transcribe(audio_path)

if __name__ == "__main__":
    main()
