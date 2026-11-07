import CoreGraphics
import Foundation

/// Export options (SPEC §4), stored in `project.json › export` so the next export starts from the last choice.
public struct ExportSettings: Codable, Equatable, Sendable {
    public enum Format: String, Codable, Sendable, CaseIterable { case mp4, gif }
    public enum Codec: String, Codable, Sendable, CaseIterable { case h264, hevc }
    /// The short side of the video (EX-01: "short side for vertical ratios").
    public enum Resolution: String, Codable, Sendable, CaseIterable {
        /// The screen at exactly 1:1 recording pixels: the sharpest text the recording allows.
        case native = "Native"
        case p720 = "720p", p1080 = "1080p", p2160 = "4K"
        public var shortSide: Int { switch self { case .native, .p1080: 1080; case .p720: 720; case .p2160: 2160 } }
    }

    /// Short side at which the screen (at rest, unzoomed) shows one recording pixel per video pixel.
    public static func nativeShortSide(layout: Layout) -> Int {
        let screenPx = Double(layout.recordingSize.height * layout.crop.height)
        let canvasH = screenPx / max(Double(layout.screenRect.height), 1e-6)
        let short = layout.canvasAspect >= 1 ? canvasH : canvasH * layout.canvasAspect
        // Even, and within what the hardware encoders take (the long side stays ≤ 8192).
        let maxShort = 8192 / max(layout.canvasAspect, 1 / layout.canvasAspect)
        return Int((min(short, maxShort) / 2).rounded(.down)) * 2
    }

    public var format: Format = .mp4
    public var resolution: Resolution = .p1080
    /// 30 or 60.
    public var fps: Int = 60
    public var codec: Codec = .hevc
    /// GIF: short side in pixels (≤ 1080) and frame rate (EX-02, default 15 fps).
    public var gifShortSide: Int = 720
    public var gifFPS: Int = 15
    /// Also save the captions as an .srt with the same name next to the video (when there is a transcript).
    public var writeSRT = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportSettings()
        format = try c.decodeIfPresent(Format.self, forKey: .format) ?? d.format
        resolution = try c.decodeIfPresent(Resolution.self, forKey: .resolution) ?? d.resolution
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? d.fps
        codec = try c.decodeIfPresent(Codec.self, forKey: .codec) ?? d.codec
        gifShortSide = try c.decodeIfPresent(Int.self, forKey: .gifShortSide) ?? d.gifShortSide
        gifFPS = try c.decodeIfPresent(Int.self, forKey: .gifFPS) ?? d.gifFPS
        writeSRT = try c.decodeIfPresent(Bool.self, forKey: .writeSRT) ?? d.writeSRT
    }

    /// Frames per second actually written.
    public var outputFPS: Int { format == .gif ? min(max(gifFPS, 5), 30) : (fps >= 45 ? 60 : 30) }

    /// Pixel size of the output for a layout (even numbers; GIF capped at 1080).
    public func outputSize(layout: Layout) -> CGSize {
        if format == .gif { return layout.outputSize(shortSide: min(max(gifShortSide, 120), 1080)) }
        return layout.outputSize(shortSide: resolution == .native ? Self.nativeShortSide(layout: layout) : resolution.shortSide)
    }

    /// Average video bitrate (bits/s) for the hardware encoder: ≈ 0.13 bit per pixel per frame for H.264,
    /// about 40 % less for HEVC at similar quality.
    public func bitrate(size: CGSize) -> Int {
        let pixelsPerSecond = Double(size.width * size.height) * Double(outputFPS)
        let bpp = codec == .h264 ? 0.13 : 0.08
        return Int(min(pixelsPerSecond * bpp, 120_000_000))
    }
}

public enum ExportNaming {
    /// A file name for the export that does not exist yet in `directory`.
    public static func uniqueURL(in directory: URL, projectName: String, ext: String, fileManager: FileManager = .default) -> URL {
        let base = projectName.replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-")
        var url = directory.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while fileManager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// Default export folder: `~/Movies/Screc/Exports`.
    public static var defaultDirectory: URL { BundleLayout.defaultDirectory.appendingPathComponent("Exports", isDirectory: true) }
}

/// GIF frame timing in hundredths of a second (the only unit GIF has).
public enum GIFTiming {
    /// Delay of frame `k`, chosen so that the sum of the first `n` delays is `round(n · 100 / fps)`.
    public static func delayHundredths(frame k: Int, fps: Int) -> Int {
        let f = Double(max(fps, 1))
        return Int((Double(k + 1) * 100 / f).rounded()) - Int((Double(k) * 100 / f).rounded())
    }
}
