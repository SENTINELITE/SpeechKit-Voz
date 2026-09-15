import Foundation
import SpeechKit
import Testing
@testable import SpeechKitVoz

#if !os(watchOS)
@Suite("VOZ Model Lifecycle")
struct VozLifecycleTests {
    @Test("isModelCached answers from the current configuration without loading a model")
    @MainActor
    func isModelCachedReflectsTheCurrentConfiguration() async {
        let cachedDirectory = URL(fileURLWithPath: "/tmp/voz-cached")
        let engine = ImmediateVozEngine()
        let transcriber = VozTranscriber(
            configuration: VozConfiguration(modelDirectory: cachedDirectory),
            engine: engine,
            cacheProbe: DirectoryVozCacheProbe(cachedModelDirectory: cachedDirectory)
        )

        #expect(transcriber.isModelCached())
        #expect(transcriber.modelState == .unprepared)
        #expect(await engine.prepareCallCount() == 0)

        transcriber.configuration = VozConfiguration(modelDirectory: URL(fileURLWithPath: "/tmp/voz-other"))
        #expect(!transcriber.isModelCached())

        // The probe is `nonisolated`, so it is callable off the main actor.
        let offMainActor = await Task.detached { transcriber.isModelCached() }.value
        #expect(!offMainActor)
        #expect(await engine.prepareCallCount() == 0)
    }

    @Test("downloadIfNeeded fetches files without loading, and load completes the lifecycle")
    @MainActor
    func downloadIfNeededFetchesWithoutLoading() async throws {
        let engine = ImmediateVozEngine()
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)

        try await transcriber.downloadIfNeeded()

        #expect(transcriber.modelState == .unprepared)
        #expect(transcriber.downloadProgress == 1)
        #expect(transcriber.isReady == false)
        #expect(await engine.recordedPhases() == [.download])

        try await transcriber.load()

