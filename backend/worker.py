"""GUI worker protocol: one JSON request on stdin, JSON-line events on stdout.

Credentials are kept in memory, never in argv, project files or event logs.
"""
import contextlib
from datetime import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid

ENGINE = Path(__file__).resolve().parent / 'engine'
sys.path.insert(0, str(ENGINE))
import prepare_qwen as q
from characters import analyze, apply_profiles


def emit(kind, **data):
    print(json.dumps(dict(type=kind, **data), ensure_ascii=False), flush=True)


def stage(message, fraction=0):
    emit('progress', message=message, fraction=fraction)


def require_key(request):
    if not request.get('key', '').strip():
        raise ValueError('Введите Ollama API key в настройках')
    return request['key'].strip()


def verify(project, require_resolved=True):
    source = q.load(project / 'roles/source.json')
    manifest = q.load(project / 'roles/manifest.json')
    book = project / 'book.epub'
    if hashlib.sha256(book.read_bytes()).hexdigest() != manifest['book']['input_sha256']:
        raise ValueError('Исходная книга не соответствует ролям')
    q.check_manifest(manifest, source)
    if require_resolved and any(s['speaker'] is None for s in manifest['segments']):
        raise ValueError('Есть неопределённые роли. Исправьте разметку перед сборкой')
    return manifest, source


def apply_role_edits(manifest, source, edits):
    lookup = {v['id']: v['voice_id'] for v in manifest['voices']}
    if not set(edits) <= {s['id'] for s in manifest['segments']}:
        raise ValueError('Неизвестный фрагмент')
    for segment in manifest['segments']:
        if segment['id'] in edits:
            speaker = edits[segment['id']]
            if speaker not in lookup:
                raise ValueError('Выберите говорящего из списка персонажей')
            segment.update(speaker=speaker, voice_id=lookup[speaker], confidence='high',
                           needs_review=False, reason='Проверено пользователем в GUI')
    q.check_manifest(manifest, source)
    manifest['stats']['unresolved_segments'] = sum(s['speaker'] is None for s in manifest['segments'])
    manifest['stats']['review_segments'] = sum(s['needs_review'] for s in manifest['segments'])
    return manifest


