internal import Foundation

internal enum EffectTiming {
    internal static func ease(_ name: String, _ fraction: Double) -> Double {
        let value = max(0, min(1, fraction))
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "insine": return 1 - cos(value * .pi / 2)
        case "outsine": return sin(value * .pi / 2)
        case "inoutsine": return -0.5 * (cos(.pi * value) - 1)
        case "inquad": return value * value
        case "outquad": return -value * (value - 2)
        case "inoutquad": return value < 0.5 ? 2 * value * value : -1 + (4 - 2 * value) * value
        case "incubic": return value * value * value
        case "outcubic": return pow(value - 1, 3) + 1
        case "inoutcubic": return value < 0.5 ? 4 * value * value * value : (value - 1) * pow(2 * value - 2, 2) + 1
        case "outquart": return 1 - pow(value - 1, 4)
        case "inback": return value * value * (2.70158 * value - 1.70158)
        case "outback": return pow(value - 1, 2) * (2.70158 * (value - 1) + 1.70158) + 1
        default: return value
        }
    }
    
    internal static func sample(_ keys: [(Double, Double)], at time: Double) -> Double {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if time <= first.0 { return first.1 }
        for index in 1..<keys.count where time <= keys[index].0 {
            let a = keys[index - 1], b = keys[index]
            return a.1 + (b.1 - a.1) * (time - a.0) / (b.0 - a.0)
        }
        return last.1
    }
    
    internal static let telopScale: [(Double, Double)] = [
        (0, 0), (0.017, 0.123), (0.033, 0.254), (0.05, 0.378), (0.067, 0.49), (0.083, 0.589), (0.1, 0.675),
        (0.117, 0.749), (0.133, 0.813), (0.15, 0.865), (0.167, 0.909), (0.183, 0.943), (0.2, 0.968), (0.217, 0.986),
        (0.233, 0.997), (0.25, 1),
    ]
    internal static let telopBaseAlpha: [(Double, Double)] = [
        (0, 0), (0.017, 0.014), (0.033, 0.055), (0.05, 0.124), (0.067, 0.216), (0.083, 0.325), (0.1, 0.442),
        (0.117, 0.557), (0.133, 0.664), (0.15, 0.757), (0.167, 0.835), (0.183, 0.897), (0.2, 0.944), (0.217, 0.976),
        (0.233, 0.994), (0.25, 1),
    ]
    internal static let telopTextAlpha: [(Double, Double)] = [
        (0.05, 0), (0.067, 0.012), (0.083, 0.052), (0.1, 0.136), (0.117, 0.291), (0.133, 0.55), (0.15, 0.808),
        (0.167, 0.9), (0.333, 1),
    ]
    internal static let telopTextX: [(Double, Double)] = [
        (0.05, -30), (0.12, -24.7), (0.19, -15), (0.26, -5.3), (0.333, 0),
    ]
    internal static let telopHide: [(Double, Double)] = [
        (0, 1), (0.033, 0.992), (0.067, 0.962), (0.1, 0.904), (0.133, 0.804), (0.167, 0.645), (0.2, 0.424),
        (0.233, 0.212), (0.267, 0.079), (0.3, 0.017), (0.333, 0),
    ]
}

internal struct EffectShake {
    private let ends: [Double]
    private let points: [SIMD2<Double>]
    internal let duration: Double
    
    internal init(
        duration: Double,
        strength: Double,
        vibrato: Double,
        fadeOut: Bool,
        ignoreZ: Bool,
        seed: UInt64 = .random(in: 1...UInt64.max)
    ) {
        self.duration = duration
        let count = max(2, Int(vibrato * duration))
        let sum = fadeOut ? Double(count * (count + 1)) / 2 : Double(count)
        var random = EffectRandom(seed: seed)
        var accumulated = 0.0
        var ends: [Double] = []
        var points: [SIMD2<Double>] = []
        var angle = random.next() * 360
        var magnitude = strength
        for index in 0..<count {
            accumulated += (fadeOut ? Double(index + 1) : 1) / sum * duration
            ends.append(accumulated)
            if index == count - 1 { points.append(.zero); continue }
            if index > 0 { angle = angle - 180 + (random.next() * 2 - 1) * 90 }
            var x = magnitude * cos(angle * .pi / 180)
            if !ignoreZ { x *= cos((random.next() * 2 - 1) * .pi / 2) }
            points.append(.init(x, magnitude * sin(angle * .pi / 180)))
            if fadeOut { magnitude -= strength / Double(count) }
        }
        self.ends = ends
        self.points = points
    }
    
    internal func offset(at time: Double) -> SIMD2<Float> {
        guard time >= 0, time < duration else { return .zero }
        let index = ends.firstIndex { $0 > time } ?? ends.count - 1
        let start = index > 0 ? ends[index - 1] : 0
        let point = index > 0 ? points[index - 1] : .zero
        let fraction = (time - start) / max(1e-10, ends[index] - start)
        return .init(point + (points[index] - point) * fraction)
    }
}
