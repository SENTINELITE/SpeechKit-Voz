# VOZ validation

## Scope

SpeechKit-Voz packages the VOZ on-device recognizer that was first prototyped on
SpeechKit's `codex/voz-integration` branch. The first version supports imported
files and recording followed by transcription. It does not add a realtime
provider.

Two parts of this record have different evidence behind them:

- **Package validation** is what this repository's own checks cover, and is
  reproducible from a clean checkout.
- **Real-model results** were measured on the SpeechKit branch that this package
  was extracted from, against the same pinned SDK and model. They are carried
  over here because the inference path is unchanged, not because they were
  re-measured against this package.

## Pinned versions

- Desert Ant `desert-ant-core` 3.1.0, revision `9e11fdf9566df2e34b9516ac76403b1ff0f839d8`.
- Model `desert-ant-labs/voz`, revision `v0.1.0`.

## Package validation

| Check | Command |
| --- | --- |
| SwiftPM build | `swift build -Xswiftc -warnings-as-errors` |
| Regression suite | `swift test -Xswiftc -warnings-as-errors` |
| DocC, warnings as errors | See `.github/workflows/ci.yml` |
| macOS build | `xcodebuild build -scheme SpeechKitVoz -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` |
| iOS build | `xcodebuild build -scheme SpeechKitVoz -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO` |
| visionOS build | `xcodebuild build -scheme SpeechKitVoz -destination 'generic/platform=visionOS' CODE_SIGNING_ALLOWED=NO` |
| watchOS build, VOZ excluded | `xcodebuild build -scheme SpeechKitVoz -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO` |

Export `SPEECHKIT_VOZ_STRICT_WARNINGS=1` for the `xcodebuild` rows; it scopes
warnings-as-errors to this package's sources. `OTHER_SWIFT_FLAGS=-warnings-as-errors`
cannot be used with `xcodebuild` here, because it is applied to every package in
the graph and conflicts with the `-suppress-warnings` Xcode gives dependency
targets.

Export `SPEECHKIT_VOZ_USE_LOCAL_SPEECHKIT=1` to resolve SpeechKit from a sibling
checkout at `../SpeechKit` instead of GitHub.

The regression suite uses scripted engines and a stub cache probe. It never
downloads model files and never opens a network connection. It covers
configuration, model state and progress, shared preparation, download-only and
load phases, retries, stale callbacks, serialized inference, cancellation,
release ordering, the background-preparation and readiness hooks, the state
stream, and the `SpeechService` extension seam.

The DocC catalog is built from filtered symbol graphs: SpeechKit and
desert-ant-core emit their own graphs into the same directory, and a catalog with
multiple root modules fails to convert. The build also passes
`-emit-extension-block-symbols` so the `SpeechService` extension members this
package adds have pages to link to.

## Real-model results carried over from the SpeechKit branch

Measured September 14-15, 2026 on `Kirklands-MacBook-Pro.local` with Xcode 27.0
(build 27A266a), Apple Swift 6.4, and a connected iPhone 16 Pro running iOS 27.0.

- Audio: 8.392375 seconds of synthesized English speech, mono, 22,050 Hz AIFF.
- Returned words: 24, with timestamps.
- Inference: 0.119641 seconds, about 70.15 times the audio duration per
  processing second, in a macOS Release build.
- Transcript: "This is a local speech kit transcription test. The recording
  should produce words with timestamps. We are testing the voice model on this
  computer"
- On the physical iPhone, after the cached-verification fix: preparation 0.4638
  seconds, inference 0.3146 seconds for the same 8.3924-second clip.

These results establish local inference on one synthetic English clip. They do
not establish multilingual accuracy, long-recording memory behavior, or offline
device behavior.

Debug builds are much slower than Release for preparation, because a fresh or
damaged cache is repaired through the SDK's pure-Swift SHA-256 verification. Use
optimized builds for performance measurements. Reopening an intact downloaded
model uses the streaming CryptoKit digest in `VozCachedModel`, which is what made
restart-time preparation fast enough to be usable.

## Reproduce the real-model smoke tests

The opt-in tests are skipped unless `SPEECHKIT_VOZ_MODEL_SMOKE=1` is set:

```sh
SPEECHKIT_VOZ_USE_LOCAL_SPEECHKIT=1 \
SPEECHKIT_VOZ_MODEL_SMOKE=1 \
SPEECHKIT_VOZ_AUDIO_FILE=/tmp/speechkit-voz-sample.aiff \
SPEECHKIT_VOZ_CACHE_DIRECTORY=/tmp/SpeechKitVozModelCache \
swift test -c release --filter Smoke
```

They download the real model into the configured cache directory on first run.
No model weights or private audio are committed to this repository.

## Not validated here

- Physical-device installation and launch for this package. The device evidence
  above comes from the SpeechKit branch's demo app.
- Interactive UI validation.
- Any accuracy claim for a language other than English, or for recording types
  other than short synthesized speech.
