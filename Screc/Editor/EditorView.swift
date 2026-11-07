import AppKit
import ScrecCore
import ScrecRender
import SwiftUI
import UniformTypeIdentifiers

/// The editor window (SPEC §3): title-bar tools, canvas with tool palette and overlays, inspector rail,
/// transport bar and timeline.
struct EditorWindowContent: View {
    let bundle: URL
    @Environment(\.openWindow) private var openWindow
    @State private var model: EditorModel?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let model {
                EditorView(model: model)
            } else if let loadError {
                ContentUnavailableView("This recording cannot be opened", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 1100, minHeight: 720)
        .onAppear { AppModel.shared.openEditors += 1 }
        .onDisappear {
            let app = AppModel.shared
            app.openEditors -= 1
            // Closing the last editor brings the recorder back (and with it the camera bubble).
            if app.openEditors == 0 && !app.recorderVisible { openWindow(id: "recorder") }
        }
        .task {
            do {
                model = try EditorModel(bundle: bundle)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

struct EditorView: View {
    @Bindable var model: EditorModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var presets = PresetStore().list()
    @State private var confirmDelete = false
    @State private var keyMonitor: Any?
    @State private var mouseMonitor: Any?
    @State private var showExport = false
    @State private var exporter = ExportController()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                CanvasBar(model: model)
                Divider()
                CanvasArea(model: model)
                Divider()
                TransportBar(model: model)
                EditorTimeline(model: model)
                    .padding(.horizontal, 6)
                    .background(.background)
            }
            Divider()
            IconRail(model: model)
            Divider()
            InspectorView(model: model)
                .frame(width: InspectorView.width)
                .clipped()
        }
        .overlay(alignment: .top) {
            if model.showPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.15).onTapGesture { model.showPalette = false }
                    CommandPalette(model: model).padding(.top, 80)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let message = model.message {
                Text(message).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 200)
                    .transition(.opacity)
            }
        }
        .navigationTitle(Binding(get: { model.project.name }, set: { name in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { model.edit { $0.name = trimmed } }
        }))
        .toolbar { toolbar }
        .confirmationDialog("Move “\(model.project.name)” to the Trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { deleteProject() }
        } message: {
            Text("The recording and all edits are moved to the Trash. You can restore them from there.")
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(model: model, controller: exporter)
                .interactiveDismissDisabled(exporter.isRunning)
        }
        .task { await model.load() }
        .onAppear { installKeys() }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            model.close()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { openProject() } label: { Label("Open", systemImage: "folder") }.help("Open a recording")
            Button { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }.help("Move this recording to the Trash")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.showPalette.toggle() } label: { Label("Search", systemImage: "command") }
                .keyboardShortcut("k", modifiers: .command).help("Search settings and actions (⌘K)")
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command).disabled(!model.canUndo)
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo)
            Menu {
                if presets.isEmpty { Text("No presets yet") }
                ForEach(presets) { p in
                    Menu(p.name) {
                        Button("Apply") { model.edit { $0.look = p.applied(to: $0.look) } }
                        Button("Rename…") { renamePreset(p) }
                        Button("Delete") {
                            try? PresetStore().delete(name: p.name)
                            presets = PresetStore().list()
                        }
                    }
                }
                Divider()
                Button("Save Current Look as Preset…") { savePreset() }
            } label: { Label("Presets", systemImage: "square.stack") }
            .help("Presets: background, padding, corners, shadow, cursor and animation")
            Button { showExport = true } label: { Text("Export") }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("e", modifiers: .command)
                .help("Export as MP4 or GIF (⌘E)")
        }
    }

    // MARK: Actions

    private func openProject() {
        let panel = NSOpenPanel()
        panel.directoryURL = AppModel.recordingsDirectory
        panel.allowedContentTypes = [UTType(exportedAs: "local.screc.project")]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWindow(value: url)
    }

    private func deleteProject() {
        model.player.pause()
        do {
            try FileManager.default.trashItem(at: model.bundle, resultingItemURL: nil)
            AppModel.shared.refreshRecent()
            dismissWindow()
        } catch {
            model.show("Could not move to the Trash: \(error.localizedDescription)")
        }
    }

    private func savePreset() {
        guard let name = ask("Save the current look as a preset", value: "My preset") else { return }
        do {
            try PresetStore().save(Preset(name: name, from: model.project.look))
            presets = PresetStore().list()
            model.show("Preset “\(name)” saved.")
        } catch {
            model.show("The preset could not be saved: \(error.localizedDescription)")
        }
    }

    private func renamePreset(_ p: Preset) {
        guard let name = ask("Rename preset", value: p.name), name != p.name else { return }
        try? PresetStore().rename(p.name, to: name)
        presets = PresetStore().list()
    }

    private func ask(_ title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// Space (play), C (split), ⌫ (delete selection) — only when no text field is being edited.
    private func installKeys() {
        // A click outside the text being edited ends the editing (and saves it), like in most Mac apps.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window, let editor = window.firstResponder as? NSTextView else { return event }
            let field = (editor.isFieldEditor ? editor.delegate as? NSView : editor.enclosingScrollView) ?? editor
            if let hit = window.contentView?.hitTest(event.locationInWindow), hit.isDescendant(of: field) || hit.isDescendant(of: editor) {
                return event
            }
            window.makeFirstResponder(nil)
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [model] event in
            guard let window = event.window, window.isKeyWindow, window.title == model.project.name || window.identifier?.rawValue.contains("editor") == true
            else { return event }
            if window.firstResponder is NSText { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            guard mods.isEmpty, !model.showPalette, window.attachedSheet == nil else { return event }
            switch event.keyCode {
            case 49: model.togglePlay(); return nil                 // space
            case 8: model.splitAtPlayhead(); return nil             // C
            case 51, 117: model.deleteSelection(); return nil       // ⌫, ⌦
            case 123: model.jump(forward: false); return nil        // ←
            case 124: model.jump(forward: true); return nil         // →
            case 53:                                                // Esc
                model.maskTool = nil
                model.pickingZoomPointFor = nil
                if model.isCropping { model.isCropping = false } else { model.selection = nil; model.wordSelection = nil }
                return nil
            default: return event
            }
        }
    }
}

