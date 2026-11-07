import AppKit
import AVFoundation
import ScrecCore
import ScrecRender
import SwiftUI
import UniformTypeIdentifiers

/// The right-hand inspector: the selection's editor (slice, zoom, mask) on top, then the open panel.
struct InspectorView: View {
    @Bindable var model: EditorModel
    /// Width of the inspector column; every panel must fit inside it.
    static let width: CGFloat = 340

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // A selected slice, zoom or mask replaces the panel. Done, Esc, clicking empty space or any icon
                    // in the rail brings the panel back.
                    if let selection = model.selection {
                        switch selection {
                        case let .slice(id): SliceInspector(model: model, sliceID: id)
                        case let .zoom(id): ZoomInspector(model: model, zoomID: id)
                        case let .mask(id): MaskInspector(model: model, maskID: id)
                        case let .audio(id): AudioClipInspector(model: model, clipID: id)
                        case let .layout(id): LayoutInspector(model: model, layoutID: id)
                        }
                        Text("Click an icon on the left or press Esc to go back to \(model.panel.title).")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                    Text(model.panel.title).font(.title3.bold())
                    switch model.panel {
                    case .background: BackgroundPanel(model: model)
                    case .cursor: CursorPanel(model: model)
                    case .animation: AnimationPanel(model: model)
                    case .audio: AudioPanel(model: model)
                    case .camera: CameraPanel(model: model)
                    case .layout: LayoutPanel(model: model)
                    case .captions: CaptionsPanel(model: model)
                    case .transcript: TranscriptPanel(model: model)
                    case .keyboard: KeyboardPanel(model: model)
                    }
                    }
                }
                .padding(14)
                // Everything inside must fit the panel; wide grids shrink instead of spilling over the icon rail.
                .frame(width: InspectorView.width, alignment: .leading)
            }
            .onChange(of: model.highlightedSetting) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

/// Equal-width tabs that always fit the panel (a segmented control does not shrink below its natural width,
/// which clipped the last tab).
struct TabStrip<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [(Value, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title)
                        .font(.callout)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selection == value ? Color.accentColor : .clear))
                        .foregroundStyle(selection == value ? Color.white : Color.primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
    }
}

/// A labelled note for parts that arrive in Phase 5 (owner decision: no controls that do nothing).
struct PhaseFiveNote: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Phase 5").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.2), in: Capsule())
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Background

private struct BackgroundPanel: View {
    @Bindable var model: EditorModel

