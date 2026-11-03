internal import simd
internal import Foundation

internal final class ParticleEmitter {
    internal let nodeIndex: Int
    internal unowned let effect: PrefabEffect
    internal var system: EffectValue
    internal var particles: [Particle] = []
    internal var time: Double = 0
    internal var emitting = false
    internal var hasPlayed = false
    internal var isSubEmitter = false
    internal var world = matrix_identity_double4x4
    internal var rotation = matrix_identity_double4x4
    internal var scale = SIMD3<Double>.one
    internal var textureTransform = SIMD4<Double>(1, 1, 0, 0)
    private var emissionAccumulator: Double = 0
    private var bursts: [Int: Int] = [:]
    
    internal init(node: Int, effect: PrefabEffect) {
        nodeIndex = node
        self.effect = effect
        system = effect.document["nodes"][node]["ps"]
        let material = effect.document["materials"][effect.document["nodes"][node]["psr"]["materials"][0].string]
        textureTransform = material["tex"]["_MainTex"]["st"].vector4(.init(1, 1, 0, 0))
    }
    
    internal var duration: Double { max(1e-6, system["lengthInSec"].number(5)) }
    internal var isWorldSpace: Bool { system["moveWithTransform"].number() == 1 }
    internal var unit: Double { effect.document["unit"].number(540) }
    
    internal func play() {
        time = -mm(system["startDelay"], at: 0, random: random())
        emitting = true
        hasPlayed = true
        emissionAccumulator = 0
        bursts = [:]
        particles = []
        if system["prewarm"].isEnabled && system["looping"].isEnabled {
            var elapsed = 0.0
            while elapsed < duration { step(1 / 30); elapsed += 1 / 30 }
        }
    }
    
    internal func stop() { emitting = false }
    
    internal func clear() {
        emitting = false
        hasPlayed = false
        particles = []
    }
    
    @discardableResult
    internal func spawn(at position: SIMD3<Double>? = nil, inheriting parent: Particle? = nil, flags: Int = 0)
        -> Particle?
    {
        let initial = system["InitialModule"]
        guard !initial.isNull, particles.count < Int(initial["maxNumParticles"].number(1000)) else { return nil }
        let normalized = max(0, time) / duration
        let randoms = (0..<8).map { _ in random() }
        var (point, direction) = shape()
        var life = mm(initial["startLifetime"], at: normalized, random: random())
        let speed = mm(initial["startSpeed"], at: normalized, random: random())
        let width = mm(initial["startSize"], at: normalized, random: randoms[0])
        var size = SIMD3(
            width,
            initial["size3D"].isEnabled ? mm(initial["startSizeY"], at: normalized, random: randoms[0]) : width,
            1
        )
        var angle = mm(initial["startRotation"], at: normalized, random: random())
        if initial["randomizeRotationDirection"].isEnabled && random() < initial["randomizeRotationDirection"].number()
        {
            angle = -angle
        }
        var color = EffectCurves.minMaxGradient(initial["startColor"], at: normalized, random: random())
        direction *= speed
        if isWorldSpace { point = toReference(point); direction = directionToReference(direction) }
        if let position { point = position }
        if let parent {
            if flags & 1 != 0 { color *= parent.color }
            if flags & 2 != 0 { size.x *= parent.size.x; size.y *= parent.size.y }
            if flags & 4 != 0 { angle += parent.angle }
            if flags & 8 != 0 { life *= parent.lifetime }
        }
        let particle = Particle(
            position: point,
            velocity: direction,
            lifetime: max(0.001, life),
            size: size,
            angle: angle,
            color: color,
            randoms: randoms
        )
        for sub in system["SubModule"]["subEmitters"].array {
            guard let emitter = effect.emitters[Int(sub["emitter"].number(-1))],
                random() <= sub["emitProbability"].number(1)
            else { continue }
            if sub["type"].number() == 0 { particle.subs.append(.init(emitter: emitter)) }
        }
        particles.append(particle)
        return particle
    }
    
