import Foundation

/// Screc's own GIF colour reducer (ARCHITECTURE §2, §10): median cut to ≤ 256 colours per frame, then an 8×8
/// ordered (Bayer) dither so smooth gradients (wallpapers, shadows) do not band. Ordered dithering is stable
/// from frame to frame, so still areas do not shimmer the way error diffusion does.
public enum GIFQuantizer {
    public struct Result: Sendable {
        /// RGB palette, 3 bytes per entry, `count ≤ 256`.
        public var palette: [UInt8]
        /// One palette index per pixel.
        public var indices: [UInt8]
        public var colorCount: Int { palette.count / 3 }
    }

    /// - Parameters:
    ///   - rgba: 8-bit RGBA (or BGRA with `bgra: true`), `width * height * 4` bytes, row stride `bytesPerRow`.
    ///   - maxColors: up to 256.
    ///   - dither: strength of the ordered dither in palette steps (0 = off).
    public static func quantize(_ rgba: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int, bgra: Bool = false,
                                maxColors: Int = 256, dither: Double = 0.75) -> Result {
        let ri = bgra ? 2 : 0, bi = bgra ? 0 : 2
        // 1. Histogram on a 5-bit-per-channel grid (32 768 cells): fast and plenty for choosing a palette.
        var histogram = [UInt32](repeating: 0, count: 32_768)
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let o = row + x * 4
                histogram[(Int(rgba[o + ri]) >> 3) << 10 | (Int(rgba[o + 1]) >> 3) << 5 | (Int(rgba[o + bi]) >> 3)] += 1
            }
        }
        // 2. Median cut over the occupied cells.
        struct Cell { var key: Int; var count: UInt32 }
        var cells: [Cell] = []
        cells.reserveCapacity(4096)
        for (k, c) in histogram.enumerated() where c > 0 { cells.append(Cell(key: k, count: c)) }
        func channel(_ key: Int, _ ch: Int) -> Int { ch == 0 ? key >> 10 : ch == 1 ? (key >> 5) & 31 : key & 31 }

        var boxes: [ArraySlice<Cell>] = [cells[...]]
        let target = min(max(maxColors, 2), 256)
        while boxes.count < target {
            // Split the box with the widest channel range (weighted by population).
            var best = -1, bestScore = 0, bestChannel = 0
            for (i, box) in boxes.enumerated() where box.count > 1 {
                for ch in 0..<3 {
                    var lo = 31, hi = 0
                    for c in box { let v = channel(c.key, ch); lo = min(lo, v); hi = max(hi, v) }
                    let score = (hi - lo) * Int(min(box.reduce(0) { $0 + $1.count }, 1 << 20))
                    if hi > lo && score > bestScore { best = i; bestScore = score; bestChannel = ch }
                }
            }
            guard best >= 0 else { break }
            let sorted = boxes[best].sorted { channel($0.key, bestChannel) < channel($1.key, bestChannel) }
            let total = sorted.reduce(UInt32(0)) { $0 + $1.count }
            var acc: UInt32 = 0, split = 1
            for (i, c) in sorted.enumerated() {
                acc += c.count
                if acc * 2 >= total { split = max(1, min(i + 1, sorted.count - 1)); break }
            }
            boxes[best] = sorted[..<split]
            boxes.append(sorted[split...])
        }
        // 3. Palette = population-weighted mean colour of each box (in 8-bit).
        var palette: [UInt8] = []
        for box in boxes {
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for c in box {
                let w = Double(c.count)
                r += Double(channel(c.key, 0) * 8 + 4) * w
                g += Double(channel(c.key, 1) * 8 + 4) * w
                b += Double(channel(c.key, 2) * 8 + 4) * w
                n += w
            }
            palette += [UInt8(min(r / n, 255)), UInt8(min(g / n, 255)), UInt8(min(b / n, 255))]
        }
        // 4. Map every pixel (with the dither offset) to its nearest palette colour, cached per 5-bit cell.
        var cache = [Int16](repeating: -1, count: 32_768)
        func nearest(_ r: Int, _ g: Int, _ b: Int) -> UInt8 {
            let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
            if cache[key] >= 0 { return UInt8(cache[key]) }
            var best = 0, bestD = Int.max
            for i in 0..<(palette.count / 3) {
                let dr = Int(palette[3 * i]) - r, dg = Int(palette[3 * i + 1]) - g, db = Int(palette[3 * i + 2]) - b
                let d = 3 * dr * dr + 4 * dg * dg + 2 * db * db       // a little perceptual weighting
                if d < bestD { bestD = d; best = i }
            }
            cache[key] = Int16(best)
            return UInt8(best)
        }
        let amplitude = dither * 8                                   // ≈ one 5-bit step
        var indices = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let o = row + x * 4
                let d = Int((bayer[(y & 7) * 8 + (x & 7)] - 0.5) * amplitude)
                let r = min(max(Int(rgba[o + ri]) + d, 0), 255)
                let g = min(max(Int(rgba[o + 1]) + d, 0), 255)
                let b = min(max(Int(rgba[o + bi]) + d, 0), 255)
                indices[y * width + x] = nearest(r, g, b)
            }
        }
        return Result(palette: palette, indices: indices)
    }

    /// 8×8 Bayer threshold matrix, values in [0, 1).
    static let bayer: [Double] = {
        let m: [Int] = [0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26, 12, 44, 4, 36, 14, 46, 6, 38,
                        60, 28, 52, 20, 62, 30, 54, 22, 3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
                        15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21]
        return m.map { (Double($0) + 0.5) / 64 }
    }()
}
