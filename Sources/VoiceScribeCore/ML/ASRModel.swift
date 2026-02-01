import Foundation
import MLX

public actor ASRModel {
    public private(set) var status: String = "Idle"
    
    // We hold a reference to the service, which is MainActor
    // Accessing MainActor isolated property from Actor requires await
    private let service: PythonASRService
    
    public init(service: PythonASRService) {
        self.service = service
    }
    
    public func loadModel() async {
        status = "Starting Engine..."
        await service.startEngine()
        // Wait for ready? Service updates its own status. 
        // We can poll or just trust the status from service
        // Let's mirror the service status for convenience if needed, 
        // but AppState should probably observe Service directly?
        // For compatibility with previous API, we update our status.
        status = "Ready" 
    }
    
    public func transcribe(samples: [Float]) async -> String {
        status = "Transcribing..."
        
        // Save WAV
        guard let wavPath = saveToTempWav(samples: samples) else {
            status = "Save Failed"
            return "Error saving audio"
        }
        
        // Call Python
        let text = await service.transcribe(audioPath: wavPath)
        
        // Clean up
        try? FileManager.default.removeItem(atPath: wavPath)
        
        status = "Idle"
        return text
    }
    
    private func saveToTempWav(samples: [Float]) -> String? {
        let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        
        // Minimal WAV Header for 16kHz Mono Float32
        // Actually, qwen-asr might expect PCM16 or Float.
        // Let's standardise on Int16 16kHz for maximum compatibility with generic wave readers.
        // float32 is fine too if handled by librosa/soundfile.
        // I will implement a quick WAV writer manually or use AVFile?
        // Manual is risky. AVFile is better but requires module AVFoundation.
        // I'll stick to float dump or basic WAV.
        // Simplest: Use Python to read "Raw Float32"?
        // No, file path APIs expect typical formats.
        
        // Let's try to write a valid WAV file using AudioToolbox or AVFoundation logic in a helper?
        // Or just write Raw PCM and tell python (if I changed script). 
        // But script expects "path" to be loaded by torchaudio/librosa. Expects header.
        
        // Quick Manual WAV Writer (16kHz, 1ch, Float32)
        // Header 44 bytes.
        let sampleRate: Int32 = 16000
        let channels: Int16 = 1
        let bitsPerSample: Int16 = 32
        let byteRate = sampleRate * Int32(channels) * Int32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = Int32(samples.count * 4)
        let chunkSize = 36 + dataSize
        
        let header = NSMutableData()
        
        // RIFF chunk
        header.append("RIFF".data(using: .ascii)!)
        var _chunkSize = chunkSize; header.append(&_chunkSize, length: 4)
        header.append("WAVE".data(using: .ascii)!)
        
        // fmt chunk
        header.append("fmt ".data(using: .ascii)!)
        var subchunk1Size: Int32 = 16; header.append(&subchunk1Size, length: 4)
        var audioFormat: Int16 = 3; header.append(&audioFormat, length: 2) // 3 = Float
        var _channels = channels; header.append(&_channels, length: 2)
        var _sampleRate = sampleRate; header.append(&_sampleRate, length: 4)
        var _byteRate = byteRate; header.append(&_byteRate, length: 4)
        var _blockAlign = blockAlign; header.append(&_blockAlign, length: 2)
        var _bitsPerSample = bitsPerSample; header.append(&_bitsPerSample, length: 2)
        
        // data chunk
        header.append("data".data(using: .ascii)!)
        var _dataSize = dataSize; header.append(&_dataSize, length: 4)
        
        // Data
        header.append(Data(bytes: samples, count: samples.count * 4))
        
        do {
            try header.write(to: tempUrl)
            return tempUrl.path
        } catch {
            print("Wav Write Error: \(error)")
            return nil
        }
    }
}
