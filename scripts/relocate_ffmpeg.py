"""Normalize the bundled FFmpeg kit without accessing a build host's Homebrew."""
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
for target in [root / 'ffmpeg', root / 'ffprobe', *sorted((root / 'lib').glob('*.dylib'))]:
    if target.suffix == '.dylib':
        subprocess.run(['install_name_tool', '-id', '@loader_path/' + target.name, str(target)], check=True)
    lines = subprocess.check_output(['otool', '-L', str(target)], text=True).splitlines()[1:]
    for line in lines:
        name = line.strip().split(' (')[0]
        if not name.startswith('/') or name.startswith(('/usr/lib/', '/System/')):
            continue
        library = root / 'lib' / Path(name).name
        if not library.is_file():
            raise ValueError('FFmpeg dependency absent from kit: ' + name)
        relative = '@loader_path/' + ('lib/' if target.parent == root else '') + library.name
        subprocess.run(['install_name_tool', '-change', name, relative, str(target)], check=True)
