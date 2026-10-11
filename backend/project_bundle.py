"""Portable projects without machine-specific paths or credentials."""
import json
from pathlib import Path
import shutil
import tempfile
import uuid
import zipfile

PREFIX = 'studio-project://'

def transform(value, change):
    if isinstance(value, dict): return {k: transform(v, change) for k, v in value.items()}
    if isinstance(value, list): return [transform(v, change) for v in value]
    return change(value) if isinstance(value, str) else value

def rewrite_json(root, change):
    for path in root.rglob('*.json'):
        value = json.loads(path.read_text())
        path.write_text(json.dumps(transform(value, change), ensure_ascii=False, indent=2))

def export_project(project, destination, settings):
    project = Path(project).resolve()
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / 'project'
        shutil.copytree(project, root)
        manifest_path = root / 'roles/manifest.json'
        manifest = json.loads(manifest_path.read_text())
        for voice in manifest['voices']:
            ref = voice.get('custom_reference')
            if ref:
                source = Path(ref['path'])
                relative = Path('voice-samples') / (voice['id'] + source.suffix)
                target = root / relative; target.parent.mkdir(exist_ok=True)
                shutil.copy2(source, target)
                ref['path'] = PREFIX + relative.as_posix()
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
        settings = dict(settings)
        if settings.get('music') and Path(settings['music']).is_file():
            source = Path(settings['music']); relative = Path('music') / source.name
            (root / relative).parent.mkdir(exist_ok=True)
            shutil.copy2(source, root / relative)
            settings['music'] = PREFIX + relative.as_posix()
        (root / 'studio-settings.json').write_text(json.dumps(settings, ensure_ascii=False))
        def portable(s):
            if not s.startswith('/'): return s
            try: return PREFIX + Path(s).resolve().relative_to(project).as_posix()
            except ValueError: return s
        rewrite_json(root, portable)
        target = Path(destination)
        temporary = target.with_name(target.name + '.partial')
        try:
            with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED) as archive:
                for file in root.rglob('*'):
                    if file.is_file(): archive.write(file, file.relative_to(root).as_posix())
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)

def import_project(archive, output):
    root = Path(output) / (Path(archive).stem + '-' + uuid.uuid4().hex[:8])
    try:
        with zipfile.ZipFile(archive) as bundle:
            for entry in bundle.infolist():
                path = Path(entry.filename)
                if path.is_absolute() or '..' in path.parts or (entry.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ValueError('Некорректный путь в проекте')
            root.mkdir(parents=True)
            bundle.extractall(root)
        if not (root / 'book.epub').is_file() or not (root / 'roles/manifest.json').is_file():
            raise ValueError('В файле нет проекта Audiobook Studio')
        def restore(s):
            if not s.startswith(PREFIX): return s
            relative = Path(s[len(PREFIX):])
            if relative.is_absolute() or '..' in relative.parts: raise ValueError('Некорректная ссылка в проекте')
            return str(root / relative)
        rewrite_json(root, restore)
        return root
    except Exception:
        if root.exists(): shutil.rmtree(root)
        raise
