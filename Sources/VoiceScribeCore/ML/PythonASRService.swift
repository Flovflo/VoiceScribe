import Foundation

/// Manages the Python ASR engine lifecycle and communication
@MainActor
public class PythonASRService: ObservableObject {
    
    // MARK: - Published State
    @Published public var status: String = "Initializing"
    @Published public var isReady: Bool = false
    @Published public var isModelCached: Bool = false
    @Published public var downloadProgress: String = ""
    @Published public var lastError: String?
    
    // MARK: - Private
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var outputBuffer = ""
    private var activeContinuation: CheckedContinuation<String, Never>?
    
    public init() {}
    
    // MARK: - Engine Lifecycle
    
    public func startEngine() async {
        status = "Launching ASR Engine..."
        lastError = nil
        
        // Locate Python and script

        // Locate Python
        let pythonPath: String
        let possiblePaths = [
            "/opt/homebrew/bin/python3", // Homebrew Apple Silicon
            "/usr/local/bin/python3",    // Homebrew Intel
            "/usr/bin/python3"           // System
        ]
        
        if let found = possiblePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            pythonPath = found
        } else {
            // Fallback (might fail if not in PATH/sandbox issues)
            pythonPath = "/usr/bin/python3"
        }
        
        // Check local venv for dev (override)
        let devVenv = "/Users/florian/Documents/Projet/Voice/venv/bin/python"
        let finalPythonPath = FileManager.default.fileExists(atPath: devVenv) ? devVenv : pythonPath

        // Try bundle first, then development path
        let scriptPath: String
        if let bundledPath = Bundle.main.path(forResource: "transcribe_daemon", ofType: "py") {
            scriptPath = bundledPath
        } else {
            scriptPath = "/Users/florian/Documents/Projet/Voice/VoiceScribe/backend/transcribe_daemon.py"
        }
        
        if !FileManager.default.fileExists(atPath: finalPythonPath) {
             status = "Error: Python not found"
             lastError = "Could not find python3 in standard locations."
             return
        }
        
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            status = "Error: Script not found"
            lastError = "ASR script not found at: \(scriptPath)"
            return
        }
        
        print("🐍 Starting Python: \(finalPythonPath)")
        print("📄 Script: \(scriptPath)")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: finalPythonPath)

        process.arguments = [scriptPath]
        
        // Set up pipes
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.process = process
        
        // Handle stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.handleOutput(str)
            }
        }
        
        // Handle stderr (for debug/logs)
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if let str = String(data: handle.availableData, encoding: .utf8), !str.isEmpty {
                print("🐍 PYTHON: \(str)")
            }
        }
        
        // Handle process termination
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                if proc.terminationStatus != 0 {
                    self?.status = "Engine crashed (code \(proc.terminationStatus))"
                    self?.isReady = false
                }
            }
        }
        
        do {
            try process.run()
            status = "Engine started, initializing..."
        } catch {
            status = "Failed to start engine"
            lastError = error.localizedDescription
        }
    }
    

    public func stopEngine() {
        if let process = process, process.isRunning {
             // Send quit command
             if let data = "QUIT\n".data(using: .utf8) {
                 try? stdinPipe?.fileHandleForWriting.write(contentsOf: data)
             }
             
             // Give it a moment, then terminate
             DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                 if process.isRunning {
                     process.terminate()
                 }
             }
         }
         isReady = false
         status = "Stopped"
     }
    
    public func setModel(_ modelName: String) {
        guard let pipe = stdinPipe else { return }
        print("Changing model to: \(modelName)")
        status = "Loading \(modelName)..."
        
        let command = "LOAD_MODEL:\(modelName)\n"
        if let data = command.data(using: .utf8) {
            try? pipe.fileHandleForWriting.write(contentsOf: data)
        }
    }

    
    // MARK: - Output Parsing
    
    private func handleOutput(_ chunk: String) {
        outputBuffer += chunk
        
        // Split by newlines
        var lines = outputBuffer.components(separatedBy: "\n")
        
        // Keep incomplete line in buffer
        if !chunk.hasSuffix("\n"), let last = lines.last {
            outputBuffer = last
            lines.removeLast()
        } else {
            outputBuffer = ""
        }
        
        for line in lines where !line.isEmpty {
            parseMessage(line)
        }
    }
    
    private func parseMessage(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else { return }
        
        struct Message: Codable {
            let type: String
            let state: String?
            let details: String?
            let message: String?
            let text: String?
            let language: String?
            let model: String?
            let path: String?
            let error: String?
        }
        
        guard let msg = try? JSONDecoder().decode(Message.self, from: data) else {
            print("⚠️ Could not parse: \(jsonString)")
            return
        }
        
        switch msg.type {
        case "status":
            handleStatusMessage(state: msg.state ?? "", details: msg.details ?? "")
            

        case "ready":
            status = msg.message ?? "Ready"
            isReady = true
            isModelCached = true
            
        case "download_start":
            status = "Downloading \(msg.model ?? "model")..."
            downloadProgress = "Starting download of \(msg.model ?? "model")..."
            
        case "download_complete":
            status = "Download complete"
            downloadProgress = ""
            isModelCached = true
            
        case "download_error":
            status = "Download failed"
            lastError = msg.error
            
        case "transcription":
            if let text = msg.text {
                activeContinuation?.resume(returning: text)
                activeContinuation = nil
                // Preserve model name in status if possible
                if status.contains("Ready") {
                     // Keep it
                } else {
                     status = "Ready"
                }

            }
            
        case "error":
            status = "Error"
            lastError = msg.message
            activeContinuation?.resume(returning: "(Error: \(msg.message ?? "Unknown"))")
            activeContinuation = nil
            
        case "fatal":
            status = "Fatal Error"
            lastError = msg.message
            isReady = false
            
        default:
            print("Unknown message type: \(msg.type)")
        }
    }
    
    private func handleStatusMessage(state: String, details: String) {
        switch state {
        case "initializing":
            status = "Initializing..."
        case "downloading":
            status = details.isEmpty ? "Downloading Model..." : details
            downloadProgress = details
        case "cached":
            status = "Model found in cache"
            isModelCached = true
        case "loading":
            status = details.isEmpty ? "Loading Model..." : details
            downloadProgress = details

        case "transcribing":
            status = "Transcribing..."
        case "shutdown":
            status = "Shutting down..."
        default:
            status = details.isEmpty ? state : details
        }
    }
    
    // MARK: - Transcription
    
    public func transcribe(audioPath: String) async -> String {
        guard isReady, let pipe = stdinPipe else {
            return "(Engine not ready)"
        }
        
        status = "Transcribing..."
        
        return await withCheckedContinuation { continuation in
            self.activeContinuation = continuation
            
            let command = "\(audioPath)\n"
            if let data = command.data(using: .utf8) {
                do {
                    try pipe.fileHandleForWriting.write(contentsOf: data)
                } catch {
                    continuation.resume(returning: "(Failed to send command)")
                    self.activeContinuation = nil
                }
            }
        }
    }
}
