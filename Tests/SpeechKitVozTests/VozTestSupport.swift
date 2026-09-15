#if !os(watchOS)
import Foundation
@testable import SpeechKitVoz

// Scripted engines and cache probes. Nothing here downloads a model or opens a
// network connection; the real engine is only exercised by the opt-in
// environment-gated smoke tests.

func temporaryVozAudioFileURL() -> URL {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("wav")
    try? Data("test".utf8).write(to: file)
    return file
}

@MainActor
func settleVozMainActor() async {
    await Task.yield()
    await Task.yield()
    await Task.yield()
}

enum StubVozError: LocalizedError, Sendable, Equatable {
    case preparationFailed

    var errorDescription: String? {
        switch self {
        case .preparationFailed:
            return "Preparation failed."
        }
    }
}

/// Answers the cache question from the configuration alone, so tests can check
/// both the result and that the current configuration reaches the probe.
struct DirectoryVozCacheProbe: VozModelCacheProbing {
    let cachedModelDirectory: URL?

    func isModelCached(configuration: VozConfiguration) -> Bool {
        configuration.modelDirectory == cachedModelDirectory
    }
}

actor ImmediateVozEngine: VozEngine {
    enum PreparationOutcome: Sendable {
        case success
        case failure
    }

    private var preparationOutcomes: [PreparationOutcome]
    private let response: VozFileTranscriptionResponse
    private var preparations = 0
    private var transcriptions = 0
    private var phases: [VozPreparationPhase] = []

    init(
        preparationOutcomes: [PreparationOutcome] = [.success],
        response: VozFileTranscriptionResponse = VozFileTranscriptionResponse(
            text: "",
            words: [],
            duration: 0,
            processingTime: 0
        )
    ) {
        self.preparationOutcomes = preparationOutcomes
        self.response = response
    }

    func prepare(
        phase: VozPreparationPhase,
        configuration: VozConfiguration,
        update: @escaping @Sendable (VozPreparationUpdate) -> Void
    ) async throws {
        preparations += 1
        phases.append(phase)
        update(.downloading(0.2))
        let outcome = preparationOutcomes.isEmpty ? .success : preparationOutcomes.removeFirst()
        switch outcome {
        case .success:
            update(.downloading(1))
            if phase == .load {
                update(.loading)
            }
        case .failure:
            throw StubVozError.preparationFailed
        }
    }

    func transcribe(file: URL) async throws -> VozFileTranscriptionResponse {
        transcriptions += 1
        return response
    }

    func release() async {}

    func prepareCallCount() -> Int { preparations }
    func transcribeCallCount() -> Int { transcriptions }
    func recordedPhases() -> [VozPreparationPhase] { phases }
}

