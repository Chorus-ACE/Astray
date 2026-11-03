#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${ASTRAY_DEMO_CONFIGURATION:-Release}"
Scripts/build.sh macOS "$configuration"
products="$PWD/.build/Build/Intermediates.noindex/InstallIntermediates/macosx/Products/$configuration"
app="$PWD/.build/AstrayDemo.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
xcrun swiftc -O -swift-version 6 -parse-as-library \
    -module-cache-path .build/SwiftModuleCache \
    -F "$products" -framework Astray \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Examples/PlayerDemo.swift -o "$app/Contents/MacOS/AstrayDemo"
# Preserve the framework's versioned bundle layout and compiled Metal library.
ditto "$products/Astray.framework" "$app/Contents/Frameworks/Astray.framework"
cp Examples/demo.json Examples/live2d_demo.json Examples/effects_demo.json "$app/Contents/Resources/"
ditto Examples/SDKAssets "$app/Contents/Resources/SDKAssets"
ditto Vendor/CubismNativeSamples/Samples/Resources/Haru "$app/Contents/Resources/SDKAssets/Haru"
if [[ -f .build/HarukiAssets/provenance.json ]]; then
    ditto .build/HarukiAssets "$app/Contents/Resources/HarukiAssets"
fi
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>top.darock.AstrayDemo</string>
<key>CFBundleExecutable</key><string>AstrayDemo</string>
<key>CFBundleName</key><string>Astray Demo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ "${1:-}" != "--build-only" ]]; then
    open "$app"
fi