    var look: Look { model.project.look }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingAnchor(model: model, id: "bg.kind") {
                TabStrip(selection: Binding(get: { look.background.kind }, set: { k in model.edit { $0.look.background.kind = k } }),
                         items: [(.wallpaper, "Wallpaper"), (.gradient, "Gradient"), (.color, "Color"), (.image, "Image")])
            }
            switch look.background.kind {
            case .wallpaper: wallpapers
            case .gradient: gradient
            case .color:
                ColorPicker("Color", selection: hexBinding(\.look.background.color), supportsOpacity: false)
            case .image: image
            }
            Divider()
            SettingRow(model: model, id: "bg.blur")
            SettingRow(model: model, id: "frame.padding")
            SettingRow(model: model, id: "frame.corners")
            SettingRow(model: model, id: "frame.shadow")
            SettingAnchor(model: model, id: "frame.shadowStyle") {
                Picker("Shadow style", selection: Binding(get: { look.frame.shadow.style }, set: { s in model.edit { $0.look.frame.shadow.style = s } })) {
                    Text("Classic").tag(FrameStyle.Shadow.Style.classic)
                    Text("Directional").tag(FrameStyle.Shadow.Style.directional)
                }
                .pickerStyle(.segmented)
            }
            if look.frame.shadow.style == .directional {
                SettingRow(model: model, id: "frame.shadowAngle")
                SettingRow(model: model, id: "frame.shadowDistance")
                SettingRow(model: model, id: "frame.shadowSoftness")
            }
            SettingRow(model: model, id: "frame.inset")
        }
    }

    private var wallpapers: some View {
        SettingAnchor(model: model, id: "bg.wallpaper") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Pick Random") {
                        let others = Wallpapers.all.filter { $0.id != look.background.wallpaper }
                        if let w = others.randomElement() { model.edit { $0.look.background.wallpaper = w.id } }
                    }
                    Spacer()
                }
                let favourites = Wallpapers.all.filter { model.favouriteWallpapers.contains($0.id) }
                if !favourites.isEmpty {
                    Text("★ Favourites").font(.caption.bold()).foregroundStyle(.secondary)
                    grid(favourites)
                }
                ForEach(Wallpaper.Category.allCases, id: \.self) { cat in
                    Text(cat.rawValue).font(.caption.bold()).foregroundStyle(.secondary)
                    grid(Wallpapers.all.filter { $0.category == cat })
                }
                Text("Right-click a wallpaper to add or remove it from favourites.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func grid(_ items: [Wallpaper]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(items) { w in
                WallpaperSwatch(wallpaper: w, selected: look.background.wallpaper == w.id,
                                favourite: model.favouriteWallpapers.contains(w.id))
                    .onTapGesture { model.edit { $0.look.background.wallpaper = w.id } }
                    .contextMenu {
                        if model.favouriteWallpapers.contains(w.id) {
                            Button("Remove from Favourites") { model.favouriteWallpapers.removeAll { $0 == w.id } }
                        } else {
                            Button("Add to Favourites") { model.favouriteWallpapers.append(w.id) }
                        }
                    }
                    .help(w.name)
            }
        }
    }

    private var gradient: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Shape", selection: Binding(get: { look.background.gradient.type }, set: { t in model.edit { $0.look.background.gradient.type = t } })) {
                Text("Linear").tag(Gradient.Kind.linear)
                Text("Radial").tag(Gradient.Kind.radial)
            }
            .pickerStyle(.segmented)
            if look.background.gradient.type == .linear {
                HStack {
                    Text("Angle")
                    Slider(value: Binding(get: { look.background.gradient.angle }, set: { a in model.edit { $0.look.background.gradient.angle = a } }),
                           in: 0...360) { e in e ? model.beginGesture() : model.endGesture() }
                    Text("\(Int(look.background.gradient.angle))°").monospacedDigit().frame(width: 40)
                }
            }
            ForEach(look.background.gradient.stops.indices, id: \.self) { i in
                HStack {
                    ColorPicker("Color \(i + 1)", selection: hexBinding(\.look.background.gradient.stops[i].color), supportsOpacity: false)
                    if look.background.gradient.stops.count > 2 {
                        Button { model.edit { $0.look.background.gradient.stops.remove(at: i) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            if look.background.gradient.stops.count < 4 {
                Button("Add Color") {
                    model.edit { p in
                        var stops = p.look.background.gradient.stops
                        stops.append(Gradient.Stop(color: stops.last?.color ?? "#FFFFFF", location: 1))
                        for k in stops.indices { stops[k].location = Double(k) / Double(stops.count - 1) }
                        p.look.background.gradient.stops = stops
                    }
                }
            }
        }
    }

    private var image: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let name = look.background.image {
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
            Button(look.background.image == nil ? "Choose Image…" : "Replace Image…") { chooseImage() }
            Text("The image is copied into the recording, so it travels with it.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let name = "background.\(ext)"
        let target = model.bundle.appendingPathComponent(name)
        do {
            for old in (try? FileManager.default.contentsOfDirectory(at: model.bundle, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent.hasPrefix("background.") { try? FileManager.default.removeItem(at: old) }
            try FileManager.default.copyItem(at: url, to: target)
            model.edit { $0.look.background.image = name; $0.look.background.kind = .image }
        } catch {
            model.show("The image could not be copied: \(error.localizedDescription)")
        }
    }

    private func hexBinding(_ path: WritableKeyPath<Project, String>) -> Binding<Color> { model.colorBinding(path) }
}

extension EditorModel {
    /// A `#RRGGBB` project value as a SwiftUI colour (for ColorPicker).
    func colorBinding(_ path: WritableKeyPath<Project, String>) -> Binding<Color> {
        let model = self
        return Binding(
            get: {
                let c = ColorParsing.srgb(model.project[keyPath: path])
                return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
            },
            set: { color in
                guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
                let hex = String(format: "#%02X%02X%02X", Int((ns.redComponent * 255).rounded()), Int((ns.greenComponent * 255).rounded()),
                                 Int((ns.blueComponent * 255).rounded()))
                model.edit { $0[keyPath: path] = hex }
            })
    }
}

/// A wallpaper thumbnail drawn with SwiftUI's mesh gradient from the same four colour points.
struct WallpaperSwatch: View {
    let wallpaper: Wallpaper
    let selected: Bool
    let favourite: Bool

    var body: some View {
        let c = wallpaper.points.map { p -> Color in
            let s = ColorParsing.srgb(p.color)
            return Color(.sRGB, red: s.r, green: s.g, blue: s.b)
        }
        // Order the four points into the mesh corners by position.
        let sorted = zip(wallpaper.points, c).sorted { ($0.0.y, $0.0.x) < ($1.0.y, $1.0.x) }.map(\.1)
        MeshGradient(width: 2, height: 2, points: [[0, 0], [1, 0], [0, 1], [1, 1]], colors: sorted)
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
            .overlay(alignment: .topTrailing) {
                if favourite { Text("★").font(.system(size: 9)).foregroundStyle(.white).padding(2) }
            }
    }
}

// MARK: Cursor

private struct CursorPanel: View {
    @Bindable var model: EditorModel
    var cursor: CursorLook { model.project.look.cursor }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingRow(model: model, id: "cursor.size")
            SettingAnchor(model: model, id: "cursor.style") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(CursorLook.Style.allCases, id: \.self) { style in
                        CursorStyleTile(style: style, color: cursor.color, selected: cursor.style == style)
                            .onTapGesture { model.edit { $0.look.cursor.style = style } }
                    }
                }
            }
            if cursor.style == .dot || cursor.style == .filledColorArrow {
                ColorPicker("Cursor color", selection: Binding(
                    get: { let c = ColorParsing.srgb(cursor.color); return Color(.sRGB, red: c.r, green: c.g, blue: c.b) },
                    set: { color in
                        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
                        let hex = String(format: "#%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
                        model.edit { $0.look.cursor.color = hex }
                    }), supportsOpacity: false)
            }
            SettingRow(model: model, id: "cursor.alwaysPointer")
            SettingRow(model: model, id: "cursor.hideIdle")
            SettingRow(model: model, id: "cursor.loop")
            SettingRow(model: model, id: "cursor.hidden")
            SettingAnchor(model: model, id: "cursor.clickEffect") {
                Picker("Click effect", selection: Binding(get: { cursor.clickEffect }, set: { e in model.edit { $0.look.cursor.clickEffect = e } })) {
                    Text("None").tag(CursorLook.ClickEffect.none)
                    Text("Circle").tag(CursorLook.ClickEffect.circle)
                    Text("Ripple").tag(CursorLook.ClickEffect.ripple)
                }
                .pickerStyle(.segmented)
            }
            SettingAnchor(model: model, id: "cursor.clickSound") {
                HStack {
                    Picker("Click sound", selection: Binding(get: { cursor.clickSound }, set: { s in model.edit { $0.look.cursor.clickSound = s } })) {
                        Text("None").tag(CursorLook.ClickSound.none)
                        Text("Soft").tag(CursorLook.ClickSound.soft)
                        Text("Crisp").tag(CursorLook.ClickSound.crisp)
                    }
                    Button { SoundPreview.play(cursor.clickSound) } label: { Image(systemName: "speaker.wave.2") }
                        .buttonStyle(.borderless).disabled(cursor.clickSound == .none).help("Listen")
                }
            }
            DisclosureGroup("Rotation") {
                SettingRow(model: model, id: "cursor.rotation")
                if cursor.rotation.enabled { SettingRow(model: model, id: "cursor.rotationMax") }
            }
            DisclosureGroup("Advanced") {
                Toggle("Own smoothing (instead of the Animation panel style)", isOn: Binding(
                    get: { cursor.smoothingOverride != nil },
                    set: { on in model.edit { $0.look.cursor.smoothingOverride = on ? 13 : nil } }))
                if let omega = cursor.smoothingOverride {
                    HStack {
                        Text("Lag")
                        // Shown as lag (2/ω) because that is what you see: how far the cursor trails behind.
                        Slider(value: Binding(get: { 2000 / omega }, set: { ms in model.edit { $0.look.cursor.smoothingOverride = 2000 / ms } }),
                               in: 20...400) { e in e ? model.beginGesture() : model.endGesture() }
                        Text("\(Int(2000 / omega)) ms").monospacedDigit().frame(width: 54)
                    }
                }
            }
        }
    }
}

private struct CursorStyleTile: View {
    let style: CursorLook.Style
    let color: String
    let selected: Bool

    var body: some View {
        VStack(spacing: 4) {
            if let r = CursorArt.raster(style: style, shape: .arrow, colorHex: color, pixelHeight: 64) {
                Image(nsImage: NSImage(cgImage: r.image, size: NSSize(width: 32, height: 32)))
            }
            Text(Self.name(style)).font(.caption2).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
    }

    static func name(_ s: CursorLook.Style) -> String {
        switch s {
        case .standardArrow: "Standard"
        case .outlineArrow: "Outline"
        case .dot: "Dot"
        case .filledColorArrow: "Color"
        case .boldWhiteArrow: "Bold white"
        case .thinArrow: "Thin"
        }
    }
}

/// Plays a click sound from the synthesised samples (no file needed).
@MainActor
enum SoundPreview {
    private static var sound: NSSound?

    static func play(_ s: CursorLook.ClickSound) {
        let samples = ClickSounds.samples(s)
        guard !samples.isEmpty else { return }
        var data = Data()
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let pcm = samples.map { Int16(max(min($0, 1), -1) * 32_000) }
        data.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + pcm.count * 2)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(48_000)); le(UInt32(96_000))
        le(UInt16(2)); le(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); le(UInt32(pcm.count * 2))
        for v in pcm { le(v) }
        sound = NSSound(data: data)
        sound?.play()
    }
}

// MARK: Keyboard shortcuts (Phase 5)

private struct KeyboardPanel: View {
    @Bindable var model: EditorModel
    var keys: KeyOverlayLook { model.project.look.keys }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingRow(model: model, id: "keys.enabled")
            Text("Shows key combinations with ⌘, ⌃ or ⌥, and special keys like Return, Delete, Esc or the arrows. Normal typing is never shown.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SettingAnchor(model: model, id: "keys.position") {
                TabStrip(selection: Binding(get: { keys.position }, set: { v in model.edit { $0.look.keys.position = v } }),
                         items: [(.bottom, "Bottom"), (.top, "Top")])
            }
            SettingAnchor(model: model, id: "keys.size") {
                TabStrip(selection: Binding(get: { keys.size }, set: { v in model.edit { $0.look.keys.size = v } }),
                         items: [(.small, "Small"), (.medium, "Medium"), (.large, "Large")])
            }
            Divider()
            TypingSection(model: model)
            Divider()
            let items = model.prepared.keys.items
            if items.isEmpty {
                Text("No shortcuts were pressed in this recording.").foregroundStyle(.secondary)
            } else {
                Text("\(items.count) shortcut\(items.count == 1 ? "" : "s") in this recording. Click one to jump there.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(items.prefix(30).enumerated()), id: \.offset) { _, item in
                    Button {
                        Task { await model.seek(to: item.start) }
                    } label: {
                        HStack {
                            Text(item.tokens.joined(separator: " ") + (item.repeatCount > 1 ? "  ×\(item.repeatCount)" : ""))
                                .font(.body.monospaced())
                            Spacer()
                            Text(TransportFormat.time(item.start)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: Transcript (Phase 5)

private struct TranscriptPanel: View {
    @Bindable var model: EditorModel
    @State private var removeFillers = true
    @State private var shortenPauses = true
    @State private var longestPause = 0.4

    var body: some View {
        if let t = model.transcript {
            let map = model.prepared.timeMap
            VStack(alignment: .leading, spacing: 10) {
                cleanUp(t, map: map)
                Divider()
                Text("Click a word to jump there, Shift-click to select more, then press ⌫ to cut it from the video. "
                     + "Click a crossed-out word to bring it back. ⌘Z undoes.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let sel = model.wordSelection {
                    HStack {
                        Text("\(sel.count) word\(sel.count == 1 ? "" : "s") selected").font(.callout)
                        Spacer()
                        Button("Clear") { model.wordSelection = nil }.buttonStyle(.link)
                        Button("Delete ⌫") { model.deleteSelectedWords() }
                    }
                }
                words(t, map: map)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("There is no transcript yet. Transcribe the voice in the Captions panel; then you can edit the video by deleting words here.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Captions") { model.panel = .captions }
            }
        }
    }

    @ViewBuilder func cleanUp(_ t: Transcript, map: TimeMap) -> some View {
        let fillers = TranscriptEdit.fillerRuns(in: t, timeMap: map).reduce(0) { $0 + $1.count }
        let pauses = TranscriptEdit.longPauses(in: t, timeMap: map, events: model.events, minimum: longestPause + 0.1, keep: longestPause)
        let saves = pauses.reduce(0) { $0 + $1.saves }
        VStack(alignment: .leading, spacing: 6) {
            Text("Clean up").font(.headline)
            Toggle("Remove filler words and sounds (\(fillers))", isOn: $removeFillers)
            Text("Sounds are noises without a word, often um, äh or a breath; they show as (sound) below.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle(String(format: "Shorten pauses (%d found, saves %.1f s)", pauses.count, saves), isOn: $shortenPauses)
            HStack {
                Text("Longest pause")
                Slider(value: $longestPause, in: 0.1...1.5, step: 0.05)
                Text(String(format: "%.2f s", longestPause)).monospacedDigit().frame(width: 52, alignment: .trailing)
            }
            .disabled(!shortenPauses)
            Text(String(format: "Every silence longer than %.2f s becomes %.2f s. Pauses where you clicked or typed are kept.", longestPause + 0.1, longestPause))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Clean Up") { model.cleanUpTranscript(fillers: removeFillers, pauses: shortenPauses, longestPause: longestPause) }
                .disabled((!removeFillers || fillers == 0) && (!shortenPauses || pauses.isEmpty))
        }
    }

    /// Words in paragraphs (a new paragraph after a silence over 1.5 s).
    @ViewBuilder func words(_ t: Transcript, map: TimeMap) -> some View {
        let source = map.toSource(model.currentTime)
        let playing = t.words.firstIndex { $0.start <= source && source < $0.end }
        let paragraphs: [Range<Int>] = {
            var out: [Range<Int>] = []
            var start = 0
            for i in t.words.indices.dropFirst() where t.words[i].start - t.words[i - 1].end > 1.5 {
                out.append(start..<i)
                start = i
            }
            if start < t.words.count { out.append(start..<t.words.count) }
            return out
        }()
        ForEach(paragraphs, id: \.lowerBound) { p in
            FlowLayout(spacing: 3) {
                ForEach(p, id: \.self) { i in
                    WordChip(text: t.words[i].isSound ? "(sound)" : t.words[i].text, visible: TranscriptEdit.isVisible(t.words[i], timeMap: map),
                             selected: model.wordSelection?.contains(i) ?? false, playing: i == playing,
                             filler: t.words[i].isSound || TranscriptEdit.isFiller(t.words[i].text)) {
                        if TranscriptEdit.isVisible(t.words[i], timeMap: map) {
                            model.selectWord(i, extend: NSEvent.modifierFlags.contains(.shift))
                        } else {
                            model.restoreWords(around: i)
                        }
                    }
                }
            }
        }
    }
}

private struct WordChip: View {
    let text: String
    let visible: Bool
    let selected: Bool
    let playing: Bool
    let filler: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .strikethrough(!visible)
                .foregroundStyle(!visible ? Color.secondary.opacity(0.6) : selected ? .white : filler ? .orange : playing ? Color.accentColor : .primary)
                .padding(.horizontal, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Color.accentColor : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(visible ? "" : "Cut. Click to bring it back.")
    }
}

/// Lays children out left to right and wraps to the next row (word flow).
struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + size.width
            r.height = max(r.height, size.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}

// MARK: Captions (Phase 5)

private struct CaptionsPanel: View {
    @Bindable var model: EditorModel
    var captions: CaptionLook { model.project.look.captions }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if #available(macOS 26, *) {
                speech
            } else {
                Text("Captions need macOS 26 or newer (Apple's on-device speech recognition).")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.transcript != nil {
                Divider()
                SettingRow(model: model, id: "captions.enabled")
                SettingAnchor(model: model, id: "captions.style") {
                    TabStrip(selection: Binding(get: { captions.style }, set: { v in model.edit { $0.look.captions.style = v } }),
                             items: [(.classic, "Classic"), (.bold, "Bold"), (.highlight, "Highlight"), (.minimal, "Minimal")])
                }
                Text(styleNote).font(.caption).foregroundStyle(.secondary)
                SettingAnchor(model: model, id: "captions.font") {
                    LabeledContent("Font") { CaptionFontMenu(model: model) }
                }
                SettingAnchor(model: model, id: "captions.colors") {
                    VStack(alignment: .leading, spacing: 6) {
                        ColorPicker("Text color", selection: model.colorBinding(\.look.captions.textColor), supportsOpacity: false)
                        if captions.style == .highlight {
                            ColorPicker("Spoken word color", selection: model.colorBinding(\.look.captions.highlightColor), supportsOpacity: false)
                        }
                        if captions.style == .classic || captions.style == .highlight {
                            ColorPicker("Box color", selection: model.colorBinding(\.look.captions.boxColor), supportsOpacity: false)
                            HStack {
                                Text("Box opacity")
                                Slider(value: Binding(get: { captions.boxOpacity }, set: { v in model.edit { $0.look.captions.boxOpacity = v } }),
                                       in: 0...1, onEditingChanged: { $0 ? model.beginGesture() : model.endGesture() })
                                Text("\(Int(captions.boxOpacity * 100)) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                            }
                        }
                        Button("Reset Font and Colors") {
                            model.edit { p in
                                let d = CaptionLook()
                                p.look.captions.font = d.font
                                p.look.captions.textColor = d.textColor
                                p.look.captions.highlightColor = d.highlightColor
                                p.look.captions.boxColor = d.boxColor
                                p.look.captions.boxOpacity = d.boxOpacity
                            }
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
                SettingAnchor(model: model, id: "captions.position") {
                    TabStrip(selection: Binding<CaptionLook.Position?>(get: { captions.center == nil ? captions.position : nil },
                                                                       set: { v in model.edit { $0.look.captions.position = v ?? .bottom; $0.look.captions.center = nil } }),
                             items: [(.bottom, "Bottom"), (.top, "Top")])
                }
                if captions.center != nil {
                    HStack {
                        Text("Placed by hand on the canvas.").font(.caption).foregroundStyle(.secondary)
                        Button("Reset") { model.edit { $0.look.captions.center = nil } }.buttonStyle(.link).font(.caption)
                    }
                } else {
                    Text("Or drag the caption on the canvas to place it anywhere.").font(.caption).foregroundStyle(.secondary)
                }
                SettingAnchor(model: model, id: "captions.size") {
                    TabStrip(selection: Binding(get: { captions.size }, set: { v in model.edit { $0.look.captions.size = v } }),
                             items: [(.small, "Small"), (.medium, "Medium"), (.large, "Large")])
                }
                SettingAnchor(model: model, id: "captions.srt") {
                    Button("Export .srt…") { model.exportSRT() }.disabled(model.prepared.captions.lines.isEmpty)
                }
                Text("The .srt follows your edits: cut parts are left out and sped-up parts are retimed.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                lines
            }
        }
        .task { await model.loadCaptionLanguages() }
    }

    var styleNote: String {
        switch captions.style {
        case .classic: "White text on a dark box."
        case .bold: "Large heavy text with an outline, no box."
        case .highlight: "Like Classic; the word being spoken gets its own color."
        case .minimal: "Small text with a soft shadow."
        }
    }

    @available(macOS 26, *)
    @ViewBuilder var speech: some View {
        Text("Screc turns your voice into text on this Mac; the audio never leaves it.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if model.captionLanguages.isEmpty {
            ProgressView().controlSize(.small)
        } else {
            Picker("Language", selection: $model.captionLanguage) {
                ForEach(model.captionLanguages, id: \.id) { Text($0.name).tag($0.id) }
            }
            .disabled(model.speechJob != .idle)
            switch model.speechJob {
            case let .downloading(p):
                ProgressView(value: p) { Text("Downloading the speech model… \(Int(p * 100)) %").font(.caption) }
            case .transcribing:
                HStack { ProgressView().controlSize(.small); Text("Transcribing…").font(.caption) }
            case .checking:
                ProgressView().controlSize(.small)
            case .idle:
                if !model.captionModelInstalled {
                    Text("The speech model for this language is not on this Mac yet. It is a one-time download from Apple.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Download Speech Model") { model.downloadCaptionModel() }
                } else {
                    Button(model.transcript == nil ? "Transcribe" : "Transcribe Again") { model.transcribe() }
                    if model.transcript != nil {
                        Text("Transcribing again replaces your text corrections.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder var lines: some View {
        let lines = model.prepared.captions.lines
        if lines.isEmpty {
            Text("No speech in the edited timeline.").foregroundStyle(.secondary)
        } else {
            Text("\(lines.count) lines. Click a time to jump there; edit the text and press Return to fix a line.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let active = model.prepared.captions.active(at: model.currentTime)?.lineIndex
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                CaptionLineRow(model: model, line: line, isActive: i == active)
            }
        }
    }
}

private struct CaptionLineRow: View {
    let model: EditorModel
    let line: CaptionTrack.Line
    let isActive: Bool
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button(TransportFormat.time(line.start)) { Task { await model.seek(to: line.start) } }
                .buttonStyle(.plain).monospacedDigit().font(.caption)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($editing)
                // Return saves and leaves the field (so Space and C work on the timeline again); Esc undoes the typing.
                .onSubmit { finish() }
                .onExitCommand {
                    text = line.text
                    finish()
                }
                .onChange(of: editing) { _, now in if !now { model.correctCaption(line: line, text: text) } }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 5).fill(editing ? Color.accentColor.opacity(0.22) : isActive ? Color.accentColor.opacity(0.12) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: editing ? 1.5 : 0))
        .onAppear { text = line.text }
        .onChange(of: line.text) { _, new in text = new }
    }

    private func finish() {
        model.correctCaption(line: line, text: text)
        editing = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

/// System designs first, a few common families, then every installed family.
private struct CaptionFontMenu: View {
    let model: EditorModel
    static let designs: [(String, String)] = [("system", "System"), ("rounded", "Rounded"), ("serif", "Serif"), ("mono", "Monospaced")]
    static let favourites = ["Avenir Next", "Futura", "Helvetica Neue", "Gill Sans", "Georgia", "American Typewriter", "Marker Felt"]

    var current: String { model.project.look.captions.font }

    var body: some View {
        let installed = NSFontManager.shared.availableFontFamilies
        Menu(Self.designs.first { $0.0 == current }?.1 ?? current) {
            ForEach(Self.designs, id: \.0) { id, title in item(id, title) }
            Divider()
            ForEach(Self.favourites.filter(installed.contains), id: \.self) { item($0, $0) }
            Divider()
            Menu("All Fonts") {
                ForEach(installed.filter { !$0.hasPrefix(".") }, id: \.self) { item($0, $0) }
            }
        }
        .fixedSize()
    }

    func item(_ id: String, _ title: String) -> some View {
        Button { model.edit { $0.look.captions.font = id } } label: {
            if id == current { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

/// Speed-up typing (Phase 5): long typing stretches with a suggested speed.
private struct TypingSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speed up typing").font(.headline)
            if model.typingStretches.isEmpty {
                Text("No long typing stretches in this recording (at least 3 s and 10 keys).").font(.caption).foregroundStyle(.secondary)
            } else {
                let saved = model.typingStretches.filter { model.currentSpeed(of: $0) == 1 }
                    .reduce(0.0) { $0 + $1.duration * (1 - 1 / $1.suggestedSpeed) }
                Text(saved > 0.05 ? "Speeding up all typing saves about \(String(format: "%.1f", saved)) s." : "All typing is sped up.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(model.typingStretches.enumerated()), id: \.offset) { _, stretch in
                    let current = model.currentSpeed(of: stretch)
                    HStack {
                        Button {
                            if let t = model.prepared.timeMap.toTimeline(stretch.sourceStart) { Task { await model.seek(to: t) } }
                        } label: {
                            Text(String(format: "%.1f s, %d keys", stretch.duration, stretch.keyCount)).monospacedDigit()
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if current == 1 {
                            Button("Apply \(SliceBlockLabel.speed(stretch.suggestedSpeed))×") { model.speedUp(stretch) }
                        } else {
                            Text("\(SliceBlockLabel.speed(current))×").foregroundStyle(.secondary)
                            Button("Undo") { model.speedUp(stretch, speed: 1) }.buttonStyle(.link)
                        }
                    }
                }
                Button("Speed Up All Typing") { model.speedUpAllTyping() }
                    .disabled(model.typingStretches.allSatisfy { model.currentSpeed(of: $0) != 1 })
            }
        }
    }
}

// MARK: Animation, Audio, Camera

private struct AnimationPanel: View {
    @Bindable var model: EditorModel
    var anim: AnimationLook { model.project.look.animation }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingAnchor(model: model, id: "anim.screen") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Screen animation style")
                        Spacer()
                        Button("Reset") { model.edit { $0.look.animation.screen = .focused } }
                            .buttonStyle(.link).font(.caption).disabled(anim.screen == .focused)
                    }
                    Picker("", selection: Binding(get: { anim.screen }, set: { s in model.edit { $0.look.animation.screen = s } })) {
                        Text("Focused").tag(AnimationLook.Screen.focused)
                        Text("Smooth").tag(AnimationLook.Screen.smooth)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text(anim.screen == .focused ? "Snappy zooms (≈ 0.55 s), built for readable content."
                                                 : "More fluid zooms (≈ 1 s), less focused on reading.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingAnchor(model: model, id: "anim.cursor") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cursor animation style")
                    Picker("", selection: Binding(get: { anim.cursor }, set: { c in model.edit { $0.look.animation.cursor = c } })) {
                        Text("Smooth").tag(AnimationLook.Cursor.smooth)
                        Text("Medium").tag(AnimationLook.Cursor.medium)
                        Text("Rapid").tag(AnimationLook.Cursor.rapid)
                        Text("None").tag(AnimationLook.Cursor.none)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    if let omega = anim.cursor.omega {
                        Text("The cursor trails \(Int((2000 / omega).rounded())) ms behind the real path.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            SettingRow(model: model, id: "anim.motionBlur")
        }
    }
}

private struct AudioPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.info.tracks.mic != nil {
                volume("Microphone", \.micVolume)
            }
            if model.info.tracks.system != nil {
                volume("System audio", \.systemVolume)
            }
            if model.info.tracks.mic == nil && model.info.tracks.system == nil {
                Text("This recording has no microphone or system audio.").foregroundStyle(.secondary)
            }
            Text("Sets the volume for all slices. For one slice only, right-click it in the timeline.")
                .font(.caption).foregroundStyle(.secondary)
            if model.info.tracks.mic != nil {
                Divider()
                VoiceSection(model: model)
            }
            Divider()
            MusicSection(model: model)
        }
    }

    private func volume(_ title: String, _ path: WritableKeyPath<Slice, Double>) -> some View {
        let value: Double = model.project.timeline.slices.first.map { $0[keyPath: path] } ?? 1
        let mixed = Set(model.project.timeline.slices.map { $0[keyPath: path] }).count > 1
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(mixed ? "mixed" : "\(Int((value * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: { v in
                model.edit { p in for i in p.timeline.slices.indices { p.timeline.slices[i][keyPath: path] = v } }
            }), in: 0...2) { e in e ? model.beginGesture() : model.endGesture() }
        }
    }
}

/// Voice (Phase 5): Standard or noise reduction with Apple's Voice Isolation.
private struct VoiceSection: View {
    @Bindable var model: EditorModel
    var voice: VoiceSettings { model.project.voice }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Voice").font(.headline)
            if VoiceCleaner.isAvailable {
                SettingAnchor(model: model, id: "voice.noise") {
                    TabStrip(selection: Binding(get: { voice.noiseReduction }, set: { v in model.edit { $0.voice.noiseReduction = v } }),
                             items: [(false, "Standard"), (true, "Noise reduction")])
                }
                if voice.noiseReduction {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Strength")
                            Spacer()
                            Text("\(Int((voice.amount * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { voice.amount }, set: { v in model.edit { $0.voice.amount = v } }), in: 0...1) { e in
                            e ? model.beginGesture() : model.endGesture()
                        }
                    }
                }
                Text(voice.noiseReduction
                     ? "Removes background noise, hum and keyboard sounds from the microphone with Apple's Voice Isolation, on this Mac. Your recording file stays unchanged."
                     : "The microphone as recorded.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Noise reduction needs Apple's Voice Isolation, which this Mac does not have.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Music and sounds (Phase 5): the owner's tracks from ~/Music/ScrecTracks, added to the Music or Sounds lane.
private struct MusicSection: View {
    @Bindable var model: EditorModel
    @State private var tracks: [MusicLibrary.Track] = []
    @State private var genre: String?
    @State private var player = PreviewPlayer()

    var music: BackgroundMusic { model.project.music }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Music and sounds").font(.headline)
            Text("♪ adds a track to the Music lane (the whole video when the lane is empty, else from the playhead). "
                 + "🔊 adds it once as a sound at the playhead. Click a clip in the timeline to change, split or delete it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SettingRow(model: model, id: "music.duck")
            if music.duck {
                SettingAnchor(model: model, id: "music.duckLevel") {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Music while you talk")
                            Spacer()
                            Text("\(Int((music.duckLevel * 100).rounded())) %").monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { music.duckLevel }, set: { v in model.edit { $0.music.duckLevel = v } }), in: 0...1) { e in
                            e ? model.beginGesture() : model.endGesture()
                        }
                    }
                }
            }
            Divider()
            library
        }
        .onAppear { tracks = MusicLibrary.scan() }
        .onDisappear { player.stop() }
    }

    @ViewBuilder var library: some View {
        let genres = tracks.reduce(into: [String]()) { if !$0.contains($1.genre) { $0.append($1.genre) } }
        if tracks.isEmpty {
            Text("Put your own music files into ~/Music/ScrecTracks. Subfolders are genres (Lo-Fi, Commercial, Electronic, Instrumental).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            FlowLayout(spacing: 4) {
                chip("All", selected: genre == nil) { genre = nil }
                ForEach(genres, id: \.self) { g in chip(g, selected: genre == g) { genre = g } }
            }
            ForEach(tracks.filter { genre == nil || $0.genre == genre }) { t in
                HStack(spacing: 6) {
                    Button { player.toggle(t.url) } label: {
                        Image(systemName: player.playing == t.url ? "stop.fill" : "play.fill").frame(width: 16)
                    }
                    .buttonStyle(.plain)
                    .help(player.playing == t.url ? "Stop" : "Listen")
                    Text(t.title).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(t.genre).font(.caption).foregroundStyle(.secondary)
                    Button { model.addAudio(path: t.url.path, lane: .music) } label: { Image(systemName: "music.note") }
                        .help("Add to the Music lane")
                    Button { model.addAudio(path: t.url.path, lane: .sound) } label: { Image(systemName: "speaker.wave.2") }
                        .help("Add as a sound at the playhead")
                }
            }
        }
        HStack {
            Button("Open Music Folder") {
                try? FileManager.default.createDirectory(at: MusicLibrary.folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(MusicLibrary.folder)
            }
            Button("Refresh") { tracks = MusicLibrary.scan() }
            Menu("Other File…") {
                Button("Add to Music Lane…") { if let url = chooseAudioFile() { model.addAudio(path: url.path, lane: .music) } }
                Button("Add as Sound…") { if let url = chooseAudioFile() { model.addAudio(path: url.path, lane: .sound) } }
            }
            .fixedSize()
        }
        .font(.callout)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout).padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(selected ? Color.accentColor : Color.secondary.opacity(0.15)))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// Plays a track for listening in the panel (one at a time).
@MainActor @Observable
final class PreviewPlayer {
    private(set) var playing: URL?
    @ObservationIgnored private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        player?.stop()
        if playing == url {
            playing = nil
            return
        }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.volume = 0.6
        playing = player?.play() == true ? url : nil
    }

    func stop() {
        player?.stop()
        playing = nil
    }
}

@MainActor func chooseAudioFile() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio]
    panel.directoryURL = MusicLibrary.folder
    return panel.runModal() == .OK ? panel.url : nil
}

/// A selected clip on the Music or Sounds lane.
private struct AudioClipInspector: View {
    @Bindable var model: EditorModel
    let clipID: String
    @State private var tracks: [MusicLibrary.Track] = []

    var body: some View {
        if let c = model.project.music.clips.first(where: { $0.id == clipID }) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(c.lane == .music ? "Music" : "Sound").font(.headline)
                        Text(String(format: "%.1f s", c.duration)).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Button("Done") { model.selection = nil }.buttonStyle(.link)
                    }
                    HStack {
                        Image(systemName: c.lane == .music ? "music.note" : "speaker.wave.2")
                        Text(c.title).lineLimit(1).truncationMode(.middle)
                    }
                    if !FileManager.default.fileExists(atPath: c.file) {
                        Text("This file is missing; the clip is silent.").font(.caption).foregroundStyle(.orange)
                    }
                    Menu("Change Track") {
                        ForEach(tracks) { t in Button("\(t.title) (\(t.genre))") { model.replaceAudioFile(clipID, path: t.url.path) } }
                        Divider()
                        Button("Other File…") { if let url = chooseAudioFile() { model.replaceAudioFile(clipID, path: url.path) } }
                    }
                    .fixedSize()
                    slider("Volume", c, \.volume, range: 0...1, format: { "\(Int(($0 * 100).rounded())) %" })
                    slider("Fade in", c, \.fadeIn, range: 0...5, format: { String(format: "%.1f s", $0) })
                    slider("Fade out", c, \.fadeOut, range: 0...5, format: { String(format: "%.1f s", $0) })
                    Toggle("Repeat to fill the clip", isOn: Binding(get: { c.loop }, set: { v in update { $0.loop = v } }))
                    Text("Drag the clip to move it, its edges to trim it. C splits it at the playhead, ⌫ deletes it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Delete", role: .destructive) { model.deleteSelection() }
                        Spacer()
                        Button("Split at Playhead") { model.splitAtPlayhead() }
                    }
                }
            }
            .onAppear { tracks = MusicLibrary.scan() }
        }
    }

    private func slider(_ title: String, _ c: AudioClip, _ path: WritableKeyPath<AudioClip, Double>, range: ClosedRange<Double>,
                        format: (Double) -> String) -> some View {
        let value = c[keyPath: path]
        return HStack {
            Text(title).frame(width: 64, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { v in update { $0[keyPath: path] = v } }), in: range) { e in e ? model.beginGesture() : model.endGesture() }
            Text(format(value)).monospacedDigit().frame(width: 48, alignment: .trailing)
        }
    }

    private func update(_ change: @escaping (inout AudioClip) -> Void) {
        model.edit { try $0.updateAudio(clipID, change) }
    }
}

/// Names and symbols of the camera layouts.
enum LayoutNames {
    static func title(_ k: LayoutKind) -> String {
        switch k {
        case .overlay: "Overlay"
        case .split: "Split"
        case .camera: "Camera"
        case .screen: "Screen only"
        }
    }

    static func symbol(_ k: LayoutKind) -> String {
        switch k {
        case .overlay: "pip"
        case .split: "rectangle.split.2x1"
        case .camera: "person.crop.rectangle"
        case .screen: "display"
        }
    }

    static func note(_ k: LayoutKind) -> String {
        switch k {
        case .overlay: "The screen, with your camera in a corner bubble."
        case .split: "Screen and camera side by side (stacked on a portrait canvas)."
        case .camera: "Your camera fills the whole video."
        case .screen: "The screen only; the camera is hidden."
        }
    }
}

private struct NoCameraNote: View {
    var body: some View {
        Text("This recording has no camera. Turn on the camera before recording (in the recorder) to show yourself in the video.")
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// The webcam's look (Phase 5): bubble shape, corner, size, mirror, cursor avoidance, shadow.
private struct CameraPanel: View {
    @Bindable var model: EditorModel
    var cam: WebcamLook { model.project.look.webcam }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.hasCamera {
                NoCameraNote()
            } else {
                Text("How your camera bubble looks. Where it shows (overlay, split, full screen) is set in the Layout panel.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SettingAnchor(model: model, id: "webcam.shape") {
                    TabStrip(selection: Binding(get: { cam.shape }, set: { v in model.edit { $0.look.webcam.shape = v } }),
                             items: [(.circle, "Circle"), (.rounded, "Rounded square")])
                }
                SettingAnchor(model: model, id: "webcam.corner") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Corner")
                        TabStrip(selection: Binding(get: { cam.corner }, set: { v in model.edit { $0.look.webcam.corner = v } }),
                                 items: [(.topLeft, "↖"), (.topRight, "↗"), (.bottomLeft, "↙"), (.bottomRight, "↘")])
                    }
                }
                SettingAnchor(model: model, id: "webcam.size") {
                    HStack {
                        Text("Size")
                        Slider(value: Binding(get: { cam.size }, set: { v in model.edit { $0.look.webcam.size = v } }), in: 0.12...0.45) { e in
                            e ? model.beginGesture() : model.endGesture()
                        }
                        Text("\(Int((cam.size * 100).rounded())) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                SettingRow(model: model, id: "webcam.mirror")
                SettingRow(model: model, id: "webcam.avoidCursor")
                Text("While the cursor is under the bubble, the bubble moves to another corner, then comes back.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SettingRow(model: model, id: "webcam.shadow")
            }
        }
    }
}

/// Camera layouts over time (Phase 5): the default layout, and blocks that change it for a while.
private struct LayoutPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.hasCamera {
                NoCameraNote()
            } else {
                SettingAnchor(model: model, id: "webcam.layout") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Everywhere else")
                        TabStrip(selection: Binding(get: { model.project.look.webcam.layout }, set: { v in model.edit { $0.look.webcam.layout = v } }),
                                 items: LayoutKind.allCases.map { ($0, LayoutNames.title($0)) })
                        Text(LayoutNames.note(model.project.look.webcam.layout)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("Add at the playhead (4 s, then drag it in the Camera lane):").font(.callout)
                HStack(spacing: 6) {
                    ForEach(LayoutKind.allCases, id: \.self) { k in
                        Button { model.addLayout(k) } label: {
                            VStack(spacing: 2) {
                                Image(systemName: LayoutNames.symbol(k))
                                Text(LayoutNames.title(k)).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                Text("Changes between layouts are animated.").font(.caption).foregroundStyle(.secondary)
                let map = model.prepared.timeMap
                let blocks = model.project.layouts.compactMap { l in
                    map.timelineIntervals(sourceStart: l.sourceStart, sourceEnd: l.sourceEnd).first.map { (l, $0.lowerBound) }
                }.sorted { $0.1 < $1.1 }
                if !blocks.isEmpty {
                    Divider()
                    ForEach(blocks, id: \.0.id) { l, start in
                        Button {
                            model.selection = .layout(l.id)
                            Task { await model.seek(to: start) }
                        } label: {
                            HStack {
                                Image(systemName: LayoutNames.symbol(l.kind))
                                Text(LayoutNames.title(l.kind))
                                Spacer()
                                Text(TransportFormat.time(start)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// A selected layout block.
private struct LayoutInspector: View {
    @Bindable var model: EditorModel
    let layoutID: String

    var body: some View {
        if let l = model.project.layouts.first(where: { $0.id == layoutID }) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Camera layout").font(.headline)
                        Spacer()
                        Button("Done") { model.selection = nil }.buttonStyle(.link)
                    }
                    TabStrip(selection: Binding(get: { l.kind }, set: { k in
                        model.edit { p in if let i = p.layouts.firstIndex(where: { $0.id == layoutID }) { p.layouts[i].kind = k } }
                    }), items: LayoutKind.allCases.map { ($0, LayoutNames.title($0)) })
                    Text(LayoutNames.note(l.kind)).font(.caption).foregroundStyle(.secondary)
                    Text("Drag the block in the Camera lane to move it, its edges to change how long it lasts.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Delete Layout", role: .destructive) { model.deleteSelection() }
                }
            }
        }
    }
}

// MARK: Selection inspectors

private struct SliceInspector: View {
    @Bindable var model: EditorModel
    let sliceID: String

    var body: some View {
        if let slice = model.project.timeline.slices.first(where: { $0.id == sliceID }),
           let entry = model.prepared.timeMap.entries.first(where: { $0.sliceID == sliceID }) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Slice").font(.headline)
                        Text(String(format: "%.1f s", entry.timelineDuration)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Done") { model.selection = nil }.buttonStyle(.link)
                    }
                    Text("Speed").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        ForEach(Project.speedPresets, id: \.self) { v in
                            Button("\(SliceBlockLabel.speed(v))×") { model.edit { try $0.setSpeed(sliceID, v) } }
                                .buttonStyle(.bordered)
                                .tint(abs(slice.speed - v) < 0.001 ? .accentColor : nil)
                                .controlSize(.small)
                        }
                    }
                    Button("Apply Speed to All Slices") { model.edit { try $0.applySpeedToAll(from: sliceID) } }
                    Toggle("Smooth mouse movement", isOn: Binding(get: { slice.smoothMouse },
                                                                  set: { v in model.edit { try $0.updateSlice(sliceID) { $0.smoothMouse = v } } }))
                    Toggle("Hide mouse cursor", isOn: Binding(get: { slice.hideCursor },
                                                              set: { v in model.edit { try $0.updateSlice(sliceID) { $0.hideCursor = v } } }))
                    Text("Cursor in this slice").font(.caption).foregroundStyle(.secondary)
                    Picker("Style", selection: Binding(get: { slice.cursorOverride?.style }, set: { v in
                        model.edit { try $0.updateSlice(sliceID) { s in
                            var o = s.cursorOverride ?? CursorOverride(); o.style = v; s.cursorOverride = o.isEmpty ? nil : o
                        } }
                    })) {
                        Text("Project setting").tag(CursorLook.Style?.none)
                        ForEach(CursorLook.Style.allCases, id: \.self) { Text(CursorStyleNames.name($0)).tag(Optional($0)) }
                    }
                    HStack {
                        Toggle("Own size", isOn: Binding(get: { slice.cursorOverride?.size != nil }, set: { on in
                            model.edit { try $0.updateSlice(sliceID) { s in
                                var o = s.cursorOverride ?? CursorOverride(); o.size = on ? model.project.look.cursor.size : nil
                                s.cursorOverride = o.isEmpty ? nil : o
                            } }
                        }))
                        if let size = slice.cursorOverride?.size {
                            Slider(value: Binding(get: { size }, set: { v in
                                model.edit { try $0.updateSlice(sliceID) { s in s.cursorOverride?.size = v } }
                            }), in: 0.5...4) { e in e ? model.beginGesture() : model.endGesture() }
                        }
                    }
                    Button("Remove Slice", role: .destructive) { model.edit { try $0.removeSlice(sliceID) } }
                }
            }
        }
    }
}

enum SliceBlockLabel {
    static func speed(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2g", v) }
}

enum CursorStyleNames {
    static func name(_ s: CursorLook.Style) -> String {
        switch s {
        case .standardArrow: "Standard arrow"
        case .outlineArrow: "Outline arrow"
        case .dot: "Dot"
        case .filledColorArrow: "Filled color arrow"
        case .boldWhiteArrow: "Bold white arrow"
        case .thinArrow: "Thin arrow"
        }
    }
}

private struct ZoomInspector: View {
    @Bindable var model: EditorModel
    let zoomID: String

    var body: some View {
        if let z = model.project.zooms.first(where: { $0.id == zoomID }) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Zoom").font(.headline)
                        Text(z.origin == .generated ? "automatic" : "your zoom").foregroundStyle(.secondary)
                        Spacer()
                        Button("Done") { model.selection = nil }.buttonStyle(.link)
                    }
                    HStack {
                        Text("Scale")
                        Slider(value: Binding(get: { z.scale }, set: { v in update { $0.scale = v; $0.origin = .user } }), in: 1.25...4) { e in
                            e ? model.beginGesture() : model.endGesture()
                        }
                        Text(String(format: "%.2f×", z.scale)).monospacedDigit().frame(width: 48)
                    }
                    Picker("Target", selection: Binding(get: { z.mode }, set: { m in
                        if m == .manual && z.manualCenter == nil {
                            model.pickingZoomPointFor = zoomID
                        } else {
                            update { $0.mode = m; $0.origin = .user }
                        }
                    })) {
                        Text("Auto (follows cursor)").tag(ZoomSegment.Mode.auto)
                        Text("Manual (fixed point)").tag(ZoomSegment.Mode.manual)
                    }
                    if z.mode == .manual || model.pickingZoomPointFor == zoomID {
                        Button(model.pickingZoomPointFor == zoomID ? "Click the point on the canvas…" : "Pick Point on Canvas") {
                            model.pickingZoomPointFor = zoomID
                        }
                    }
                    HStack {
                        Button("Delete Zoom", role: .destructive) { model.edit { p in p.zooms.removeAll { $0.id == zoomID } } }
                        Spacer()
                        Button("Regenerate Auto-Zooms") { model.regenerateZooms() }
                            .help("Replaces the automatic zooms; zooms you added or changed stay.")
                    }
                }
            }
        }
    }

    private func update(_ change: @escaping (inout ZoomSegment) -> Void) {
        model.edit { p in
            guard let i = p.zooms.firstIndex(where: { $0.id == zoomID }) else { return }
            change(&p.zooms[i])
        }
    }
}

private struct MaskInspector: View {
    @Bindable var model: EditorModel
    let maskID: String

    var body: some View {
        if let m = model.project.masks.first(where: { $0.id == maskID }) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Mask").font(.headline)
                        Spacer()
                        Button("Done") { model.selection = nil }.buttonStyle(.link)
                    }
                    Picker("Type", selection: Binding(get: { m.kind }, set: { k in update { $0.kind = k } })) {
                        Text("Blur").tag(Mask.Kind.blur)
                        Text("Hide").tag(Mask.Kind.hide)
                        Text("Highlight").tag(Mask.Kind.highlight)
                    }
                    .pickerStyle(.segmented)
                    if m.kind != .hide {
                        HStack {
                            Text(m.kind == .blur ? "Blur" : "Dimming")
                            Slider(value: Binding(get: { m.strength }, set: { v in update { $0.strength = v } }), in: 0.05...1) { e in
                                e ? model.beginGesture() : model.endGesture()
                            }
                        }
                    }
                    Text("Drag the rectangle on the canvas to move it, its corner to resize. The time range is the block in the mask track.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Delete Mask", role: .destructive) { model.edit { p in p.masks.removeAll { $0.id == maskID } } }
                }
            }
        }
    }

    private func update(_ change: @escaping (inout Mask) -> Void) {
        model.edit { p in
            guard let i = p.masks.firstIndex(where: { $0.id == maskID }) else { return }
            change(&p.masks[i])
        }
    }
}
