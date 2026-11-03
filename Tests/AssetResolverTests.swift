import Foundation
@testable import Astray

@main
@MainActor
private struct AssetResolverTests {
    private static func main() async throws {
        let host = "https://sekai-assets-cn03-she01-cdn.haruki.seiunx.com/"
        for suffix in ["cn-assets/ondemand", "cn-assets/ondemand/", "jp-assets", "jp-assets/startapp", ""] {
            let root = HarukiAssetResolver.japaneseAssetRoot(for: URL(string: host + suffix)!)
            try expect(
                root?.absoluteString == host + "jp-assets/",
                "Normalize a Haruki tree or subtree without duplicate components"
            )
        }
        try expect(
            HarukiAssetResolver.japaneseAssetRoot(for: URL(string: "https://example.com/assets/")!) == nil,
            "Keep arranged asset directories separate"
        )
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(
            path: ".build/TestArtifacts/Resolver/\(UUID().uuidString)"
        )
        let jp = root.appending(path: "jp-assets")
        let index: [String: Any] = [
            "models": [
                "hero": [
                    "dir": "startapp/live2d/model/hero", "model3": "hero.model3", "physics": "hero.physics3",
                    "motionBase": "startapp/live2d/motion/base", "motions": ["extra"],
                ],
                "sibling": [
                    "dir": "startapp/live2d/model/sibling", "model3": "sibling.model3",
                    "motionBase": "startapp/live2d/motion/base", "motions": ["shared"],
                ],
            ],
            "movies": ["opening": "ondemand/movie/opening.mp4"],
            "se": ["door": "startapp/sound/scenario/se/common/door.mp3"],
        ]
        func write(_ name: String, _ data: Data) throws {
            let url = jp.appending(path: name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
        try write("story-player/index.json", JSONSerialization.data(withJSONObject: index))
        try write(
            "startapp/live2d/model/hero/hero.model3",
            Data(
                #"{"FileReferences":{"Moc":"hero.moc3","Textures":["texture.png"],"Physics":"hero.physics3.json"}}"#
                    .utf8
            )
        )
        for file in ["hero.moc3", "texture.png", "hero.physics3"] {
            try write("startapp/live2d/model/hero/" + file, Data(file.utf8))
        }
        try write("startapp/live2d/motion/base/motion/idle.motion3.json", Data("motion".utf8))
        try write("startapp/live2d/motion/base/facial/face.motion3.json", Data("facial".utf8))
        try write("startapp/scenario/background/bg/bg.png", Data("background".utf8))
        try write("startapp/sound/scenario/bgm/bgm/bgm.mp3", Data("bgm".utf8))
        try write("ondemand/sound/card_scenario/voice/event_145_07/line.mp3", Data("voice".utf8))
        let scene = Scenario(
            id: "event_145_07",
            initialLayout: [.init(characterID: 1, costume: "hero", motion: "IDLE", facial: "FACE")]
        )
        let resolver = try await HarukiAssetResolver(
            baseURL: root.appending(path: "cn-assets/ondemand"),
            scenario: scene
        )
        try expect(
            resolver.baseURL.path == jp.path + "/" || resolver.baseURL.path == jp.path,
            "Resolve the Japanese playback tree from CN input"
        )
        let request = AssetRequest.voice(scenario: "event_145_07", id: "voice_ev_night_18_07_22_20")
        try expect(
            resolver.url(for: request)?.path
                == jp.appending(path: "ondemand/sound/scenario/voice/event_145_07/voice_ev_night_18_07_22_20.mp3").path,
            "Exact reported voice hierarchy"
        )
        try expect(
            resolver.url(
                for: .motion(directory: "startapp/live2d/model/hero", base: "base", kind: "motion", name: "EXTRA")
            )?.path.hasSuffix("hero/motions/extra.motion3.json") == true,
            "Costume-only motion lookup"
        )
        try expect(
            resolver.url(
                for: .motion(directory: "startapp/live2d/model/hero", base: "base", kind: "motion", name: "SHARED")
            )?.path.hasSuffix("sibling/motions/shared.motion3.json") == true,
            "Sibling costume motion lookup"
        )
        try expect(
            resolver.url(for: .sound("door"))?.path.hasSuffix("startapp/sound/scenario/se/common/door.mp3") == true,
            "Indexed shared sound"
        )
        try expect(
            resolver.url(for: .movie("opening"))?.path.hasSuffix("ondemand/movie/opening.mp4") == true,
            "Indexed movie"
        )
        try expect(
            resolver.url(for: .effect("rain/effect.json"))?.path.hasSuffix("story-player/v1/fx/rain/effect.json")
                == true,
            "Converted prefab root"
        )
        try expect(
            resolver.url(for: .voice(scenario: "../private", id: "line")) == nil,
            "Reject traversal in identifiers"
        )
        try expect(resolver.url(for: .effect("../private")) == nil, "Reject traversal in prefab paths")
        try expect(
            try await resolver.data(for: .background("bg")) == Data("background".utf8),
            "Background candidate fallback"
        )
        try expect(try await resolver.data(for: .bgm("bgm")) == Data("bgm".utf8), "BGM candidate fallback")
        var loadedVoice = false
        try await AssetLoader.load([.voice(scenario: scene.id, id: "line")], resolver: resolver) { result, _, _ in
            loadedVoice = result.error == nil && result.data == Data("voice".utf8)
        }
        try expect(loadedVoice, "Generic preloading uses resolver candidates")
        var warnings: [String] = []
        let models = try await Live2DAssetLoader.load(scenario: scene, resolver: resolver) {
            warnings.append($0.localizedDescription)
        }
        try expect(warnings.isEmpty, "Raw model metadata resolves all referenced resources")
        try expect(models["hero"]?.physics == Data("hero.physics3".utf8), "Exported physics filename override")
        try expect(
            models["hero"]?.motions["IDLE"] == Data("motion".utf8)
                && models["hero"]?.facials["FACE"] == Data("facial".utf8),
            "Case-insensitive motion paths retain scenario names"
        )
        let arranged = DirectoryAssetResolver(baseURL: root)
        try expect(
            arranged.url(for: .voice(scenario: scene.id, id: "line"))?.path.hasSuffix(
                "sound/voice/event_145_07/line.mp3"
            ) == true,
            "Preserve arranged directory compatibility"
        )
        if CommandLine.arguments.contains("--online") {
            let online = try await HarukiAssetResolver(
                baseURL: URL(string: host + "cn-assets/ondemand")!,
                scenario: .init(id: scene.id)
            )
            try expect(
                online.url(for: request)?.absoluteString == host
                    + "jp-assets/ondemand/sound/scenario/voice/event_145_07/voice_ev_night_18_07_22_20.mp3",
                "Exact reported online URL"
            )
            let data = try await online.data(for: request)
            try expect((data?.count ?? 0) > 1000, "Reported voice downloads successfully")
            print("PASS: reported Haruki voice downloads from the same JP URL as the reference webpage.")
        }
        print(
            "PASS: Haruki subtree normalization, manifest adaptation, physics, motions, media candidates and arranged-directory compatibility."
        )
    }
    
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.message(message) }
    }
    
    private enum Failure: Error { case message(String) }
}