        #expect(transcriber.modelState == .ready)
        #expect(transcriber.downloadProgress == 1)
        #expect(await engine.recordedPhases() == [.download, .load])
    }

    @Test("a load requested during a download-only operation shares that download")
    @MainActor
    func loadDuringDownloadSharesTheDownload() async throws {
        let engine = BlockingVozEngine()
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)

        let download = Task { try await transcriber.downloadIfNeeded() }
        await engine.waitForPreparationStart(1)
        let load = Task { try await transcriber.load() }
        await settleVozMainActor()
        #expect(await engine.prepareCallCount() == 1)

        await engine.finishPreparation()
        try await download.value

        await engine.waitForPreparationStart(2)
        await engine.finishPreparation()
        try await load.value

        #expect(transcriber.modelState == .ready)
        #expect(await engine.recordedPhases() == [.download, .load])
    }

    @Test("prepareInBackground is idempotent while a preparation is in flight")
    @MainActor
    func prepareInBackgroundIsIdempotent() async throws {
        let engine = BlockingVozEngine()
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)

        let first = transcriber.prepareInBackground()
        let second = transcriber.prepareInBackground()
        #expect(first == second)

        await engine.waitForPreparationStart()
        #expect(transcriber.prepareInBackground() == first)
        #expect(await engine.prepareCallCount() == 1)

        await engine.finishPreparation()
        await first.value

        #expect(transcriber.modelState == .ready)
        #expect(await engine.prepareCallCount() == 1)

        let third = transcriber.prepareInBackground()
        #expect(third != first)
        await third.value
        #expect(transcriber.modelState == .ready)
        #expect(await engine.prepareCallCount() == 1)
    }

    @Test("prepareInBackground reports a failure through modelState instead of throwing")
    @MainActor
    func prepareInBackgroundRecordsFailureInModelState() async {
        let engine = ImmediateVozEngine(preparationOutcomes: [.failure])
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)

        await transcriber.prepareInBackground().value

        #expect(transcriber.modelState == .failed(message: StubVozError.preparationFailed.localizedDescription))
        #expect(transcriber.isReady == false)
    }

    @Test("waitUntilReady resolves after a preparation already in flight")
    @MainActor
    func waitUntilReadyResolvesAfterBackgroundPreparation() async throws {
        let engine = BlockingVozEngine()
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)

        transcriber.prepareInBackground()
        await engine.waitForPreparationStart()

        let waiter = Task { try await transcriber.waitUntilReady() }
        await settleVozMainActor()
        #expect(transcriber.isReady == false)

        await engine.finishPreparation()
        try await waiter.value

        #expect(transcriber.modelState == .ready)
        #expect(await engine.prepareCallCount() == 1)
    }

    @Test("waitUntilReady starts preparation when none is in flight")
    @MainActor
    func waitUntilReadyStartsPreparation() async throws {
        let engine = ImmediateVozEngine()
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)

        try await transcriber.waitUntilReady()

        #expect(transcriber.modelState == .ready)
        #expect(await engine.prepareCallCount() == 1)

        try await transcriber.waitUntilReady()
        #expect(await engine.prepareCallCount() == 1)
    }

    @Test("waitUntilReady throws when preparation fails and keeps throwing while failed")
    @MainActor
    func waitUntilReadyThrowsOnFailure() async {
        let engine = ImmediateVozEngine(preparationOutcomes: [.failure])
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)

        await #expect(throws: StubVozError.preparationFailed) {
            try await transcriber.waitUntilReady()
        }

        let message = StubVozError.preparationFailed.localizedDescription
        #expect(transcriber.modelState == .failed(message: message))
        await #expect(throws: VozError.loadFailed(message)) {
            try await transcriber.waitUntilReady()
        }
        #expect(await engine.prepareCallCount() == 1)
    }

    @Test("stateUpdates yields the current state and then every change")
    @MainActor
    func stateUpdatesYieldsCurrentThenSubsequentStates() async throws {
        let engine = BlockingVozEngine()
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)

        var iterator = transcriber.stateUpdates.makeAsyncIterator()
        #expect(await iterator.next() == .unprepared)

        let preparation = Task { try await transcriber.prepare() }
        await engine.waitForPreparationStart()

        #expect(await iterator.next() == .checkingCache)
        #expect(await iterator.next() == .downloading(progress: 0.35))

        await engine.finishPreparation()
        try await preparation.value

        var observed: [VozModelState] = []
        while let state = await iterator.next() {
            observed.append(state)
            if state == .ready { break }
        }
        #expect(observed.last == .ready)
        #expect(!observed.contains(.unprepared))

        // A second stream starts from the current state rather than replaying.
        var late = transcriber.stateUpdates.makeAsyncIterator()
        #expect(await late.next() == .ready)

        transcriber.release()
        #expect(await late.next() == .unprepared)
        #expect(await iterator.next() == .unprepared)
    }

    @Test("release drops the in-memory model and returns to unprepared")
    @MainActor
    func releaseReturnsToUnprepared() async throws {
        let engine = ImmediateVozEngine()
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)
        try await transcriber.prepare()
        #expect(transcriber.modelState == .ready)
        #expect(transcriber.downloadProgress == 1)

        transcriber.release()

        #expect(transcriber.modelState == .unprepared)
        #expect(transcriber.downloadProgress == 0)
        #expect(transcriber.isReady == false)
        await #expect(throws: VozError.notPrepared) {
            _ = try await transcriber.transcribeAudioFile(file: temporaryVozAudioFileURL())
        }

        await transcriber.waitForRelease()
        try await transcriber.prepare()
        #expect(transcriber.modelState == .ready)
        #expect(await engine.prepareCallCount() == 2)
    }

    @Test("a transcriber round trips through the SpeechService extension seam")
    @MainActor
    func speechServiceRoundTripsTheTranscriber() async throws {
        let service = SpeechService()
        #expect(service.voz == nil)
        #expect(service.vozModelState == .unprepared)
        #expect(service.vozModelDownloadProgress == 0)

        let transcriber = VozTranscriber(configuration: .init(), engine: ImmediateVozEngine())
        service.voz = transcriber
        #expect(service.voz === transcriber)
        #expect(service.vozModelState == .unprepared)

        try await service.prepareVozModel()
        #expect(service.vozModelState == .ready)
        #expect(service.vozModelDownloadProgress == 1)

        service.releaseVozModel()
        #expect(service.vozModelState == .unprepared)
        #expect(service.vozModelDownloadProgress == 0)

        service.voz = nil
        #expect(service.voz == nil)
        #expect(service.vozModelState == .unprepared)
        #expect(service.vozModelDownloadProgress == 0)
    }

    @Test("transcribeVozAudioFile throws notPrepared before the model is prepared")
    @MainActor
    func serviceTranscriptionThrowsBeforePreparation() async throws {
        let service = SpeechService()
        service.voz = VozTranscriber(configuration: .init(), engine: ImmediateVozEngine())
        let file = temporaryVozAudioFileURL()

        await #expect(throws: VozError.notPrepared) {
            _ = try await service.transcribeVozAudioFile(file: file)
        }

        try await service.prepareVozModel()
        _ = try await service.transcribeVozAudioFile(file: file)
        #expect(service.vozModelState == .ready)
    }

    @Test("a transcriber configured to prepare in the background starts when it is attached")
    @MainActor
    func attachingAPreparingTranscriberStartsPreparation() async throws {
        let engine = BlockingVozEngine()
        let transcriber = VozTranscriber(
            configuration: VozConfiguration(preparesInBackgroundOnConfiguration: true),
            engine: engine
        )
        #expect(transcriber.modelState == .unprepared)
        #expect(await engine.prepareCallCount() == 0)

        let service = SpeechService()
        service.voz = transcriber

        await engine.waitForPreparationStart()
        await engine.finishPreparation()
        try await transcriber.waitUntilReady()

        #expect(service.vozModelState == .ready)
        #expect(await engine.prepareCallCount() == 1)
    }

    @Test("a transcriber that does not opt in stays unprepared when it is attached")
    @MainActor
    func attachingAPlainTranscriberDoesNotPrepare() async {
        let engine = BlockingVozEngine()
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)

        let service = SpeechService()
        service.voz = transcriber
        await settleVozMainActor()

        #expect(service.vozModelState == .unprepared)
        #expect(await engine.prepareCallCount() == 0)
    }
}
#endif
