# ``SpeechKitVoz``

Add on-device speech-to-text to a SpeechKit app with the VOZ local model.

## Overview

SpeechKitVoz transcribes completed audio files on the device. It adds one
observable object, ``VozTranscriber``, which owns the VOZ model's download,
loading, and release lifecycle, plus an extension on SpeechKit's
`SpeechService` so an app that already holds a speech service can reach VOZ
through it.

VOZ needs no API key and sends no audio to a transcription API. It downloads a
roughly 467 MB Core ML model on first preparation unless the configured model
directory already contains the required files. SpeechKitVoz does not bundle
model files, and this repository does not commit them.

VOZ runs on iOS 18, macOS 15, and visionOS 2, and is unavailable on watchOS. It
handles imported files and recordings after capture ends; it does not provide
realtime transcription or microphone capture. Use SpeechKit's realtime providers
for that.

```swift
import SpeechKit
import SpeechKitVoz

let voz = VozTranscriber()
voz.prepareInBackground()

// Later, when the user has a recording:
try await voz.waitUntilReady()
let response = try await voz.transcribeAudioFile(file: recordingURL)
print(response.text)
```

## Topics

### Essentials

- <doc:VozLocalSpeech>
- ``VozTranscriber``
- ``VozConfiguration``

### Model lifecycle

- ``VozModelState``
- ``VozTranscriber/isModelCached()``
- ``VozTranscriber/downloadIfNeeded()``
- ``VozTranscriber/load()``
- ``VozTranscriber/prepare()``
- ``VozTranscriber/prepareInBackground()``
- ``VozTranscriber/waitUntilReady()``
- ``VozTranscriber/stateUpdates``
- ``VozTranscriber/release()``

### Transcription

- ``VozTranscriber/transcribeAudioFile(file:)``
- ``VozTranscriber/transcribeAudioFile(securityScopedURL:)``
- ``VozFileTranscriptionResponse``
- ``VozFileTranscriptionWord``

### SpeechService integration

- ``SpeechKit/SpeechService/voz``
- ``SpeechKit/SpeechService/vozModelState``
- ``SpeechKit/SpeechService/vozModelDownloadProgress``
- ``SpeechKit/SpeechService/prepareVozModel()``
- ``SpeechKit/SpeechService/prepareVozModelInBackground()``
- ``SpeechKit/SpeechService/releaseVozModel()``
- ``SpeechKit/SpeechService/transcribeVozAudioFile(file:)``
- ``SpeechKit/SpeechService/transcribeVozAudioFile(securityScopedURL:)``

### Errors

- ``VozError``
