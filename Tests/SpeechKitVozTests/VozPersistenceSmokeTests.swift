#if !os(watchOS)
import Foundation
import SpeechKit
import Testing
@testable import SpeechKitVoz

/// Opt-in tests that use the real downloaded model. They are skipped unless
/// `SPEECHKIT_VOZ_MODEL_SMOKE=1` is set, so the normal suite never touches the
/// network or a multi-hundred-megabyte cache.
@Suite("VOZ Real Model Persistence Smoke", .serialized)
struct VozPersistenceSmokeTests {
    @Test(
        "one prepared transcriber completes repeated transcriptions",
        .enabled(if: ProcessInfo.processInfo.environment["SPEECHKIT_VOZ_MODEL_SMOKE"] == "1")
    )
    @MainActor
    func repeatedTranscriptionsRemainUsable() async throws {
        let input = try realVozSmokeInput()
        let service = SpeechService()
        service.voz = VozTranscriber(configuration: input.configuration)

        try await service.prepareVozModel()
        let first = try await service.transcribeVozAudioFile(file: input.audioFile)
        let second = try await service.transcribeVozAudioFile(file: input.audioFile)

        expectUsableResponse(first)
        expectUsableResponse(second)
        #expect(second.text == first.text)
        #expect(second.words == first.words)
    }

    @Test(
        "a new transcriber reloads the model from the existing cache",
        .enabled(if: ProcessInfo.processInfo.environment["SPEECHKIT_VOZ_MODEL_SMOKE"] == "1")
    )
    @MainActor
    func newTranscriberReloadsFromCache() async throws {
        let input = try realVozSmokeInput()
        let firstService = SpeechService()
        firstService.voz = VozTranscriber(configuration: input.configuration)

        try await firstService.prepareVozModel()
        let first = try await firstService.transcribeVozAudioFile(file: input.audioFile)
        expectUsableResponse(first)

        firstService.releaseVozModel()
        #expect(firstService.vozModelState == .unprepared)
        #expect(FileManager.default.fileExists(atPath: input.configuration.cacheDirectory!.path))

        // A fresh transcriber forces a new model lifecycle. Preparation must find
        // the model artifacts left in the cache.
        let reloadedService = SpeechService()
        let reloadedTranscriber = VozTranscriber(configuration: input.configuration)
        reloadedService.voz = reloadedTranscriber
        #expect(reloadedTranscriber.isModelCached())

        try await reloadedService.prepareVozModel()
        let reloaded = try await reloadedService.transcribeVozAudioFile(file: input.audioFile)

        expectUsableResponse(reloaded)
        #expect(reloaded.text == first.text)
        #expect(reloaded.words == first.words)
    }

    @MainActor
    private func expectUsableResponse(_ response: VozFileTranscriptionResponse) {
        #expect(!response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!response.words.isEmpty)
        #expect(response.duration > 0)
        #expect(response.processingTime > 0)
        #expect(response.realtimeFactor > 0)
    }
}

private struct VozRealSmokeInput {
    let audioFile: URL
    let configuration: VozConfiguration
}

private func realVozSmokeInput() throws -> VozRealSmokeInput {
    let environment = ProcessInfo.processInfo.environment
    let audioPath = environment["SPEECHKIT_VOZ_AUDIO_FILE"] ?? "/tmp/speechkit-voz-sample.aiff"
    let audioFile = URL(fileURLWithPath: audioPath)
    guard FileManager.default.fileExists(atPath: audioFile.path) else {
        throw VozPersistenceSmokeError.missingAudio(audioFile.path)
    }

    let cachePath = environment["SPEECHKIT_VOZ_CACHE_DIRECTORY"] ?? "/tmp/SpeechKitVozModelCache"
    let cacheDirectory = URL(fileURLWithPath: cachePath)
    guard FileManager.default.fileExists(atPath: cacheDirectory.path) else {
        throw VozPersistenceSmokeError.missingCache(cacheDirectory.path)
    }

    return VozRealSmokeInput(
        audioFile: audioFile,
        configuration: VozConfiguration(
            modelDirectory: environment["SPEECHKIT_VOZ_MODEL_DIRECTORY"].map(URL.init(fileURLWithPath:)),
            cacheDirectory: cacheDirectory
        )
    )
}

private enum VozPersistenceSmokeError: LocalizedError {
    case missingAudio(String)
    case missingCache(String)

    var errorDescription: String? {
        switch self {
        case .missingAudio(let path):
            return "VOZ smoke audio file does not exist: \(path)"
        case .missingCache(let path):
            return "VOZ smoke cache directory does not exist: \(path)"
        }
    }
}
#endif
