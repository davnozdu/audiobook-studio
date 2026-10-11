"""Assemble runnable kit without books, keys, debug prototypes or git history."""
import argparse
from pathlib import Path
import shutil
import subprocess

FILES = ['START.command','START-5MIN.command','TEST-7MIN.command','WEEKEND.md','THIRD_PARTY.md',
 'build_audiobook.py','setup_audiobook.py','prepare_qwen.py','audiobook_epub.py',
 'prepare_silero.py','prepare_speech.py','arbitrate_stress.py','stress_dictionary.py',
 'russian_text.py','supertonic_rules.json','synthesize_qwen_mlx.py','normalize_book_audio.py',
 'mix_book_music.py','export_rab_text.py','requirements.txt','requirements-stress.txt',
 'stress_model_files.json','design_model_files.json']


def assemble(destination, installed=None):
    project=Path(__file__).resolve().parent
    destination=Path(destination).resolve()
    if destination==project: raise ValueError('Укажите отдельную папку комплекта')
    destination.mkdir(parents=True,exist_ok=True)
    for name in FILES: shutil.copy2(project/name,destination/name)
    for name in ['resources','rab']:
        shutil.copytree(project/name,destination/name,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
    for name in ['books','results','models']: (destination/name).mkdir(exist_ok=True)
    if installed:
        installed=Path(installed).resolve()
        for name in ['.venv-mlx','.venv-stress']:
            target=destination/name
            if not target.exists() and (installed/name).is_dir():
                subprocess.run(['cp','-cR',str(installed/name),str(target)],check=True)
        dictionary=installed/'qwen-epub-audiobook/data/stress'
        if dictionary.is_dir():
            shutil.copytree(dictionary,destination/'data/stress',dirs_exist_ok=True)
    print(f'Комплект: {destination}\nЗапуск: {destination / "START.command"}')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',required=True,type=Path)
    parser.add_argument('--installed',type=Path)
    args=parser.parse_args()
    assemble(args.out,args.installed)
