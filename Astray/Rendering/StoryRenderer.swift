public import Metal
internal import Foundation
internal import CoreGraphics

@MainActor
public final class StoryRenderer {
    public let player: StoryPlayer
    public let device: any MTLDevice
    public var characterRenderer: (any CharacterRendering)?
    internal var scalesToFill = false
    internal var interfaceBounds: CGRect?
    private let live2D: Live2DRenderer
    private let effects: EffectRuntime
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let blurPipeline: any MTLRenderPipelineState
    private let effectPipelines: [EffectBlend: any MTLRenderPipelineState]
    private let white: any MTLTexture
    private let text: TextRasterizer
    private let frameSlots = FrameSlots()
    private let frames: [FrameResources]
    private var frameResources: FrameResources?
    private var textures: [AssetRequest: any MTLTexture] = [:]
    private var prefabTextures: [String: any MTLTexture] = [:]
    private var targets: [String: any MTLTexture] = [:]
    private var failedTextures: Set<AssetRequest> = []
    private var holograms: [Int: Hologram] = [:]
    private var assetRevision = -1
    private var playbackRevision = -1
    private var lastTime: Double = 0
    private var textScale: Double = 1
    private var textCanvasWidth: Double = 1280
    private var continuationMark: (any MTLTexture)?
    
