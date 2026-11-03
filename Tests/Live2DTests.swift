import Metal
import Astray
import ImageIO
import Foundation
import CoreGraphics
import UniformTypeIdentifiers

@main
@MainActor
private struct Live2DTests {
    private static func complete(_ buffer: any MTLCommandBuffer) { buffer.waitUntilCompleted() }
    
    private static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = root.appending(path: ".build/TestArtifacts/Live2D")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let manifest = output.appending(path: "model_manifest.json")
        try Data(#"{"Haru":{"modelDir":"Haru","modelFile":"Haru.model3.json"}}"#.utf8).write(to: manifest)
        let player = StoryPlayer()
        var warnings: [String] = []
        player.onEvent = { if case .warning(let error) = $0 { warnings.append(error.localizedDescription) } }
        try await player.load(
            .init(
                initialLayout: [.init(side: 4, characterID: 1, costume: "Haru", motion: "Idle_0", facial: "F01")],
                snippets: [.init(delay: 20)]
            ),
            resolver: Resolver(root: root, manifest: manifest)
        )
        guard warnings.isEmpty else { throw TestError.failure(warnings.joined(separator: "\n")) }
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
        player.play()
        var previous: [UInt8] = []
        var changes = 0
        for frame in 0..<4 {
            player.advance(by: 0.25)
            let buffer = try renderer.render(to: target)
            complete(buffer)
            guard buffer.status == .completed else {
                throw TestError.failure("GPU failed: \(String(describing: buffer.error))")
            }
            var pixels = [UInt8](repeating: 0, count: 1280 * 720 * 4)
            target.getBytes(
                &pixels,
                bytesPerRow: 5120,
                from: .init(origin: .init(x: 0, y: 0, z: 0), size: .init(width: 1280, height: 720, depth: 1)),
                mipmapLevel: 0
            )
            let colored = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 2] > 50 || pixels[$0 + 1] > 50 }
                .count
            guard colored > 10000 else {
                throw TestError.failure("Live2D model did not render: \(colored) colored pixels")
            }
            if !previous.isEmpty { changes += zip(pixels, previous).filter { $0 != $1 }.count }
            previous = pixels
            if frame == 3 { try write(pixels, to: output.appending(path: "haru.png")) }
        }
        guard changes > 1000 else {
            throw TestError.failure("Motion, physics and parameter updates did not animate the model.")
        }
        try player.jump(to: 0)
        complete(try renderer.render(to: target))
        guard warnings.isEmpty else { throw TestError.failure(warnings.joined(separator: "\n")) }
        print(
            "PASS: real Cubism Core model, expressions, body motion, physics, Metal clipping masks and jump reset; \(changes) changed color channels."
        )
    }
    
    private static func write(_ pixels: [UInt8], to url: URL) throws {
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
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestError.failure("Image write failed") }
    }
    
    private struct Resolver: AssetResolving {
        let root: URL
        let manifest: URL
        func url(for request: AssetRequest) -> URL? {
            switch request {
            case .modelManifest: manifest
            case .model: root.appending(path: "Vendor/CubismNativeSamples/Samples/Resources/Haru/Haru.model3.json")
            case .resource(let url): url
            default: nil
            }
        }
    }
    
    private enum TestError: Error { case failure(String) }
}
