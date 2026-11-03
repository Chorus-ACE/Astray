# Astray

Astray 是用于 iOS、macOS 和 visionOS 的 Swift 故事播放器 framework。它参考本仓库中 `sekai-scenario-player` 的 `ScenarioSceneData` 格式和并行时间线，以 Metal 渲染原生 Cubism 模型、背景、Unity prefab / Shuriken 特效、对话、字幕、选择按钮与转场。SwiftUI、UIKit 和 AppKit 应用都可以嵌入。

Shader 位于 `Astray/Rendering/StoryShaders.metal` 与 `CubismShaders.metal`。Xcode 的 Compile Sources 阶段将其编译并链接为 framework 内的 `default.metallib`；运行时通过 `makeDefaultLibrary(bundle:)` 加载。没有运行时 Shader 源码字符串或 Shader 编译。

## 构建与运行

使用 Xcode 27.2 或更新版本打开 `Astray.xcodeproj`，选择 `Astray` scheme。项目使用 Xcode 的 `.xcproj` 项目格式，最低系统版本为 iOS 18、macOS 15、visionOS 2。

源码依赖通过 Git submodule 固定版本；Core 是官方单独分发的专有运行时，不进入 Git。首次构建：

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

`run-demo.sh` 默认以 Release 构建并启动 macOS 示例应用，包含导入 JSON、素材根地址、手动推进、自动、快进、暂停和台词跳转。`--build-only` 只构建；调试框架可使用 `ASTRAY_DEMO_CONFIGURATION=Debug Scripts/run-demo.sh`。无需游戏素材即可播放自带示例；窗口内的「Live2D 示例」使用 SDK 的 Haru 模型和本项目自制粒子数据，验证实际模型和特效链路。SDK 示例模型仅复制到 Git 忽略的构建目录。

「效果示例」使用同一 SDK 模型展示富文本、文字驱动口型，以及两名角色的模糊 / 显示器 / 全息材质切换。可以通过台词列表检查跳转后的效果恢复。

`Scripts/test.sh` 在 macOS 真正的 Metal 设备上运行，包含：

- 场景解码、时间线屏障、对话、暂停、跳转、取消、音频和 GPU 图层合成回归。
- 固定随机种子，直接执行参考项目未修改的 TypeScript 粒子实现，逐帧比对原生粒子的出生、位置、速度、寿命、颜色、曲线、UV、Custom1、顶点、prefab Sprite/Image 和 Animator。
- Unity YAML prefab 经原转换器和本地转换器产生相同 JSON，并将输出交给原生运行时。
- 八种擦除、DollyZoom、全屏文字、字幕、DOTween easing / shake 时序，以及编译后 Metal Shader 的像素结果。
- 官方 Haru 的真实 Core 解码、动作、表情、物理、Metal 遮罩、跳转重置；AVPlayer 实际视频解码、CVMetalTexture、暂停和电影结束转场。
- 头发物理逐顶点轨迹：在 60 Hz 帧间隔中交替加入纳秒 / 微秒抖动，验证无异常跳变；长帧均匀分步保持动作时间与物理轨迹，暂停不推进物理。真实章节测试会覆盖全部 6 套角色。
- Cleista 对照：30 组文字处理与样式、36 组语音 RMS 目标、38 个文字口型值、角色材质切换、四种动态表情曲线，以及实际 Metal 富文本渲染和文字纹理显存上限。
- 屏幕 backing scale、120 FPS 偏好、@1x / @2x / @3x 像素尺寸、Cubism 渲染元数据快照一致性，以及超过三帧排队时的缓冲隔离与 GPU 像素一致性。

图片位于 `.build/TestArtifacts/`。没有 Metal 设备时测试失败，不跳过 GPU 检查。测试需要 Node.js、npm、Python 3，会在参考子模块安装锁定的 npm 依赖，并在 `.build/fx-env` 安装转换器依赖。

## 帧率、分辨率与渲染性能

