import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', ns)
version = os.environ['VERSION']
archive = Path(f'dist/AudiobookStudio-{version}-arm64.zip')
signer = '.build-tools/bin/sign_update'
keyfile = os.environ['SPARKLE_KEY_FILE']
signature = subprocess.check_output([signer, '--ed-key-file', keyfile, '-p', str(archive)], text=True).strip()
rss = ET.Element('rss', version='2.0')
channel = ET.SubElement(rss, 'channel'); ET.SubElement(channel, 'title').text = 'Audiobook Studio'
item = ET.SubElement(channel, 'item'); ET.SubElement(item, 'title').text = f'Audiobook Studio {version}'
ET.SubElement(item, '{'+ns+'}version').text = os.environ['BUILD_NUMBER']
ET.SubElement(item, '{'+ns+'}shortVersionString').text = version
ET.SubElement(item, '{'+ns+'}minimumSystemVersion').text = '15.0'
ET.SubElement(item, '{'+ns+'}hardwareRequirements').text = 'arm64'
ET.SubElement(item, 'enclosure', url=f'https://github.com/davnozdu/audiobook-studio/releases/download/v{version}/{archive.name}',
              length=str(archive.stat().st_size), type='application/octet-stream', attrib={'{'+ns+'}edSignature': signature})
feed = Path('dist/appcast.xml'); ET.ElementTree(rss).write(feed, encoding='utf-8', xml_declaration=True)
subprocess.run([signer, '--ed-key-file', keyfile, str(feed)], check=True)
