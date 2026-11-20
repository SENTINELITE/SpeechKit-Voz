# Changelog

All notable changes to SpeechKit-Voz will be documented in this file.

SpeechKit-Voz follows semantic versioning. Source-breaking changes ship in a new major version.

## [1.1.0] - 2026-11-20

- Supports SpeechKit 2.x and 3.x.
- Pins Desert Ant Core 4.3.0, which downloads the tagged VOZ v0.5.0 Core ML
  model on Apple platforms. The managed model download is about 337 MB.
- Exposes the model revision and approximate download size through
  `VozModelDetails` for apps and command-line tools.

## [1.0.0] - 2026-09-15

Requires SpeechKit 2.0.0 or later.

### Added

- `VozTranscriber`, an observable main-actor object that owns the VOZ on-device model lifecycle for file transcription on iOS 18, macOS 15, and visionOS 2.
- Explicit lifecycle hooks: `isModelCached()`, `downloadIfNeeded()`, `load()`, `prepare()`, `prepareInBackground()`, `waitUntilReady()`, `release()`, and a multi-consumer `stateUpdates` stream that yields the current state before subsequent changes.
- `VozConfiguration` with `modelDirectory`, `cacheDirectory`, and `preparesInBackgroundOnConfiguration`.
- `VozModelState`, `VozFileTranscriptionResponse`, and `VozFileTranscriptionWord`, plus `VozFileTranscriptionResponse.transcriptWords` for interoperating with SpeechKit's `SpeechTranscriptWord`.
- `VozError` for every failure this package raises, including the OS/platform, configuration, preparation, download, load, and inference cases.
- `SpeechService.voz` and companion APIs (`vozModelState`, `vozModelDownloadProgress`, `prepareVozModel()`, `prepareVozModelInBackground()`, `releaseVozModel()`, `transcribeVozAudioFile(file:)`, `transcribeVozAudioFile(securityScopedURL:)`), stored through SpeechKit's `SpeechServiceExtensionKey` seam so SpeechKit keeps no VOZ dependency.
- DocC catalog with a VOZ local speech article covering preparation, transcription, caching, privacy, and licensing.

### License

- The VOZ runtime and its model use the Desert Ant Labs Source-Available License 1.0, not this package's Apache 2.0 license. It requires user-visible attribution and limits standalone redistribution. See [NOTICE.md](NOTICE.md) before distributing an app that links this package.
