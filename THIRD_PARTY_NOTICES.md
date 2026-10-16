# Third-party notices for Desert Ant Flow

Flow's source code is MIT licensed (see [`LICENSE`](LICENSE)). Everything listed below has its own license. The full text of each license is in [`LICENSES`](LICENSES), and the app shows all of them under About Desert Ant Flow, Acknowledgements.

## Desert Ant Labs models and SDKs

The models and their SDKs are licensed under the Desert Ant Labs Source-Available License, Version 1.0. The full terms are at <https://license.desertant.com/1.0>, and in plain text at <https://license.desertant.com/1.0.txt>. Copyright © 2026 Desert Ant Labs B.V. `SPDX-License-Identifier: LicenseRef-DAL-Source-Available-1.0`

The license is free below 100,000 monthly active devices per platform, for each model. Above that, you need a commercial license from <licensing@desertant.com>. You can embed the models in your app. You can't use the models, their outputs, or their logs to train a competing on-device model. Apps that ship the models credit Desert Ant Labs, as the [attribution guide](https://license.desertant.com/attribution) describes.

| Package | What Flow uses it for |
|---|---|
| [`desert-ant-core`](https://github.com/Desert-Ant-Labs/desert-ant-core) | The eleven models: Voz, Clear, Ear, Redact, Gist, Emo, Tongue, Shapes, Moderator, Eye, and Who |

The package includes Tongue's weights. Flow downloads the other models from Hugging Face the first time a flow uses them. The notices for the weights each model was trained from are in [`LICENSES/desert-ant-core-notices.md`](LICENSES/desert-ant-core-notices.md) and on each model's Hugging Face page.

## Desert Ant Labs brand kit

[`desert-ant-swift`](https://github.com/Desert-Ant-Labs/desert-ant-swift) (product `DesertAntUI`) draws the Desert Ant mark, the loader, the colors, and the attribution line. Its code is MIT licensed. The Desert Ant Labs name and mark are trademarks, and none of these licenses grant rights to them.

## Swift packages

| Package | License | Copyright |
|---|---|---|
| [Sparkle](https://github.com/sparkle-project/Sparkle) | MIT | © 2006-2013 Andy Matuschak, © 2009-2013 Elgato Systems GmbH, © 2011-2014 Kornel Lesiński, © 2015-2024 Mayur Pawashe, and contributors |
| [Yams](https://github.com/jpsim/Yams) | MIT | © 2016 JP Simard |
| [swift-numerics](https://github.com/apple/swift-numerics) | Apache-2.0 | © Apple Inc. |

## Echo cancellation

`Packages/EchoCancel` builds these two libraries into one static library with its `build.sh`. Flow uses the library to remove the call's audio from the microphone, so each person on a call is transcribed once.

| Library | License | Copyright |
|---|---|---|
| [webrtc-audio-processing](https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing) 2.1, the PulseAudio package of WebRTC's audio processing | BSD-3-Clause, plus Google's patent grant in [`LICENSES/webrtc-PATENTS.txt`](LICENSES/webrtc-PATENTS.txt) | © 2011 The WebRTC project authors |
| [Abseil](https://github.com/abseil/abseil-cpp) 20240722.0 | Apache-2.0 | © The Abseil Authors |

## Samples

Two sample recordings are in the public domain: a reading of *Ant Ventures* by Blanche Elizabeth Wade from [LibriVox](https://librivox.org/ant-ventures-by-blanche-elizabeth-wade/), and President Kennedy's 1961 inaugural address. Desert Ant Labs made the other recordings, in `App/Resources/Samples/clear`, `voice-memo-2.wav`, and `designing-on-device.wav`.

The sample photos are © Detail Technologies B.V. and Desert Ant Labs B.V., all rights reserved. Flow's MIT license doesn't cover them.
