"""Provision/check local runtimes, dictionaries and two models beside the launcher."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import shutil
import subprocess
import sys


def checksum(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as reader:
        for block in iter(lambda: reader.read(1024*1024), b''): h.update(block)
    return h.hexdigest()


def valid_model(folder, spec):
    return all((folder / item['path']).is_file() and (folder / item['path']).stat().st_size == item['size']
               and (not item['sha256'] or checksum(folder / item['path']) == item['sha256']) for item in spec['files'])


def ensure_model(root, name, spec, check_only=False):
    target = root / 'models' / name
    if valid_model(target, spec):
        print(f'Модель проверена: {target}', flush=True)
        return target
    if check_only:
        raise ValueError(f'Нет полной проверенной модели: {target}')
    installed = root.parent / 'models' / name
    if not target.exists() and valid_model(installed, spec):
        target.parent.mkdir(parents=True, exist_ok=True)
        # macOS APFS clone: independent files in this kit, not symlinks outside it.
        subprocess.run(['cp', '-cR', str(installed), str(target)], check=True)
        print(f'Использована уже установленная модель: {target}', flush=True)
        return target
    for item in spec['files']:
        path = target / item['path']
        if path.is_file():
            if path.stat().st_size == item['size'] and (not item['sha256'] or checksum(path) == item['sha256']):
                continue
            raise ValueError(f'Файл модели повреждён; не перезаписываю: {path}')
        path.parent.mkdir(parents=True, exist_ok=True)
        partial = path.with_name(path.name + '.partial')
        url = f"https://huggingface.co/{spec['repo']}/resolve/{spec['revision']}/{item['path']}"
        print(f'Скачивается: {path}', flush=True)
        subprocess.run(['curl','-fL','--retry','3','-C','-',url,'-o',str(partial)], check=True)
        if partial.stat().st_size != item['size'] or (item['sha256'] and checksum(partial) != item['sha256']):
            raise ValueError(f'Не совпадает размер/SHA256: {partial}')
        partial.rename(path)
    if not valid_model(target, spec): raise ValueError('Не завершена загрузка модели')
    return target


def runtime(root, name, requirements, modules, check_only):
    python = root / name / 'bin/python'
    if not python.exists():
        if check_only: raise ValueError(f'Не установлено окружение: {python}')
        subprocess.run([sys.executable, '-m','venv',str(root / name)], check=True)
    expression = 'import importlib.util; assert all(importlib.util.find_spec(x) for x in ' + repr(modules) + ')'
    probe = subprocess.run([str(python),'-c',expression], capture_output=True)
    if probe.returncode:
        if check_only: raise ValueError(f'Не все зависимости установлены: {name}')
        env = dict(os.environ, PIP_CACHE_DIR=str(root / '.cache/pip'))
        subprocess.run([str(python),'-m','pip','install','-r',str(root / requirements)], env=env, check=True)
        subprocess.run([str(python),'-c',expression], check=True)
    return python


def setup(root, check_only=False):
    if sys.platform != 'darwin' or platform.machine() != 'arm64': raise ValueError('Комплект рассчитан на macOS Apple Silicon (Python arm64, не Rosetta)')
    if not Path(os.environ.get('AUDIOBOOK_FFMPEG', '/opt/homebrew/bin/ffmpeg')).exists():
        raise ValueError('Не найден встроенный FFmpeg')
    if not check_only:
        for name in ['books', 'results', 'models']:
            (root / name).mkdir(parents=True, exist_ok=True)
    runtime(root,'.venv-mlx','requirements.txt',['mlx_audio','ebooklib','razdel','soundfile','bs4'],check_only)
    runtime(root,'.venv-stress','requirements-stress.txt',['torch','silero_stress'],check_only)
    for name, spec_file in [('Qwen3-TTS-12Hz-1.7B-Ru-Stress-CF-source','stress_model_files.json'),
                            ('Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit','design_model_files.json')]:
        ensure_model(root,name,json.loads((root / spec_file).read_text()),check_only)
    dictionary = root / 'data/stress/dictionary.json'
    if not dictionary.exists():
        if check_only: raise ValueError('Не установлен словарь исключений')
        dictionary.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(root / 'resources/stress_dictionary.json',dictionary)
    binary = root / 'data/stress/russian_accents_full.sacc'
    expected = 'a1ac32606e99f6d8ab8e8ce796b0005b0693908555460656976c54e171658b27'
    if not binary.exists():
        if check_only: raise ValueError('Не установлен бинарный словарь')
        bundled = root / 'resources/russian_accents_full.sacc'
        installed = root.parent / 'qwen-epub-audiobook/data/stress/russian_accents_full.sacc'
        if bundled.is_file() and checksum(bundled) == expected:
            shutil.copyfile(bundled, binary)
        elif installed.is_file() and checksum(installed) == expected:
            subprocess.run(['cp','-c',str(installed),str(binary)],check=True)
        else:
            partial = binary.with_suffix('.sacc.partial')
            subprocess.run(['curl','-fL','--retry','3','-C','-',
                'https://github.com/davnozdu/supertonic-dictionaries/releases/download/russian-v1.1/russian_accents_full.sacc',
                '-o',str(partial)],check=True)
            if partial.stat().st_size != 179200764 or checksum(partial) != expected:
                raise ValueError('Не прошёл проверку бинарный словарь')
            partial.rename(binary)
    if binary.stat().st_size != 179200764 or checksum(binary) != expected:
        raise ValueError('Повреждён бинарный словарь; не перезаписываю')
    music = root / 'resources/Lamplight_and_Paper.mp3'
    from mix_book_music import FIRST_TRACK
    if not music.is_file() or music.stat().st_size != FIRST_TRACK['size'] or checksum(music) != FIRST_TRACK['sha256']:
        raise ValueError('Музыка не совпадает с каталогом MyTTS')
    print('Комплект готов: все данные и модели проверены, TTS-модели ещё не загружались.',flush=True)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parent)
    parser.add_argument('--check-only',action='store_true')
    args=parser.parse_args()
    try: setup(args.root.resolve(),args.check_only)
    except (ValueError,OSError,subprocess.CalledProcessError) as exc: parser.exit(1,f'Ошибка установки: {exc}\n')
