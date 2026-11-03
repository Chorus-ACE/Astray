internal import Foundation

internal struct TextStyle: Hashable, Sendable {
    internal var scale: Double = 1
    internal var color: SIMD4<Float>?
    internal var isBold = false
    internal var isItalic = false
    internal var isUnderlined = false
    internal var alignment: Alignment?
    internal var margin: Double = 0
    internal var link: String?
    
    internal enum Alignment: String, Sendable { case left, center, right }
}

internal struct TextRun: Hashable, Sendable {
    internal let range: Range<Int>
    internal let style: TextStyle
}

internal struct FullScreenText: Sendable {
    private static let styles: [String: (String, String)] = [
        "H1": ("<size=2em><b><#40ff80>*", "*</size></b></color>"),
        "QUOTE": ("<i><size=75%><margin=10%>", "</i></size></width></margin>"),
        "LINK": ("<u><#40a0ff><link=\"ID_01\">", "</u></color></link>"),
        "TITLE": ("<size=125%><b><align=center>", "</size></b></align>"),
        "H2": ("<size=1.5em><b><#4080FF>", "</size></b></color>"),
        "H3": ("<size=1.17em><b><#FF8040>", "</size></b></color>"),
        "C1": ("<color=#ffff40>", "</color>"),
        "C2": ("<color=#ff40FF><size=125%>", "</color></size>"),
        "C3": ("<color=#80A0FF><b>", "</color></b>"),
        "NORMAL": ("", ""),
    ]
    private static let tagPattern = try! NSRegularExpression(pattern: "<([^>]+)>")
    private static let richTextPattern = try! NSRegularExpression(
        pattern: "<(?:b|i|u|size=|color=|#[0-9a-f]{6}|align=|margin=|link=)",
        options: .caseInsensitive
    )
    private static let controls: [UInt16: UInt32] = [110: 10, 114: 13, 116: 9, 118: 11]
    private static let replacements: [String: (UInt32, Int)] = ["BR": (10, 4), "NBSP": (160, 6), "ZWSP": (8203, 6)]
    
    internal static func expand(_ source: String) -> (text: String, count: Int) {
        let units = Array(source.utf16)
        var points: [UInt32] = []
        var styleStack: [(String, String)] = []
        var index = 0
        func append(_ text: String) { points.append(contentsOf: text.unicodeScalars.map(\.value)) }
        while index < units.count {
            let value = units[index]
            if value == 0 { break }
            if value == 92 && index + 1 < units.count {
                let next = units[index + 1]
                if let control = controls[next] {
                    points.append(control); index += 2; continue
                }
                if next == 92 && index + 2 < units.count {
                    points += [92, UInt32(units[index + 2])]; index += 3; continue
                }
                let digits = next == 117 ? 4 : (next == 85 ? 8 : 0)
                if digits > 0 && index + 1 + digits < units.count {
                    var number: UInt32 = 0
                    for digit in units[(index + 2)..<(index + 2 + digits)] {
                        let character = String(UnicodeScalar(UInt32(digit)) ?? "\u{FFFD}")
                        number = (number &* 16) &+ (UInt32(character, radix: 16) ?? 15)
                    }
                    points.append(number); index += 2 + digits; continue
                }
            }
            if value == 60 {
                var end = index + 1
                while end < units.count, ![32, 61, 62].contains(units[end]), end - index <= 16 { end += 1 }
                if end > index + 1, end < units.count, [32, 61, 62].contains(units[end]) {
                    let tag = String(decoding: units[(index + 1)..<end], as: UTF16.self).uppercased()
                    if tag == "STYLE", index + 7 <= units.count,
                        let close = units[(index + 7)...].firstIndex(of: 62)
                    {
                        let name = String(decoding: units[(index + 7)..<close], as: UTF16.self)
                            .replacingOccurrences(of: "\"", with: "").uppercased()
                        if let style = styles[name] {
                            styleStack.append(style); append(style.0); index = close + 1; continue
                        }
                    }
                    if tag == "/STYLE" {
                        append(styleStack.popLast()?.1 ?? ""); index += 8; continue
                    }
                    if let replacement = replacements[tag] {
                        points.append(replacement.0); index += replacement.1; continue
                    }
                }
            }
            if (0xD800...0xDBFF).contains(value), index + 1 < units.count,
                (0xDC00...0xDFFF).contains(units[index + 1])
            {
                points.append(0x10000 + (UInt32(value) - 0xD800) * 1024 + UInt32(units[index + 1]) - 0xDC00)
                index += 2
            } else {
                points.append(UInt32(value)); index += 1
            }
        }
        var output: [UInt16] = []
        for point in points {
            if point <= 0xFFFF {
                output.append(UInt16(point))
            } else if point <= 0x10FFFF {
                output += [UInt16(0xD800 + (point - 0x10000) / 1024), UInt16(0xDC00 + (point - 0x10000) % 1024)]
            } else {
                output.append(0xFFFD)
            }
        }
        return (String(decoding: output, as: UTF16.self), points.count)
    }
    
