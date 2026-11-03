internal import simd

internal struct EffectRandom {
    private var state: UInt64
    
    internal init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    
    internal mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state >> 11) / 9007199254740992
    }
}

internal enum EffectMath {
    internal static let unit: Double = 540
    internal static let degrees = Double.pi / 180
    
    internal static func quaternion(_ euler: SIMD3<Double>) -> simd_quatd {
        let e = euler * (degrees / 2)
        let cx = cos(e.x), sx = sin(e.x), cy = cos(e.y), sy = sin(e.y), cz = cos(e.z), sz = sin(e.z)
        return .init(
            ix: sx * cy * cz + cx * sy * sz,
            iy: cx * sy * cz - sx * cy * sz,
            iz: cx * cy * sz - sx * sy * cz,
            r: cx * cy * cz + sx * sy * sz
        )
    }
    
    internal static func transform(position: SIMD3<Double>, rotation: simd_quatd, scale: SIMD3<Double>)
        -> simd_double4x4
    {
        var matrix = simd_double4x4(rotation)
        for axis in 0..<3 { matrix[axis] *= scale[axis] }
        matrix[3] = .init(position.x, position.y, position.z, 1)
        return matrix
    }
    
    internal static func point(_ matrix: simd_double4x4, _ value: SIMD3<Double>) -> SIMD3<Double> {
        let result = matrix * SIMD4(value.x, value.y, value.z, 1)
        return .init(result.x, result.y, result.z)
    }
    
    internal static func direction(_ matrix: simd_double4x4, _ value: SIMD3<Double>) -> SIMD3<Double> {
        let result = matrix * SIMD4(value.x, value.y, value.z, 0)
        return .init(result.x, result.y, result.z)
    }
    
    internal static func rotationOnly(_ matrix: simd_double4x4) -> simd_double4x4 {
        var result = matrix
        for axis in 0..<3 {
            let column = SIMD3(matrix[axis].x, matrix[axis].y, matrix[axis].z)
            result[axis] /= max(1e-10, simd_length(column))
        }
        result[3] = .init(0, 0, 0, 1)
        return result
    }
}
