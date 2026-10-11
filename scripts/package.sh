#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP="dist/Audiobook Studio.app"
SPARKLE_VERSION=2.9.6
mkdir -p .build-tools dist
if [ ! -f .build-tools/Sparkle.framework/Sparkle ]; then
  curl -fL --retry 3 "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" -o .build-tools/sparkle.tar.xz
  echo '52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192  .build-tools/sparkle.tar.xz' | shasum -a 256 -c -
  tar -xf .build-tools/sparkle.tar.xz -C .build-tools
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
bash scripts/icon.sh
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library Sources/StudioApp.swift -F .build-tools -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$APP/Contents/MacOS/AudiobookStudio"
ditto .build-tools/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
ditto backend "$APP/Contents/Resources/backend"
mkdir -p "$APP/Contents/Resources/runtime"
if [ ! -x "$APP/Contents/Resources/runtime/python/bin/python3" ]; then
  curl -fL --retry 3 'https://github.com/astral-sh/python-build-standalone/releases/download/20261009/cpython-3.11.17%2B20261009-aarch64-apple-darwin-install_only.tar.gz' -o .build-tools/python.tar.gz
  tar -xf .build-tools/python.tar.gz -C "$APP/Contents/Resources/runtime"
fi
# Resolve and install all dependencies on the build runner, including when reusing a build directory.
"$APP/Contents/Resources/runtime/python/bin/python3" -m pip install -r backend/engine/requirements.txt -r backend/engine/requirements-stress.txt
if [ ! -x "$APP/Contents/Resources/runtime/bin/ffmpeg" ]; then
  python3 scripts/vendor_ffmpeg.py "$APP/Contents/Resources/runtime/bin"
fi
DICTIONARY="$APP/Contents/Resources/backend/engine/resources/russian_accents_full.sacc"
if [ ! -f "$DICTIONARY" ]; then
  curl -fL --retry 3 https://github.com/davnozdu/supertonic-dictionaries/releases/download/russian-v1.1/russian_accents_full.sacc -o "$DICTIONARY"
fi
echo "a1ac32606e99f6d8ab8e8ce796b0005b0693908555460656976c54e171658b27  $DICTIONARY" | shasum -a 256 -c -
export VERSION BUILD_NUMBER APP
python3 scripts/plist.py
# Sign Mach-O dependencies first, then the app; no Apple account needed for test builds.
python3 scripts/sign_bundle.py "$APP"
codesign --verify --deep --strict "$APP"
python3 scripts/check_bundle.py "$APP"
"$APP/Contents/Resources/runtime/bin/ffmpeg" -version
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/AudiobookStudio-$VERSION-arm64.zip"
