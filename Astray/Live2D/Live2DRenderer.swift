internal import Metal
internal import Foundation
internal import AstrayCubismBridge

@MainActor
internal final class Live2DRenderer {
    internal static func advance(_ runtime: ASRCubismModel, by delta: Double, time: Double, mouth: Float) {
        guard delta > 0 else { return }
        // A tiny remainder can amplify particle velocity in physics files without an authored FPS.
        // Keep normal display intervals intact and divide long intervals into comparable steps.
        let count = max(1, Int((delta * 60).rounded()))
        let step = delta / Double(count)
        for index in 0..<count {
            runtime.update(step, time: time - delta + Double(index + 1) * step, mouth: mouth)
        }
    }
    
    private let player: StoryPlayer
    private let device: any MTLDevice
    private let pipelines: [Int: any MTLRenderPipelineState]
    private let maskPipeline: any MTLRenderPipelineState
    internal var stageHeight = 720
    private var models: [Key: Model] = [:]
    private var textures: [String: [any MTLTexture]] = [:]
    private var revision = -1
    
    internal init(player: StoryPlayer, device: any MTLDevice, library: any MTLLibrary) throws {
        self.player = player
        self.device = device
        func pipeline(blend: Int, mask: Bool = false) throws -> any MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "astray_cubism_vertex")
            descriptor.fragmentFunction = library.makeFunction(
                name: mask ? "astray_cubism_mask" : "astray_cubism_fragment"
            )
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = mask ? .r8Unorm : .bgra8Unorm
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = blend == 2 ? .destinationColor : .one
            color.destinationRGBBlendFactor = blend == 1 ? .one : .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = blend == 0 ? .one : .zero
            color.destinationAlphaBlendFactor = blend == 0 ? .oneMinusSourceAlpha : .one
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        pipelines = try [0: pipeline(blend: 0), 1: pipeline(blend: 1), 2: pipeline(blend: 2)]
        maskPipeline = try pipeline(blend: 0, mask: true)
    }
    
    internal func reset() {
        for model in models.values {
            model.runtime.reset()
            model.motionRevision = -1
            model.lastTime = nil
            model.lastFacial = ""
            model.hasRendered = false
            for mask in model.masks { mask.isValid = false }
        }
    }
    
    internal func isMotionPlaying(characterID: Int) -> Bool {
        models.contains { $0.key.characterID == characterID && $0.value.runtime.isMotionPlaying }
    }
    
    internal func texture(
        for character: CharacterState,
        time: TimeInterval,
        device: any MTLDevice,
        commandBuffer: any MTLCommandBuffer,
        resources: FrameResources
    ) throws -> (any MTLTexture)? {
        guard let assets = player.live2DAssets[character.costume], let model = try model(for: character) else { return nil }
        finishBottomCalibration()
        let rest = character.motion.isEmpty ? player.modelRestingParameterValues : [:]
        let overrides = rest.merging(player.modelFaceTrackingValues) { _, tracked in tracked }
            .merging(player.modelParameterOverrides) { _, manual in manual }
        let controlsChanged = model.runtime.blinkEnabled != player.isModelBlinkEnabled
            || model.runtime.locksTransform != player.usesFixedModelFraming
            || model.runtime.breathEnabled != player.isModelBreathEnabled
            || model.runtime.breathSwayEnabled != player.isModelBreathSwayEnabled
            || model.overrides != overrides
        model.runtime.blinkEnabled = player.isModelBlinkEnabled
        model.runtime.locksTransform = player.usesFixedModelFraming
        model.runtime.breathEnabled = player.isModelBreathEnabled
        model.runtime.breathSwayEnabled = player.isModelBreathSwayEnabled
        if model.overrides != overrides {
            model.overrides = overrides
            model.runtime.parameterOverrides = model.overrides.mapValues { NSNumber(value: $0) }
        }
        let first = model.motionRevision == -1
        let motionChanged = model.motionRevision != character.motionRevision
        let facialChanged = model.lastFacial != character.facial
        // Register new clips on the existing Cubism instance and retain geometry,
        // textures, physics and the other animation channel.
        if !character.motion.isEmpty, !model.loadedMotions.contains(character.motion), let data = assets.motions[character.motion] {
            try model.runtime.loadMotion(data, name: character.motion, facial: false)
            model.loadedMotions.insert(character.motion)
        }
        if !character.facial.isEmpty, !model.loadedFacials.contains(character.facial), let data = assets.facials[character.facial] {
            try model.runtime.loadMotion(data, name: character.facial, facial: true)
            model.loadedFacials.insert(character.facial)
        }
        if motionChanged, character.motion.isEmpty { model.runtime.stopMotion() }
        if facialChanged, character.facial.isEmpty { model.runtime.clearFacial() }
        if first || motionChanged || facialChanged {
            model.runtime.playMotion(
                motionChanged || first ? character.motion : "",
                facial: character.facial,
                instant: first || player.status == .paused
            )
            model.motionRevision = character.motionRevision
            model.lastFacial = character.facial
        }
        let delta = max(0, time - (model.lastTime ?? time))
        if first || motionChanged || facialChanged || controlsChanged || delta > 0 {
            if first || motionChanged || facialChanged || controlsChanged { model.runtime.update(0, time: time - delta, mouth: character.mouthOpen) }
            Self.advance(model.runtime, by: delta, time: time, mouth: character.mouthOpen)
            model.lastTime = time
        }
        model.runtime.updateRenderDrawables()
        if model.bottom == nil {
            model.bottom = model.runtime.renderDrawables
                .filter { $0.isVisible && $0.opacity > 0 && $0.vertexCount > 0 }
                .map { $0.bounds.y }.min().map { $0 / model.runtime.canvasHeight }
        }
        let extent = model.runtime.maximumDrawableExtent
        if !player.usesFixedModelFraming || !model.hasRendered {
            let padding: Float = player.usesFixedModelFraming ? 1.5 : 1.02
            model.renderWidth = max(model.runtime.canvasWidth * padding, extent.x * 2 + model.runtime.canvasWidth * 0.02)
            model.renderHeight = max(model.runtime.canvasHeight * padding, extent.y * 2 + model.runtime.canvasHeight * 0.02)
        }
        let pixelsPerUnit = Double(stageHeight) * 2.08 * Double(character.scale) / Double(model.runtime.canvasHeight)
        let height = max(1, min(16384, Int(ceil(Double(model.renderHeight) * pixelsPerUnit))))
        let width = max(1, min(16384, Int(ceil(Double(model.renderWidth) * pixelsPerUnit))))
        let resized = model.target.width != width || model.target.height != height
        if resized {
            model.target = try renderTexture(width: width, height: height)
        }
        if model.hasRendered && !resized && !model.runtime.hasRenderChanges { return model.target }
        if model.drawOrder.contains(where: { model.geometry[$0].order != model.geometry[$0].drawable.renderOrder }) {
            model.drawOrder.sort { model.geometry[$0].drawable.renderOrder < model.geometry[$1].drawable.renderOrder }
        }
        for geometry in model.geometry {
            geometry.order = geometry.drawable.renderOrder
            if geometry.drawable.vertexCount > 0 {
                geometry.positions = try resources.upload(
                    geometry.drawable.positionBytes,
                    count: geometry.drawable.vertexCount * 8
                )
            }
        }
        for (index, mask) in model.masks.enumerated() {
            if resized || mask.identifiers.contains(where: { model.geometry[$0].drawable.verticesChanged }) {
                mask.isValid = false
            }
            guard model.geometry.contains(where: { $0.mask == index && $0.drawable.isVisible }) else { continue }
            if mask.isValid { continue }
            let rect = maskRect(mask, model: model)
            if mask.target == nil || mask.target!.width < rect.width || mask.target!.height < rect.height {
                mask.target = try renderTexture(width: rect.width, height: rect.height, mask: true)
            }
            let target = mask.target!
            let scale = SIMD2(Float(width) / Float(target.width), Float(height) / Float(target.height))
            mask.transform = .init(
                scale.x,
                scale.y,
                -Float(rect.x) / Float(target.width),
                -Float(rect.y) / Float(target.height)
            )
            let canvas = SIMD4<Float>(
                2 / model.renderWidth * scale.x,
                2 / model.renderHeight * scale.y,
                (Float(width) - 2 * Float(rect.x)) / Float(target.width) - 1,
                1 - (Float(height) - 2 * Float(rect.y)) / Float(target.height)
            )
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass(for: target)) else {
                throw AstrayError.renderingFailed("Unable to encode a Cubism clipping mask.")
            }
            defer { encoder.endEncoding() }
            encoder.label = "Cubism clipping mask"
            encoder.setRenderPipelineState(maskPipeline)
            for identifier in mask.identifiers {
                draw(model.geometry[identifier], model: model, canvas: canvas, encoder: encoder)
            }
            mask.isValid = true
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass(for: model.target)) else {
            throw AstrayError.renderingFailed("Unable to encode a Cubism model.")
        }
        encoder.label = "Cubism character \(character.id)"
        for index in model.drawOrder {
            let geometry = model.geometry[index]
            let drawable = geometry.drawable
            guard drawable.isVisible && drawable.opacity > 0 else { continue }
            guard let pipeline = pipelines[drawable.blendMode] else {
                encoder.endEncoding()
                throw AstrayError.renderingFailed("Unknown Cubism drawable blend mode: \(drawable.blendMode).")
            }
            encoder.setRenderPipelineState(pipeline)
            draw(geometry, model: model, encoder: encoder)
        }
        encoder.endEncoding()
        if player.usesFixedModelFraming && !model.hasRendered {
            // Calibrate once from rendered alpha, excluding transparent texture padding.
            let stride = (width * 4 + 255) / 256 * 256
            if let buffer = device.makeBuffer(length: stride * height, options: .storageModeShared),
               let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: model.target, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: .init(x: 0, y: 0, z: 0), sourceSize: .init(width: width, height: height, depth: 1),
                          to: buffer, destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * height)
                blit.endEncoding()
                model.calibration = (buffer, commandBuffer, width, height, stride)
            }
        }
        model.hasRendered = true
        return model.target
    }
    
    internal func finishBottomCalibration() {
        for model in models.values {
            guard let (buffer, command, width, height, stride) = model.calibration, command.status == .completed else { continue }
            let pixels = buffer.contents().assumingMemoryBound(to: UInt8.self)
            // Use the body's central lower edge, not long hair, ribbons or other
            // side accessories that can extend below the feet (notably normal Miku).
            let halfBody = max(1, Int(Float(width) * model.runtime.canvasHeight * 0.065 / model.renderWidth))
            let body = max(0, width / 2 - halfBody)..<min(width, width / 2 + halfBody)
            func bottomRow(in columns: Range<Int>) -> Int? {
                for row in (0..<height).reversed() {
                    if columns.contains(where: { pixels[row * stride + $0 * 4 + 3] > 32 }) { return row }
                }
                return nil
            }
            if let row = bottomRow(in: body) ?? bottomRow(in: 0..<width) {
                model.bottom = (0.5 - Float(row + 1) / Float(height)) * model.renderHeight / model.runtime.canvasHeight
            }
            model.calibration = nil
        }
    }

    private func model(for character: CharacterState) throws -> Model? {
        if revision != player.assetRevision {
            models.removeAll()
            textures.removeAll()
            revision = player.assetRevision
        }
        let key = Key(characterID: character.id, costume: character.costume)
        if let existing = models[key] { return existing }
        guard let assets = player.live2DAssets[character.costume] else { return nil }
        let model = try makeModel(assets, costume: character.costume)
        models[key] = model
        return model
    }

    internal func parameters(for character: CharacterState) throws -> [ModelParameter] {
        try model(for: character)?.runtime.parameters.map {
            ModelParameter(id: $0.identifier, minimum: $0.minimum, maximum: $0.maximum,
                           defaultValue: $0.defaultValue, value: $0.value)
        } ?? []
    }

    internal func bottom(for character: CharacterState) -> Float {
        models[.init(characterID: character.id, costume: character.costume)]?.bottom ?? -0.5
    }

    internal func canvasScale(for character: CharacterState) -> SIMD2<Float> {
        guard let model = models[.init(characterID: character.id, costume: character.costume)] else { return .one }
        return .init(model.renderWidth / model.runtime.canvasHeight, model.renderHeight / model.runtime.canvasHeight)
    }
    
    internal func canvasAspect(for character: CharacterState) -> Float {
        guard let model = models[.init(characterID: character.id, costume: character.costume)] else { return 1 }
        return model.runtime.canvasWidth / model.runtime.canvasHeight
    }
    
    private func makeModel(_ assets: Live2DAssets, costume: String) throws -> Model {
        let runtime = try ASRCubismModel(moc: assets.moc, physics: assets.physics, pose: assets.pose)
        for (name, data) in assets.motions { try runtime.loadMotion(data, name: name, facial: false) }
        for (name, data) in assets.facials { try runtime.loadMotion(data, name: name, facial: true) }
        let textures: [any MTLTexture]
        if let cached = self.textures[costume] {
            textures = cached
        } else {
            textures = try assets.textures.map { try BitmapTexture.make(data: $0, device: device) }
            self.textures[costume] = textures
        }
        func buffer(_ data: Data) throws -> (any MTLBuffer)? {
            guard !data.isEmpty else { return nil }
            guard let result = data.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
            else {
                throw AstrayError.renderingFailed("Unable to allocate Cubism geometry storage.")
            }
            return result
        }
        let geometry = try runtime.renderDrawables.map { drawable in
            try Geometry(
                drawable: drawable,
                coordinates: buffer(drawable.textureCoordinates),
                indices: buffer(drawable.indices)
            )
        }
        var masks: [Mask] = []
        var groups: [[Int]: Int] = [:]
        for item in geometry where !item.drawable.masks.isEmpty {
            let identifiers = item.drawable.masks.map(\.intValue)
            if let index = groups[identifiers] {
                item.mask = index
            } else {
                item.mask = masks.count
                groups[identifiers] = masks.count
                masks.append(.init(identifiers: identifiers))
            }
        }
        let width = max(1, min(4096, Int(1024 * runtime.canvasWidth / max(0.001, runtime.canvasHeight))))
        let model = try Model(
            runtime: runtime,
            textures: textures,
            geometry: geometry,
            masks: masks,
            target: renderTexture(width: width, height: 1024)
        )
        model.loadedMotions = Set(assets.motions.keys)
        model.loadedFacials = Set(assets.facials.keys)
        return model
    }
    
    private func draw(
        _ geometry: Geometry,
        model: Model,
        canvas: SIMD4<Float>? = nil,
        encoder: any MTLRenderCommandEncoder
    ) {
        let drawable = geometry.drawable
        guard model.textures.indices.contains(drawable.textureIndex), let positions = geometry.positions,
            let coordinates = geometry.coordinates, let indices = geometry.indices
        else { return }
        let mask = canvas == nil ? geometry.mask.map { model.masks[$0] } : nil
        var uniforms = Uniforms(
            canvas: canvas ?? .init(2 / model.renderWidth, 2 / model.renderHeight, 0, 0),
            multiply: drawable.multiplyColor,
            screen: drawable.screenColor,
            options: .init(drawable.opacity, mask == nil ? 0 : 1, drawable.isMaskInverted ? 1 : 0, 0),
            maskTransform: mask?.transform ?? .init(1, 1, 0, 0)
        )
        encoder.setVertexBuffer(positions.buffer, offset: positions.offset, index: 0)
        encoder.setVertexBuffer(coordinates, offset: 0, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
        encoder.setFragmentTexture(model.textures[drawable.textureIndex], index: 0)
        encoder.setFragmentTexture(mask?.target ?? model.textures[drawable.textureIndex], index: 1)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(drawable.isCulling ? .back : .none)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: drawable.indices.count / 2,
            indexType: .uint16,
            indexBuffer: indices,
            indexBufferOffset: 0
        )
    }
    
    private func maskRect(_ mask: Mask, model: Model) -> (x: Int, y: Int, width: Int, height: Int) {
        var minimum = SIMD2<Float>(repeating: .infinity), maximum = SIMD2<Float>(repeating: -.infinity)
        for id in mask.identifiers where model.geometry[id].drawable.vertexCount > 0 {
            let bounds = model.geometry[id].drawable.bounds
            minimum = .init(min(minimum.x, bounds.x), min(minimum.y, bounds.y))
            maximum = .init(max(maximum.x, bounds.z), max(maximum.y, bounds.w))
        }
        guard minimum.x.isFinite else { return (0, 0, 1, 1) }
        let width = model.target.width, height = model.target.height
        let x = max(
            0,
            min(width - 1, Int(floor((Double(minimum.x / model.renderWidth + 0.5) * Double(width) - 2) / 32)) * 32)
        )
        let y = max(
            0,
            min(height - 1, Int(floor((Double(0.5 - maximum.y / model.renderHeight) * Double(height) - 2) / 32)) * 32)
        )
        let right = min(width, Int(ceil((Double(maximum.x / model.renderWidth + 0.5) * Double(width) + 2) / 32)) * 32)
        let bottom = min(
            height,
            Int(ceil((Double(0.5 - minimum.y / model.renderHeight) * Double(height) + 2) / 32)) * 32
        )
        return (x, y, max(1, right - x), max(1, bottom - y))
    }
    
    private func renderTexture(width: Int, height: Int, mask: Bool = false) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: mask ? .r8Unorm : .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let target = device.makeTexture(descriptor: descriptor) else { throw AstrayError.metalUnavailable }
        return target
    }
    
    private func pass(for texture: any MTLTexture) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = .init(red: 0, green: 0, blue: 0, alpha: 0)
        return pass
    }
    
    private struct Key: Hashable {
        internal let characterID: Int
        internal let costume: String
    }
    
    private struct Uniforms {
        internal var canvas: SIMD4<Float>
        internal var multiply: SIMD4<Float>
        internal var screen: SIMD4<Float>
        internal var options: SIMD4<Float>
        internal var maskTransform: SIMD4<Float>
    }
    
    private final class Model {
        internal let runtime: ASRCubismModel
        internal let textures: [any MTLTexture]
        internal let geometry: [Geometry]
        internal let masks: [Mask]
        internal var drawOrder: [Int]
        internal var hasRendered = false
        internal var bottom: Float?
        internal var calibration: ((any MTLBuffer), (any MTLCommandBuffer), Int, Int, Int)?
        internal var overrides: [String: Float] = [:]
        internal var target: any MTLTexture
        internal var renderWidth: Float
        internal var renderHeight: Float
        internal var motionRevision = -1
        internal var lastFacial = ""
        internal var lastTime: Double?
        internal var loadedMotions: Set<String> = []
        internal var loadedFacials: Set<String> = []
        
        internal init(
            runtime: ASRCubismModel,
            textures: [any MTLTexture],
            geometry: [Geometry],
            masks: [Mask],
            target: any MTLTexture
        ) {
            renderWidth = runtime.canvasWidth * 1.02
            renderHeight = runtime.canvasHeight * 1.02
            self.runtime = runtime
            self.textures = textures
            self.geometry = geometry
            self.masks = masks
            drawOrder = geometry.indices.sorted {
                geometry[$0].drawable.renderOrder < geometry[$1].drawable.renderOrder
            }
            self.target = target
        }
    }
    
    private final class Geometry {
        internal let drawable: ASRCubismDrawable
        internal let coordinates: (any MTLBuffer)?
        internal let indices: (any MTLBuffer)?
        internal var positions: BufferSlice?
        internal var mask: Int?
        internal var order: Int
        
        internal init(drawable: ASRCubismDrawable, coordinates: (any MTLBuffer)?, indices: (any MTLBuffer)?) {
            self.drawable = drawable; self.coordinates = coordinates; self.indices = indices
            order = drawable.renderOrder
        }
    }
    
    private final class Mask {
        internal let identifiers: [Int]
        internal var target: (any MTLTexture)?
        internal var transform = SIMD4<Float>(1, 1, 0, 0)
        internal var isValid = false
        
        internal init(identifiers: [Int]) { self.identifiers = identifiers }
    }
}