actor BlockingVozEngine: VozEngine {
    private var preparations = 0
    private var phases: [VozPreparationPhase] = []
    private var preparationContinuation: CheckedContinuation<Void, Never>?
    private var preparationStartWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var preparationUpdate: (@Sendable (VozPreparationUpdate) -> Void)?

    func prepare(
        phase: VozPreparationPhase,
        configuration: VozConfiguration,
        update: @escaping @Sendable (VozPreparationUpdate) -> Void
    ) async throws {
        preparations += 1
        phases.append(phase)
        preparationUpdate = update
        update(.downloading(0.35))
        resumeSatisfiedStartWaiters()
        await withCheckedContinuation { preparationContinuation = $0 }
        update(.downloading(1))
        if phase == .load {
            update(.loading)
        }
    }

    func transcribe(file: URL) async throws -> VozFileTranscriptionResponse {
        VozFileTranscriptionResponse(text: "", words: [], duration: 0, processingTime: 0)
    }

    func release() async {
        finishPreparation()
    }

    func waitForPreparationStart(_ count: Int = 1) async {
        guard preparations < count else { return }
        await withCheckedContinuation { preparationStartWaiters.append((count, $0)) }
    }

    func finishPreparation() {
        preparationContinuation?.resume()
        preparationContinuation = nil
    }

    func emit(_ update: VozPreparationUpdate) {
        preparationUpdate?(update)
    }

    func prepareCallCount() -> Int { preparations }
    func recordedPhases() -> [VozPreparationPhase] { phases }

    private func resumeSatisfiedStartWaiters() {
        let ready = preparationStartWaiters.filter { $0.count <= preparations }
        preparationStartWaiters.removeAll { $0.count <= preparations }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

actor QueuedVozEngine: VozEngine {
    private var transcriptions = 0
    private var transcriptionsToFinish: [CheckedContinuation<Void, Never>] = []
    private var transcriptionStartWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func prepare(
        phase: VozPreparationPhase,
        configuration: VozConfiguration,
        update: @escaping @Sendable (VozPreparationUpdate) -> Void
    ) async throws {
        update(.downloading(1))
        if phase == .load {
            update(.loading)
        }
    }

    func transcribe(file: URL) async throws -> VozFileTranscriptionResponse {
        transcriptions += 1
        resumeSatisfiedStartWaiters()
        let transcriptNumber = transcriptions
        await withCheckedContinuation { transcriptionsToFinish.append($0) }
        return VozFileTranscriptionResponse(
            text: "transcript \(transcriptNumber)",
            words: [VozFileTranscriptionWord(text: "word", startTime: 0, endTime: 0.2)],
            duration: 0.2,
            processingTime: 0.1
        )
    }

    func release() async {}

    func waitForTranscriptionStart(_ count: Int) async {
        guard transcriptions < count else { return }
        await withCheckedContinuation {
            transcriptionStartWaiters.append((count, $0))
        }
    }

    func finishNextTranscription() {
        guard !transcriptionsToFinish.isEmpty else { return }
        transcriptionsToFinish.removeFirst().resume()
    }

    func transcribeCallCount() -> Int { transcriptions }

    private func resumeSatisfiedStartWaiters() {
        let ready = transcriptionStartWaiters.filter { $0.count <= transcriptions }
        transcriptionStartWaiters.removeAll { $0.count <= transcriptions }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

actor RetirementBlockingVozEngine: VozEngine {
    private var preparations = 0
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseStartWaiters: [CheckedContinuation<Void, Never>] = []

    func prepare(
        phase: VozPreparationPhase,
        configuration: VozConfiguration,
        update: @escaping @Sendable (VozPreparationUpdate) -> Void
    ) async throws {
        preparations += 1
        update(.downloading(1))
        if phase == .load {
            update(.loading)
        }
    }

    func transcribe(file: URL) async throws -> VozFileTranscriptionResponse {
        VozFileTranscriptionResponse(text: "", words: [], duration: 0, processingTime: 0)
    }

    func release() async {
        let waiters = releaseStartWaiters
        releaseStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitForReleaseStart() async {
        guard releaseContinuation == nil else { return }
        await withCheckedContinuation { releaseStartWaiters.append($0) }
    }

    func finishRelease() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func prepareCallCount() -> Int { preparations }
}

actor RetryCallbackVozEngine: VozEngine {
    private var preparationAttempt = 0
    private var failedPreparationUpdate: (@Sendable (VozPreparationUpdate) -> Void)?
    private var retryContinuation: CheckedContinuation<Void, Never>?
    private var retryStartWaiters: [CheckedContinuation<Void, Never>] = []

    func prepare(
        phase: VozPreparationPhase,
        configuration: VozConfiguration,
        update: @escaping @Sendable (VozPreparationUpdate) -> Void
    ) async throws {
        preparationAttempt += 1
        if preparationAttempt == 1 {
            failedPreparationUpdate = update
            throw StubVozError.preparationFailed
        }

        update(.downloading(0.4))
        let waiters = retryStartWaiters
        retryStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { retryContinuation = $0 }
        update(.loading)
    }

    func transcribe(file: URL) async throws -> VozFileTranscriptionResponse {
        VozFileTranscriptionResponse(text: "", words: [], duration: 0, processingTime: 0)
    }

    func release() async {
        finishRetry()
    }

    func waitForRetryStart() async {
        guard preparationAttempt < 2 else { return }
        await withCheckedContinuation { retryStartWaiters.append($0) }
    }

    func emitDelayedFailedPreparationUpdate(_ update: VozPreparationUpdate) {
        failedPreparationUpdate?(update)
    }

    func finishRetry() {
        retryContinuation?.resume()
        retryContinuation = nil
    }
}
#endif
