internal import simd
internal import Foundation

internal final class PrefabEffect {
    internal let document: EffectValue
    internal var random: EffectRandom
    internal var emitters: [Int: ParticleEmitter] = [:]
    internal var state: State = .playing
    internal var origin = SIMD3<Double>.zero
    internal var originScale: Double = 1
    internal var pivotY: Double = 0.5
    internal var isVisible = true
    private var nodes: [Node]
    private var animators: [Animator] = []
    private var stopClipRemaining: Double = 0
    
    internal init(document: EffectValue, seed: UInt64 = .random(in: 1...UInt64.max)) throws {
        self.document = document
        random = .init(seed: seed)
        let data = document["nodes"].array
        nodes = data.map(Node.init)
        var visited: Set<Int> = []
        func validate(_ index: Int, ancestors: Set<Int>) throws {
            guard data.indices.contains(index), !ancestors.contains(index), !visited.contains(index) else {
                throw AstrayError.invalidScenario("Invalid or cyclic prefab hierarchy.")
            }
            visited.insert(index)
            for child in data[index]["children"].array {
                try validate(Int(child.number(-1)), ancestors: ancestors.union([index]))
            }
        }
        for root in document["roots"].array { try validate(Int(root.number(-1)), ancestors: []) }
        for (index, node) in data.enumerated() {
            if !node["ps"].isNull { emitters[index] = .init(node: index, effect: self) }
            if !node["animator"].isNull {
                animators.append(.init(node: index, data: node["animator"], state: node["animator"]["default"].string))
            }
        }
        for emitter in emitters.values {
            for sub in emitter.system["SubModule"]["subEmitters"].array {
                emitters[Int(sub["emitter"].number(-1))]?.isSubEmitter = true
            }
        }
    }
    
    internal func update(_ delta: Double) {
        guard state != .dead else { return }
        animate(delta)
        layout()
        for index in nodes.indices {
            let on = effectiveActive(index)
            if let emitter = emitters[index], on != nodes[index].wasActive {
                if on && state == .playing && emitter.system["playOnAwake"].number(1) != 0 && !emitter.isSubEmitter {
                    emitter.play()
                } else if !on {
                    emitter.clear()
                }
            }
            nodes[index].wasActive = on
        }
        for (index, emitter) in emitters.sorted(by: { $0.key < $1.key }) {
            emitter.world = nodes[index].world
            emitter.rotation = EffectMath.rotationOnly(nodes[index].world)
            emitter.scale = nodes[index].scale
            if nodes[index].wasActive || emitter.isSubEmitter { emitter.step(delta) }
        }
        if state == .stopping {
            stopClipRemaining -= delta
            if stopClipRemaining <= 0 && emitters.values.allSatisfy({ $0.particles.isEmpty }) { state = .dead }
        }
    }
    
    internal func settle() {
        var length: Double = 0
        func top(_ value: EffectValue) -> Double { max(value["s"].number(), value["n"].number()) }
        for emitter in emitters.values {
            let run =
                top(emitter.system["startDelay"]) + emitter.duration
                + top(emitter.system["InitialModule"]["startLifetime"])
            length = max(length, run / max(1e-6, emitter.system["simulationSpeed"].number(1)))
        }
        for clip in document["clips"].object.values { length += clip["len"].number() }
        var time: Double = 0
        while time < min(length, 10) && state != .dead { update(1 / 30); time += 1 / 30 }
    }
    
    internal func stop() {
        guard state == .playing else { return }
        state = .stopping
        for emitter in emitters.values { emitter.stop() }
        for animator in animators {
            if let stop = animator.data["states"].object.first(where: { $0.value["name"].string == "Stop" }) {
                animator.state = stop.key
                animator.time = 0
                stopClipRemaining = max(stopClipRemaining, document["clips"][stop.value["clip"].string]["len"].number())
            } else {
                animator.state = ""
            }
        }
    }
    
    internal func forceStop() { state = .dead }
    
    internal func meshes() -> [EffectMesh] {
        guard state != .dead else { return [] }
        var result: [EffectMesh] = []
        for index in nodes.indices {
            if let mesh = emitters[index]?.mesh(
                visible: isVisible && (nodes[index].wasActive || emitters[index]?.isSubEmitter == true)
            ) {
                result.append(mesh)
            }
            if isVisible && effectiveActive(index), let sprite = sprite(node: index) { result.append(sprite) }
        }
        return result.sorted {
            $0.layer != $1.layer
                ? $0.layer < $1.layer : ($0.order != $1.order ? $0.order < $1.order : $0.sequence < $1.sequence)
        }
    }
    
    internal func ordering(node index: Int, particle: Bool) -> (layer: EffectLayer, order: Int) {
        let node = document["nodes"][index]
        var layer = -348333445
        var order = 230
        if particle {
            layer = Int(node["psr"]["m_SortingLayerID"].number(-348333445))
            order = Int(node["psr"]["m_SortingOrder"].number())
        } else if !node["sprite"].isNull {
            order = Int(node["sprite"]["order"].number())
        } else {
            var parent = index
            while nodes.indices.contains(parent) {
                let data = document["nodes"][parent]
                if !data["canvas"].isNull {
                    layer = Int(data["canvas"]["m_SortingLayerID"].number(-348333445))
                    order = Int(data["canvas"]["m_SortingOrder"].number(230))
                    break
                }
                parent = Int(data["parent"].number(-1))
            }
        }
        return (layer == 0 ? .bottom : (layer == 109347411 ? .top : (order < 220 ? .back : .front)), order)
    }
    
