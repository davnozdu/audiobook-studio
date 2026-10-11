"""One isolated VoiceDesign job; no Base model, API key or persistent TTS cache."""
import argparse
import gc
import json
import os
from pathlib import Path
import signal
from types import SimpleNamespace

from synthesize_qwen_mlx import generate_audio, save


def validate_request(request):
    text = request.get('text', '').strip()
    description = request.get('description', '').strip()
    if not 20 <= len(text) <= 250 or not any(c.isalnum() for c in text):
        raise ValueError('Тестовый текст: 20–250 символов, одно-три коротких предложения')
    if not 10 <= len(description) <= 3000:
        raise ValueError('Опишите голос: возраст, тембр, высота и манера говорить')
    return text, description


def generate(request, model_path, output):
    text, description = validate_request(request)
    engine = 'Клонирование голоса' if request.get('reference') else 'VoiceDesign'
    def stage(message):
        print('STUDIO_PROGRESS ' + json.dumps(dict(message=message), ensure_ascii=False), flush=True)
    stage('Запуск движка ' + engine + ' · подготовка локального окружения')
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    os.environ.pop('OLLAMA_API_KEY', None)
    import mlx.core as mx
    import soundfile as sf
    from mlx_audio.tts.utils import load_model
    model = None
    try:
        mx.set_default_device(mx.gpu)
        mx.set_cache_limit(512 * 1024 * 1024)
        mx.set_memory_limit(8 * 1024 ** 3)
        stage('Загрузка модели в память · подготовка GPU')
        model = load_model(str(model_path))
        if not request.get('reference') and model.config.tts_model_type != 'voice_design':
            raise ValueError('Выберите модель VoiceDesign')
        stage('Генерация реплик персонажа · ' + engine + ' работает на GPU')
        audio, rate, metrics = generate_audio(model, mx, text, description,
            int(request.get('seed', 17001)), SimpleNamespace(temperature=.9, max_tokens=1024, rab_generation=True), reference=request.get('reference'))
        if not 3 <= len(audio) / rate <= 30:
            raise ValueError('Для переносимого образца нужна запись 3–30 секунд. Измените длину тестового текста')
        output = Path(output); output.mkdir(parents=True, exist_ok=True)
        stage('Сохранение образца WAV и текста записи')
        temp = output / 'sample.tmp.wav'
        sf.write(temp, audio, rate, subtype='PCM_16')
        temp.replace(output / 'sample.wav')
        save(output / 'sample.json', dict(text=text, description=description, metrics=metrics,
                                         seed=int(request.get('seed', 17001))))
        print(f'Образец готов: {len(audio)/rate:.1f} секунд', flush=True)
    finally:
        stage('Выгрузка модели · освобождение памяти')
        if model is not None:
            del model
        gc.collect(); mx.clear_cache()
        print('VoiceDesign выгружен', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--request', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        generate(json.loads(Path(args.request).read_text()), Path(args.model), Path(args.out))
    except (ValueError, RuntimeError, OSError) as exc:
        parser.exit(1, str(exc) + '\n')
