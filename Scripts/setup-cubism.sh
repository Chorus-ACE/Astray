#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="5-r.4.1"
archive=""
if [[ "${1:-}" == "--download" && "${2:-}" == "--accept-license" ]]; then
    archive="$PWD/.build/CubismSdkForNative-$version.zip"
    mkdir -p .build
    curl --fail --location --show-error "https://cubism.live2d.com/sdk-native/bin/CubismSdkForNative-$version.zip" -o "$archive"
elif [[ "${1:-}" == "--archive" && -n "${2:-}" ]]; then
    archive="$2"
else
    cat >&2 <<'USAGE'
Supply an official Cubism Native 5-r.4.1 archive:
  Scripts/setup-cubism.sh --archive /path/to/CubismSdkForNative-5-r.4.1.zip
Or, after reading and accepting the Live2D licenses:
  Scripts/setup-cubism.sh --download --accept-license
https://www.live2d.com/en/sdk/download/native/
USAGE
    exit 2
fi
python3 - "$archive" <<'PY'
from pathlib import Path
from zipfile import ZipFile
import hashlib
import sys
archive = Path(sys.argv[1]).resolve()
expected = 'b71ec6bafc6578cce3b4cbbaa42a1cb51ae6eb477557932b02d22af957e733c7'
if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
    raise SystemExit('SDK archive checksum does not match the pinned official R4.1 package.')
root = Path('Vendor/CubismCore').resolve()
prefix = 'CubismSdkForNative-5-r.4.1/Core/'
with ZipFile(archive) as source:
    if prefix + 'include/Live2DCubismCore.h' not in source.namelist():
        raise SystemExit('Expected an official Cubism Native 5-r.4.1 archive.')
    for name in source.namelist():
        if not name.startswith(prefix) or name.endswith('/'):
            continue
        output = (root / name[len(prefix):]).resolve()
        if not output.is_relative_to(root):
            raise SystemExit('Invalid archive path.')
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(source.read(name))
print('Installed Cubism Core 5-r.4.1 in Vendor/CubismCore (Git-ignored).')
print('Archive SHA-256:', hashlib.sha256(archive.read_bytes()).hexdigest())
PY
