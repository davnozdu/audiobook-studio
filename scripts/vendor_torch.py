"""Copy only the native libtorch dependency closure, without Python modules."""
from pathlib import Path
import shutil
import subprocess
import sys
source, destination = map(Path, sys.argv[1:3])
destination.mkdir(parents=True, exist_ok=True)
seen = set()
def copy(name):
    path = source / name
    if name in seen: return
    if not path.is_file(): raise ValueError('Missing native Torch dependency: ' + name)
    seen.add(name)
    target = destination / name
    shutil.copy2(path, target)
    for line in subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[1:]:
        dependency = line.strip().split(' (')[0]
        if dependency.startswith(('/System/', '/usr/lib/')): continue
        filename = Path(dependency).name
        if filename == name: continue
        if filename == 'libtorch_python.dylib': raise ValueError('Python bridge must not be shipped')
        copy(filename)
        subprocess.run(['install_name_tool', '-change', dependency, '@loader_path/' + filename, str(target)], check=True)
    subprocess.run(['install_name_tool', '-id', '@rpath/' + name, str(target)], check=True)
copy('libtorch.dylib')
