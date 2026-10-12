# Qwen Swift inference audit

Pinned library revision: `244458d7b61e54ff135073ddc9ed76782bb20758`.
The build applies `scripts/patch_qwen_native.py` after resolving packages.
The script verifies the entire original source SHA256 and is idempotent only for
the exact original/modified pair. Unexpected source fails the build.

Codec ID zero is valid. The pinned Swift `decodeChunk` and tokenizer length
calculation incorrectly count only IDs greater than zero, then crop the tail of
the decoded waveform. Official Qwen counts IDs greater than -1 (negative IDs
are padding). Both Swift calculations are patched to include zero. At 24 kHz
with 1920 samples per codec frame, each ignored zero removes 80 ms from the end;
ICL includes reference codes, so zeros in the reference can also shorten output.
The offline bundle self-check exercises the actual patched MLX length function
on zero/nonzero/padding IDs without loading a TTS model or generating speech.
The tokenizer source is pinned by its own full-source SHA256 as well.

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

Mel tensors are cast to the speaker encoder weight dtype, as in official Qwen.
The resulting speaker vector is cast to the codec prefix dtype before insertion,
as in the original Python MLX implementation. A Float32 frontend/vector must not
promote an entire BF16 generation prefix to Float32. Cached outputs include the
inference revision so these fixes cannot reuse outputs from the previous path.
