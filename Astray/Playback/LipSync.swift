internal import Foundation

internal enum LipSync {
    internal static let textStep = 0.06
    private static let flap: [Float] = [
        0.12, 0.24, 0.9, 1, 0.5, 0.24, 0.1, 0.24, 0.45, 0.8,
        0.8, 0.96, 0.8, 0.4, 0.24, 0.1, 0.06, 0.1, 0.24, 0.24,
        0.5, 0.7, 0.96, 0.9, 0.8, 0.24, 0.24, 0.1, 0.06, 0.1,
        0.24, 0.4, 0.5, 0.9, 0.8, 0.45, 0.3, 0.24,
    ]

    internal static func textTarget(at elapsed: Double, duration: Double) -> Float {
        guard elapsed.isFinite, elapsed >= 0, elapsed < duration else { return 0 }
        return flap[Int(elapsed / textStep) % flap.count]
    }
    
    internal static func voiceTarget(rms: Float, scale: Float) -> Float {
        guard rms.isFinite, scale.isFinite, scale > 0 else { return 0 }
        let value = max(0, rms) * scale
        let target = value * pow(value + 1, 1.75 * scale)
        return target.isNaN || target < 0.06 ? 0 : min(1, max(0.2, target))
    }
}
