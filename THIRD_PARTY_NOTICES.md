# Third-party notices

Astray's scenario schema, timeline semantics and layout constants are based on
sekai-scenario-player by Haruki Dev Team and contributors. The original source
is available in the sibling `sekai-scenario-player/` directory and at
https://github.com/Team-Haruki/sekai-scenario-player.

`Tests/Fixtures/sample_demo.json` is copied from that project's
`web/public/samples/sample_demo.json` for compatibility regression testing.

MIT License

Copyright (c) 2026 Haruki Dev Team and contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.


Cubism Native Samples 5-r.4.1 and its Framework are included as Git submodules
from https://github.com/Live2D/CubismNativeSamples. Their respective LICENSE.md
and NOTICE.md files remain in the submodules. Cubism Core is installed separately
from the official SDK archive into the ignored Vendor/CubismCore directory and
is subject to Live2D's proprietary license; it is not covered by the MIT license
above. The optional local demo uses the SDK's Haru sample, subject to its model
terms and sample notices.

Astray's native particle runtime, camera shader formulas, UI measurements and
Tools/fx_convert.py are ports or copies of the reference project named above,
covered by its MIT notice. Reference files are pinned at v0.6.0.

Source Han Sans JP Bold and Medium are copied without modification from the
reference project's assets. Their SIL Open Font License is retained at
Astray/Resources/Fonts/LICENSE.txt.

Haruki CDN path mapping in Scripts/fetch-haruki-fixture.py and
Astray/Assets/HarukiAssetResolver.swift follows the public
Haruki-Toolbox story resolver (https://github.com/Team-Haruki/Haruki-Toolbox),
Copyright (c) 2025 Haruki Dev Team, under the MIT license text above. Downloaded game
assets stay in .build and retain their original rightsholders' terms; no game
asset is included in the source distribution. The fixture provenance records
source URLs and SHA-256 digests.

Additional compatibility behavior is compared with the user-supplied Cleista
JavaScript files, including full-screen text processing and style definitions,
lip-sync targets, facial curves and character shader state. The differential
harness reads the original local files and records their SHA-256 digests in
Tests/Fixtures/cleista-reference.json. These files are separate from the MIT
reference project above; no Cleista JavaScript runtime or game assets are
bundled into Astray.framework or the demo application.