    private func effectiveActive(_ index: Int) -> Bool {
        var current = index
        while nodes.indices.contains(current) {
            if !nodes[current].active { return false }
            current = Int(document["nodes"][current]["parent"].number(-1))
        }
        return true
    }
    
    private func layout() {
        func visit(_ index: Int, parent: simd_double4x4, parentSize: SIMD2<Double>, parentPivot: SIMD2<Double>) {
            let node = nodes[index]
            let rect = node.rect
            var position = node.position
            if !rect.isNull {
                let minimum = -parentPivot * parentSize
                let anchorMin = minimum + SIMD2(rect["amin"][0].number(), rect["amin"][1].number()) * parentSize
                let anchorMax = minimum + SIMD2(rect["amax"][0].number(), rect["amax"][1].number()) * parentSize
                node.rectSize = anchorMax - anchorMin + SIMD2(rect["size"][0].number(), rect["size"][1].number())
                let local =
                    anchorMin + (anchorMax - anchorMin) * SIMD2(rect["pivot"][0].number(), rect["pivot"][1].number())
                    + SIMD2(rect["apos"][0].number(), rect["apos"][1].number())
                position.x = local.x
                position.y = local.y
            }
            node.world = parent * EffectMath.transform(position: position, rotation: node.rotation, scale: node.scale)
            for child in document["nodes"][index]["children"].array {
                let size = SIMD2(
                    node.rectSize.x == 0 ? parentSize.x : node.rectSize.x,
                    node.rectSize.y == 0 ? parentSize.y : node.rectSize.y
                )
                let pivot =
                    rect.isNull
                    ? SIMD2<Double>(repeating: 0.5) : SIMD2(rect["pivot"][0].number(), rect["pivot"][1].number())
                visit(Int(child.number()), parent: node.world, parentSize: size, parentPivot: pivot)
            }
        }
        let transform = EffectMath.transform(
            position: origin,
            rotation: .init(ix: 0, iy: 0, iz: 0, r: 1),
            scale: .init(originScale, originScale, 1)
        )
        for root in document["roots"].array {
            visit(Int(root.number()), parent: transform, parentSize: .init(1920, 1080), parentPivot: .init(0.5, pivotY))
        }
    }
    
    private func sprite(node index: Int) -> EffectMesh? {
        let data = document["nodes"][index]
        let isImage = !data["image"].isNull
        let metadata = isImage ? data["image"] : data["sprite"]
        let sprite = document["sprites"][metadata["sprite"].string]
        guard !sprite["tex"].string.isEmpty else { return nil }
        let node = nodes[index]
        let world = node.world
        let sx = hypot(world[0].x, world[0].y)
        let sy = hypot(world[1].x, world[1].y)
        let width: Double
        let height: Double
        if isImage && !node.rect.isNull {
            width = node.rectSize.x * sx * 2 / 3
            height = node.rectSize.y * sy * 2 / 3
        } else {
            width =
                sprite["rect"][2].number() / max(1e-6, sprite["ppu"].number(100)) * sx * 2 / 3
                * (metadata["flip"][0].isEnabled ? -1 : 1)
            height = sprite["rect"][3].number() / max(1e-6, sprite["ppu"].number(100)) * sy * 2 / 3
        }
        let center = SIMD2(640 + world[3].x * 2 / 3, 360 - world[3].y * 2 / 3)
        let angle = -atan2(world[0].y, world[0].x)
        let color = SIMD4<Float>(
            Float(min(1, max(0, node.color.x))),
            Float(min(1, max(0, node.color.y))),
            Float(min(1, max(0, node.color.z))),
            Float(min(1, max(0, node.color.w)))
        )
        let textureSize = sprite["textureSize"].vector3()
        let rect = sprite["rect"].vector4(.zero)
        // Sprite UVs remain in source pixels until the texture size is known by the renderer.
        let coordinates: [SIMD2<Double>] = [
            .init(rect.x, -rect.y - rect.w), .init(rect.x + rect.z, -rect.y - rect.w), .init(rect.x + rect.z, -rect.y),
            .init(rect.x, -rect.y),
        ]
        let corners: [SIMD2<Double>] = [
            .init(-width / 2, -height / 2), .init(width / 2, -height / 2), .init(width / 2, height / 2),
            .init(-width / 2, height / 2),
        ]
        let material = document["materials"][(isImage ? metadata["material"] : metadata["materials"][0]).string]
        let blend = EffectBlend.forShader(material["shader"].string)
        let vertices = corners.enumerated().map { corner, position -> EffectVertex in
            let rotated =
                SIMD2(
                    position.x * cos(angle) - position.y * sin(angle),
                    position.x * sin(angle) + position.y * cos(angle)
                ) + center
            return .init(
                position: .init(rotated),
                uv: .init(coordinates[corner]),
                color: color,
                keep: blend == .additive ? 0 : 1
            )
        }
        _ = textureSize
        let order = ordering(node: index, particle: false)
        return .init(
            vertices: vertices,
            indices: [0, 1, 2, 0, 2, 3],
            texture: sprite["tex"].string,
            blend: blend == .multiply ? .multiply : .alpha,
            layer: order.layer,
            order: order.order,
            sequence: index * 2 + 1,
            textureTransform: .init(-1, -1, 0, 0)
        )
    }
    
