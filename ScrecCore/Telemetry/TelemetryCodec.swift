import Foundation

/// Encodes and decodes `events.jsonl` lines.
///
/// Encoding is hand-written: the sampler writes 120+ lines per second, and a fixed key order
/// (`t`, `type`, …) keeps the file easy to read and diff.
public enum TelemetryCodec {

    // MARK: Encoding

    public static func encode(_ event: TelemetryEvent) -> String {
        switch event {
        case let .pos(t, x, y):
            return #"{"t":\#(time(t)),"type":"pos","x":\#(num(x)),"y":\#(num(y))}"#
        case let .down(t, button, x, y, clickCount):
            return #"{"t":\#(time(t)),"type":"down","button":"\#(button.rawValue)","x":\#(num(x)),"y":\#(num(y)),"clickCount":\#(clickCount)}"#
        case let .up(t, button, x, y):
            return #"{"t":\#(time(t)),"type":"up","button":"\#(button.rawValue)","x":\#(num(x)),"y":\#(num(y))}"#
        case let .scroll(t, dx, dy, x, y):
            return #"{"t":\#(time(t)),"type":"scroll","dx":\#(num(dx)),"dy":\#(num(dy)),"x":\#(num(x)),"y":\#(num(y))}"#
        case let .key(t, phase, keyCode, chars, mods, key):
            let modList = mods.map { "\"\($0)\"" }.joined(separator: ",")
            let keyField = key.map { #","key":\#(jsonString($0))"# } ?? ""
            return #"{"t":\#(time(t)),"type":"key","phase":"\#(phase.rawValue)","keyCode":\#(keyCode),"chars":\#(jsonString(chars)),"mods":[\#(modList)]\#(keyField)}"#
        case let .cursor(t, shape):
            return #"{"t":\#(time(t)),"type":"cursor","shape":"\#(shape.rawValue)"}"#
        case let .frame(t, rect):
            return #"{"t":\#(time(t)),"type":"frame","rect":[\#(rect.map(num).joined(separator: ","))]}"#
        }
    }

    public static func encode(_ header: TelemetryHeader) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding a plain struct of numbers and strings cannot fail.
        return String(decoding: try! encoder.encode(header), as: UTF8.self)
    }

    /// Source time with microsecond precision.
    static func time(_ t: Double) -> String { String(format: "%.6f", t) }

    /// Positions and deltas: 2 decimals is far below one recording pixel.
    static func num(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e9 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }

    static func jsonString(_ s: String) -> String {
        let data = try! JSONEncoder().encode(s)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Decoding

    private struct RawLine: Decodable {
        var type: String
        var t: Double?
        var x: Double?
        var y: Double?
        var button: MouseButton?
        var clickCount: Int?
        var dx: Double?
        var dy: Double?
        var phase: KeyPhase?
        var keyCode: Int?
        var chars: String?
        var mods: [String]?
        var shape: String?
        var rect: [Double]?
        var key: String?
    }

    public enum DecodeError: Error, CustomStringConvertible {
        case missingHeader
        case badLine(number: Int, reason: String)

        public var description: String {
            switch self {
            case .missingHeader: "events.jsonl: the first line is not a header"
            case let .badLine(n, reason): "events.jsonl line \(n): \(reason)"
            }
        }
    }

    /// Decodes a whole file. Unknown event types are skipped (forward compatibility).
    /// A truncated last line (crash while writing) is ignored.
    public static func decodeFile(_ data: Data) throws -> (header: TelemetryHeader, events: [TelemetryEvent]) {
        let decoder = JSONDecoder()
        var header: TelemetryHeader?
        var events: [TelemetryEvent] = []
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for (index, line) in lines.enumerated() {
            let isLast = index == lines.count - 1
            if header == nil {
                guard let h = try? decoder.decode(TelemetryHeader.self, from: Data(line)), h.type == "header" else {
                    throw DecodeError.missingHeader
                }
                header = h
                continue
            }
            let raw: RawLine
            do {
                raw = try decoder.decode(RawLine.self, from: Data(line))
            } catch {
                if isLast { break }
                throw DecodeError.badLine(number: index + 1, reason: "\(error)")
            }
            if let event = try makeEvent(raw, lineNumber: index + 1) { events.append(event) }
        }
        guard let header else { throw DecodeError.missingHeader }
        // Lines from different input sources can arrive slightly out of order; readers sort by time.
        events = events.enumerated().sorted { a, b in
            a.element.t == b.element.t ? a.offset < b.offset : a.element.t < b.element.t
        }.map(\.element)
        return (header, events)
    }

    private static func makeEvent(_ r: RawLine, lineNumber n: Int) throws -> TelemetryEvent? {
        func need<T>(_ v: T?, _ name: String) throws -> T {
            guard let v else { throw DecodeError.badLine(number: n, reason: "missing \"\(name)\"") }
            return v
        }
        let t = try need(r.t, "t")
        switch r.type {
        case "pos":
            return .pos(t: t, x: try need(r.x, "x"), y: try need(r.y, "y"))
        case "down":
            return .down(t: t, button: try need(r.button, "button"), x: try need(r.x, "x"), y: try need(r.y, "y"),
                         clickCount: r.clickCount ?? 1)
        case "up":
            return .up(t: t, button: try need(r.button, "button"), x: try need(r.x, "x"), y: try need(r.y, "y"))
        case "scroll":
            return .scroll(t: t, dx: r.dx ?? 0, dy: r.dy ?? 0, x: try need(r.x, "x"), y: try need(r.y, "y"))
        case "key":
            return .key(t: t, phase: try need(r.phase, "phase"), keyCode: try need(r.keyCode, "keyCode"),
                        chars: r.chars ?? "", mods: r.mods ?? [], key: r.key)
        case "cursor":
            return .cursor(t: t, shape: CursorShape(rawValue: try need(r.shape, "shape")) ?? .unknown)
        case "frame":
            return .frame(t: t, rect: try need(r.rect, "rect"))
        default:
            return nil
        }
    }
}
