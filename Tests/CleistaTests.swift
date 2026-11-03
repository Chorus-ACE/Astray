import Metal
import ImageIO
import Foundation
import CoreGraphics
@testable import Astray
import AstrayCubismBridge
import UniformTypeIdentifiers

@main
@MainActor
private struct CleistaTests {
    private static var checks = 0
    
    private static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixture = try JSONDecoder().decode(
            EffectValue.self,
            from: Data(contentsOf: root.appending(path: ".build/TestArtifacts/Cleista/reference.json"))
        )
        try text(fixture["text"].array)
        try lips(fixture)
        try await characterShaders(fixture["shaderStates"].array)
        try await dialogue()
        try await fullScreenSequence()
        try mouthSmoothing(root)
        try facialCurves(root, fixture: fixture["curves"].array)
        try await rendering(root)
        try textCacheBudget()
        print(
            "PASS: \(checks) Cleista differential checks, text mouth, retained character shaders, full-screen text and Metal rendering."
        )
    }
    
    private static func text(_ samples: [EffectValue]) throws {
        for sample in samples {
            let source = sample["source"].string
            let expanded = FullScreenText.expand(source)
            let parsed = FullScreenText(source)
            try expect(expanded.text == sample["expanded"].string, "Expanded text: \(source)")
            try expect(parsed.processingCount == Int(sample["processingCount"].number()), "Processing count: \(source)")
            try expect(parsed.text == sample["plain"].string, "Plain text: \(source)")
            let glyphs = sample["glyphs"].array
            try expect(parsed.text.unicodeScalars.count == glyphs.count, "Unicode scalar count: \(source)")
            var offset = 0
            for (index, scalar) in parsed.text.unicodeScalars.enumerated() {
                let expected = glyphs[index]
                guard let style = parsed.runs.first(where: { $0.range.contains(offset) })?.style else {
                    throw Failure.message("Missing text style")
                }
                try expect(String(scalar) == expected["value"].string, "Unicode value")
                try expect(abs(style.scale - expected["scale"].number()) < 1e-6, "Font size: \(source)")
                try expect(style.isBold == expected["bold"].isEnabled, "Bold: \(source)")
                try expect(style.isItalic == expected["italic"].isEnabled, "Italic: \(source)")
                try expect(style.isUnderlined == expected["underline"].isEnabled, "Underline: \(source)")
                try expect((style.alignment?.rawValue ?? "") == expected["alignment"].string, "Alignment: \(source)")
                try expect(abs(style.margin - expected["margin"].number()) < 1e-6, "Margin: \(source)")
                try expect((style.link ?? "") == expected["link"].string, "Link metadata")
                if !expected["color"].isNull {
                    guard let color = style.color else { throw Failure.message("Missing text color") }
                    for channel in 0..<4 {
                        try expect(abs(Double(color[channel]) - expected["color"][channel].number()) < 1e-6, "Color")
                    }
                } else {
                    try expect(style.color == nil, "Default text color")
                }
                offset += scalar.value > 0xFFFF ? 2 : 1
            }
        }
    }
    
    private static func lips(_ fixture: EffectValue) throws {
        for row in fixture["voices"].array {
            let target = LipSync.voiceTarget(rms: Float(row["rms"].number()), scale: Float(row["scale"].number()))
            try expect(abs(Double(target) - row["target"].number()) < 1e-6, "Voice RMS target: \(row)")
        }
        for (index, value) in fixture["flap"].array.enumerated() {
            let target = LipSync.textTarget(at: Double(index) * 0.06 + 0.001, duration: 20)
            try expect(abs(Double(target) - value.number()) < 1e-6, "Authored mouth pose \(index)")
        }
        try expect(LipSync.textTarget(at: -0.01, duration: 1) == 0, "Wait for the dialogue opening")
        try expect(LipSync.textTarget(at: 1, duration: 1) == 0, "Stop the text mouth at the end")
    }
    
    private static func characterShaders(_ rows: [EffectValue]) async throws {
        let effects: [ScenarioEffect] = rows.map {
            .init(
                type: 22,
                value: $0["op"].string == "detach" ? "none" : $0["kind"].string,
                secondaryValue: $0["intensity"].string,
                integer: Int($0["id"].number())
            )
        }
        let player = StoryPlayer()
        try await player.load(
            .init(
                initialLayout: (1...3).map { .init(characterID: $0, costume: "fixture") },
                snippets: effects.indices.map { .init(action: .specialEffect, referenceIndex: $0) },
                effects: effects
            )
        )
        for (index, row) in rows.enumerated() {
            try player.jump(to: index + 1)
            for id in 1...3 {
                let expected = row["state"].array.first { Int($0["id"].number()) == id }
                let character = player.stage.characters[id]!
                try expect(character.shader == (expected?["kind"].string ?? ""), "Per-character shader retention")
                if let expected, expected["kind"].string == "blur" {
                    try expect(
                        character.shaderIntensity == Float(expected["intensity"].number(1)),
                        "Repeated blur keeps its first intensity"
                    )
                }
            }
        }
        try await player.load(
            .init(
                snippets: [.init(action: .specialEffect), .init(action: .characterLayout)],
                layouts: [.init(type: 2, characterID: 4, costume: "fixture")],
                effects: [.init(type: 22, value: "blur", secondaryValue: "2", integer: 4)]
            )
        )
        try player.jump(to: 2)
        try expect(player.stage.characters[4]?.shader == "blur", "Retain shaders attached before a character appears")
        try expect(player.stage.characters[4]?.shaderIntensity == 2, "Restore shader intensity on appearance")
        player.stop()
        try expect(player.stage.characters[4] == nil, "Reset clears pending character shader state")
    }
    
    private static func dialogue() async throws {
        let player = StoryPlayer()
        for mode in [0, 2] {
            try await player.load(
                .init(
                    initialLayout: [.init(characterID: 1), .init(characterID: 2)],
                    snippets: [.init(action: .talk)],
                    talks: [.init(characters: [.init(characterID: 900000)], body: "文字だけでも口が動きます。", lipSync: mode)]
                )
            )
            player.play()
            player.advance(by: 0.35)
            for id in 1...2 {
                try expect(
                    (player.stage.characters[id]!.mouthOpen > 0) == (mode == 0),
                    "Text mouth and disabled mouth modes"
                )
            }
            let before = player.stage.characters[1]!.mouthOpen
            player.pause()
            player.advance(by: 1)
            try expect(player.stage.characters[1]!.mouthOpen == before, "Paused text mouth is frozen")
            player.play()
            player.isDialogueHidden = true
            player.advance()
            try expect(
                !player.isDialogueHidden && player.dialogue.isTyping,
                "First hidden-dialogue tap only reveals the interface"
            )
            player.advance()
            player.advance(by: 0.02)
            try expect(player.stage.characters[1]?.mouthOpen == 0, "Finishing text reveal closes the text mouth")
        }
    }
    
    private static func fullScreenSequence() async throws {
        let player = StoryPlayer()
        try await player.load(
            .init(
                snippets: [
                    .init(action: .specialEffect),
                    .init(action: .specialEffect, progressBehavior: .waitFinished, referenceIndex: 1),
                ],
                effects: [.init(type: 24, value: "abcdefghijkl"), .init(type: 24, value: "短")]
            )
        )
        player.play()
        player.advance(by: 0.5)
        try expect(
            player.dialogue.fullScreenBackgroundOpacity > 0 && player.dialogue.fullScreenBackgroundOpacity < 0.5,
            "Full-screen background fades in"
        )
        for _ in 0..<600 {
            if player.dialogue.body == "短" { break }
            player.advance(by: 1 / 60)
        }
        try expect(player.dialogue.body == "短", "Consecutive full-screen text advances")
        player.advance(by: 1.1)
        try expect(player.dialogue.isTyping, "A shorter page retains the previous processing capacity")
        player.advance(by: 0.6)
        try expect(!player.dialogue.isTyping, "Full-screen reveal completes at the retained capacity")
    }
    
    private static func mouthSmoothing(_ root: URL) throws {
        let moc = try Data(
            contentsOf: root.appending(path: "Vendor/CubismNativeSamples/Samples/Resources/Haru/Haru.moc3")
        )
        let normal = try ASRCubismModel(moc: moc, physics: nil, pose: nil)
        let fast = try ASRCubismModel(moc: moc, physics: nil, pose: nil)
        for _ in 0..<3 {
            normal.update(1 / 60, time: 0, mouth: 1)
            fast.update(1 / 60, time: 0, mouth: 1)
        }
        normal.update(1 / 60, time: 0, mouth: 0)
        fast.update(1 / 120, time: 0, mouth: 0)
        fast.update(1 / 120, time: 0, mouth: 0)
        let a = positions(normal), b = positions(fast)
        try expect(
            zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 },
            "60 and 120 Hz mouth smoothing agrees on real geometry"
        )
        fast.update(0, time: 0, mouth: 1)
        try expect(positions(fast) == b, "Zero elapsed time does not advance mouth smoothing")
    }
    
    private static func positions(_ model: ASRCubismModel) -> [Float] {
        model.drawables.flatMap { $0.positions.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
    }
    
    private static func facialCurves(_ root: URL, fixture: [EffectValue]) throws {
        let moc = try Data(
            contentsOf: root.appending(path: "Vendor/CubismNativeSamples/Samples/Resources/Haru/Haru.moc3")
        )
        func motion(_ segments: [Double], count: Int, points: Int) -> Data {
            let values = segments.map { String(format: "%.9f", $0) }.joined(separator: ", ")
            return Data(
                """
                {
                    "Version": 3,
                    "Meta": {
                        "Duration": 1, "Fps": 30, "Loop": false, "AreBeziersRestricted": false,
                        "CurveCount": 1, "TotalSegmentCount": \(count), "TotalPointCount": \(points)
                    },
                    "Curves": [{"Target": "Parameter", "Id": "ParamAngleX", "Segments": [
                        \(values)
                    ]}]
                }
                """.utf8
            )
        }
        for row in fixture {
            let segments = row["segments"].numbers
            let bezier = segments.count == 9
            let count = segments.count == 8 ? 2 : 1
            let animated = try ASRCubismModel(moc: moc, physics: nil, pose: nil)
            try animated.loadMotion(
                motion(segments, count: count, points: bezier ? 4 : count + 1),
                name: "animated",
                facial: true
            )
            animated.playMotion("", facial: "animated", instant: true)
            animated.update(0, time: 0, mouth: 0)
            var previousTime = 0.0
            for sample in row["samples"].array {
                let time = sample["time"].number()
                let value = sample["value"].number()
                animated.update(time - previousTime, time: 0, mouth: 0)
                previousTime = time
                let expected = try ASRCubismModel(moc: moc, physics: nil, pose: nil)
                try expected.loadMotion(
                    motion([0, value, 0, 1, value], count: 1, points: 2),
                    name: "expected",
                    facial: false
                )
                expected.playMotion("expected", facial: "", instant: true)
                expected.update(0, time: 0, mouth: 0)
                try expect(
                    zip(positions(animated), positions(expected)).allSatisfy { abs($0 - $1) < 1e-5 },
                    "Animated facial curve matches JS and holds its final value at \(time)"
                )
            }
        }
        let transitioning = try ASRCubismModel(moc: moc, physics: nil, pose: nil)
        try transitioning.loadMotion(motion([0, -20, 0, 1, -20], count: 1, points: 2), name: "from", facial: true)
        try transitioning.loadMotion(motion([0, 20, 0, 1, 20], count: 1, points: 2), name: "to", facial: true)
        transitioning.playMotion("", facial: "from", instant: true)
        transitioning.update(0, time: 0, mouth: 0)
        transitioning.playMotion("", facial: "to", instant: false)
        for (delta, value) in [(0.0, -20.0), (0.125, 0), (0.125, 20), (1.5, 20)] {
            transitioning.update(delta, time: 0, mouth: 0)
            let expected = try ASRCubismModel(moc: moc, physics: nil, pose: nil)
            try expected.loadMotion(motion([0, value, 0, 1, value], count: 1, points: 2), name: "pose", facial: false)
            expected.playMotion("pose", facial: "", instant: true)
            expected.update(0, time: 0, mouth: 0)
            try expect(
                zip(positions(transitioning), positions(expected)).allSatisfy { abs($0 - $1) < 1e-5 },
                "Facial transition fades from the previous pose and holds its endpoint"
            )
        }
    }
    
    private static func rendering(_ root: URL) async throws {
        let player = StoryPlayer()
        let source =
            "<style=Title>色と文字の演出</style>\n<color=#ff4040>赤い文字</color> <style=Link>青いリンク</style>\n<style=Quote>引用文と斜体</style>"
        try await player.load(
            .init(snippets: [.init(action: .specialEffect)], effects: [.init(type: 24, value: source)])
        )
        try expect(player.transcript.first?.body.contains("<style") == false, "Transcript contains readable text")
        let renderer = try StoryRenderer(player: player)
        let rasterizer = TextRasterizer(device: renderer.device)
        let invisible = try rasterizer.texture(
            text: "A😀e\u{301}",
            width: 400,
            height: 100,
            size: 48,
            alphas: [0, 0, 0, 0]
        )!
        var hidden = [UInt8](repeating: 0, count: 400 * 100 * 4)
        invisible.getBytes(
            &hidden,
            bytesPerRow: 1600,
            from: .init(origin: .init(x: 0, y: 0, z: 0), size: .init(width: 400, height: 100, depth: 1)),
            mipmapLevel: 0
        )
        try expect(
            stride(from: 3, to: hidden.count, by: 4).allSatisfy { hidden[$0] == 0 },
            "Emoji and combining scalars honor per-character alpha"
        )
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1280,
            height: 720,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let texture = renderer.device.makeTexture(descriptor: descriptor)!
        player.play()
        player.advance(by: 2)
        player.advance()
        player.advance(by: 1 / 60)
        complete(try renderer.render(to: texture))
        var bytes = [UInt8](repeating: 0, count: 1280 * 720 * 4)
        texture.getBytes(
            &bytes,
            bytesPerRow: 5120,
            from: .init(origin: .init(x: 0, y: 0, z: 0), size: .init(width: 1280, height: 720, depth: 1)),
            mipmapLevel: 0
        )
        let red = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0 + 2] > 150 && bytes[$0 + 1] < 100 }.count
        let blue = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 180 && bytes[$0 + 2] < 100 }.count
        try expect(red > 100 && blue > 100, "Styled colors survive scalar alpha and actual Metal composition")
        let output = root.appending(path: ".build/TestArtifacts/Cleista/fulltext.png")
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
            provider: CGDataProvider(data: Data(bytes) as CFData)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        try expect(CGImageDestinationFinalize(destination), "Save the full-screen text rendering artifact")
    }
    
    private static func complete(_ buffer: any MTLCommandBuffer) { buffer.waitUntilCompleted() }
    
    private static func textCacheBudget() throws {
        let device = MTLCreateSystemDefaultDevice()!
        let text = TextRasterizer(device: device)
        let before = device.currentAllocatedSize
        for index in 0..<64 {
            try autoreleasepool {
                _ = try text.texture(text: "\(index) — 文字のフェードとキャッシュ", width: 1200, height: 400, size: 40)
            }
        }
        let growth = device.currentAllocatedSize - min(before, device.currentAllocatedSize)
        try expect(growth < 40 * 1024 * 1024, "Text GPU cache remains bounded during changing text")
        print("Text GPU allocation growth: \(growth) bytes across 64 full-size text textures.")
    }
    
    private static func expect(_ value: Bool, _ message: String) throws {
        checks += 1
        if !value { throw Failure.message(message) }
    }
    
    private enum Failure: Error { case message(String) }
}