    private func shape() -> (SIMD3<Double>, SIMD3<Double>) {
        let shape = system["ShapeModule"]
        guard shape["enabled"].isEnabled else { return (.zero, .init(0, 0, 1)) }
        let radius = shape["radius"]["value"].number(1)
        let thickness = shape["radiusThickness"].number(1)
        let arc = shape["arc"]["value"].number(360) * EffectMath.degrees
        func sphere() -> SIMD3<Double> {
            let z = random() * 2 - 1
            let angle = random() * 2 * .pi
            let radial = sqrt(max(0, 1 - z * z))
            return .init(radial * cos(angle), radial * sin(angle), z)
        }
        func shellRadius() -> Double { radius * (1 - thickness * (1 - sqrt(random()))) }
        let type = Int(shape["type"].number())
        var position = SIMD3<Double>.zero
        var direction = SIMD3<Double>(0, 0, 1)
        switch type {
        case 0...3:
            direction = sphere()
            if type >= 2 { direction.z = abs(direction.z) }
            position = direction * radius * (1 - thickness * (1 - pow(random(), 1.0 / 3)))
        case 4, 7, 8, 9:
            let angle = random() * arc
            let distance = shellRadius()
            let base = SIMD3(cos(angle) * distance, sin(angle) * distance, 0)
            let tangent = tan(shape["angle"].number(25) * EffectMath.degrees)
            direction = simd_normalize(
                .init(base.x / (radius == 0 ? 1 : radius) * tangent, base.y / (radius == 0 ? 1 : radius) * tangent, 1)
            )
            position = base
            if type >= 8 { position += direction * random() * shape["length"].number(5) / direction.z }
        case 10, 11, 17:
            let angle = random() * arc
            let distance = type == 11 ? radius : shellRadius()
            direction = .init(cos(angle), sin(angle), 0)
            position = direction * distance
        case 12:
            position = .init((random() * 2 - 1) * radius, 0, 0)
            direction = .init(0, 1, 0)
        default:
            position = .init(random() - 0.5, random() - 0.5, random() - 0.5)
        }
        let rotation = EffectMath.quaternion(shape["m_Rotation"].vector3())
        position = EffectMath.point(
            EffectMath.transform(
                position: shape["m_Position"].vector3(),
                rotation: rotation,
                scale: shape["m_Scale"].vector3(.one)
            ),
            position
        )
        direction = rotation.act(direction)
        if shape["randomDirectionAmount"].isEnabled {
            direction += (sphere() - direction) * shape["randomDirectionAmount"].number()
        }
        if shape["sphericalDirectionAmount"].isEnabled {
            direction +=
                (position / max(1e-10, simd_length(position)) - direction) * shape["sphericalDirectionAmount"].number()
        }
        if shape["randomPositionAmount"].isEnabled {
            position +=
                SIMD3(random() * 2 - 1, random() * 2 - 1, random() * 2 - 1) * shape["randomPositionAmount"].number()
        }
        return (position, direction / max(1e-10, simd_length(direction)))
    }
    
    internal func toReference(_ point: SIMD3<Double>) -> SIMD3<Double> { EffectMath.point(world, point * unit * scale) }
    internal func directionToReference(_ vector: SIMD3<Double>) -> SIMD3<Double> {
        EffectMath.direction(rotation, vector * unit * scale)
    }
    
