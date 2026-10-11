"""Validate the distribution in a clean environment, without models or network."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

app = Path(sys.argv[1]).resolve()
resources = app / 'Contents/Resources'
interpreter = resources / 'runtime/python/bin/python3'
# A preview linked to Homebrew or a developer venv is not a distributable app.
interpreter.resolve().relative_to(resources / 'runtime/python')
for path in (resources / 'runtime').rglob('*'):
    if path.is_symlink():
        path.resolve().relative_to(resources / 'runtime')
with tempfile.TemporaryDirectory(prefix='studio-bundle-check-') as tmp:
    env = dict(PATH='/usr/bin:/bin', HOME=tmp, TMPDIR=tmp, PYTHONNOUSERSITE='1',
               HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1')
    code = '''import sys
from pathlib import Path
runtime = Path(sys.executable).resolve().parents[1]
Path(sys.prefix).resolve().relative_to(runtime)
import bs4, torch, silero_stress, mlx.core, mlx_audio.tts.utils, ebooklib, soundfile, razdel, lxml.etree
# Loading packaged Silero weights must work offline, before the user downloads Qwen.
from silero_stress import load_accentor
accentor = load_accentor()
print("Standalone engine and bundled stress model are ready; no pip or user packages required.")
'''
    subprocess.run([str(interpreter), '-s', '-B', '-c', code], cwd=tmp, env=env, check=True)