def prepare(request):
    from types import SimpleNamespace
    key = require_key(request)
    book = Path(request['book']).resolve()
    if not book.is_file() or book.suffix.lower() != '.epub':
        raise ValueError('Выберите EPUB-книгу')
    base = Path(request['output']).expanduser().resolve()
    project = base / (book.stem + '-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    folder = project / 'roles'
    folder.mkdir(parents=True)
    shutil.copy2(book, project / 'book.epub')
    emit('project', path=str(project))
    source = q.read_source(project / 'book.epub')
    q.write(folder / 'source.json', source)
    args = SimpleNamespace(command='run', model=request.get('model', 'deepseek-v4.1-flash'),
        endpoint='https://ollama.com', no_think=True, max_tokens=16000, timeout=240,
        target_chars=220, max_chars=360)
    cast = {'characters': []}
    chunks = q.batches(source['paragraphs'], 16000)
    for i, batch in enumerate(chunks):
        stage(f'Поиск персонажей · {i+1}/{len(chunks)}', .45 * i / len(chunks))
        prompt = q.cast_prompt(dict(source, paragraphs=batch))
        prompt += '\nВерни полный накопленный реестр, сохраняя ID, имена, пол и голоса. Объединяй прозвища в aliases. Реестр: ' + json.dumps(cast, ensure_ascii=False)
        previous = {c['id']: c for c in cast['characters']}
        def validate(data):
            value = q.validate_cast(data)
            current = {c['id']: c for c in value['characters']}
            if not set(previous) <= set(current):
                raise ValueError('Потеряны персонажи')
            for cid, old in previous.items():
                if current[cid]['name'] != old['name'] or current[cid]['gender'] != old['gender']:
                    raise ValueError('Изменена личность персонажа')
                current[cid]['voice_description'] = old['voice_description']
                current[cid]['aliases'] = list(dict.fromkeys(old['aliases'] + current[cid]['aliases']))
            return q.validate_cast(value)
        with contextlib.redirect_stdout(sys.stderr):
            cast = q.obtain(folder, f'cast-{i+1}', prompt, validate, args, key)
    labels = []
    chunks = q.batches(source['paragraphs'], 4000)
    for i, batch in enumerate(chunks):
        stage(f'Расстановка ролей · {i+1}/{len(chunks)}', .45 + .55 * i / len(chunks))
        with contextlib.redirect_stdout(sys.stderr):
            result = q.obtain(folder, f'roles-{i+1}', q.roles_prompt(source, cast, batch, labels[-5:]),
                              lambda data: q.validate_roles(data, batch, cast), args, key)
        labels.extend(result)
    q.write(folder / 'cast.json', dict(cast, input_sha256=source['input_sha256']))
    q.write(folder / 'roles.json', {'paragraphs': labels})
    with contextlib.redirect_stdout(sys.stderr):
        q.export_project(folder, source, cast, labels, args)
    unresolved = sum(s['speaker'] is None for s in q.load(folder / 'manifest.json')['segments'])
    if unresolved:
        emit('done', path=str(project), message=f'Проверьте роли: {unresolved} неопределённых фрагментов')
    else:
        emit('done', path=str(project), message='Персонажи и роли готовы')


def run_step(python, script, options, project, key=None, progress=None):
    env = dict(os.environ)
    env.pop('OLLAMA_API_KEY', None)
    env['PATH'] = '/opt/homebrew/bin:/usr/local/bin:' + env.get('PATH', '')
    if key:
        env['OLLAMA_API_KEY'] = key
    child = subprocess.Popen([str(python), '-u', str(ENGINE / script), *map(str, options)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    emit('child', pid=child.pid)
    with (project / 'run.log').open('a', encoding='utf-8') as log:
        for line in child.stdout:
            if key:
                line = line.replace(key, '[REDACTED]')
            log.write(line); log.flush()
            emit('log', message=line.rstrip()[-2000:])
            if progress:
                progress(line)
    if child.wait():
        raise ValueError(f'Этап {script} завершился ошибкой. См. run.log')
    emit('child', pid=0)


class Speed:
    """Recent measured throughput; text-weighted estimate of remaining synthesis."""
    pattern = re.compile(r'(seg\d+) .*?: ([\d.]+)s audio / ([\d.]+)s generation;')
    def __init__(self, manifest):
        self.weights = {s['id']: max(1, len(s['text'])) for s in manifest['segments']}
        self.total = sum(self.weights.values())
        self.done = set()
        self.samples = []

    def update(self, line):
        match = self.pattern.search(line)
        if not match:
            return None
        sid, audio, elapsed = match.groups()
        if sid not in self.weights or sid in self.done or float(elapsed) <= 0:
            return None
        self.done.add(sid)
        self.samples.append((float(audio), float(elapsed), self.weights[sid]))
        recent = self.samples[-12:]
        seconds = sum(x[1] for x in recent)
        weight = sum(x[2] for x in recent)
        completed = sum(self.weights[x] for x in self.done)
        return dict(speed=sum(x[0] for x in recent) / seconds,
                    eta=max(0, self.total - completed) * seconds / weight,
                    fraction=completed / self.total, completed=len(self.done), total=len(self.weights))


def build(request):
    project = Path(request['project']).resolve()
    manifest, source = verify(project)
    runtime = Path(request['runtime']).expanduser().resolve()
    py = runtime / '.venv-mlx/bin/python'
    stress = runtime / '.venv-stress/bin/python'
    if not py.is_file() or not stress.is_file():
        raise ValueError('Сначала установите движок или выберите готовый комплект в настройках')
    if (project / 'audio').exists():
        raise ValueError('Аудио уже существует. Создайте копию проекта для повторной сборки')
    model = runtime / 'models/Qwen3-TTS-12Hz-1.7B-Ru-Stress-CF-source'
    design = runtime / 'models/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit'
    for path in (model, design, runtime / 'data/stress/russian_accents_full.sacc'):
        if not path.exists():
            raise ValueError('Не установлены модели или словарь; выполните установку движка')
    music = None
    if request.get('music_enabled', True):
        selected = Path(request.get('music') or ENGINE / 'resources/Lamplight_and_Paper.mp3').resolve()
        if not selected.is_file():
            raise ValueError('Не найден музыкальный файл')
        music_dir = project / 'music'; music_dir.mkdir(exist_ok=True)
        music = music_dir / selected.name
        if selected != music:
            shutil.copy2(selected, music)
    stage('Подготовка предложений и EPUB')
    run_step(py, 'audiobook_epub.py', ['prepare', '--manifest', project / 'roles/manifest.json',
             '--out', project / 'source', '--highlight', 'sentence'], project)
    prepared = project / 'source/manifest.json'
    stage('Нормализация текста · словарь + Silero')
    key = require_key(request) if request.get('cloud_stress') else None
    run_step(stress, 'prepare_silero.py', ['--manifest', prepared, '--dictionary-dir', runtime / 'data/stress',
             '--llm-disputes', 'run' if key else 'off'], project, key)
    key = None
    stage('Создание голосов и загрузка модели · оценка времени появится после первых фрагментов')
    speed = Speed(q.load(prepared))
    def progress(line):
        metrics = speed.update(line)
        if metrics:
            emit('metrics', message='Озвучивание книги', **metrics)
    run_step(py, 'synthesize_qwen_mlx.py', ['--manifest', prepared, '--model', model,
        '--design-model', design, '--ephemeral-voices', '--mode', 'clone', '--rab-generation',
        '--temperature', '.9', '--stress-marks', 'keep', '--whole-book', '--out', project / 'audio'],
        project, progress=progress)
    stage('Нормализация громкости по ролям')
    run_step(py, 'normalize_book_audio.py', ['--audio-dir', project / 'audio', '--out', project / 'audio-normalized'], project)
    final_audio = project / 'audio-normalized'
    if music:
        stage('Зацикливание и наложение фоновой музыки')
        run_step(py, 'mix_book_music.py', ['--audio-dir', final_audio, '--out', project / 'audio-music',
            '--music', music, '--volume-percent', request.get('music_volume', 5)], project)
        final_audio = project / 'audio-music'
    stage('Сборка отдельного M4B и EPUB с синхронным аудио')
    run_step(py, 'audiobook_epub.py', ['package', '--manifest', prepared, '--audio-dir', final_audio,
             '--out', project / 'result'], project)
    emit('done', path=str(project), message='Готовы book.m4b и book-read-along.epub')


def main():
    # All subprocesses inherit this group, so the GUI can cancel the whole job.
    try:
        os.setpgid(0, 0)
    except PermissionError:
        pass
    request = json.loads(sys.stdin.readline())
    action = request['action']
    if action == 'prepare':
        prepare(request)
    elif action in ('characters', 'save'):
        project = Path(request['project']).resolve()
        manifest, source = verify(project, require_resolved=action == 'characters')
        if action == 'characters':
            profiles = analyze(manifest, source, require_key(request), request.get('model', 'deepseek-v4.1-flash'),
                               request.get('web_search', False), q, stage)
        else:
            manifest = apply_role_edits(manifest, source, request.get('edits', {}))
            profiles = request['profiles']
        updated = apply_profiles(manifest, profiles, source, q)
        q.write(project / 'roles/manifest.json', updated)
        q.write(project / 'roles/voices.json', {'voices': updated['voices']})
        q.write(project / 'characters.json', profiles)
        emit('done', path=str(project), message='Карточки сохранены, голоса обновлены')
    elif action == 'sample':
        project = Path(request['project']).resolve()
        manifest, source = verify(project)
        voice = next((v for v in manifest['voices'] if v['id'] == request['character']), None)
        if not voice:
            raise ValueError('Неизвестный персонаж')
        if request.get('remove'):
            voice.pop('custom_reference', None)
        else:
            text = request.get('text', '').strip()
            if not text:
                raise ValueError('Введите точный текст, произнесённый в образце')
            sample = Path(request['sample']).resolve()
            directory = project / 'voice-samples'; directory.mkdir(exist_ok=True)
            target = directory / (voice['id'] + '.wav')
            temp = target.with_suffix('.tmp.wav')
            subprocess.run([os.environ.get('AUDIOBOOK_FFMPEG', '/opt/homebrew/bin/ffmpeg'), '-hide_banner', '-loglevel', 'error', '-y',
                '-i', str(sample), '-ac', '1', '-ar', '24000', '-c:a', 'pcm_s16le', str(temp)],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            probe = subprocess.check_output([os.environ.get('AUDIOBOOK_FFPROBE', '/opt/homebrew/bin/ffprobe'), '-v', 'error',
                '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', str(temp)], text=True)
            duration = float(probe)
            if not 3 <= duration <= 30:
                temp.unlink()
                raise ValueError('Выберите чистый образец одного голоса длительностью 3–30 секунд')
            temp.replace(target)
            voice['custom_reference'] = dict(path=str(target), text=text, seconds=duration,
                                             sha256=hashlib.sha256(target.read_bytes()).hexdigest())
        q.write(project / 'roles/manifest.json', manifest)
        q.write(project / 'roles/voices.json', {'voices': manifest['voices']})
        emit('done', path=str(project), message='Образец голоса обновлён')
    elif action == 'roles-save':
        project = Path(request['project']).resolve()
        manifest, source = verify(project, require_resolved=False)
        manifest = apply_role_edits(manifest, source, request.get('edits', {}))
        q.write(project / 'roles/manifest.json', manifest)
        emit('done', path=str(project), message='Назначения ролей сохранены')
    elif action == 'voice-preview':
        from setup_audiobook import ensure_model
        from voice_designer import validate_request
        text, description = validate_request(request)
        if request.get('casting'):
            from synthesize_qwen_mlx import reference_instruction
            description = reference_instruction(request['casting'])
        root = Path(request['runtime']).expanduser().resolve()
        root.mkdir(parents=True, exist_ok=True)
        stage('Проверка модели VoiceDesign')
        with contextlib.redirect_stdout(sys.stderr):
            model = ensure_model(root, 'Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit', q.load(ENGINE / 'design_model_files.json'))
        output = root.parent / 'VoiceLab' / uuid.uuid4().hex
        output.mkdir(parents=True)
        q.write(output / 'request.json', dict(text=text, description=description, seed=request.get('seed', 17001)))
        stage('Генератор голосов · создание тестового образца')
        run_step(request['python'], 'voice_designer.py', ['--request', output / 'request.json',
            '--model', model, '--out', output], output)
        emit('sample', path=str(output / 'sample.wav'), text=text, description=description,
             character=request.get('character', ''))
        emit('done', message='Образец голоса готов · VoiceDesign выгружен')
    elif action == 'build':
        build(request)
    elif action == 'setup':
        root = Path(request['runtime']).expanduser().resolve()
        root.mkdir(parents=True, exist_ok=True)
        # A single bundled interpreter includes both MLX and Silero dependencies.
        # Compatibility paths preserve the existing engine without separate venvs.
        for name in ('.venv-mlx', '.venv-stress'):
            executable = root / name / 'bin/python'
            executable.parent.mkdir(parents=True, exist_ok=True)
            if executable.is_symlink():
                executable.unlink()
            elif executable.exists():
                raise ValueError('Каталог движка занят другим Python-окружением')
            executable.symlink_to(Path(request['python']).resolve())
        for path in ENGINE.rglob('*'):
            if path.is_file() and '__pycache__' not in path.parts:
                target = root / path.relative_to(ENGINE)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
        stage('Проверка встроенного движка · загрузка необходимых моделей')
        run_step(request['python'], 'setup_audiobook.py', ['--root', root], root)
        emit('done', message='Движок установлен')
    else:
        raise ValueError('Неизвестная команда')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        # Never expose raw HTTP bodies, request content or credential-bearing tracebacks.
        if isinstance(exc, ValueError):
            message = str(exc)
        else:
            message = f'{type(exc).__name__}: операция не завершена. Проверьте настройки и run.log'
        emit('error', message=message)
        sys.exit(1)
