"""Verify a native distribution offline, with an empty home and no user dependencies."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
app = Path(sys.argv[1]).resolve()
for path in app.rglob('*'):
    if path.is_symlink(): path.resolve().relative_to(app)
    if path.suffix in {'.py', '.pyc'} or path.name.startswith(('python', 'libpython')):
        raise ValueError('Python runtime unexpectedly shipped: ' + str(path))
    if path.is_file():
        with path.open('rb') as reader: magic = reader.read(4)
        if magic == b'\xcf\xfa\xed\xfe':
            for line in subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[1:]:
                dependency = line.strip().split(' (')[0]
                if dependency.startswith('/') and not dependency.startswith(('/usr/lib/', '/System/')):
                    raise ValueError('External runtime dependency: ' + dependency)
with tempfile.TemporaryDirectory(prefix='studio-native-check-') as tmp:
    env = dict(PATH='/usr/bin:/bin', HOME=tmp, TMPDIR=tmp, HF_HUB_OFFLINE='1')
    subprocess.run([str(app / 'Contents/MacOS/StudioEngine'), '--self-check',
                    str(app / 'Contents/Resources/engine')], cwd=tmp, env=env, check=True)
print('Native Swift/MLX and C++ Silero bundle checked offline; no Python runtime.')
