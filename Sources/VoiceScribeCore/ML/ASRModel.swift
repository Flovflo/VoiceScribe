import Foundation

public actor ASRModel {
    public private(set) var status: String = "Idle"
    
    private let service: NativeASREngine
    
    public init(service: NativeASREngine) {
        self.service = service
    }
    
    public func loadModel() async {
        status = "Starting Engine..."
        await service.startEngine()
        status = "Ready" 
    }
    
    public func transcribe(samples: [Float]) async -> String {
        status = "Transcribing..."

        let text = await service.transcribe(samples: samples)

        status = "Idle"
        return text
    }
}
