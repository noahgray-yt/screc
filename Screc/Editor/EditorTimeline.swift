import AppKit
import ScrecCore
import SwiftUI

/// The timeline (SPEC §3.2): ruler, clip track (slices, cut badges, waveform), zoom track, mask track, the Music
/// and Sounds lanes (Phase 5), playhead.
///
/// Interaction: each track handles the mouse itself, in its own fixed coordinate space, and finds the block (or
/// block edge) under the pointer by hit-testing the model. The drawn blocks never take events. This avoids two
/// problems of per-block gestures: clicks falling through to the track (which adds zooms) and drag offsets
/// measured against a block that moves while it is dragged.
struct EditorTimeline: View {
    @Bindable var model: EditorModel

    static let inset: CGFloat = 14
    static let rulerHeight: CGFloat = 22
    static let clipHeight: CGFloat = 56
    static let zoomHeight: CGFloat = 30
    static let maskHeight: CGFloat = 26
    static let audioHeight: CGFloat = 26
    static let spacing: CGFloat = 4
    static let layoutHeight: CGFloat = 26
    static var baseHeight: CGFloat { rulerHeight + clipHeight + zoomHeight + maskHeight + 2 * audioHeight + 5 * spacing }
    /// The Camera lane only shows when the recording has a camera.
    var totalHeight: CGFloat { Self.baseHeight + (model.hasCamera ? Self.layoutHeight + Self.spacing : 0) }

    var body: some View {
        GeometryReader { geo in
            let duration = max(model.duration, 0.1)
            let pps = max((geo.size.width - 2 * Self.inset) / duration * model.timelineZoom, 4)
            let width = max(duration * pps + 2 * Self.inset, geo.size.width)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: Self.spacing) {
                    Ruler(duration: duration, pps: pps) { t in Task { await model.seek(to: t) } }
                        .frame(height: Self.rulerHeight)
                    ClipLane(model: model, pps: pps)
                        .frame(height: Self.clipHeight)
                    BlockLane(model: model, kind: .zoom, pps: pps)
                        .frame(height: Self.zoomHeight)
                    if model.hasCamera {
                        BlockLane(model: model, kind: .layout, pps: pps)
                            .frame(height: Self.layoutHeight)
                    }
                    BlockLane(model: model, kind: .mask, pps: pps)
                        .frame(height: Self.maskHeight)
                    AudioLane(model: model, lane: .music, pps: pps)
                        .frame(height: Self.audioHeight)
                    AudioLane(model: model, lane: .sound, pps: pps)
                        .frame(height: Self.audioHeight)
                }
                .frame(width: width, alignment: .leading)
                .overlay(alignment: .topLeading) {
                    Playhead(height: totalHeight)
                        .offset(x: Self.x(model.currentTime, pps) - 6)
                        .allowsHitTesting(false)
                }
            }
            .scrollIndicators(.visible)
        }
        .frame(height: totalHeight + 14)
    }

    static func x(_ t: Double, _ pps: Double) -> CGFloat { inset + t * pps }
    static func t(_ x: CGFloat, _ pps: Double) -> Double { (x - inset) / pps }
    static let edgeTolerance: CGFloat = 6
}

// MARK: Ruler and playhead

private struct Ruler: View {
    let duration: Double
    let pps: Double
    let seek: (Double) -> Void

    var body: some View {
        Canvas { ctx, _ in
            let step: Double = pps > 120 ? 0.5 : pps > 40 ? 1 : pps > 12 ? 5 : 10
            var t = 0.0
            while t <= duration + 1e-6 {
                let x = EditorTimeline.x(t, pps)
                let major = (t / step).rounded().truncatingRemainder(dividingBy: 2) == 0
                ctx.fill(Path(CGRect(x: x, y: major ? 10 : 15, width: 1, height: major ? 12 : 7)), with: .color(.secondary.opacity(0.6)))
                if major {
                    let s = Int(t)
                    ctx.draw(Text(String(format: "%d:%02d", s / 60, s % 60)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary),
                             at: CGPoint(x: x + 3, y: 5), anchor: .leading)
                }
                t += step
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in seek(max(EditorTimeline.t(g.location.x, pps), 0)) })
        .help("Click or drag to move the playhead")
    }
}

