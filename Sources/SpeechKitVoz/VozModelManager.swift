#if !os(watchOS)
import Foundation

/// Runs the VOZ model lifecycle: download, load, serialized inference, release.
///
/// This is the engine-facing half of ``VozTranscriber``. It owns every task and
/// generation counter and reports state through ``onChange`` so the transcriber
/// can publish observable values without duplicating the bookkeeping.
@MainActor
final class VozModelManager {
    /// The configuration used for the current model lifecycle.
    ///
    /// Assigning a different configuration releases the loaded model. Cached
    /// files for the previous configuration stay on disk.
    var configuration: VozConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            release()
        }
    }

    /// The current download, loading, or ready state.
    private(set) var modelState: VozModelState = .unprepared {
        didSet {
            guard modelState != oldValue else { return }
            onChange?()
        }
    }

    /// The latest model-download fraction, from `0` through `1`.
    private(set) var downloadProgress: Double = 0 {
        didSet {
            guard downloadProgress != oldValue else { return }
            onChange?()
        }
    }

    /// Called on the main actor after ``modelState`` or ``downloadProgress`` changes.
    var onChange: (@MainActor () -> Void)?

    private let engine: any VozEngine
    private var preparationTask: Task<Void, Error>?
    private var preparationID: Int?
    private var preparationPhase: VozPreparationPhase?
    private var inferenceTail: Task<Void, Never>?
    private var inferenceTasks: [Int: Task<VozFileTranscriptionResponse, Error>] = [:]
    private var retirementTask: Task<Void, Never>?
    private var lifecycleGeneration = 0
    private var nextOperationID = 0

    /// Creates a manager backed by the real Core ML inference engine.
    init(configuration: VozConfiguration = .init()) {
        self.configuration = configuration
        self.engine = VozInferenceEngine()
    }

    /// Creates a manager with a caller-supplied engine, for tests.
    init(configuration: VozConfiguration, engine: any VozEngine) {
        self.configuration = configuration
        self.engine = engine
    }

    /// Takes the model as far as `phase`, sharing work already in flight.
    ///
    /// Concurrent callers share one operation. Cancelling one caller does not
    /// cancel the shared model download; call ``release()`` to explicitly
    /// discard the current lifecycle. A caller that needs a loaded model while
    /// a download-only operation is in flight waits for that download, then
    /// loads from its result.
    func prepare(_ phase: VozPreparationPhase) async throws {
        while true {
            if case .ready = modelState {
                return
            }

            if let preparationTask, let preparationID, let preparationPhase {
                let generation = lifecycleGeneration
                if preparationPhase >= phase {
                    return try await waitForPreparation(
                        preparationTask,
                        id: preparationID,
                        generation: generation
                    )
                }

                try await waitForPreparation(
                    preparationTask,
                    id: preparationID,
                    generation: generation
                )
                continue
            }

            return try await startPreparation(phase)
        }
    }

    /// Transcribes a completed local recording using the prepared, reusable model.
    ///
    /// This does not start microphone capture or realtime transcription.
    func transcribe(file: URL) async throws -> VozFileTranscriptionResponse {
        guard case .ready = modelState else {
            throw VozError.notPrepared
        }

        let expectedGeneration = lifecycleGeneration
        let previousInference = inferenceTail
        let engine = engine
        let inferenceID = makeOperationID()
        let transcriptionTask = Task {
            await previousInference?.value
            try Task.checkCancellation()
            return try await engine.transcribe(file: file)
        }
        inferenceTail = Task {
            _ = try? await transcriptionTask.value
        }
        inferenceTasks[inferenceID] = transcriptionTask
        let cancelInference: @MainActor @Sendable (Int) -> Void = { [weak self] id in
            self?.cancelInference(id)
        }

        return try await withTaskCancellationHandler {
            defer { inferenceTasks[inferenceID] = nil }
            let response = try await transcriptionTask.value
            try Task.checkCancellation()
            guard lifecycleGeneration == expectedGeneration, case .ready = modelState else {
                throw VozError.releasedDuringTranscription
            }
            return response
        } onCancel: {
            Task { @MainActor in
                cancelInference(inferenceID)
            }
        }
    }

    /// Discards the in-memory model and invalidates stale preparation or inference results.
    ///
    /// Cached model files remain on disk and will be reused by a later
    /// ``prepare(_:)`` call.
    func release() {
        lifecycleGeneration &+= 1
        let previousRetirement = retirementTask
        let previousPreparation = preparationTask
        let previousInference = inferenceTail
        previousPreparation?.cancel()
        for task in inferenceTasks.values {
            task.cancel()
        }
        preparationTask = nil
        preparationID = nil
        preparationPhase = nil
        inferenceTail = nil
        inferenceTasks = [:]
        modelState = .unprepared
        downloadProgress = 0

        let engine = engine
        retirementTask = Task {
            await previousRetirement?.value
            _ = try? await previousPreparation?.value
            await previousInference?.value
            await engine.release()
        }
    }

    /// Waits for work retired by ``release()`` to finish.
    func waitForRelease() async {
        await retirementTask?.value
    }

    private func startPreparation(_ phase: VozPreparationPhase) async throws {
        let expectedGeneration = lifecycleGeneration
        let engine = engine
        let configuration = configuration
        let precedingRetirement = retirementTask
        let preparationID = makeOperationID()
        modelState = .checkingCache
        downloadProgress = 0
        self.preparationID = preparationID
        self.preparationPhase = phase
        let updateState: @MainActor @Sendable (VozPreparationUpdate) -> Void = { [weak self] update in
            self?.receive(update, for: expectedGeneration, preparationID: preparationID)
        }

        let task = Task {
            await precedingRetirement?.value
            try Task.checkCancellation()
            try await engine.prepare(phase: phase, configuration: configuration) { update in
                Task { @MainActor in
                    updateState(update)
                }
            }
        }
        preparationTask = task
        let finishState: @MainActor @Sendable (Result<Void, Error>) -> Void = { [weak self] result in
            self?.finishPreparation(result, id: preparationID, generation: expectedGeneration)
        }
        Task { @MainActor in
            do {
                try await task.value
                finishState(.success(()))
            } catch {
                finishState(.failure(error))
            }
        }

        return try await waitForPreparation(task, id: preparationID, generation: expectedGeneration)
    }

    private func receive(
        _ update: VozPreparationUpdate,
        for generation: Int,
        preparationID: Int
    ) {
        guard lifecycleGeneration == generation, self.preparationID == preparationID else {
            return
        }

        switch update {
        case .downloading(let fraction):
            // Download callbacks hop to the main actor independently. A late
            // callback must not move the UI back after Core ML loading starts.
            guard modelState != .loading else { return }
            let boundedFraction = max(downloadProgress, min(max(fraction, 0), 1))
            downloadProgress = boundedFraction
            modelState = .downloading(progress: boundedFraction)
        case .loading:
            downloadProgress = 1
            modelState = .loading
        }
    }

    private func waitForPreparation(
        _ task: Task<Void, Error>,
        id: Int,
        generation: Int
    ) async throws {
        do {
            try await task.value
            guard lifecycleGeneration == generation else {
                throw CancellationError()
            }
            finishPreparation(.success(()), id: id, generation: generation)
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled && !task.isCancelled {
                throw CancellationError()
            }
            finishPreparation(.failure(error), id: id, generation: generation)
            throw error
        }
    }

    private func finishPreparation(
        _ result: Result<Void, Error>,
        id: Int,
        generation: Int
    ) {
        guard lifecycleGeneration == generation, preparationID == id else {
            return
        }
        let phase = preparationPhase ?? .load
        preparationTask = nil
        preparationID = nil
        preparationPhase = nil

        switch result {
        case .success:
            downloadProgress = 1
            // A download-only operation leaves nothing in memory, so the model
            // returns to `.unprepared` with its files cached on disk.
            modelState = phase == .load ? .ready : .unprepared
        case .failure(let error) where error is CancellationError:
            modelState = .unprepared
        case .failure(let error):
            modelState = .failed(message: failureMessage(for: error))
        }
    }

    private func cancelInference(_ id: Int) {
        inferenceTasks[id]?.cancel()
    }

    private func makeOperationID() -> Int {
        defer { nextOperationID &+= 1 }
        return nextOperationID
    }

    private func failureMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let message = localizedError.errorDescription,
           !message.isEmpty {
            return message
        }
        return error.localizedDescription
    }
}
#endif
