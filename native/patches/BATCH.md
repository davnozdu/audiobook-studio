# Short-line batching and large-book assembly

The pinned Qwen Swift source is extended by `scripts/native/Qwen3TTSStudioBatch.swift`.
One GPU batch contains at most four short (≤96 characters), similarly sized lines; each lane
has its own voice, so characters and manner samples may share a batch. Long lines stay single:
measured pairs ran at 1.20× against 1.19× for single lines, with ~1 GB more peak memory. Voice-only ICL pieces (reference text and
codec embeddings, codec prefix with speaker embedding) are built once per character.
Inputs use the official offline ICL layout, left padding, attention masks and
per-lane positions. Token choice is vectorised over [batch, vocab] with the same
steps as upstream `sampleToken` (suppression, repetition penalty, EOS-preserving
top-k, temperature) as Gumbel-max; the noise is a GPU hash of each lane's own seed, step and
code group, so a line's draws do not depend on its batch neighbours (checked in the self-check). Repetition history
and EOS flags live on the GPU, so the next step is queued (`asyncEval`) before the
previous step's tokens are read. Finished lanes stop collecting frames; token-limit
failures are retried independently while accepted neighbours are saved immediately.
Codec decoding is sequential, using the shared decoder safely. Each line is decoded
after the last 25 reference frames (the official `chunked_decode` left context)
instead of the whole reference; the context audio is cut by its exact frame count,
including valid zero-valued codec IDs. Every batch logs MLX peak memory and system swap.

References: [Qwen model](https://github.com/QwenLM/Qwen3-TTS/blob/main/qwen_tts/core/models/modeling_qwen3_tts.py),
[Qwen inference](https://github.com/QwenLM/Qwen3-TTS/blob/main/qwen_tts/inference/qwen3_tts_model.py),
[MLX explicit random keys](https://github.com/ml-explore/mlx-swift/blob/0.32.3/Source/MLXRandom/Random.swift).

The offline bundle self-check compares a tiny actual Swift talker and subcodebook
model in batched and singleton mode, including unequal input lengths, prefill,
three continuation steps, independent random sampling and staggered EOS.
It loads no voice weights and generates no speech. Core tests check retries,
complete ID coverage, original order, final-utterance duration and 10/20-hour
frame counts. Sparse RF64 fixtures verify the bundled FFprobe above 4 GB.
These are structural/numerical checks, not a multi-hour acoustic benchmark.

Scheduling scans a bounded 64-row window per pending row; a large book does not
repeatedly sort all remaining rows. Montage streams one utterance at a time and
uses 64-bit RF64 headers. Every segment is checked before packaging, and the
completed M4B duration must match the timeline.

Per-line cache (`.spcm`, SPC2) keeps 16-bit PCM — CD quality, quantisation noise at −96 dBFS,
far below the final 96 kbit/s AAC — as second-order prediction residuals in low/high byte planes,
compressed with macOS LZMA. It is lossless at 16 bits. Measured on speech: 95 MB per hour against
283 MB for the former exact Float32 + LZFSE container (still readable as SPC1); writing costs about
33 s and reading 4 s per hour of speech. SHA256, frame count and cache signatures protect against
stale or incomplete data. Source: [Apple Compression](https://developer.apple.com/documentation/compression).
Role loudness is measured through a bounded PCM stdin pipe. Final montage reads
one utterance at a time, applies per-role gain and writes exact samples/pauses
directly to FFmpeg. Music mixing, limiting and AAC encoding run in that same
process. No full measurement, normalized or music WAV is created. Pipe failures
abort packaging and retain the resumable cache. The bundle self-check packages
deterministic small signal fixtures with and without music, checks decoded AAC
duration, EPUB text/CRC and verified cleanup. It does not synthesize speech.
Reference: [FFmpeg pipe protocol](https://ffmpeg.org/ffmpeg-protocols.html#pipe).

Only after M4B/EPUB packaging and SHA256 verification of the external copies are
all cached utterances deleted. Source EPUB, roles, voice references, logs,
timeline and final exports are retained. Cancellation/failure retains accepted
utterances for resume; disposable normalization/music files are cleaned on exit.
Failure to delete a file is reported in the log. Successful rebuilds regenerate
speech because the completed-book cache has intentionally been reclaimed.

Disk use per book: the speech cache is about 0.95 GB for 10 hours and 1.9 GB for 20 hours while
the book is being read (it is deleted after a verified export). Each final M4B is about 432/864 MB
at 96 kb/s and the EPUB holds another copy of that audio. Copies between the project and an export
folder on the same APFS volume are clones and take no extra space; packaging the EPUB needs about one
more compressed copy temporarily. Allow roughly 3 GB free for 10 hours and 5 GB for 20 hours, plus
about 7.6 GB once for model downloads. Media inside the EPUB is stored, not deflated again.
