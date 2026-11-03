import Metal
import ImageIO
import Foundation
import CoreGraphics
import UniformTypeIdentifiers
@testable import Astray

@main
@MainActor
private struct EffectsTests {
    private static var comparisons = 0
    
    private static func expect(_ value: Bool, _ message: String) throws {
        comparisons += 1
        if !value { throw TestError.failure(message) }
    }
    
    private static func close(_ value: Double, _ expected: Double, _ path: String, tolerance: Double = 1e-7) throws {
        try expect(abs(value - expected) <= tolerance * max(1, abs(expected)), "\(path): \(value) != \(expected)")
    }
    
    private static func compare(_ values: [Double], _ expected: EffectValue, _ path: String, tolerance: Double = 1e-7)
        throws
    {
        try expect(values.count == expected.array.count, "\(path) size: \(values.count) != \(expected.array.count)")
        for (index, value) in values.enumerated() {
            try close(value, expected[index].number(), "\(path)[\(index)]", tolerance: tolerance)
        }
    }
    
    private static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output =
            ProcessInfo.processInfo.environment["ASTRAY_EFFECT_FIXTURE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? root.appending(path: ".build/TestArtifacts/Effects")
        let document = try JSONDecoder().decode(
            EffectValue.self,
            from: Data(contentsOf: output.appending(path: "coverage.json"))
        )
        let reference = try JSONDecoder().decode(
            EffectValue.self,
            from: Data(contentsOf: output.appending(path: "reference.json"))
        )
        let effect = try PrefabEffect(document: document, seed: 1)
        let frames = Dictionary(uniqueKeysWithValues: reference.array.map { (Int($0["frame"].number()), $0) })
        for frame in 0..<45 {
            if frame == 30 { effect.stop() }
            effect.update(1 / 30)
            guard let expected = frames[frame] else { continue }
            let state = effect.state == .playing ? "play" : effect.state == .stopping ? "stopping" : "dead"
            try expect(state == expected["state"].string, "Effect lifecycle at frame \(frame)")
            for sprite in expected["sprites"].array where sprite["visible"].isEnabled {
                let node = Int(sprite["node"].number())
                let mesh = effect.meshes().first { $0.sequence == node * 2 + 1 }!
                let halfWidth = sprite["width"].number() / 2
                let halfHeight = sprite["height"].number() / 2
                let angle = sprite["rotation"].number()
                let center = sprite["position"].array.map { $0.number() }
                let corners: [SIMD2<Double>] = [
                    .init(-halfWidth, -halfHeight), .init(halfWidth, -halfHeight), .init(halfWidth, halfHeight),
                    .init(-halfWidth, halfHeight),
                ]
                for (index, corner) in corners.enumerated() {
                    try close(
                        Double(mesh.vertices[index].position.x),
                        center[0] + corner.x * cos(angle) - corner.y * sin(angle),
                        "Prefab sprite X",
                        tolerance: 1e-6
                    )
                    try close(
                        Double(mesh.vertices[index].position.y),
                        center[1] + corner.x * sin(angle) + corner.y * cos(angle),
                        "Prefab sprite Y",
                        tolerance: 1e-6
                    )
                    try close(
                        Double(mesh.vertices[index].color.w),
                        sprite["alpha"].number(),
                        "Prefab sprite alpha",
                        tolerance: 1e-6
                    )
                }
            }
            for emitter in expected["emitters"].array {
                let node = Int(emitter["node"].number())
                let actual = effect.emitters[node]!
                let path = "frame[\(frame)].emitter[\(node)]"
                try expect(
                    actual.particles.count == emitter["particles"].array.count,
                    "\(path) particle count \(actual.particles.count) != \(emitter["particles"].array.count)"
                )
                for (index, particle) in actual.particles.enumerated() {
                    let expected = emitter["particles"][index]
                    let prefix = path + ".particle[\(index)]"
                    try compare(particle.randoms, expected["randoms"], prefix + ".randomsBeforePosition")
                    try close(particle.lifetime, expected["life"].number(), prefix + ".lifeBeforePosition")
                    try compare(
                        [particle.position.x, particle.position.y, particle.position.z],
                        expected["position"],
                        prefix + ".position"
                    )
                    try compare(
                        [particle.velocity.x, particle.velocity.y, particle.velocity.z],
                        expected["velocity"],
                        prefix + ".velocity"
                    )
                    try close(particle.age, expected["age"].number(), prefix + ".age")
                    try close(particle.lifetime, expected["life"].number(), prefix + ".life")
                    try close(particle.angle, expected["rotation"].number(), prefix + ".rotation")
                    try compare(
                        [particle.size.x, particle.size.y, particle.size.z],
                        expected["size"],
                        prefix + ".size"
                    )
                    try compare(
                        [particle.color.x, particle.color.y, particle.color.z, particle.color.w],
                        expected["color"],
                        prefix + ".color"
                    )
                    try compare(particle.randoms, expected["randoms"], prefix + ".randoms")
                }
                let mesh = actual.mesh(visible: true)
                try compare(
                    mesh?.vertices.flatMap { [Double($0.position.x), Double($0.position.y)] } ?? [],
                    emitter["positions"],
                    path + ".vertices",
                    tolerance: 1e-6
                )
                try compare(
                    mesh?.vertices.flatMap { [Double($0.uv.x), Double($0.uv.y)] } ?? [],
                    emitter["uv"],
                    path + ".uv",
                    tolerance: 1e-6
                )
                try compare(
                    mesh?.vertices.flatMap {
                        [Double($0.color.x), Double($0.color.y), Double($0.color.z), Double($0.color.w)]
                    } ?? [],
                    emitter["colors"],
                    path + ".colors",
                    tolerance: 1e-6
                )
                try compare(
                    mesh?.vertices.map { Double($0.keep) } ?? [],
                    emitter["keep"],
                    path + ".customAlpha",
                    tolerance: 1e-6
                )
            }
        }
        let converted = try JSONDecoder().decode(
            EffectValue.self,
            from: Data(contentsOf: root.appending(path: ".build/TestArtifacts/Converter/native/fixture/effect.json"))
        )
        let convertedEffect = try PrefabEffect(document: converted, seed: 1)
        convertedEffect.update(0.5)
        try expect(!convertedEffect.meshes().isEmpty, "Converted Unity prefab runs in the native Shuriken runtime")
        try await timing(at: output)
        try await timeline(at: output)
        try await render(document, at: output)
        print(
            "PASS: \(comparisons) differential assertions against the unmodified reference Shuriken implementation, plus real Metal particle rendering."
        )
    }
    
