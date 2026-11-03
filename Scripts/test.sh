#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -d sekai-scenario-player/node_modules/typescript ]]; then
    npm --prefix sekai-scenario-player ci --ignore-scripts
fi
if [[ ! -x .build/fx-env/bin/python ]]; then
    python3 -m venv .build/fx-env
    .build/fx-env/bin/python -m pip install -r Tools/requirements.txt
fi
node Scripts/reference-effects.cjs
node Scripts/reference-cleista.cjs
.build/fx-env/bin/python Tests/ConverterTests.py
Scripts/build.sh macOS Debug
products="$PWD/.build/Build/Intermediates.noindex/InstallIntermediates/macosx/Products/Debug"
for suite in Playback AssetResolver Cleista Effects Live2D RenderResources PhysicsTiming MotionEvent AudioLifetime Movie Shader Viewport; do
    xcrun swiftc -swift-version 6 -parse-as-library \
        -module-cache-path .build/SwiftModuleCache -I Astray/Live2D/Bridge \
        -F "$products" -framework Astray \
        -Xlinker -rpath -Xlinker "$products" \
        "Tests/${suite}Tests.swift" -o ".build/${suite}Tests"
    ".build/${suite}Tests" Tests/Fixtures/sample_demo.json .build/TestArtifacts
done
