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
import time


def report_status(message):
    print('STUDIO_PROGRESS ' + json.dumps(dict(message=message), ensure_ascii=False), flush=True)


def checksum(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as reader:
        for block in iter(lambda: reader.read(1024*1024), b''): h.update(block)
    return h.hexdigest()


def valid_model(folder, spec):
    return all((folder / item['path']).is_file() and (folder / item['path']).stat().st_size == item['size']
               and (not item['sha256'] or checksum(folder / item['path']) == item['sha256']) for item in spec['files'])


def ensure_model(root, name, spec, check_only=False, progress=None):
    target = root / 'models' / name
    total = sum(item['size'] for item in spec['files'])
    done = 0
    def report(message, fraction=0):
        if progress:
            progress(message, fraction)
        else:
            print('STUDIO_PROGRESS ' + json.dumps(dict(message=message, fraction=fraction), ensure_ascii=False), flush=True)
    label = 'VoiceDesign' if 'VoiceDesign' in name else 'модель озвучки'
    installed = root.parent / 'models' / name
    if not target.exists() and installed.exists():
        report(f'Проверка ранее установленной модели · {label}')
        if valid_model(installed, spec):
            target.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['cp', '-cR', str(installed), str(target)], check=True)
    for item in spec['files']:
        path = target / item['path']
        report(f'Проверка файлов {label} · {item["path"]}', done / total)
        if path.is_file():
            if path.stat().st_size != item['size'] or (item['sha256'] and checksum(path) != item['sha256']):
                raise ValueError(f'Файл модели повреждён; не перезаписываю: {path}')
            done += item['size']
            continue
        if check_only:
            raise ValueError(f'Нет файла модели: {path}')
        path.parent.mkdir(parents=True, exist_ok=True)
        partial = path.with_name(path.name + '.partial')
        url = f"https://huggingface.co/{spec['repo']}/resolve/{spec['revision']}/{item['path']}"
        start_size = partial.stat().st_size if partial.exists() else 0
        start = time.monotonic()
        child = subprocess.Popen(['curl', '-fsSL', '--connect-timeout', '30', '--speed-limit', '1024', '--speed-time', '90', '--retry', '3', '-C', '-', url, '-o', str(partial)],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        while child.poll() is None:
            size = partial.stat().st_size if partial.exists() else 0
            seconds = max(time.monotonic() - start, .01)
            rate = max(0, size - start_size) / seconds
            timing = f' · {rate/1024**2:.1f} МБ/с' if rate else ' · соединение с сервером'
            report(f'Скачивание {label} · {item["path"]} · {(done+size)/1024**2:.0f} / {total/1024**2:.0f} МБ' + timing,
                   min(1, (done + size) / total))
            time.sleep(1)
        error = child.stderr.read(); child.stderr.close()
        if child.returncode:
            raise ValueError(f'Не удалось скачать {label}: ' + error[-500:])
        report(f'Проверка контрольной суммы {label} · {item["path"]}', (done + item['size']) / total)
        if partial.stat().st_size != item['size'] or (item['sha256'] and checksum(partial) != item['sha256']):
            raise ValueError(f'Не совпадает размер/SHA256: {partial}')
        partial.rename(path)
        done += item['size']
    report(f'{label} установлена · файлы проверены', 1)
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


def bundled_runtime_check():
    # This path is used by the app: validation only, never venv/pip/installation.
    modules = ['mlx.core', 'mlx_audio.tts.utils', 'torch', 'silero_stress',
               'ebooklib', 'razdel', 'soundfile', 'bs4', 'lxml.etree']
    expression = 'import importlib; [importlib.import_module(x) for x in ' + repr(modules) + ']'
    probe = subprocess.run([sys.executable, '-s', '-B', '-c', expression], capture_output=True, text=True)
    if probe.returncode:
        raise ValueError('Встроенный движок повреждён или несовместим с macOS. Установите полную сборку приложения; зависимости автоматически не устанавливаются.')
    return Path(sys.executable)


def setup(root, check_only=False, bundled_engine=None):
    engine = Path(bundled_engine).resolve() if bundled_engine else root
    report_status('Подготовка локального движка · проверка совместимости Mac')
    if sys.platform != 'darwin' or platform.machine() != 'arm64': raise ValueError('Комплект рассчитан на macOS Apple Silicon (Python arm64, не Rosetta)')
    if not Path(os.environ.get('AUDIOBOOK_FFMPEG', '/opt/homebrew/bin/ffmpeg')).exists():
        raise ValueError('Не найден встроенный FFmpeg')
    if not check_only:
        for name in ['books', 'results', 'models']:
            (root / name).mkdir(parents=True, exist_ok=True)
    report_status('Проверка встроенного движка озвучки MLX')
    if bundled_engine:
        bundled_runtime_check()
        report_status('Встроенный движок готов · установка зависимостей не требуется')
    else:
        runtime(root,'.venv-mlx','requirements.txt',['mlx_audio','ebooklib','razdel','soundfile','bs4'],check_only)
        report_status('Проверка движка ударений Silero')
        runtime(root,'.venv-stress','requirements-stress.txt',['torch','silero_stress'],check_only)
    for name, spec_file in [('Qwen3-TTS-12Hz-1.7B-Ru-Stress-CF-source','stress_model_files.json'),
                            ('Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit','design_model_files.json')]:
        ensure_model(root,name,json.loads((engine / spec_file).read_text()),check_only)
    report_status('Подготовка словарей ударений')
    dictionary = root / 'data/stress/dictionary.json'
    if not dictionary.exists():
        if check_only: raise ValueError('Не установлен словарь исключений')
        dictionary.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(engine / 'resources/stress_dictionary.json',dictionary)
    binary = root / 'data/stress/russian_accents_full.sacc'
    expected = 'a1ac32606e99f6d8ab8e8ce796b0005b0693908555460656976c54e171658b27'
    if not binary.exists():
        if check_only: raise ValueError('Не установлен бинарный словарь')
        bundled = engine / 'resources/russian_accents_full.sacc'
        installed = root.parent / 'qwen-epub-audiobook/data/stress/russian_accents_full.sacc'
        if bundled.is_file() and checksum(bundled) == expected:
            shutil.copyfile(bundled, binary)
        elif installed.is_file() and checksum(installed) == expected:
            subprocess.run(['cp','-c',str(installed),str(binary)],check=True)
        else:
            if bundled_engine: raise ValueError('В полной сборке отсутствует встроенный словарь ударений. Переустановите приложение.')
            partial = binary.with_suffix('.sacc.partial')
            subprocess.run(['curl','-fL','--retry','3','-C','-',
                'https://github.com/davnozdu/supertonic-dictionaries/releases/download/russian-v1.1/russian_accents_full.sacc',
                '-o',str(partial)],check=True)
            if partial.stat().st_size != 179200764 or checksum(partial) != expected:
                raise ValueError('Не прошёл проверку бинарный словарь')
            partial.rename(binary)
    if binary.stat().st_size != 179200764 or checksum(binary) != expected:
        raise ValueError('Повреждён бинарный словарь; не перезаписываю')
    report_status('Проверка встроенной музыки')
    music = engine / 'resources/Lamplight_and_Paper.mp3'
    from mix_book_music import FIRST_TRACK
    if not music.is_file() or music.stat().st_size != FIRST_TRACK['size'] or checksum(music) != FIRST_TRACK['sha256']:
        raise ValueError('Музыка не совпадает с каталогом MyTTS')
    print('Комплект готов: все данные и модели проверены, TTS-модели ещё не загружались.',flush=True)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parent)
    parser.add_argument('--check-only',action='store_true')
    parser.add_argument('--bundled-engine',type=Path)
    args=parser.parse_args()
    try: setup(args.root.resolve(),args.check_only,args.bundled_engine)
    except (ValueError,OSError,subprocess.CalledProcessError) as exc: parser.exit(1,f'Ошибка установки: {exc}\n')
