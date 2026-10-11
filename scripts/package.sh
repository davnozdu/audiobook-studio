#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.5.7}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP="dist/Audiobook Studio.app"
SPARKLE_VERSION=2.9.6
mkdir -p .build-tools dist
if [ ! -f .build-tools/Sparkle.framework/Sparkle ]; then
  curl -fL --retry 3 "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" -o .build-tools/sparkle.tar.xz
  echo '52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192  .build-tools/sparkle.tar.xz' | shasum -a 256 -c -
  tar -xf .build-tools/sparkle.tar.xz -C .build-tools
fi
# Always create a clean app: no interpreter or stale Python resources from earlier versions.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/engine/resources" "$APP/Contents/Resources/licenses"
bash scripts/icon.sh
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library Sources/StudioApp.swift -F .build-tools -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$APP/Contents/MacOS/AudiobookStudio"
ditto .build-tools/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
xcodebuild -downloadComponent MetalToolchain
(cd native && xcodebuild -list -json) > .build-tools/native-schemes.json
cat .build-tools/native-schemes.json
NATIVE_SCHEME="$(python3 -c 'import json; d=json.load(open(".build-tools/native-schemes.json")); s=(d.get("workspace") or d.get("project"))["schemes"]; print(next(x for x in ["StudioEngine", "StudioNative", "native", "StudioNative-Package", "native-Package"] if x in s))')"
(cd native && xcodebuild build -scheme "$NATIVE_SCHEME" -configuration Release -destination "platform=macOS,arch=arm64" -derivedDataPath ../.build-tools/native-build MACOSX_DEPLOYMENT_TARGET=14.0 CODE_SIGNING_ALLOWED=NO) > .build-tools/native-build.log 2>&1 || { tail -100 .build-tools/native-build.log; exit 1; }
NATIVE_BIN=".build-tools/native-build/Build/Products/Release"
cp "$NATIVE_BIN/StudioEngine" "$APP/Contents/MacOS/StudioEngine"
# Keep data bundles in the standard Resources location, outside nested executable code.
for bundle in "$NATIVE_BIN"/*.bundle; do
  [ ! -d "$bundle" ] || ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
cp backend/engine/{design_model_files.json,stress_model_files.json,supertonic_rules.json} "$APP/Contents/Resources/engine/"
cp backend/engine/resources/*.{json,mp3} "$APP/Contents/Resources/engine/resources/"
# Reuse the checked ARM FFmpeg kit built on macOS 15; newer Homebrew bottles require macOS 26.
if [ ! -d .build-tools/ffmpeg-kit/bin ]; then
  curl -fL --retry 3 https://github.com/davnozdu/audiobook-studio/releases/download/v0.4.0/AudiobookStudio-0.4.0-arm64.zip -o .build-tools/ffmpeg-source.zip
  echo '1380400c98f1e78204fd9e19aef66aeb79817f6b5bc03414f080fad41fa6578d  .build-tools/ffmpeg-source.zip' | shasum -a 256 -c -
  unzip -q .build-tools/ffmpeg-source.zip 'Audiobook Studio.app/Contents/Resources/runtime/bin/*' -d .build-tools/ffmpeg-kit
  mv '.build-tools/ffmpeg-kit/Audiobook Studio.app/Contents/Resources/runtime/bin' .build-tools/ffmpeg-kit/bin
fi
ditto .build-tools/ffmpeg-kit/bin "$APP/Contents/Resources/runtime/bin"
python3 scripts/relocate_ffmpeg.py "$APP/Contents/Resources/runtime/bin"
# Python is exclusively a build tool. Export offline Silero weights and link a C++ executable to libtorch.
if [ ! -x .build-tools/stress-export/bin/python3 ]; then python3 -m venv .build-tools/stress-export; fi
BUILD_PY=.build-tools/stress-export/bin/python3
"$BUILD_PY" -m pip install 'torch==2.14.1' 'silero-stress==1.5'
"$BUILD_PY" scripts/export_native_stress.py "$APP/Contents/Resources/engine/silero"
TORCH_ROOT="$("$BUILD_PY" -c 'import pathlib,torch;print(pathlib.Path(torch.__file__).parent)')"
clang++ -O2 -std=c++20 -mmacosx-version-min=14.0 -arch arm64 native/stress/StudioStress.mm -I "$TORCH_ROOT/include" -I "$TORCH_ROOT/include/torch/csrc/api/include" -L "$TORCH_ROOT/lib" -ltorch -ltorch_cpu -lc10 -framework Foundation -Wl,-rpath,@executable_path/../Frameworks/torch -o "$APP/Contents/MacOS/StudioStress"
python3 scripts/vendor_torch.py "$TORCH_ROOT/lib" "$APP/Contents/Frameworks/torch"
cp "$TORCH_ROOT/../torch-"*.dist-info/licenses/LICENSE "$APP/Contents/Resources/licenses/PyTorch.txt"
cp backend/engine/THIRD_PARTY.md "$APP/Contents/Resources/licenses/THIRD_PARTY.md"
for dependency in .build-tools/native-build/SourcePackages/checkouts/*; do
  for license in "$dependency"/LICENSE "$dependency"/LICENSE.md "$dependency"/LICENSE.txt; do
    if [ -f "$license" ]; then cp "$license" "$APP/Contents/Resources/licenses/$(basename "$dependency").txt"; break; fi
  done
done
DICTIONARY="$APP/Contents/Resources/engine/resources/russian_accents_full.sacc"
curl -fL --retry 3 https://github.com/davnozdu/supertonic-dictionaries/releases/download/russian-v1.1/russian_accents_full.sacc -o "$DICTIONARY"
echo "a1ac32606e99f6d8ab8e8ce796b0005b0693908555460656976c54e171658b27  $DICTIONARY" | shasum -a 256 -c -
export VERSION BUILD_NUMBER APP
python3 scripts/plist.py
xattr -cr "$APP"
python3 scripts/sign_bundle.py "$APP"
codesign --verify --deep --strict "$APP"
python3 scripts/check_bundle.py "$APP"
"$APP/Contents/Resources/runtime/bin/ffmpeg" -version
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/AudiobookStudio-$VERSION-arm64.zip"
