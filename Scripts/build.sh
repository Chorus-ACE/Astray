#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
platform="${1:-macOS}"
configuration="${2:-Debug}"
if [[ ! -f Vendor/CubismNativeSamples/Framework/src/CubismFramework.hpp ]]; then
    echo "Initialize source dependencies: git submodule update --init --recursive" >&2
    exit 2
fi
if [[ "$platform" != "visionOS" && "$platform" != "visionOS Simulator" && ! -f Vendor/CubismCore/include/Live2DCubismCore.h ]]; then
    echo "Install the authorized Core archive with Scripts/setup-cubism.sh --archive /path/to/CubismSdkForNative-5-r.4.1.zip" >&2
    exit 2
fi
xcodebuild -project Astray.xcodeproj -scheme Astray \
    -configuration "$configuration" -destination "generic/platform=$platform" \
    -derivedDataPath .build CODE_SIGNING_ALLOWED=NO
