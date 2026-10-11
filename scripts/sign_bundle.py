from pathlib import Path
import subprocess
import sys

app = Path(sys.argv[1])
magic = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
for path in app.rglob('*'):
    if not path.is_file() or path.is_symlink() or 'Sparkle.framework' in path.parts:
        continue
    with path.open('rb') as handle:
        if handle.read(4) not in magic:
            continue
    subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True)
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