    private static func timing(at output: URL) async throws {
        let reference = try JSONDecoder().decode(
            EffectValue.self,
            from: Data(contentsOf: output.appending(path: "timing-reference.json"))
        )
        for easing in reference["easing"].array {
            for sample in easing["samples"].array {
                try close(
                    EffectTiming.ease(easing["name"].string, sample[0].number()),
                    sample[1].number(),
                    "Easing \(easing["name"].string)"
                )
            }
        }
        for data in reference["shakes"].array {
            let shake = EffectShake(
                duration: data["duration"].number(),
                strength: 10,
                vibrato: 16,
                fadeOut: true,
                ignoreZ: data["ignoreZ"].isEnabled,
                seed: 1
            )
            for sample in data["samples"].array {
                let actual = shake.offset(at: sample[0].number())
                try close(Double(actual.x), sample[1].number(), "Shake X", tolerance: 1e-6)
                try close(Double(actual.y), sample[2].number(), "Shake Y", tolerance: 1e-6)
            }
        }
    }
    private static func timeline(at output: URL) async throws {
        let reference = try JSONDecoder().decode(
            EffectValue.self,
            from: Data(contentsOf: output.appending(path: "timing-reference.json"))
        )
        for (index, wipe) in reference["wipes"].array.enumerated() {
            let player = StoryPlayer()
            try await player.load(
                .init(
                    snippets: [.init(action: .specialEffect, referenceIndex: 0)],
                    effects: [.init(type: 29 + index, duration: 1)]
                )
            )
            player.play()
            player.advance(by: 0.000001)
            player.advance(by: 0.000001)
            player.advance(by: 0.25)
            let progress = EffectTiming.ease("OutQuad", 0.25)
            let x = wipe["from"][0].number() + (wipe["to"][0].number() - wipe["from"][0].number()) * progress
            let y = wipe["from"][1].number() + (wipe["to"][1].number() - wipe["from"][1].number()) * progress
            try close(Double(player.stage.wipeOffset.x), x / 1920, "Wipe \(wipe["name"].string) X", tolerance: 1e-6)
            try close(Double(player.stage.wipeOffset.y), -y / 1080, "Wipe \(wipe["name"].string) Y", tolerance: 1e-6)
            player.advance(by: 0.8)
            try expect(player.stage.isWipeVisible != wipe["hideAtEnd"].isEnabled, "Wipe visibility at completion")
        }
        for dolly in reference["dolly"].array {
            let player = StoryPlayer()
            try await player.load(
                .init(
                    snippets: [.init(action: .specialEffect, referenceIndex: 0)],
                    effects: [.init(type: 45, value: dolly["value"].string, duration: 1)]
                )
            )
            player.play()
            player.advance(by: 0.000001)
            player.advance(by: 0.000001)
            player.advance(by: 1)
            let data = dolly["parsed"]
            let zoom = data["zoom"].number(1)
            let distortion = data["dist"].number() * (1 - zoom)
            try close(Double(player.stage.dolly.x), zoom, "Dolly zoom", tolerance: 1e-6)
            try close(
                Double(player.stage.dolly.y),
                data["zoom"].isNull ? 0 : data["blur"].number(),
                "Dolly blur",
                tolerance: 1e-6
            )
            try close(Double(player.stage.dolly.z), distortion, "Dolly distortion", tolerance: 1e-6)
        }
        let talkPlayer = StoryPlayer()
        var motionBusy = true
        talkPlayer.motionIsPlaying = { _ in motionBusy }
        talkPlayer.isAutomatic = true
        try await talkPlayer.load(
            .init(
                initialLayout: [.init(characterID: 1)],
                snippets: [
                    .init(action: .talk, referenceIndex: 0),
                    .init(action: .talk, progressBehavior: .waitFinished, referenceIndex: 1),
                ],
                talks: [.init(body: "A", voices: [.init(characterID: 1, voiceID: "ended")]), .init(body: "B")]
            )
        )
        talkPlayer.play()
        talkPlayer.advance(by: 3)
        try expect(talkPlayer.dialogue.body == "A", "Voiced automatic dialogue waits for the visible body's motion")
        motionBusy = false
        talkPlayer.advance(by: 0.3)
        try expect(talkPlayer.dialogue.body == "A", "Automatic paging holds after motion completion")
        talkPlayer.advance(by: 0.3)
        try expect(talkPlayer.dialogue.body == "B", "Automatic paging releases after the post-motion half second")
        let player = StoryPlayer()
        try await player.load(
            .init(snippets: [.init(action: .specialEffect, referenceIndex: 0)], effects: [.init(type: 24, value: "AB")])
        )
        player.play()
        player.advance(by: 1.8)
        try expect(
            player.dialogue.isFullScreen && player.dialogue.characterAlphas.count == 2,
            "Full-screen text creates scalar opacity slots"
        )
        player.advance(by: 3)
        try expect(
            !player.dialogue.isVisible && player.status == .finished,
            "Full-screen text completes without manual or automatic mode"
        )
        try await player.load(
            .init(
                snippets: [.init(action: .specialEffect, referenceIndex: 0)],
                effects: [.init(type: 8, value: "Caption")]
            )
        )
        player.isAutomatic = true
        player.play()
        player.advance(by: 2.2)
        try expect(player.stage.caption == "Caption", "Caption remains through the reference hold")
        player.advance(by: 0.6)
        try expect(
            player.stage.caption.isEmpty && player.status == .finished,
            "Caption sampled hide animation releases its barrier"
        )
    }
    
