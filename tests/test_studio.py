import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'backend'))
sys.path.insert(0, str(ROOT / 'backend/engine'))
import characters
import worker
import prepare_qwen as q
import synthesize_qwen_mlx as synth
import voice_designer
import setup_audiobook


def fixture():
    source = dict(title='Тест', author='Автор', input_sha256='abc', normalization='none',
        chapters=[dict(id='ch001', title='Глава', href='chapter.xhtml')],
        paragraphs=[dict(id='p00001', chapter_id='ch001', text='Миша сказал: «Я приду».',
                         source=dict(href='chapter.xhtml', block_index=0, element_id=None, tag='p'))])
    cast = {'characters': [dict(id='narrator', name='Рассказчик', gender='male', age='adult',
        aliases=[], evidence='Текст автора', voice_description='Calm mature baritone'),
        dict(id='misha', name='Миша', gender='male', age='young', aliases=['Михаил'],
             evidence='Реплика', voice_description='Bright youthful tenor')]}
    labels = [{'id': 'p00001', 'spans': [{'start': 0, 'end': 22, 'speaker': 'misha', 'confidence': 'high', 'reason': ''}]}]
    labels[0]['spans'][0]['end'] = len(source['paragraphs'][0]['text'])
    with tempfile.TemporaryDirectory() as directory:
        with patch('builtins.print'):
            q.export_project(Path(directory), source, cast, labels,
                SimpleNamespace(target_chars=220, max_chars=360, model='test', no_think=True))
        return q.load(Path(directory) / 'manifest.json'), source


def profile(cid):
    return dict(id=cid, age='12 лет, предположение', personality='Любознательный', habits='Неизвестны',
        speaking_style='Быстрая речь', voice_description='Youthful Russian tenor ' + cid,
        certainty='low', assumptions=['Возраст приблизительный'],
        evidence=[dict(kind='book', reference='p00001', note='Контекст реплики')])


class CharacterTests(unittest.TestCase):
    def test_preserves_roles_text_and_identity(self):
        manifest, source = fixture(); original = copy.deepcopy(manifest)
        profiles = dict(input_sha256='abc', characters=[profile('narrator'), profile('misha')])
        updated = characters.apply_profiles(manifest, profiles, source, q)
        self.assertEqual(updated['segments'], original['segments'])
        self.assertEqual(manifest, original)
        for old, new in zip(original['voices'], updated['voices']):
            for field in ('id', 'name', 'gender', 'voice_id', 'seed'):
                self.assertEqual(old[field], new[field])
            self.assertIn('Youthful Russian tenor', new['instruct'])

    def test_rejects_other_book(self):
        manifest, source = fixture()
        with self.assertRaises(ValueError):
            characters.apply_profiles(manifest, dict(input_sha256='wrong', characters=[]), source, q)

    def test_rejects_missing_or_duplicate_roles(self):
        manifest, source = fixture()
        for values in ([profile('narrator')], [profile('narrator'), profile('narrator')]):
            with self.assertRaises(ValueError):
                characters.apply_profiles(manifest, dict(input_sha256='abc', characters=values), source, q)

    def test_rejects_invented_evidence(self):
        data = profile('misha'); voice = dict(id='misha')
        data['evidence'][0]['reference'] = 'p99999'
        with self.assertRaises(ValueError):
            characters.validate_profile(data, voice, {'p00001'}, set())
        data['evidence'] = [dict(kind='web', reference='https://fake.invalid', note='Выдумано')]
        with self.assertRaises(ValueError):
            characters.validate_profile(data, voice, {'p00001'}, set())

    def test_analysis_calls_are_sequential_and_profile_accumulates(self):
        manifest, source = fixture()
        calls = []
        def fake(spec, args, key):
            payload = spec['messages'][0]['content']
            cid = 'narrator' if '"id": "narrator"' in payload else 'misha'
            calls.append(cid)
            return dict(done_reason='stop', message=dict(content=json.dumps(profile(cid))))
        with patch.object(q, 'online_request', side_effect=fake), patch.object(characters, 'search', return_value=[] ) as search:
            result = characters.analyze(manifest, source, 'secret', 'test', True, q, lambda *_: None)
        self.assertEqual(calls, ['misha'])
        self.assertEqual(len(result['characters']), 2)
        search.assert_called_once()

    def test_narrator_template_fills_all_fields_without_cloud(self):
        voice = dict(id='narrator', voice_gender='female')
        profile = characters.narrator_profile(voice)
        self.assertTrue(all(profile[field].strip() for field in characters.FIELDS))
        self.assertIn('female', profile['voice_description'])
        characters.validate_profile(profile, voice, set(), set())

    def test_custom_sample_survives_profile_update(self):
        manifest, source = fixture()
        manifest['voices'][0]['custom_reference'] = dict(path='sample.wav', text='Текст', sha256='hash')
        updated = characters.apply_profiles(manifest, dict(input_sha256='abc', characters=[profile('narrator'), profile('misha')]), source, q)
        self.assertEqual(updated['voices'][0]['custom_reference'], manifest['voices'][0]['custom_reference'])


