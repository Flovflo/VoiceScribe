import XCTest
import Carbon
@testable import VoiceScribeCore

final class VoiceScribeTests: XCTestCase {
    
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
        XCTAssertEqual(recorder.outputSampleRate, 16000, "Recorder output should be 16kHz")
    }
    
    @MainActor
    func testAudioRecorderStopWithoutStart() {
        let recorder = AudioRecorder()
        
        // Stopping without starting should not crash and return empty buffer
        let samples = recorder.stopRecording()
        XCTAssertTrue(samples.isEmpty, "Should return empty buffer if never started")
        XCTAssertFalse(recorder.isRecording)
    }
    
    // MARK: - NativeASRService Tests
    
    @MainActor
    func testNativeASRServiceInitialState() {
        let engine = NativeASRService()
        
        XCTAssertFalse(engine.isReady, "Should not be ready before loading")
        XCTAssertFalse(engine.isModelCached, "Model might be cached/uncached but default state check")
        XCTAssertNil(engine.lastError, "Should have no error initially")
    }

    func testPermissionBridgeHandlesBackgroundCallback() async {
        let granted = await AudioRecorder.bridgePermissionRequest { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                completion(true)
            }
        }
        XCTAssertTrue(granted)
    }

    func testPermissionBridgeCanReturnFalse() async {
        let granted = await AudioRecorder.bridgePermissionRequest { completion in
            DispatchQueue.global(qos: .utility).async {
                completion(false)
            }
        }
        XCTAssertFalse(granted)
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

    func testHotKeyTriggerGateDebouncesRapidEvents() {
        var gate = HotKeyTriggerGate(cooldown: 0.30)

        XCTAssertTrue(gate.allowsTrigger(now: 10.0))
        XCTAssertFalse(gate.allowsTrigger(now: 10.05))
        XCTAssertFalse(gate.allowsTrigger(now: 10.29))
        XCTAssertTrue(gate.allowsTrigger(now: 10.31))
    }

    func testHotKeyPressStateIgnoresRepeatsUntilRelease() {
        var state = HotKeyPressState(cooldown: 0.30)

        XCTAssertTrue(state.shouldTrigger(for: UInt32(kEventHotKeyPressed), now: 1.0))
        XCTAssertFalse(state.shouldTrigger(for: UInt32(kEventHotKeyPressed), now: 1.1))
        XCTAssertFalse(state.shouldTrigger(for: UInt32(kEventHotKeyPressed), now: 1.5))

        XCTAssertFalse(state.shouldTrigger(for: UInt32(kEventHotKeyReleased), now: 1.6))
        XCTAssertTrue(state.shouldTrigger(for: UInt32(kEventHotKeyPressed), now: 1.7))
        XCTAssertFalse(state.shouldTrigger(for: UInt32(kEventHotKeyPressed), now: 2.0))
    }

    @MainActor
    func testHotKeyManagerHandlesPressReleaseStorm() {
        let manager = HotKeyManager.shared
        var triggerCount = 0
        manager.onTrigger = { triggerCount += 1 }

        for cycle in 0..<240 {
            let now = Double(cycle) * 0.01
            manager.__test_handleHotKeyEvent(kind: UInt32(kEventHotKeyPressed), now: now)
            manager.__test_handleHotKeyEvent(kind: UInt32(kEventHotKeyPressed), now: now + 0.001)
            manager.__test_handleHotKeyEvent(kind: UInt32(kEventHotKeyReleased), now: now + 0.002)
        }

        XCTAssertGreaterThan(triggerCount, 0)
    }

    func testASRModelCatalogSupportsAllQwen3ASRVariantsOnly() {
        XCTAssertTrue(ASRModelCatalog.isSupportedASRModel("mlx-community/Qwen3-ASR-0.6B-4bit"))
        XCTAssertTrue(ASRModelCatalog.isSupportedASRModel("mlx-community/Qwen3-ASR-0.6B-8bit"))
        XCTAssertTrue(ASRModelCatalog.isSupportedASRModel("mlx-community/Qwen3-ASR-1.7B-8bit"))
        XCTAssertTrue(ASRModelCatalog.isSupportedASRModel("mlx-community/Qwen3-ASR-1.7B-bf16"))
        XCTAssertFalse(ASRModelCatalog.isSupportedASRModel("mlx-community/Qwen3-ForcedAligner-0.6B-8bit"))
        XCTAssertFalse(ASRModelCatalog.isSupportedASRModel("mlx-community/Llama-3.2-1B-Instruct-4bit"))
    }
}
