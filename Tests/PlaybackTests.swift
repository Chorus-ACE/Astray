import Metal
import Astray
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private enum TestFailure: Error { case assertion(String) }

@main
@MainActor
private struct PlaybackTests {
    private static var assertions = 0
    
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !value() { throw TestFailure.assertion(message) }
    }
    
    private static func snippet(_ action: ScenarioAction, _ reference: Int, wait: Bool = true, delay: Double = 0)
        -> ScenarioSnippet
    {
        .init(action: action, progressBehavior: wait ? .waitFinished : .now, referenceIndex: reference, delay: delay)
    }
    
    private static func main() async throws {
        try await decoding()
        try await barriersAndDialogue()
        try await jumpAndPause()
        try await choicesAndCallbacks()
        try await delayedEffects()
        try await assetFailuresAndCancellation()
        try await audioPlayback()
        try await demo()
        try await rendering()
        print("PASS: \(assertions) assertions, including real Metal rendering and compiled library loading.")
    }
    
    private static func decoding() async throws {
        let data = Data(
            #"{"ScenarioId":"tiny","Snippets":[{"Action":1,"ReferenceIndex":0}],"TalkData":[{"Body":"Hello","WhenFinishCloseWindow":1}]}"#
                .utf8
        )
        let scenario = try Scenario.decode(data)
        try expect(scenario.talks[0].closesWindow, "Integer close-window flag")
        try expect(scenario.talks[0].voices.isEmpty, "Absent optional arrays")
        let roundTrip = try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(scenario))
        try expect(roundTrip == scenario, "Codable round trip")
        do {
            try Scenario(snippets: [snippet(.talk, 4)]).validate()
            throw TestFailure.assertion("Invalid references must throw")
        } catch is AstrayError {}
        do {
            try Scenario(snippets: [.init(delay: -.infinity)]).validate()
            throw TestFailure.assertion("Invalid timings must throw")
        } catch is AstrayError {}
        let resolver = DirectoryAssetResolver(baseURL: URL(fileURLWithPath: "/tmp/assets"))
        try expect(resolver.url(for: .background("../secret")) == nil, "Reject path traversal")
        try expect(
            resolver.url(for: .voice(scenario: "episode", id: "voice"))?.path
                == "/tmp/assets/sound/voice/episode/voice.mp3",
            "Reference asset layout"
        )
    }
    
    private static func barriersAndDialogue() async throws {
        let player = StoryPlayer()
        try await player.load(
            .init(
                snippets: [snippet(.specialEffect, 0, delay: 0.5), snippet(.talk, 0, wait: false), snippet(.talk, 1)],
                talks: [.init(body: "First line"), .init(body: "Second line")],
                effects: [.init(type: 2, duration: 1)]
            )
        )
        player.play()
        player.advance(by: 0.1)
        try expect(player.snippetIndex == 1, "Now starts alongside a delayed predecessor")
        try expect(player.dialogue.body == "First line", "Parallel talk starts")
        player.advance()
        try expect(!player.dialogue.isTyping, "First tap reveals text")
        player.advance()
        player.advance(by: 0.1)
        try expect(player.snippetIndex == 1, "WaitFinished waits for all prior snippets, including their delays")
        player.advance(by: 1.5)
        try expect(player.dialogue.body == "Second line", "Barrier releases after prior fade completes")
        try expect(player.stage.cover.w == 1, "Fade reaches target")
        player.advance()
        player.advance()
        player.advance(by: 0.1)
        try expect(player.status == .finished, "Manual dialogue drains timeline")
    }
    
    private static func jumpAndPause() async throws {
        let player = StoryPlayer()
        let scenario = Scenario(
            initialBackground: "before",
            snippets: [
                snippet(.characterLayout, 0), snippet(.specialEffect, 0), snippet(.talk, 0), snippet(.specialEffect, 1),
            ],
            talks: [.init(body: "Hold this page")],
            layouts: [.init(type: 2, sideFrom: 2, sideTo: 5, characterID: 10, costume: "costume", motion: "wave")],
            effects: [.init(type: 7, value: "after"), .init(type: 4, duration: 2)]
        )
        try await player.load(scenario)
        player.play()
        player.advance(by: 0.08)
        let x = player.stage.characters[10]?.x
        let time = player.elapsedTime
        player.pause()
        player.advance(by: 5)
        try expect(player.elapsedTime == time && player.stage.characters[10]?.x == x, "Pause freezes the shared clock")
        try player.jump(to: 2)
        try expect(player.status == .paused, "Jump preserves pause")
        try expect(player.stage.background == "after", "Jump reconstructs background")
        try expect(
            abs((player.stage.characters[10]?.x ?? 0) - 0.68) < 0.0001,
            "Jump reconstructs final character position"
        )
        player.play()
        player.advance(by: 0.1)
        try expect(player.dialogue.body == "Hold this page", "Jump resumes at the requested snippet")
        try player.jump(to: 0)
        player.advance(by: 0.03)
        try expect(player.stage.background == "before", "Rewind resets background")
        player.stop()
        player.advance(by: 20)
        try expect(
            player.stage.characters.isEmpty && player.stage.cover.w == 0,
            "Old animation work cannot mutate a stopped stage"
        )
        try expect(player.transcript.first?.snippetIndex == 2, "Transcript preserves snippet position")
    }
    
    private static func choicesAndCallbacks() async throws {
        let player = StoryPlayer()
        var selection = ""
        player.onEvent = { event in
            if case .selected(_, let value) = event { selection = value }
        }
        try await player.load(
            .init(
                snippets: [snippet(.specialEffect, 0), snippet(.talk, 0)],
                talks: [.init(body: "After choice")],
                effects: [.init(type: 23, value: "One/Two")]
            )
        )
        player.play()
        player.advance(by: 0.1)
        try expect(player.stage.choices == ["One", "Two"], "Choice appears")
        player.advance()
        player.advance(by: 1)
        try expect(player.snippetIndex == 0, "Normal advance does not dismiss a choice")
        player.selectChoice(at: 1)
        player.advance(by: 0.8)
        try expect(selection == "Two" && player.dialogue.body == "After choice", "Selection releases choice barrier")
        player.onEvent = { event in
            if case .progress = event { player.stop() }
        }
        player.stop()
        player.play()
        player.advance(by: 1)
        try expect(
            player.status == .ready && player.stage.choices.isEmpty,
            "Callbacks can stop playback without stale mutations"
        )
    }
    
    private static func delayedEffects() async throws {
        let player = StoryPlayer()
        var events = 0
        player.onEvent = { event in
            if case .scenarioEffect = event { events += 1 }
        }
        try await player.load(
            .init(
                snippets: [snippet(.specialEffect, 0), snippet(.talk, 0)],
                talks: [.init(body: "Hold")],
                effects: [.init(type: 15, value: "sparkle", duration: 0.4)]
            )
        )
        player.play()
        player.advance(by: 0.1)
        try expect(events == 0 && player.dialogue.body == "Hold", "Effect predelay does not gate later snippets")
        player.advance(by: 0.5)
        try expect(
            events == 1 && player.stage.effects.contains("sparkle"),
            "Effect starts once after its shared-clock delay (events: \(events), effects: \(player.stage.effects))"
        )
        player.stop()
        player.onEvent = { event in
            if case .scenarioEffect = event { player.stop() }
        }
        player.play()
        player.advance(by: 0.8)
        try expect(
            player.status == .ready && player.stage.effects.isEmpty,
            "Delayed callbacks cannot revive cancelled animation work"
        )
        player.onEvent = nil
    }
    
    private static func assetFailuresAndCancellation() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let player = StoryPlayer()
        var warnings = 0
        player.onEvent = { if case .warning = $0 { warnings += 1 } }
        let scene = Scenario(
            initialBackground: "absent",
            snippets: [snippet(.talk, 0)],
            talks: [.init(body: "Still playable")]
        )
        try await player.load(scene, resolver: DirectoryAssetResolver(baseURL: root))
        try expect(
            player.status == .ready && warnings == 1,
            "Missing optional assets report warnings and remain playable"
        )
        player.onEvent = { event in
            if case .loadProgress = event { player.stop() }
        }
        do {
            try await player.load(scene, resolver: DirectoryAssetResolver(baseURL: root))
            throw TestFailure.assertion("Stopped preload must cancel")
        } catch is CancellationError {}
        try expect(player.status == .ready, "Cancelled preload cannot overwrite a stopped player's state")
    }
    
    private static func audioPlayback() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let url = root.appending(path: "tone.wav")
        var wave = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { wave.append(contentsOf: $0) }
        }
        let sampleCount = 4410
        wave.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + sampleCount * 2))
        wave.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(44100))
        append(UInt32(88200))
        append(UInt16(2))
        append(UInt16(16))
        wave.append(contentsOf: "data".utf8)
        append(UInt32(sampleCount * 2))
        for index in 0..<sampleCount {
            append(Int16(sin(Double(index) * 440 * 2 * .pi / 44100) * 1000))
        }
        try wave.write(to: url)
        let player = StoryPlayer()
        player.setVolume(bgm: 0, voice: 0, sound: 0)
        var warnings = 0
        player.onEvent = { if case .warning = $0 { warnings += 1 } }
        try await player.load(
            .init(
                initialBGM: "tone",
                snippets: [snippet(.sound, 0), snippet(.talk, 0)],
                talks: [.init(body: "Audio", lipSync: 1, voices: [.init(characterID: 1, voiceID: "tone")])],
                sounds: [.init(playMode: 2, se: "tone")]
            ),
            resolver: AudioFixtureResolver(url: url)
        )
        player.play()
        player.advance(by: 0.1)
        player.pause()
        player.play()
        player.advance()
        player.advance()
        player.advance(by: 0.1)
        try expect(warnings == 0, "BGM, SE and voice decode and start through native audio")
        try expect(player.status == .finished, "Audio remains nonblocking")
        player.stop()
    }
    
    private static func demo() async throws {
        let path = URL(fileURLWithPath: CommandLine.arguments[1])
        let player = StoryPlayer()
        try await player.load(data: Data(contentsOf: path))
        try expect(player.transcript.count == 7, "Reference demo transcript")
        player.isAutomatic = true
        player.isFastForwarding = true
        player.play()
        player.advance(by: 60)
        try expect(player.status == .finished, "Reference demo completes")
        try expect(player.stage.cover.w == 1, "Reference demo ends with black cover")
    }
    
    private static func completed(_ buffer: any MTLCommandBuffer) {
        buffer.waitUntilCompleted()
    }
    
    private static func rendering() async throws {
        let player = StoryPlayer()
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appending(path: "background"),
            withIntermediateDirectories: true
        )
        try makeFixture(at: root.appending(path: "background/test.png"))
        var warnings = 0
        player.onEvent = { if case .warning = $0 { warnings += 1 } }
        try await player.load(
            .init(
                initialBackground: "test",
                snippets: [snippet(.talk, 0)],
                talks: [.init(speaker: "Astray", body: "Metal 原生故事播放器\nNative story rendering.")]
            ),
            resolver: DirectoryAssetResolver(baseURL: root)
        )
        let renderer = try StoryRenderer(player: player)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1280,
            height: 720,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let target = renderer.device.makeTexture(descriptor: descriptor) else {
            throw TestFailure.assertion("Metal target allocation")
        }
        player.play()
        player.advance(by: 0.1)
        player.advance()
        player.advance(by: 0.1)
        let buffer = try renderer.render(to: target)
        completed(buffer)
        try expect(buffer.status == .completed, "GPU command buffer completes")
        try expect(warnings == 0, "Image and text upload succeeds")
        var pixels = [UInt8](repeating: 0, count: 1280 * 720 * 4)
        target.getBytes(
            &pixels,
            bytesPerRow: 1280 * 4,
            from: .init(origin: .init(x: 0, y: 0, z: 0), size: .init(width: 1280, height: 720, depth: 1)),
            mipmapLevel: 0
        )
        let topLeft = (100 * 1280 + 100) * 4
        let topRight = (100 * 1280 + 1100) * 4
        try expect(pixels[topLeft + 2] > 200 && pixels[topLeft] < 30, "Background orientation and red pixels")
        try expect(pixels[topRight] > 200 && pixels[topRight + 2] < 30, "Background blue pixels")
        var whitePixels = 0
        for y in 565..<665 {
            for x in 78..<900 {
                let offset = (y * 1280 + x) * 4
                if pixels[offset] > 180 && pixels[offset + 1] > 180 && pixels[offset + 2] > 180 { whitePixels += 1 }
            }
        }
        try expect(whitePixels > 300, "CoreText dialogue is actually composited by Metal")
        try writeImage(pixels, to: root.appending(path: "render.png"))
        try FileManager.default.createDirectory(
            at: root.appending(path: "character"),
            withIntermediateDirectories: true
        )
        let alphaContext = CGContext(
            data: nil,
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bytesPerRow: 64,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        alphaContext.setFillColor(
            CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0, 1, 0, 0.5])!
        )
        alphaContext.fill(.init(x: 0, y: 0, width: 16, height: 16))
        let alphaDestination = CGImageDestinationCreateWithURL(
            root.appending(path: "character/semi.png") as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(alphaDestination, alphaContext.makeImage()!, nil)
        try expect(CGImageDestinationFinalize(alphaDestination), "Write alpha fixture")
        try await player.load(
            .init(initialLayout: [.init(characterID: 1, costume: "semi")], initialBackground: "test"),
            resolver: DirectoryAssetResolver(baseURL: root)
        )
        let alphaFrame = try renderer.render(to: target)
        completed(alphaFrame)
        target.getBytes(
            &pixels,
            bytesPerRow: 1280 * 4,
            from: .init(origin: .init(x: 0, y: 0, z: 0), size: .init(width: 1280, height: 720, depth: 1)),
            mipmapLevel: 0
        )
        let alphaPixel = (300 * 1280 + 500) * 4
        try expect(
            abs(Int(pixels[alphaPixel + 1]) - 128) < 4 && abs(Int(pixels[alphaPixel + 2]) - 127) < 4,
            "PNG premultiplied alpha composites correctly (RGBA: \(pixels[alphaPixel + 2]), \(pixels[alphaPixel + 1]), \(pixels[alphaPixel]), \(pixels[alphaPixel + 3]))"
        )
        let characters = SolidCharacterRenderer()
        renderer.characterRenderer = characters
        try await player.load(
            .init(
                initialLayout: [.init(characterID: 1)],
                snippets: [snippet(.talk, 0)],
                talks: [.init(body: "Native character layer")]
            )
        )
        let characterFrame = try renderer.render(to: target)
        completed(characterFrame)
        target.getBytes(
            &pixels,
            bytesPerRow: 1280 * 4,
            from: .init(origin: .init(x: 0, y: 0, z: 0), size: .init(width: 1280, height: 720, depth: 1)),
            mipmapLevel: 0
        )
        let center = (300 * 1280 + 640) * 4
        try expect(
            pixels[center + 1] > 240 && pixels[center + 2] < 20,
            "Native character renderer texture reaches the GPU composite"
        )
        try expect(characters.resets == 1 && characters.draws == 1, "Character runtime receives reset and draw calls")
        try player.jump(to: 0)
        let jumpedFrame = try renderer.render(to: target)
        completed(jumpedFrame)
        try expect(characters.resets == 2, "Jump resets external character simulations")
        print("Metal render: \(root.appending(path: "render.png").path)")
    }
    
    private static func makeFixture(at url: URL) throws {
        let context = CGContext(
            data: nil,
            width: 1280,
            height: 720,
            bitsPerComponent: 8,
            bytesPerRow: 1280 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [1, 0, 0, 1])!)
        context.fill(.init(x: 0, y: 0, width: 640, height: 720))
        context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0, 0, 1, 1])!)
        context.fill(.init(x: 640, y: 0, width: 640, height: 720))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try expect(CGImageDestinationFinalize(destination), "Write image fixture")
    }
    
    private static func writeImage(_ pixels: [UInt8], to url: URL) throws {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: 1280,
            height: 720,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 1280 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        try expect(CGImageDestinationFinalize(destination), "Write render artifact")
    }
}

@MainActor
private final class SolidCharacterRenderer: CharacterRendering {
    private var cached: (any MTLTexture)?
    var resets = 0
    var draws = 0
    
    func reset() { resets += 1 }
    
    func texture(
        for character: CharacterState,
        time: TimeInterval,
        device: any MTLDevice,
        commandBuffer: any MTLCommandBuffer
    ) throws -> (any MTLTexture)? {
        draws += 1
        if let cached { return cached }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        let texture = device.makeTexture(descriptor: descriptor)!
        var pixel: UInt32 = 0xFF00FF00
        texture.replace(
            region: .init(origin: .init(x: 0, y: 0, z: 0), size: .init(width: 1, height: 1, depth: 1)),
            mipmapLevel: 0,
            withBytes: &pixel,
            bytesPerRow: 4
        )
        cached = texture
        return texture
    }
}

private struct AudioFixtureResolver: AssetResolving {
    let url: URL
    
    func url(for request: AssetRequest) -> URL? {
        switch request {
        case .bgm, .sound, .voice: url
        default: nil
        }
    }
}
