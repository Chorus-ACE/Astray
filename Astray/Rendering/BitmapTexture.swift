internal import Metal
internal import ImageIO
internal import Foundation
internal import CoreGraphics

internal enum BitmapTexture {
    internal static func make(data: Data, device: any MTLDevice) throws -> any MTLTexture {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw AstrayError.renderingFailed("Unable to decode texture image.")
        }
        context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
        return try make(context: context, device: device)
    }
    
    internal static func make(context: CGContext, device: any MTLDevice) throws -> any MTLTexture {
        guard let data = context.data else { throw AstrayError.renderingFailed("Missing bitmap storage.") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: context.width,
            height: context.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw AstrayError.renderingFailed("Unable to allocate a bitmap texture.")
        }
        texture.replace(
            region: .init(
                origin: .init(x: 0, y: 0, z: 0),
                size: .init(width: context.width, height: context.height, depth: 1)
            ),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: context.bytesPerRow
        )
        return texture
    }
}
