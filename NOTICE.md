# Third-party notices

SpeechKit-Voz's own source is licensed under the Apache License 2.0. See
[LICENSE](LICENSE).

The VOZ runtime and the VOZ speech model that this package depends on are not
Apache 2.0, and their terms apply to any app that ships this package.

## Desert Ant Labs Source-Available License 1.0

The pinned
[`desert-ant-core` 3.1.0 source](https://github.com/Desert-Ant-Labs/desert-ant-core/tree/v3.1.0/Sources/Voz)
and the [`desert-ant-labs/voz` model](https://huggingface.co/desert-ant-labs/voz)
are licensed under the
[Desert Ant Labs Source-Available License 1.0](https://license.desertant.com/1.0).

The obligations that affect an app shipping SpeechKit-Voz are:

- **Free below 100,000 monthly active devices per platform for each model.** A
  commercial license from Desert Ant Labs is required above that threshold.
- **User-visible attribution.** A distributed app must show a "Powered by Desert
  Ant Labs" credit, linked to [desertant.com](https://desertant.com) where links
  are supported.
- **No training competing models.** The terms forbid using the model, its
  outputs, or its logs to train a competing on-device model.
- **No standalone redistribution.** The terms forbid redistributing the VOZ
  runtime or the model as a standalone product.
- **Telemetry.** The VOZ runtime may send the license's minimal device-counting
  telemetry. The license says this telemetry excludes inputs, outputs, and user
  content.

## Model distribution

SpeechKit-Voz does not bundle model files and this repository does not commit
them. Preparation fetches the pinned `v0.1.0` model from
<https://huggingface.co/desert-ant-labs/voz> unless the configured model
directory already contains the required files. The download is roughly 467 MB.

This summary is provided for convenience only. Read the full license text at
<https://license.desertant.com/1.0> before distributing an app that links this
package.
