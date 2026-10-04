import Foundation
import CryptoKit
import Metal
import MLX
import MLXNN
import MLXAudioCore
import MLXAudioSTT
import BenchmarkMetrics

private struct ModelSpec: Codable, Sendable {
    let name: String
    let repository: String
    let revision: String
    let weightSHA256: String
    let files: [String]
    static let all = [
        ModelSpec(name: "voxtral", repository: "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit",
                  revision: "fdebf7b2af834a1db4b8a3c99ab7480b333adf9e", weightSHA256: "6f59b425d8a1ceb2de795454558be63937cf75b59f9c9bc77accd85aaf32af05",
                  files: ["config.json", "model.safetensors", "model.safetensors.index.json", "tekken.json"]),
        ModelSpec(name: "qwen", repository: "mlx-community/Qwen3-ASR-1.7B-4bit",
                  revision: "78a389c776a5483b2d0d4ea5494e11012e0d6159", weightSHA256: "9848eaf7a5c1589c671b35035ac27b72e248dd0c604eacae547e7e403d29db45",
                  files: ["config.json", "model.safetensors", "model.safetensors.index.json", "chat_template.json",
                          "generation_config.json", "merges.txt", "preprocessor_config.json", "tokenizer_config.json", "vocab.json"]),
        ModelSpec(name: "parakeet", repository: "mlx-community/parakeet-tdt-0.6b-v3",
                  revision: "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15", weightSHA256: "05e01c7f396c298cf7d23f61da7b504adeab698f0aaeafd9c82d198625464592", files: ["config.json", "model.safetensors", "vocab.txt"])
    ]
}

private struct Options: Sendable {
    var model = ""
    var modelRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/VoiceScribeBenchmark/models")
    var fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    var output = URL(fileURLWithPath: "benchmark.json")
    var runs = 3
    var prepare = false
    static let usage = """
    Usage: asr-benchmark --model voxtral|qwen|parakeet [--prepare]
      --model-root PATH  Immutable model snapshots (default ~/Library/Caches/VoiceScribeBenchmark/models)
      --fixtures PATH    Directory containing fr.wav and en.wav
      --runs N           Measured repetitions per condition, default 3
      --output PATH      JSON checkpoint/report, default benchmark.json
      --prepare          Download chosen model only, no GPU inference; --model all is allowed
    Run one model per process, serially, to isolate memory and avoid GPU contention.
    """
    static func parse() throws -> Options {
        var result = Options()
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let key = args.removeFirst()
            if key == "--prepare" { result.prepare = true; continue }
            guard !args.isEmpty else { throw failure("Missing value for \(key)") }
            let value = args.removeFirst()
            switch key {
            case "--model": result.model = value
            case "--model-root": result.modelRoot = URL(fileURLWithPath: value)
            case "--fixtures": result.fixtures = URL(fileURLWithPath: value)
            case "--output": result.output = URL(fileURLWithPath: value)
            case "--runs":
                guard let runs = Int(value), (1...10).contains(runs) else { throw failure("--runs must be 1...10") }
                result.runs = runs
            default: throw failure("Unknown option: \(key)")
            }
        }
        guard ModelSpec.all.contains(where: { $0.name == result.model }) || (result.prepare && result.model == "all") else {
            throw failure("Choose --model voxtral|qwen|parakeet (all only with --prepare)")
        }
        return result
    }
}

private struct AudioCase {
    let name: String
    let samples: [Float]
    let reference: String
}
private struct Measurement: Codable, Sendable {
    let condition: String
    let phase: String
    let repetition: Int
    let audioSeconds: Double
    let inferenceSeconds: Double
    let realTimeFactor: Double
    let peakMLXActiveBytes: Int
    let activeMLXBytesAfter: Int
    let cacheMLXBytesAfter: Int
    let generationTokens: Int
    let transcript: String
    let reference: String
    let wordErrorRate: Double?
    let emittedWords: Int
    let status: String
}
private struct Report: Encodable, Sendable {
    var status = "running"
    var failure: String?
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let libraryRevision = "8d86630ade569728aaea3dc1a29fc44e2efa719b"
    let compatibilityPatch = "parakeet-swift6.patch: capture annotations only; serial use"
    let device = MTLCreateSystemDefaultDevice()?.name ?? "No Metal device"
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    let model: ModelSpec
    let runs: Int
    let maxTokens = 512
    let perOperationTimeoutSeconds = 180
    let parakeetGenerationLimit = "Upstream frame/symbol bounded decoding; maxTokens is not consumed by Parakeet"
    let temperature: Float = 0
    let languageHint: String? = nil
let cacheLimitBytes = 512 * 1024 * 1024
    let measurementScope = "Resident mono 16kHz samples; features + inference + token decode, GPU synchronized; excludes audio file I/O"
    let localModelLoadScope = "Local weights + tokenizer initialization + eval, excludes network; OS page cache not flushed"
    let parakeetComputeDType = "bfloat16 (upstream default), float32 stored weights"
    let fixtureProvenance = "macOS say: Thomas (French), Samantha (English), converted by afconvert to Int16 mono 16kHz; synthetic small corpus"
    var fixtureSHA256: [String: String] = [:]
    var verifiedWeightSHA256: String?
    var localModelLoadSeconds: Double?
    var loadPeakMLXActiveBytes: Int?
    var measurements: [Measurement] = []
}