    internal func step(_ delta: Double) {
        let delta = delta * system["simulationSpeed"].number(1)
        if emitting && !isSubEmitter {
            time += delta
            if time >= 0 {
                if time >= duration {
                    if system["looping"].isEnabled { time -= duration; bursts = [:] } else { emitting = false }
                }
                let emission = system["EmissionModule"]
                if emitting && emission["enabled"].isEnabled {
                    emissionAccumulator += mm(emission["rateOverTime"], at: time / duration, random: random()) * delta
                    while emissionAccumulator >= 1 { emissionAccumulator -= 1; spawn() }
                    for (index, burst) in emission["m_Bursts"].array.enumerated() { emitBurst(burst, index: index) }
                }
            }
        }
        let initial = system["InitialModule"]
        let gravity = mm(initial["gravityModifier"], at: max(0, time) / duration, random: random())
        var surviving: [Particle] = []
        for particle in particles {
            particle.age += delta
            if particle.age >= particle.lifetime { onDeath(particle); continue }
            let age = particle.age / particle.lifetime
            if gravity != 0 {
                let worldGravity = SIMD3<Double>(0, -9.81 * gravity, 0)
                let localGravity =
                    EffectMath.direction(rotation.transpose, worldGravity)
                    / SIMD3(scale.x == 0 ? 1 : scale.x, scale.y == 0 ? 1 : scale.y, scale.z == 0 ? 1 : scale.z)
                particle.velocity += (isWorldSpace ? worldGravity * unit : localGravity) * delta
            }
            var velocity = particle.velocity
            let module = system["VelocityModule"]
            if module["enabled"].isEnabled {
                let addition = SIMD3(
                    mm(module["x"], at: age, random: particle.randoms[1]),
                    mm(module["y"], at: age, random: particle.randoms[2]),
                    mm(module["z"], at: age, random: particle.randoms[3])
                )
                velocity += isWorldSpace ? directionToReference(addition) : addition
                if !module["speedModifier"].isNull {
                    velocity *= mm(module["speedModifier"], at: age, random: particle.randoms[4])
                }
                let radial = mm(module["radial"], at: age, random: particle.randoms[5])
                if radial != 0 {
                    velocity +=
                        particle.position / max(1e-10, simd_length(particle.position)) * radial
                        * (isWorldSpace ? unit : 1)
                }
            }
            let clamp = system["ClampVelocityModule"]
            if clamp["enabled"].isEnabled {
                let units = isWorldSpace ? unit : 1
                let damp = 1 - pow(1 - min(1, clamp["dampen"].number()), delta * 30)
                if clamp["separateAxis"].isEnabled {
                    for (axis, key) in ["x", "y", "z"].enumerated() {
                        let limit = mm(clamp[key], at: age, random: particle.randoms[6]) * units
                        let speed = abs(particle.velocity[axis])
                        if speed > limit {
                            particle.velocity[axis] -= (particle.velocity[axis] < 0 ? -1 : 1) * (speed - limit) * damp
                        }
                    }
                } else {
                    let limit = mm(clamp["magnitude"], at: age, random: particle.randoms[6]) * units
                    let speed = simd_length(particle.velocity)
                    if speed > limit && speed > 0 { particle.velocity *= (speed - (speed - limit) * damp) / speed }
                }
                if !clamp["drag"].isNull {
                    particle.velocity *= max(0, 1 - mm(clamp["drag"], at: age, random: particle.randoms[7]) * delta)
                }
            }
            let noise = system["NoiseModule"]
            if noise["enabled"].isEnabled {
                let strength = mm(noise["strength"], at: age, random: particle.randoms[0]) * (isWorldSpace ? unit : 1)
                let frequency = noise["frequency"].number(0.5)
                let time = (time + particle.randoms[1] * 10) * (1 + mm(noise["scrollSpeed"], at: age, random: 0))
                func noiseValue(_ value: Double) -> Double {
                    sin(value * 1.7 + time * 2.3) * 0.6 + sin(value * 3.1 - time * 1.3) * 0.4
                }
                let scale = isWorldSpace ? 1 / unit : 1
                velocity.x += noiseValue(particle.position.y * frequency * scale + particle.randoms[2] * 50) * strength
                velocity.y += noiseValue(particle.position.x * frequency * scale + particle.randoms[3] * 50) * strength
            }
            particle.position += velocity * delta
            if system["RotationModule"]["enabled"].isEnabled {
                particle.angle += mm(system["RotationModule"]["curve"], at: age, random: particle.randoms[4]) * delta
            }
            for sub in particle.subs { runSub(sub, parent: particle, delta: delta) }
            surviving.append(particle)
        }
        particles = surviving
    }
    
    private func emitBurst(_ burst: EffectValue, index: Int) {
        let cycles = Int(burst["cycleCount"].number(1))
        for _ in 0..<64 {
            let done = bursts[index, default: 0]
            if cycles > 0 && done >= cycles { return }
            if time < burst["time"].number() + Double(done)
                * (burst["repeatInterval"].number() == 0 ? 0.01 : burst["repeatInterval"].number())
            {
                return
            }
            bursts[index] = done + 1
            if random() > burst["probability"].number(1) { continue }
            let count = Int(mm(burst["countCurve"], at: 0, random: random()).rounded())
            for _ in 0..<max(0, count) { spawn() }
        }
    }
    
