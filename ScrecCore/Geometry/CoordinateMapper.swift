import CoreGraphics
import Foundation

/// Converts global screen positions into **recording pixels** (top-left origin, `screen.mov` pixel grid).
///
/// Two global coordinate systems exist on macOS:
/// - Core Graphics ("CG"): origin at the top-left of the main display, y grows downwards.
///   Used by `CGEvent.location`, `SCDisplay.frame`, `SCWindow.frame`.
/// - AppKit: origin at the bottom-left of the main display, y grows upwards. Used by `NSEvent.mouseLocation`.
public struct CoordinateMapper: Equatable, Sendable {
    /// Captured area in global CG points.
    public var captureRect: CGRect
    /// Size of the video in pixels.
    public var videoPixelSize: CGSize

    public init(captureRect: CGRect, videoPixelSize: CGSize) {
        self.captureRect = captureRect
        self.videoPixelSize = videoPixelSize
    }

    /// Global CG point → recording pixels. Points outside the capture area are kept (ARCHITECTURE §4.2).
    public func recordingPixels(fromCG p: CGPoint) -> CGPoint {
        guard captureRect.width > 0, captureRect.height > 0 else { return .zero }
        let sx = videoPixelSize.width / captureRect.width
        let sy = videoPixelSize.height / captureRect.height
        return CGPoint(x: (p.x - captureRect.minX) * sx, y: (p.y - captureRect.minY) * sy)
    }

    /// Global CG rect → recording pixels.
    public func recordingPixels(fromCG r: CGRect) -> CGRect {
        let a = recordingPixels(fromCG: CGPoint(x: r.minX, y: r.minY))
        let b = recordingPixels(fromCG: CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// AppKit global point → CG global point. `mainDisplayHeight` is the height of the main display in points.
    public static func cgPoint(fromAppKit p: CGPoint, mainDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: mainDisplayHeight - p.y)
    }
}
