#if !os(watchOS)
import Foundation
import SpeechKit

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@available(watchOS, unavailable)
extension SpeechServiceExtensionKey where Value == VozTranscriber {
    /// The key SpeechKitVoz uses to attach its transcriber to a `SpeechService`.
    static var vozTranscriber: SpeechServiceExtensionKey<VozTranscriber> {
        SpeechServiceExtensionKey("com.sentinelite.SpeechKitVoz.transcriber")
    }
}

/// VOZ local-model APIs on SpeechKit's speech service.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@available(watchOS, unavailable)
extension SpeechService {
    /// The VOZ transcriber attached to this service, if any.
    ///
    /// SpeechKitVoz stores the transcriber on the service through SpeechKit's
    /// extension-storage seam, so a SwiftUI view that already holds a
    /// `SpeechService` can reach VOZ without a second object.
    ///
    /// Assigning a transcriber whose
    /// ``VozConfiguration/preparesInBackgroundOnConfiguration`` is `true` starts
    /// ``VozTranscriber/prepareInBackground()`` immediately.
    ///
    /// ```swift
    /// speech.voz = VozTranscriber(
    ///     configuration: VozConfiguration(preparesInBackgroundOnConfiguration: true)
    /// )
    /// ```
    public var voz: VozTranscriber? {
        get { self[extension: .vozTranscriber] }
        set {
            self[extension: .vozTranscriber] = newValue
            if let newValue, newValue.configuration.preparesInBackgroundOnConfiguration {
                newValue.prepareInBackground()
            }
        }
    }

    /// The current lifecycle state of the attached VOZ model.
    ///
    /// This is ``VozModelState/unprepared`` when no transcriber is attached.
    public var vozModelState: VozModelState {
        voz?.modelState ?? .unprepared
    }

    /// The current VOZ model-download progress, from `0` through `1`.
    ///
    /// This is `0` when no transcriber is attached.
    public var vozModelDownloadProgress: Double {
        voz?.downloadProgress ?? 0
    }

    /// Downloads, if needed, and loads the attached VOZ model.
    ///
    /// - Throws: ``VozError/notConfigured`` when no transcriber is attached, or
    ///   an error from the VOZ model lifecycle.
    public func prepareVozModel() async throws {
        guard let voz else {
            throw VozError.notConfigured
        }
        try await voz.prepare()
    }

    /// Starts VOZ model preparation without waiting for it.
    ///
    /// Failures land in ``vozModelState``. This does nothing when no transcriber
    /// is attached.
    public func prepareVozModelInBackground() {
        voz?.prepareInBackground()
    }

    /// Releases the in-memory VOZ model, keeping its cached files on disk.
    public func releaseVozModel() {
        voz?.release()
    }

    /// Transcribes a local audio file with the prepared VOZ model.
    ///
    /// - Parameter file: A readable local audio-file URL.
    /// - Returns: The transcript, word timestamps, and processing metrics.
    /// - Throws: ``VozError/notConfigured`` when no transcriber is attached, or
    ///   ``VozError/notPrepared`` when the model has not been prepared.
    public func transcribeVozAudioFile(
        file: URL
    ) async throws -> VozFileTranscriptionResponse {
        guard let voz else {
            throw VozError.notConfigured
        }
        return try await voz.transcribeAudioFile(file: file)
    }

    /// Transcribes a security-scoped local audio file with the prepared VOZ model.
    ///
    /// - Parameter securityScopedURL: A security-scoped file URL from an open
    ///   panel, document picker, or drag-and-drop handoff.
    /// - Returns: The transcript, word timestamps, and processing metrics.
    public func transcribeVozAudioFile(
        securityScopedURL: URL
    ) async throws -> VozFileTranscriptionResponse {
        guard let voz else {
            throw VozError.notConfigured
        }
        return try await voz.transcribeAudioFile(securityScopedURL: securityScopedURL)
    }
}
#endif