    public init(player: StoryPlayer, device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw AstrayError.metalUnavailable }
        self.player = player
        self.device = device
        self.queue = queue
        frames = (0..<3).map { _ in FrameResources(device: device) }
        text = .init(device: device)
        effects = .init(player: player)
        let library: any MTLLibrary
        do { library = try device.makeDefaultLibrary(bundle: Bundle(for: ShaderBundleToken.self)) } catch {
            throw AstrayError.shaderLibraryUnavailable(error.localizedDescription)
        }
        live2D = try .init(player: player, device: device, library: library)
        func make(vertex: String, fragment: String, multiply: Bool = false) throws -> any MTLRenderPipelineState {
            guard let vertexFunction = library.makeFunction(name: vertex),
                let fragmentFunction = library.makeFunction(name: fragment)
            else {
                throw AstrayError.shaderLibraryUnavailable("Missing \(vertex) / \(fragment).")
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            color.isBlendingEnabled = true
            color.sourceRGBBlendFactor = multiply ? .destinationColor : .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .one
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        pipeline = try make(vertex: "astray_vertex", fragment: "astray_fragment")
        blurPipeline = try make(vertex: "astray_vertex", fragment: "astray_blur_fragment")
        effectPipelines = try [
            .alpha: make(vertex: "astray_effect_vertex", fragment: "astray_effect_fragment"),
            .multiply: make(vertex: "astray_effect_vertex", fragment: "astray_effect_fragment", multiply: true),
        ]
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let white = device.makeTexture(descriptor: descriptor) else { throw AstrayError.metalUnavailable }
        self.white = white
        var pixel = UInt32.max
        white.replace(
            region: .init(origin: .init(x: 0, y: 0, z: 0), size: .init(width: 1, height: 1, depth: 1)),
            mipmapLevel: 0,
            withBytes: &pixel,
            bytesPerRow: 4
        )
        player.motionIsPlaying = { [weak live2D] in live2D?.isMotionPlaying(characterID: $0) == true }
    }
    
    /// The target must be a single-sample BGRA8Unorm render target. The returned buffer is committed.
    @discardableResult
    public func render(to target: any MTLTexture) throws -> any MTLCommandBuffer {
        try render(to: target, presenting: nil)
    }
    
    @discardableResult
    internal func render(to target: any MTLTexture, presenting drawable: (any MTLDrawable)?) throws
        -> any MTLCommandBuffer
    {
        guard target.pixelFormat == .bgra8Unorm, target.sampleCount == 1,
            target.usage.contains(.renderTarget), target.device.registryID == device.registryID
        else {
            throw AstrayError.renderingFailed("Target must be a BGRA8Unorm render texture on the renderer's device.")
        }
        let slot = frameSlots.acquire()
        var submitted = false
        defer {
            frameResources = nil
            if !submitted { frameSlots.release(slot) }
        }
        let resources = frames[slot]
        resources.reset()
        frameResources = resources
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw AstrayError.renderingFailed("Unable to allocate a command buffer.")
        }
        commandBuffer.label = "Astray story render graph"
        if assetRevision != player.assetRevision {
            textures = [:]
            prefabTextures = [:]
            failedTextures = []
            text.clear()
            assetRevision = player.assetRevision
        }
        if playbackRevision != player.renderRevision {
            characterRenderer?.reset()
            live2D.reset()
            holograms = [:]
            lastTime = player.visualTime
            playbackRevision = player.renderRevision
        }
        effects.update()
        let stage = player.stage
        let delta = max(0, player.visualTime - lastTime)
        lastTime = player.visualTime
        let viewport = Self.viewport(width: target.width, height: target.height, scalesToFill: scalesToFill)
        let characterViewport = characterViewport(
            width: max(1, Int(viewport.width)),
            height: max(1, Int(viewport.height))
        )
        live2D.stageHeight = max(1, Int(characterViewport.height))
        let characters = stage.characters.values.sorted { $0.depth == $1.depth ? $0.id < $1.id : $0.depth < $1.depth }
        var characterTextures: [Int: any MTLTexture] = [:]
        var nativeScales: [Int: SIMD2<Float>] = [:]
        for character in characters where character.opacity > 0 {
            let supplied = try characterRenderer?.texture(
                for: character,
                time: player.visualTime,
                device: device,
                commandBuffer: commandBuffer
            )
            let native =
                supplied == nil
                ? try live2D.texture(
                    for: character,
                    time: player.visualTime,
                    device: device,
                    commandBuffer: commandBuffer,
                    resources: resources
                ) : nil
            if native != nil { nativeScales[character.id] = live2D.canvasScale(for: character) }
            guard var texture = try supplied ?? native ?? texture(for: .character(character.costume)) else { continue }
            if character.shader == "blur" {
                let strength = pow(min(3, max(1, character.shaderIntensity)), 2) * 2 / 3
                let pixelsPerStagePixel =
                    Float(texture.height) / (720 * 2.08 * character.scale * (nativeScales[character.id]?.y ?? 1))
                texture = try blur(
                    texture,
                    key: "character.\(character.id)",
                    passes: [(1, 0), (1, 0), (0, 1), (0, 1)],
                    steps: Array(repeating: strength * pixelsPerStagePixel / 2, count: 4),
                    character: true,
                    commandBuffer: commandBuffer
                )
            }
            if character.shader == "hologram" || character.shader == "monitor" {
                let flicker =
                    holograms[character.id].flatMap { $0.kind == character.shader ? $0 : nil }
                    ?? .init(kind: character.shader)
                flicker.update(delta)
                holograms[character.id] = flicker
            } else {
                holograms[character.id] = nil
            }
            characterTextures[character.id] = texture
        }
        let movie = try player.movie.texture(device: device, commandBuffer: commandBuffer)
        let world = try self.target(
            key: "world",
            width: max(1, Int(viewport.width)),
            height: max(1, Int(viewport.height))
        )
        let worldEncoder = try encoder(
            commandBuffer,
            target: world,
            clear: .init(red: 0.025, green: 0.03, blue: 0.045, alpha: 1)
        )
        worldEncoder.label = "Astray world, background prefab and particle layers"
        let backgroundViewport = Self.viewport(width: world.width, height: world.height, scalesToFill: true)
        let backgroundAspect = Float(world.width) / Float(world.height)
        do {
            worldEncoder.setViewport(characterViewport)
            try drawEffects(layer: .bottom, stage: stage, encoder: worldEncoder)
            worldEncoder.setViewport(backgroundViewport)
            let backgroundRect = worldRect(
                .init(
                    0.5 - 1.21 * stage.dolly.x / 2,
                    0.5 - 1.21 * stage.dolly.x / 2,
                    1.21 * stage.dolly.x,
                    1.21 * stage.dolly.x
                ),
                stage: stage
            )
            let sampling = stage.dolly.w > 0 ? stage.dolly.y : stage.backgroundBlur
            let distortion = stage.dolly.w > 0 ? stage.dolly.z : 0
            if stage.backgroundMix < 1, let previous = try texture(for: .background(stage.previousBackground)) {
                draw(
                    previous,
                    rect: backgroundRect,
                    uv: aspectFill(previous, aspect: backgroundAspect),
                    effects: .init(4, sampling, distortion, 0),
                    encoder: worldEncoder
                )
            }
            if let background = try texture(for: .background(stage.background)) {
                draw(
                    background,
                    rect: backgroundRect,
                    uv: aspectFill(background, aspect: backgroundAspect),
                    color: .init(1, 1, 1, stage.backgroundMix),
                    effects: .init(4, sampling, distortion, 0),
                    encoder: worldEncoder
                )
            }
            worldEncoder.setViewport(characterViewport)
            try drawEffects(layer: .bottom, stage: stage, backgroundOnly: true, encoder: worldEncoder)
            try drawEffects(layer: .back, stage: stage, encoder: worldEncoder)
            for character in characters {
                guard let source = characterTextures[character.id] else { continue }
                let base = character.scale * 2.08
                let extent = nativeScales[character.id] ?? .init(Float(source.width) / Float(source.height), 1)
                let height = base * extent.y
                let width = base * extent.x * 9 / 16
                let rect = worldRect(
                    .init(
                        character.x - width / 2 + character.shake.x,
                        0.811 - height / 2 + character.shake.y,
                        width,
                        height
                    ),
                    stage: stage
                )
                let tint = SIMD4(stage.tint.x, stage.tint.y, stage.tint.z, character.opacity)
                let flicker = holograms[character.id]
                let noise = try texture(for: .ui("scenario/holo.png")) ?? white
                draw(
                    source,
                    rect: rect,
                    color: tint,
                    effects: .init(
                        flicker == nil ? 0 : 3,
                        flicker?.line ?? 0,
                        Float(flicker?.time ?? 0),
                        flicker?.alpha ?? 1
                    ),
                    parameters: .init(
                        extent.x,
                        extent.y,
                        nativeScales[character.id] == nil ? extent.x : live2D.canvasAspect(for: character),
                        0
                    ),
                    noise: noise,
                    encoder: worldEncoder
                )
            }
            try drawEffects(layer: .front, stage: stage, encoder: worldEncoder)
            try drawEffects(layer: .top, stage: stage, encoder: worldEncoder)
        } catch { worldEncoder.endEncoding(); throw error }
        worldEncoder.endEncoding()
        var composed: any MTLTexture = world
        if stage.isCameraBlurActive {
            let half = try self.target(
                key: "world.half",
                width: max(1, world.width / 2),
                height: max(1, world.height / 2)
            )
            let downsample = try encoder(commandBuffer, target: half)
            draw(world, rect: .init(0, 0, 1, 1), encoder: downsample)
            downsample.endEncoding()
            let steps = (0..<3).flatMap { index -> [Float] in
                let value = (1 + stage.blur * Float(index)) * 4 / 3 * Float(half.width) / 1280
                return [value, value]
            }
            composed = try blur(
                half,
                key: "world.post",
                passes: [(0, 1), (1, 0), (0, 1), (1, 0), (0, 1), (1, 0)],
                steps: steps,
                commandBuffer: commandBuffer
            )
        }
        let output = try encoder(
            commandBuffer,
            target: target,
            clear: .init(red: 0.025, green: 0.03, blue: 0.045, alpha: 1)
        )
        output.label = "Astray post processing and interface"
        let interfaceViewport = interfaceViewport(width: target.width, height: target.height)
        setViewport(viewport, target: target, encoder: output)
        do {
            draw(
                composed,
                rect: .init(0, 0, 1, 1),
                effects: .init(stage.isCameraBlurActive ? 0 : Float(stage.colorEffect), 0, 0, 0),
                encoder: output
            )
            if let movie {
                draw(movie, rect: .init(0, 0, 1, 1), uv: aspectFill(movie, aspect: backgroundAspect), encoder: output)
            }
            if player.dialogue.isVisible && !player.isDialogueHidden && !player.dialogue.isFullScreen {
                drawDialogueBackground(player.dialogue, encoder: output)
                setViewport(interfaceViewport, target: target, encoder: output)
                try drawDialogue(player.dialogue, encoder: output)
            }
            setViewport(interfaceViewport, target: target, encoder: output)
            try drawPlace(stage, encoder: output)
            setViewport(viewport, target: target, encoder: output)
            if stage.cover.w > 0 { draw(white, rect: .init(0, 0, 1, 1), color: stage.cover, encoder: output) }
            setViewport(interfaceViewport, target: target, encoder: output)
            try drawCaption(stage, encoder: output)
            if player.dialogue.isVisible && player.dialogue.isFullScreen {
                setViewport(viewport, target: target, encoder: output)
                drawFullScreenTextBackground(player.dialogue, encoder: output)
                setViewport(interfaceViewport, target: target, encoder: output)
                try drawFullScreenText(player.dialogue, encoder: output)
            }
            try drawChoices(stage, encoder: output)
            setViewport(viewport, target: target, encoder: output)
            if stage.isWipeVisible { try drawWipe(stage, encoder: output) }
        } catch { output.endEncoding(); throw error }
        output.endEncoding()
        if let drawable { commandBuffer.present(drawable) }
        commandBuffer.addCompletedHandler { [frameSlots] _ in frameSlots.release(slot) }
        submitted = true
        commandBuffer.commit()
        return commandBuffer
    }
    
