"""Check the bundled probe on sparse 10/20-hour Float32 RF64 files, no synthesis."""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile


def check_rf64(ffprobe):
    with tempfile.TemporaryDirectory(prefix='studio-rf64-check-') as tmp:
        for hours in (10, 20):
            frames = hours * 3600 * 24000
            size = frames * 4
            header = (b'RF64' + struct.pack('<I', 0xffffffff) + b'WAVEds64'
                      + struct.pack('<IQQQI', 28, size + 72, size, frames, 0)
                      + b'fmt ' + struct.pack('<IHHIIHH', 16, 3, 1, 24000, 96000, 4, 32)
                      + b'data' + struct.pack('<I', 0xffffffff))
            assert len(header) == 80
            wav = Path(tmp) / f'{hours}h.wav'
            with wav.open('wb') as writer:
                writer.write(header)
                writer.truncate(size + len(header))  # sparse, does not allocate gigabytes
            seconds = float(subprocess.check_output(
                [str(ffprobe), '-v', 'error', '-show_entries', 'format=duration',
                 '-of', 'default=noprint_wrappers=1:nokey=1', str(wav)], text=True, timeout=30))
            assert abs(seconds - hours * 3600) < 1 / 24000, (hours, seconds)
            print(f'RF64 {hours}h checked: {size:,} PCM bytes, duration {seconds:.3f}s')


if __name__ == '__main__':
    check_rf64(Path(sys.argv[1]))
