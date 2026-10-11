"""Independent PyTorch/librosa numerical fixture for the Qwen speaker frontend.

Matches QwenLM/Qwen3-TTS modeling_qwen3_tts.py mel_spectrogram. No models, speech,
network requests or user files. This script is exclusively a CI build tool.
"""
import json
import math
import sys
from pathlib import Path

import librosa
import numpy as np
import torch

audio = np.array([
    0.2 * math.sin(2 * math.pi * 437 * i / 24000)
    + 0.07 * math.cos(2 * math.pi * 3100 * i / 24000)
    + ((i % 97) - 48) * 0.0001 for i in range(4096)
], dtype=np.float32)
wave = torch.nn.functional.pad(torch.from_numpy(audio)[None, None], (384, 384), mode="reflect")[:, 0]
spectrum = torch.stft(wave, 1024, hop_length=256, win_length=1024,
    window=torch.hann_window(1024), center=False, normalized=False,
    onesided=True, return_complex=True)
magnitude = torch.sqrt(torch.abs(spectrum).square() + 1e-9)
filters = torch.from_numpy(librosa.filters.mel(sr=24000, n_fft=1024, n_mels=128,
    fmin=0, fmax=12000, htk=False, norm="slaney"))
mel = torch.log(torch.clamp(filters @ magnitude, min=1e-5))[0].transpose(0, 1)
points = [[frame, channel, float(mel[frame, channel])]
    for frame in [0, 1, 7, 15] for channel in [0, 7, 15, 31, 63, 95, 127]]
target = Path(sys.argv[1])
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps({"shape": list(mel.shape), "points": points}))
print("Independent Qwen speaker-mel numerical fixture exported")
