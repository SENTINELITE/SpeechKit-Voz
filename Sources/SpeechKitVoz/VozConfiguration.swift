#if !os(watchOS)
import Foundation

/// Controls where VOZ reads and stores its on-device speech-recognition model.
///
/// Leave both locations unset to use the VOZ managed cache. Model files are not
/// bundled with SpeechKitVoz; the first preparation downloads roughly 467 MB.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@available(watchOS, unavailable)
public struct VozConfiguration: Sendable, Hashable {
    /// A directory containing model files managed by the app, if any.
    public var modelDirectory: URL?
    /// The root directory used by VOZ's managed model cache, if any.
    public var cacheDirectory: URL?
    /// A Boolean value indicating whether assigning this transcriber to a
    /// `SpeechService` starts preparation immediately.
    ///
    /// When this is `true`, `SpeechService.voz = transcriber` calls
    /// ``VozTranscriber/prepareInBackground()``. Assigning a
    /// ``VozTranscriber`` directly, or creating one, never starts preparation on
    /// its own.
    public var preparesInBackgroundOnConfiguration: Bool

    /// Creates a configuration for the VOZ local model.
    ///
    /// - Parameters:
    ///   - modelDirectory: A directory of model files the app manages, or `nil`
    ///     to let VOZ resolve one.
    ///   - cacheDirectory: The root of VOZ's managed cache, or `nil` for the
    ///     platform default cache.
    ///   - preparesInBackgroundOnConfiguration: Whether assigning the
    ///     transcriber to a `SpeechService` starts preparation.
    public init(
        modelDirectory: URL? = nil,
        cacheDirectory: URL? = nil,
        preparesInBackgroundOnConfiguration: Bool = false
    ) {
        self.modelDirectory = modelDirectory
        self.cacheDirectory = cacheDirectory
        self.preparesInBackgroundOnConfiguration = preparesInBackgroundOnConfiguration
    }
}
#endif
