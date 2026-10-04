import XCTest
@preconcurrency import AVFoundation
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
}
