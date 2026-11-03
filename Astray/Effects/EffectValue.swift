internal import Foundation

internal indirect enum EffectValue: Decodable, Sendable {
    case object([String: EffectValue])
    case array([EffectValue])
    case number(Double)
    case string(String)
    case bool(Bool)
    case null
    
    internal init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let object = try? value.decode([String: Self].self) {
            self = .object(object)
        } else if let array = try? value.decode([Self].self) {
            self = .array(array)
        } else if let boolean = try? value.decode(Bool.self) {
            self = .bool(boolean)
        } else if let number = try? value.decode(Double.self) {
            self = .number(number)
        } else {
            self = .string(try value.decode(String.self))
        }
    }
    
    internal subscript(_ key: String) -> Self {
        get { object[key] ?? .null }
        set {
            var values = object
            values[key] = newValue
            self = .object(values)
        }
    }
    
    internal subscript(_ index: Int) -> Self {
        get { array.indices.contains(index) ? array[index] : .null }
        set {
            var values = array
            guard values.indices.contains(index) else { return }
            values[index] = newValue
            self = .array(values)
        }
    }
    
    internal var object: [String: Self] { if case .object(let value) = self { value } else { [:] } }
    internal var array: [Self] { if case .array(let value) = self { value } else { [] } }
    internal var string: String { if case .string(let value) = self { value } else { "" } }
    internal var numbers: [Double] { array.map { $0.number() } }
    internal var isNull: Bool { if case .null = self { true } else { false } }
    internal var isEnabled: Bool { number() != 0 }
    
    internal func number(_ fallback: Double = 0) -> Double {
        switch self {
        case .number(let value): value
        case .bool(let value): value ? 1 : 0
        case .string(let value): Double(value) ?? fallback
        default: fallback
        }
    }
    
    internal func vector3(_ fallback: SIMD3<Double> = .zero) -> SIMD3<Double> {
        if case .array = self {
            return .init(self[0].number(fallback.x), self[1].number(fallback.y), self[2].number(fallback.z))
        }
        return .init(self["x"].number(fallback.x), self["y"].number(fallback.y), self["z"].number(fallback.z))
    }
    
    internal func vector4(_ fallback: SIMD4<Double> = .one) -> SIMD4<Double> {
        .init(
            self[0].number(fallback.x),
            self[1].number(fallback.y),
            self[2].number(fallback.z),
            self[3].number(fallback.w)
        )
    }
}

internal enum EffectCurves {
    internal static func evaluate(_ curve: EffectValue, at time: Double) -> Double {
        let keys = curve["k"].array
        guard let first = keys.first, let last = keys.last else { return 0 }
        if time <= first[0].number() { return first[1].number() }
        if time >= last[0].number() { return last[1].number() }
        var index = 1
        while index < keys.count - 1 && keys[index][0].number() < time { index += 1 }
        let a = keys[index - 1].numbers
        let b = keys[index].numbers
        guard a.count >= 4, b.count >= 4 else { return 0 }
        if abs(a[3]) > 1e8 || abs(b[2]) > 1e8 { return a[1] }
        let duration = b[0] - a[0]
        guard duration > 0 else { return b[1] }
        let s = (time - a[0]) / duration
        let s2 = s * s
        let s3 = s2 * s
        return (2 * s3 - 3 * s2 + 1) * a[1] + (s3 - 2 * s2 + s) * duration * a[3]
            + (-2 * s3 + 3 * s2) * b[1] + (s3 - s2) * duration * b[2]
    }
    
    internal static func minMax(_ value: EffectValue, at time: Double, random: Double) -> Double {
        switch Int(value["m"].number()) {
        case 0: value["s"].number()
        case 1: value["s"].number() * evaluate(value["c"], at: time)
        case 2:
            value["s"].number()
                * (evaluate(value["cn"], at: time) * (1 - random) + evaluate(value["c"], at: time) * random)
        default: value["n"].number() * (1 - random) + value["s"].number() * random
        }
    }
    
    internal static func gradient(_ gradient: EffectValue, at time: Double) -> SIMD4<Double> {
        func channels(_ keys: [EffectValue], indices: [Int]) -> [Double] {
            guard let first = keys.first, let last = keys.last else { return indices.map { _ in 1 } }
            if time <= first[0].number() { return indices.map { first[$0].number() } }
            if time >= last[0].number() { return indices.map { last[$0].number() } }
            var index = 1
            while index < keys.count - 1 && keys[index][0].number() < time { index += 1 }
            let a = keys[index - 1]
            let b = keys[index]
            if gradient["f"].number() == 1 { return indices.map { b[$0].number() } }
            let duration = b[0].number() - a[0].number()
            let fraction = (time - a[0].number()) / (duration == 0 ? 1 : duration)
            return indices.map { a[$0].number() + (b[$0].number() - a[$0].number()) * fraction }
        }
        let rgb = channels(gradient["c"].array, indices: [1, 2, 3])
        return .init(rgb[0], rgb[1], rgb[2], channels(gradient["a"].array, indices: [1])[0])
    }
    
    internal static func minMaxGradient(_ value: EffectValue, at time: Double, random: Double) -> SIMD4<Double> {
        switch Int(value["m"].number()) {
        case 0: value["max"].vector4()
        case 1: gradient(value["g"], at: time)
        case 2: value["min"].vector4() * (1 - random) + value["max"].vector4() * random
        case 3: gradient(value["gn"], at: time) * (1 - random) + gradient(value["g"], at: time) * random
        default: gradient(value["g"], at: random)
        }
    }
    
    internal static func vector(_ keys: [EffectValue], at time: Double) -> SIMD3<Double> {
        var result = SIMD3<Double>.zero
        for axis in 0..<3 {
            let curve = EffectValue.object([
                "k": .array(
                    keys.map { key in
                        .array([key[0], key[1][axis], key[2][axis], key[3][axis]])
                    }
                )
            ])
            result[axis] = evaluate(curve, at: time)
        }
        return result
    }
}
