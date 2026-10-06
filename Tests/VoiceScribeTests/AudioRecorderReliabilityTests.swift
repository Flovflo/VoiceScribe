import XCTest
@preconcurrency import AVFoundation
import CoreAudio
@testable import VoiceScribeCore

@MainActor
final class AudioRecorderReliabilityTests: XCTestCase {
    func testCaptureDownmixIncludesSpeechOnSecondChannel() throws {
        let engine = AudioCaptureEngine()
        let buffer = try makeBuffer(channels: [[0, 0, 0, 0], [1, -1, 0.5, -0.5]])
        engine.handleBuffer(buffer)

        XCTAssertEqual(engine.lastRMS, sqrt(0.15625), accuracy: 0.00001)
        XCTAssertEqual(engine.stop(), [0.5, -0.5, 0.25, -0.25])
    }

    func testCapturePreservesMonoSamples() throws {
        let engine = AudioCaptureEngine()
        engine.handleBuffer(try makeBuffer(channels: [[0.25, -0.5, 1, 0]]))
        XCTAssertEqual(engine.stop(), [0.25, -0.5, 1, 0])
        XCTAssertEqual(engine.lastRMS, 0, "Stopping must clear the meter from the previous recording")
    }

    func testCaptureDownmixHonorsInterleavedChannelStride() throws {
        let engine = AudioCaptureEngine()
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: 2, interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        let data = try XCTUnwrap(buffer.floatChannelData)
        data[0].update(from: [0, 1, 0, -1, 0.5, 0.5], count: 6)
        engine.handleBuffer(buffer)
        XCTAssertEqual(engine.stop(), [0.5, -0.5, 0.5])
    }

    func testCancelledFirstBufferWaitReturnsPromptly() async {
        let engine = AudioCaptureEngine()
        let task = Task {
            let started = ContinuousClock.now
            let received = await engine.waitForFirstBuffer(timeout: .milliseconds(350))
            return (received, ContinuousClock.now - started)
        }
        task.cancel()
        let (received, elapsed) = await task.value
        XCTAssertFalse(received)
        XCTAssertLessThan(elapsed, .milliseconds(100))
    }

