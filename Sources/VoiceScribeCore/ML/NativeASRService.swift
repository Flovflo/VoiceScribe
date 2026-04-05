import Foundation

/// UI-facing wrapper for the NativeASREngine actor.
@MainActor
public final class NativeASRService: ObservableObject {

    // MARK: - Published Properties

    @Published public private(set) var status: String = "Not initialized"
    @Published public private(set) var isReady: Bool = false
    @Published public private(set) var isModelCached: Bool = false
    @Published public private(set) var loadProgress: Double = 0.0
    @Published public private(set) var lastError: String?

    // MARK: - Private Properties

    private let engine: NativeASREngine
    private var eventsTask: Task<Void, Never>?

    // MARK: - Initialization

    public init(config: NativeASREngine.Config = .qwen3ASR_1_7B_8bit) {
        self.engine = NativeASREngine(config: config)
        startListening()
    }

    deinit {
        eventsTask?.cancel()
    }

    // MARK: - Public API

    public func loadModel() async throws {
        do {
            try await engine.loadModel()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public func transcribe(samples: [Float], sampleRate: Int) async throws -> String {
        try await engine.transcribe(samples: samples, sampleRate: sampleRate)
    }

    public func transcribe(from url: URL) async throws -> String {
        try await engine.transcribe(from: url)
    }

    public func setModel(_ name: String) {
        Task {
            do {
                try await engine.setModel(name)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    public func setModelAndWait(_ name: String) async throws {
        do {
            try await engine.setModel(name)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public func setPreferredLanguage(_ language: String?) {
        Task {
            await engine.setPreferredLanguage(language)
        }
    }

    public func setPreferredLanguageAndWait(_ language: String?) async {
        await engine.setPreferredLanguage(language)
    }

    public func shutdown() {
        status = "Shutdown"
        isReady = false
        isModelCached = false
        loadProgress = 0.0
        Task {
            await engine.shutdown()
        }
    }

    // MARK: - Private Helpers

    private func startListening() {
        eventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.engine.events {
                self.handle(event)
            }
        }
    }

    private func handle(_ event: NativeASREngine.Event) {
        switch event {
        case .status(let value):
            status = value
        case .progress(let value):
            loadProgress = value
        case .ready(let value):
            isReady = value
        case .cached(let value):
            isModelCached = value
        case .error(let message):
            lastError = message
        }
    }
}
