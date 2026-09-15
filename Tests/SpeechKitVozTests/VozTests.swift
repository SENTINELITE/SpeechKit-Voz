import Foundation
import SpeechKit
import Testing
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import SpeechKitVoz

#if !os(watchOS)
@Suite("VOZ Local File Transcription")
struct VozTests {
    @Test("cached model verification is fast-path safe and rejects changed artifacts")
    @MainActor
    func cachedModelVerificationRequiresIntactManifestFiles() throws {
        #if canImport(CryptoKit)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voz-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let files: [(String, Data)] = [
            ("encoder.mlmodelc/model.mil", Data("encoder".utf8)),
            ("mel.mlmodelc/model.mil", Data("mel".utf8)),
            ("decoder.mlmodelc/model.mil", Data("decoder".utf8)),
            ("meta.json", Data("{}".utf8)),
            ("vocab.json", Data("{}".utf8)),
            ("embedding.f16", Data("embedding".utf8))
        ]
        for (path, data) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }

        let manifestDirectory = directory.appendingPathComponent(".dal-meta", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        let roots = [
            "encoder.mlmodelc/", "mel.mlmodelc/", "decoder.mlmodelc/",
            "meta.json", "vocab.json", "embedding.f16"
        ]
        var manifest = "DAL1\n" + roots.map { "R\t\($0)" }.joined(separator: "\n") + "\n"
        for (path, data) in files {
            let digest = CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            manifest += "F\t\(path)\t\(data.count)\t\(digest)\n"
        }
        try Data(manifest.utf8).write(to: manifestDirectory.appendingPathComponent("manifest"))

        #expect(VozCachedModel.isValid(at: directory))
        try Data("changed".utf8).write(to: directory.appendingPathComponent("meta.json"))
        #expect(!VozCachedModel.isValid(at: directory))
        #endif
    }

    @Test("the public configuration is constructible and carries its cache locations")
    @MainActor
    func publicConfigurationIsConstructible() {
        let modelDirectory = URL(fileURLWithPath: "/tmp/voz-model")
        let cacheDirectory = URL(fileURLWithPath: "/tmp/voz-cache")
        let configuration = VozConfiguration(
            modelDirectory: modelDirectory,
            cacheDirectory: cacheDirectory
        )
        let transcriber = VozTranscriber(configuration: configuration)

        #expect(configuration.modelDirectory == modelDirectory)
        #expect(configuration.cacheDirectory == cacheDirectory)
        #expect(configuration.preparesInBackgroundOnConfiguration == false)
        #expect(transcriber.configuration == configuration)
        #expect(transcriber.modelState == .unprepared)
        #expect(transcriber.isReady == false)
    }

    @Test("the service rejects VOZ file transcription when no transcriber is attached")
    @MainActor
    func serviceRejectsVozFileTranscriptionWhenItIsNotConfigured() async {
        let service = SpeechService()
        let file = temporaryVozAudioFileURL()

        await #expect(throws: VozError.notConfigured) {
            _ = try await service.transcribeVozAudioFile(file: file)
        }
        await #expect(throws: VozError.notConfigured) {
            try await service.prepareVozModel()
        }
    }

    @Test("the transcriber exposes an explicit unprepared lifecycle before preparation")
    @MainActor
    func transcriberStartsUnpreparedAndRejectsTranscription() async {
        let transcriber = VozTranscriber(
            configuration: .init(),
            engine: ImmediateVozEngine()
        )

        #expect(transcriber.modelState == .unprepared)
        #expect(transcriber.downloadProgress == 0)
        await #expect(throws: VozError.notPrepared) {
            _ = try await transcriber.transcribeAudioFile(file: temporaryVozAudioFileURL())
        }
    }

    @Test("concurrent preparation shares one engine operation and exposes progress")
    @MainActor
    func preparationCoalescesAndPublishesProgress() async throws {
        let engine = BlockingVozEngine()
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)

        let first = Task { try await transcriber.prepare() }
        await engine.waitForPreparationStart()
        await settleVozMainActor()

        #expect(transcriber.modelState == .downloading(progress: 0.35))
        #expect(transcriber.downloadProgress == 0.35)

        let second = Task { try await transcriber.prepare() }
        await settleVozMainActor()
        #expect(await engine.prepareCallCount() == 1)

        await engine.finishPreparation()
        try await first.value
        try await second.value

        #expect(transcriber.modelState == .ready)
        #expect(transcriber.isReady)
        #expect(transcriber.downloadProgress == 1)
        #expect(await engine.prepareCallCount() == 1)
    }

    @Test("cancelling the caller that began preparation does not cancel shared preparation")
    @MainActor
    func cancellingOriginatingPreparationCallerDoesNotPoisonSharedWaiter() async throws {
        let engine = BlockingVozEngine()
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)

        let originatingCaller = Task { try await transcriber.prepare() }
        await engine.waitForPreparationStart()
        let sharedCaller = Task { try await transcriber.prepare() }
        originatingCaller.cancel()

        await engine.finishPreparation()
        await #expect(throws: CancellationError.self) {
            try await originatingCaller.value
        }
        try await sharedCaller.value

        #expect(transcriber.modelState == .ready)
        #expect(await engine.prepareCallCount() == 1)
    }

    @Test("late preparation callbacks cannot regress a ready model")
    @MainActor
    func delayedPreparationCallbacksCannotRegressReadyState() async throws {
        let engine = BlockingVozEngine()
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)
        let preparation = Task { try await transcriber.prepare() }

        await engine.waitForPreparationStart()
        await engine.finishPreparation()
        try await preparation.value
        await engine.emit(.downloading(0.1))
        await engine.emit(.loading)
        await settleVozMainActor()

        #expect(transcriber.modelState == .ready)
        #expect(transcriber.downloadProgress == 1)
    }

    @Test("file transcriptions are serialized in request order")
    @MainActor
    func fileTranscriptionsAreSerialized() async throws {
        let engine = QueuedVozEngine()
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)
        try await transcriber.prepare()

        let first = Task { try await transcriber.transcribeAudioFile(file: temporaryVozAudioFileURL()) }
        await engine.waitForTranscriptionStart(1)
        let second = Task { try await transcriber.transcribeAudioFile(file: temporaryVozAudioFileURL()) }
        await settleVozMainActor()
        #expect(await engine.transcribeCallCount() == 1)

        await engine.finishNextTranscription()
        let firstResponse = try await first.value
        await engine.waitForTranscriptionStart(2)
        await engine.finishNextTranscription()
        let secondResponse = try await second.value

        #expect(firstResponse.text == "transcript 1")
        #expect(secondResponse.text == "transcript 2")
        #expect(await engine.transcribeCallCount() == 2)
    }

    @Test("release invalidates an in-flight transcription result")
    @MainActor
    func releaseInvalidatesInFlightTranscriptionResult() async throws {
        let engine = QueuedVozEngine()
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)
        try await transcriber.prepare()

        let transcription = Task { try await transcriber.transcribeAudioFile(file: temporaryVozAudioFileURL()) }
        await engine.waitForTranscriptionStart(1)
        transcriber.release()
        await engine.finishNextTranscription()

        await #expect(throws: VozError.releasedDuringTranscription) {
            _ = try await transcription.value
        }
        #expect(transcriber.modelState == .unprepared)
        #expect(transcriber.downloadProgress == 0)
    }

    @Test("preparation waits for prior model retirement after release")
    @MainActor
    func preparationWaitsForPriorModelRetirementAfterRelease() async throws {
        let engine = RetirementBlockingVozEngine()
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)
        try await transcriber.prepare()

        transcriber.release()
        await engine.waitForReleaseStart()
        let replacementPreparation = Task { try await transcriber.prepare() }
        await settleVozMainActor()
        #expect(await engine.prepareCallCount() == 1)

        await engine.finishRelease()
        try await replacementPreparation.value

        #expect(await engine.prepareCallCount() == 2)
        #expect(transcriber.modelState == .ready)
    }

    @Test("late download progress cannot regress model loading")
    @MainActor
    func delayedDownloadCallbacksCannotRegressLoadingState() async throws {
        let engine = BlockingVozEngine()
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)
        let preparation = Task { try await transcriber.prepare() }
        await engine.waitForPreparationStart()
        await engine.emit(.loading)
        await settleVozMainActor()
        await engine.emit(.downloading(0.9))
        await settleVozMainActor()

        #expect(transcriber.modelState == .loading)
        #expect(transcriber.downloadProgress == 1)
        await engine.finishPreparation()
        try await preparation.value
    }

    @Test("a failed preparation can be retried")
    @MainActor
    func failedPreparationCanBeRetried() async throws {
        let engine = ImmediateVozEngine(preparationOutcomes: [.failure, .success])
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)

        await #expect(throws: StubVozError.preparationFailed) {
            try await transcriber.prepare()
        }
        #expect(transcriber.modelState == .failed(message: StubVozError.preparationFailed.localizedDescription))
        #expect(transcriber.downloadProgress == 0.2)

        try await transcriber.prepare()

        #expect(transcriber.modelState == .ready)
        #expect(transcriber.downloadProgress == 1)
        #expect(await engine.prepareCallCount() == 2)
    }

    @Test("a delayed callback from a failed preparation cannot alter its retry")
    @MainActor
    func failedPreparationCallbackCannotAlterRetry() async throws {
        let engine = RetryCallbackVozEngine()
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)

        await #expect(throws: StubVozError.preparationFailed) {
            try await transcriber.prepare()
        }

        let retry = Task { try await transcriber.prepare() }
        await engine.waitForRetryStart()
        await settleVozMainActor()
        #expect(transcriber.modelState == .downloading(progress: 0.4))
        #expect(transcriber.downloadProgress == 0.4)

        await engine.emitDelayedFailedPreparationUpdate(.loading)
        await settleVozMainActor()
        #expect(transcriber.modelState == .downloading(progress: 0.4))
        #expect(transcriber.downloadProgress == 0.4)

        await engine.finishRetry()
        try await retry.value
        #expect(transcriber.modelState == .ready)
    }

    @Test("release clears state and rejects stale preparation updates")
    @MainActor
    func releaseClearsStateAndRejectsStalePreparationUpdates() async {
        let engine = BlockingVozEngine()
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)
        let preparation = Task { try await transcriber.prepare() }

        await engine.waitForPreparationStart()
        transcriber.release()
        await engine.emit(.downloading(0.9))
        await engine.finishPreparation()
        _ = await preparation.result
        await settleVozMainActor()

        #expect(transcriber.modelState == .unprepared)
        #expect(transcriber.downloadProgress == 0)
    }

    @Test("a prepared transcriber preserves VOZ text and word timestamps through the service")
    @MainActor
    func servicePreservesDetailedResponse() async throws {
        let response = VozFileTranscriptionResponse(
            text: "hello SpeechKit",
            words: [
                VozFileTranscriptionWord(text: "hello", startTime: 0.12, endTime: 0.41),
                VozFileTranscriptionWord(text: "SpeechKit", startTime: 0.52, endTime: 1.08)
            ],
            duration: 1.2,
            processingTime: 0.3
        )
        let engine = ImmediateVozEngine(response: response)
        let transcriber = VozTranscriber(configuration: .init(), engine: engine)
        try await transcriber.prepare()

        let service = SpeechService()
        service.voz = transcriber
        let file = temporaryVozAudioFileURL()

        let detailed = try await service.transcribeVozAudioFile(file: file)

        #expect(detailed == response)
        #expect(detailed.words.map(\.text) == ["hello", "SpeechKit"])
        #expect(detailed.words.map(\.startTime) == [0.12, 0.52])
        #expect(detailed.words.map(\.endTime) == [0.41, 1.08])
        #expect(detailed.realtimeFactor == 4)
        #expect(await engine.transcribeCallCount() == 1)
    }

    @Test("word timestamps convert to SpeechKit's provider-neutral transcript words")
    func responseConvertsToSpeechTranscriptWords() {
        let response = VozFileTranscriptionResponse(
            text: "hello SpeechKit",
            words: [
                VozFileTranscriptionWord(text: "hello", startTime: 0.12, endTime: 0.41),
                VozFileTranscriptionWord(text: "SpeechKit", startTime: 0.52, endTime: 1.08)
            ],
            duration: 1.2,
            processingTime: 0.3
        )

        let words: [SpeechTranscriptWord] = response.transcriptWords

        #expect(words.map(\.text) == ["hello", "SpeechKit"])
        #expect(words.map(\.start) == [0.12, 0.52])
        #expect(words.map(\.end) == [0.41, 1.08])
        #expect(words.allSatisfy { $0.speaker == nil })
        #expect(words.allSatisfy { $0.confidence == nil })
        #expect(VozFileTranscriptionResponse(text: "", words: [], duration: 0, processingTime: 0).realtimeFactor == 0)
    }

    @Test("changing the configuration releases visible model state")
    @MainActor
    func changingConfigurationReleasesVisibleModelState() async throws {
        let transcriber = VozTranscriber(
            configuration: .init(modelDirectory: URL(fileURLWithPath: "/tmp/voz-a")),
            engine: ImmediateVozEngine()
        )
        try await transcriber.prepare()
        #expect(transcriber.modelState == .ready)

        transcriber.configuration = VozConfiguration(modelDirectory: URL(fileURLWithPath: "/tmp/voz-b"))

        #expect(transcriber.modelState == .unprepared)
        #expect(transcriber.downloadProgress == 0)
        #expect(transcriber.configuration.modelDirectory == URL(fileURLWithPath: "/tmp/voz-b"))
    }

    @Test("assigning an equal configuration preserves a warmed model")
    @MainActor
    func assigningEqualConfigurationPreservesWarmedModel() async throws {
        let configuration = VozConfiguration(modelDirectory: URL(fileURLWithPath: "/tmp/voz"))
        let transcriber = VozTranscriber(configuration: configuration, engine: ImmediateVozEngine())
        try await transcriber.prepare()

        transcriber.configuration = configuration

        #expect(transcriber.modelState == .ready)
        #expect(transcriber.downloadProgress == 1)
    }

    @Test(
        "real VOZ model smoke test",
        .enabled(if: ProcessInfo.processInfo.environment["SPEECHKIT_VOZ_MODEL_SMOKE"] == "1")
    )
    @MainActor
    func realModelSmokeTest() async throws {
        let environment = ProcessInfo.processInfo.environment
        let audioPath = try #require(environment["SPEECHKIT_VOZ_AUDIO_FILE"])
        let audioFile = URL(fileURLWithPath: audioPath)
        #expect(FileManager.default.fileExists(atPath: audioFile.path))

        let configuration = VozConfiguration(
            modelDirectory: environment["SPEECHKIT_VOZ_MODEL_DIRECTORY"].map(URL.init(fileURLWithPath:)),
            cacheDirectory: environment["SPEECHKIT_VOZ_CACHE_DIRECTORY"].map(URL.init(fileURLWithPath:))
        )
        let service = SpeechService()
        service.voz = VozTranscriber(configuration: configuration)

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await service.prepareVozModel()
            let response = try await service.transcribeVozAudioFile(file: audioFile)
            #expect(!response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!response.words.isEmpty)
            #expect(response.duration >= 0)
            #expect(response.processingTime >= 0)
            #expect(response.realtimeFactor >= 0)
            print("VOZ smoke: text=\(response.text.debugDescription) words=\(response.words.count) duration=\(response.duration)s processing=\(response.processingTime)s rtf=\(response.realtimeFactor)")
        }

        print("VOZ smoke wall time: \(elapsed)")
    }
}
#endif
