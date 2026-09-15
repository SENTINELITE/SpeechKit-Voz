#if !os(watchOS)
import Foundation

/// Errors raised by the VOZ model lifecycle and local transcription.
///
/// SpeechKitVoz cannot add cases to SpeechKit's `SpeechError`, so every failure
/// this package raises is a `VozError`.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@available(watchOS, unavailable)
public enum VozError: Error, LocalizedError, Sendable, Equatable {
    /// VOZ cannot run on this OS or platform.
    ///
    /// VOZ is Core ML only. It runs on iOS 18, macOS 15, and visionOS 2, and is
    /// unavailable on watchOS.
    case unavailable
    /// No ``VozTranscriber`` is attached to the `SpeechService`.
    case notConfigured
    /// Transcription was requested before the model was prepared.
    case notPrepared
    /// The model was released while a transcription was in flight.
    case releasedDuringTranscription
    /// Fetching the model files failed. The associated value is a user-presentable message.
    case downloadFailed(String)
    /// Loading the downloaded model failed. The associated value is a user-presentable message.
    case loadFailed(String)
    /// Local inference failed. The associated value is a user-presentable message.
    case transcriptionFailed(String)

    /// A localized description of the error.
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "VOZ local transcription requires iOS 18, macOS 15, or visionOS 2."
        case .notConfigured:
            return "Assign a VozTranscriber to the speech service before using VOZ."
        case .notPrepared:
            return "Prepare the VOZ model before transcribing audio."
        case .releasedDuringTranscription:
            return "The VOZ model was released before transcription completed."
        case .downloadFailed(let message):
            return "Downloading the VOZ model failed: \(message)"
        case .loadFailed(let message):
            return "Loading the VOZ model failed: \(message)"
        case .transcriptionFailed(let message):
            return "VOZ transcription failed: \(message)"
        }
    }
}
#endif
