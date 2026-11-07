import CoreGraphics
import Foundation

/// Which timeline block (or block edge) is under the pointer. Pure, so the timeline's mouse handling is testable.
public enum TimelineHitTest {
    public enum Hit: Equatable, Sendable {
        case none
        case body(String)
        case startEdge(String)
        case endEdge(String)

        public var id: String? {
            switch self {
            case .none: nil
            case let .body(id), let .startEdge(id), let .endEdge(id): id
            }
        }

        public var isEdge: Bool {
            switch self {
            case .startEdge, .endEdge: true
            default: false
            }
        }
    }

    /// A block on screen: id and its timeline interval (a zoom across a cut has several spans).
    public struct Span: Equatable, Sendable {
        public let id: String
        public let start: Double
        public let end: Double
        public init(id: String, start: Double, end: Double) {
            self.id = id
            self.start = start
            self.end = end
        }
    }

    /// - Parameters:
    ///   - x: pointer x in track coordinates.
    ///   - inset: x of timeline time 0.
    ///   - pps: points per second.
    ///   - tolerance: how close to an edge counts as the edge.
    /// Edges win over bodies (they are thin); among overlapping blocks the last drawn (topmost) wins.
    /// Blocks too narrow for two edges only offer their end edge (to make them longer) on their right half.
    public static func hit(x: CGFloat, spans: [Span], inset: CGFloat, pps: Double, tolerance: CGFloat = 6) -> Hit {
        for s in spans.reversed() {
            let a = inset + s.start * pps, b = inset + s.end * pps
            guard x >= a - tolerance, x <= b + tolerance else { continue }
            if b - a > 3 * tolerance {
                if abs(x - a) <= tolerance { return .startEdge(s.id) }
                if abs(x - b) <= tolerance { return .endEdge(s.id) }
            } else if abs(x - b) <= tolerance, x > (a + b) / 2 {
                return .endEdge(s.id)
            }
            if x >= a, x <= b { return .body(s.id) }
        }
        return .none
    }
}