private struct Playhead: View {
    let height: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 10)).foregroundStyle(.red)
            Rectangle().fill(.red).frame(width: 1.5, height: height - 10)
        }
        .frame(width: 12)
    }
}

// MARK: Shared hit testing and drag state

private typealias Hit = TimelineHitTest.Hit
private typealias Span = TimelineHitTest.Span

@MainActor private func hitTest(_ x: CGFloat, spans: [Span], pps: Double) -> Hit {
    TimelineHitTest.hit(x: x, spans: spans, inset: EditorTimeline.inset, pps: pps, tolerance: EditorTimeline.edgeTolerance)
}

@MainActor private func setCursor(for hit: Hit) {
    if hit.isEdge { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
}

// MARK: Clip track

private struct ClipLane: View {
    @Bindable var model: EditorModel
    let pps: Double
    @State private var hovered: Hit = .none
    @State private var drag: (hit: Hit, origin: Double)?
    @State private var dragging = false

    var spans: [Span] {
        model.prepared.timeMap.entries.map { Span(id: $0.sliceID, start: $0.timelineStart, end: $0.timelineEnd) }
    }

    var body: some View {
        let map = model.prepared.timeMap
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4))
            ForEach(map.entries, id: \.sliceID) { e in
                if let slice = model.project.timeline.slices.first(where: { $0.id == e.sliceID }) {
                    SliceDrawing(model: model, slice: slice, entry: e, pps: pps,
                                 hoveredEdge: hovered.isEdge && hovered.id == slice.id)
                        .frame(width: max(e.timelineDuration * pps - 2, 3), height: EditorTimeline.clipHeight)
                        .offset(x: EditorTimeline.x(e.timelineStart, pps) + 1)
                }
            }
            ForEach(Array(zip(map.entries, map.entries.dropFirst())), id: \.0.sliceID) { a, b in
                let gap = b.sourceStart - a.sourceEnd
                if gap > 1.0 / 60 { CutBadge(seconds: gap).position(x: EditorTimeline.x(b.timelineStart, pps), y: EditorTimeline.clipHeight - 8) }
            }
            // Typing that could be sped up (Keyboard panel → Speed up typing).
            ForEach(Array(model.typingStretches.enumerated()), id: \.offset) { _, st in
                if model.currentSpeed(of: st) == 1 {
                    ForEach(Array(map.timelineIntervals(sourceStart: st.sourceStart, sourceEnd: st.sourceEnd).enumerated()), id: \.offset) { _, r in
                        HStack(spacing: 3) {
                            Image(systemName: "keyboard")
                            Text("\(SliceBlockLabel.speed(st.suggestedSpeed))×?")
                        }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: max((r.upperBound - r.lowerBound) * pps, 8), height: 14)
                        .background(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        .offset(x: EditorTimeline.x(r.lowerBound, pps), y: EditorTimeline.clipHeight - 34)
                    }
                }
            }
            if let first = map.entries.first, first.sourceStart > 1.0 / 60 {
                CutBadge(seconds: first.sourceStart).position(x: EditorTimeline.x(0, pps) + 20, y: EditorTimeline.clipHeight - 8)
            }
            if let last = map.entries.last, model.recordingDuration - last.sourceEnd > 1.0 / 60 {
                CutBadge(seconds: model.recordingDuration - last.sourceEnd).position(x: EditorTimeline.x(map.duration, pps) - 20, y: EditorTimeline.clipHeight - 8)
            }
        }
        .allowsHitTesting(false)
        .overlay {
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard !dragging else { return }
                    if case let .active(p) = phase {
                        hovered = hitTest(p.x, spans: spans, pps: pps)
                        setCursor(for: hovered)
                    } else {
                        hovered = .none
                        NSCursor.arrow.set()
                    }
                }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if drag == nil {
                            let hit = hitTest(g.startLocation.x, spans: spans, pps: pps)
                            if let id = hit.id { model.selection = .slice(id) }
                            let slice = hit.id.flatMap { id in model.project.timeline.slices.first { $0.id == id } }
                            let origin: Double = switch hit {
                            case .startEdge: slice?.sourceStart ?? 0
                            case .endEdge: slice?.sourceEnd ?? 0
                            default: 0
                            }
                            drag = (hit, origin)
                        }
                        guard let drag, drag.hit.isEdge, let id = drag.hit.id,
                              let slice = model.project.timeline.slices.first(where: { $0.id == id }) else { return }
                        if !dragging, abs(g.translation.width) > 2 {
                            dragging = true
                            model.beginGesture()
                        }
                        guard dragging else { return }
                        let target = drag.origin + g.translation.width / pps * slice.speed
                        let d = model.recordingDuration
                        if case .startEdge = drag.hit {
                            model.edit { try $0.trimStart(sliceID: id, toSource: target) }
                        } else {
                            model.edit { try $0.trimEnd(sliceID: id, toSource: target, recordingDuration: d) }
                        }
                    }
                    .onEnded { _ in
                        if drag?.hit == Hit.none { model.selection = nil }
                        if dragging { model.endGesture() }
                        drag = nil
                        dragging = false
                    })
                .contextMenu {
                    if let id = hovered.id {
                        SliceMenu(model: model, sliceID: id)
                    } else {
                        Button("Split at current time") { model.splitAtPlayhead() }
                    }
                }
        }
        .help("Click a slice to select it, drag its edge to trim it, right-click for more")
    }
}

