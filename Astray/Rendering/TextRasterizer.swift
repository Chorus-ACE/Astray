internal import Metal
internal import CoreText
internal import Foundation
internal import CoreGraphics

@MainActor
internal final class TextRasterizer {
    private static var fontsRegistered = false
    private static let cacheBudget = 32 * 1024 * 1024
    private let device: any MTLDevice
    private var cache: [Key: any MTLTexture] = [:]
    private var cacheOrder: [Key] = []
    private var cacheBytes = 0
    
    internal init(device: any MTLDevice) {
        self.device = device
        if !Self.fontsRegistered {
            let bundle = Bundle(for: ShaderBundleToken.self)
            for name in ["SourceHanSansJP-Bold", "SourceHanSansJP-Medium"] {
                let url =
                    bundle.url(forResource: name, withExtension: "otf")
                    ?? bundle.url(forResource: name, withExtension: "otf", subdirectory: "Fonts")
                if let url { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
            }
            Self.fontsRegistered = true
        }
    }
    
    internal func texture(
        text: String,
        width: Int,
        height: Int,
        size: Double,
        centered: Bool = false,
        bold: Bool = false,
        color: SIMD4<Float> = .one,
        outline: Bool = false,
        alphas: [Float] = [],
        lineHeight: Double? = nil,
        singleLine: Bool = false,
        letterSpacing: Double = 0,
        runs: [TextRun] = [],
        usesStyleColor: Bool = true
    ) throws -> (any MTLTexture)? {
        guard !text.isEmpty else { return nil }
        let key = Key(
            text: text,
            width: width,
            height: height,
            size: size,
            centered: centered,
            bold: bold,
            color: color,
            outline: outline,
            alphas: alphas,
            lineHeight: lineHeight,
            singleLine: singleLine,
            letterSpacing: letterSpacing,
            runs: runs,
            usesStyleColor: usesStyleColor
        )
        if let texture = cache[key] {
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            return texture
        }
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw AstrayError.renderingFailed("Unable to allocate a text bitmap.") }
        let font = CTFontCreateWithName(
            (bold ? "SourceHanSansJP-Bold" : "SourceHanSansJP-Medium") as CFString,
            size,
            nil
        )
        func paragraph(for style: TextStyle) -> CTParagraphStyle {
            var alignment: CTTextAlignment
            switch style.alignment {
            case .left: alignment = .left
            case .center: alignment = .center
            case .right: alignment = .right
            case nil: alignment = centered ? .center : .left
            }
            var paragraphHeight = (lineHeight ?? size * 1.2) * style.scale
            var head = Double(width) * style.margin
            var tail = -head
            return withUnsafePointer(to: &alignment) { alignment in
                withUnsafePointer(to: &paragraphHeight) { height in
                    withUnsafePointer(to: &head) { head in
                        withUnsafePointer(to: &tail) { tail in
                            let settings = [
                                CTParagraphStyleSetting(
                                    spec: .alignment,
                                    valueSize: MemoryLayout<CTTextAlignment>.size,
                                    value: alignment
                                ),
                                CTParagraphStyleSetting(
                                    spec: .minimumLineHeight,
                                    valueSize: MemoryLayout<Double>.size,
                                    value: height
                                ),
                                CTParagraphStyleSetting(
                                    spec: .maximumLineHeight,
                                    valueSize: MemoryLayout<Double>.size,
                                    value: height
                                ),
                                CTParagraphStyleSetting(
                                    spec: .firstLineHeadIndent,
                                    valueSize: MemoryLayout<Double>.size,
                                    value: head
                                ),
                                CTParagraphStyleSetting(
                                    spec: .headIndent,
                                    valueSize: MemoryLayout<Double>.size,
                                    value: head
                                ),
                                CTParagraphStyleSetting(
                                    spec: .tailIndent,
                                    valueSize: MemoryLayout<Double>.size,
                                    value: tail
                                ),
                            ]
                            return settings.withUnsafeBufferPointer { CTParagraphStyleCreate($0.baseAddress, $0.count) }
                        }
                    }
                }
            }
        }
        func attributes(_ style: TextStyle) -> [NSAttributedString.Key: Any] {
            let styledColor = usesStyleColor ? style.color ?? color : color
            let ink = CGColor(
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                components: [
                    CGFloat(styledColor.x), CGFloat(styledColor.y), CGFloat(styledColor.z),
                    CGFloat(style.scale == 0 ? 0 : color.w * (style.color?.w ?? 1)),
                ]
            )!
            var styledFont =
                style.scale == 1 && !style.isBold
                ? font
                : CTFontCreateWithName(
                    (bold || style.isBold ? "SourceHanSansJP-Bold" : "SourceHanSansJP-Medium") as CFString,
                    max(0.001, size * style.scale),
                    nil
                )
            if style.isItalic {
                if let italic = CTFontCreateCopyWithSymbolicTraits(styledFont, 0, nil, .traitItalic, .traitItalic) {
                    styledFont = italic
                } else {
                    var transform = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
                    styledFont = CTFontCreateCopyWithAttributes(styledFont, 0, &transform, nil)
                }
            }
            var values: [NSAttributedString.Key: Any] = [
                .init(kCTFontAttributeName as String): styledFont,
                .init(kCTForegroundColorAttributeName as String): ink,
                .init(kCTParagraphStyleAttributeName as String): paragraph(for: style),
            ]
            values[.init(kCTKernAttributeName as String)] = letterSpacing
            if style.isUnderlined { values[.init(kCTUnderlineStyleAttributeName as String)] = 1 }
            if outline {
                values[.init(kCTStrokeWidthAttributeName as String)] = -6.4 / (bold ? 29.333333 : 26.666667) * 100
                values[.init(kCTStrokeColorAttributeName as String)] = ink
            }
            return values
        }
        let string = NSMutableAttributedString(string: text, attributes: attributes(.init()))
        for run in runs where run.range.lowerBound >= 0 && run.range.upperBound <= string.length {
            string.setAttributes(
                attributes(run.style),
                range: .init(location: run.range.lowerBound, length: run.range.count)
            )
        }
        if !alphas.isEmpty {
            var offset = 0
            for (index, scalar) in text.unicodeScalars.enumerated() {
                let length = scalar.value > 0xFFFF ? 2 : 1
                let key = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
                let ink = string.attribute(key, at: offset, effectiveRange: nil) as! CGColor
                let alpha = alphas.indices.contains(index) ? alphas[index] : 1
                let faded = ink.copy(alpha: ink.alpha * CGFloat(alpha))!
                let range = NSRange(location: offset, length: length)
                string.addAttribute(key, value: faded, range: range)
                if outline {
                    string.addAttribute(.init(kCTStrokeColorAttributeName as String), value: faded, range: range)
                }
                offset += length
            }
        }
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let path = CGPath(rect: .init(x: 0, y: 0, width: width, height: height), transform: nil)
        if singleLine {
            let line = CTLineCreateWithAttributedString(string)
            let measured = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.textPosition = .init(
                x: centered ? (Double(width) - measured) / 2 : 0,
                y: Double(height) - CTFontGetAscent(font)
            )
            CTLineDraw(line, context)
        } else {
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, .init(location: 0, length: 0), path, nil), context)
        }
        let texture = try BitmapTexture.make(context: context, device: device)
        let bytes = texture.allocatedSize
        if bytes <= Self.cacheBudget {
            while cacheBytes + bytes > Self.cacheBudget || cache.count >= 128 {
                let oldest = cacheOrder.removeFirst()
                if let removed = cache.removeValue(forKey: oldest) { cacheBytes -= removed.allocatedSize }
            }
            cache[key] = texture
            cacheOrder.append(key)
            cacheBytes += bytes
        }
        return texture
    }
    
    internal func fittingSize(text: String, width: Double, minimum: Double, maximum: Double, step: Double) -> Double {
        var size = maximum
        while size > minimum {
            let font = CTFontCreateWithName("SourceHanSansJP-Medium" as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
            )
            if CTLineGetTypographicBounds(line, nil, nil, nil) <= width { break }
            size -= step
        }
        return max(minimum, size)
    }
    
    internal func continuationMark() throws -> any MTLTexture {
        let scale = 3.0
        let context = CGContext(
            data: nil,
            width: 150,
            height: 132,
            bitsPerComponent: 8,
            bytesPerRow: 600,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.translateBy(x: 0, y: 132)
        context.scaleBy(x: scale, y: -scale)
        let path = CGMutablePath()
        path.move(to: .init(x: 22, y: 6))
        for point in [CGPoint(x: 40, y: 1), .init(x: 40, y: 9), .init(x: 26, y: 13), .init(x: 26, y: 33)] {
            path.addLine(to: point)
        }
        // The endpoint arc is the same large clockwise ellipse as the reference SVG.
        let start = CGPoint(x: 26, y: 33)
        let end = CGPoint(x: 22, y: 26.9)
        let rx = 8.0, ry = 7.0
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let factor = -sqrt(
            max(
                0,
                (rx * rx * ry * ry - rx * rx * dy * dy - ry * ry * dx * dx) / (rx * rx * dy * dy + ry * ry * dx * dx)
            )
        )
        let center = CGPoint(
            x: factor * rx * dy / ry + (start.x + end.x) / 2,
            y: -factor * ry * dx / rx + (start.y + end.y) / 2
        )
        let a = atan2((start.y - center.y) / ry, (start.x - center.x) / rx)
        var b = atan2((end.y - center.y) / ry, (end.x - center.x) / rx)
        while b <= a { b += .pi * 2 }
        let transform = CGAffineTransform(a: rx, b: 0, c: 0, d: ry, tx: center.x, ty: center.y)
        path.addArc(center: .zero, radius: 1, startAngle: a, endAngle: b, clockwise: false, transform: transform)
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 187 / 255, alpha: 1))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(2.5)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
        return try BitmapTexture.make(context: context, device: device)
    }
    
    internal func clear() {
        cache = [:]
        cacheOrder = []
        cacheBytes = 0
    }
    
    private struct Key: Hashable {
        internal let text: String
        internal let width: Int
        internal let height: Int
        internal let size: Double
        internal let centered: Bool
        internal let bold: Bool
        internal let color: SIMD4<Float>
        internal let outline: Bool
        internal let alphas: [Float]
        internal let lineHeight: Double?
        internal let singleLine: Bool
        internal let letterSpacing: Double
        internal let runs: [TextRun]
        internal let usesStyleColor: Bool
    }
}
