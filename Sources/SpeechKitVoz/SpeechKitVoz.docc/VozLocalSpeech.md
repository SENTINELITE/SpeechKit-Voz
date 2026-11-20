# VOZ local speech

Transcribe completed audio files on the device with VOZ.

## Overview

SpeechKitVoz exposes VOZ on iOS 18, macOS 15, and visionOS 2. It is unavailable
on watchOS. VOZ handles imported files and recordings after capture ends. It
does not provide realtime transcription or microphone capture.

VOZ needs no API key. It downloads a roughly 337 MB Core ML model during
preparation unless the configured model directory already contains the required
files. SpeechKitVoz does not bundle model files, and this repository does not
commit them.

Create a ``VozTranscriber`` and keep one for the app, or for the feature that
imports and records audio:

```swift
let voz = VozTranscriber()
```

Use ``VozConfiguration/modelDirectory`` when your app supplies and manages the
model files. Use ``VozConfiguration/cacheDirectory`` to choose the root of VOZ's
managed cache. Leave both unset for the managed default.

```swift
let voz = VozTranscriber(
    configuration: VozConfiguration(
        modelDirectory: appManagedModelDirectory,
        cacheDirectory: applicationSupportDirectory
    )
)
```

## Prepare the model

Preparation resolves and verifies model files, downloads missing files, loads
the model, and completes one-time Neural Engine specialization. It stays a
separate step from transcription so your app can show progress for it.

Start it at launch and let it run while the user does something else:

```swift
voz.prepareInBackground()
```

``VozTranscriber/prepareInBackground()`` is idempotent while a preparation is in
flight, and records failures in ``VozTranscriber/modelState`` instead of
throwing. Immediately before the first transcription, call
``VozTranscriber/waitUntilReady()``; it resolves when an in-flight preparation
finishes, and starts one if none is running.

Split the two costs when you want an explicit onboarding download step.
``VozTranscriber/isModelCached()`` answers whether the files are already on disk,
``VozTranscriber/downloadIfNeeded()`` fetches them without loading the model, and
``VozTranscriber/load()`` pays the per-launch loading cost:

```swift
if !voz.isModelCached() {
    // Show a "download the speech model" prompt, then:
    try await voz.downloadIfNeeded()
}
try await voz.load()
```

``VozTranscriber/isModelCached()`` re-hashes the cached files against the
manifest recorded at download time, so it is far cheaper than loading the model
but it is not instant. It is `nonisolated`, so you can run it off the main actor.

Observe ``VozTranscriber/modelState`` from SwiftUI, or iterate
``VozTranscriber/stateUpdates`` from your own model layer, to drive setup UI:

| State | Meaning |
| --- | --- |
| ``VozModelState/unprepared`` | No model is resident in memory. |
| ``VozModelState/checkingCache`` | SpeechKitVoz is verifying saved model files before deciding whether a download is needed. |
| ``VozModelState/downloading(progress:)`` | Model files are downloading. Read ``VozTranscriber/downloadProgress`` for a value from `0` through `1`. |
| ``VozModelState/loading`` | VOZ is loading and specializing the model. |
| ``VozModelState/ready`` | Transcription can begin. |
| ``VozModelState/failed(message:)`` | Download or loading failed. Show the message and let the user retry. |

Concurrent calls to ``VozTranscriber/prepare()`` share one operation. Cancelling
one caller does not stop that shared work. Call ``VozTranscriber/release()`` when
the feature must discard the current lifecycle.

## Use it through SpeechService

An app that already has a SpeechKit `SpeechService` can attach the transcriber to
it and keep one object in its environment. SpeechKitVoz stores the transcriber
through SpeechKit's `SpeechServiceExtensionKey` seam.

```swift
let speech = SpeechService()
speech.voz = VozTranscriber(
    configuration: VozConfiguration(preparesInBackgroundOnConfiguration: true)
)

// Later:
let response = try await speech.transcribeVozAudioFile(file: audioFileURL)
```

Setting ``SpeechKit/SpeechService/voz`` to a transcriber whose configuration has
``VozConfiguration/preparesInBackgroundOnConfiguration`` set to `true` starts
``VozTranscriber/prepareInBackground()`` immediately. Leave it `false` to keep
preparation entirely under your control.

