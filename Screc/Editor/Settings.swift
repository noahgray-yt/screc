import ScrecCore
import SwiftUI

/// One entry per setting (ARCHITECTURE §11): label, synonyms, panel, control and default. The inspectors draw
/// their sliders and toggles from it (with Reset), and ⌘K searches it, so both always use the same names.
struct SettingDescriptor: Identifiable {
    enum Control {
        case slider(WritableKeyPath<Project, Double>, ClosedRange<Double>, format: String, default: Double)
        case toggle(WritableKeyPath<Project, Bool>, default: Bool)
        /// Pickers and other custom controls: ⌘K only opens the panel and highlights them.
        case custom
    }

    let id: String
    let label: String
    let synonyms: [String]
    let panel: EditorModel.Panel
    let control: Control

    @MainActor static let all: [SettingDescriptor] = [
        // Background
        .init(id: "bg.kind", label: "Background type", synonyms: ["wallpaper", "gradient", "color", "image"], panel: .background, control: .custom),
        .init(id: "bg.wallpaper", label: "Wallpaper", synonyms: ["background picture", "pick random"], panel: .background, control: .custom),
        .init(id: "bg.blur", label: "Background blur", synonyms: ["blur wallpaper", "soften background"], panel: .background,
              control: .slider(\.look.background.blur, 0...100, format: "%.0f", default: 0)),
        .init(id: "frame.padding", label: "Padding", synonyms: ["margin", "space around", "inset size"], panel: .background,
              control: .slider(\.look.frame.padding, 0...0.4, format: "%.2f", default: 0.10)),
        .init(id: "frame.corners", label: "Screen rounded corners", synonyms: ["corner radius", "round corners"], panel: .background,
              control: .slider(\.look.frame.cornerRadius, 0...48, format: "%.0f px", default: 12)),
        .init(id: "frame.shadow", label: "Shadow", synonyms: ["drop shadow", "depth"], panel: .background,
              control: .slider(\.look.frame.shadow.amount, 0...1, format: "%.2f", default: 0.5)),
        .init(id: "frame.shadowStyle", label: "Shadow style", synonyms: ["classic shadow", "directional shadow"], panel: .background, control: .custom),
        .init(id: "frame.shadowAngle", label: "Shadow angle", synonyms: ["light direction"], panel: .background,
              control: .slider(\.look.frame.shadow.angle, 0...360, format: "%.0f°", default: 90)),
        .init(id: "frame.shadowDistance", label: "Shadow distance", synonyms: ["shadow offset"], panel: .background,
              control: .slider(\.look.frame.shadow.distance, 0...1, format: "%.2f", default: 0.3)),
        .init(id: "frame.shadowSoftness", label: "Shadow softness", synonyms: ["shadow blur"], panel: .background,
              control: .slider(\.look.frame.shadow.softness, 0...1, format: "%.2f", default: 0.6)),
        .init(id: "frame.inset", label: "Inset", synonyms: ["border", "outline", "edge line"], panel: .background,
              control: .toggle(\.look.frame.inset, default: false)),
        // Cursor
        .init(id: "cursor.size", label: "Cursor size", synonyms: ["pointer size", "mouse size", "bigger cursor"], panel: .cursor,
              control: .slider(\.look.cursor.size, 0.5...4, format: "%.2f×", default: 1.5)),
        .init(id: "cursor.style", label: "Cursor style", synonyms: ["pointer style", "arrow", "dot"], panel: .cursor, control: .custom),
        .init(id: "cursor.alwaysPointer", label: "Always use pointer cursor", synonyms: ["arrow only", "no i-beam"], panel: .cursor,
              control: .toggle(\.look.cursor.alwaysPointer, default: false)),
        .init(id: "cursor.hideIdle", label: "Hide cursor if not moving", synonyms: ["auto hide pointer", "idle"], panel: .cursor,
              control: .toggle(\.look.cursor.hideWhenIdle, default: false)),
        .init(id: "cursor.loop", label: "Loop cursor position", synonyms: ["seamless loop", "return to start"], panel: .cursor,
              control: .toggle(\.look.cursor.loop, default: false)),
        .init(id: "cursor.hidden", label: "Hide cursor", synonyms: ["no cursor", "remove pointer"], panel: .cursor,
              control: .toggle(\.look.cursor.hidden, default: false)),
        .init(id: "cursor.clickEffect", label: "Click effect", synonyms: ["ripple", "circle", "click highlight"], panel: .cursor, control: .custom),
        .init(id: "cursor.clickSound", label: "Click sound", synonyms: ["click noise", "audio click"], panel: .cursor, control: .custom),
        .init(id: "cursor.rotation", label: "Cursor rotation", synonyms: ["tilt", "lean"], panel: .cursor,
              control: .toggle(\.look.cursor.rotation.enabled, default: false)),
        .init(id: "cursor.rotationMax", label: "Rotation amount", synonyms: ["tilt degrees"], panel: .cursor,
              control: .slider(\.look.cursor.rotation.maxDegrees, 1...20, format: "%.0f°", default: 8)),
        // Keyboard shortcuts
        .init(id: "keys.enabled", label: "Show keyboard shortcuts", synonyms: ["key overlay", "keystrokes", "hotkeys on screen"],
              panel: .keyboard, control: .toggle(\.look.keys.enabled, default: false)),
        .init(id: "keys.position", label: "Shortcut overlay position", synonyms: ["keys top", "keys bottom"], panel: .keyboard, control: .custom),
        .init(id: "keys.size", label: "Shortcut overlay size", synonyms: ["bigger keys"], panel: .keyboard, control: .custom),
        // Reframing
        .init(id: "look.fillFrame", label: "Fill the frame (reframe)", synonyms: ["reframe", "reel", "vertical", "crop to fill"],
              panel: .background, control: .toggle(\.look.fillFrame, default: false)),
        // Camera
        .init(id: "webcam.layout", label: "Camera layout", synonyms: ["webcam", "split screen", "picture in picture", "full screen camera"],
              panel: .layout, control: .custom),
        .init(id: "webcam.shape", label: "Camera shape", synonyms: ["circle", "bubble", "rounded"], panel: .camera, control: .custom),
        .init(id: "webcam.corner", label: "Camera corner", synonyms: ["bubble position", "webcam position"], panel: .camera, control: .custom),
        .init(id: "webcam.size", label: "Camera size", synonyms: ["bigger webcam", "bubble size"], panel: .camera, control: .custom),
        .init(id: "webcam.mirror", label: "Mirror camera", synonyms: ["flip webcam"], panel: .camera, control: .toggle(\.look.webcam.mirror, default: true)),
        .init(id: "webcam.avoidCursor", label: "Move camera away from the cursor", synonyms: ["avoid cursor", "dodge"],
              panel: .camera, control: .toggle(\.look.webcam.avoidCursor, default: true)),
        .init(id: "webcam.shadow", label: "Camera shadow", synonyms: ["webcam shadow"], panel: .camera, control: .toggle(\.look.webcam.shadow, default: true)),
        // Voice
        .init(id: "voice.noise", label: "Noise reduction", synonyms: ["denoise", "voice isolation", "background noise", "clean audio"],
              panel: .audio, control: .toggle(\.voice.noiseReduction, default: false)),
        // Music
        .init(id: "music.duckLevel", label: "Music level while talking", synonyms: ["duck amount", "background music", "song", "soundtrack"],
              panel: .audio, control: .custom),
        .init(id: "music.duck", label: "Lower music while talking", synonyms: ["auto-duck", "ducking"],
              panel: .audio, control: .toggle(\.music.duck, default: true)),
        // Captions
        .init(id: "captions.enabled", label: "Show captions", synonyms: ["subtitles", "transcribe", "speech to text"],
              panel: .captions, control: .toggle(\.look.captions.enabled, default: false)),
        .init(id: "captions.style", label: "Caption style", synonyms: ["subtitle style", "highlight words"], panel: .captions, control: .custom),
        .init(id: "captions.font", label: "Caption font", synonyms: ["subtitle font", "typeface"], panel: .captions, control: .custom),
        .init(id: "captions.colors", label: "Caption colors", synonyms: ["subtitle color", "text color", "caption box"], panel: .captions, control: .custom),
        .init(id: "captions.position", label: "Caption position", synonyms: ["subtitles top"], panel: .captions, control: .custom),
        .init(id: "captions.size", label: "Caption size", synonyms: ["bigger subtitles"], panel: .captions, control: .custom),
        .init(id: "captions.srt", label: "Export subtitles (.srt)", synonyms: ["srt", "subrip"], panel: .captions, control: .custom),
        // Animation
        .init(id: "anim.screen", label: "Screen animation style", synonyms: ["zoom style", "focused", "smooth zoom"], panel: .animation, control: .custom),
        .init(id: "anim.cursor", label: "Cursor animation style", synonyms: ["cursor smoothing", "smooth mouse", "rapid"], panel: .animation, control: .custom),
        .init(id: "anim.motionBlur", label: "Motion blur", synonyms: ["blur movement", "shutter"], panel: .animation,
              control: .slider(\.look.animation.motionBlur, 0...100, format: "%.0f", default: 0)),
    ]

