public import Metal
public import Foundation

/// A host can render Cubism or another animated character into a premultiplied RGBA texture.
@MainActor
public protocol CharacterRendering: AnyObject {
    /// Encode work on this command buffer, without committing it. Return nil to use the built-in Cubism renderer or costume PNG.
    func texture(
        for character: CharacterState,
        time: TimeInterval,
        device: any MTLDevice,
        commandBuffer: any MTLCommandBuffer
    ) throws -> (any MTLTexture)?
    
    /// Called after a new load, stop, or jump so motion and simulation state can be rebuilt.
    func reset()
}

extension CharacterRendering {
    public func reset() {}
}