    internal let text: String
    internal let runs: [TextRun]
    internal let processingCount: Int
    
    internal init(_ source: String) {
        let expanded = Self.expand(source)
        let value = expanded.text as NSString
        guard Self.richTextPattern.firstMatch(in: expanded.text, range: .init(location: 0, length: value.length)) != nil
        else {
            text = expanded.text
            runs = value.length == 0 ? [] : [.init(range: 0..<value.length, style: .init())]
            processingCount = expanded.count
            return
        }
        var text = ""
        var runs: [TextRun] = []
        var state = StyleStack()
        var previous = 0
        func append(_ value: String) {
            guard !value.isEmpty else { return }
            let start = text.utf16.count
            text += value
            let range = start..<text.utf16.count
            let style = state.style
            if let last = runs.last, last.style == style, last.range.upperBound == range.lowerBound {
                runs[runs.count - 1] = .init(range: last.range.lowerBound..<range.upperBound, style: style)
            } else {
                runs.append(.init(range: range, style: style))
            }
        }
        for match in Self.tagPattern.matches(in: expanded.text, range: .init(location: 0, length: value.length)) {
            append(value.substring(with: .init(location: previous, length: match.range.location - previous)))
            let token = value.substring(with: match.range(at: 1))
            if !state.apply(token) { append(value.substring(with: match.range)) }
            previous = NSMaxRange(match.range)
        }
        append(value.substring(from: previous))
        self.text = text
        self.runs = runs
        processingCount = expanded.count
    }
    
    private struct StyleStack {
        private var scales: [Double] = [1]
        private var colors: [SIMD4<Float>?] = [nil]
        private var bold = [false]
        private var italic = [false]
        private var underline = [false]
        private var alignment: [TextStyle.Alignment?] = [nil]
        private var margins: [Double] = [0]
        private var links: [String?] = [nil]
        
        internal var style: TextStyle {
            .init(
                scale: scales.last!,
                color: colors.last!,
                isBold: bold.last!,
                isItalic: italic.last!,
                isUnderlined: underline.last!,
                alignment: alignment.last!,
                margin: margins.last!,
                link: links.last!
            )
        }
        
        internal mutating func apply(_ token: String) -> Bool {
            func pop<T>(_ values: inout [T]) { if values.count > 1 { values.removeLast() } }
            switch token.lowercased() {
            case "b": bold.append(true)
            case "i": italic.append(true)
            case "u": underline.append(true)
            case "/b": pop(&bold)
            case "/i": pop(&italic)
            case "/u": pop(&underline)
            case "/size": pop(&scales)
            case "/color": pop(&colors)
            case "/align": pop(&alignment)
            case "/margin": margins = [0]
            case "/link": pop(&links)
            case "/width": break
            default:
                let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = parts[0].lowercased()
                let value = parts.count == 2 ? String(parts[1]) : token
                if key == "size", let scale = Self.dimension(value) {
                    scales.append(scale)
                } else if (key == "color" || token.hasPrefix("#")), let color = Self.color(value) {
                    colors.append(color)
                } else if key == "align", let value = TextStyle.Alignment(rawValue: value.lowercased()) {
                    alignment.append(value)
                } else if key == "margin", value.hasSuffix("%"), let margin = Self.dimension(value) {
                    margins.append(margin)
                } else if key == "link", value.hasPrefix("\""), value.hasSuffix("\"") {
                    links.append(String(value.dropFirst().dropLast()))
                } else {
                    return false
                }
            }
            return true
        }
        
        private static func dimension(_ value: String) -> Double? {
            let suffix = value.lowercased().hasSuffix("em") ? 2 : (value.hasSuffix("%") ? 1 : 0)
            guard suffix > 0, let number = Double(value.dropLast(suffix)), number.isFinite, number >= 0 else {
                return nil
            }
            return suffix == 1 ? number / 100 : number
        }
        
        private static func color(_ value: String) -> SIMD4<Float>? {
            guard value.hasPrefix("#"), [7, 9].contains(value.count), let hex = UInt32(value.dropFirst(), radix: 16)
            else { return nil }
            let rgba = value.count == 7 ? hex << 8 | 0xFF : hex
            return .init(Float(rgba >> 24), Float(rgba >> 16 & 0xFF), Float(rgba >> 8 & 0xFF), Float(rgba & 0xFF)) / 255
        }
    }
}
