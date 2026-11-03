#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f .build/HarukiAssets/provenance.json ]]; then
    echo "Prepare the real chapter first: Scripts/test-haruki.sh" >&2
    exit 2
fi
Scripts/build.sh macOS Release
products="$PWD/.build/Build/Intermediates.noindex/InstallIntermediates/macosx/Products/Release"
xcrun swiftc -O -swift-version 6 -parse-as-library \
    -module-cache-path .build/SwiftModuleCache \
    -F "$products" -framework Astray -Xlinker -rpath -Xlinker "$products" \
    Tests/RenderPerformanceTests.swift -o .build/RenderPerformanceTests
.build/RenderPerformanceTests "$@"