`MetalStoryView` 默认请求最高 120 FPS，实际刷新率由屏幕能力与系统调度决定。iPhone 宿主还需在应用的 Info.plist 设置 [`CADisableMinimumFrameDurationOnPhone = YES`](https://developer.apple.com/documentation/bundleresources/information-property-list/cadisableminimumframedurationonphone)，允许系统提供高于默认值的刷新率。

视图的 drawable 使用 `ceil(bounds × displayScale)`，随窗口调整、跨屏移动和 UIKit display-scale trait 更新；macOS 使用窗口的 backingScaleFactor。离屏场景、Cubism 纹理与文字栅格化均按 drawable 的实际像素计算，不会将 @2x / @3x 屏幕固定为逻辑点分辨率。相机模糊仍保留参考实现的半分辨率中间纹理。测试在本机实际 @2x 屏幕上检查了附着窗口及缩放后的 drawable，同时覆盖 @1x / @2x / @3x 尺寸换算和渲染目标；未在实体 @3x 设备上测量显示刷新率。

渲染器复用三组受 GPU 完成回调保护的动态几何缓冲，缓存 Cubism 的 UV / 索引与服装纹理，只在变化时更新排序、顶点边界和模型画面。组合遮罩使用同等像素密度的 R8 局部纹理，保留线性采样与反向遮罩；粒子网格每帧生成一次后分层复用。暂停且画面状态不变时不再提交重复帧。

本机 Apple M4、Release、真实章节三角色及背景 prefab、2560 × 1440 的离屏基准：CPU 中位帧耗时 **4.38 → 0.97 ms**，GPU 中位耗时 **14.56 → 3.55 ms**。两次均保持相同渲染尺寸和粒子设置。CPU 包含推进、编码和提交，GPU 使用 command buffer 时间戳；每帧串行等待完成，因此这些数字不代表屏幕持续呈现帧率。排除随机粒子后，相同模型动作在 1280 × 720 和 2560 × 1440 下与优化前逐像素对比，最大误差为单个通道 1/255，分别仅有 14 / 42 个通道值不同，alpha 完全相同。

```sh
Scripts/benchmark-render.sh
# Deterministic character frames without randomly seeded background particles:
Scripts/benchmark-render.sh --static
```

结果及 BGRA 原始帧保存于 `.build/TestArtifacts/Performance/`。在修改优化前可用 `--baseline` 保存基线；对比时应使用相同的 Release 配置并关闭其他 GPU 密集任务。

## Cleista 实现对照

本机 `cleista/` 提供了另一套播放器代码。本次对照集中于能够从随附文件确认的播放行为：

| 参考文件 | 原生改进 |
| --- | --- |
| `fulltext-processing.js`、`fulltext-styles.js`、`fulltext-richtext.js` | 全屏文字支持控制字符 / Unicode 转义、BR / NBSP / ZWSP、十种命名样式，以及字号、颜色 / alpha、粗体、斜体、下划线、段落对齐和缩进。未知标签保留为文字。Link 保留样式及内部标记，纹理文字不触发网页导航。 |
| `fulltext-sequence.js`、`index-8.js` | 连续全屏文字保留至少 8 个槽位及此前最大处理容量，较短后续页保留尾部等待；背景随黑边进场渐暗，台词列表显示处理后的正文。 |
| `lipsync.js`、`live2d.js` | `LipSync = 0` 使用 60 ms 文字口型序列，`900000` 支持同时说话；`LipSync = 2` 不驱动口型。语音目标在非线性增益后进行门限判断；口型平滑按真实时间校正，兼容 60 / 120 Hz。 |
| `cubism-curve.js`、`live2d.js` | motion3 表情的线性、贝塞尔、阶跃和反向阶跃曲线随时间更新，淡入时保留前一表情，结束后保持末帧。 |
| `character-shader-state.js`、`live2d.js` | 材质状态按角色保留，支持先附加再出场；重复 blur 保留原强度，none 只移除指定人物的效果，跳转和重播重建相应状态。 |
| `dialogue-hide.js` | 隐藏对话时，第一次点击恢复界面，随后点击才执行显示全文或推进。 |

文字纹理缓存另改为按实际 Metal 分配大小限制在 **32 MiB**，按最近使用顺序淘汰，避免逐字 alpha 动画缓存上百张整幅文字纹理。实际 GPU 分配测试覆盖 64 张 1200 × 400 文字纹理。

`Scripts/reference-cleista.cjs` 直接运行上述随附 JS 中的纯函数，差分结果记录在 `Tests/Fixtures/cleista-reference.json`，包含源文件 SHA-256。随附文件可用时重新生成对照；缺少本机参考目录时使用记录基线。使用 `node Scripts/reference-cleista.cjs --record` 可显式更新记录，截图输出到 `.build/TestArtifacts/Cleista/fulltext.png`。

随附 `effects.js` 的部分依赖（如 `scene-overlay-effects.js`、`native-ui-effect.js`、`native-particle-runs.js`）不在此目录中。本次保留已有的 Unity prefab / Shuriken Metal 渲染，并使用实际转换数据验证；这些缺少定义的 JS 分支没有被视为已完成差分验收。effect 11 / 17 / 37 的有效数据语义仍未能从随附文件确认。

Cubism Samples 固定 **5-r.4.1**，内层 Framework 固定相应提交；参考项目固定 **v0.6.0**。选择该 Core 以保留 iOS 18 / macOS 15 最低系统版本。该官方包的模拟器 Core 只有 **x86_64**，项目因此排除 iOS 模拟器 arm64；iOS 真机 arm64 和 macOS arm64 / x86_64 可使用 Live2D。官方包没有 visionOS Core，visionOS 可构建故事及特效渲染，但加载 MOC3 会明确报告 Core 不可用。
把 `Astray` target 加入宿主的依赖，并将 `Astray.framework` 设置为 **Embed & Sign**。必须嵌入整个 framework，使 `.metallib` 随框架一起分发。

## 真实资源验证

已从 Team-Haruki 公开资源中找到并验证实际剧情：

- [haruki-sekai-master](https://github.com/Team-Haruki/haruki-sekai-master) 提供日服剧情目录等主数据；同组织的 en / tc / sc / kr master 对应其他服务器。
- [Haruki-Sekai-Asset-Updater](https://github.com/Team-Haruki/Haruki-Sekai-Asset-Updater) 是资源提取和导出工具。
- [Haruki Toolbox 素材配置](https://github.com/Team-Haruki/Haruki-Toolbox/blob/main/src/modules/story/engine/urls.ts) 给出模型、动作、音频及 `story-player/v1/fx` / UI 的公开路径；[数据源配置](https://github.com/Team-Haruki/Haruki-Toolbox/blob/main/src/shared/sekai/data-sources.ts) 列出国内及全球 CDN。

```sh
Scripts/test-haruki.sh
# Reuse downloaded files, and compare the reference through an installed Edge/Chrome:
Scripts/test-haruki.sh --offline --browser
Scripts/run-demo.sh
```

验证章节为 MORE MORE JUMP! 主线 `mmj_01_06`，包括 6 套模型、68 行台词、232 个 snippet、舞台背景 prefab 和 SEKAI 转场。下载器将本章 224 个依赖（约 60 MB）转换为框架目录规则，仅保存在 `.build/HarukiAssets`，保留来源 URL、索引版本、大小及 SHA-256 到 `provenance.json`。不会将游戏资产加入 Git。实际资源下载器目前面向该主线验收章节；直接播放其他剧情可使用下述 `HarukiAssetResolver`。

设置 `ASTRAY_HARUKI_CDN_ROOT` 后运行 `Scripts/test-haruki.sh --offline`，会保留本机剧情 JSON，改用原始 CDN 解析器加载整章素材并完成相同的 Metal 播放验证。`--offline` 仅跳过整理后的验收素材下载；设置此环境变量时仍需联网。单独运行 `.build/AssetResolverTests --online` 可验证报告过的 `event_145_07` 语音路径。

原生测试保存场景截图，并将真实转换数据逐帧交给参考 TypeScript 和 Swift 比对。可选浏览器测试使用未修改的参考 Stage 与硬件 WebGL，在相同模型 / 动作和背景上与 Metal 截图比较，输出 `comparison.json`、`native-pose.png`、`reference-pose.png`。该测试需要安装 Edge 或 Chrome；其他 Chromium 可通过 `ASTRAY_BROWSER_PATH` 指定。Web Core 来自官方 CDN，沿用已同意的 Live2D 许可。

已下载资源时，macOS 示例还会显示「真实剧情示例」按钮。原始剧情及 UI / 模型资源遵循各自权利方的条款，本地验证下载不构成对它们的再授权。

## 嵌入

播放器和渲染器均由主 actor 管理。创建一个播放器、一个渲染器，保持它们在视图生命周期内存活：

```swift
import Astray
import SwiftUI

@MainActor
struct ReaderView: View {
    @State private var player: StoryPlayer
    private let renderer: StoryRenderer
    
    init() throws {
        let player = StoryPlayer()
        _player = State(initialValue: player)
        renderer = try .init(player: player)
    }
    
    var body: some View {
        StoryView(renderer: renderer)
            .task {
                do {
                    let resolver = DirectoryAssetResolver(
                        baseURL: URL(string: "https://example.com/assets/")!
                    )
                    try await player.load(id: "episode_01", resolver: resolver)
                    player.play()
                } catch {
                    // Present the load error in the host application.
                }
            }
    }
}
```

UIKit / AppKit 使用 `MetalStoryView(renderer:)`。故事按 1280×720 逻辑画布绘制，视图自动保持 16:9 并添加留边。点击画面或在 macOS 按空格推进；第一次点击显示整句，第二次结束当前台词。选择按钮通过点击选取。

也可以加载本地或内存场景：

```swift
try await player.load(data: jsonData, resolver: resolver)
try await player.load(Scenario(
    snippets: [.init(action: .talk, referenceIndex: 0)],
    talks: [.init(body: "Hello")]
))
```

通过 `Scenario.snippets` 引用对应的 `talks`，`load` 后调用 `play()`。完整可运行场景见 `Examples/demo.json`，宿主完整示例见 `Examples/PlayerDemo.swift`。

## 播放与事件

```swift
player.isAutomatic = true
player.isFastForwarding = false
player.isDialogueHidden = false
player.setVolume(bgm: 0.7, voice: 1, sound: 1)
player.pause()
player.play()
player.advance()
try player.jump(to: line.snippetIndex)
player.stop()
```

`load` 预载成功后停在 `.ready`，调用 `play()` 开始。`stop()` 回到初始状态；重播可调用 `stop()` 再 `play()`。`jump(to:)` 的索引是 **Snippets 数组位置**，不是 JSON 的 `Index` 字段或 TalkData 索引；可传数组长度跳到结束。跳转保留暂停状态，其余状态会开始播放。`transcript` 提供可跳转的台词及字幕。

`status`、`stage`、`dialogue`、`snippetIndex` 等属性可被 Swift Observation 观察。事件回调用于进度、素材警告和宿主扩展：

```swift
player.onEvent = { event in
    switch event {
    case .loadProgress(let completed, let total):
        print(completed, total)
    case .selected(let index, let value):
        print(index, value)
    case .warning(let error):
        print(error.localizedDescription)
    case .unsupportedAction(let index, _, let detail):
        print(index, detail)
    default:
        break
    }
}
```

场景解析、无效引用和场景 URL 加载失败会抛出错误；可选图片、音频失败会发出警告并继续播放。`resolver` 返回 `nil` 表示宿主有意省略素材。取消调用 `load` 的任务会取消预载；在加载中 `stop` 或再次 `load` 会使旧结果失效。素材按最多六个并发请求预载，网络请求有 30 秒超时；每次加载替换上一集的缓存。

## 素材

`DirectoryAssetResolver` 使用整理后的素材目录，背景、剧情及音频布局遵循参考项目，并增加 PNG 立绘目录：

```text
assets/
├── scenario/<ScenarioId>.json
├── background/<id>.png
├── character/<CostumeType>.png
├── model_manifest.json
├── <modelDir>/<modelFile>.model3.json
├── motions/<motionDir>/<motionBase>/{motion,facial}/<name>.motion3.json
├── fx/<effectName>/effect.json
├── fx/<effectName>/<texture>.png
├── fx/bg/index.json
├── ui/...
└── sound/
    ├── bgm/<id>.mp3
    ├── se/<id>.mp3
    └── voice/<ScenarioId>/<VoiceId>.mp3
```

`DirectoryAssetResolver` 同时支持 `file:` 和 HTTP(S) 根地址。Haruki 原始 CDN 的目录不同，使用 `HarukiAssetResolver`：

```swift
let scenario = try Scenario.decode(jsonData)
let resolver = try await HarukiAssetResolver(
    baseURL: URL(string: "https://sekai-assets-cn03-she01-cdn.haruki.seiunx.com/cn-assets/ondemand")!,
    scenario: scenario
)
try await player.load(scenario, resolver: resolver)
```

Demo 的「素材根目录 / URL」会自动识别这种地址。与 Haruki 网页一致，播放素材统一使用同主机的 `jp-assets/`，保留导入 JSON 的剧情文本；输入地区根目录或 `ondemand` / `startapp` 子目录均可。界面会显示实际播放素材根地址。例如语音解析为 `jp-assets/ondemand/sound/scenario/voice/<ScenarioId>/<VoiceId>.mp3`，并按剧情类型尝试其他合法目录。模型索引来自 `story-player/index.json`，解析器同时适配导出的 physics 文件名、共用及服装专属动作、背景、BGM、SE、part voice、视频，以及 `story-player/v1` 的 prefab 和 UI。part voice 与活动专属 SE 需要查询日服公开主数据。

要使用其他命名、格式或主机，实现 `AssetResolving.url(for:)`；可通过 `urls(for:)` 提供依次尝试的候选地址，或通过 `data(for:)` 适配资源数据。已有仅实现 `url(for:)` 的解析器继续使用默认加载实现。音频由 AVAudioPlayer 解码，可解析到平台支持的其他格式。音频会预载到内存，适合按集加载。

立绘以透明背景、底部居中显示，左右站位和三人布局取自参考实现的 1920 宽画布规则。图片和文字统一转换为 sRGB 预乘 alpha 位图后上传为 Metal 纹理；动态角色接口返回的纹理也需要预乘 alpha。文字通过 CoreText 使用框架自带的参考 Source Han Sans JP Bold / Medium 字体及 Unicode 字体回退，无需安装字体。

## Live2D

无需宿主适配器：`model_manifest.json` 的格式与参考项目一致，键是 `CostumeType`：

```json
{
  "costume_01": {
    "modelDir": "models/costume_01",
    "modelFile": "character.model3.json",
    "motionDir": "character_01",
    "motionBase": "base"
  }
}
```

相对 model3.json 加载 MOC、纹理、physics3、pose3、模型内声明的 motions / expressions，并按 manifest 加载剧情引用的身体 motion3 与 facial motion3。`motionDir` / `motionBase` 对仅使用模型自带动作的 SDK 模型可省略。模型内动作缺少 Name 时使用 `<group>_<index>`，例如 `Idle_0`。

官方 C++ Framework 负责 MOC、动作淡入淡出、表情、物理和 pose。Objective-C++ 桥接保持内部模块边界；Swift Metal 管线按 drawable 的 render order、纹理、剔除、Multiply / Screen Color、normal / additive / multiplicative blend、组合遮罩及反向遮罩绘制。角色先合成为预乘纹理，透明度应用于完整角色；离屏分辨率随视图实际像素高度调整，并为超出原模型画布的 drawable 扩展透明边界，保留动作与模糊边缘。身体动作、独立 facial、facial 静态参数保持、参考 blink / breath 与语音平滑口型由运行时更新。

`StoryRenderer.characterRenderer` 仍可接管角色，返回 `nil` 时使用内置 Cubism，再回退到 costume PNG。自定义 `CharacterRendering` 使用传入设备和 command buffer，返回预乘 alpha 纹理，在返回前结束 encoder，不能提交该 buffer。`reset()` 随新加载、停止和跳转触发。

## Unity prefab / Shuriken

使用与参考项目相同的转换格式和工具，不需要宿主实现粒子系统：

```sh
python3 -m venv .build/fx-env
.build/fx-env/bin/python -m pip install -r Tools/requirements.txt
FX_RAW_DIR=/path/to/raw-bundles .build/fx-env/bin/python -I Tools/fx_convert.py \
  /path/to/AssetRipper/Assets /path/to/assets/fx effect_name
# Standalone prefab, including SEKAI transition prefabs:
.build/fx-env/bin/python -I Tools/fx_convert.py /path/to/Assets /path/to/assets/fx \
  --prefab=/path/to/example.prefab --name=example --unit=540
```

`Tools/fx_convert.py` 保留原转换器。AssetRipper 导出层级、材质、纹理、Sprite、AnimatorController 和 AnimationClip；`FX_RAW_DIR` 指向原 bundle，以 UnityPy 解析导出缺失的 UI Image / 脚本字段。将 `effect.json` 及转换后的纹理放到 `fx/<name>/`。背景 prefab 放到 `fx/bg/<backgroundID>/`，并在 `fx/bg/index.json` 的字符串数组中列出 ID；SEKAI 使用 `sekai_transition` / `sekai_transition_3anv`，角色附着光效使用 `hologram`。

原生支持参考运行时的层级 / RectTransform、激活边缘、SpriteRenderer / UI Image、Canvas 排序、Animator 默认状态 / exit-time 转移 / Stop clip、位置 / 缩放 / Euler / 浮点属性曲线和材质 ST 动画。粒子支持 MinMaxCurve / Gradient、Hermite 曲线、初始属性、延迟 / 预热 / 循环、发射率 / burst、球 / 半球 / 锥 / 圆 / 边 / 盒形状、局部 / 世界模拟、重力、速度 / radial / speed modifier、速度限制 / drag、噪声、旋转、大小及按速度大小、颜色、纹理表动画、Custom1.x 混合控制、birth / death sub-emitter 与属性继承、billboard / stretched billboard / pivot，以及 additive / alpha / multiply 材质。

效果按 bottom → 背景及背景 prefab → back → 角色 → front → top 合成，之后执行相机后处理及独立 UI。重复 Play 可同时存在多个实例；Stop 播放停止 clip 并排空粒子，快进强制停止；跳转按参考方式恢复并预运行效果。

覆盖范围以参考项目实际解释的 Unity 子集为准。原转换器丢弃的 Collision / Trigger / Lights / ExternalForces 等模块、参考运行时未绘制的 MeshRenderer / mesh particles 不会变成完整 Unity 引擎功能。

## 时间线与覆盖范围

每个 snippet 在自己的延迟之后启动。`Now` 允许与前面的 snippet 并行；`WaitFinished` 等待所有先前 snippet，包括延迟中的 snippet。音频和动作切换不阻塞后续屏障，对话等待推进，布局与转场等待相应动画。角色出现的淡入结束即可释放屏障，滑入仍可继续。时间线时钟驱动打字、布局、淡入淡出、镜头和延迟音效，快进加速三倍并跳过语音；Cubism、粒子、hologram 和电影使用未加速的视觉时钟，与参考项目一致。暂停冻结播放。跳转清除旧的运行任务并重放目标之前的状态操作。

已实现的主要行为：

- 台词打字、手动 / 自动 / 快进、全屏文字、字幕、地点提示、台词列表、SimpleSelectable 选择事件。
- 角色出现、隐藏、移动、震动、动作 / 表情状态、前后层级、两人 / 三人站位、语音音量驱动的口型。
- 背景交叉淡入、黑白遮罩、四方向擦除、画面 / 窗口震动、环境颜色、灰度 / 棕褐色、镜头移动与缩放、背景 / 角色模糊、扫描线角色效果。
- BGM 交叉渐变、音量控制、SE 延迟播放与停止、语音播放与暂停。
- `StoryRenderer.render(to:)` 离屏渲染接口，供测试、预览或宿主导出使用。目标纹理须在同一设备上，格式为 BGRA8Unorm、单采样且具有 renderTarget usage。提交的 command buffer 由方法返回。

Metal 实现保留参考项目的完整 RGBA 转场、SEKAI 延迟与 prefab、512-ref 羽化擦除、DOTween shake、环境色、flashback / sepia 色矩阵、相机六次高斯模糊、背景十四采样 Gaussian / Dolly 径向畸变、Cubism 四次 Gaussian 模糊、hologram / monitor 的噪声采样和闪烁；UI 使用参考尺寸、字体、字幕曲线、全屏文字逐字 alpha / 电影黑边、地点进出和选择框时序。Movie 使用 AVPlayer 解码并通过 CVMetalTexture 合成。

`InputName`、原始 `Selectable` 分支 schema、游戏音频中间件模式仍与参考项目的边界一致；不能解释时发出 `unsupportedAction`。SimpleSelectable 发送选择事件，不隐式跳转。参考没有实现的 effect 11 / 17 / 37 保持无操作。

数值差分和 GPU 测试用于验证实现；真实 Haruki 章节已完成资源加载、GPU 截图和代表性画面对照；这不等于每个游戏场景已经完成逐帧、逐像素验收。提供相同素材时，框架直接使用转换后的资源和上述 Metal 管线，不以简化特效替代缺失资源。
## 参考与许可

时间线语义、枚举值、站位以及兼容 JSON 字段参考 `sekai-scenario-player/src/scenario/` 与其 `docs/internals.md`。参考项目以 MIT 许可发布，相关版权声明及测试示例来源见 `THIRD_PARTY_NOTICES.md`。本项目不分发游戏素材；Core 安装到 Git 忽略目录，仅本机链接。Live2D SDK、Core 与 SDK 示例模型遵循各自许可，详见 `Vendor/CubismNativeSamples/LICENSE.md`、`NOTICE.md` 和 Core 包许可。
