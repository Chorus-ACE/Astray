import Metal
import Astray
import ImageIO
import Foundation
import CoreGraphics
import UniformTypeIdentifiers

@main
@MainActor
private struct HarukiTests {
    private static func wait(_ buffer: any MTLCommandBuffer) { buffer.waitUntilCompleted() }
    
    private static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let assets = root.appending(path: ".build/HarukiAssets")
        let output = root.appending(path: ".build/TestArtifacts/Haruki")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try Scenario.decode(Data(contentsOf: assets.appending(path: "scenario/mmj_01_06.json")))
        let resolver: any AssetResolving
        if let input = ProcessInfo.processInfo.environment["ASTRAY_HARUKI_CDN_ROOT"], let url = URL(string: input) {
            resolver = try await HarukiAssetResolver(baseURL: url, scenario: scene)
        } else {
            resolver = DirectoryAssetResolver(baseURL: assets)
        }
        let player = StoryPlayer()
        var warnings: [String] = []
        player.onEvent = { if case .warning(let error) = $0 { warnings.append(error.localizedDescription) } }
        try await player.load(scene, resolver: resolver)
        guard warnings.isEmpty else { throw Failure.message(warnings.joined(separator: "\n")) }
        let renderer = try StoryRenderer(player: player)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1280,
            height: 720,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        let target = renderer.device.makeTexture(descriptor: descriptor)!
        try continuousPlayback(player: player, renderer: renderer, target: target, scene: scene)
        let talks = scene.snippets.indices.filter { scene.snippets[$0].action == .talk }
        var frames = 0
        for (sample, index) in talks.enumerated() where sample % 10 == 0 {
            try player.jump(to: index)
            player.advance(by: 0.3)
            player.advance()
            let buffer = try renderer.render(to: target)
            wait(buffer)
            guard buffer.status == .completed else { throw Failure.message("Real story GPU command failed") }
            try snapshot(target, to: output.appending(path: "story-\(sample).png"))
            frames += 1
        }
        try player.jump(to: 0)
        for _ in 0..<30 {
            player.advance(by: 1 / 30)
            let buffer = try renderer.render(to: target)
            wait(buffer)
            guard buffer.status == .completed else { throw Failure.message("SEKAI prefab GPU command failed") }
        }
        try snapshot(target, to: output.appending(path: "sekai-transition.png"))
        guard warnings.isEmpty else { throw Failure.message(warnings.joined(separator: "\n")) }
        player.stop()
        let allModels = scene.characters.map { character -> ScenarioInitialLayout in
            let pose = scene.layouts.first { $0.characterID == character.characterID }
            return .init(
                side: 4,
                characterID: character.characterID,
                costume: character.costume,
                motion: pose?.motion ?? "",
                facial: pose?.facial ?? ""
            )
        }
        try await player.load(
            .init(initialLayout: allModels, initialBackground: scene.initialBackground),
            resolver: resolver
        )
        let allModelBuffer = try renderer.render(to: target)
        wait(allModelBuffer)
        guard allModelBuffer.status == .completed, warnings.isEmpty else {
            throw Failure.message("All six game models must decode and render successfully")
        }
        let first = scene.layouts.first { !$0.costume.isEmpty }!
        let comparison = Scenario(
            initialLayout: [
                .init(
                    side: 4,
                    characterID: first.characterID,
                    costume: first.costume,
                    motion: first.motion,
                    facial: first.facial
                )
            ],
            initialBackground: scene.initialBackground
        )
        try JSONEncoder().encode(comparison).write(to: assets.appending(path: "comparison-scene.json"))
        try await player.load(comparison, resolver: resolver)
        wait(try renderer.render(to: target))
        try snapshot(target, to: output.appending(path: "native-pose.png"))
        print(
            "PASS: real Haruki mmj_01_06, 6 game models, motion/facial libraries, physics, 68 lines, 232 snippets, background prefab and SEKAI transition; \(frames) scene snapshots without asset or GPU warnings."
        )
    }
    
    private static func continuousPlayback(
        player: StoryPlayer,
        renderer: StoryRenderer,
        target: any MTLTexture,
        scene: Scenario
    ) throws {
        player.play()
        var captionDismissed = false
        var firstLineDismissed = false
        var firstLineTime = 0.0
        var secondLineTime = 0.0
        let firstBody = scene.talks[0].body.replacingOccurrences(of: "\\n", with: "\n")
        let secondBody = scene.talks[1].body.replacingOccurrences(of: "\\n", with: "\n")
        for frame in 0..<900 {
            player.advance(by: 1 / 60)
            if !captionDismissed && !player.stage.caption.isEmpty && player.stage.captionTransform.z >= 0.999 {
                player.advance()
                captionDismissed = true
            }
            if player.dialogue.isVisible && player.dialogue.body == firstBody {
                firstLineTime += 1 / 60
                if firstLineTime >= 1.5 && !firstLineDismissed {
                    if player.dialogue.isTyping { player.advance() }
                    player.advance()
                    firstLineDismissed = true
                }
            }
            if player.dialogue.isVisible && player.dialogue.body == secondBody { secondLineTime += 1 / 60 }
            if frame.isMultiple(of: 2) {
                let buffer = try renderer.render(to: target)
                wait(buffer)
                guard buffer.status == .completed else { throw Failure.message("Continuous story GPU command failed") }
            }
            if secondLineTime >= 1 { break }
        }
        guard captionDismissed, firstLineDismissed, firstLineTime >= 1.5, secondLineTime >= 1 else {
            throw Failure.message(
                "Continuous playback did not pass both opening dialogues and their motion event times"
            )
        }
        player.stop()
        print(
            "PASS: continuous opening playback, caption click, first-line motion event at 0.517 s and manual advance to the second dialogue."
        )
    }
    
    private static func snapshot(_ texture: any MTLTexture, to url: URL) throws {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(
            &bytes,
            bytesPerRow: texture.width * 4,
            from: .init(
                origin: .init(x: 0, y: 0, z: 0),
                size: .init(width: texture.width, height: texture.height, depth: 1)
            ),
            mipmapLevel: 0
        )
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(
            width: texture.width,
            height: texture.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: texture.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: .init(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.message("Unable to write story snapshot") }
    }
    
    private enum Failure: Error { case message(String) }
}
