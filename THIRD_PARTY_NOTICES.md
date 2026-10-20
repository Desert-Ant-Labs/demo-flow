# Third-party notices for Desert Ant Flow

Flow's source code is MIT licensed (see [`LICENSE`](LICENSE)). Everything listed below has its own license. The full text of each license is in [`LICENSES`](LICENSES), and the app shows all of them under About Desert Ant Flow, Acknowledgements.

## Desert Ant Labs models and SDKs

The models and their SDKs are licensed under the Desert Ant Labs Source-Available License, Version 1.0. The full terms are at <https://license.desertant.com/1.0>, and in plain text at <https://license.desertant.com/1.0.txt>. Copyright © 2026 Desert Ant Labs B.V. `SPDX-License-Identifier: LicenseRef-DAL-Source-Available-1.0`

The license is free below 100,000 monthly active devices per platform, for each model. Above that, you need a commercial license from <licensing@desertant.com>. You can embed the models in your app. You can't use the models, their outputs, or their logs to train a competing on-device model. Apps that ship the models credit Desert Ant Labs, as the [attribution guide](https://license.desertant.com/attribution) describes.

| Package | What Flow uses it for |
|---|---|
| [`desert-ant-core`](https://github.com/Desert-Ant-Labs/desert-ant-core) | The thirteen models: Voz, Clear, Ear, Redact, Gist, Emo, Tongue, Shapes, Moderator, Eye, Who, Uhm, and Clips |

The package includes Tongue's weights. Flow downloads the other models from Hugging Face the first time a flow uses them. The notices for the weights each model was trained from are in [`LICENSES/desert-ant-core-notices.md`](LICENSES/desert-ant-core-notices.md) and on each model's Hugging Face page.

## Desert Ant Labs brand kit

[`desert-ant-swift`](https://github.com/Desert-Ant-Labs/desert-ant-swift) (product `DesertAntUI`) draws the Desert Ant mark, the loader, the colors, and the attribution line. Its code is MIT licensed. The Desert Ant Labs name and mark are trademarks, and none of these licenses grant rights to them.

## Inclusive Sans

The Clips step burns captions in Inclusive Sans, by the Inclusive Sans Project Authors, shipped as `App/Resources/Fonts/InclusiveSans-Regular.ttf` and `App/Resources/Fonts/InclusiveSans-Bold.ttf`: the Regular (400) and Bold (700) instances of the variable font, version 2.004. Licensed under the SIL Open Font License 1.1, in [`LICENSES/InclusiveSans-OFL.txt`](LICENSES/InclusiveSans-OFL.txt). Source: https://github.com/LivKing/Inclusive-Sans

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

The Desert Ant Labs team shot the trip photos, and the photos of people marked Desert Ant Labs below. They're © Desert Ant Labs B.V., all rights reserved, and Flow's MIT license doesn't cover them.

The other photos of people are from Lummi and Dupe, under the [Lummi license](https://www.lummi.ai/license) and the [Dupe license](https://dupephotos.com/license-and-terms). Their creators keep the copyright.

| Photo | Source | Creator | Original |
|---|---|---|---|
| `couple-chatting-at-cafe.jpg` | [Lummi](https://www.lummi.ai/license) | [Pablo Stanley](https://www.lummi.ai/creator/pablostanley) | [Cozy Café Conversation](https://www.lummi.ai/photo/cozy-cafe-conversation-xn-sh) |
| `man-bleached-hair-smiling-at-phone.jpg` | [Lummi](https://www.lummi.ai/license) | [Sanna Granqvist](https://www.lummi.ai/creator/granqvistsanna-xh1cz) | [Cheerful Smartphone User](https://www.lummi.ai/photo/cheerful-smartphone-user-yjage) |
| `person-on-checkered-floor-crowd.jpg` | [Lummi](https://www.lummi.ai/license) | [Harsh](https://www.lummi.ai/creator/harshworks) | [Urban Contemplation](https://www.lummi.ai/photo/urban-contemplation-k7dvx) |
| `redhead-selfie-by-mural.jpg` | Desert Ant Labs | Desert Ant Labs team |  |
| `redhead-selfie-graffiti-wall.jpg` | Desert Ant Labs | Desert Ant Labs team |  |
| `redhead-with-phone-closeup.jpg` | Desert Ant Labs | Desert Ant Labs team |  |
| `silhouettes-at-window-table.jpg` | [Lummi](https://www.lummi.ai/license) | [rena](https://www.lummi.ai/creator/rena) | [Conversing at Table](https://www.lummi.ai/photo/conversing-at-table-jwbhd) |
| `silhouettes-behind-glass.jpg` | [Lummi](https://www.lummi.ai/license) | [rena](https://www.lummi.ai/creator/rena) | [Blurry Indoor Scene](https://www.lummi.ai/photo/blurry-indoor-scene-mbs-t) |
| `three-friends-sunset-palms.jpg` | [Dupe](https://dupephotos.com/license-and-terms) | [Alex Rusciano](https://dupephotos.com/profile/splitforthecoast) | [Photo](https://dupephotos.com/profile/splitforthecoast?content=a8a2ba85-e524-495d-8fa7-76a9b95f7ee9) |
| `two-friends-at-desk-overhead.jpg` | [Dupe](https://dupephotos.com/license-and-terms) | [CHLOE CHRISTIANSON](https://dupephotos.com/profile/chloechristiansonn) | [Photo](https://dupephotos.com/profile/chloechristiansonn?content=cc027a52-4184-4ab4-b862-456ef2fbd9ea) |
| `two-friends-city-walk-winter.jpg` | [Dupe](https://dupephotos.com/license-and-terms) | [Jayda Anderson](https://dupephotos.com/profile/jaydaanderson) | [Photo](https://dupephotos.com/profile/jaydaanderson?content=5fe3f400-4719-4350-a295-c286aee92711) |
| `two-people-chatting-against-sky.jpg` | [Lummi](https://www.lummi.ai/license) | [Sanna Granqvist](https://www.lummi.ai/creator/granqvistsanna-xh1cz) | [Outdoor Phone Interaction](https://www.lummi.ai/photo/outdoor-phone-interaction-pllwu) |
| `two-people-in-soft-light.jpg` | [Lummi](https://www.lummi.ai/license) | [Steph Meade](https://www.lummi.ai/creator/steph) | [Thoughtful Duo Indoors](https://www.lummi.ai/photo/thoughtful-duo-indoors-rkd78) |
| `two-people-on-colorful-street.jpg` | [Lummi](https://www.lummi.ai/license) | [Sam Stoof](https://www.lummi.ai/creator/samstoof) | [Urban Stroll Duo](https://www.lummi.ai/photo/urban-stroll-duo-wfnms) |
| `two-people-reading-book-together.jpg` | [Dupe](https://dupephotos.com/license-and-terms) | [SIHAM HANNAOUI](https://dupephotos.com/profile/Siham) | [Photo](https://dupephotos.com/profile/Siham?content=94591372-dbf7-451e-afa3-c0b417667dbb) |
| `two-people-with-laptop-glow.jpg` | [Lummi](https://www.lummi.ai/license) | [Steph Meade](https://www.lummi.ai/creator/steph) | [Focused Collaboration](https://www.lummi.ai/photo/focused-collaboration-cq3sa) |
| `two-women-laughing-with-phones.jpg` | [Lummi](https://www.lummi.ai/license) | [Sanna Granqvist](https://www.lummi.ai/creator/granqvistsanna-xh1cz) | [Joyful Outdoor Moment](https://www.lummi.ai/photo/joyful-outdoor-moment-hpuhg) |
| `two-women-sharing-phones-laughing.jpg` | [Lummi](https://www.lummi.ai/license) | [Sanna Granqvist](https://www.lummi.ai/creator/granqvistsanna-xh1cz) | [Outdoor Smartphone Joy](https://www.lummi.ai/photo/outdoor-smartphone-joy-qfe7a) |
| `two-women-taking-selfie.jpg` | Desert Ant Labs | Desert Ant Labs team |  |
| `woman-at-street-cafe.jpg` | [Lummi](https://www.lummi.ai/license) | [Sam Stoof](https://www.lummi.ai/creator/samstoof) | [Café Conversation Scene](https://www.lummi.ai/photo/cafe-conversation-scene-wv7wt) |
| `woman-brown-coat-taking-selfie.jpg` | Desert Ant Labs | Desert Ant Labs team |  |
| `woman-bucket-hat-with-phone.jpg` | Desert Ant Labs | Desert Ant Labs team |  |
| `woman-gazing-through-crowd.jpg` | [Lummi](https://www.lummi.ai/license) | [Georgi Valkov](https://www.lummi.ai/creator/georgi) | [Woman in Focused Crowd](https://www.lummi.ai/photo/woman-in-focused-crowd-zvpz2) |
| `woman-hand-reaching-toward-camera.jpg` | [Dupe](https://dupephotos.com/license-and-terms) | [Stevie Wenzel](https://dupephotos.com/profile/StevieMarie13) | [Photo](https://dupephotos.com/profile/StevieMarie13?content=cf0cf7d0-1b2a-4ea3-9618-ee9b055fe6e2) |
| `woman-in-busy-restaurant.jpg` | [Lummi](https://www.lummi.ai/license) | [Pablo Stanley](https://www.lummi.ai/creator/pablostanley) | [Retro Diner Gathering](https://www.lummi.ai/photo/retro-diner-gathering-gx4ma) |
| `woman-long-hair-smiling-at-cafe.jpg` | Desert Ant Labs | Desert Ant Labs team |  |
| `woman-looking-up-blue-sky.jpg` | [Dupe](https://dupephotos.com/license-and-terms) | [Sarah Moore](https://dupephotos.com/profile/Moorej) | [Photo](https://dupephotos.com/profile/Moorej?content=7a8c8086-2508-4942-be2c-4e774451118c) |
| `woman-on-beach-with-phone.jpg` | Desert Ant Labs | Desert Ant Labs team |  |
| `woman-selfie-european-city-dusk.jpg` | [Lummi](https://www.lummi.ai/license) | [Pablo Stanley](https://www.lummi.ai/creator/pablostanley) | [Twilight City Selfie](https://www.lummi.ai/photo/twilight-city-selfie-vimzy) |
| `woman-smiling-at-phone-dark-bg.jpg` | Desert Ant Labs | Desert Ant Labs team |  |
| `woman-standing-still-in-crowd.jpg` | [Lummi](https://www.lummi.ai/license) | [Harsh](https://www.lummi.ai/creator/harshworks) | [Urban Stillness Portrait](https://www.lummi.ai/photo/urban-stillness-portrait-5-kyd) |
| `woman-still-in-crosswalk-blur.jpg` | [Lummi](https://www.lummi.ai/license) | [Harsh](https://www.lummi.ai/creator/harshworks) | [Urban Contemplation](https://www.lummi.ai/photo/urban-contemplation-d8xxm) |
| `woman-trenchcoat-blurred-crowd.jpg` | [Lummi](https://www.lummi.ai/license) | [Harsh](https://www.lummi.ai/creator/harshworks) | [Urban Introspection](https://www.lummi.ai/photo/urban-introspection-wek8z) |
| `woman-yellow-jacket-with-phone.jpg` | [Lummi](https://www.lummi.ai/license) | [Sanna Granqvist](https://www.lummi.ai/creator/granqvistsanna-xh1cz) | [Smiling Woman with Phone](https://www.lummi.ai/photo/smiling-woman-with-phone-plw78) |
| `young-man-golden-hour-backlight.jpg` | [Lummi](https://www.lummi.ai/license) | [Pablo Stanley](https://www.lummi.ai/creator/pablostanley) | [Outdoor Selfie Scene](https://www.lummi.ai/photo/outdoor-selfie-scene-1b_c9) |