// MARK: - Bar above the canvas

private struct CanvasBar: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(get: { model.project.look.aspect }, set: { a in model.edit { $0.look.aspect = a } })) {
                ForEach(Look.Aspect.allCases, id: \.self) { Text(AspectMenu.name($0)).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            .help("Aspect ratio")
            Toggle(isOn: $model.isCropping) { Label("Crop", systemImage: "crop") }
                .toggleStyle(.button)
            if model.project.look.aspect != .auto {
                Toggle(isOn: Binding(get: { model.project.look.fillFrame }, set: { v in model.edit { $0.look.fillFrame = v } })) {
                    Label("Fill", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .toggleStyle(.button)
                .help("Fill the frame: zoom in until the screen fills the video and follow the cursor (for reels and other formats)")
            }
            if model.displayed.layout.canvasAspect < 1 {
                Toggle(isOn: $model.showReelGuides) { Label("Reel guides", systemImage: "rectangle.dashed") }
                    .toggleStyle(.button)
                    .help("Shows where social apps put their buttons and text. Only in the editor, never exported.")
            }
            Spacer()
            Picker("Preview", selection: $model.quality) {
                ForEach(EditorModel.Quality.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 150)
            .help("Preview quality (export is always full quality)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Canvas with palette and overlays

private struct CanvasArea: View {
    @Bindable var model: EditorModel

    var body: some View {
        GeometryReader { geo in
            let aspect = model.displayed.layout.canvasAspect
            let fit = fitSize(container: CGSize(width: geo.size.width - 162, height: geo.size.height - 24), aspect: aspect)
            let size = CGSize(width: fit.width * model.canvasZoom, height: fit.height * model.canvasZoom)
            ZStack {
                Color(white: 0.11)
                ScrollView([.horizontal, .vertical]) {
                    ZStack {
                        MetalPreview(model: model)
                        CanvasOverlay(model: model, size: size)
                    }
                    .frame(width: size.width, height: size.height)
                    .frame(minWidth: geo.size.width - 162, minHeight: geo.size.height - 24)
                }
                .scrollIndicators(model.canvasZoom > 1 ? .visible : .hidden)
                .padding(.leading, 142)
                ToolPalette(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                if model.isCropping {
                    VStack {
                        Spacer()
                        HStack {
                            Button("Reset Crop") { model.edit { $0.look.crop = [0, 0, 1, 1] } }
                            Button("Done") { model.isCropping = false }.keyboardShortcut(.defaultAction)
                        }
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 12)
                    }
                }
            }
        }
    }

    private func fitSize(container: CGSize, aspect: Double) -> CGSize {
        guard container.width > 0, container.height > 0 else { return CGSize(width: 16, height: 9) }
        if container.width / container.height > aspect {
            return CGSize(width: container.height * aspect, height: container.height)
        }
        return CGSize(width: container.width, height: container.width / aspect)
    }
}

/// Rough safe areas of vertical social video (our own simple shapes): top and bottom bands where the apps put
/// names, captions and progress bars, and the right-hand column of buttons. Editor only, never exported.
private struct ReelGuides: View {
    let size: CGSize

    var body: some View {
        let w = size.width, h = size.height
        ZStack(alignment: .topLeading) {
            zone(CGRect(x: 0, y: 0, width: w, height: h * 0.12), label: "Top bar")
            zone(CGRect(x: 0, y: h * 0.78, width: w, height: h * 0.22), label: "Name and caption")
            zone(CGRect(x: w * 0.86, y: h * 0.42, width: w * 0.14, height: h * 0.36), label: "Buttons")
            Rectangle().strokeBorder(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                .frame(width: w * 0.86 - w * 0.05, height: h * 0.66)
                .offset(x: w * 0.05, y: h * 0.12)
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func zone(_ r: CGRect, label: String) -> some View {
        ZStack {
            Rectangle().fill(Color.red.opacity(0.18))
            Rectangle().strokeBorder(Color.red.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
            Text(label).font(.caption2.bold()).foregroundStyle(.white).shadow(radius: 2)
        }
        .frame(width: r.width, height: r.height)
        .offset(x: r.minX, y: r.minY)
    }
}

/// Left floating palette: canvas zoom and mask tools (SPEC §3.1), with visible labels.
private struct ToolPalette: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("View").font(.caption2.bold()).foregroundStyle(.secondary)
            item("plus.magnifyingglass", "Zoom in", active: false) { model.canvasZoom = min(model.canvasZoom * 1.25, 4) }
                .help("Make the canvas bigger to look at details (does not change the video)")
            item("minus.magnifyingglass", "Zoom out", active: false) { model.canvasZoom = max(model.canvasZoom / 1.25, 1) }
                .disabled(model.canvasZoom <= 1)
                .help("Back towards fitting the window")
            Divider().padding(.vertical, 2)
            Text("Masks").font(.caption2.bold()).foregroundStyle(.secondary)
            tool(.blur, "drop.halffull", "Blur", "Blur a region, e.g. a password or e-mail address")
            tool(.hide, "rectangle.fill", "Hide", "Cover a region with a solid colour")
            tool(.highlight, "light.max", "Highlight", "Keep a region bright and dim everything else")
        }
        .buttonStyle(.borderless)
        .padding(8)
        .frame(width: 124, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func tool(_ kind: Mask.Kind, _ symbol: String, _ title: String, _ help: String) -> some View {
        item(symbol, title, active: model.maskTool == kind) { model.maskTool = model.maskTool == kind ? nil : kind }
            .help(help + ". Choose it, then drag over the picture.")
    }

    private func item(_ symbol: String, _ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).frame(width: 18)
                Text(title).font(.callout).lineLimit(1).fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.35) : .clear))
            .contentShape(Rectangle())
        }
    }
}

/// Interaction layer over the preview: draw masks, edit the selected mask, pick a zoom point, crop.
private struct CanvasOverlay: View {
    @Bindable var model: EditorModel
    let size: CGSize
    @State private var drawStart: CGPoint?
    @State private var drawCurrent: CGPoint?
    @State private var maskDragOrigin: [Double]?
    @State private var cropOrigin: [Double]?
    @State private var captionDragOrigin: [Double]?
    @State private var captionHover = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .gesture(drawGesture)
                .onTapGesture { location in tap(at: location) }
            if let a = drawStart, let b = drawCurrent {
                Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .background(Color.accentColor.opacity(0.12))
                    .frame(width: abs(b.x - a.x), height: abs(b.y - a.y))
                    .offset(x: min(a.x, b.x), y: min(a.y, b.y))
                    .allowsHitTesting(false)
            }
            if model.maskTool == nil, model.pickingZoomPointFor == nil, !model.isCropping, let r = captionBox {
                captionHandle(r)
            }
            if case let .mask(id)? = model.selection, let m = model.project.masks.first(where: { $0.id == id }), !model.isCropping {
                maskHandles(m)
            }
            if model.isCropping { cropHandles }
            if model.showReelGuides, model.displayed.layout.canvasAspect < 1, !model.isCropping { ReelGuides(size: size) }
            if model.pickingZoomPointFor != nil {
                hint("Click the point the zoom should aim at. Esc cancels.")
            } else if let tool = model.maskTool {
                hint(tool == .blur ? "Drag over the area to blur. Esc cancels."
                     : tool == .hide ? "Drag over the area to cover. Esc cancels."
                     : "Drag over the area to highlight; everything else is dimmed. Esc cancels.")
            } else if case .mask = model.selection {
                hint("Drag the dashed rectangle to move the mask, its corner dot to resize it.")
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "canvas")
    }

    /// The caption on screen now, as a fraction of the canvas (same art and placement as the compositor).
    private var captionBox: CGRect? {
        let p = model.displayed
        let c = p.project.look.captions
        guard c.enabled, let active = p.captions.active(at: model.currentTime) else { return nil }
        let out = p.layout.outputSize(shortSide: 1080)
        let short = Double(min(out.width, out.height))
        guard let art = CaptionArt.raster(words: active.line.words.map(\.text), activeWord: nil, look: c,
                                          textHeight: Int((c.size.fraction * short).rounded()), maxWidth: Int(Double(out.width) * 0.8))
        else { return nil }
        let box = CGSize(width: art.width, height: art.height)
        let o = c.origin(box: box, output: out)
        return CGRect(x: o.x / out.width, y: o.y / out.height, width: box.width / out.width, height: box.height / out.height)
    }

    /// Drag the caption anywhere; it snaps to the horizontal centre.
    private func captionHandle(_ r: CGRect) -> some View {
        let showOutline = captionHover || captionDragOrigin != nil || model.panel == .captions
        return Rectangle()
            .strokeBorder(showOutline ? Color.white.opacity(0.9) : .clear, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .contentShape(Rectangle())
            .frame(width: r.width * size.width, height: r.height * size.height)
            .offset(x: r.minX * size.width, y: r.minY * size.height)
            .onHover { captionHover = $0 }
            .help("Drag to move the caption")
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
                .onChanged { g in
                    if captionDragOrigin == nil { captionDragOrigin = [Double(r.midX), Double(r.midY)]; model.beginGesture() }
                    guard let o = captionDragOrigin else { return }
                    var x = o[0] + Double((g.location.x - g.startLocation.x) / max(size.width, 1))
                    let y = o[1] + Double((g.location.y - g.startLocation.y) / max(size.height, 1))
                    if abs(x - 0.5) < 0.015 { x = 0.5 }
                    model.edit { $0.look.captions.center = [min(max(x, 0), 1), min(max(y, 0), 1)] }
                }
                .onEnded { _ in captionDragOrigin = nil; model.endGesture() })
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.callout).padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule()).padding(10)
            .allowsHitTesting(false)
    }

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("canvas"))
            .onChanged { g in
                guard model.maskTool != nil else { return }
                if drawStart == nil { drawStart = g.startLocation }
                drawCurrent = g.location
            }
            .onEnded { g in
                defer { drawStart = nil; drawCurrent = nil }
                guard let kind = model.maskTool else { return }
                let a = model.recordingPoint(fromView: unit(g.startLocation)), b = model.recordingPoint(fromView: unit(g.location))
                let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard rect.width > 0.005, rect.height > 0.005 else { return }
                model.addMask(kind: kind, rect: rect)
            }
    }

    private func tap(at location: CGPoint) {
        guard let id = model.pickingZoomPointFor else {
            // Select the mask under the pointer (one that is visible now), or clear a mask selection.
            let r = model.recordingPoint(fromView: unit(location))
            let s = model.prepared.timeMap.toSource(model.currentTime)
            if let m = model.project.masks.last(where: { m in
                m.sourceStart <= s && s < m.sourceEnd && m.rect.count == 4
                    && r.x >= m.rect[0] && r.x <= m.rect[0] + m.rect[2] && r.y >= m.rect[1] && r.y <= m.rect[1] + m.rect[3]
            }) {
                model.selection = .mask(m.id)
            } else if case .mask = model.selection {
                model.selection = nil
            }
            return
        }
        let r = model.recordingPoint(fromView: unit(location))
        let point: [Double] = [Double(min(max(r.x, 0), 1)), Double(min(max(r.y, 0), 1))]
        model.edit { p in
            guard let i = p.zooms.firstIndex(where: { $0.id == id }) else { return }
            p.zooms[i].manualCenter = point
            p.zooms[i].mode = .manual
            p.zooms[i].origin = .user
        }
        model.pickingZoomPointFor = nil
    }

    private func unit(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / max(size.width, 1), y: p.y / max(size.height, 1)) }
    private func view(_ r: CGPoint) -> CGPoint {
        let v = model.viewPoint(fromRecording: r)
        return CGPoint(x: v.x * size.width, y: v.y * size.height)
    }

    /// The selected mask's rectangle: drag inside to move, drag the corner to resize.
    @ViewBuilder
    private func maskHandles(_ m: Mask) -> some View {
        let a = view(CGPoint(x: m.rect[0], y: m.rect[1]))
        let b = view(CGPoint(x: m.rect[0] + m.rect[2], y: m.rect[1] + m.rect[3]))
        Rectangle().strokeBorder(.white, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .contentShape(Rectangle())
            .frame(width: max(b.x - a.x, 4), height: max(b.y - a.y, 4))
            .offset(x: a.x, y: a.y)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                .onChanged { g in
                    if maskDragOrigin == nil { maskDragOrigin = m.rect; model.beginGesture() }
                    guard let o = maskDragOrigin else { return }
                    let d0 = model.recordingPoint(fromView: unit(g.startLocation)), d1 = model.recordingPoint(fromView: unit(g.location))
                    let x: Double = min(max(o[0] + Double(d1.x - d0.x), 0), 1 - o[2]), y: Double = min(max(o[1] + Double(d1.y - d0.y), 0), 1 - o[3])
                    updateMask(m.id, [x, y, o[2], o[3]])
                }
                .onEnded { _ in maskDragOrigin = nil; model.endGesture() })
        Circle().fill(.white).frame(width: 12, height: 12)
            .offset(x: b.x - 6, y: b.y - 6)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                .onChanged { g in
                    if maskDragOrigin == nil { maskDragOrigin = m.rect; model.beginGesture() }
                    guard let o = maskDragOrigin else { return }
                    let p = model.recordingPoint(fromView: unit(g.location))
                    updateMask(m.id, [o[0], o[1], min(max(Double(p.x) - o[0], 0.01), 1 - o[0]), min(max(Double(p.y) - o[1], 0.01), 1 - o[1])])
                }
                .onEnded { _ in maskDragOrigin = nil; model.endGesture() })
    }

    private func updateMask(_ id: String, _ rect: [Double]) {
        model.edit { p in
            guard let i = p.masks.firstIndex(where: { $0.id == id }) else { return }
            p.masks[i].rect = rect
        }
    }

    /// Crop: the preview shows the whole recording; drag inside the rectangle to move it, corners to resize.
    @ViewBuilder
    private var cropHandles: some View {
        let c = model.project.look.crop
        let a = view(CGPoint(x: c[0], y: c[1]))
        let b = view(CGPoint(x: c[0] + c[2], y: c[1] + c[3]))
        Path { p in
            p.addRect(CGRect(origin: .zero, size: size))
            p.addRect(CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))
        }
        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
        Rectangle().strokeBorder(.white, lineWidth: 1.5)
            .contentShape(Rectangle())
            .frame(width: max(b.x - a.x, 4), height: max(b.y - a.y, 4))
            .offset(x: a.x, y: a.y)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                .onChanged { g in
                    if cropOrigin == nil { cropOrigin = c; model.beginGesture() }
                    guard let o = cropOrigin else { return }
                    let d0 = model.recordingPoint(fromView: unit(g.startLocation)), d1 = model.recordingPoint(fromView: unit(g.location))
                    let x: Double = min(max(o[0] + Double(d1.x - d0.x), 0), 1 - o[2]), y: Double = min(max(o[1] + Double(d1.y - d0.y), 0), 1 - o[3])
                    model.edit { $0.look.crop = [x, y, o[2], o[3]] }
                }
                .onEnded { _ in cropOrigin = nil; model.endGesture() })
        ForEach(0..<4, id: \.self) { corner in
            let px = corner % 2 == 0 ? a.x : b.x, py = corner < 2 ? a.y : b.y
            Circle().fill(.white).frame(width: 12, height: 12)
                .offset(x: px - 6, y: py - 6)
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                    .onChanged { g in
                        if cropOrigin == nil { cropOrigin = c; model.beginGesture() }
                        guard let o = cropOrigin else { return }
                        let p = model.recordingPoint(fromView: unit(g.location))
                        var x0 = o[0], y0 = o[1], x1 = o[0] + o[2], y1 = o[1] + o[3]
                        let px = Double(p.x), py = Double(p.y)
                        if corner % 2 == 0 { x0 = min(max(px, 0), x1 - 0.05) } else { x1 = max(min(px, 1), x0 + 0.05) }
                        if corner < 2 { y0 = min(max(py, 0), y1 - 0.05) } else { y1 = max(min(py, 1), y0 + 0.05) }
                        model.edit { $0.look.crop = [x0, y0, x1 - x0, y1 - y0] }
                    }
                    .onEnded { _ in cropOrigin = nil; model.endGesture() })
        }
    }
}

