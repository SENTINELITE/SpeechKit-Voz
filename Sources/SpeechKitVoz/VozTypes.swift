#if !os(watchOS)
import Foundation
import SpeechKit

/// The lifecycle of the in-memory VOZ model managed by a ``VozTranscriber``.
///
/// The state describes the model that is resident in memory, not the files on
/// disk. Use ``VozTranscriber/isModelCached()`` to ask whether the download has
/// already happened.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@available(watchOS, unavailable)
public enum VozModelState: Sendable, Equatable {
    /// No model is resident in memory.
    case unprepared
    /// Checking whether a complete verified model is already cached on disk.
    case checkingCache
    /// The model files are being downloaded. The associated value is `0...1`.
    case downloading(progress: Double)
    /// The downloaded model is being loaded and specialized for the Neural Engine.
    case loading
    /// The model is resident and ready to transcribe.
    case ready
    /// Download or loading failed. The associated value is a user-presentable message.
    case failed(message: String)
}

/// A word recognized by VOZ, including its audio-time range in seconds.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@available(watchOS, unavailable)
public struct VozFileTranscriptionWord: Sendable, Equatable, Hashable {
    /// The recognized word.
    public let text: String
    /// The audio-time position at which the word starts.
    public let startTime: TimeInterval
    /// The audio-time position at which the word ends.
    public let endTime: TimeInterval

    /// Creates a recognized word with its audio-time range.
    public init(text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// The detailed result of transcribing a completed audio recording with VOZ.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
@available(watchOS, unavailable)
public struct VozFileTranscriptionResponse: Sendable, Equatable {
    /// The complete transcript.
    public let text: String
    /// Recognized words in audio-time order.
    public let words: [VozFileTranscriptionWord]
    /// Audio duration in seconds.
    public let duration: TimeInterval
    /// Wall-clock time the recognizer spent transcribing.
    public let processingTime: TimeInterval

    /// Seconds of audio transcribed per second of wall-clock processing time.
    public var realtimeFactor: Double {
        processingTime > 0 ? duration / processingTime : 0
    }

    /// ``words`` converted to SpeechKit's provider-neutral word type.
    ///
    /// Use this to feed VOZ results into code that already consumes
    /// `SpeechTranscriptWord` from another provider. VOZ reports no
    /// speaker label or confidence, so those values are `nil`.
    ///
    /// Each call mints new `SpeechTranscriptWord` identities. Store the result
    /// once instead of recomputing it inside a SwiftUI `ForEach`.
    public var transcriptWords: [SpeechTranscriptWord] {
        words.map {
            SpeechTranscriptWord(
                text: $0.text,
                start: $0.startTime,
                end: $0.endTime
            )
        }
    }

    /// Creates a detailed VOZ file transcription result.
    public init(
        text: String,
        words: [VozFileTranscriptionWord],
        duration: TimeInterval,
        processingTime: TimeInterval
    ) {
        self.text = text
        self.words = words
        self.duration = duration
        self.processingTime = processingTime
    }
}
#endif
