"""Relocate Homebrew FFmpeg/FFprobe and their recursive dylib dependencies."""
from pathlib import Path
import shutil
import subprocess
import sys

destination = Path(sys.argv[1]).resolve()
destination.mkdir(parents=True, exist_ok=True)
libs = destination / 'lib'; libs.mkdir(exist_ok=True)
seen = {}


def dependencies(path):
    lines = subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[1:]
    return [line.strip().split(' (')[0] for line in lines]


def copy(source, target):
    source = source.resolve()
    if source in seen:
        return seen[source]
    if target.exists():
        raise ValueError(f'Library name collision: {target.name}')
    seen[source] = target
    shutil.copy2(source, target)
    target.chmod(0o755)
    for name in dependencies(source):
        if not name.startswith('/') or name.startswith(('/usr/lib/', '/System/')):
            continue
        dependency = Path(name).resolve()
        if dependency == source:
            continue
        copied = copy(dependency, libs / dependency.name)
        relative = '@loader_path/' + ('lib/' if target.parent == destination else '') + copied.name
        subprocess.run(['install_name_tool', '-change', name, relative, str(target)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(target)], check=True)
    return target


for executable in ('ffmpeg', 'ffprobe'):
    copy(Path(shutil.which(executable)), destination / executable)
