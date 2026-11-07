import CoreGraphics
import Foundation

/// Where the recording sits on the canvas (ARCHITECTURE §9.2 pass 1).
///
/// Everything is computed in **normalised canvas coordinates** (0…1 on each axis, top-left origin), so the
/// same layout serves the preview at any window size and the export at any resolution.
public struct Layout: Equatable, Sendable {
    /// Canvas width / height.
    public var canvasAspect: Double
    /// The (cropped) recording on the canvas, normalised.
    public var screenRect: CGRect
    /// Crop rectangle in normalised recording coordinates.
    public var crop: CGRect
    /// Size of the (uncropped) recording in pixels.
    public var recordingSize: CGSize

    /// - Parameters:
    ///   - recordingSize: pixel size of `screen.mov`.
    ///   - look: aspect, crop and padding come from here.
    public init(recordingSize: CGSize, look: Look) {
        self.recordingSize = recordingSize
        let c = look.crop.count == 4 ? CGRect(x: look.crop[0], y: look.crop[1], width: look.crop[2], height: look.crop[3])
                                     : CGRect(x: 0, y: 0, width: 1, height: 1)
        crop = c.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let cw = max(Double(recordingSize.width * crop.width), 1)
        let ch = max(Double(recordingSize.height * crop.height), 1)
        let p = min(max(look.frame.padding, 0), 0.4)

        if let ratio = look.aspect.ratio {
            // Fixed aspect: canvas in arbitrary units with height 1 and width `ratio`.
            canvasAspect = ratio
            let canvasW = ratio, canvasH = 1.0
            let pad = p * min(canvasW, canvasH)
            let availW = max(canvasW - 2 * pad, 1e-6), availH = max(canvasH - 2 * pad, 1e-6)
            let fit = min(availW / cw, availH / ch)
            let w = cw * fit, h = ch * fit
            screenRect = CGRect(x: (canvasW - w) / 2 / canvasW, y: (canvasH - h) / 2 / canvasH,
                                width: w / canvasW, height: h / canvasH)
        } else {
            // Auto: the recording's own aspect plus equal padding on all sides,
            // where the padding is a fraction of the canvas' short side.
            let m = min(cw, ch) / (1 - 2 * p)
            let pad = p * m
            let canvasW = cw + 2 * pad, canvasH = ch + 2 * pad
            canvasAspect = canvasW / canvasH
            screenRect = CGRect(x: pad / canvasW, y: pad / canvasH, width: cw / canvasW, height: ch / canvasH)
        }
    }

    /// Recording pixels → normalised canvas coordinates (used for the cursor and click effects).
    public func canvasPoint(fromRecordingPixels p: CGPoint) -> CGPoint {
        let u = (Double(p.x) / Double(recordingSize.width) - crop.minX) / crop.width
        let v = (Double(p.y) / Double(recordingSize.height) - crop.minY) / crop.height
        return CGPoint(x: screenRect.minX + u * screenRect.width, y: screenRect.minY + v * screenRect.height)
    }

    /// Normalised canvas coordinates → normalised recording coordinates (0…1 of the uncropped recording).
    public func recordingPoint(fromCanvas c: CGPoint) -> CGPoint {
        let u = (c.x - screenRect.minX) / screenRect.width
        let v = (c.y - screenRect.minY) / screenRect.height
        return CGPoint(x: crop.minX + u * crop.width, y: crop.minY + v * crop.height)
    }

    /// Normalised recording coordinates → normalised canvas coordinates.
    public func canvasPoint(fromRecordingNormalized p: CGPoint) -> CGPoint {
        canvasPoint(fromRecordingPixels: CGPoint(x: p.x * recordingSize.width, y: p.y * recordingSize.height))
    }

    /// Output pixel size for a target short side (e.g. 1080), keeping the canvas aspect. Even numbers.
    public func outputSize(shortSide: Int) -> CGSize {
        func even(_ v: Double) -> Double { max(2, (v / 2).rounded() * 2) }
        if canvasAspect >= 1 {
            return CGSize(width: even(Double(shortSide) * canvasAspect), height: Double(shortSide))
        }
        return CGSize(width: Double(shortSide), height: even(Double(shortSide) / canvasAspect))
    }

    /// How many output pixels one "1080p reference pixel" is (corner radius, shadow, inset scale with this).
    public static func referenceScale(outputSize: CGSize) -> Double {
        Double(min(outputSize.width, outputSize.height)) / 1080
    }

    /// Recording pixels per output pixel at zoom 1, i.e. how much detail the recording has to spare.
    public func sourceDensity(outputSize: CGSize) -> Double {
        let screenOutW = Double(screenRect.width * outputSize.width)
        guard screenOutW > 0 else { return 1 }
        return Double(recordingSize.width * crop.width) / screenOutW
    }
}
