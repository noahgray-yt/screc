import Foundation

/// `recording.json`: immutable facts about one take (ARCHITECTURE §4.1).
/// Written when recording starts (`finalised = false`) and rewritten at stop or after recovery.
public struct RecordingInfo: Codable, Equatable, Sendable {
    public enum CaptureKind: String, Codable, Sendable { case display, window, area }

    public struct Capture: Codable, Equatable, Sendable {
        public var kind: CaptureKind
        public var displayID: UInt32
        public var displayPixelSize: [Int]
        public var pointPixelScale: Double
        /// Capture rect in global points (top-left origin) at the start.
        public var contentRectPoints: [Double]
        public var videoPixelSize: [Int]
        public var fps: Int
        public var windowID: UInt32?

        public init(kind: CaptureKind, displayID: UInt32, displayPixelSize: [Int], pointPixelScale: Double,
                    contentRectPoints: [Double], videoPixelSize: [Int], fps: Int, windowID: UInt32? = nil) {
            self.kind = kind
            self.displayID = displayID
            self.displayPixelSize = displayPixelSize
            self.pointPixelScale = pointPixelScale
            self.contentRectPoints = contentRectPoints
            self.videoPixelSize = videoPixelSize
            self.fps = fps
            self.windowID = windowID
        }
    }

    public struct Clock: Codable, Equatable, Sendable {
        public var kind: String = "hostTime"
        public var t0HostSeconds: Double?
        public init(t0HostSeconds: Double?) { self.t0HostSeconds = t0HostSeconds }
    }

    public struct Tracks: Codable, Equatable, Sendable {
        public var screen: String
        public var camera: String?
        public var mic: String?
        public var system: String?
        public init(screen: String = BundleLayout.screen, camera: String? = nil, mic: String? = nil, system: String? = nil) {
            self.screen = screen
            self.camera = camera
            self.mic = mic
            self.system = system
        }
    }

    public struct PauseRecord: Codable, Equatable, Sendable {
        public var atSource: Double
        public var pausedFor: Double
        public init(atSource: Double, pausedFor: Double) {
            self.atSource = atSource
            self.pausedFor = pausedFor
        }
    }

    public var schemaVersion: Int = 1
    public var id: String
    public var startedAt: Date
    public var sourceApp: String
    public var capture: Capture
    public var clock: Clock
    public var tracks: Tracks
    public var pauses: [PauseRecord]
    public var duration: Double?
    public var finalised: Bool
    /// True for alignment-calibration takes (recorded with the system cursor visible).
    public var calibration: Bool?
    /// Set when the take was rebuilt after a crash.
    public var recovered: Bool?
    /// Per-track counters for troubleshooting, e.g. `"mic": {"received": 412, "written": 410, …}`.
    public var diagnostics: [String: [String: Double]]?

    public init(id: String = UUID().uuidString, startedAt: Date, sourceApp: String, capture: Capture,
                tracks: Tracks, calibration: Bool = false) {
        self.id = id
        self.startedAt = startedAt
        self.sourceApp = sourceApp
        self.capture = capture
        self.clock = Clock(t0HostSeconds: nil)
        self.tracks = tracks
        self.pauses = []
        self.duration = nil
        self.finalised = false
        self.calibration = calibration ? true : nil
    }

    public static func decode(from data: Data) throws -> RecordingInfo {
        try JSONCoding.decoder.decode(RecordingInfo.self, from: data)
    }

    public func encoded() throws -> Data {
        try JSONCoding.encoder.encode(self)
    }
}

/// Shared JSON settings for Screc's files: readable, sorted keys, ISO-8601 dates with time zone.
public enum JSONCoding {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(isoFormatter.string(from: date))
        }
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = isoFormatter.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
            }
            return date
        }
        return d
    }

    private static var isoFormatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }
}
