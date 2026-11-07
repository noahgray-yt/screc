import CoreGraphics
import Foundation

/// Everything the compositor needs, computed once per project change (ARCHITECTURE §7):
/// the time map, the layout and the motion tracks. Immutable and `Sendable`, so it can be built off the
/// main thread and shared by preview and export.
public struct PreparedProject: Sendable {
    public let project: Project
    public let timeMap: TimeMap
    public let layout: Layout
    public let cursor: CursorTrack
    public let camera: CameraTrack
    /// Where the screen and the webcam are (Phase 5 camera layouts).
    public let layouts: CameraLayoutTrack
    public let keys: KeyOverlayTrack
    public let captions: CaptionTrack
    public let transcript: Transcript?
    /// Recording pixels per screen point (2 on Retina), used to size the cursor like the real one.
    public let pointPixelScale: Double
    /// False when the take has no position telemetry (then no cursor is drawn).
    public let hasCursorData: Bool

    public init(project: Project, recordingSize: CGSize, pointPixelScale: Double, events: [TelemetryEvent], transcript: Transcript? = nil,
                hasCamera: Bool = false) {
        self.project = project
        self.pointPixelScale = pointPixelScale
        timeMap = TimeMap(slices: project.timeline.slices)
        layout = Layout(recordingSize: recordingSize, look: project.look)
        cursor = CursorTrack(events: events, timeMap: timeMap, slices: project.timeline.slices, look: project.look)
        camera = CameraTrack(zooms: project.zooms, timeMap: timeMap, cursor: cursor, layout: layout, style: project.look.animation.screen,
                             fillFrame: project.look.fillFrame)
        keys = KeyOverlayTrack(events: events, timeMap: timeMap)
        layouts = CameraLayoutTrack(project: project, timeMap: timeMap, layout: layout, cursor: cursor, camera: camera, hasCamera: hasCamera)
        self.transcript = transcript
        captions = CaptionTrack(transcript: transcript, timeMap: timeMap)
        hasCursorData = events.contains { if case .pos = $0 { true } else { false } }
    }

    /// Loads a `.screc` bundle from disk.
    public static func load(bundle: URL) throws -> PreparedProject {
        let info = try RecordingInfo.decode(from: Data(contentsOf: bundle.appendingPathComponent(BundleLayout.recording)))
        let project = try Project.decode(from: Data(contentsOf: bundle.appendingPathComponent(BundleLayout.project)))
        let events = (try? TelemetryCodec.decodeFile(Data(contentsOf: bundle.appendingPathComponent(BundleLayout.events))).events) ?? []
        let size = CGSize(width: info.capture.videoPixelSize[0], height: info.capture.videoPixelSize[1])
        return PreparedProject(project: project, recordingSize: size, pointPixelScale: info.capture.pointPixelScale, events: events,
                               transcript: Transcript.load(bundle: bundle), hasCamera: info.tracks.camera != nil)
    }

    /// The same recording with a changed project (look, zooms, slices): rebuilds what depends on it.
    public func with(project: Project, events: [TelemetryEvent], transcript: Transcript?? = .none) -> PreparedProject {
        PreparedProject(project: project, recordingSize: layout.recordingSize, pointPixelScale: pointPixelScale, events: events,
                        transcript: transcript ?? self.transcript, hasCamera: layouts.hasCamera)
    }
}