    internal static func viewport(width: Int, height: Int, scalesToFill: Bool = false) -> MTLViewport {
        if scalesToFill {
            return .init(
                originX: 0,
                originY: 0,
                width: Double(width),
                height: Double(height),
                znear: 0,
                zfar: 1
            )
        }
        let scale = min(Double(width) / 1280, Double(height) / 720)
        return .init(
            originX: (Double(width) - 1280 * scale) / 2,
            originY: (Double(height) - 720 * scale) / 2,
            width: 1280 * scale,
            height: 720 * scale,
            znear: 0,
            zfar: 1
        )
    }
    
    // Keep character height and baseline stable when the display aspect ratio changes.
    internal func characterViewport(width: Int, height: Int) -> MTLViewport {
        guard scalesToFill else { return Self.viewport(width: width, height: height) }
        let stageWidth = Double(height) * 16 / 9
        return .init(
            originX: (Double(width) - stageWidth) / 2,
            originY: 0,
            width: stageWidth,
            height: Double(height),
            znear: 0,
            zfar: 1
        )
    }
    
    internal static func choiceRect(index: Int, count: Int, scale: Float = 1) -> SIMD4<Float> {
        let original = SIMD4<Float>((index == 0 ? 160 : 773.333333) / 1280, 328 / 720, 346.666667 / 1280, 64 / 720)
        return .init(
            0.5 + (original.x - 0.5) * scale,
            0.5 + (original.y - 0.5) * scale,
            original.z * scale,
            original.w * scale
        )
    }
    