    @MainActor static func find(_ id: String) -> SettingDescriptor? { all.first { $0.id == id } }
}

/// A slider or toggle drawn from the settings table, with Reset. Slider drags are one undo step.
struct SettingRow: View {
    @Bindable var model: EditorModel
    let id: String

    var body: some View {
        if let d = SettingDescriptor.find(id) {
            Group {
                switch d.control {
                case let .slider(path, range, format, def):
                    let value = Binding<Double>(get: { model.project[keyPath: path] }, set: { v in model.edit { $0[keyPath: path] = v } })
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(d.label)
                            Spacer()
                            Text(String(format: format, value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
                            Button("Reset") { model.edit { $0[keyPath: path] = def } }
                                .buttonStyle(.link).font(.caption)
                                .disabled(value.wrappedValue == def)
                        }
                        Slider(value: value, in: range) { editing in editing ? model.beginGesture() : model.endGesture() }
                    }
                case let .toggle(path, _):
                    Toggle(d.label, isOn: Binding(get: { model.project[keyPath: path] }, set: { v in model.edit { $0[keyPath: path] = v } }))
                case .custom:
                    EmptyView()
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(model.highlightedSetting == id ? 0.25 : 0)))
            .id(id)
        }
    }
}

/// Highlight wrapper for custom controls, so ⌘K can point at them too.
struct SettingAnchor<Content: View>: View {
    @Bindable var model: EditorModel
    let id: String
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(model.highlightedSetting == id ? 0.25 : 0)))
            .id(id)
    }
}

