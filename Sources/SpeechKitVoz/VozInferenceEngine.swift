#if !os(watchOS)
import Foundation
import ModelStore
import Voz

/// How far a lifecycle operation should take the model.
///
/// `.download` is ordered before `.load`, so a caller that needs a loaded model
/// can tell whether an in-flight operation already covers its request.
enum VozPreparationPhase: Sendable, Comparable {
    /// Fetch the model files only. Nothing is loaded into memory.
    case download
    /// Fetch the model files if needed, then load them into memory.
    case load
}

/// Progress reported by the engine while it works through a phase.
enum VozPreparationUpdate: Sendable {
    case downloading(Double)
    case loading
}

protocol VozEngine: Sendable {
    func prepare(
        phase: VozPreparationPhase,
        configuration: VozConfiguration,
        update: @escaping @Sendable (VozPreparationUpdate) -> Void
    ) async throws

    func transcribe(file: URL) async throws -> VozFileTranscriptionResponse
    func release() async
}

/// Keeps Core ML, AVFoundation decoding, and the VOZ actor off the main actor.
actor VozInferenceEngine: VozEngine {
    private var voz: Voz?
    private var generation = 0

    func prepare(
        phase: VozPreparationPhase,
        configuration: VozConfiguration,
        update: @escaping @Sendable (VozPreparationUpdate) -> Void
    ) async throws {
        if voz != nil {
            // A loaded model implies a complete verified download.
            update(.downloading(1))
            return
        }

        guard VozModel.supports(.current) else {
            throw VozError.unavailable
        }

        let expectedGeneration = generation
        let directory = configuration.modelDirectory?.path
        let cacheRoot = configuration.cacheDirectory?.path

        // ModelStore verifies a complete cached model with its pure-Swift
        // SHA-256 implementation before returning from `download`. On a Debug
        // build that can keep the UI at 0% for several minutes. Verify the same
        // manifest with CryptoKit when the cache is already complete, then load
        // it directly. Invalid or incomplete caches continue through
        // `Voz.download`, which repairs them with the SDK's integrity checks.
        if let cachedDirectory = VozCachedModel.location(for: configuration),
           VozCachedModel.isValid(at: cachedDirectory) {
            try Task.checkCancellation()
            update(.downloading(1))
            guard phase == .load else { return }
            update(.loading)
            let loadedModel = try load(at: cachedDirectory)
            try Task.checkCancellation()
            guard expectedGeneration == generation else {
                throw CancellationError()
            }
            voz = loadedModel
            return
        }

        // `ModelStore.isDownloaded` is deliberately a synchronous Bool API and
        // cannot propagate cancellation from a custom digest. Do not begin a
        // network repair after the caller has cancelled while the cache check
        // was running.
        try Task.checkCancellation()

        // `download` resolves a managed or caller-supplied directory and verifies
        // every cached artifact before returning its root. Reusing that root for
        // the direct initializer avoids a second full SHA-256 cache verification.
        let modelRoot: String
        do {
            modelRoot = try await Voz.download(directory: directory, cacheRoot: cacheRoot) { progress in
                update(.downloading(progress.fraction))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VozError.downloadFailed(String(describing: error))
        }

        try Task.checkCancellation()
        guard expectedGeneration == generation else {
            throw CancellationError()
        }

        update(.downloading(1))
        guard phase == .load else { return }

        update(.loading)
        let loadedModel = try load(at: URL(fileURLWithPath: modelRoot))

        try Task.checkCancellation()
        guard expectedGeneration == generation else {
            throw CancellationError()
        }

        voz = loadedModel
    }

    func transcribe(file: URL) async throws -> VozFileTranscriptionResponse {
        guard let voz else {
            throw VozError.notPrepared
        }
        guard file.isFileURL else {
            throw VozError.transcriptionFailed("VOZ can only transcribe a local file URL")
        }

        try Task.checkCancellation()

        // VOZ decodes, downmixes, and resamples the file as a stream. Its
        // underlying actor performs synchronous inference, keeping requests
        // serialized without retaining an entire recording in memory.
        let result: Voz.Result
        do {
            result = try await voz.transcribe(file)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VozError.transcriptionFailed(String(describing: error))
        }
        try Task.checkCancellation()

        return VozFileTranscriptionResponse(
            text: result.text,
            words: result.words.map {
                VozFileTranscriptionWord(
                    text: $0.text,
                    startTime: $0.start,
                    endTime: $0.end
                )
            },
            duration: result.duration,
            processingTime: result.processingTime
        )
    }

    func release() {
        generation &+= 1
        voz = nil
    }

    private func load(at directory: URL) throws -> Voz {
        do {
            return try Voz(modelDirectory: directory)
        } catch {
            throw VozError.loadFailed(String(describing: error))
        }
    }
}
#endif