    internal func interfaceViewport(width: Int, height: Int) -> MTLViewport {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard scalesToFill else { return Self.viewport(width: width, height: height) }
        let safeBounds = (interfaceBounds ?? bounds).intersection(bounds)
        guard !safeBounds.isNull, safeBounds.width > 0, safeBounds.height > 0 else {
            return Self.viewport(width: width, height: height, scalesToFill: true)
        }
        return .init(
            originX: safeBounds.minX,
            originY: safeBounds.minY,
            width: safeBounds.width,
            height: safeBounds.height,
            znear: 0,
            zfar: 1
        )
    }
    
    private func setViewport(
        _ viewport: MTLViewport,
        target: any MTLTexture,
        encoder: any MTLRenderCommandEncoder
    ) {
        encoder.setViewport(viewport)
        let left = max(0, Int(floor(viewport.originX)))
        let top = max(0, Int(floor(viewport.originY)))
        let right = min(target.width, Int(ceil(viewport.originX + viewport.width)))
        let bottom = min(target.height, Int(ceil(viewport.originY + viewport.height)))
        encoder.setScissorRect(.init(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top)))
        textScale = max(0.25, viewport.height / 720)
        textCanvasWidth = viewport.width / textScale
    }
    
    private func target(key: String, width: Int, height: Int) throws -> any MTLTexture {
        if let existing = targets[key], existing.width == width, existing.height == height { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw AstrayError.metalUnavailable }
        targets[key] = texture
        return texture
    }
    
    private func encoder(
        _ commandBuffer: any MTLCommandBuffer,
        target: any MTLTexture,
        clear: MTLClearColor = .init(red: 0, green: 0, blue: 0, alpha: 0)
    ) throws -> any MTLRenderCommandEncoder {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clear
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            throw AstrayError.renderingFailed("Unable to allocate a render graph encoder.")
        }
        encoder.setRenderPipelineState(pipeline)
        return encoder
    }
    
    private func blur(
        _ source: any MTLTexture,
        key: String,
        passes: [(Float, Float)],
        steps: [Float],
        character: Bool = false,
        commandBuffer: any MTLCommandBuffer
    ) throws -> any MTLTexture {
        var input = source
        for (index, direction) in passes.enumerated() {
            let name =
                index == passes.count - 1
                ? key + ".result" : (character ? "character.working.\(index % 2)" : key + ".working.\(index % 2)")
            let output = try target(key: name, width: source.width, height: source.height)
            let encoder = try encoder(commandBuffer, target: output)
            encoder.label = character ? "Cubism Gaussian blur pass \(index)" : "Scenario camera blur pass \(index)"
            encoder.setRenderPipelineState(blurPipeline)
            draw(
                input,
                rect: .init(0, 0, 1, 1),
                effects: .init(0, steps[index], 0, character ? 1 : 0),
                parameters: .init(direction.0, direction.1, 0, 0),
                encoder: encoder
            )
            encoder.endEncoding()
            input = output
        }
        return input
    }
    
    private func drawEffects(
        layer: EffectLayer,
        stage: StageState,
        backgroundOnly: Bool = false,
        encoder: any MTLRenderCommandEncoder
    ) throws {
        let zoom = stage.camera.z * (backgroundOnly ? stage.dolly.x : 1)
        var transform = SIMD4(-stage.camera.x + stage.shake.x, -stage.camera.y + stage.shake.y, zoom, 0)
        for (name, mesh) in effects.meshes(layer: layer, backgroundOnly: backgroundOnly) {
            let key = name + "/" + mesh.texture
            let source: any MTLTexture
            if let cached = prefabTextures[key] {
                source = cached
            } else if let data = player.prefabAssets[name]?.textures[mesh.texture] {
                source = try BitmapTexture.make(data: data, device: device)
                prefabTextures[key] = source
            } else {
                source = white
            }
            var vertices = mesh.vertices
            var textureTransform = mesh.textureTransform
            if textureTransform.x < 0 {
                for index in vertices.indices {
                    vertices[index].uv = .init(
                        vertices[index].uv.x / Float(source.width),
                        1 + vertices[index].uv.y / Float(source.height)
                    )
                }
                textureTransform = .init(1, 1, 0, 0)
            }
            guard !vertices.isEmpty, !mesh.indices.isEmpty, let resources = frameResources
            else { continue }
            let vertexBuffer = try vertices.withUnsafeBytes { try resources.upload($0.baseAddress!, count: $0.count) }
            let indexBuffer = try mesh.indices.withUnsafeBytes {
                try resources.upload($0.baseAddress!, count: $0.count)
            }
            encoder.setRenderPipelineState(effectPipelines[mesh.blend] ?? effectPipelines[.alpha]!)
            encoder.setVertexBuffer(vertexBuffer.buffer, offset: vertexBuffer.offset, index: 0)
            encoder.setVertexBytes(&transform, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            encoder.setVertexBytes(&textureTransform, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            encoder.setFragmentTexture(source, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: mesh.indices.count,
                indexType: .uint32,
                indexBuffer: indexBuffer.buffer,
                indexBufferOffset: indexBuffer.offset
            )
        }
        encoder.setRenderPipelineState(pipeline)
    }
    
    private func texture(for request: AssetRequest) throws -> (any MTLTexture)? {
        if let cached = textures[request] { return cached }
        guard !failedTextures.contains(request), let data = player.assets[request] else { return nil }
        do {
            let texture = try BitmapTexture.make(data: data, device: device)
            textures[request] = texture
            return texture
        } catch {
            failedTextures.insert(request)
            player.onEvent?(.warning(.renderingFailed("Image \(request): \(error.localizedDescription)")))
            return nil
        }
    }
    
    private func draw(
        _ texture: any MTLTexture,
        rect: SIMD4<Float>,
        uv: SIMD4<Float> = .init(0, 0, 1, 1),
        color: SIMD4<Float> = .one,
        effects: SIMD4<Float> = .zero,
        parameters: SIMD4<Float> = .zero,
        noise: (any MTLTexture)? = nil,
        encoder: any MTLRenderCommandEncoder
    ) {
        var uniforms = QuadUniforms(rect: rect, uvRect: uv, color: color, effects: effects, parameters: parameters)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(noise ?? white, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
    
    private func worldRect(_ rect: SIMD4<Float>, stage: StageState) -> SIMD4<Float> {
        .init(
            (rect.x - 0.5) * stage.camera.z + 0.5 - stage.camera.x + stage.shake.x,
            (rect.y - 0.5) * stage.camera.z + 0.5 - stage.camera.y + stage.shake.y,
            rect.z * stage.camera.z,
            rect.w * stage.camera.z
        )
    }
    
    private func aspectFill(_ texture: any MTLTexture, aspect: Float) -> SIMD4<Float> {
        let ratio = Float(texture.width) / Float(texture.height)
        if ratio > aspect { let width = aspect / ratio; return .init((1 - width) / 2, 0, width, 1) }
        let height = ratio / aspect
        return .init(0, (1 - height) / 2, 1, height)
    }
    
    private struct QuadUniforms {
        internal var rect: SIMD4<Float>
        internal var uvRect: SIMD4<Float>
        internal var color: SIMD4<Float>
        internal var effects: SIMD4<Float>
        internal var parameters: SIMD4<Float>
    }
    
    private final class Hologram {
        internal let kind: String
        internal var time: Double = 0
        internal var line: Float = 0.86
        internal var alpha: Float = 0.7764706
        private var timer: Double = .random(in: 0.05...0.25)
        
        internal init(kind: String) { self.kind = kind }
        
        internal func update(_ delta: Double) {
            guard delta > 0 else { return }
            time += delta
            if Double.random(in: 0..<10000) < 150 || timer <= 0 {
                line = .random(in: 0.6...0.8)
                alpha = .random(in: 0.85...0.9)
                timer = .random(in: 0...0.5)
            }
            timer -= delta
        }
    }
}

internal final class ShaderBundleToken: NSObject {}

extension StoryRenderer {
    private func drawText(
        _ string: String,
        rect: SIMD4<Float>,
        size: Double,
        centered: Bool = false,
        bold: Bool = false,
        tint: SIMD4<Float> = .one,
        opacity: Float = 1,
        outline: Bool = false,
        alphas: [Float] = [],
        lineHeight: Double? = nil,
        singleLine: Bool = false,
        letterSpacing: Double = 0,
        runs: [TextRun] = [],
        usesStyleColor: Bool = true,
        encoder: any MTLRenderCommandEncoder
    ) throws {
        if let texture = try text.texture(
            text: string,
            width: max(1, Int(Double(rect.z) * textCanvasWidth * textScale)),
            height: max(1, Int(Double(rect.w) * 720 * textScale)),
            size: size * textScale,
            centered: centered,
            bold: bold,
            color: tint,
            outline: outline,
            alphas: alphas,
            lineHeight: lineHeight.map { $0 * textScale },
            singleLine: singleLine,
            letterSpacing: letterSpacing * textScale,
            runs: runs,
            usesStyleColor: usesStyleColor
        ) {
            draw(texture, rect: rect, color: .init(1, 1, 1, opacity), encoder: encoder)
        }
    }
    
    private func drawDialogueBackground(_ dialogue: DialogueState, encoder: any MTLRenderCommandEncoder) {
        draw(
            white,
            rect: .init(0, 0, 1, 1),
            color: .init(0, 0, 34 / 255, dialogue.opacity),
            effects: .init(9, 0, 0, 0),
            encoder: encoder
        )
    }
    
    private func drawDialogue(_ dialogue: DialogueState, encoder: any MTLRenderCommandEncoder) throws {
        let opacity = dialogue.opacity
        if !dialogue.speaker.isEmpty {
            draw(
                white,
                rect: .init(140 / 1280, 549.333333 / 720, 480 / 1280, 10.666667 / 720),
                color: .init(1, 1, 1, 0.6 * opacity),
                effects: .init(13, 0, 0, 0),
                parameters: .init(45, 0, 0, 0),
                encoder: encoder
            )
            let rect = SIMD4<Float>(
                153.333333 / 1280 + dialogue.shake.x,
                512.666667 / 720 + dialogue.shake.y,
                395.333333 / 1280,
                50 / 720
            )
            try drawText(
                dialogue.speaker,
                rect: rect,
                size: 29.333333,
                bold: true,
                tint: .init(68 / 255, 68 / 255, 102 / 255, 1),
                opacity: 0.6 * opacity,
                outline: true,
                singleLine: true,
                encoder: encoder
            )
            try drawText(
                dialogue.speaker,
                rect: rect,
                size: 29.333333,
                bold: true,
                tint: .init(235 / 255, 235 / 255, 242 / 255, 1),
                opacity: opacity,
                singleLine: true,
                encoder: encoder
            )
        }
        let body = SIMD4<Float>(166.7 / 1280 + dialogue.shake.x, 572 / 720 + dialogue.shake.y, 912.2 / 1280, 130 / 720)
        try drawText(
            dialogue.displayedText,
            rect: body,
            size: 26.666667,
            tint: .init(68 / 255, 68 / 255, 102 / 255, 1),
            opacity: 0.6 * opacity,
            outline: true,
            lineHeight: 32,
            encoder: encoder
        )
        try drawText(
            dialogue.displayedText,
            rect: body,
            size: 26.666667,
            opacity: opacity,
            lineHeight: 32,
            encoder: encoder
        )
        if !dialogue.isTyping && !player.isAutomatic && !player.isFastForwarding {
            let bob = Float((1 - cos(player.visualTime * .pi * 2 / 1.1)) * 2.5)
            if let note = try texture(for: .ui("serif_note.png")) {
                draw(
                    note,
                    rect: .init(
                        1044.8 / 1280,
                        (720 - 16.87 - 29.333333 + bob) / 720,
                        33.333333 / 1280,
                        29.333333 / 720
                    ),
                    color: .init(1, 1, 1, 0.95 * opacity),
                    encoder: encoder
                )
            } else {
                if continuationMark == nil { continuationMark = try text.continuationMark() }
                draw(
                    continuationMark!,
                    rect: .init(
                        1044.8 / 1280,
                        (720 - 16.87 - 29.333333 + bob) / 720,
                        33.333333 / 1280,
                        29.333333 / 720
                    ),
                    color: .init(1, 1, 1, 0.95 * opacity),
                    encoder: encoder
                )
            }
        }
        if player.isAutomatic || player.isFastForwarding {
            let rect = SIMD4<Float>(
                (1280 - 42.666667 - 133.333333) / 1280,
                (720 - 16 - 32) / 720,
                133.333333 / 1280,
                32 / 720
            )
            draw(
                white,
                rect: rect,
                color: .init(68 / 255, 68 / 255, 102 / 255, 0.8 * opacity),
                effects: .init(8, 0, 0, 0),
                parameters: .init(133.333333 / 32, 13.333333 / 32, 0, 0),
                encoder: encoder
            )
            let phase = player.visualTime.truncatingRemainder(dividingBy: 1)
            let blink = Float(phase <= 0.503 ? 1 : phase >= 0.508 ? 0.005 : 1 - (phase - 0.503) / 0.005 * 0.995)
            let arrows = player.isFastForwarding ? [21.6, 21.6 + 29.6 * 0.54] : [26.4]
            for x in arrows {
                draw(
                    white,
                    rect: .init(
                        rect.x + Float(x) / 1280,
                        rect.y + 6.333333 / 720,
                        Float(player.isFastForwarding ? 29.6 * 0.46 : 15) / 1280,
                        19.333333 / 720
                    ),
                    color: .init(1, 1, 1, blink * opacity),
                    effects: .init(12, 0, 0, 0),
                    encoder: encoder
                )
            }
            try drawText(
                player.isFastForwarding ? "SKIP" : "AUTO",
                rect: .init(
                    rect.x + 58.37 / 1280,
                    rect.y + 2 / 720,
                    Float(player.isFastForwarding ? 55.25 : 49.21) / 1280,
                    30 / 720
                ),
                size: 21.333333,
                centered: true,
                bold: true,
                opacity: opacity,
                singleLine: true,
                letterSpacing: 21.333333 * (player.isFastForwarding ? 0.02 : -0.04),
                encoder: encoder
            )
        }
    }
    
    private func drawPlace(_ stage: StageState, encoder: any MTLRenderCommandEncoder) throws {
        guard !stage.place.isEmpty else { return }
        draw(
            white,
            rect: .init(stage.placeOffset, 20.666667 / 720, 386.666667 / 1280, 42.666667 / 720),
            color: .init(68 / 255, 68 / 255, 102 / 255, 0.8),
            encoder: encoder
        )
        draw(
            white,
            rect: .init(stage.placeOffset + 386.666667 / 1280, 20.666667 / 720, 101.333333 / 1280, 42.666667 / 720),
            color: .init(68 / 255, 68 / 255, 102 / 255, 0.8),
            effects: .init(10, 0, 0, 0),
            encoder: encoder
        )
        let size =
            text.fittingSize(
                text: stage.place,
                width: 346.666667 / 1280 * textCanvasWidth * textScale,
                minimum: 12 * textScale,
                maximum: 26.666667 * textScale,
                step: 2 / 3 * textScale
            ) / textScale
        try drawText(
            stage.place,
            rect: .init(stage.placeOffset + 26.666667 / 1280, 24 / 720, 346.666667 / 1280, 40 / 720),
            size: size,
            singleLine: true,
            encoder: encoder
        )
    }
    
    private func drawCaption(_ stage: StageState, encoder: any MTLRenderCommandEncoder) throws {
        guard !stage.caption.isEmpty else { return }
        let transform = stage.captionTransform
        let width: Float = 693.333333 / 1280
        let left: Float = 0.5 - width / 2
        let pivot = left + width * 0.02
        draw(
            white,
            rect: .init(pivot + (left - pivot) * transform.x, (360 - 40) / 720, width * transform.x, 80 / 720),
            color: .init(68 / 255, 68 / 255, 102 / 255, transform.y * 0.8),
            effects: .init(6, 0, 0, 0),
            encoder: encoder
        )
        try drawText(
            stage.caption,
            rect: .init(left + transform.w, (360 - 23) / 720, width, 80 / 720),
            size: 29.333333,
            centered: true,
            opacity: transform.z,
            singleLine: true,
            encoder: encoder
        )
    }
    
    private func drawFullScreenTextBackground(_ dialogue: DialogueState, encoder: any MTLRenderCommandEncoder) {
        draw(
            white,
            rect: .init(0, 0, 1, 1),
            color: .init(0, 0, 0, dialogue.fullScreenBackgroundOpacity),
            encoder: encoder
        )
        draw(white, rect: .init(0, 0, 1, dialogue.cinemaBarHeight), color: .init(0, 0, 0, 1), encoder: encoder)
        draw(
            white,
            rect: .init(0, 1 - dialogue.cinemaBarHeight, 1, dialogue.cinemaBarHeight),
            color: .init(0, 0, 0, 1),
            encoder: encoder
        )
    }
    
    private func drawFullScreenText(_ dialogue: DialogueState, encoder: any MTLRenderCommandEncoder) throws {
        let lines = dialogue.body.components(separatedBy: "\n").count
        let y = Float(160 + max(0, (400 - Double(lines) * 37.333333 * 1.68) / 2)) / 720
        let rect = SIMD4<Float>(186.666667 / 1280, y, (1280 - 186.666667) / 1280, 400 / 720)
        try drawText(
            dialogue.body,
            rect: rect + .init(0, 4.333333 / 720, 0, 0),
            size: 37.333333,
            tint: .init(0, 0, 0, 1),
            opacity: dialogue.opacity,
            alphas: dialogue.characterAlphas,
            lineHeight: 37.333333 * 1.68,
            runs: dialogue.textRuns,
            usesStyleColor: false,
            encoder: encoder
        )
        try drawText(
            dialogue.body,
            rect: rect,
            size: 37.333333,
            opacity: dialogue.opacity,
            alphas: dialogue.characterAlphas,
            lineHeight: 37.333333 * 1.68,
            runs: dialogue.textRuns,
            encoder: encoder
        )
    }
    
    private func drawChoices(_ stage: StageState, encoder: any MTLRenderCommandEncoder) throws {
        guard !stage.choices.isEmpty, stage.choiceScale > 0 else { return }
        for (index, choice) in stage.choices.enumerated() {
            let scale = stage.choiceScale
            let rect = Self.choiceRect(index: index, count: stage.choices.count, scale: scale)
            if let pill = try texture(for: .ui("scenario/btn_round_h80_wh.png")) {
                let side = 34 / 1280.0 * scale
                let slice: Float = min(0.5, 51 / Float(pill.width))
                draw(pill, rect: .init(rect.x, rect.y, side, rect.w), uv: .init(0, 0, slice, 1), encoder: encoder)
                draw(
                    pill,
                    rect: .init(rect.x + side, rect.y, max(0, rect.z - side * 2), rect.w),
                    uv: .init(0.5, 0, 0.0001, 1),
                    encoder: encoder
                )
                draw(
                    pill,
                    rect: .init(rect.x + rect.z - side, rect.y, side, rect.w),
                    uv: .init(1 - slice, 0, slice, 1),
                    encoder: encoder
                )
            } else {
                draw(
                    white,
                    rect: rect,
                    effects: .init(8, 0, 0, 0),
                    parameters: .init(rect.z * 1280 / max(1, rect.w * 720), 0, 0, 0),
                    encoder: encoder
                )
            }
            try drawText(
                choice,
                rect: .init(
                    rect.x + 10 / 1280 * scale,
                    rect.y + 15 / 720 * scale,
                    rect.z - 20 / 1280 * scale,
                    rect.w - 12 / 720 * scale
                ),
                size: 21.333333 * Double(scale),
                centered: true,
                bold: true,
                tint: .init(68 / 255, 68 / 255, 102 / 255, 1),
                singleLine: true,
                encoder: encoder
            )
        }
    }
    
    private func drawWipe(_ stage: StageState, encoder: any MTLRenderCommandEncoder) throws {
        let rect = SIMD4<Float>(
            -32 / 1920 + stage.wipeOffset.x,
            -32 / 1080 + stage.wipeOffset.y,
            (1920 + 64) / 1920.0,
            (1080 + 64) / 1080.0
        )
        draw(white, rect: rect, color: .init(0, 0, 0, 1), encoder: encoder)
        let horizontal = try texture(for: .ui("scenario/tex_transition_left.png"))
        let vertical = try texture(for: .ui("scenario/tex_transition_top.png"))
        let width: Float = 512 / 1920.0
        let height: Float = 512 / 1080.0
        for right in [false, true] {
            let strip = SIMD4<Float>(right ? rect.x + rect.z : rect.x - width, rect.y, width, rect.w)
            if let horizontal {
                draw(
                    horizontal,
                    rect: strip,
                    uv: .init(right ? 1 : 0, 0, right ? -1 : 1, strip.w * 1080 / 512),
                    effects: .init(7, 0, 0, 0),
                    encoder: encoder
                )
            } else {
                draw(
                    white,
                    rect: strip,
                    color: .init(0, 0, 0, 1),
                    effects: .init(10, 0, 0, 0),
                    parameters: .init(right ? 0 : 1, 0, 0, 0),
                    encoder: encoder
                )
            }
        }
        for bottom in [false, true] {
            let strip = SIMD4<Float>(
                rect.x - width,
                bottom ? rect.y + rect.w : rect.y - height,
                rect.z + width * 2,
                height
            )
            if let vertical {
                draw(
                    vertical,
                    rect: strip,
                    uv: .init(0, bottom ? 1 : 0, strip.z * 1920 / 512, bottom ? -1 : 1),
                    effects: .init(7, 0, 0, 0),
                    encoder: encoder
                )
            } else {
                draw(
                    white,
                    rect: strip,
                    color: .init(0, 0, 0, 1),
                    effects: .init(11, 0, 0, 0),
                    parameters: .init(bottom ? 0 : 1, 0, 0, 0),
                    encoder: encoder
                )
            }
        }
    }
}