// MARK: - Right icon rail

private struct IconRail: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 4) {
            ForEach(EditorModel.Panel.allCases) { p in
                Button {
                    model.panel = p
                    model.selection = nil          // back from a slice/zoom/mask to the panel
                } label: {
                    Image(systemName: p.symbol)
                        .font(.system(size: 15))
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 8).fill(model.panel == p && model.selection == nil ? Color.accentColor.opacity(0.3) : .clear))
                }
                .buttonStyle(.borderless)
                .help(p.title)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
    }
}

// MARK: - Transport bar

private struct TransportBar: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            Button { model.splitAtPlayhead() } label: { Image(systemName: "scissors") }.help("Split at the playhead (C)")
            Text(Self.format(model.currentTime)).monospacedDigit().frame(width: 70, alignment: .trailing)
            Button { model.jump(forward: false) } label: { Image(systemName: "backward.end.fill") }.help("Previous edit point (←)")
            Button { model.togglePlay() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18) }
                .help("Play / Pause (Space)")
            Button { model.jump(forward: true) } label: { Image(systemName: "forward.end.fill") }.help("Next edit point (→)")
            Text(Self.format(model.duration)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Spacer()
            Toggle(isOn: $model.showWaveform) { Image(systemName: "waveform") }.toggleStyle(.button).help("Show the audio waveform")
            Picker("", selection: $model.playbackRate) {
                ForEach([Float(0.5), 1, 1.5, 2], id: \.self) { Text("\(String(format: "%g", $0))×").tag($0) }
            }
            .labelsHidden().frame(width: 70).help("Playback speed (preview only)")
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $model.timelineZoom, in: 1...12).frame(width: 120).help("Timeline zoom")
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// `m:ss.cc` (SPEC §3.1).
    static func format(_ t: Double) -> String {
        let cs = Int((t * 100).rounded())
        return String(format: "%d:%02d.%02d", cs / 6000, (cs / 100) % 60, cs % 100)
    }
}
