import AppKit
import ScrecCore
import ScrecExport
import SwiftUI

/// Runs one export and publishes its progress (EX-04).
@MainActor
@Observable
final class ExportController {
    enum State {
        case idle
        case running(Exporter.Progress?)
        case finished(URL)
        case failed(String)
    }

    var state: State = .idle
    var directory: URL = UserDefaults.standard.url(forKey: "exportDirectory") ?? ExportNaming.defaultDirectory {
        didSet { UserDefaults.standard.set(directory, forKey: "exportDirectory") }
    }
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { if case .running = state { true } else { false } }

    func start(prepared: PreparedProject, bundle: URL, settings: ExportSettings) {
        guard !isRunning else { return }
        let dir = directory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            state = .failed("The export folder could not be created: \(error.localizedDescription)")
            return
        }
        let url = ExportNaming.uniqueURL(in: dir, projectName: prepared.project.name, ext: settings.format == .gif ? "gif" : "mp4")
        state = .running(nil)
        task = Task {
            // The export task keeps the controller alive until it ends anyway, so a strong reference is fine.
            let report: Exporter.ProgressHandler = { p in
                Task { @MainActor in
                    if case .running = self.state { self.state = .running(p) }
                }
            }
            do {
                if settings.format == .gif {
                    try await Exporter.exportGIF(prepared, bundle: bundle, settings: settings, to: url, progress: report)
                } else {
                    try await Exporter.exportMP4(prepared, bundle: bundle, settings: settings, to: url, progress: report)
                }
                if settings.writeSRT, settings.format == .mp4, !prepared.captions.lines.isEmpty {
                    try prepared.captions.srt().write(to: url.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
                }
                state = .finished(url)
            } catch {
                state = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        state = .idle
    }

    /// EX-03: the finished file on the clipboard (as a file, so it can be pasted into Finder, Mail, Slack…).
    static func copyToClipboard(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }
}

struct ExportSheet: View {
    @Bindable var model: EditorModel
    @Bindable var controller: ExportController
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var settings: ExportSettings { model.project.export }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.title2.bold())
            switch controller.state {
            case .idle, .failed:
                options
                if case let .failed(message) = controller.state {
                    Text(message).foregroundStyle(.red).font(.callout)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Export") {
                        model.saveNow()
                        controller.start(prepared: model.prepared, bundle: model.bundle, settings: settings)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            case let .running(progress):
                running(progress)
            case let .finished(url):
                finished(url)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    // MARK: Options

    private func set(_ change: @escaping (inout ExportSettings) -> Void) {
        model.edit { change(&$0.export) }
    }

    private var options: some View {
        let size = settings.outputSize(layout: model.prepared.layout)
        let frames = model.prepared.timeMap.frameCount(fps: settings.outputFPS)
        return VStack(alignment: .leading, spacing: 12) {
            Picker("Format", selection: Binding(get: { settings.format }, set: { f in set { $0.format = f } })) {
                Text("MP4 video").tag(ExportSettings.Format.mp4)
                Text("GIF animation").tag(ExportSettings.Format.gif)
            }
            .pickerStyle(.segmented)
            if settings.format == .mp4 {
                Picker("Resolution", selection: Binding(get: { settings.resolution }, set: { r in set { $0.resolution = r } })) {
                    ForEach(ExportSettings.Resolution.allCases, id: \.self) { r in
                        if r == .native {
                            let short = ExportSettings.nativeShortSide(layout: model.prepared.layout)
                            Text("Native (sharpest text, \(short)p)").tag(r)
                        } else {
                            Text(r.rawValue).tag(r)
                        }
                    }
                }
                let rec = model.prepared.layout.recordingSize
                Text("The recording is \(Int(rec.width)) × \(Int(rec.height)). Smaller sizes shrink the screen (text gets softer); "
                     + "larger ones enlarge it without adding detail. Native keeps every recorded pixel.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Frame rate", selection: Binding(get: { settings.fps }, set: { v in set { $0.fps = v } })) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("Codec", selection: Binding(get: { settings.codec }, set: { c in set { $0.codec = c } })) {
                    Text("HEVC (smaller files)").tag(ExportSettings.Codec.hevc)
                    Text("H.264 (plays everywhere)").tag(ExportSettings.Codec.h264)
                }
            } else {
                Picker("Size", selection: Binding(get: { settings.gifShortSide }, set: { v in set { $0.gifShortSide = v } })) {
                    Text("480p").tag(480)
                    Text("720p").tag(720)
                    Text("1080p").tag(1080)
                }
                Picker("Frame rate", selection: Binding(get: { settings.gifFPS }, set: { v in set { $0.gifFPS = v } })) {
                    Text("10 fps").tag(10)
                    Text("15 fps").tag(15)
                    Text("20 fps").tag(20)
                }
                Text("GIFs loop forever. They are much larger than MP4s; keep them short.").font(.caption).foregroundStyle(.secondary)
            }
            if settings.format == .mp4, !model.prepared.captions.lines.isEmpty {
                Toggle("Also save captions as .srt next to the video",
                       isOn: Binding(get: { settings.writeSRT }, set: { v in set { $0.writeSRT = v } }))
            }
            LabeledContent("Output") {
                Text("\(Int(size.width)) × \(Int(size.height)) px · \(TransportFormat.time(model.duration)) · \(frames) frames")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            LabeledContent("Save to") {
                HStack {
                    Text(controller.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Change…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        panel.directoryURL = controller.directory
                        if panel.runModal() == .OK, let url = panel.url { controller.directory = url }
                    }
                }
            }
        }
    }

    // MARK: Progress and result

    private func running(_ p: Exporter.Progress?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: p?.fraction ?? 0)
            HStack {
                Text(p.map { "\($0.framesDone) of \($0.totalFrames) frames" } ?? "Preparing…").monospacedDigit()
                Spacer()
                if let remaining = p?.remaining {
                    Text("about \(TransportFormat.duration(remaining)) left").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            HStack {
                Spacer()
                Button("Cancel Export") { controller.cancel() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func finished(_ url: URL) -> some View {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            Label("Export finished", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)).foregroundStyle(.secondary)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button(copied ? "Copied" : "Copy to Clipboard") {
                    ExportController.copyToClipboard(url)
                    copied = true
                }
                Button("Open") { NSWorkspace.shared.open(url) }
                Spacer()
                Button("Done") {
                    controller.state = .idle
                    copied = false
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

enum TransportFormat {
    static func time(_ t: Double) -> String {
        let cs = Int((t * 100).rounded())
        return String(format: "%d:%02d.%02d", cs / 6000, (cs / 100) % 60, cs % 100)
    }

    static func duration(_ s: Double) -> String {
        s < 60 ? "\(Int(s.rounded())) s" : "\(Int(s) / 60) min \(Int(s) % 60) s"
    }
}
