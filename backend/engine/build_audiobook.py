"""Universal EPUB -> role-labelled, accented M4B + EPUB with background music."""
import argparse
import getpass
from datetime import datetime
import json
import hashlib
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
from types import SimpleNamespace

import prepare_qwen as q
from prepare_silero import choose_cloud


def input_path(value, root, books=False):
    value = value.strip()
    if value.startswith(('"', "'")) or '\\ ' in value:
        parts = shlex.split(value)
        if len(parts) != 1: raise ValueError('Укажите один путь')
        value = parts[0]
    path = Path(value).expanduser()
    if not path.is_absolute():
        candidate = root / 'books' / path if books else root / path
        path = candidate if candidate.exists() or not books else root / path
    return path.resolve()


def prepare_roles(book, folder, cloud, key, test=False):
    if not cloud:
        raise ValueError('Без LLM используйте готовый manifest ролей: переключение всех героев на рассказчика запрещено')
    source = q.read_source(book)
    if test:
        # Test only whole paragraphs; avoid processing the entire novel first.
        paragraphs, size = [], 0
        for p in source['paragraphs']:
            paragraphs.append(p); size += len(p['text'])
            if size >= 4200: break
        source['paragraphs'] = paragraphs
        used = {p['chapter_id'] for p in paragraphs}
        source['chapters'] = [c for c in source['chapters'] if c['id'] in used]
    args = SimpleNamespace(command='run',model='deepseek-v4.1-flash',endpoint='https://ollama.com',
        no_think=True,max_tokens=16000,timeout=180,target_chars=220,max_chars=360)
    folder.mkdir(parents=True,exist_ok=True)
    q.write(folder / 'source.json',source)
    labels=[]
    if cloud:
        cast={'characters': []}
        chunks=q.batches(source['paragraphs'],16000)
        for i, batch in enumerate(chunks,1):
            prompt=q.cast_prompt(dict(source,paragraphs=batch))
            prompt+='\nРеестр уже найденных персонажей: '+json.dumps(cast,ensure_ascii=False)
            prompt+='\nВерни полный накопленный реестр: сохрани прежние ID, имена, пол и описания голосов. Имена/прозвища одного человека объединяй в aliases, а не новую роль. Добавляй только новых говорящих.'
            previous={c['id']: c for c in cast['characters']}
            def validate(data):
                value=q.validate_cast(data)
                current={c['id']:c for c in value['characters']}
                if not set(previous)<=set(current): raise ValueError('Потеряны прежние персонажи')
                for cid, old in previous.items():
                    if current[cid]['name'] != old['name'] or current[cid]['gender'] != old['gender']:
                        raise ValueError('Изменена личность прежнего персонажа')
                    current[cid]['voice_description']=old['voice_description']
                    current[cid]['aliases']=list(dict.fromkeys(old['aliases']+current[cid]['aliases']))
                return q.validate_cast(value)
            cast=q.obtain(folder,f'cast-{i}/{len(chunks)}',prompt,validate,args,key)
        role_batches=q.batches(source['paragraphs'],4000)
        for i,batch in enumerate(role_batches,1):
            labelled=q.obtain(folder,f'roles-{i}/{len(role_batches)}',q.roles_prompt(source,cast,batch,labels[-5:]),
                lambda data:q.validate_roles(data,batch,cast),args,key)
            labels.extend(labelled)
    if any(s['speaker'] is None for p in labels for s in p['spans']):
        q.write(folder/'roles-review.json',labels)
        raise ValueError('LLM не определила часть говорящих. Озвучка остановлена; см. roles-review.json')
    q.write(folder/'cast.json',dict(cast,input_sha256=source['input_sha256']))
    q.write(folder/'roles.json',{'paragraphs':labels})
    q.export_project(folder,source,cast,labels,args)
    return folder/'manifest.json'


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('book',nargs='?')
    parser.add_argument('output',nargs='?')
    parser.add_argument('--test',action='store_true',help='Около пяти минут с начала книги')
    parser.add_argument('--prepare-only',action='store_true',help='Роли и текст без загрузки TTS/генерации аудио')
    parser.add_argument('--roles-manifest',type=Path,help='Готовые роли для ТОГО ЖЕ исходного EPUB; не запрашивать LLM для ролей')
    args=parser.parse_args()
    root=Path(__file__).resolve().parent
    book=input_path(args.book or input('EPUB: имя файла в books или полный путь (можно перетащить файл): '),root,True)
    if not book.is_file() or book.suffix.lower()!='.epub': raise ValueError(f'EPUB не найден: {book}')
    output=input_path(args.output or input(f'Куда сохранить? Enter = {root / "results"}: ') or str(root/'results'),root)
    print('Y/Enter: облачная проверка спорных ударений. N/нет: без неё, все роли сохраняются.')
    cloud,key=choose_cloud()
    ready_roles=args.roles_manifest
    if ready_roles is None:
        candidate=book.with_suffix('.roles.json')
        if candidate.is_file(): ready_roles=candidate
    roles_key=key
    if ready_roles is None and not roles_key:
        print('Для этой новой книги нет готовой разметки ролей. N отключает только проверку ударений, не многоголосность.')
        answer=input('Путь к готовому manifest ролей (Enter — ввести отдельный ключ для определения ролей): ').strip()
        if answer: ready_roles=input_path(answer,root)
        else:
            roles_key=getpass.getpass('Ollama API key ТОЛЬКО для определения ролей (не сохраняется): ').strip()
            if not roles_key: raise ValueError('Нужен готовый manifest ролей или ключ для их определения; роли не заменены рассказчиком')
    project=output/(book.stem+('-test-' if args.test else '-')+datetime.now().strftime('%Y%m%d-%H%M%S'))
    project.mkdir(parents=True,exist_ok=False)
    with (project/'run.log').open('w',encoding='utf-8') as log:
        def run(python,script,*options):
            print(f'Этап: {script}',flush=True)
            env=dict(os.environ)
            env.pop('OLLAMA_API_KEY',None)
            if cloud: env['OLLAMA_API_KEY']=key
            child=subprocess.Popen([str(python),'-u',str(root/script),*map(str,options)],env=env,
                stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
            for line in child.stdout:
                print(line,end='',flush=True);log.write(line);log.flush()
            if child.wait(): raise ValueError(f'Этап {script} завершился ошибкой. Журнал: {project / "run.log"}')
        py=root/'.venv-mlx/bin/python'
        if ready_roles:
            prepared=q.load(ready_roles)
            if prepared['book']['input_sha256']!=hashlib.sha256(book.read_bytes()).hexdigest():
                raise ValueError('Разметка ролей относится к другому EPUB')
            q.check_manifest(prepared,q.read_source(book))
            if any(s['speaker'] is None for s in prepared['segments']):
                raise ValueError('В готовом manifest есть неопределённые роли')
            roles_dir=project/'roles';roles_dir.mkdir()
            roles=roles_dir/'manifest.json';q.write(roles,prepared)
            nearby=Path(ready_roles).parent/'source.json'
            if nearby.exists(): shutil.copyfile(nearby,roles_dir/'source.json')
            elif 'paragraph_texts' not in prepared:
                q.write(roles_dir/'source.json',q.read_source(book))
        else:
            roles=prepare_roles(book,project/'roles',True,roles_key,args.test)
        roles_key=None
        options=[]
        if args.test:
            first=q.load(roles)['segments'][0]['paragraph_id']
            options=['--seconds','300','--start-paragraph',first]
        run(py,'audiobook_epub.py','prepare','--manifest',roles,'--out',project/'source','--highlight','sentence',*options)
        manifest=project/'source/manifest.json'
        run(root/'.venv-stress/bin/python','prepare_silero.py','--manifest',manifest,'--dictionary-dir',root/'data/stress',
            '--llm-disputes','run' if cloud else 'off')
        key=None
        # Do not pass the cloud key to synthesis/FFmpeg processes.
        cloud=False
        if args.prepare_only:
            print(f'Подготовлено без аудио: {manifest}',flush=True)
            return
        run(py,'synthesize_qwen_mlx.py','--manifest',manifest,'--model',root/'models/Qwen3-TTS-12Hz-1.7B-Ru-Stress-CF-source',
            '--design-model',root/'models/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit','--ephemeral-voices','--mode','clone',
            '--rab-generation','--temperature','0.9','--stress-marks','keep','--whole-book','--out',project/'audio')
        run(py,'normalize_book_audio.py','--audio-dir',project/'audio','--out',project/'audio-normalized')
        run(py,'mix_book_music.py','--audio-dir',project/'audio-normalized','--out',project/'audio-music',
            '--music',root/'resources/Lamplight_and_Paper.mp3','--volume-percent','5')
        run(py,'audiobook_epub.py','package','--manifest',manifest,'--audio-dir',project/'audio-music','--out',project/'result')
    print(f'Готово: {project / "result"}',flush=True)
    subprocess.run(['open',str(project/'result')],check=False)
    subprocess.run(['open','-a','QuickTime Player',str(project/'audio-music/sample.mp3')],check=False)


if __name__=='__main__':
    try: main()
    except (ValueError,OSError,subprocess.CalledProcessError) as exc: sys.exit(f'Ошибка: {exc}')
