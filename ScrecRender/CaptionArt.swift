import AppKit
import CoreGraphics
import CoreText
import Foundation
import ScrecCore

/// Draws one caption line (Phase 5 item 3) in one of four original styles, wrapped to at most `maxWidth` pixels.
public enum CaptionArt {
    /// - Parameters:
    ///   - textHeight: font size in pixels.
    ///   - activeWord: index of the word being spoken (coloured in the highlight style).
    public static func raster(words: [String], activeWord: Int?, look: CaptionLook, textHeight: Int, maxWidth: Int) -> CGImage? {
        let style = look.style
        let size = CGFloat(max(textHeight, 8)) * (style == .bold ? 1.15 : 1)
        let font = font(look.font, size: size, heavy: style == .bold)
        let text = NSMutableAttributedString()
        let fill = color(look.textColor), accent = color(look.highlightColor)

        // Attributed text, word by word (so the spoken word can get its own colour).
        for (i, w) in words.enumerated() {
            let color = (style == .highlight && i == activeWord) ? accent : fill
            var attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font,
                                                        .init(kCTForegroundColorAttributeName as String): color]
            if style == .bold {
                // Negative stroke width = fill and stroke.
                attrs[.init(kCTStrokeWidthAttributeName as String)] = -3.0
                attrs[.init(kCTStrokeColorAttributeName as String)] = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.9)
            }
            text.append(NSAttributedString(string: (i == 0 ? "" : " ") + w, attributes: attrs))
        }
        let centered = CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                                       value: withUnsafePointer(to: CTTextAlignment.center) { UnsafeRawPointer($0) })], 1)
        text.addAttribute(.init(kCTParagraphStyleAttributeName as String), value: centered, range: NSRange(location: 0, length: text.length))

        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let constraint = CGSize(width: CGFloat(maxWidth), height: .greatestFiniteMagnitude)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)
        let boxed = style == .classic || style == .highlight
        let padX = boxed ? size * 0.6 : size * 0.3
        let padY = boxed ? size * 0.35 : size * 0.25
        let width = Int((fit.width + padX * 2).rounded(.up)) + 2
        let height = Int((fit.height + padY * 2).rounded(.up)) + 2

        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setShouldAntialias(true)
        if boxed, look.boxOpacity > 0 {
            let box = CGRect(x: 1, y: 1, width: CGFloat(width - 2), height: CGFloat(height - 2))
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: size * 0.35, cornerHeight: size * 0.35, transform: nil))
            ctx.setFillColor(color(look.boxColor, alpha: min(max(look.boxOpacity, 0), 1)))
            ctx.fillPath()
        }
        if style == .minimal {
            ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.06), blur: size * 0.35, color: CGColor(gray: 0, alpha: 0.8))
        }
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: padX + 1, y: padY + 1, width: fit.width + 1, height: fit.height + 1), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()
    }

    /// The caption font: a system design or an installed family; the Bold style asks for the heaviest weight.
    /// A family that is not installed falls back to the system font.
    static func font(_ name: String, size: CGFloat, heavy: Bool) -> CTFont {
        let system = NSFont.systemFont(ofSize: size, weight: heavy ? .heavy : .medium)
        let design: NSFontDescriptor.SystemDesign? = switch name {
        case "rounded": .rounded
        case "serif": .serif
        case "mono": .monospaced
        default: nil
        }
        if let design, let d = system.fontDescriptor.withDesign(design), let f = NSFont(descriptor: d, size: size) { return f as CTFont }
        if name != "system", design == nil,
           let f = NSFontManager.shared.font(withFamily: name, traits: heavy ? .boldFontMask : [], weight: heavy ? 11 : 5, size: size) {
            return f as CTFont
        }
        return system as CTFont
    }

    static func color(_ hex: String, alpha: Double = 1) -> CGColor {
        let c = ColorParsing.srgb(hex)
        return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
    }
}
