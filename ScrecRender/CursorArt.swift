import CoreGraphics
import Foundation
import ScrecCore

/// Screc's own cursor artwork (SPEC §3.5): six styles, each with shapes for every system cursor type.
/// Drawn as vector paths in a 32-unit design space (y down) and rasterised at the exact pixel size needed,
/// so the cursor stays sharp at any size and zoom.
public enum CursorArt {
    public struct Raster {
        public var image: CGImage
        /// Hotspot in image pixels (top-left origin).
        public var hotspot: CGPoint
    }

    /// Design-space height of every shape.
    static let designHeight: CGFloat = 32

    /// Rasterises `shape` in `style` so that the design height becomes `pixelHeight` pixels.
    public static func raster(style: CursorLook.Style, shape: CursorShape, colorHex: String, pixelHeight: Int) -> Raster? {
        let k = CGFloat(max(pixelHeight, 4)) / designHeight
        let side = Int((designHeight * k).rounded(.up)) + 2
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Flip to a y-down design space.
        ctx.translateBy(x: 1, y: CGFloat(side) - 1)
        ctx.scaleBy(x: k, y: -k)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high

        let colors = palette(style: style, colorHex: colorHex)
        let (path, hotspot) = style == .dot ? dot() : geometry(for: shape, thin: style == .thinArrow)

        // Soft drop shadow under the cursor.
        ctx.saveGState()
        // Shadow offset and blur are in device pixels (not affected by the CTM), so scale them by k.
        ctx.setShadow(offset: CGSize(width: 0, height: -0.8 * k), blur: 2.2 * k, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(path)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.setLineWidth(colors.outlineWidth * 2)
        ctx.setStrokeColor(colors.outline)
        ctx.strokePath()
        ctx.restoreGState()

        // Outline (drawn twice as wide, then the fill covers its inner half).
        ctx.addPath(path)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(colors.outlineWidth * 2)
        ctx.setStrokeColor(colors.outline)
        ctx.strokePath()
        if let fill = colors.fill {
            ctx.addPath(path)
            ctx.setFillColor(fill)
            ctx.fillPath()
        }
        if let inner = colors.innerStroke {
            ctx.addPath(path)
            ctx.setLineWidth(colors.innerStrokeWidth)
            ctx.setStrokeColor(inner)
            ctx.strokePath()
        }
        guard let image = ctx.makeImage() else { return nil }
        return Raster(image: image, hotspot: CGPoint(x: 1 + hotspot.x * k, y: 1 + hotspot.y * k))
    }

    // MARK: Styles

    struct Palette {
        var fill: CGColor?
        var outline: CGColor
        var outlineWidth: CGFloat
        var innerStroke: CGColor?
        var innerStrokeWidth: CGFloat = 0
    }

    static func palette(style: CursorLook.Style, colorHex: String) -> Palette {
        let black = CGColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let c = ColorParsing.srgb(colorHex)
        let custom = CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        switch style {
        case .standardArrow: return Palette(fill: black, outline: white, outlineWidth: 1.4)
        case .outlineArrow: return Palette(fill: nil, outline: white, outlineWidth: 1.2, innerStroke: black, innerStrokeWidth: 1.6)
        case .dot: return Palette(fill: custom, outline: white, outlineWidth: 1.6)
        case .filledColorArrow: return Palette(fill: custom, outline: white, outlineWidth: 1.6)
        case .boldWhiteArrow: return Palette(fill: white, outline: black, outlineWidth: 2.2)
        case .thinArrow: return Palette(fill: black, outline: white, outlineWidth: 1.0)
        }
    }

    // MARK: Shapes (original geometry)

    static func dot() -> (CGPath, CGPoint) {
        (CGPath(ellipseIn: CGRect(x: 9, y: 9, width: 14, height: 14), transform: nil), CGPoint(x: 16, y: 16))
    }

    static func geometry(for shape: CursorShape, thin: Bool) -> (CGPath, CGPoint) {
        switch shape {
        case .arrow, .unknown: return (arrow(thin: thin), CGPoint(x: 3, y: 2))
        case .contextMenu, .dragCopy, .dragLink, .notAllowed:
            let p = CGMutablePath()
            p.addPath(arrow(thin: thin))
            // Small badge at the lower right of the arrow.
            let badge = CGRect(x: 17, y: 19, width: 11, height: 11)
            if shape == .notAllowed {
                p.addEllipse(in: badge)
            } else {
                p.addRoundedRect(in: badge, cornerWidth: 2.5, cornerHeight: 2.5)
            }
            return (p, CGPoint(x: 3, y: 2))
        case .iBeam:
            let p = CGMutablePath()
            p.addRoundedRect(in: CGRect(x: 15, y: 6, width: 2.4, height: 20), cornerWidth: 1, cornerHeight: 1)
            p.addRoundedRect(in: CGRect(x: 11, y: 5, width: 10.4, height: 2.4), cornerWidth: 1.2, cornerHeight: 1.2)
            p.addRoundedRect(in: CGRect(x: 11, y: 24.6, width: 10.4, height: 2.4), cornerWidth: 1.2, cornerHeight: 1.2)
            return (p, CGPoint(x: 16.2, y: 16))
        case .pointingHand:
            let p = CGMutablePath()
            p.addRoundedRect(in: CGRect(x: 11, y: 3, width: 5, height: 16), cornerWidth: 2.5, cornerHeight: 2.5)   // finger
            p.addRoundedRect(in: CGRect(x: 8, y: 13, width: 17, height: 15), cornerWidth: 6, cornerHeight: 6)      // palm
            return (p, CGPoint(x: 13.5, y: 3.5))
        case .openHand, .closedHand:
            let p = CGMutablePath()
            let fingers = shape == .openHand ? 9.0 : 5.0
            for i in 0..<4 {
                let x = 7.5 + Double(i) * 4.4
                p.addRoundedRect(in: CGRect(x: x, y: 13 - fingers, width: 3.8, height: fingers + 6), cornerWidth: 1.9, cornerHeight: 1.9)
            }
            p.addRoundedRect(in: CGRect(x: 7, y: 12, width: 19, height: 15), cornerWidth: 6.5, cornerHeight: 6.5)
            return (p, CGPoint(x: 16, y: 16))
        case .resizeLeftRight, .resizeUpDown:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 3, y: 16))
            p.addLine(to: CGPoint(x: 10, y: 9))
            p.addLine(to: CGPoint(x: 10, y: 13.6))
            p.addLine(to: CGPoint(x: 22, y: 13.6))
            p.addLine(to: CGPoint(x: 22, y: 9))
            p.addLine(to: CGPoint(x: 29, y: 16))
            p.addLine(to: CGPoint(x: 22, y: 23))
            p.addLine(to: CGPoint(x: 22, y: 18.4))
            p.addLine(to: CGPoint(x: 10, y: 18.4))
            p.addLine(to: CGPoint(x: 10, y: 23))
            p.closeSubpath()
            if shape == .resizeUpDown {
                var t = CGAffineTransform(translationX: 16, y: 16).rotated(by: .pi / 2).translatedBy(x: -16, y: -16)
                return (p.copy(using: &t)!, CGPoint(x: 16, y: 16))
            }
            return (p, CGPoint(x: 16, y: 16))
        case .crosshair:
            let p = CGMutablePath()
            p.addRect(CGRect(x: 15, y: 4, width: 2, height: 24))
            p.addRect(CGRect(x: 4, y: 15, width: 24, height: 2))
            return (p, CGPoint(x: 16, y: 16))
        }
    }

    /// The pointer: a tall arrow head with a short tail.
    static func arrow(thin: Bool) -> CGPath {
        let p = CGMutablePath()
        if thin {
            p.move(to: CGPoint(x: 3, y: 2))
            p.addLine(to: CGPoint(x: 3, y: 24))
            p.addLine(to: CGPoint(x: 8, y: 19))
            p.addLine(to: CGPoint(x: 11.5, y: 27))
            p.addLine(to: CGPoint(x: 13.6, y: 26))
            p.addLine(to: CGPoint(x: 10.2, y: 18.2))
            p.addLine(to: CGPoint(x: 17, y: 18.2))
        } else {
            p.move(to: CGPoint(x: 3, y: 2))
            p.addLine(to: CGPoint(x: 3, y: 24.5))
            p.addLine(to: CGPoint(x: 8.6, y: 19.3))
            p.addLine(to: CGPoint(x: 12.4, y: 28))
            p.addLine(to: CGPoint(x: 16.2, y: 26.4))
            p.addLine(to: CGPoint(x: 12.5, y: 18))
            p.addLine(to: CGPoint(x: 19.6, y: 18))
        }
        p.closeSubpath()
        return p
    }
}
