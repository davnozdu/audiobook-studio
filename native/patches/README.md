# Qwen Swift inference audit

Pinned library revision: `244458d7b61e54ff135073ddc9ed76782bb20758`.
The build applies `scripts/patch_qwen_native.py` after resolving packages.
The script verifies the entire original source SHA256 and is idempotent only for
the exact original/modified pair. Unexpected source fails the build.

Reference: [official inference wrapper](https://github.com/QwenLM/Qwen3-TTS/blob/main/qwen_tts/inference/qwen3_tts_model.py)
and [model input assembly](https://github.com/QwenLM/Qwen3-TTS/blob/main/qwen_tts/core/models/modeling_qwen3_tts.py).
VoiceDesign defaults to `non_streaming_mode=True`: instruction, role, language
prefix, full text plus EOS over codec PAD, then codec BOS over text PAD.
The pinned Swift library instead feeds text progressively even for offline calls.
The patch uses the official full-text layout for offline calls; streaming retains
the original progressive layout. ICL cloning already has the offline layout.

The official wrapper honours the supplied token limit. The Swift text-token-times-six
heuristic can truncate slow speech; it is removed, and unfinished utterances throw
instead of being saved as complete. Base loading/conditioning rejects absent
speaker encoder weights/embeddings rather than continuing without speaker identity.

These corrections align algorithms and prevent silent degradation. They do not
prove perceptual voice separation: acoustic evaluation belongs to the user.

Speaker encoder preprocessing also differed from Qwen. The shared Swift DSP
helper used HTK, log10 of power, Whisper dynamic range clipping/normalization,
symmetric Hann and FFT/2 centre padding. Qwen requires Slaney mel filters,
magnitude `sqrt(abs(STFT)^2 + 1e-9)`, natural log with floor `1e-5`, periodic Hann,
384 reflected samples at each edge and an uncentred 1024 FFT / 256 hop. The patch
uses a dedicated Qwen frontend, leaving the shared Whisper helper unchanged.
Packaging checks its numerical output against a synthetic signal fixture produced
by PyTorch and librosa, without speech synthesis or loading voice model weights.