    private func subPosition(_ particle: Particle, emitter: ParticleEmitter) -> SIMD3<Double> {
        let reference = isWorldSpace ? particle.position : toReference(particle.position)
        if emitter.isWorldSpace { return reference }
        let translation = SIMD3(emitter.world[3].x, emitter.world[3].y, emitter.world[3].z)
        let local = EffectMath.direction(emitter.rotation.transpose, reference - translation)
        let scale = emitter.scale.replacing(with: .one, where: emitter.scale .== .zero)
        return local / (unit * scale)
    }
    
    private func runSub(_ sub: SubState, parent: Particle, delta: Double) {
        guard let emitter = sub.emitter else { return }
        let emission = emitter.system["EmissionModule"]
        guard emission["enabled"].isEnabled else { return }
        sub.time += delta
        if sub.time > emitter.duration && !emitter.system["looping"].isEnabled { return }
        let normalized = sub.time.truncatingRemainder(dividingBy: emitter.duration) / emitter.duration
        sub.accumulator += mm(emission["rateOverTime"], at: normalized, random: random()) * delta
        let at = subPosition(parent, emitter: emitter)
        while sub.accumulator >= 1 { sub.accumulator -= 1; emitter.spawn(at: at) }
        for (index, burst) in emission["m_Bursts"].array.enumerated() {
            for _ in 0..<64 {
                let done = sub.bursts[index, default: 0]
                let cycles = Int(burst["cycleCount"].number(1))
                if cycles > 0 && done >= cycles { break }
                if sub.time < burst["time"].number() + Double(done)
                    * (burst["repeatInterval"].number() == 0 ? 0.01 : burst["repeatInterval"].number())
                {
                    break
                }
                sub.bursts[index] = done + 1
                let count = Int(mm(burst["countCurve"], at: 0, random: random()).rounded())
                for _ in 0..<max(0, count) { emitter.spawn(at: at) }
            }
        }
    }
    
    private func onDeath(_ particle: Particle) {
        for sub in system["SubModule"]["subEmitters"].array {
            guard sub["type"].number() == 2, let emitter = effect.emitters[Int(sub["emitter"].number(-1))],
                random() <= sub["emitProbability"].number(1)
            else { continue }
            let at = subPosition(particle, emitter: emitter)
            var count = 0
            for burst in emitter.system["EmissionModule"]["m_Bursts"].array {
                count += Int(mm(burst["countCurve"], at: 0, random: random()).rounded())
            }
            for _ in 0..<max(1, count) {
                emitter.spawn(at: at, inheriting: particle, flags: Int(sub["properties"].number()))
            }
        }
    }
    
    private func mm(_ value: EffectValue, at time: Double, random: Double) -> Double {
        EffectCurves.minMax(value, at: time, random: random)
    }
    private func random() -> Double { effect.random.next() }
    
    internal final class Particle {
        internal var position: SIMD3<Double>
        internal var velocity: SIMD3<Double>
        internal let lifetime: Double
        internal let size: SIMD3<Double>
        internal var angle: Double
        internal let color: SIMD4<Double>
        internal let randoms: [Double]
        internal var age: Double = 0
        internal var subs: [SubState] = []
        
        internal init(
            position: SIMD3<Double>,
            velocity: SIMD3<Double>,
            lifetime: Double,
            size: SIMD3<Double>,
            angle: Double,
            color: SIMD4<Double>,
            randoms: [Double]
        ) {
            self.position = position
            self.velocity = velocity
            self.lifetime = lifetime
            self.size = size
            self.angle = angle
            self.color = color
            self.randoms = randoms
        }
    }
    
    internal final class SubState {
        internal weak var emitter: ParticleEmitter?
        internal var time: Double = 0
        internal var accumulator: Double = 0
        internal var bursts: [Int: Int] = [:]
        
        internal init(emitter: ParticleEmitter) { self.emitter = emitter }
    }
}