// MARK: - ⌘K command palette

/// Fuzzy search over every setting (opens its panel and highlights it) and every action (runs it).
struct CommandPalette: View {
    @Bindable var model: EditorModel
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    struct Entry: Identifiable {
        let id: String
        let label: String
        let detail: String
        let synonyms: [String]
        let run: @MainActor () -> Void
    }

    var entries: [Entry] {
        var list: [Entry] = SettingDescriptor.all.map { d in
            Entry(id: d.id, label: d.label, detail: d.panel.title, synonyms: d.synonyms) { [model] in
                model.panel = d.panel
                model.highlightedSetting = d.id
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if model.highlightedSetting == d.id { model.highlightedSetting = nil }
                }
            }
        }
        let m = model
        list += [
            Entry(id: "a.play", label: "Play / Pause", detail: "Action", synonyms: ["start", "stop playback"]) { m.togglePlay() },
            Entry(id: "a.split", label: "Split at current time", detail: "Action · C", synonyms: ["cut", "scissors"]) { m.splitAtPlayhead() },
            Entry(id: "a.undo", label: "Undo", detail: "Action · ⌘Z", synonyms: []) { m.undo() },
            Entry(id: "a.redo", label: "Redo", detail: "Action · ⇧⌘Z", synonyms: []) { m.redo() },
            Entry(id: "a.autozoom", label: "Generate auto-zooms", detail: "Action", synonyms: ["auto zoom", "zoom on clicks", "regenerate zooms"]) { m.regenerateZooms() },
            Entry(id: "a.typing", label: "Speed up all typing", detail: "Action", synonyms: ["fast typing", "skip typing"]) { m.speedUpAllTyping() },
            Entry(id: "a.transcribe", label: "Transcribe voice for captions", detail: "Action", synonyms: ["subtitles", "speech to text"]) {
                m.panel = .captions
                m.selection = nil
                if m.captionModelInstalled { m.transcribe() }
            },
            Entry(id: "a.cleanup", label: "Remove filler words and long pauses", detail: "Action", synonyms: ["clean up", "um", "silence"]) {
                m.cleanUpTranscript(fillers: true, pauses: true, longestPause: 0.4)
            },
            Entry(id: "a.addzoom", label: "Add zoom at playhead", detail: "Action", synonyms: ["new zoom"]) { m.addZoom(atTimeline: m.currentTime) },
            Entry(id: "a.clearzoom", label: "Remove all zooms", detail: "Action", synonyms: ["delete zooms"]) { m.edit { $0.zooms.removeAll() } },
            Entry(id: "a.crop", label: "Crop", detail: "Action", synonyms: ["trim edges", "cut out area"]) { m.isCropping = true },
            Entry(id: "a.waveform", label: "Show audio waveform", detail: "Action", synonyms: ["waveform", "audio"]) { m.showWaveform.toggle() },
            Entry(id: "a.resetcuts", label: "Reset trims and cuts for all slices", detail: "Action", synonyms: ["undo cuts"]) {
                let d = m.recordingDuration
                m.edit { $0.resetAllTrimsAndCuts(recordingDuration: d) }
            },
            Entry(id: "a.next", label: "Next edit point", detail: "Action", synonyms: ["jump forward"]) { m.jump(forward: true) },
            Entry(id: "a.prev", label: "Previous edit point", detail: "Action", synonyms: ["jump back"]) { m.jump(forward: false) },
        ]
        for a in Look.Aspect.allCases {
            list.append(Entry(id: "a.aspect.\(a.rawValue)", label: "Aspect ratio \(a == .auto ? "Auto" : a.rawValue)", detail: "Action",
                              synonyms: [AspectMenu.name(a)]) { m.edit { $0.look.aspect = a } })
        }
        for q in EditorModel.Quality.allCases {
            list.append(Entry(id: "a.quality.\(q.title)", label: "Preview quality \(q.title)", detail: "Action", synonyms: []) { m.quality = q })
        }
        for p in EditorModel.Panel.allCases {
            list.append(Entry(id: "p.\(p.rawValue)", label: "\(p.title) panel", detail: "Panel", synonyms: []) { m.panel = p })
        }
        return list
    }

    var results: [Entry] {
        guard !query.isEmpty else { return Array(entries.prefix(12)) }
        return entries.compactMap { e in FuzzyMatcher.bestScore(query, label: e.label, synonyms: e.synonyms).map { (e, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(12)
            .map(\.0)
    }

    var body: some View {
        let list = results
        VStack(spacing: 0) {
            TextField("Search settings and actions…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($focused)
                .onSubmit { run(list) }
                .onKeyPress(.downArrow) { index = min(index + 1, max(list.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                .onKeyPress(.escape) { model.showPalette = false; return .handled }
                .onChange(of: query) { index = 0 }
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                        HStack {
                            Text(e.label)
                            Spacer()
                            Text(e.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(i == index ? Color.accentColor.opacity(0.25) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            index = i
                            run(list)
                        }
                    }
                    if list.isEmpty { Text("Nothing found").foregroundStyle(.secondary).padding() }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .onAppear { focused = true }
    }

    private func run(_ list: [Entry]) {
        guard list.indices.contains(index) else { return }
        model.showPalette = false
        list[index].run()
    }
}

/// Names for the aspect-ratio menu (SPEC §3.1).
enum AspectMenu {
    static func name(_ a: Look.Aspect) -> String {
        switch a {
        case .auto: "Auto"
        case .wide: "Wide 16:9"
        case .square: "Square 1:1"
        case .classic: "Classic 4:3"
        case .vertical: "Vertical 9:16"
        case .tall: "Tall 3:4"
        case .portrait: "Portrait 4:5"
        }
    }
}
