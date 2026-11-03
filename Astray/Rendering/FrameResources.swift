internal import Metal
internal import Foundation

internal struct BufferSlice {
    internal let buffer: any MTLBuffer
    internal let offset: Int
}

@MainActor
internal final class FrameResources {
    private let device: any MTLDevice
    private var buffers: [any MTLBuffer] = []
    private var index = 0
    private var offset = 0
    
    internal init(device: any MTLDevice) { self.device = device }
    
    internal func reset() { index = 0; offset = 0 }
    
    internal func upload(_ bytes: UnsafeRawPointer, count: Int) throws -> BufferSlice {
        let aligned = (offset + 255) & ~255
        if index < buffers.count && aligned + count > buffers[index].length {
            index += 1
            offset = 0
        }
        if index == buffers.count {
            let capacity = max(256 * 1024, (count + 65535) & ~65535)
            guard let buffer = device.makeBuffer(length: capacity, options: .storageModeShared) else {
                throw AstrayError.renderingFailed("Unable to allocate frame geometry storage.")
            }
            buffers.append(buffer)
        } else if buffers[index].length < count {
            guard let buffer = device.makeBuffer(length: (count + 65535) & ~65535, options: .storageModeShared) else {
                throw AstrayError.renderingFailed("Unable to grow frame geometry storage.")
            }
            buffers[index] = buffer
        }
        let start = (offset + 255) & ~255
        let buffer = buffers[index]
        buffer.contents().advanced(by: start).copyMemory(from: bytes, byteCount: count)
        offset = start + count
        return .init(buffer: buffer, offset: start)
    }
}

// Only the slot indices cross threads; frame storage is owned by the renderer's main actor.
internal final class FrameSlots: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 3)
    private let lock = NSLock()
    private var available = [0, 1, 2]
    
    internal func acquire() -> Int {
        semaphore.wait()
        lock.lock()
        let index = available.removeLast()
        lock.unlock()
        return index
    }
    
    internal func release(_ index: Int) {
        lock.lock()
        available.append(index)
        lock.unlock()
        semaphore.signal()
    }
}
