"""Package resized PNG representations into the standard macOS ICNS container."""
from pathlib import Path
import struct

representations = {'icp4': '16x16', 'icp5': '32x32', 'icp6': '32x32@2x',
                   'ic07': '128x128', 'ic08': '256x256', 'ic09': '512x512', 'ic10': '512x512@2x',
                   'ic11': '16x16@2x', 'ic12': '32x32@2x', 'ic13': '128x128@2x', 'ic14': '256x256@2x'}
payload = b''
for kind, name in representations.items():
    image = (Path('.build-tools/AppIcon.iconset') / f'icon_{name}.png').read_bytes()
    payload += struct.pack('>4sI', kind.encode(), len(image) + 8) + image
Path('assets/AppIcon.icns').write_bytes(struct.pack('>4sI', b'icns', len(payload) + 8) + payload)
