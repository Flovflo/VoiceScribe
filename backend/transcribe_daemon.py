
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
except ImportError:
    send_message("fatal", message="Missing dependencies. Please run: pip install git+https://github.com/Blaizzy/mlx-audio.git")
    sys.exit(1)

# Default model
DEFAULT_MODEL = "mlx-community/Qwen3-ASR-1.7B-8bit"
current_model = None
model_instance = None

def load_model(model_name=DEFAULT_MODEL):
    global current_model, model_instance
    
    if current_model == model_name and model_instance is not None:
        return
    

    try:
        short_name = model_name.split('/')[-1]
        send_message("status", state="downloading", details=f"Downloading {short_name}...")
        # Load logic
        model_instance = load(model_name)
        current_model = model_name
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
        
        # Generate transcription
        # Qwen3-ASR supports language auto-detection if None? 
        # The README says: result = model.generate("audio.wav", language="English")
        # If language is None, maybe it defaults or detects?
        # Let's try passing language if set, else let it default (or use English/auto)
        
        # Note: Qwen3 might require language. Defaulting to auto if supported, or English/Multi.
        # Based on docs, supported languages are limited. I'll default to "auto" if None.
        
        kwargs = {}
        if language:
            kwargs["language"] = language
        
        result = model_instance.generate(audio_path, **kwargs)
        
        duration = time.time() - start_time
        
        # result.text contains the text
        text = result.text.strip()
        
        send_message("transcription", text=text, language=language or "auto", duration=duration)
        
    except Exception as e:
        send_message("error", message=f"Transcription failed: {str(e)}")

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
            
        # Otherwise interpret as audio path
        audio_path = line
        transcribe(audio_path)

if __name__ == "__main__":
    main()