private struct CutBadge: View {
    let seconds: Double
    var body: some View {
        Text("\(SliceDrawing.seconds(seconds)) ✂")
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.black.opacity(0.75), in: Capsule())
            .foregroundStyle(.white)
            .fixedSize()
    }
}

private struct SliceDrawing: View {
    @Bindable var model: EditorModel
    let slice: Slice
    let entry: TimeMap.Entry
    let pps: Double
    let hoveredEdge: Bool

    var body: some View {
        let selected = model.selection == .slice(slice.id)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.36, green: 0.42, blue: 0.95).opacity(selected ? 0.95 : 0.7))
            if model.showWaveform && !model.waveform.isEmpty {
                Canvas { ctx, size in
                    let step = EditorModel.waveformStep
                    var x: CGFloat = 0
                    while x < size.width {
                        let s = entry.sourceStart + Double(x) / pps * entry.speed
                        let i = Int(s / step)
                        if i >= 0, i < model.waveform.count {
                            let h = CGFloat(min(model.waveform[i] * 1.6, 1)) * (size.height - 20)
                            ctx.fill(Path(CGRect(x: x, y: (size.height - h) / 2 + 6, width: 1, height: max(h, 0.5))), with: .color(.white.opacity(0.35)))
                        }
                        x += 2
                    }
                }
            }
            HStack(spacing: 4) {
                Text(Self.seconds(entry.timelineDuration))
                if slice.speed != 1 { Text("⊙\(SliceBlockLabel.speed(slice.speed))x") }
                if !slice.smoothMouse { Image(systemName: "cursorarrow.motionlines.click") }
                if slice.hideCursor { Image(systemName: "cursorarrow.slash") }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.top, 4)
            .lineLimit(1)
            if selected { RoundedRectangle(cornerRadius: 6).strokeBorder(.white, lineWidth: 2) }
            if selected || hoveredEdge {
                HStack {
                    Capsule().fill(.white.opacity(0.8)).frame(width: 3, height: 22).padding(.leading, 2)
                    Spacer()
                    Capsule().fill(.white.opacity(0.8)).frame(width: 3, height: 22).padding(.trailing, 2)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    static func seconds(_ s: Double) -> String { s < 10 ? String(format: "%.1fs", s) : "\(Int(s.rounded()))s" }
}

/// The slice context menu (ED-06).
struct SliceMenu: View {
    let model: EditorModel
    let sliceID: String

    var slice: Slice? { model.project.timeline.slices.first { $0.id == sliceID } }

    var body: some View {
        let volumes: [Double] = [0, 0.25, 0.5, 0.75, 1, 1.5, 2]
        Menu("Set slice speed") {
            ForEach(Project.speedPresets, id: \.self) { v in
                Button("\(SliceBlockLabel.speed(v))×") { model.edit { try $0.setSpeed(sliceID, v) } }
            }
        }
        Menu("Set slice volume") {
            ForEach(volumes, id: \.self) { v in Button("\(Int(v * 100)) %") { model.edit { try $0.updateSlice(sliceID) { $0.volume = v } } } }
        }
        Menu("Set system-audio volume") {
            ForEach(volumes, id: \.self) { v in Button("\(Int(v * 100)) %") { model.edit { try $0.updateSlice(sliceID) { $0.systemVolume = v } } } }
        }
        Menu("Set external-device audio volume") {
            ForEach(volumes, id: \.self) { v in Button("\(Int(v * 100)) %") { model.edit { try $0.updateSlice(sliceID) { $0.micVolume = v } } } }
        }
        Divider()
        Button("Remove slice") { model.edit { try $0.removeSlice(sliceID) } }
        Button("Split at current time") { model.splitAtPlayhead() }
        Button("Reset slice trim") { let d = model.recordingDuration; model.edit { try $0.resetTrim(sliceID, recordingDuration: d) } }
        Button("Merge with next") { model.edit { try $0.mergeWithNext(sliceID) } }
        Button("Merge with previous") { model.edit { try $0.mergeWithPrevious(sliceID) } }
        Divider()
        Toggle("Disable smooth mouse movement", isOn: Binding(
            get: { slice?.smoothMouse == false },
            set: { off in model.edit { try $0.updateSlice(sliceID) { $0.smoothMouse = !off } } }))
        Toggle("Hide mouse cursor", isOn: Binding(
            get: { slice?.hideCursor == true },
            set: { hide in model.edit { try $0.updateSlice(sliceID) { $0.hideCursor = hide } } }))
        Divider()
        Button("Reset trims and cuts for all slices") { let d = model.recordingDuration; model.edit { $0.resetAllTrimsAndCuts(recordingDuration: d) } }
        Button("Apply speed to all slices") { model.edit { try $0.applySpeedToAll(from: sliceID) } }
    }
}

// MARK: Zoom and mask tracks

private enum LaneKind { case zoom, mask, layout }

private struct BlockLane: View {
    @Bindable var model: EditorModel
    let kind: LaneKind
    let pps: Double
    @State private var hovered: Hit = .none
    @State private var drag: (hit: Hit, origin: Double)?
    @State private var dragging = false

    var spans: [Span] {
        let map = model.prepared.timeMap
        switch kind {
        case .zoom:
            return model.project.zooms.flatMap { z in
                map.timelineIntervals(sourceStart: z.sourceStart, sourceEnd: z.sourceEnd).map { Span(id: z.id, start: $0.lowerBound, end: $0.upperBound) }
            }
        case .mask:
            return model.project.masks.flatMap { m in
                map.timelineIntervals(sourceStart: m.sourceStart, sourceEnd: m.sourceEnd).map { Span(id: m.id, start: $0.lowerBound, end: $0.upperBound) }
            }
        case .layout:
            return model.project.layouts.flatMap { l in
                map.timelineIntervals(sourceStart: l.sourceStart, sourceEnd: l.sourceEnd).map { Span(id: l.id, start: $0.lowerBound, end: $0.upperBound) }
            }
        }
    }

    func selection(_ id: String) -> EditorModel.Selection {
        switch kind {
        case .zoom: .zoom(id)
        case .mask: .mask(id)
        case .layout: .layout(id)
        }
    }

    var body: some View {
        let spans = spans
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(kind == .zoom ? 0.3 : 0.2))
            if spans.isEmpty {
                Text(emptyText).font(.caption).foregroundStyle(.secondary).padding(.leading, 10)
                    .frame(maxHeight: .infinity)
            }
            ForEach(Array(spans.enumerated()), id: \.offset) { _, s in
                BlockDrawing(icon: icon(s.id), label: label(s.id), color: color(s.id),
                             selected: model.selection == selection(s.id), hoveredEdge: hovered.isEdge && hovered.id == s.id)
                    .frame(width: max((s.end - s.start) * pps - 2, 6))
                    .offset(x: EditorTimeline.x(s.start, pps) + 1)
            }
        }
        .allowsHitTesting(false)
        .overlay {
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard !dragging else { return }
                    if case let .active(p) = phase {
                        hovered = hitTest(p.x, spans: spans, pps: pps)
                        setCursor(for: hovered)
                    } else {
                        hovered = .none
                        NSCursor.arrow.set()
                    }
                }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if drag == nil {
                            let hit = hitTest(g.startLocation.x, spans: spans, pps: pps)
                            if let id = hit.id { model.selection = selection(id) }
                            let span = spans.first { $0.id == hit.id }
                            let origin: Double = switch hit {
                            case .body: span?.start ?? 0
                            case .startEdge: span?.start ?? 0
                            case .endEdge: spans.last { $0.id == hit.id }?.end ?? 0
                            case .none: 0
                            }
                            drag = (hit, origin)
                        }
                        guard let drag, let id = drag.hit.id else { return }
                        if !dragging, abs(g.translation.width) > 2 {
                            dragging = true
                            model.beginGesture()
                        }
                        guard dragging else { return }
                        let t = drag.origin + g.translation.width / pps
                        switch (kind, drag.hit) {
                        case (.zoom, .body): model.edit { try $0.moveZoom(id, toTimelineStart: t) }
                        case (.zoom, .startEdge): model.edit { try $0.resizeZoom(id, start: true, toTimeline: t) }
                        case (.zoom, .endEdge): model.edit { try $0.resizeZoom(id, start: false, toTimeline: t) }
                        case (.mask, .body): model.edit { try $0.moveMask(id, toTimelineStart: t) }
                        case (.mask, .startEdge): model.edit { try $0.resizeMask(id, start: true, toTimeline: t) }
                        case (.mask, .endEdge): model.edit { try $0.resizeMask(id, start: false, toTimeline: t) }
                        case (.layout, .body): model.edit { try $0.moveLayout(id, toTimelineStart: t) }
                        case (.layout, .startEdge): model.edit { try $0.resizeLayout(id, start: true, toTimeline: t) }
                        case (.layout, .endEdge): model.edit { try $0.resizeLayout(id, start: false, toTimeline: t) }
                        default: break
                        }
                    }
                    .onEnded { g in
                        // A click (no drag) on empty zoom track adds a zoom there; on empty space it deselects.
                        if !dragging, drag?.hit == Hit.none {
                            switch kind {
                            case .zoom: model.addZoom(atTimeline: max(EditorTimeline.t(g.location.x, pps) - 1, 0))
                            case .mask: model.selection = nil
                            case .layout:
                                model.selection = nil
                                model.panel = .layout
                            }
                        }
                        if dragging { model.endGesture() }
                        drag = nil
                        dragging = false
                    })
                .contextMenu {
                    if let id = hovered.id {
                        switch kind {
                        case .zoom: ZoomMenu(model: model, zoomID: id)
                        case .mask: Button("Delete mask") { model.edit { p in p.masks.removeAll { $0.id == id } } }
                        case .layout:
                            ForEach(LayoutKind.allCases, id: \.self) { k in
                                Button(LayoutNames.title(k)) { model.edit { p in if let i = p.layouts.firstIndex(where: { $0.id == id }) { p.layouts[i].kind = k } } }
                            }
                            Divider()
                            Button("Delete layout") { model.edit { p in p.layouts.removeAll { $0.id == id } } }
                        }
                    }
                }
        }
        .help(helpText)
    }

    private var emptyText: String {
        switch kind {
        case .zoom: "Zooms — click here to add one"
        case .mask: "Masks — choose Blur, Hide or Highlight on the left, then drag over the picture"
        case .layout: "Camera — \(LayoutNames.title(model.project.look.webcam.layout)) everywhere. Add layouts in the Layout panel."
        }
    }

    private var helpText: String {
        switch kind {
        case .zoom: "Click empty space to add a zoom. Drag a zoom to move it, drag its edge to change its length, right-click for options."
        case .mask: "Drag a mask to move it in time, drag its edge to change its length, right-click to delete."
        case .layout: "Camera layouts: drag to move, drag an edge to change the length, right-click to change or delete. Click empty space for the Layout panel."
        }
    }

    private func icon(_ id: String) -> String {
        if kind == .layout { return LayoutNames.symbol(model.project.layouts.first { $0.id == id }?.kind ?? .overlay) }
        if kind == .zoom { return model.project.zooms.first { $0.id == id }?.mode == .manual ? "mappin.and.ellipse" : "plus.magnifyingglass" }
        switch model.project.masks.first(where: { $0.id == id })?.kind {
        case .blur?: return "drop.halffull"
        case .hide?: return "rectangle.fill"
        default: return "light.max"
        }
    }

    private func label(_ id: String) -> String {
        if kind == .layout { return LayoutNames.title(model.project.layouts.first { $0.id == id }?.kind ?? .overlay) }
        if kind == .zoom, let z = model.project.zooms.first(where: { $0.id == id }) {
            let scale = z.scale == z.scale.rounded() ? "\(Int(z.scale))" : String(format: "%.2g", z.scale)
            return "\(scale)× · \(z.mode == .auto ? "Auto" : "Manual")"
        }
        return model.project.masks.first { $0.id == id }?.kind.rawValue.capitalized ?? ""
    }

    private func color(_ id: String) -> Color {
        if kind == .layout { return Color(red: 0.25, green: 0.5, blue: 0.85) }
        if kind == .zoom {
            return model.project.zooms.first { $0.id == id }?.origin == .generated ? Color(red: 0.55, green: 0.36, blue: 0.9) : Color(red: 0.72, green: 0.35, blue: 0.95)
        }
        switch model.project.masks.first(where: { $0.id == id })?.kind {
        case .blur?: return .teal
        case .hide?: return .gray
        default: return .orange
        }
    }
}

