#!/bin/bash
set -euo pipefail
mkdir -p .build-tools/AppIcon.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/AppIcon.png --out ".build-tools/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" assets/AppIcon.png --out ".build-tools/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
python3 scripts/icon.py
