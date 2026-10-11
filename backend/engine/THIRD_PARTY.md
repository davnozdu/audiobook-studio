# Third-party components

These projects are dependencies; their source and weights are not bundled here.

- EbookLib 0.20: AGPL-3.0-or-later, https://github.com/aerkalov/ebooklib.
  Distribution and network-service obligations may apply to derivative uses.
- Razdel: MIT, https://github.com/natasha/razdel.
- MLX-Audio and MLX: inspect their bundled licenses when redistributing.
- Qwen3-TTS weights: Apache-2.0; model checkpoints are downloaded separately.
- FFmpeg: license depends on the Homebrew build and enabled libraries (LGPL/GPL).

No blanket license for user-owned source code is chosen by this repository.
Review dependency licenses before redistributing or operating a public service.

## Supertonic text preparation

`russian_text.py` adapts the user-provided Supertonic Android Russian book,
number and date normalizers. `supertonic_rules.json` contains its numeral tables,
acronym lists and Russian text-preparation instruction from `LlmProviders.kt`.
Source supplied at `/Users/davnozdu/Downloads/supertonic`, under
`supertonic-android/app/src/main/java/com/brahmadeo/supertonic/tts/`;
source file SHA-256 values are embedded in that JSON for traceability.
Android/Silero neural binaries, weights and English currency rules are not bundled.
The runnable kit includes the user-supplied portable static dictionary in
`resources/stress_dictionary.json`; its provenance identifies the original
Supertonic/Silero inputs. Runtime copies in `data/stress` are excluded from Git.
The optional full SACC dictionary is from
https://github.com/davnozdu/supertonic-dictionaries/releases/tag/russian-v1.1
(179200764 bytes, SHA-256 a1ac32606e99f6d8ab8e8ce796b0005b0693908555460656976c54e171658b27).
Its data is not redistributed in this repository. No additional license grant
is asserted for user-owned or separately downloaded dictionary data.

## Background music

The user requested inclusion of their first MyTTS reading-music track:
`resources/Lamplight_and_Paper.mp3`, from their local `Downloads/MusicRead`.
Size and SHA256 match their public `reading-music-v1` catalog/release:
https://github.com/davnozdu/supertonic-android/releases/tag/reading-music-v1.
No new license or third-party redistribution rights are asserted by this project.
