import CoreGraphics
import Foundation

/// Measures how well telemetry lines up with the video (ARCHITECTURE §6.4, REC-14).
///
/// Input: the cursor position found in each video frame of a calibration take (the system cursor is
/// visible in that mode) and the `pos` events. The estimator searches for the time shift `δ` for which
/// `event position at (t + δ)` best matches `video position at t`.
/// A constant spatial offset (the found centroid is not exactly the cursor hotspot) is removed first.
///
/// `δ > 0` means the video shows the cursor where the events put it *later*, i.e. the video is ahead.
/// `δ < 0` means the video lags behind the events.
public enum AlignmentEstimator {
    public struct Sample: Equatable, Sendable {
        public var t: Double
        public var x: Double
        public var y: Double
        public init(t: Double, x: Double, y: Double) {
            self.t = t
            self.x = x
            self.y = y
        }
    }

    public struct Result: Equatable, Sendable {
        /// Best time shift in seconds.
        public var offset: Double
        /// RMS position error (recording pixels) at the best shift, after removing the constant offset.
        public var rmsError: Double
        /// RMS position error at shift 0, for comparison.
        public var rmsErrorAtZero: Double
        /// Constant spatial offset (video centroid − event position).
        public var meanOffset: CGPoint
        /// Number of video samples used.
        public var samplesUsed: Int
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notEnoughSamples(Int)
        case noMotion

        public var description: String {
            switch self {
            case let .notEnoughSamples(n): "only \(n) usable video samples (need ≥ 30)"
            case .noMotion: "the cursor hardly moved; the alignment cannot be measured"
            }
        }
    }

    /// - Parameters:
    ///   - searchRange: largest |δ| tried, in seconds.
    ///   - step: grid step of the search; the minimum is then refined with a parabola.
    public static func estimate(video: [Sample], events: [Sample], searchRange: Double = 0.2,
                                step: Double = 0.0005) throws -> Result {
        let events = events.sorted { $0.t < $1.t }
        guard events.count >= 2 else { throw Failure.notEnoughSamples(0) }

        // Use only video samples whose shifted time stays inside the event range for every δ.
        let lo = events.first!.t + searchRange, hi = events.last!.t - searchRange
        let video = video.filter { $0.t >= lo && $0.t <= hi }
        guard video.count >= 30 else { throw Failure.notEnoughSamples(video.count) }

        let xs = events.map(\.x), ys = events.map(\.y)
        let spread = (xs.max()! - xs.min()!) + (ys.max()! - ys.min()!)
        guard spread > 50 else { throw Failure.noMotion }

        let ts = events.map(\.t)
        func position(at t: Double) -> (Double, Double) {
            // Binary search for the last event at or before t, then interpolate linearly.
            var a = 0, b = ts.count - 1
            while b - a > 1 {
                let m = (a + b) / 2
                if ts[m] <= t { a = m } else { b = m }
            }
            let span = ts[b] - ts[a]
            let w = span > 0 ? min(max((t - ts[a]) / span, 0), 1) : 0
            return (xs[a] + (xs[b] - xs[a]) * w, ys[a] + (ys[b] - ys[a]) * w)
        }

        func cost(_ delta: Double) -> (rms: Double, mean: CGPoint) {
            var dx: [Double] = [], dy: [Double] = []
            dx.reserveCapacity(video.count)
            dy.reserveCapacity(video.count)
            for s in video {
                let (ex, ey) = position(at: s.t + delta)
                dx.append(s.x - ex)
                dy.append(s.y - ey)
            }
            let mx = dx.reduce(0, +) / Double(dx.count), my = dy.reduce(0, +) / Double(dy.count)
            var sum = 0.0
            for i in dx.indices {
                let ex = dx[i] - mx, ey = dy[i] - my
                sum += ex * ex + ey * ey
            }
            return (sqrt(sum / Double(dx.count)), CGPoint(x: mx, y: my))
        }

        let n = Int((searchRange / step).rounded())
        var best = (k: 0, rms: Double.infinity)
        var costs: [Int: Double] = [:]
        for k in -n...n {
            let c = cost(Double(k) * step).rms
            costs[k] = c
            if c < best.rms { best = (k, c) }
        }

        // Parabolic refinement around the grid minimum.
        var offset = Double(best.k) * step
        if let l = costs[best.k - 1], let r = costs[best.k + 1] {
            let denom = l - 2 * best.rms + r
            if denom > 0 { offset += 0.5 * (l - r) / denom * step }
        }
        let final = cost(offset)
        return Result(offset: offset, rmsError: final.rms, rmsErrorAtZero: cost(0).rms,
                      meanOffset: final.mean, samplesUsed: video.count)
    }
}