## Transcribe an audio file

The VOZ API returns text, word timestamps, audio duration, processing time, and
a realtime factor.

```swift
let response = try await voz.transcribeAudioFile(file: audioFileURL)

print(response.text)
print(response.words)
print(response.duration)
print(response.processingTime)
print(response.realtimeFactor)
```

``VozFileTranscriptionWord`` timestamps are in seconds on the audio timeline. The
model reports timestamps at about 80 ms resolution. Use
``VozFileTranscriptionResponse/transcriptWords`` to hand the result to code that
already consumes SpeechKit's `SpeechTranscriptWord`.

Use the security-scoped overload for a URL obtained from a document picker, open
panel, or drag and drop:

```swift
let response = try await voz.transcribeAudioFile(
    securityScopedURL: pickedAudioURL
)
```

Transcription never prepares the model for you. It throws
``VozError/notPrepared`` when the model is not ready, because a first
preparation can take minutes and belongs in UI you control.

The audio URL must be readable by `AVAudioFile`. VOZ decodes, downmixes, and
resamples the file incrementally before local inference, so SpeechKitVoz does not
retain a full decoded PCM recording in memory.

## Model storage and caching

Restarting the app clears the in-memory model, not its downloaded files. Call
``VozTranscriber/load()`` or ``VozTranscriber/prepare()`` again to reopen them.
Cached files are verified with streaming CryptoKit SHA-256 checks before loading.

The default cache can be purged by the operating system. Use an app-managed
Application Support location through ``VozConfiguration/cacheDirectory`` when
files must remain until the app removes them.

## Release and cancellation

Call ``VozTranscriber/release()`` to cancel queued preparation, mark the model
``VozModelState/unprepared``, and schedule its in-memory resources for release.
Cached model files stay on disk and are reused by a later preparation. VOZ
inference is noninterruptible while it is running, so SpeechKitVoz waits for
retiring work before starting a new model lifecycle.

If you release the model while a transcription is running, SpeechKitVoz rejects
the stale result with ``VozError/releasedDuringTranscription``. Cancelling the
task that calls transcription is checked before and after local inference. The
recognizer runs synchronously while it is active, so cancellation does not
guarantee that inference stops at once.

Assigning a different ``VozTranscriber/configuration`` has the same effect as
``VozTranscriber/release()``, then uses the new locations on the next
preparation.

## Network, platform, and language limits

SpeechKitVoz does not send selected or recorded audio to a transcription API. A
managed model download uses the network and fetches the pinned `v0.5.0` model
from [Hugging Face](https://huggingface.co/desert-ant-labs/voz). The VOZ runtime
may also send the license's minimal device-counting telemetry. The license says
this telemetry excludes inputs, outputs, and user content. Once model files are
present, transcription runs locally.

VOZ is Apple-only because it uses Core ML. SpeechKitVoz exposes it on iOS 18,
macOS 15, and visionOS 2. There is no watchOS, Android, Linux, or web VOZ
integration. The package still declares watchOS 11 so a multi-platform app can
depend on it from every target; the VOZ API is simply absent there.

The model covers 25 languages and does not detect which one is being spoken.
Audio in an unsupported language can produce a confident but incorrect
transcript. Check the [VOZ model card](https://huggingface.co/desert-ant-labs/voz)
before making accuracy claims for a language or recording type.

## License

SpeechKitVoz source is available under Apache 2.0. VOZ is different. The pinned
[`desert-ant-core` 4.3.0 source](https://github.com/Desert-Ant-Labs/desert-ant-core/tree/v4.3.0/Sources/Voz)
and the [`desert-ant-labs/voz` model](https://huggingface.co/desert-ant-labs/voz)
use the [Desert Ant Labs Source-Available License 1.0](https://license.desertant.com/1.0).
The terms are free below 100,000 monthly active devices per platform for each
model. A commercial license is required above that threshold. Distributed apps
must show a user-visible "Powered by Desert Ant Labs" credit, linked to
[desertant.com](https://desertant.com) where links are supported. The terms
forbid training a competing on-device model with VOZ, its outputs, or its logs,
and forbid standalone redistribution of the VOZ runtime or model. Read the full
terms before distribution.