    private static func wait(_ commandBuffer: any MTLCommandBuffer) { commandBuffer.waitUntilCompleted() }
    
    private static func render(_ document: EffectValue, at output: URL) async throws {
        let player = StoryPlayer()
        try await player.load(
            .init(
                snippets: [.init(action: .specialEffect, referenceIndex: 0), .init(delay: 20)],
                effects: [.init(type: 15, value: "coverage")]
            )
        )
        player.prefabAssets = ["coverage": .init(document: document, textures: [:])]
        let renderer = try StoryRenderer(player: player)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1280,
            height: 720,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let target = renderer.device.makeTexture(descriptor: descriptor)!
        player.play()
        for _ in 0..<15 {
            player.advance(by: 1 / 30)
            let buffer = try renderer.render(to: target)
            wait(buffer)
            try expect(buffer.status == .completed, "GPU particle render")
        }
        var pixels = [UInt8](repeating: 0, count: 1280 * 720 * 4)
        target.getBytes(
            &pixels,
            bytesPerRow: 5120,
            from: .init(origin: .init(x: 0, y: 0, z: 0), size: .init(width: 1280, height: 720, depth: 1)),
            mipmapLevel: 0
        )
        let colored = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 1] > 60 || pixels[$0 + 2] > 60 }
            .count
        try expect(colored > 500, "Prefab images and particles reach the Metal framebuffer")
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: 1280,
            height: 720,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 5120,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: .init(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let destination = CGImageDestinationCreateWithURL(
            output.appending(path: "particles.png") as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        try expect(CGImageDestinationFinalize(destination), "Write particle render")
    }
    
    private enum TestError: Error { case failure(String) }
}
