"""Loop MyTTS track over the FINAL normalized narration without changing timing."""
import argparse
import os
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import tempfile

FFMPEG = os.environ.get("AUDIOBOOK_FFMPEG", "/opt/homebrew/bin/ffmpeg")
FIRST_TRACK = {'file': 'Lamplight_and_Paper.mp3', 'title': 'Свет лампы и страницы',
               'size': 4247943, 'sha256': 'f1048274fd167a826b18b94f52782d89848606e21719deb835e5bde75e42bba2'}


def default_music():
    project = Path(__file__).resolve().parent
    bundled = project / 'resources' / FIRST_TRACK['file']
    if bundled.is_file():
        return bundled
    runtime = project.parent if (project.parent / '.venv-mlx').is_dir() else project
    return runtime / 'data/music' / FIRST_TRACK['file']


def mix(source, out, music, percent=5):
    import numpy as np
    import soundfile as sf
    source, out, music = Path(source).resolve(), Path(out).resolve(), Path(music).resolve()
    if source == out:
        raise ValueError('Сохраните речь без музыки: выход должен быть в другом каталоге')
    if not math.isfinite(percent) or not 0 <= percent <= 25:
        raise ValueError('Громкость музыки должна быть 0–25%')
    if not music.is_file():
        raise ValueError(f'Музыкальный трек не найден: {music}')
    sha = hashlib.sha256(music.read_bytes()).hexdigest()
    if music.name == FIRST_TRACK['file'] and (music.stat().st_size != FIRST_TRACK['size'] or sha != FIRST_TRACK['sha256']):
        raise ValueError('Первый трек MyTTS не совпадает с каталогом (размер/SHA256)')
    benchmark = json.loads((source / 'benchmark.json').read_text())
    if benchmark.get('state') != 'complete':
        raise ValueError('Сборка речи не завершена')
    if benchmark.get('background_music'):
        raise ValueError('Музыка уже наложена; используйте исходную речь без музыки')
    info = sf.info(source / 'sample.wav')
    if info.channels != 1 or abs(info.duration - benchmark['final_audio_seconds']) > 1 / info.samplerate:
        raise ValueError('Ожидается готовая моно-дорожка с исходной длительностью')
    out.mkdir(parents=True, exist_ok=True)
    (out / 'benchmark.json').write_text(json.dumps({'state': 'mixing_music'}))
    gain = percent / 100
    # No amix automatic normalization: speech gain stays exactly 1.0.
    filters = (f'[1:a]aformat=sample_rates={info.samplerate}:channel_layouts=mono,'
               f'volume={gain:.8f}[music];[0:a][music]amix=inputs=2:duration=first:'
               f'dropout_transition=0:normalize=0,atrim=end_sample={info.frames}[mixed]')
    with tempfile.TemporaryDirectory(prefix='book-music-') as temporary:
        mixed = Path(temporary) / 'mixed.wav'
        subprocess.run([FFMPEG, '-hide_banner', '-loglevel', 'error', '-y',
                        '-i', str(source / 'sample.wav'), '-stream_loop', '-1', '-i', str(music),
                        '-filter_complex', filters, '-map', '[mixed]', '-c:a', 'pcm_f32le', str(mixed)], check=True)
        got = sf.info(mixed)
        if (got.frames, got.samplerate, got.channels) != (info.frames, info.samplerate, info.channels):
            raise ValueError('Наложение музыки изменило длительность/формат речи')
        peak = 0.0
        with sf.SoundFile(mixed) as reader:
            for block in reader.blocks(blocksize=65536, dtype='float32'):
                if not np.isfinite(block).all():
                    raise ValueError('Некорректные значения аудио')
                peak = max(peak, float(np.max(np.abs(block), initial=0)))
        if peak >= 1:
            raise ValueError('Сумма речи и музыки перегружена: сначала нормализуйте речь с запасом по пикам')
        with sf.SoundFile(mixed) as reader, sf.SoundFile(out / 'sample.wav', 'w', samplerate=info.samplerate,
                                                       channels=1, subtype='PCM_16') as writer:
            for block in reader.blocks(blocksize=65536, dtype='float32'):
                writer.write(block)
    shutil.copyfile(source / 'timeline.json', out / 'timeline.json')
    subprocess.run([FFMPEG, '-hide_banner', '-loglevel', 'error', '-y', '-i', str(out / 'sample.wav'),
                    '-c:a', 'libmp3lame', '-b:a', '192k', str(out / 'sample.mp3')], check=True)
    report = {'file': str(music), 'sha256': sha, 'title': FIRST_TRACK['title'] if music.name == FIRST_TRACK['file'] else music.stem,
              'volume_percent': percent, 'linear_gain': gain, 'speech_gain': 1.0, 'loop': True,
              'peak': peak, 'frames': info.frames, 'timing_unchanged': True, 'source_speech': str(source)}
    (out / 'music.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    benchmark.update(background_music=report, output_files={'wav': str(out / 'sample.wav'), 'mp3': str(out / 'sample.mp3')})
    (out / 'benchmark.json').write_text(json.dumps(benchmark, ensure_ascii=False, indent=2))
    print(f"Музыка: {report['title']}, {percent:g}%, цикл до конца книги; речь/тайминг сохранены. {out / 'sample.mp3'}")
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audio-dir', required=True)
    parser.add_argument('--out', required=True)
    parser.add_argument('--music', default=str(default_music()))
    parser.add_argument('--volume-percent', type=float, default=5)
    args = parser.parse_args()
    try:
        mix(args.audio_dir, args.out, args.music, args.volume_percent)
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f'Ошибка фоновой музыки: {exc}\n')
