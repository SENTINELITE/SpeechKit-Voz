# SpeechKit-Voz

[![CI](https://github.com/SENTINELITE/SpeechKit-Voz/actions/workflows/ci.yml/badge.svg)](https://github.com/SENTINELITE/SpeechKit-Voz/actions/workflows/ci.yml)
![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platforms](https://img.shields.io/badge/platforms-iOS%2018%20%7C%20macOS%2015%20%7C%20visionOS%202-lightgrey.svg)

SpeechKit-Voz adds on-device file transcription to [SpeechKit](https://github.com/SENTINELITE/SpeechKit) using the VOZ local speech model. It is a separate, opt-in package: apps that do not want a several-hundred-megabyte model or a source-available dependency never link it.

It transcribes completed audio: imported files and recordings after capture ends. It does not provide realtime transcription or microphone capture. Use SpeechKit's realtime providers for that.

## Highlights

- One observable `VozTranscriber` that owns the model's download, loading, and release lifecycle.
- No API key, and no audio sent to a transcription API.
- Explicit launch-time preparation hooks: `isModelCached()`, `downloadIfNeeded()`, `load()`, `prepareInBackground()`, `waitUntilReady()`, and a `stateUpdates` stream.
- Word-level timestamps, audio duration, processing time, and a realtime factor, convertible to SpeechKit's provider-neutral `SpeechTranscriptWord`.
- An extension on SpeechKit's `SpeechService` so an app that already holds a speech service can reach VOZ through it.

## Requirements

- Swift 6.2+
- iOS 18+
- macOS 15+
- visionOS 2+
- SpeechKit

VOZ is unavailable on watchOS because it runs on Core ML. The package still declares watchOS 11 so a multi-platform app can depend on it from every target; the VOZ API is simply absent there.

The model is not bundled with the package and is not committed to this repository. The first preparation downloads roughly 467 MB.

## Platform Support

| Platform | Minimum version | VOZ |
| --- | ---: | --- |
| iOS | 18.0 | Available |
| macOS | 15.0 | Available |
| visionOS | 2.0 | Available |
| watchOS | 11.0 | Unavailable; the package builds with VOZ compiled out |

## Installation

Add SpeechKit-Voz as a Swift Package dependency in Xcode:

1. Open your app project.
2. Select `File > Add Package Dependencies...`.
3. Enter `https://github.com/SENTINELITE/SpeechKit-Voz.git`.
4. Add the `SpeechKitVoz` library to your app target.

SpeechKit comes along as a transitive dependency. Add the `SpeechKit` library to your target as well if you use the rest of its API.

## Prepare the model

Preparation resolves and verifies model files, downloads missing files, loads the model, and completes one-time Neural Engine specialization. It is an explicit step, separate from transcription, so your app can show progress for it.

Start it at app launch and let it run while the user does something else:

```swift
import SpeechKitVoz

@main
struct DemoApp: App {
    @State private var voz = VozTranscriber()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(voz)
                .task { voz.prepareInBackground() }
        }
    }
}
```

`prepareInBackground()` is safe to call more than once: while a preparation is in flight it returns the task already running. A failure lands in `modelState` as `.failed(message:)` instead of throwing.

Use `isModelCached()` to decide whether to show a download prompt. It is synchronous and does not load the model, and it is `nonisolated`, so you can run it off the main actor:

```swift
let cached = await Task.detached { voz.isModelCached() }.value
if !cached {
    // Ask first: this is a ~467 MB download.
    try await voz.downloadIfNeeded()
}
try await voz.load()
```

`downloadIfNeeded()` fetches the files without loading them, and `load()` pays the per-launch loading cost. `prepare()` does both.

Drive setup UI from `modelState`, or from the `stateUpdates` stream in your own model layer:

```swift
struct ModelSetupView: View {
    @Environment(VozTranscriber.self) private var voz

    var body: some View {
        switch voz.modelState {
        case .unprepared:
            Button("Download speech model") { voz.prepareInBackground() }
        case .checkingCache:
            ProgressView("Checking saved model files")
        case .downloading(let progress):
            ProgressView("Downloading", value: progress)
        case .loading:
            ProgressView("Preparing the model")
        case .ready:
            RecordingView()
        case .failed(let message):
            RetryView(message: message) { voz.prepareInBackground() }
        }
    }
}
```

Call `waitUntilReady()` immediately before the first transcription. It resolves when an in-flight preparation finishes, and starts one if none is running:

```swift
try await voz.waitUntilReady()
let response = try await voz.transcribeAudioFile(file: recordingURL)
```

## Use it through SpeechService

An app that already keeps a SpeechKit `SpeechService` can attach the transcriber to it and hold one object:

```swift
import SpeechKit
import SpeechKitVoz

let speech = SpeechService()
speech.voz = VozTranscriber(
    configuration: VozConfiguration(preparesInBackgroundOnConfiguration: true)
)
```

Assigning a transcriber whose configuration has `preparesInBackgroundOnConfiguration` set to `true` starts `prepareInBackground()` immediately. Leave it `false` to keep preparation entirely under your control.

The service then exposes `voz`, `vozModelState`, `vozModelDownloadProgress`, `prepareVozModel()`, `prepareVozModelInBackground()`, `releaseVozModel()`, `transcribeVozAudioFile(file:)`, and `transcribeVozAudioFile(securityScopedURL:)`. They are stored through SpeechKit's `SpeechServiceExtensionKey` seam, so SpeechKit itself has no VOZ dependency.

## Transcribe a file

```swift
let response = try await voz.transcribeAudioFile(file: audioFileURL)

print(response.text)
print(response.words)
print(response.duration)
print(response.processingTime)
print(response.realtimeFactor)
```

`VozFileTranscriptionWord` timestamps are in seconds on the audio timeline. The model reports timestamps at about 80 ms resolution. Use `response.transcriptWords` to hand the result to code that already consumes SpeechKit's `SpeechTranscriptWord`.

If your app receives a security-scoped file URL from a document picker, use the matching overload:

```swift
let response = try await voz.transcribeAudioFile(
    securityScopedURL: pickedAudioURL
)
```

Transcription never prepares the model for you. It throws `VozError.notPrepared` when the model is not ready, because a first preparation can take minutes and belongs in UI you control.

The audio URL must be readable by `AVAudioFile`. VOZ decodes, downmixes, and resamples the file incrementally before local inference, so SpeechKit-Voz does not retain a full decoded PCM recording in memory.

## Errors

The package throws `VozError`:

| Case | When |
| --- | --- |
| `.unavailable` | VOZ cannot run on this OS or platform. |
| `.notConfigured` | No transcriber is attached to the `SpeechService`. |
| `.notPrepared` | Transcription was requested before preparation. |
| `.releasedDuringTranscription` | `release()` discarded a transcription that was in flight. |
| `.downloadFailed(_:)` | Fetching the model files failed. |
| `.loadFailed(_:)` | Loading the downloaded model failed. |
| `.transcriptionFailed(_:)` | Local inference failed. |

A failed download or load also appears as `.failed(message:)` in `modelState`.

## Model storage and caching

Restarting the app clears the in-memory model, not its downloaded files. Call `load()` or `prepare()` again to reopen them. Cached files are verified with streaming CryptoKit SHA-256 checks before loading.

The default cache can be purged by the operating system. Use an app-managed Application Support location when the files must remain until your app removes them:

```swift
let voz = VozTranscriber(
    configuration: VozConfiguration(
        modelDirectory: appManagedModelDirectory,
        cacheDirectory: applicationSupportDirectory
    )
)
```

Use `modelDirectory` when your app supplies and manages the model files. Use `cacheDirectory` to choose the root of VOZ's managed cache. Leave both unset for the managed default.

Call `release()` to drop the in-memory model while keeping its cached files. Assigning a different `configuration` does the same and then uses the new locations on the next preparation.

## Privacy and network

SpeechKit-Voz does not send selected or recorded audio to a transcription API. A managed model download uses the network and fetches the pinned `v0.1.0` model from [Hugging Face](https://huggingface.co/desert-ant-labs/voz). The VOZ runtime may also send the license's minimal device-counting telemetry, which the license says excludes inputs, outputs, and user content. Once model files are present, transcription runs locally.

The model covers 25 languages and does not detect which one is being spoken. Audio in an unsupported language can produce a confident but incorrect transcript. Check the [VOZ model card](https://huggingface.co/desert-ant-labs/voz) before making accuracy claims for a language or recording type.

## Documentation

Open the package in Xcode and choose `Product > Build Documentation` to view the DocC reference.

## License

SpeechKit-Voz is available under the Apache License 2.0. See [LICENSE](LICENSE) for details.

The VOZ runtime and model are **not** Apache 2.0. `desert-ant-core` and the `desert-ant-labs/voz` model use the Desert Ant Labs Source-Available License 1.0, which adds attribution, device-count, redistribution, and model-training obligations to any app that ships this package. See [NOTICE.md](NOTICE.md) and read the full terms before distributing.