// MARK: Music and Sounds lanes (Phase 5)

/// Audio clips in timeline time. Same interaction as the zoom track: drag to move, drag an edge to trim;
/// clips on a lane never overlap.
private struct AudioLane: View {
    @Bindable var model: EditorModel
    let lane: AudioClip.Lane
    let pps: Double
    @State private var hovered: Hit = .none
    @State private var drag: (hit: Hit, origin: Double)?
    @State private var dragging = false

    var clips: [AudioClip] { model.project.music.clips(on: lane) }
    var spans: [Span] { clips.map { Span(id: $0.id, start: $0.start, end: min($0.end, max(model.duration, $0.start + 0.1))) } }

    var body: some View {
        let spans = spans
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.2))
            if spans.isEmpty {
                Text(lane == .music ? "Music — add a track in the Audio panel (♪)" : "Sounds — add one at the playhead in the Audio panel (🔊)")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 10)
                    .frame(maxHeight: .infinity)
            }
            ForEach(Array(zip(clips, spans)), id: \.0.id) { c, s in
                BlockDrawing(icon: lane == .music ? "music.note" : "speaker.wave.2", label: c.title,
                             color: lane == .music ? Color(red: 0.2, green: 0.62, blue: 0.45) : Color(red: 0.85, green: 0.5, blue: 0.2),
                             selected: model.selection == .audio(c.id), hoveredEdge: hovered.isEdge && hovered.id == c.id)
                    .opacity(FileManager.default.fileExists(atPath: c.file) ? 1 : 0.4)
                    .frame(width: max((s.end - s.start) * pps - 2, 6))
                    .offset(x: EditorTimeline.x(s.start, pps) + 1)
            }
        }
        .allowsHitTesting(false)
        .overlay {
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard !dragging else { return }
                    if case let .active(p) = phase {
                        hovered = hitTest(p.x, spans: spans, pps: pps)
                        setCursor(for: hovered)
                    } else {
                        hovered = .none
                        NSCursor.arrow.set()
                    }
                }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if drag == nil {
                            let hit = hitTest(g.startLocation.x, spans: spans, pps: pps)
                            if let id = hit.id { model.selection = .audio(id) }
                            let span = spans.first { $0.id == hit.id }
                            let origin: Double = switch hit {
                            case .body, .startEdge: span?.start ?? 0
                            case .endEdge: span?.end ?? 0
                            case .none: 0
                            }
                            drag = (hit, origin)
                        }
                        guard let drag, let id = drag.hit.id else { return }
                        if !dragging, abs(g.translation.width) > 2 {
                            dragging = true
                            model.beginGesture()
                        }
                        guard dragging else { return }
                        let t = drag.origin + g.translation.width / pps
                        switch drag.hit {
                        case .body: model.edit { try $0.moveAudio(id, toStart: t) }
                        case .startEdge: model.edit { try $0.resizeAudio(id, start: true, to: t) }
                        case .endEdge: model.edit { try $0.resizeAudio(id, start: false, to: t) }
                        case .none: break
                        }
                    }
                    .onEnded { _ in
                        if !dragging, drag?.hit == Hit.none {
                            model.selection = nil
                            model.panel = .audio
                        }
                        if dragging { model.endGesture() }
                        drag = nil
                        dragging = false
                    })
                .contextMenu {
                    if let id = hovered.id {
                        Button("Split at Playhead") {
                            model.selection = .audio(id)
                            model.splitAtPlayhead()
                        }
                        Button("Delete") { model.edit { p in p.music.clips.removeAll { $0.id == id } } }
                    }
                }
        }
        .help(lane == .music ? "Music clips: drag to move, drag an edge to trim, C splits at the playhead, ⌫ deletes. Click empty space for the Audio panel."
                             : "Sound clips: drag to move, drag an edge to trim, ⌫ deletes. Click empty space for the Audio panel.")
    }
}

