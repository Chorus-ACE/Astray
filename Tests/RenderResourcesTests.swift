import Metal
import AppKit
import Foundation
import AstrayCubismBridge
@testable import Astray

@main
@MainActor
private struct RenderResourcesTests {
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.message(message) }
    }
    
    private static func complete(_ buffer: any MTLCommandBuffer) throws {
        buffer.waitUntilCompleted()
        try check(buffer.status == .completed, "GPU failure: \(String(describing: buffer.error))")
    }
    
    private static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let device = MTLCreateSystemDefaultDevice()!
        try verifyFrameStorage(device: device)
        try verifyMetadata(root: root)
        let player = StoryPlayer()
        let renderer = try StoryRenderer(player: player, device: device)
        try verifyDisplayScale(renderer: renderer)
        try await verifyQueuedFrames(root: root, device: device)
        print(
            "PASS: 120 FPS preference, native backing scale, @1x/@2x/@3x pixel sizes, borrowed Cubism metadata, arena boundaries and queued GPU frame isolation."
        )
    }
    
    private static func verifyFrameStorage(device: any MTLDevice) throws {
        let queue = device.makeCommandQueue()!
        let slots = FrameSlots()
        let frames = (0..<3).map { _ in FrameResources(device: device) }
        var pending: [(any MTLCommandBuffer, any MTLBuffer, UInt8)] = []
        for index in 0..<24 {
            let slot = slots.acquire()
            let frame = frames[slot]
            frame.reset()
            let buffer = queue.makeCommandBuffer()!
            let encoder = buffer.makeBlitCommandEncoder()!
            let sizes = [13, 262143, 512, 700001]
            let result = device.makeBuffer(length: sizes.reduce(0, +), options: .storageModeShared)!
            let value = UInt8(index + 1)
            var offset = 0
            for size in sizes {
                let bytes = [UInt8](repeating: value, count: size)
                let slice = try bytes.withUnsafeBytes { try frame.upload($0.baseAddress!, count: size) }
                try check(slice.offset.isMultiple(of: 256), "GPU geometry offset lost alignment")
                encoder.copy(
                    from: slice.buffer,
                    sourceOffset: slice.offset,
                    to: result,
                    destinationOffset: offset,
                    size: size
                )
                offset += size
            }
            encoder.endEncoding()
            buffer.addCompletedHandler { _ in slots.release(slot) }
            buffer.commit()
            pending.append((buffer, result, value))
        }
        for (buffer, result, value) in pending {
            try complete(buffer)
            let bytes = result.contents().bindMemory(to: UInt8.self, capacity: result.length)
            try check((0..<result.length).allSatisfy { bytes[$0] == value }, "In-flight geometry was overwritten")
        }
    }
    
    private static func verifyMetadata(root: URL) throws {
        let haru = root.appending(path: "Vendor/CubismNativeSamples/Samples/Resources/Haru")
        let runtime = try ASRCubismModel(
            moc: Data(contentsOf: haru.appending(path: "Haru.moc3")),
            physics: Data(contentsOf: haru.appending(path: "Haru.physics3.json")),
            pose: nil
        )
        let drawables = runtime.renderDrawables
        let snapshot = runtime.drawables
        let saved = snapshot.map(\.positions)
        for frame in 0..<40 {
            runtime.update(1 / 120, time: Double(frame) / 120, mouth: Float(frame % 7) / 7)
            runtime.updateRenderDrawables()
            let expected = runtime.drawables
            for (index, drawable) in drawables.enumerated() {
                let bytes = Data(bytes: drawable.positionBytes, count: drawable.vertexCount * 8)
                try check(bytes == expected[index].positions, "Borrowed vertex data differs from Core snapshot")
                try check(drawable.renderOrder == expected[index].renderOrder, "Stale drawable order")
                bytes.withUnsafeBytes { raw in
                    for vertex in raw.bindMemory(to: SIMD2<Float>.self) {
                        precondition(vertex.x >= drawable.bounds.x && vertex.x <= drawable.bounds.z)
                        precondition(vertex.y >= drawable.bounds.y && vertex.y <= drawable.bounds.w)
                    }
                }
            }
            runtime.updateRenderDrawables()
            try check(!runtime.hasRenderChanges, "Unchanged Core data invalidated the model cache")
        }
        try check(snapshot.map(\.positions) == saved, "Snapshot data was mutated by render metadata updates")
    }
    
    private static func verifyDisplayScale(renderer: StoryRenderer) throws {
        _ = NSApplication.shared
        let size = CGSize(width: 641.25, height: 359.5)
        for scale in [CGFloat(1), 2, 3] {
            let pixels = MetalStoryView.pixelSize(for: size, scale: scale)
            try check(
                pixels.width == ceil(size.width * scale) && pixels.height == ceil(size.height * scale),
                "Incorrect backing pixel conversion"
            )
        }
        let view = MetalStoryView(renderer: renderer)
        view.isPaused = true
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let scale = window.backingScaleFactor
        try check(view.preferredFramesPerSecond == 120, "Frame-rate preference is not 120")
        try check(
            view.drawableSize == MetalStoryView.pixelSize(for: view.bounds.size, scale: scale),
            "Drawable size does not match the attached screen scale"
        )
        try check(view.layer?.contentsScale == scale, "Metal layer scale differs from the window")
        view.frame.size = .init(width: 801, height: 451)
        view.layoutSubtreeIfNeeded()
        try check(
            view.drawableSize == MetalStoryView.pixelSize(for: view.bounds.size, scale: scale),
            "Resize lost backing scale"
        )
        print("PASS: attached screen @\(scale)x, drawable \(view.drawableSize).")
        window.close()
    }
    
    private static func verifyQueuedFrames(root: URL, device: any MTLDevice) async throws {
        let manifest = root.appending(path: ".build/TestArtifacts/RenderResources/model_manifest.json")
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"Haru":{"modelDir":"Haru","modelFile":"Haru.model3.json"}}"#.utf8).write(to: manifest)
        let resolver = Resolver(root: root, manifest: manifest)
        let scene = Scenario(
            initialLayout: [.init(side: 4, characterID: 1, costume: "Haru", motion: "Idle_0", facial: "F01")],
            snippets: [.init(delay: 30)]
        )
        var expected: [Data] = []
        for queued in [false, true] {
            let player = StoryPlayer()
            try await player.load(scene, resolver: resolver)
            let renderer = try StoryRenderer(player: player, device: device)
            player.play()
            var pending: [(any MTLCommandBuffer, any MTLTexture)] = []
            for index in 0..<18 {
                let scale = index % 3 + 1
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm,
                    width: 320 * scale,
                    height: 180 * scale,
                    mipmapped: false
                )
                descriptor.usage = [.shaderRead, .renderTarget]
                descriptor.storageMode = .shared
                let target = device.makeTexture(descriptor: descriptor)!
                player.advance(by: 1 / 120)
                let buffer = try renderer.render(to: target)
                pending.append((buffer, target))
                if !queued { try complete(buffer); expected.append(pixels(target)) }
            }
            if queued {
                for (index, pair) in pending.enumerated() {
                    try complete(pair.0)
                    try check(
                        pixels(pair.1) == expected[index],
                        "Queued model frame differs from serialized frame \(index)"
                    )
                }
            }
        }
    }
    
    private static func pixels(_ texture: any MTLTexture) -> Data {
        var data = Data(count: texture.width * texture.height * 4)
        data.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!,
                bytesPerRow: texture.width * 4,
                from: .init(
                    origin: .init(x: 0, y: 0, z: 0),
                    size: .init(width: texture.width, height: texture.height, depth: 1)
                ),
                mipmapLevel: 0
            )
        }
        return data
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
    
    private enum Failure: Error { case message(String) }
}
