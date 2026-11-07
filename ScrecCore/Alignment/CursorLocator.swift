import CoreGraphics
import Foundation

/// Finds the system cursor in a calibration frame (ARCHITECTURE §6.4).
///
/// During calibration the display shows a plain grey window, so every pixel that differs clearly from
/// the background colour belongs to the cursor. The centroid of those pixels is the cursor position
/// (plus a constant offset to the hotspot, which the `AlignmentEstimator` removes).
public enum CursorLocator {
    public struct Found: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var pixelCount: Int
        /// Size of the bounding box of all changed pixels.
        public var extent: CGSize
    }

    /// The cursor is the **largest connected blob** of pixels that differ from the background.
    /// Small separate blobs elsewhere (display corner masks, a stray pixel) are ignored. A blob larger
    /// than `maxExtent` (e.g. a system dialog over the backdrop) makes the frame unusable.
    ///
    /// - Parameters:
    ///   - bgra: BGRA bytes, 8 bits per channel.
    ///   - background: the expected background colour (B, G, R).
    ///   - threshold: minimum difference in any channel to count as "changed".
    ///   - stride: only every `stride`-th pixel in x and y is examined (speed).
    ///   - maxFraction: if more than this fraction of the frame changed, it is not a calibration frame.
    ///   - maxExtent: largest plausible cursor size in pixels.
    /// - Returns: nil if no plausible cursor is found.
    public static func locate(bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                              background: (b: UInt8, g: UInt8, r: UInt8), threshold: Int = 48,
                              stride: Int = 2, maxFraction: Double = 0.02, maxExtent: Double = .infinity) -> Found? {
        let gw = (width + stride - 1) / stride, gh = (height + stride - 1) / stride
        var mask = [Bool](repeating: false, count: gw * gh)
        var changed: [Int] = []
        let bb = Int(background.b), bg = Int(background.g), br = Int(background.r)
        for gy in 0..<gh {
            let row = gy * stride * bytesPerRow
            for gx in 0..<gw {
                let o = row + gx * stride * 4
                let d = max(abs(Int(bgra[o]) - bb), abs(Int(bgra[o + 1]) - bg), abs(Int(bgra[o + 2]) - br))
                if d > threshold {
                    mask[gy * gw + gx] = true
                    changed.append(gy * gw + gx)
                }
            }
        }
        guard changed.count >= 3, Double(changed.count) <= Double(gw * gh) * maxFraction else { return nil }

        // Connected components (8-neighbourhood, bridging 1-cell gaps so a thin outline stays one blob).
        var seen = [Bool](repeating: false, count: gw * gh)
        var best: [Int] = []
        for seed in changed where !seen[seed] {
            var blob: [Int] = []
            var stack = [seed]
            seen[seed] = true
            while let i = stack.popLast() {
                blob.append(i)
                let x = i % gw, y = i / gw
                for dy in -2...2 {
                    for dx in -2...2 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < gw, ny < gh else { continue }
                        let n = ny * gw + nx
                        if mask[n] && !seen[n] {
                            seen[n] = true
                            stack.append(n)
                        }
                    }
                }
            }
            if blob.count > best.count { best = blob }
        }
        guard best.count >= 3 else { return nil }

        var sumX = 0.0, sumY = 0.0
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for i in best {
            let x = (i % gw) * stride, y = (i / gw) * stride
            sumX += Double(x); sumY += Double(y)
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        let extent = CGSize(width: maxX - minX + stride, height: maxY - minY + stride)
        guard Double(extent.width) <= maxExtent, Double(extent.height) <= maxExtent else { return nil }
        return Found(x: sumX / Double(best.count), y: sumY / Double(best.count), pixelCount: best.count, extent: extent)
    }

    /// The most common colour in a coarse sample of the frame (the calibration background).
    public static func dominantColor(bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) -> (b: UInt8, g: UInt8, r: UInt8) {
        var histogram: [UInt32: Int] = [:]
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let o = y * bytesPerRow + x * 4
                // Quantise to 4 bits per channel so encoder noise falls into one bucket.
                let key = (UInt32(bgra[o]) >> 4) << 8 | (UInt32(bgra[o + 1]) >> 4) << 4 | (UInt32(bgra[o + 2]) >> 4)
                histogram[key, default: 0] += 1
                x += 16
            }
            y += 16
        }
        let key = histogram.max { $0.value < $1.value }?.key ?? 0
        func centre(_ q: UInt32) -> UInt8 { UInt8(min(255, Int(q) * 16 + 8)) }
        return (centre((key >> 8) & 0xF), centre((key >> 4) & 0xF), centre(key & 0xF))
    }
}

/// The path the cursor follows during a calibration take: a Lissajous figure.
/// It never repeats exactly within 20 s and changes speed and direction all the time,
/// so the time shift between video and telemetry has a single clear minimum.
public enum CalibrationPath {
    public static let duration: Double = 20

    /// Position at time `t` (seconds), inside `rect` with a 15 % margin.
    public static func position(at t: Double, in rect: CGRect) -> CGPoint {
        let ax = rect.width * 0.35, ay = rect.height * 0.35
        let x = rect.midX + ax * sin(2 * .pi * 0.31 * t + 0.4) * cos(2 * .pi * 0.047 * t)
        let y = rect.midY + ay * sin(2 * .pi * 0.43 * t)
        return CGPoint(x: x, y: y)
    }
}
