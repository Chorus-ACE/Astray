import Metal
import Foundation

@main
@MainActor
private struct ShaderTests {
    private static var checks = 0
    private static func wait(_ buffer: any MTLCommandBuffer) { buffer.waitUntilCompleted() }
    
    private static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure.gpu
        }
        let path = ".build/Build/Intermediates.noindex/InstallIntermediates/macosx/Products/Debug/Astray.framework"
        let library = try device.makeDefaultLibrary(bundle: Bundle(path: path)!)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "astray_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "astray_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let source = texture(device: device, pixel: [102, 51, 25, 128])
        let noise = texture(device: device, pixel: [64, 64, 64, 255])
        let output = texture(device: device, pixel: [0, 0, 0, 0], size: 33)
        let rgb = SIMD3<Float>(102, 51, 25) / 255
        func sample(
            _ mode: Float,
            effects: SIMD4<Float>? = nil,
            parameters: SIMD4<Float> = .zero,
            pixelX: Int = 16,
            noiseTexture: (any MTLTexture)? = nil
        ) throws -> SIMD4<
            Float
        > {
            var uniforms = Uniforms(
                rect: .init(0, 0, 1, 1),
                uv: .init(0, 0, 1, 1),
                color: .one,
                effects: effects ?? .init(mode, 0, 0, 0),
                parameters: parameters
            )
            let buffer = queue.makeCommandBuffer()!
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentTexture(noiseTexture ?? noise, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
            buffer.commit()
            wait(buffer)
            guard buffer.status == .completed else { throw Failure.gpu }
            var bytes = [UInt8](repeating: 0, count: 4)
            output.getBytes(
                &bytes,
                bytesPerRow: 4,
                from: .init(origin: .init(x: pixelX, y: 16, z: 0), size: .init(width: 1, height: 1, depth: 1)),
                mipmapLevel: 0
            )
            return .init(Float(bytes[2]) / 255, Float(bytes[1]) / 255, Float(bytes[0]) / 255, Float(bytes[3]) / 255)
        }
        func expect(_ actual: SIMD4<Float>, _ expected: SIMD4<Float>, _ name: String) throws {
            checks += 1
            for index in 0..<4 where abs(actual[index] - expected[index]) > 1.5 / 255 {
                throw Failure.mismatch("\(name): \(actual) != \(expected)")
            }
        }
        let alpha: Float = 128 / 255
        try expect(sample(0), .init(rgb, alpha), "Premultiplied source")
        let mono = (rgb.x + rgb.y + rgb.z) * 0.5
        try expect(sample(1), .init(rgb * 0.5 + SIMD3(repeating: mono * 0.25), alpha), "Reference flashback matrix")
        let gray = rgb.x * 0.298912 + rgb.y * 0.586611 + rgb.z * 0.114478
        try expect(
            sample(2),
            .init(rgb * 0.25 + SIMD3<Float>(1.07, 0.74, 0.43) * gray * 0.75, alpha),
            "Reference sepia matrix"
        )
        let straight = rgb / alpha
        let holoGray = (straight.x * 0.2 + straight.y * 0.45 + straight.z * 0.35) * alpha
        let holo =
            (SIMD3<Float>(0.9, 1.2, 1.15) * holoGray * 0.6 + straight * 0.4 + SIMD3(repeating: 64.0 / 255 * 0.07))
            * alpha * 0.87
        try expect(
            sample(3, effects: .init(3, 0.86, 0.3, 0.87), parameters: .init(1, 1, 1, 0)),
            .init(holo, alpha * 0.87),
            "Hologram premultiplication, tone and noise threshold"
        )
        try expect(
            sample(4, effects: .init(4, 2.8, -0.5, 0)),
            .init(rgb * 0.999, alpha * 0.999),
            "Fourteen-tap background Gaussian material"
        )
        try expect(sample(8, parameters: .init(4, 0, 0, 0)), .init(rgb, alpha), "Choice pill center")
        try expect(sample(9), .zero, "Dialogue gradient leaves upper stage clear")
        try expect(sample(10), .init(rgb * 0.5, alpha * 0.5), "Horizontal transition feather")
        try expect(sample(11), .init(rgb * 0.5, alpha * 0.5), "Vertical transition feather")
        try expect(
            sample(13, parameters: .init(45, 0, 0, 0)),
            .init(rgb * 0.5, alpha * 0.5),
            "Rounded namebar gradient"
        )
        let rampDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 8,
            height: 1,
            mipmapped: false
        )
        rampDescriptor.usage = .shaderRead
        let ramp = device.makeTexture(descriptor: rampDescriptor)!
        let rampBytes: [UInt8] = (0..<8).flatMap { [UInt8($0 * 32), 0, 0, 255] }
        rampBytes.withUnsafeBytes {
            ramp.replace(
                region: .init(origin: .init(x: 0, y: 0, z: 0), size: .init(width: 8, height: 1, depth: 1)),
                mipmapLevel: 0,
                withBytes: $0.baseAddress!,
                bytesPerRow: 32
            )
        }
        let u = ((3.5 / 33 - 0.5) * 4 + 0.5) * 0.25
        let coordinate = u * 8 - 0.5
        let fraction = Float(coordinate - floor(coordinate))
        let index = ((Int(floor(coordinate)) % 8) + 8) % 8
        let intensity = (Float(index * 32) * (1 - fraction) + Float(((index + 1) % 8) * 32) * fraction) / 255
        let paddedHolo =
            (SIMD3<Float>(0.9, 1.2, 1.15) * holoGray * 0.6 + straight * 0.4 + SIMD3(repeating: intensity * 0.07))
            * alpha * 0.87
        try expect(
            sample(
                3,
                effects: .init(3, 0.86, 0.3, 0.87),
                parameters: .init(4, 2.2, 1, 0),
                pixelX: 3,
                noiseTexture: ramp
            ),
            .init(paddedHolo, alpha * 0.87),
            "Hologram noise remains anchored to the model canvas when drawable bounds expand"
        )
        print(
            "PASS: \(checks) compiled Metal shader pixel comparisons against reference color, hologram, Gaussian and transition formulas."
        )
    }
    
    private static func texture(device: any MTLDevice, pixel: [UInt8], size: Int = 1) -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        let bytes = (0..<(size * size)).flatMap { _ in [pixel[2], pixel[1], pixel[0], pixel[3]] }
        bytes.withUnsafeBytes {
            texture.replace(
                region: .init(origin: .init(x: 0, y: 0, z: 0), size: .init(width: size, height: size, depth: 1)),
                mipmapLevel: 0,
                withBytes: $0.baseAddress!,
                bytesPerRow: size * 4
            )
        }
        return texture
    }
    
    private struct Uniforms {
        var rect: SIMD4<Float>
        var uv: SIMD4<Float>
        var color: SIMD4<Float>
        var effects: SIMD4<Float>
        var parameters: SIMD4<Float>
    }
    
    private enum Failure: Error { case gpu, mismatch(String) }
}
