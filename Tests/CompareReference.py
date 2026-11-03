from pathlib import Path
import json
import math
from PIL import Image, ImageChops, ImageStat

root = Path('.build/TestArtifacts/Haruki')
native = Image.open(root / 'native-pose.png').convert('RGB')
reference = Image.open(root / 'reference-pose.png').convert('RGB')
assert native.size == reference.size == (1280, 720)
difference = ImageChops.difference(native, reference)
metrics = {}
for name, box in [('full', (0, 0, 1280, 720)), ('background', (0, 0, 250, 500)), ('model', (300, 100, 1000, 720))]:
    stats = ImageStat.Stat(difference.crop(box))
    mse = sum(value * value for value in stats.rms) / 3
    metrics[name] = {'meanAbsoluteError8Bit': sum(stats.mean) / 3, 'psnrDB': 10 * math.log10(255 * 255 / max(mse, 1e-12))}
# Independent motion initialization frames and GPU edge sampling are
# intentionally measured rather than described as exact pixel equality.
assert metrics['full']['meanAbsoluteError8Bit'] < 1
assert metrics['full']['psnrDB'] > 35
assert metrics['background']['meanAbsoluteError8Bit'] < 0.1
assert metrics['model']['meanAbsoluteError8Bit'] < 2
(root / 'comparison.json').write_text(json.dumps(metrics, indent=2) + '\n')
print('PASS: native Metal vs reference WebGL, mean RGB error', round(metrics['full']['meanAbsoluteError8Bit'], 4), '/ 255; PSNR', round(metrics['full']['psnrDB'], 2), 'dB.')