class VoiceTests(unittest.TestCase):
    def test_model_check_reports_files_and_rejects_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); target = root / 'models/test'; target.mkdir(parents=True)
            (target / 'weights').write_bytes(b'model')
            spec = dict(files=[dict(path='weights', size=5, sha256=hashlib.sha256(b'model').hexdigest())])
            states = []
            self.assertEqual(setup_audiobook.ensure_model(root, 'test', spec, progress=lambda *x: states.append(x)), target)
            self.assertTrue(any('Проверка файлов' in x[0] for x in states))
            self.assertEqual(states[-1][1], 1)
            (target / 'weights').write_bytes(b'wrong')
            with self.assertRaises(ValueError): setup_audiobook.ensure_model(root, 'test', spec)

    def test_designer_validates_text_before_loading_gpu(self):
        text, description = voice_designer.validate_request(dict(text='Сегодня мы открываем новую книгу.', description='Warm mature Russian baritone'))
        self.assertIn('книгу', text)
        for request in (dict(text='!', description=description), dict(text='x'*251, description=description), dict(text=text, description='')):
            with self.assertRaises(ValueError):
                voice_designer.validate_request(request)

    def test_user_sample_bypasses_generated_reference(self):
        with tempfile.TemporaryDirectory() as directory:
            wav = Path(directory) / 'original.wav'; wav.write_bytes(b'fake audio')
            voice = dict(id='narrator', name='Рассказчик', custom_reference=dict(path=str(wav), text='Мой текст',
                          sha256=hashlib.sha256(wav.read_bytes()).hexdigest()))
            result = synth.read_reference(Path(directory) / 'ephemeral', voice, 'abc')
            self.assertEqual(result['ref_text'], 'Мой текст')
            self.assertEqual(Path(result['ref_audio']), wav.resolve())
            self.assertTrue(wav.exists())
            wav.write_bytes(b'changed')
            with self.assertRaises(ValueError):
                synth.read_reference(directory, voice, 'abc')

    def test_voice_direction_uses_edited_description(self):
        voice = dict(id='narrator', voice_description='User edited warm contralto', voice_gender='female', age='adult')
        self.assertIn('User edited warm contralto', synth.reference_instruction(voice))


class SpeedTests(unittest.TestCase):
    def test_current_throughput_and_remaining_time(self):
        meter = worker.Speed(dict(segments=[dict(id='seg000001', text='a'*100), dict(id='seg000002', text='b'*300)]))
        self.assertIsNone(meter.update('Loading Base next'))
        result = meter.update('seg000001 Рассказчик: 10.0s audio / 5.0s generation; sample 10.3s')
        self.assertEqual(result['speed'], 2)
        self.assertEqual(result['eta'], 15)
        self.assertEqual(result['fraction'], .25)
        self.assertIsNone(meter.update('seg000001 Рассказчик: 10.0s audio / 5.0s generation; sample 10.3s'))
        result = meter.update('seg000002 Рассказчик: 30.0s audio / 30.0s generation; sample 40.3s')
        self.assertEqual(result['eta'], 0)
        self.assertAlmostEqual(result['speed'], 40/35)


class RoleEditorTests(unittest.TestCase):
    def test_automatic_unknown_roles_use_other_voice_and_preserve_text(self):
        manifest, source = fixture()
        segment = manifest['segments'][0]
        original = copy.deepcopy(segment)
        segment.update(speaker=None, voice_id=None, needs_review=True)
        with tempfile.TemporaryDirectory() as directory, patch.object(q, 'obtain', return_value={segment['id']: None}), patch.object(worker, 'emit'):
            worker.resolve_automatic_roles(manifest, source, Path(directory), SimpleNamespace(), 'secret')
        self.assertEqual(segment['speaker'], 'other_voices')
        self.assertEqual(manifest['stats']['unresolved_segments'], 0)
        self.assertTrue(segment['needs_review'])
        for field in ('text', 'source', 'order', 'chapter_id', 'paragraph_id', 'pause_after_ms'):
            self.assertEqual(segment[field], original[field])
        q.check_manifest(manifest, source)

    def test_edit_keeps_text_and_epub_anchors(self):
        manifest, source = fixture()
        before = copy.deepcopy(manifest['segments'][0])
        updated = worker.apply_role_edits(manifest, source, {before['id']: 'narrator'})
        after = updated['segments'][0]
        self.assertEqual(after['speaker'], 'narrator')
        self.assertEqual(after['voice_id'], updated['voices'][0]['voice_id'])
        for field in ('text', 'source', 'order', 'chapter_id', 'paragraph_id', 'pause_after_ms'):
            self.assertEqual(before[field], after[field])

    def test_unknown_speaker_is_rejected(self):
        manifest, source = fixture()
        with self.assertRaises(ValueError):
            worker.apply_role_edits(manifest, source, {manifest['segments'][0]['id']: 'invented'})