    func testPermissionCancellationDoesNotWaitForSystemResponse() async {
        let started = ContinuousClock.now
        let (requests, requestStarted) = AsyncStream<Void>.makeStream()
        let task = Task {
            await AudioRecorder.bridgePermissionRequest { completion in
                requestStarted.yield(())
                requestStarted.finish()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) {
                    completion(true)
                }
            }
        }
        for await _ in requests { break }
        task.cancel()
        let granted = await task.value
        XCTAssertFalse(granted)
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(100))
        // Let the real asynchronous completion arrive after cancellation: it must
        // be ignored rather than resuming the checked continuation a second time.
        try? await Task.sleep(for: .milliseconds(400))
    }

    func testStoppedCaptureRejectsLateTapBuffer() throws {
        let engine = AudioCaptureEngine()
        let buffer = try makeBuffer(channels: [[0.5, -0.5]])
        engine.handleBuffer(buffer, generation: 0)
        XCTAssertEqual(engine.stop(), [0.5, -0.5])
        engine.handleBuffer(buffer, generation: 0)
        XCTAssertEqual(engine.lastRMS, 0)
        XCTAssertTrue(engine.stop().isEmpty)
    }

    func testCaptureSessionSampleBufferPreservesChannelsAndSampleRate() throws {
        let engine = AudioCaptureEngine()
        let buffer = try makeSampleBuffer(samples: [0, 1, 0, -1, 0.5, 0.5], channels: 2, sampleRate: 24_000)
        engine.handleSampleBuffer(buffer, generation: 0)
        XCTAssertEqual(engine.sampleRate, 24_000)
        XCTAssertEqual(engine.lastRMS, 0.5, accuracy: 0.00001)
        XCTAssertEqual(engine.stop(), [0.5, -0.5, 0.5])
        engine.handleSampleBuffer(buffer, generation: 0)
        XCTAssertTrue(engine.stop().isEmpty, "CoreMedia callbacks from a stopped session must be discarded")
    }

    func testAlreadyCancelledStartDoesNotActivateRecording() async {
        let recorder = AudioRecorder()
        let task = Task {
            do {
                try await recorder.startRecording()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(recorder.stopRecording().isEmpty)
    }

    func testResamplingPreservesDurationAndSignalLevel() {
        let converted = AudioRecorder.resample(
            [Float](repeating: 0.25, count: 48_000), from: 48_000, to: 16_000
        )
        XCTAssertEqual(converted.count, 16_000)
        XCTAssertEqual(converted[8_000], 0.25, accuracy: 0.001)
    }

    func testStoppingIdleRecorderAsynchronouslyReturnsEmptyAudio() async {
        let recorder = AudioRecorder()
        let samples = await recorder.stopRecordingAndResample()
        XCTAssertTrue(samples.isEmpty)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.audioLevel, 0)
    }

    func testSelectedMicrophoneCaptureDoesNotChangeSystemDefault() async throws {
        guard ProcessInfo.processInfo.environment["VOICESCRIBE_RUN_CAPTURE_TESTS"] == "1" else {
            throw XCTSkip("Set VOICESCRIBE_RUN_CAPTURE_TESTS=1 to run authorized microphone hardware capture.")
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("The test runner needs microphone permission before hardware capture.")
        }
        let recorder = AudioRecorder()
        let defaultBefore = try defaultInputDeviceID()
        let previousSelection = recorder.selectedInputDeviceUID
        defer {
            _ = recorder.stopRecording()
            recorder.setSelectedInputDevice(uid: previousSelection)
        }
        let devices = recorder.availableInputDevices.filter {
            $0.id.contains("BuiltInMicrophone") || $0.name.localizedCaseInsensitiveContains("AirPods")
        }
        XCTAssertFalse(devices.isEmpty, "Hardware test requires a built-in microphone or AirPods")
        for device in devices {
            print("Hardware capture device: \(device.name)")
            recorder.setSelectedInputDevice(uid: device.id)
            try await recorder.startRecording()
            XCTAssertTrue(recorder.isRecording)
            XCTAssertEqual(try defaultInputDeviceID(), defaultBefore)
            try await Task.sleep(for: .seconds(1))
            let samples = await recorder.stopRecordingAndResample()
            XCTAssertFalse(recorder.isRecording)
            XCTAssertGreaterThanOrEqual(samples.count, 8_000, "\(device.name) must deliver at least half a second of real audio")
            XCTAssertTrue(samples.allSatisfy { $0.isFinite })
            XCTAssertEqual(try defaultInputDeviceID(), defaultBefore)
        }
    }

    private func defaultInputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr else {
            throw AudioRecorderError.engineSetupFailed("Cannot inspect default microphone: \(status)")
        }
        return device
    }

    private func makeBuffer(channels: [[Float]]) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: AVAudioChannelCount(channels.count), interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count)
        ))
        buffer.frameLength = buffer.frameCapacity
        let data = try XCTUnwrap(buffer.floatChannelData)
        for (channel, samples) in channels.enumerated() {
            data[channel].update(from: samples, count: samples.count)
        }
        return buffer
    }

    private func makeSampleBuffer(samples: [Float], channels: UInt32, sampleRate: Double) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: channels, interleaved: true
        ))
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description
        ), noErr)
        var block: CMBlockBuffer?
        let byteCount = samples.count * MemoryLayout<Float>.size
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block
        ), noErr)
        let blockBuffer = try XCTUnwrap(block)
        samples.withUnsafeBytes { bytes in
            XCTAssertEqual(CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: byteCount
            ), noErr)
        }
        var result: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: try XCTUnwrap(description),
            sampleCount: samples.count / Int(channels), presentationTimeStamp: .zero,
            packetDescriptions: nil, sampleBufferOut: &result
        ), noErr)
        return try XCTUnwrap(result)
    }
}