    private func animate(_ delta: Double) {
        for animator in animators {
            let state = animator.data["states"][animator.state]
            guard !state.isNull else { continue }
            let clip = document["clips"][state["clip"].string]
            animator.time += delta * state["speed"].number(1)
            let length = clip["len"].number()
            for transition in state["trans"].array {
                if transition["exit"].isEnabled && transition["conds"].array.isEmpty && length > 0
                    && animator.time >= transition["exitTime"].number() * length
                {
                    animator.state = transition["to"].string
                    animator.time = 0
                    break
                }
            }
            let time =
                clip["loop"].isEnabled && length > 0
                ? animator.time.truncatingRemainder(dividingBy: length) : min(animator.time, length)
            applyClip(clip, from: animator.node, time: time)
        }
    }
    
    private func applyClip(_ clip: EffectValue, from index: Int, time: Double) {
        for curve in clip["curves"].array {
            var index = index
            for part in curve["path"].string.split(separator: "/") {
                index =
                    document["nodes"][index]["children"].array.map { Int($0.number(-1)) }.first {
                        document["nodes"][$0]["name"].string == part
                    } ?? -1
                if index < 0 { break }
            }
            guard nodes.indices.contains(index) else { continue }
            let node = nodes[index]
            let kind = curve["kind"].string
            if kind == "float" {
                let value = EffectCurves.evaluate(curve["curve"], at: time)
                let attribute = curve["attr"].string
                let axis = attribute.last.flatMap { "xyzw".firstIndex(of: $0)?.utf16Offset(in: "xyzw") } ?? 0
                if attribute == "m_IsActive" {
                    node.active = value > 0.5
                } else if attribute.hasPrefix("script:m_Color.") || attribute.hasPrefix("m_Color.")
                    || attribute.hasPrefix("material._Color.")
                {
                    if let char = attribute.last, let index = "rgba".firstIndex(of: char) {
                        node.color[index.utf16Offset(in: "rgba")] = value
                    }
                } else if attribute.hasPrefix("m_AnchoredPosition.") {
                    node.rect["apos"][axis] = .number(value)
                } else if attribute.hasPrefix("m_AnchorMax.") {
                    node.rect["amax"][axis] = .number(value)
                } else if attribute.hasPrefix("m_AnchorMin.") {
                    node.rect["amin"][axis] = .number(value)
                } else if attribute.hasPrefix("m_SizeDelta.") {
                    node.rect["size"][axis] = .number(value)
                } else if attribute.hasPrefix("m_LocalPosition."), axis < 3 {
                    node.position[axis] = value
                } else if attribute.hasPrefix("m_LocalScale."), axis < 3 {
                    node.scale[axis] = value
                } else if attribute == "looping" {
                    emitters[index]?.system["looping"] = .bool(value > 0.5)
                } else if attribute.hasPrefix("material._MainTex_ST.") {
                    emitters[index]?.textureTransform[axis] = value
                }
            } else if ["position", "scale", "euler"].contains(kind) {
                let value = EffectCurves.vector(curve["keys"].array, at: time)
                switch kind {
                case "position":
                    if node.rect.isNull {
                        node.position = value
                    } else {
                        node.rect["apos"][0] = .number(value.x); node.rect["apos"][1] = .number(value.y)
                    }
                case "scale": node.scale = value
                default: node.rotation = EffectMath.quaternion(value)
                }
            }
        }
    }
    
    internal enum State { case playing, stopping, dead }
    
    private final class Node {
        internal var active: Bool
        internal var position: SIMD3<Double>
        internal var rotation: simd_quatd
        internal var scale: SIMD3<Double>
        internal var rect: EffectValue
        internal var color: SIMD4<Double>
        internal var world = matrix_identity_double4x4
        internal var rectSize = SIMD2<Double>.zero
        internal var wasActive = false
        
        internal init(_ node: EffectValue) {
            active = node["active"].isEnabled
            position = node["pos"].vector3()
            let rotation = node["rot"].vector4(.init(0, 0, 0, 1))
            self.rotation = .init(vector: rotation)
            scale = node["scale"].vector3(.one)
            rect = node["rect"]
            color = (!node["image"].isNull ? node["image"]["color"] : node["sprite"]["color"]).vector4()
        }
    }
    
    private final class Animator {
        internal let node: Int
        internal let data: EffectValue
        internal var state: String
        internal var time: Double = 0
        
        internal init(node: Int, data: EffectValue, state: String) {
            self.node = node
            self.data = data
            self.state = state
        }
    }
}
