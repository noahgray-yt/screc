import CoreGraphics
import CoreText
import Foundation

/// Draws a keyboard-shortcut badge (Phase 5): one light keycap per token on a dark rounded backing,
/// e.g. [⇧][⌘][Z] ×3. Original design; rasterised at the exact pixel size needed.
public enum KeyBadgeArt {
    /// - Parameter keyHeight: keycap height in pixels.
    public static func raster(tokens: [String], repeatCount: Int, keyHeight: Int) -> CGImage? {
        let h = CGFloat(max(keyHeight, 12))
        let font = CTFontCreateUIFontForLanguage(.system, h * 0.52, nil) ?? CTFontCreateWithName("Helvetica" as CFString, h * 0.52, nil)
        let bold = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitBold, .traitBold) ?? font
        func line(_ s: String, color: CGColor) -> CTLine {
            let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): bold,
                                                        .init(kCTForegroundColorAttributeName as String): color]
            return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        }
        let keyText = CGColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let lines = tokens.map { line($0, color: keyText) }
        let widths = lines.map { max(h, CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) + h * 0.5) }
        let countLine = repeatCount > 1 ? line("×\(repeatCount)", color: white) : nil
        let countWidth = countLine.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) + h * 0.3 } ?? 0
        let gap = h * 0.14, pad = h * 0.2
        let width = Int((widths.reduce(0, +) + gap * CGFloat(max(widths.count - 1, 0)) + countWidth + pad * 2).rounded(.up)) + 2
        let height = Int((h + pad * 2).rounded(.up)) + 2

        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setShouldAntialias(true)
        // Backing.
        let backing = CGRect(x: 1, y: 1, width: CGFloat(width - 2), height: CGFloat(height - 2))
        ctx.addPath(CGPath(roundedRect: backing, cornerWidth: h * 0.34, cornerHeight: h * 0.34, transform: nil))
        ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 0.72))
        ctx.fillPath()
        // Keycaps.
        var x = 1 + pad
        let y = 1 + pad
        for (l, w) in zip(lines, widths) {
            let cap = CGRect(x: x, y: y, width: w, height: h)
            ctx.addPath(CGPath(roundedRect: cap, cornerWidth: h * 0.22, cornerHeight: h * 0.22, transform: nil))
            ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1))
            ctx.fillPath()
            // A thin darker base gives the keycap some depth.
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h * 0.1), cornerWidth: h * 0.05, cornerHeight: h * 0.05, transform: nil))
            ctx.setFillColor(CGColor(srgbRed: 0.78, green: 0.78, blue: 0.82, alpha: 1))
            ctx.fillPath()
            let b = CTLineGetBoundsWithOptions(l, .useOpticalBounds)
            ctx.textPosition = CGPoint(x: cap.midX - b.midX, y: cap.midY - b.midY + h * 0.03)
            CTLineDraw(l, ctx)
            x += w + gap
        }
        if let countLine {
            let b = CTLineGetBoundsWithOptions(countLine, .useOpticalBounds)
            ctx.textPosition = CGPoint(x: x - gap + h * 0.2, y: y + h / 2 - b.midY)
            CTLineDraw(countLine, ctx)
        }
        return ctx.makeImage()
    }
}
