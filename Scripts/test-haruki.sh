#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
offline=false
browser=false
for argument in "$@"; do
    case "$argument" in
        --offline) offline=true ;;
        --browser) browser=true ;;
        *) echo "Usage: Scripts/test-haruki.sh [--offline] [--browser]" >&2; exit 2 ;;
    esac
done
if [[ "$offline" != true ]]; then
    python3 Scripts/fetch-haruki-fixture.py
fi
if [[ ! -d sekai-scenario-player/node_modules/typescript ]]; then
    npm --prefix sekai-scenario-player ci --ignore-scripts
fi
if [[ ! -x .build/fx-env/bin/python ]]; then
    python3 -m venv .build/fx-env
    .build/fx-env/bin/python -m pip install -r Tools/requirements.txt
fi
.build/fx-env/bin/python Tests/ConverterTests.py
Scripts/build.sh macOS Debug
products="$PWD/.build/Build/Intermediates.noindex/InstallIntermediates/macosx/Products/Debug"
for suite in Haruki Effects PhysicsTiming; do
    xcrun swiftc -swift-version 6 -parse-as-library \
        -module-cache-path .build/SwiftModuleCache -I Astray/Live2D/Bridge \
        -F "$products" -framework Astray -Xlinker -rpath -Xlinker "$products" \
        "Tests/${suite}Tests.swift" -o ".build/${suite}Tests"
done
.build/HarukiTests
.build/PhysicsTimingTests --real
for effect in sekai_transition bg/bg_b001002; do
    artifacts=".build/TestArtifacts/Haruki-${effect//\//-}"
    node Scripts/reference-effects.cjs ".build/HarukiAssets/fx/$effect/effect.json" "$artifacts"
    ASTRAY_EFFECT_FIXTURE_DIR="$artifacts" .build/EffectsTests
done
if [[ "$browser" == true ]]; then
    if [[ ! -d .build/browser/node_modules/playwright ]]; then
        npm install --prefix .build/browser --no-audit --no-fund playwright@1.64.1
    fi
    if [[ ! -f .build/HarukiAssets/lib/live2dcubismcore.min.js ]]; then
        mkdir -p .build/HarukiAssets/lib
        curl --fail --location --max-time 30 \
            https://cubism.live2d.com/sdk-web/cubismcore/live2dcubismcore.min.js \
            -o .build/HarukiAssets/lib/live2dcubismcore.min.js
    fi
    node Scripts/capture-reference.cjs
    .build/fx-env/bin/python Tests/CompareReference.py
fi
