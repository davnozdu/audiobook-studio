"""Equalize measured role loudness using constant gains; preserve every timestamp."""
import argparse
import os
from collections import defaultdict
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

FFMPEG = os.environ.get("AUDIOBOOK_FFMPEG", "/opt/homebrew/bin/ffmpeg")


def measure(path):
    result = subprocess.run([FFMPEG, "-hide_banner", "-nostats", "-i", str(path),
        "-af", "loudnorm=I=-20:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"],
        check=True, capture_output=True, text=True)
    values = json.loads(re.findall(r'\{\s*"input_i"[\s\S]*?\}', result.stderr)[-1])
    return {"lufs": float(values["input_i"]), "true_peak_db": float(values["input_tp"])}


def gains_for(measurements, requested=-20.0, peak_limit=-1.5):
    valid = {k: v for k, v in measurements.items() if math.isfinite(v["lufs"]) and math.isfinite(v["true_peak_db"])}
    if not valid:
        raise ValueError("No measurable role speech")
    # Lower the COMMON target if any role cannot reach it without clipping.
    target = min([requested] + [v["lufs"] + peak_limit - v["true_peak_db"] - 0.1 for v in valid.values()])
    return target, {k: target - v["lufs"] if k in valid else 0.0 for k, v in measurements.items()}


def pool(rows, folder, path, sr):
    import numpy as np
    import soundfile as sf
    with sf.SoundFile(path, "w", samplerate=sr, channels=1, subtype="FLOAT") as writer:
        for row in rows:
            with sf.SoundFile(folder / "segments" / (row["segment_id"] + ".wav")) as reader:
                if reader.samplerate != sr or reader.channels != 1:
                    raise ValueError("Only consistent mono role WAVs are supported")
                for block in reader.blocks(blocksize=65536, dtype="float32"):
                    writer.write(block)
            writer.write(np.zeros(round(sr * 0.05), dtype=np.float32))


def normalize(source, out, target=-20.0, peak_limit=-1.5):
    import numpy as np
    import soundfile as sf
    source, out = Path(source).resolve(), Path(out).resolve()
    if source == out:
        raise ValueError("Keep raw audio: output must be a different directory")
    timeline = json.loads((source / "timeline.json").read_text())
    benchmark = json.loads((source / "benchmark.json").read_text())
    if benchmark.get("state") != "complete":
        raise ValueError("Raw synthesis is incomplete")
    info = sf.info(source / "sample.wav")
    if info.channels != 1 or abs(info.duration - benchmark["final_audio_seconds"]) > 1 / info.samplerate:
        raise ValueError("Raw WAV does not match its benchmark")
    grouped = defaultdict(list)
    for row in timeline["segments"]:
        grouped[row["speaker"]].append(row)
    out.mkdir(parents=True, exist_ok=True)
    (out / "segments").mkdir(exist_ok=True)
    (out / "benchmark.json").write_text(json.dumps({"state": "normalizing"}))
    with tempfile.TemporaryDirectory(prefix="book-loudness-") as temporary:
        pooled = Path(temporary) / "role.wav"
        before = {}
        for speaker, rows in grouped.items():
            pool(rows, source, pooled, info.samplerate)
            before[speaker] = measure(pooled)
        actual_target, gain_db = gains_for(before, target, peak_limit)
        for speaker in grouped:
            print(f"{speaker}: {before[speaker]['lufs']:.2f} LUFS; gain {gain_db[speaker]:+.2f} dB", flush=True)
        for row in timeline["segments"]:
            filename = row["segment_id"] + ".wav"
            with sf.SoundFile(source / "segments" / filename) as reader, sf.SoundFile(
                    out / "segments" / filename, "w", samplerate=reader.samplerate,
                    channels=reader.channels, subtype="PCM_16") as writer:
                if abs(reader.frames / reader.samplerate - (row["audio_end"] - row["audio_start"])) > 1 / reader.samplerate:
                    raise ValueError("Segment duration differs from timeline")
                for block in reader.blocks(blocksize=65536, dtype="float32"):
                    block *= 10 ** (gain_db[row["speaker"]] / 20)
                    if not np.isfinite(block).all() or np.max(np.abs(block), initial=0) >= 1:
                        raise ValueError("Non-finite or clipped audio; refusing normalization")
                    writer.write(block)
        # Read original montage, apply the same role gain in its exact frame
        # intervals. Never resample, stretch, trim or rebuild timing from floats.
        with sf.SoundFile(source / "sample.wav") as reader, sf.SoundFile(
                out / "sample.wav", "w", samplerate=info.samplerate, channels=1, subtype="PCM_16") as writer:
            rows = timeline["segments"]
            for index, row in enumerate(rows):
                stop = round(rows[index + 1]["audio_start"] * info.samplerate) if index + 1 < len(rows) else info.frames
                if reader.tell() != round(row["audio_start"] * info.samplerate) or stop < reader.tell():
                    raise ValueError("Invalid montage offsets")
                gain = 10 ** (gain_db[row["speaker"]] / 20)
                while reader.tell() < stop:
                    block = reader.read(min(65536, stop - reader.tell()), dtype="float32")
                    if not len(block):
                        raise ValueError("Unexpected end of raw montage")
                    writer.write(block * gain)
        if sf.info(out / "sample.wav").frames != info.frames:
            raise ValueError("Normalization changed duration")
        after = {}
        for speaker, rows in grouped.items():
            pool(rows, out, pooled, info.samplerate)
            after[speaker] = measure(pooled)
            if math.isfinite(before[speaker]["lufs"]) and (abs(after[speaker]["lufs"] - actual_target) > 0.3 or after[speaker]["true_peak_db"] > peak_limit + 0.15):
                raise ValueError("Loudness/peak verification failed")
    shutil.copyfile(source / "timeline.json", out / "timeline.json")
    subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", str(out / "sample.wav"),
                    "-codec:a", "libmp3lame", "-b:a", "192k", str(out / "sample.mp3")], check=True)
    report = dict(method="role-integrated EBU R128 measurement + constant gain", raw_audio=str(source),
                  requested_lufs=target, actual_lufs=actual_target, true_peak_limit_db=peak_limit,
                  gains_db=gain_db, before=before, after=after, timing_unchanged=True)
    (out / "loudness.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    benchmark.update(loudness_normalization=report, output_files={"wav": str(out / "sample.wav"), "mp3": str(out / "sample.mp3")})
    (out / "benchmark.json").write_text(json.dumps(benchmark, ensure_ascii=False, indent=2))
    print(f"Normalized: {out / 'sample.wav'}; target {actual_target:.2f} LUFS; timing unchanged", flush=True)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audio-dir", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--target-lufs", type=float, default=-20)
    parser.add_argument("--true-peak", type=float, default=-1.5)
    args = parser.parse_args()
    if not -40 <= args.target_lufs <= -10 or not -9 <= args.true_peak <= -1:
        parser.error("Unsafe loudness/peak target")
    normalize(args.audio_dir, args.out, args.target_lufs, args.true_peak)
