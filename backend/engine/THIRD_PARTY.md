# Third-party components

The license texts of bundled native dependencies are copied into
`Contents/Resources/licenses` of the application at build time.

- MLX Swift, MLX Swift LM, MLX Audio Swift, Swift Transformers, Swift Hugging Face:
  see their bundled licenses.
- Sparkle 2: MIT, https://github.com/sparkle-project/Sparkle.
- PyTorch / libtorch (Silero Stress runtime): BSD-style, bundled as `PyTorch.txt`.
- Silero Stress weights: exported to TorchScript at build time; see
  https://github.com/snakers4/silero-stress for their terms.
- Qwen3-TTS weights: Apache-2.0; model checkpoints are downloaded separately on first use.
- FFmpeg: license depends on the Homebrew build and enabled libraries (LGPL/GPL).

No blanket license for user-owned source code is chosen by this repository.
Review dependency licenses before redistributing or operating a public service.

## Supertonic text preparation

`native/Sources/StudioCore/Russian.swift` adapts the user-provided Supertonic Android
Russian book, number and date normalizers. `supertonic_rules.json` contains its numeral
tables, acronym lists and Russian text-preparation instruction from `LlmProviders.kt`.
Source supplied at `/Users/davnozdu/Downloads/supertonic`, under
`supertonic-android/app/src/main/java/com/brahmadeo/supertonic/tts/`;
source file SHA-256 values are embedded in that JSON for traceability.
The portable static dictionary is `resources/stress_dictionary.json`; its provenance
identifies the original Supertonic/Silero inputs.
The full SACC dictionary is from
https://github.com/davnozdu/supertonic-dictionaries/releases/tag/russian-v1.1
(179200764 bytes, SHA-256 a1ac32606e99f6d8ab8e8ce796b0005b0693908555460656976c54e171658b27).
It is downloaded and verified while building the application and is not stored in this
repository. No additional license grant is asserted for user-owned or separately
downloaded dictionary data.

## Background music

The seven bundled reading-music tracks in `resources/` are included at the request and
with the permission of the project owner; the first, `Lamplight_and_Paper.mp3`, matches
the public `reading-music-v1` catalog/release:
https://github.com/davnozdu/supertonic-android/releases/tag/reading-music-v1.
No new license or third-party redistribution rights are asserted by this project.
