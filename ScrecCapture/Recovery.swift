@preconcurrency import AVFoundation
import ScrecCore

/// Rebuilds a take that was interrupted by a crash (REC-06, ARCHITECTURE §6.2).
///
/// The media files were written as fragmented movies, so they are readable up to the last 2-second
/// fragment. Recovery rewrites each file into a normal one (passthrough, no re-encoding), cuts the
/// telemetry to the video length, and finalises `recording.json` and `project.json`.
public enum Recovery {
    public struct Report: Sendable {
        public var bundle: URL
        public var duration: Double
        public var rewrittenFiles: [String]
        public var droppedEvents: Int
    }

    public enum RecoveryError: Error, CustomStringConvertible {
        case noScreenVideo
        public var description: String { "The screen recording in this take is missing or unreadable." }
    }

    public static func recover(bundle: URL) async throws -> Report {
        let fm = FileManager.default
        var rewritten: [String] = []

        // 1. Media files: passthrough rewrite. If that fails the fragmented original stays (still readable).
        for name in [BundleLayout.screen, BundleLayout.camera, BundleLayout.mic, BundleLayout.system] {
            let url = bundle.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            if (try? await rewrite(url)) == true { rewritten.append(name) }
        }

        // 2. Duration from the screen track.
        let screenURL = bundle.appendingPathComponent(BundleLayout.screen)
        guard fm.fileExists(atPath: screenURL.path) else { throw RecoveryError.noScreenVideo }
        let duration = try await AVURLAsset(url: screenURL).load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw RecoveryError.noScreenVideo }

        // 3. Telemetry: drop everything after the end of the video.
        var dropped = 0
        let eventsURL = bundle.appendingPathComponent(BundleLayout.events)
        if let data = try? Data(contentsOf: eventsURL), let decoded = try? TelemetryCodec.decodeFile(data) {
            let kept = decoded.events.filter { $0.t <= duration }
            dropped = decoded.events.count - kept.count
            var text = TelemetryCodec.encode(decoded.header) + "\n"
            for e in kept { text += TelemetryCodec.encode(e) + "\n" }
            try Data(text.utf8).write(to: eventsURL, options: .atomic)
        }

        // 4. recording.json and project.json.
        let infoURL = bundle.appendingPathComponent(BundleLayout.recording)
        var name = bundle.deletingPathExtension().lastPathComponent
        if let data = try? Data(contentsOf: infoURL), var info = try? RecordingInfo.decode(from: data) {
            info.duration = duration
            info.finalised = true
            info.recovered = true
            for (track, file) in [(\RecordingInfo.Tracks.camera, BundleLayout.camera), (\.mic, BundleLayout.mic), (\.system, BundleLayout.system)] {
                if !fm.fileExists(atPath: bundle.appendingPathComponent(file).path) { info.tracks[keyPath: track] = nil }
            }
            name = BundleLayout.projectName(sourceApp: info.sourceApp, date: info.startedAt)
            try info.encoded().write(to: infoURL, options: .atomic)
        }
        let projectURL = bundle.appendingPathComponent(BundleLayout.project)
        if !fm.fileExists(atPath: projectURL.path) {
            try Project.fresh(name: name, duration: duration).encoded().write(to: projectURL, options: .atomic)
        }

        // 5. Done: remove the lock.
        try? fm.removeItem(at: bundle.appendingPathComponent(BundleLayout.lock))
        return Report(bundle: bundle, duration: duration, rewrittenFiles: rewritten, droppedEvents: dropped)
    }

    private static func rewrite(_ url: URL) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        guard try await !asset.load(.tracks).isEmpty,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return false }
        let fileType: AVFileType = url.pathExtension == "m4a" ? .m4a : .mov
        let temp = url.deletingLastPathComponent().appendingPathComponent(".recovering-" + url.lastPathComponent)
        try? FileManager.default.removeItem(at: temp)
        try await export.export(to: temp, as: fileType)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        return true
    }
}
