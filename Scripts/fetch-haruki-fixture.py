#!/usr/bin/env python3
"""Stage one public Haruki story and its referenced assets for local validation."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import posixpath
import subprocess
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import urlopen

parser = argparse.ArgumentParser()
parser.add_argument('--scenario-path', default='startapp/scenario/unitstory/idol-story-chapter/mmj_01_06.json')
parser.add_argument('--output', default='.build/HarukiAssets')
args = parser.parse_args()
root = Path(args.output).resolve()
cache = Path('.build/HarukiCache').resolve()
cache.mkdir(parents=True, exist_ok=True)
root.mkdir(parents=True, exist_ok=True)
hosts = ['https://sekai-assets-haruki.seiunx.net/jp-assets/', 'https://sekai-assets-cn03-she01-cdn.haruki.seiunx.com/jp-assets/']
records = {}


def target(path):
    result = (root / path).resolve()
    if not result.is_relative_to(root):
        raise ValueError('Asset path escapes fixture root: ' + path)
    result.parent.mkdir(parents=True, exist_ok=True)
    return result


def fetch(path):
    path = posixpath.normpath(path)
    if path.startswith(('/', '../')):
        raise ValueError('Invalid remote asset path: ' + path)
    entry = cache / hashlib.sha256(path.encode()).hexdigest()
    if entry.exists():
        return entry.read_bytes()
    last = None
    for host in hosts:
        try:
            with urlopen(host + quote(path, safe='/'), timeout=30) as response:
                data = response.read()
            entry.write_bytes(data)
            return data
        except HTTPError as error:
            last = error
            if error.code == 404:
                raise
        except (URLError, TimeoutError) as error:
            result = subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error', '--max-time', '30', host + quote(path, safe='/')], capture_output=True)
            if result.returncode == 0:
                entry.write_bytes(result.stdout)
                return result.stdout
            if b'404' in result.stderr:
                raise HTTPError(host + path, 404, 'Not found', None, None)
            last = error
    raise RuntimeError('Failed to fetch ' + path) from last


def save(path, remote):
    data = fetch(remote)
    target(path).write_bytes(data)
    records[path] = {'source': hosts[0] + quote(remote, safe='/'), 'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
    return data


def candidates(path, remotes, required=True):
    for remote in remotes:
        try:
            return save(path, remote)
        except HTTPError as error:
            if error.code not in (403, 404):
                raise
    if required:
        raise FileNotFoundError('No asset candidate: ' + path)
    return None


def json_file(path, value):
    target(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


index = json.loads(fetch('story-player/index.json'))
scene = json.loads(fetch(args.scenario_path))
sid = scene['ScenarioId']
save('scenario/' + sid + '.json', args.scenario_path)
layouts = scene.get('FirstLayout', []) + scene.get('LayoutData', [])
characters = scene.get('AppearCharacters', []) + layouts
costumes = {c['CostumeType']: c['Character2dId'] for c in characters if c.get('CostumeType')}
manifest = {}
with ThreadPoolExecutor(max_workers=6) as pool:
    for costume, character in costumes.items():
        entry = index['models'][costume]
        model_dir = 'models/' + costume
        settings = json.loads(fetch(entry['dir'] + '/' + entry['model3']))
        refs = settings['FileReferences']
        jobs = []
        for name in [refs['Moc']] + refs.get('Textures', []):
            jobs.append(pool.submit(save, model_dir + '/' + name, entry['dir'] + '/' + name))
        if entry.get('physics'):
            physics = refs.get('Physics', Path(entry['physics']).name)
            refs['Physics'] = physics
            jobs.append(pool.submit(save, model_dir + '/' + physics, entry['dir'] + '/' + entry['physics']))
        else:
            refs.pop('Physics', None)
        if refs.get('Pose'):
            jobs.append(pool.submit(save, model_dir + '/' + refs['Pose'], entry['dir'] + '/' + refs['Pose']))
        # Story clips are indexed separately; keep every declared model clip too.
        for group in refs.get('Motions', {}).values():
            for clip in group:
                jobs.append(pool.submit(save, model_dir + '/' + clip['File'], entry['dir'] + '/' + clip['File']))
        for clip in refs.get('Expressions', []):
            jobs.append(pool.submit(save, model_dir + '/' + clip['File'], entry['dir'] + '/' + clip['File']))
        names = {'motion': set(), 'facial': set()}
        motions = layouts + [m for talk in scene.get('TalkData', []) for m in talk.get('Motions', [])]
        for motion in motions:
            if motion.get('Character2dId') == character:
                names['motion'].add(motion.get('MotionName', ''))
                names['facial'].add(motion.get('FacialName', ''))
        for kind, clips in names.items():
            for name in sorted(clips - {''}):
                clip = name.lower()
                owner = None
                if kind == 'motion':
                    if clip in entry.get('motions', []):
                        owner = entry
                    else:
                        parent = entry['dir'].rsplit('/', 1)[0] + '/'
                        owner = next((e for e in index['models'].values() if e is not entry and e['dir'].startswith(parent) and clip in e.get('motions', [])), None)
                remote = owner['dir'] + '/motions/' + clip + '.motion3.json' if owner else entry.get('motionBase', '') + '/' + kind + '/' + clip + '.motion3.json'
                jobs.append(pool.submit(save, 'motions/' + costume + '/base/' + kind + '/' + name + '.motion3.json', remote))
        for job in jobs:
            job.result()
        json_file(model_dir + '/model.model3.json', settings)
        manifest[costume] = {'modelDir': model_dir, 'modelFile': 'model.model3.json', 'motionDir': costume, 'motionBase': 'base'}
        print('Model:', costume, flush=True)
    json_file('model_manifest.json', manifest)
    backgrounds = {scene.get('FirstBackground', '')} | {e.get('StringVal', '') for e in scene.get('SpecialEffectData', []) if e['EffectType'] == 7}
    jobs = []
    for bg in backgrounds - {''}:
        jobs.append(pool.submit(candidates, 'background/' + bg + '.png', [f'ondemand/scenario/background/{bg}/{bg}.png', f'startapp/scenario/background/{bg}/{bg}.png', f'ondemand/scenario/background/{bg}/scenariobgdata.assets/texture2d/{bg}.png']))
    effects = {e['StringVal'] for e in scene.get('SpecialEffectData', []) if e['EffectType'] == 15 and e.get('StringVal')}
    for effect in scene.get('SpecialEffectData', []):
        if effect['EffectType'] in (20, 21):
            effects.add('sekai_transition')
        if effect['EffectType'] in (40, 41):
            effects.add('sekai_transition_3anv')
        if effect['EffectType'] == 22 and effect.get('StringVal') == 'hologram':
            effects.add('hologram')
    bg_effects = set(json.loads(fetch('story-player/v1/fx/bg/index.json'))) & backgrounds
    json_file('fx/bg/index.json', sorted(bg_effects))
    effects |= {'bg/' + name for name in bg_effects}
    for name in sorted(effects):
        doc = json.loads(save('fx/' + name + '/effect.json', 'story-player/v1/fx/' + name + '/effect.json'))
        files = {t['file'] for m in doc.get('materials', {}).values() for t in m.get('tex', {}).values() if t.get('file')}
        files |= {s['tex'] for s in doc.get('sprites', {}).values() if s.get('tex')}
        jobs.extend(pool.submit(save, 'fx/' + name + '/' + file, 'story-player/v1/fx/' + name + '/' + file) for file in files)
        print('Prefab:', name, flush=True)
    for file in ['serif_note.png', 'scenario/tex_transition_left.png', 'scenario/tex_transition_top.png', 'scenario/btn_round_h80_wh.png', 'scenario/holo.png']:
        jobs.append(pool.submit(save, 'ui/' + file, 'story-player/v1/ui/' + file))
    bgms = {scene.get('FirstBgm', '')} | {s.get('Bgm', '') for s in scene.get('SoundData', [])}
    for bgm in bgms - {''}:
        jobs.append(pool.submit(candidates, 'sound/bgm/' + bgm + '.mp3', [f'ondemand/sound/scenario/bgm/{bgm}/{bgm}.mp3', f'startapp/sound/scenario/bgm/{bgm}/{bgm}.mp3']))
    for se in {s.get('Se', '') for s in scene.get('SoundData', [])} - {''}:
        if se in index['se']:
            jobs.append(pool.submit(save, 'sound/se/' + se + '.mp3', index['se'][se]))
    for voice in {v['VoiceId'] for t in scene.get('TalkData', []) for v in t.get('Voices', [])}:
        jobs.append(pool.submit(candidates, 'sound/voice/' + sid + '/' + voice + '.mp3', [f'{d}/{sid}/{voice}.mp3' for d in ['ondemand/sound/scenario/voice', 'ondemand/sound/card_scenario/voice', 'startapp/sound/scenario/voice']]))
    for effect in scene.get('SpecialEffectData', []):
        if effect['EffectType'] == 19:
            name = effect.get('StringVal', '')
            jobs.append(pool.submit(save, 'movie/' + name + '.mp4', index['movies'][name]))
    for job in jobs:
        job.result()
json_file('provenance.json', {'scenario': args.scenario_path, 'assetIndexVersion': index.get('version'), 'assetIndexGeneratedAt': index.get('generatedAt'), 'files': dict(sorted(records.items()))})
print('Staged', sid, ':', len(records), 'files,', sum(r['bytes'] for r in records.values()), 'bytes at', root, flush=True)