private struct BlockDrawing: View {
    let icon: String
    let label: String
    let color: Color
    let selected: Bool
    let hoveredEdge: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(color.opacity(selected ? 0.95 : 0.72))
            if selected { RoundedRectangle(cornerRadius: 5).strokeBorder(.white, lineWidth: 2) }
            HStack(spacing: 3) {
                Image(systemName: icon)
                Text(label).lineLimit(1)
            }
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 6)
            if selected || hoveredEdge {
                HStack {
                    Capsule().fill(.white.opacity(0.85)).frame(width: 3, height: 14).padding(.leading, 2)
                    Spacer()
                    Capsule().fill(.white.opacity(0.85)).frame(width: 3, height: 14).padding(.trailing, 2)
                }
            }
        }
    }
}

struct ZoomMenu: View {
    let model: EditorModel
    let zoomID: String

    var body: some View {
        Menu("Scale") {
            ForEach([1.25, 1.5, 2, 2.5, 3, 4], id: \.self) { v in
                Button("\(String(format: "%g", v))×") { update { $0.scale = v } }
            }
        }
        Button("Follow cursor (Auto)") { update { $0.mode = .auto } }
        Button("Fixed point (Manual)…") {
            model.selection = .zoom(zoomID)
            model.pickingZoomPointFor = zoomID
        }
        Divider()
        Button("Delete zoom") { model.edit { p in p.zooms.removeAll { $0.id == zoomID } } }
    }

    private func update(_ change: @escaping (inout ZoomSegment) -> Void) {
        model.edit { p in
            guard let i = p.zooms.firstIndex(where: { $0.id == zoomID }) else { return }
            change(&p.zooms[i])
            p.zooms[i].origin = .user
        }
    }
}
