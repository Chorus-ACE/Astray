from pathlib import Path
import json
import subprocess
import sys
import yaml

root = Path(__file__).resolve().parents[1]
out = root / '.build/TestArtifacts/Converter'
assets = out / 'Assets'
assets.mkdir(parents=True, exist_ok=True)


def mm(value):
    return {'minMaxState': 0, 'scalar': value, 'minScalar': 0}


curve = {'m_Curve': [{'time': 0, 'value': 0, 'inSlope': 0, 'outSlope': 1}, {'time': 1, 'value': 1, 'inSlope': 1, 'outSlope': 0}], 'm_PreInfinity': 2, 'm_PostInfinity': 2}
ps = {
    'm_GameObject': {'fileID': 1}, 'lengthInSec': 1, 'looping': 1, 'simulationSpeed': 1, 'playOnAwake': 1,
    'startDelay': mm(0), 'moveWithTransform': 1,
    'InitialModule': {'enabled': 1, 'maxNumParticles': 100, 'startLifetime': mm(1), 'startSpeed': mm(0.1), 'startSize': mm(0.05), 'startColor': {'minMaxState': 0, 'maxColor': {'r': 1, 'g': 0.5, 'b': 0.25, 'a': 1}}},
    'ShapeModule': {'enabled': 1, 'type': 0, 'radius': {'value': 0.2}},
    'EmissionModule': {'enabled': 1, 'rateOverTime': mm(10)},
    'VelocityModule': {'enabled': 1, 'x': mm(0.1), 'y': mm(0), 'z': mm(0)},
    'SizeModule': {'enabled': 1, 'curve': {'minMaxState': 1, 'scalar': 1, 'maxCurve': curve}},
    'NoiseModule': {'enabled': 1, 'strength': mm(0.1), 'frequency': 0.5},
    'UVModule': {'enabled': 1, 'tilesX': 2, 'tilesY': 2, 'frameOverTime': mm(0.5)},
    'CustomDataModule': {'enabled': 1, 'vector0_0': mm(1)},
}
go = {'m_Name': 'ConverterFixture', 'm_IsActive': 1, 'm_Layer': 5, 'm_Component': [{'component': {'fileID': n}} for n in [2, 3, 4]]}
transform = {'m_GameObject': {'fileID': 1}, 'm_LocalPosition': {'x': 10, 'y': 20, 'z': 0}, 'm_LocalRotation': {'x': 0, 'y': 0, 'z': 0, 'w': 1}, 'm_LocalScale': {'x': 1, 'y': 1, 'z': 1}, 'm_Father': {'fileID': 0}, 'm_Children': []}
renderer = {'m_GameObject': {'fileID': 1}, 'm_RenderMode': 0, 'm_SortingOrder': 230, 'm_SortingLayerID': -348333445, 'm_Materials': [], 'm_MinParticleSize': 0, 'm_MaxParticleSize': 1, 'm_Pivot': {'x': 0, 'y': 0, 'z': 0}}
prefab = assets / 'fixture.prefab'
prefab.write_text('%YAML 1.1\n%TAG !u! tag:unity3d.com,2011:\n' + ''.join(f'--- !u!{cls} &{index}\n' + yaml.safe_dump({name: body}, sort_keys=False) for cls, index, name, body in [(1, 1, 'GameObject', go), (4, 2, 'Transform', transform), (198, 3, 'ParticleSystem', ps), (199, 4, 'ParticleSystemRenderer', renderer)]))
results = []
for converter, destination in [('Tools/fx_convert.py', 'native'), ('sekai-scenario-player/tools/fx_convert.py', 'reference')]:
    subprocess.run([sys.executable, '-I', str(root / converter), str(assets), str(out / destination), '--prefab=' + str(prefab), '--name=fixture', '--unit=540'], check=True)
    results.append(json.loads((out / destination / 'fixture/effect.json').read_text()))
assert results[0] == results[1], 'Converter output differs from the pinned reference'
node = results[0]['nodes'][0]
assert node['ps']['SizeModule']['curve']['c']['k'][1][1] == 1
assert node['ps']['InitialModule']['startColor']['max'] == [1, 0.5, 0.25, 1]
assert node['psr']['m_SortingOrder'] == 230
assert results[0]['roots'] == [0] and results[0]['unit'] == 540
print('PASS: real Unity prefab YAML conversion matches the pinned reference, including curves, gradients, modules and sorting.')