class BundledMusicTests(unittest.TestCase):
    def test_complete_catalog_and_audio_integrity(self):
        resources = ROOT / 'backend/engine/resources'
        tracks = json.loads((resources / 'music_catalog.json').read_text())
        self.assertEqual(len(tracks), 7)
        self.assertEqual(len({track['filename'] for track in tracks}), 7)
        for track in tracks:
            with self.subTest(track=track['filename']):
                audio = (resources / track['filename']).read_bytes()
                self.assertEqual(len(audio), track['size'])
                self.assertEqual(hashlib.sha256(audio).hexdigest(), track['sha256'])


if __name__ == '__main__':
    unittest.main()

class PortableProjectTests(unittest.TestCase):
    def test_roundtrip_keeps_audio_samples_music_and_relocates_paths(self):
        import project_bundle
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); original = base / 'original'; (original / 'roles').mkdir(parents=True)
            (original / 'book.epub').write_bytes(b'book')
            (original / 'audio').mkdir(); (original / 'audio/seg.wav').write_bytes(b'audio')
            sample = base / 'external.wav'; sample.write_bytes(b'voice')
            music = base / 'music.mp3'; music.write_bytes(b'music')
            (original / 'roles/manifest.json').write_text(json.dumps({'voices': [{'id': 'misha', 'custom_reference': {'path': str(sample), 'text': 'Привет'}}], 'audio': str(original / 'audio/seg.wav')}))
            archive = base / 'test.audiobookstudio'
            project_bundle.export_project(original, archive, {'music': str(music), 'music_volume': 7})
            shutil = __import__('shutil'); shutil.rmtree(original); sample.unlink(); music.unlink()
            restored = project_bundle.import_project(archive, base / 'restored')
            manifest = json.loads((restored / 'roles/manifest.json').read_text())
            self.assertEqual(Path(manifest['voices'][0]['custom_reference']['path']).read_bytes(), b'voice')
            self.assertEqual(Path(manifest['audio']).read_bytes(), b'audio')
            settings = json.loads((restored / 'studio-settings.json').read_text())
            self.assertEqual(Path(settings['music']).read_bytes(), b'music')
            self.assertEqual(settings['music_volume'], 7)

    def test_rejects_archive_path_traversal(self):
        import project_bundle, zipfile
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / 'bad.audiobookstudio'
            with zipfile.ZipFile(archive, 'w') as z: z.writestr('../escape.txt', 'bad')
            with self.assertRaises(ValueError): project_bundle.import_project(archive, Path(tmp) / 'out')
            self.assertFalse((Path(tmp) / 'escape.txt').exists())

    def test_excerpt_only_contains_selected_characters_words(self):
        manifest = {'segments': [{'speaker': 'narrator', 'text': 'Чужой текст автора.'},
            {'speaker': 'misha', 'text': '— Здравствуйте, добрый человек! Как ваши дела?'},
            {'speaker': 'other', 'text': 'Не включать.'}]}
        self.assertEqual(worker.character_excerpt(manifest, 'misha'), 'Здравствуйте, добрый человек! Как ваши дела?')

    def test_long_excerpt_is_short_and_does_not_use_other_speakers(self):
        text = 'Длинная реплика персонажа ' * 30
        result = worker.character_excerpt({'segments': [{'speaker': 'misha', 'text': text}]}, 'misha')
        self.assertLessEqual(len(result), 150)
        self.assertTrue(result.endswith('…'))

    def test_excerpt_gathers_enough_text_past_short_opening_replies(self):
        text = 'Я давно хотел рассказать вам об этой истории. Мне кажется, сегодня самое подходящее время для нашего разговора.'
        manifest = {'segments': [{'speaker': 'misha', 'text': 'О, еще бы!'}, {'speaker': 'other', 'text': 'Чужая реплика.'}, {'speaker': 'misha', 'text': text}]}
        result = worker.character_excerpt(manifest, 'misha')
        self.assertGreaterEqual(len(result), 110)
        self.assertLessEqual(len(result), 150)
        self.assertNotIn('Чужая', result)
        self.assertIn('рассказать', result)
