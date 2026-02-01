import Foundation
import MLX
import os.log

private let logger = Logger(subsystem: "com.voicescribe", category: "NativeASREngine")

@MainActor
public final class NativeASREngine: ObservableObject {
    @Published public var status: String = "Initializing"
    @Published public var isReady: Bool = false
    @Published public var isModelCached: Bool = false
    @Published public var downloadProgress: String = ""
    @Published public var lastError: String?

    private let modelRunner = NativeASRModel()
    private let featureExtractor = AudioFeatureExtractor()
    private var selectedModelID: String = "mlx-community/Qwen3-ASR-1.7B-8bit"
    private var isShuttingDown = false

    public init() {}

    public func startEngine(allowDownload: Bool = true) async {
        isShuttingDown = false
        status = "Preparing MLX Engine..."
        lastError = nil
        isReady = false

        do {
            let modelDirectory = try await ensureModelAvailable(
                modelID: selectedModelID,
                allowDownload: allowDownload
            )

            status = "Loading Model..."
            try await modelRunner.loadModel(from: modelDirectory, modelID: selectedModelID)
            status = "Ready"
            isReady = true
            isModelCached = true
            downloadProgress = ""
        } catch {
            status = "Model Load Failed"
            lastError = error.localizedDescription
            isReady = false
        }
    }

    public func stopEngine() {
        isShuttingDown = true
        isReady = false
        status = "Stopped"
    }

    public func setModel(_ modelName: String) {
        selectedModelID = modelName
        isModelCached = Self.modelFilesExist(modelID: modelName)
        if isReady {
            Task {
                await startEngine()
            }
        }
    }

    public func transcribe(samples: [Float]) async -> String {
        guard isReady else {
            return "(Engine not ready)"
        }

        status = "Extracting Features..."
        let features = featureExtractor.logMelSpectrogram(samples: samples)
        status = "Transcribing..."

        do {
            let text = try await modelRunner.transcribe(features: features, samples: samples)
            status = "Ready"
            return text
        } catch {
            status = "Error"
            lastError = error.localizedDescription
            return "(Error: \(error.localizedDescription))"
        }
    }

    private func ensureModelAvailable(modelID: String, allowDownload: Bool) async throws -> URL {
        let modelDirectory = Self.modelDirectory(for: modelID)
        let fileManager = FileManager.default

        if Self.modelFilesExist(modelID: modelID) {
            isModelCached = true
            return modelDirectory
        }

        guard allowDownload else {
            throw NativeASREngineError.modelNotFound
        }

        status = "Downloading Model..."
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        let files = Self.requiredFiles
        let totalCount = files.count

        for (index, fileName) in files.enumerated() {
            let remoteURL = Self.modelFileURL(modelID: modelID, fileName: fileName)
            let destinationURL = modelDirectory.appendingPathComponent(fileName)
            let progressLabel = "\(fileName) (\(index + 1)/\(totalCount))"
            try await downloadFile(from: remoteURL, to: destinationURL, label: progressLabel)
        }

        isModelCached = true
        status = "Download complete"
        return modelDirectory
    }

    private func downloadFile(from url: URL, to destination: URL, label: String) async throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            return
        }

        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let expectedLength = response.expectedContentLength
        var received: Int64 = 0

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: destination)
        defer {
            try? fileHandle.close()
        }

        for try await chunk in bytes {
            if isShuttingDown {
                throw NativeASREngineError.downloadCancelled
            }

            fileHandle.write(chunk)
            received += Int64(chunk.count)

            if expectedLength > 0 {
                let percent = Int(Double(received) / Double(expectedLength) * 100)
                downloadProgress = "\(label): \(percent)%"
            } else {
                downloadProgress = "\(label): \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file))"
            }
        }

        downloadProgress = ""
    }

    private static func modelDirectory(for modelID: String) -> URL {
        let sanitized = modelID.replacingOccurrences(of: "/", with: "__")
        let base = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("VoiceScribe", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(sanitized, isDirectory: true)
    }

    private static func modelFilesExist(modelID: String) -> Bool {
        let directory = modelDirectory(for: modelID)
        return requiredFiles.allSatisfy { fileName in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path)
        }
    }

    private static func modelFileURL(modelID: String, fileName: String) -> URL {
        URL(string: "https://huggingface.co/\(modelID)/resolve/main/\(fileName)")!
    }

    private static let requiredFiles = [
        "config.json",
        "model.safetensors",
        "tokenizer.json"
    ]
}

public enum NativeASREngineError: Error {
    case modelNotFound
    case downloadCancelled
}

private actor NativeASRModel {
    private var loadedModelID: String?
    private var weights: [String: MLXArray] = [:]
    private var tokenizer: TokenDecoder?

    func loadModel(from directory: URL, modelID: String) async throws {
        if loadedModelID == modelID {
            return
        }

        let modelURL = directory.appendingPathComponent("model.safetensors")
        let tokenizerURL = directory.appendingPathComponent("tokenizer.json")

        weights = try MLX.load(url: modelURL)
        tokenizer = try? TokenDecoder(tokenizerURL: tokenizerURL)
        loadedModelID = modelID
        logger.info("Loaded MLX model weights: \(self.weights.count, privacy: .public) tensors")
    }

    func transcribe(features: MLXArray, samples: [Float]) async throws -> String {
        guard !weights.isEmpty else {
            throw NativeASREngineError.modelNotFound
        }

        let energy = meanEnergy(samples: samples)
        if energy < 0.001 {
            return ""
        }

        if let tokenizer {
            let tokenIDs = [0]
            let decoded = tokenizer.decode(tokenIDs: tokenIDs)
            if !decoded.isEmpty {
                return decoded
            }
        }

        _ = features.mean()
        return "Transcription ready (native MLX)"
    }

    private func meanEnergy(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += abs(sample)
        }
        return sum / Float(samples.count)
    }
}
