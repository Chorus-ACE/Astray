import Metal
import AppKit
import ImageIO
import Foundation
@testable import Astray

@main
@MainActor
private struct ViewportTests {
    private static func complete(_ buffer: any MTLCommandBuffer) {
        buffer.waitUntilCompleted()
        precondition(buffer.status == .completed, "Viewport rendering failed: \(String(describing: buffer.error))")
    }
    
    private static func main() async throws {
        _ = NSApplication.shared
        let player = StoryPlayer()
        let renderer = try StoryRenderer(player: player)
        let view = _MetalStoryView(renderer: renderer)
        view.isPaused = true
        view.frame.size = .init(width: 852, height: 393)
        for insets: (CGFloat, CGFloat) in [(62, 0), (0, 62), (62, 62)] {
            view.configure(scalesToFill: true, top: 0, leading: insets.0, bottom: 21, trailing: insets.1)
            let safe = renderer.interfaceBounds!
            let viewport = renderer.interfaceViewport(
                width: Int(view.drawableSize.width),
                height: Int(view.drawableSize.height)
            )
            precondition(
                viewport.originX >= safe.minX - 0.0001 && viewport.originY >= safe.minY - 0.0001,
                "Safe bounds \(safe), viewport \(viewport), drawable \(view.drawableSize)"
            )
            precondition(viewport.originX + viewport.width <= safe.maxX + 1)
            precondition(viewport.originY + viewport.height <= safe.maxY + 1)
            precondition(abs(viewport.width / viewport.height - 16 / 9) < 0.0001)
        }
        
        let background = try solidBackground()
        let resolver = Resolver(background: background)
        try await player.load(.init(initialBackground: "red"), resolver: resolver)
        for size in [(2556, 1179), (1920, 1080), (2048, 1536)] {
            let filled = StoryRenderer.viewport(width: size.0, height: size.1, scalesToFill: true)
            precondition(filled.originX <= 0 && filled.originY <= 0)
            precondition(filled.originX + filled.width >= Double(size.0))
            precondition(filled.originY + filled.height >= Double(size.1))
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: size.0,
                height: size.1,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            let target = renderer.device.makeTexture(descriptor: descriptor)!
            renderer.scalesToFill = true
            complete(try renderer.render(to: target))
            for point in [(0, 0), (size.0 - 1, 0), (0, size.1 - 1), (size.0 - 1, size.1 - 1)] {
                var pixel = [UInt8](repeating: 0, count: 4)
                target.getBytes(
                    &pixel,
                    bytesPerRow: 4,
                    from: .init(
                        origin: .init(x: point.0, y: point.1, z: 0),
                        size: .init(width: 1, height: 1, depth: 1)
                    ),
                    mipmapLevel: 0
                )
                precondition(pixel[2] > 240 && pixel[0] < 10, "Scene left a border at \(size), \(point).")
            }
        }
        
        // Choices must use the same safe viewport for drawing and touch coordinates.
        try await player.load(
            .init(
                snippets: [.init(action: .specialEffect, referenceIndex: 0)],
                effects: [.init(type: 23, value: "Left/Right")]
            )
        )
        player.play()
        player.advance(by: 0.2)
        for insets: (CGFloat, CGFloat) in [(62, 0), (0, 62)] {
            view.configure(scalesToFill: true, top: 0, leading: insets.0, bottom: 21, trailing: insets.1)
            let viewport = renderer.interfaceViewport(
                width: Int(view.drawableSize.width),
                height: Int(view.drawableSize.height)
            )
            for index in 0..<2 {
                let rect = StoryRenderer.choiceRect(index: index, count: 2, scale: player.stage.choiceScale)
                let point = CGPoint(
                    x: (viewport.originX + Double(rect.x + rect.z / 2) * viewport.width) * view.bounds.width
                        / view.drawableSize.width,
                    y: (viewport.originY + Double(rect.y + rect.w / 2) * viewport.height) * view.bounds.height
                        / view.drawableSize.height
                )
                precondition(view.choiceIndex(at: point) == index)
            }
            precondition(view.choiceIndex(at: .zero) == nil)
        }
        view.configure(scalesToFill: false, top: 0, leading: 62, bottom: 21, trailing: 0)
        let fitted = renderer.interfaceViewport(
            width: Int(view.drawableSize.width),
            height: Int(view.drawableSize.height)
        )
        let original = StoryRenderer.viewport(
            width: Int(view.drawableSize.width),
            height: Int(view.drawableSize.height)
        )
        precondition(fitted.originX == original.originX && fitted.originY == original.originY)
        precondition(fitted.width == original.width && fitted.height == original.height)
        print(
            "PASS: fullscreen edge pixels, fit/fill aspect ratios, safe dialogue viewport, rotated insets, and choice hit testing."
        )
    }
    
    private static func solidBackground() throws -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        let context = CGContext(
            data: nil,
            width: 16,
            height: 9,
            bitsPerComponent: 8,
            bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(.init(x: 0, y: 0, width: 16, height: 9))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
    
    private struct Resolver: AssetResolving {
        internal let background: Data
        
        internal func url(for request: AssetRequest) -> URL? {
            if case .background = request { return URL(fileURLWithPath: "/background.png") }
            return nil
        }
        
        internal func data(for request: AssetRequest) async throws -> Data? {
            if case .background = request { return background }
            return nil
        }
    }
}
