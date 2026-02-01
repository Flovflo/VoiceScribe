import XCTest
@testable import VoiceScribeCore

final class VoiceScribeTests: XCTestCase {
    
    // MARK: - ASRModel Tests
    
    @MainActor
    func testASRModelInitialization() async {
        let service = NativeASREngine()
        let model = ASRModel(service: service)
        let status = await model.status
        XCTAssertEqual(status, "Idle", "ASRModel should start in Idle state")
    }
    
    // MARK: - AppState Tests
    
    @MainActor
    func testAppStateInitialValues() {
        let appState = AppState()
        
        XCTAssertEqual(appState.transcript, "", "Transcript should be empty initially")
        XCTAssertFalse(appState.isRecording, "Should not be recording initially")
        XCTAssertFalse(appState.isReady, "Should not be ready before initialization")
        XCTAssertNil(appState.errorMessage, "Should have no error initially")
    }
    
    @MainActor
    func testAppStateTranscriptManagement() {
        let appState = AppState()
        
        // Set transcript
        appState.transcript = "Test transcription"
        XCTAssertEqual(appState.transcript, "Test transcription")
        
        // Clear transcript
        appState.clearTranscript()
        XCTAssertEqual(appState.transcript, "")
    }
    
    // MARK: - AudioRecorder Tests
    
    @MainActor
    func testAudioRecorderInitialState() {
        let recorder = AudioRecorder()
        
        XCTAssertFalse(recorder.isRecording, "Should not be recording after init")
        XCTAssertEqual(recorder.audioLevel, 0.0, accuracy: 0.001, "Audio level should be 0")
    }
    
    @MainActor
    func testAudioRecorderStopWithoutStart() {
        let recorder = AudioRecorder()
        
        // Stopping without starting should not crash and return empty buffer
        let samples = recorder.stopRecording()
        XCTAssertTrue(samples.isEmpty, "Should return empty buffer if never started")
        XCTAssertFalse(recorder.isRecording)
    }
    
    // MARK: - NativeASREngine Tests
    
    @MainActor
    func testNativeASREngineInitialState() {
        let service = NativeASREngine()
        
        XCTAssertFalse(service.isReady, "Should not be ready before starting")
        XCTAssertFalse(service.isModelCached, "Model should not be cached initially")
        XCTAssertNil(service.lastError, "Should have no error initially")
    }
    
    // MARK: - Feature Extraction Tests
    
    func testAudioFeatureExtraction() {
        let extractor = AudioFeatureExtractor()
        let samples = [Float](repeating: 0.0, count: 16000)
        let expectedFrames = extractor.frameCount(sampleCount: samples.count)
        
        let features = extractor.logMelSpectrogram(samples: samples)
        
        XCTAssertEqual(features.shape, [1, expectedFrames, extractor.configuration.melBinCount])
    }
    
    // MARK: - Integration Tests
    
    @MainActor
    func testFullRecordingCycle() async {
        let appState = AppState()
        
        // Verify initial state
        XCTAssertFalse(appState.isRecording)
        
        // Simulate transcript update
        appState.transcript = "Integration test passed"
        XCTAssertEqual(appState.transcript, "Integration test passed")
        
        // Test copy functionality exists
        appState.copyToClipboard()
        
        // Test clear functionality
        appState.clearTranscript()
        XCTAssertEqual(appState.transcript, "")
    }
    
    @MainActor
    func testAppStateShutdown() {
        let appState = AppState()
        
        // Shutdown should not crash
        appState.shutdown()
        
        // State should remain consistent
        XCTAssertFalse(appState.isRecording)
    }
}
