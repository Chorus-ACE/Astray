# Astray

Renders Project Sekai stories natively on Apple GPUs.

## Build & Run

```sh
git submodule update --init --recursive
# Read and accept the Live2D licenses before using --accept-license.
Scripts/setup-cubism.sh --download --accept-license
# Or install an already authorized official archive:
# Scripts/setup-cubism.sh --archive /path/to/CubismSdkForNative-5-r.4.1.zip
Scripts/build.sh macOS Debug
Scripts/build.sh iOS Release
Scripts/build.sh visionOS Release
Scripts/test.sh
Scripts/run-demo.sh
```
