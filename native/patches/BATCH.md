# Short-line batching and large-book assembly

The pinned Qwen Swift source is extended by `scripts/native/Qwen3TTSStudioBatch.swift`.
One GPU batch contains at most four short, similarly sized lines of one speaker.
Inputs use the official offline ICL layout, left padding, attention masks and
per-lane positions. Each lane owns its sampling key, token history, EOS flag and
codec frames. Finished lanes stop collecting frames; token-limit failures are
retried independently while accepted neighbours are saved immediately.
Codec decoding is sequential, using the shared decoder safely. Reference audio
is cut by its exact codec frame count, including valid zero-valued codec IDs.

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

Per-line cache uses exact Float32 PCM compressed by native macOS LZFSE in `.spcm`
containers with reversible byte-plane transposition; incompressible data falls
back to raw PCM. No sample conversion or
lossy encoding is performed. SHA256, frame count and cache signatures protect
against stale or incomplete data. Source: [Apple Compression](https://developer.apple.com/documentation/compression).
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

At 24 kHz mono Float32, 10 hours is 3.456 GB PCM; 20 hours is 6.912 GB.
96 kb/s AAC is approximately 432/864 MB per final M4B; the EPUB contains another
copy. Project and external result folders both retain these compressed outputs.
Allow roughly 7 GB free for 10 hours and 12 GB for 20 hours, excluding first-time
model downloads, existing projects, archives and source music. Actual lossless
compression ratio depends on the waveform; estimates assume no saving from it.
With both internal/external M4B+EPUB copies, the PCM+final-file bound is roughly
5.2/10.4 GB plus metadata and transient packaging. AAC faststart and EPUB packaging
may add one extra compressed copy temporarily. Model downloads total about
7.6 GB independently of book length and remain available for subsequent books.