private func failure(_ description: String) -> NSError {
    NSError(domain: "ASRBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
}
private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
private func seconds(since start: UInt64) -> Double { Double(now() - start) / 1e9 }
private func save(_ report: Report, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(report).write(to: url, options: .atomic)
}

private func prepare(_ spec: ModelSpec, root: URL) async throws {
    let directory = root.appendingPathComponent(spec.name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for filename in spec.files {
        let destination = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path),
           (try destination.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 > 0 { continue }
        let url = URL(string: "https://huggingface.co/\(spec.repository)/resolve/\(spec.revision)/\(filename)")!
        print("Downloading \(spec.name)/\(filename) at \(spec.revision)")
        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw failure("Failed download: \(url)")
        }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

private func verifyWeights(_ spec: ModelSpec, root: URL) throws -> String {
    let url = root.appendingPathComponent(spec.name).appendingPathComponent("model.safetensors")
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest == spec.weightSHA256 else { throw failure("Weight SHA256 mismatch for \(spec.name): \(digest)") }
    return digest
}

private func cases(fixtures: URL, report: inout Report) throws -> [AudioCase] {
    let texts = [
        "fr": "Bonjour, ceci est un test de transcription en français. Je voudrais vérifier que les accents et la ponctuation fonctionnent correctement sur mon Mac.",
        "en": "Hello, this is an English dictation test. I want to check that speech recognition works correctly on my Mac, including punctuation and everyday words."
    ]
    var result: [AudioCase] = []
    for language in ["fr", "en"] {
        let url = fixtures.appendingPathComponent("\(language).wav")
        let data = try Data(contentsOf: url)
        report.fixtureSHA256[language] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let (_, audio) = try loadAudioArray(from: url, sampleRate: 16_000)
        let samples = audio.asArray(Float.self)
        guard !samples.isEmpty else { throw failure("Empty fixture: \(url.path)") }
        let reference = texts[language]!
        result.append(AudioCase(name: "\(language)-clean", samples: samples, reference: reference))
        result.append(AudioCase(name: "\(language)-noise10dB", samples: AudioConditions.addingNoise(samples, snrDB: 10), reference: reference))
        let gap = [Float](repeating: 0, count: 8_000)
        result.append(AudioCase(name: "\(language)-long3x", samples: samples + gap + samples + gap + samples,
                                reference: [String](repeating: reference, count: 3).joined(separator: " ")))
    }
    result.append(AudioCase(name: "silence10s", samples: [Float](repeating: 0, count: 160_000), reference: ""))
    return result
}

private func timeoutGuard(report: Report, output: URL, operation: String) -> DispatchSourceTimer {
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now() + .seconds(report.perOperationTimeoutSeconds))
    timer.setEventHandler {
        var timedOut = report
        timedOut.status = "failed"
        timedOut.failure = "Timeout after \(report.perOperationTimeoutSeconds)s: \(operation)"
        try? save(timedOut, to: output)
        FileHandle.standardError.write(Data("\(timedOut.failure!)\n".utf8))
        _exit(124)
    }
    timer.resume()
    return timer
}

private func load(_ spec: ModelSpec, root: URL) async throws -> any STTGenerationModel {
    let directory = root.appendingPathComponent(spec.name)
    switch spec.name {
    case "voxtral": return try VoxtralRealtimeModel.fromDirectory(directory)
    case "qwen": return try await Qwen3ASRModel.fromModelDirectory(directory)
    case "parakeet": return try ParakeetModel.fromDirectory(directory)
    default: throw failure("Unexpected model")
    }
}

private func measure(model: any STTGenerationModel, audioCase: AudioCase, phase: String, repetition: Int) -> Measurement {
    let audio = MLXArray(audioCase.samples)
    eval(audio)
    Stream.gpu.synchronize()
    Memory.peakMemory = 0
    let start = now()
    let output = model.generate(audio: audio, generationParameters: STTGenerateParameters(maxTokens: 512, temperature: 0))
    Stream.gpu.synchronize()
    let elapsed = seconds(since: start)
    let duration = Double(audioCase.samples.count) / 16_000
    let wordCount = Metrics.words(output.text).count
    let status: String
    if output.generationTokens >= 512 { status = "tokenLimitReached" }
    else if audioCase.reference.isEmpty && wordCount > 0 { status = "silenceHallucination" }
    else if !audioCase.reference.isEmpty && wordCount == 0 { status = "emptyTranscript" }
    else { status = "ok" }
    return Measurement(condition: audioCase.name, phase: phase, repetition: repetition,
                       audioSeconds: duration, inferenceSeconds: elapsed, realTimeFactor: elapsed / duration,
                       peakMLXActiveBytes: Memory.peakMemory, activeMLXBytesAfter: Memory.activeMemory,
                       cacheMLXBytesAfter: Memory.cacheMemory, generationTokens: output.generationTokens,
                       transcript: output.text, reference: audioCase.reference,
                       wordErrorRate: Metrics.wordErrorRate(reference: audioCase.reference, hypothesis: output.text),
                       emittedWords: wordCount, status: status)
}

@main struct Benchmark {
    static func main() async {
        if CommandLine.arguments.contains("--help") { print(Options.usage); return }
        do {
            let options = try Options.parse()
            try await run(options)
        } catch {
            FileHandle.standardError.write(Data("ASRBenchmark failed: \(error)\n".utf8))
            exit(1)
        }
    }
}

@concurrent private func run(_ options: Options) async throws {
    let specs = ModelSpec.all.filter { options.model == "all" || $0.name == options.model }
    if options.prepare {
        for spec in specs { try await prepare(spec, root: options.modelRoot); _ = try verifyWeights(spec, root: options.modelRoot) }
        return
    }
    let spec = specs[0]
    var report = Report(model: spec, runs: options.runs)
    try save(report, to: options.output)
    do {
        try await Device.withDefaultDevice(.gpu) {
            Memory.cacheLimit = report.cacheLimitBytes
            report.verifiedWeightSHA256 = try verifyWeights(spec, root: options.modelRoot)
            let audioCases = try cases(fixtures: options.fixtures, report: &report)
            Stream.gpu.synchronize()
            Memory.peakMemory = 0
            let start = now()
            let loadTimeout = timeoutGuard(report: report, output: options.output, operation: "model load")
            let model = try await load(spec, root: options.modelRoot)
            if let module = model as? Module { eval(module.parameters()) }
            Stream.gpu.synchronize()
            loadTimeout.cancel()
            report.localModelLoadSeconds = seconds(since: start)
            report.loadPeakMLXActiveBytes = Memory.peakMemory
            try save(report, to: options.output)
            // First generation is explicitly retained as cold inference,
            // then each condition gets its own untimed shape warmup.
            for audioCase in audioCases {
                let warmupTimeout = timeoutGuard(report: report, output: options.output, operation: "warmup \(audioCase.name)")
                let cold = measure(model: model, audioCase: audioCase, phase: report.measurements.isEmpty ? "firstInference" : "conditionWarmup", repetition: 0)
                warmupTimeout.cancel()
                report.measurements.append(cold)
                try save(report, to: options.output)
                for run in 1...options.runs {
                    let inferenceTimeout = timeoutGuard(report: report, output: options.output, operation: "inference \(audioCase.name), run \(run)")
                    let measurement = measure(model: model, audioCase: audioCase, phase: "warm", repetition: run)
                    inferenceTimeout.cancel()
                    report.measurements.append(measurement)
                    try save(report, to: options.output)
                    print(String(format: "%@ %@ run %d: %.3fs, WER %@, %@", spec.name, audioCase.name, run,
                                 measurement.inferenceSeconds, measurement.wordErrorRate.map { String(format: "%.3f", $0) } ?? "n/a", measurement.status))
                }
            }
            report.status = "completed"
            try save(report, to: options.output)
        }
    } catch {
        report.status = "failed"
        report.failure = String(describing: error)
        try save(report, to: options.output)
        throw error
    }
}
