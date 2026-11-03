internal import simd
internal import Foundation

internal enum EffectLayer: Int, Comparable {
    case bottom, back, front, top
    internal static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

internal enum EffectBlend: Int {
    case alpha, additive, multiply
    
    internal static func forShader(_ shader: String) -> Self {
        if shader.contains("Multiply") { return .multiply }
        if shader.contains("Add") { return .additive }
        return .alpha
    }
}

internal struct EffectVertex {
    internal var position: SIMD2<Float>
    internal var uv: SIMD2<Float>
    internal var color: SIMD4<Float>
    internal var keep: Float
}

internal struct EffectMesh {
    internal var vertices: [EffectVertex]
    internal var indices: [UInt32]
    internal let texture: String
    internal let blend: EffectBlend
    internal let layer: EffectLayer
    internal let order: Int
    internal let sequence: Int
    internal let textureTransform: SIMD4<Float>
}

extension ParticleEmitter {
    internal func mesh(visible: Bool) -> EffectMesh? {
        guard visible, !particles.isEmpty else { return nil }
        let node = effect.document["nodes"][nodeIndex]
        let renderer = node["psr"]
        let material = effect.document["materials"][renderer["materials"][0].string]
        let shader = material["shader"].string
        let blend = EffectBlend.forShader(shader)
        let addAlpha = shader.contains("Additive+AlphaBlend")
        let customStream =
            renderer["m_UseCustomVertexStreams"].isEnabled && renderer["m_VertexStreams"].string.contains("1f")
        let pivot = renderer["pivot"].vector3()
        let minimum = renderer["m_MinParticleSize"].number() * 720
        let maximum = renderer["m_MaxParticleSize"].number(0.5) * 1440
        let uv = system["UVModule"]
        let tilesX = max(1, Int(uv["tilesX"].number(1)))
        let tilesY = max(1, Int(uv["tilesY"].number(1)))
        var vertices: [EffectVertex] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity(particles.count * 4)
        indices.reserveCapacity(particles.count * 6)
        for particle in particles {
            let age = particle.age / particle.lifetime
            let position = isWorldSpace ? particle.position : toReference(particle.position)
            let center = SIMD2(640 + position.x * 2 / 3, 360 - position.y * 2 / 3)
            var size = SIMD2(particle.size.x, particle.size.y)
            let sizeModule = system["SizeModule"]
            if sizeModule["enabled"].isEnabled {
                let value = EffectCurves.minMax(sizeModule["curve"], at: age, random: particle.randoms[5])
                size.x *= value
                size.y *=
                    sizeModule["separateAxes"].isEnabled
                    ? EffectCurves.minMax(sizeModule["y"], at: age, random: particle.randoms[5]) : value
            }
            let bySpeed = system["SizeBySpeedModule"]
            if bySpeed["enabled"].isEnabled {
                let speed = simd_length(particle.velocity) / (isWorldSpace ? unit : 1)
                let range = bySpeed["range"]
                let span = range["y"].number(1) - range["x"].number()
                let fraction = min(1, max(0, (speed - range["x"].number()) / (span == 0 ? 1 : span)))
                size *= EffectCurves.minMax(bySpeed["curve"], at: fraction, random: particle.randoms[5])
            }
            size *= SIMD2(abs(scale.x), abs(scale.y)) * unit * 2 / 3
            size.x = min(max(size.x, minimum), maximum == 0 ? size.x : maximum)
            size.y = min(max(size.y, minimum), maximum == 0 ? size.y : maximum)
            var color = particle.color
            if system["ColorModule"]["enabled"].isEnabled {
                color *= EffectCurves.minMaxGradient(
                    system["ColorModule"]["gradient"],
                    at: age,
                    random: particle.randoms[6]
                )
            }
            var uvRect = SIMD4<Double>(0, 0, 1, 1)
            if uv["enabled"].isEnabled && (tilesX > 1 || tilesY > 1) {
                let singleRow = uv["animationType"].number() == 1
                let count = singleRow ? tilesX : tilesX * tilesY
                let normalized = (age * uv["cycles"].number(1)).truncatingRemainder(dividingBy: 1)
                let fraction =
                    EffectCurves.minMax(uv["frameOverTime"], at: normalized, random: particle.randoms[7])
                    + EffectCurves.minMax(uv["startFrame"], at: 0, random: particle.randoms[7])
                let frame = ((Int(floor(fraction * Double(count))) % count) + count) % count
                let column = singleRow ? frame : frame % tilesX
                let row =
                    singleRow
                    ? (uv["rowMode"].number() == 1
                        ? Int(floor(particle.randoms[0] * Double(tilesY))) : Int(uv["rowIndex"].number()))
                    : frame / tilesX
                uvRect = .init(
                    Double(column) / Double(tilesX),
                    Double(row) / Double(tilesY),
                    Double(column + 1) / Double(tilesX),
                    Double(row + 1) / Double(tilesY)
                )
            }
            var halfSize = size / 2
            var angle = particle.angle
            if renderer["m_RenderMode"].number() == 1 {
                let velocity = (isWorldSpace ? particle.velocity : directionToReference(particle.velocity)) * 2 / 3
                let projected = SIMD2(velocity.x, -velocity.y)
                let speed = simd_length(projected)
                halfSize = .init(
                    (size.y * renderer["m_LengthScale"].number(2) + speed * renderer["m_VelocityScale"].number()) / 2,
                    size.x / 2
                )
                angle = speed > 1e-6 ? atan2(projected.y, projected.x) : -.pi / 2
            }
            let offset = SIMD2(-pivot.x * size.x, pivot.y * size.y)
            let cosine = cos(angle), sine = sin(angle)
            let corners: [SIMD2<Double>] = [
                .init(-halfSize.x, -halfSize.y), .init(halfSize.x, -halfSize.y), .init(halfSize.x, halfSize.y),
                .init(-halfSize.x, halfSize.y),
            ]
            let coordinates: [SIMD2<Double>] = [
                .init(uvRect.x, uvRect.y), .init(uvRect.z, uvRect.y), .init(uvRect.z, uvRect.w),
                .init(uvRect.x, uvRect.w),
            ]
            var keep: Float = blend == .additive ? 0 : 1
            if addAlpha {
                let custom = system["CustomDataModule"]
                let x =
                    customStream && custom["enabled"].isEnabled
                    ? EffectCurves.minMax(custom["vector0_0"], at: age, random: particle.randoms[3]) : 0
                keep = x > 0.5 ? 0 : 1
            }
            let base = UInt32(vertices.count)
            for index in 0..<4 {
                let point = corners[index] + offset
                let rotated = SIMD2(point.x * cosine - point.y * sine, point.x * sine + point.y * cosine) + center
                vertices.append(
                    .init(position: .init(rotated), uv: .init(coordinates[index]), color: .init(color), keep: keep)
                )
            }
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
        let ordering = effect.ordering(node: nodeIndex, particle: true)
        return .init(
            vertices: vertices,
            indices: indices,
            texture: material["tex"]["_MainTex"]["file"].string,
            blend: blend == .multiply ? .multiply : .alpha,
            layer: ordering.layer,
            order: ordering.order,
            sequence: nodeIndex * 2,
            textureTransform: .init(textureTransform)
        )
    }
}
