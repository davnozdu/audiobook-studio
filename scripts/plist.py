import os
from pathlib import Path
import plistlib

public_key = Path('sparkle-public-key.txt').read_text().strip()
data = dict(CFBundleIdentifier='com.davnozdu.audiobook-studio', CFBundleName='Audiobook Studio',
    CFBundleDisplayName='Audiobook Studio', CFBundleExecutable='AudiobookStudio', CFBundlePackageType='APPL',
    CFBundleShortVersionString=os.environ['VERSION'], CFBundleVersion=os.environ['BUILD_NUMBER'],
    LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True,
    SUFeedURL='https://github.com/davnozdu/audiobook-studio/releases/latest/download/appcast.xml',
    SUPublicEDKey=public_key, SURequireSignedFeed=True, SUEnableAutomaticChecks=True)
with (Path(os.environ['APP']) / 'Contents/Info.plist').open('wb') as handle:
    plistlib.dump(data, handle)
