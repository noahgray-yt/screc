import AVFoundation
import ScrecCapture
import ScrecCore
import SwiftUI

/// The main window: choose what to record, which tracks, and the utilities (REC-01 … REC-10).
/// One compact column: source, target, tracks, the record button and recent takes. Less frequent
/// options (countdown, frame rate, shortcut, desktop icons, speaker notes) sit behind the gear button.
struct RecorderView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showOptions = false

    var body: some View {
        VStack(spacing: 14) {
            header
            sourceTiles
            targetCard
            tracksCard
            recordButton
            messages
            recentList
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .ignoresSafeArea(edges: .top)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(VisualEffectBackground().ignoresSafeArea())
        .onAppear { model.recorderVisible = true }
        .onDisappear { model.recorderVisible = false }
        .task {
            model.refreshRecent()
            // The snapshot check must not trigger the Screen Recording prompt.
            if !AppDelegate.isSnapshot { await model.refreshSources() }
        }
    }

    // MARK: Header

    /// Sits in the title bar row, next to the traffic lights.
    private var header: some View {
        ZStack {
            Text("Screc")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Spacer()
                HeaderButton(symbol: "folder", help: "Open the recordings folder (Movies › Screc)") { Self.openRecordingsFolder() }
                HeaderButton(symbol: "slider.horizontal.3", help: "Recording options") { showOptions.toggle() }
                    .popover(isPresented: $showOptions, arrowEdge: .bottom) { RecorderOptionsView(model: model) }
            }
        }
        .frame(height: 28)
        .padding(.top, 1)
        .padding(.trailing, -6)
    }

    // MARK: Source (REC-01)

    private var sourceTiles: some View {
        HStack(spacing: 8) {
            ForEach(AppModel.SourceKind.allCases) { kind in
                SourceTile(kind: kind, selected: model.sourceKind == kind) {
                    withAnimation(.snappy(duration: 0.2)) { model.sourceKind = kind }
                }
            }
        }
    }

    private var targetCard: some View {
        Card {
            switch model.sourceKind {
            case .display:
                displayMenu
            case .window:
                windowMenu
                Hairline()
                WindowResizeRow(model: model)
            case .area:
                displayMenu
                Hairline()
                areaRow
            }
        }
    }

    private var displayMenu: some View {
        let display = model.catalog.displays.first { $0.id == model.displayID }
        return Menu {
            ForEach(model.catalog.displays) { d in
                Toggle(isOn: Binding(get: { model.displayID == d.id }, set: { if $0 { model.displayID = d.id } })) {
                    Text("\(d.name)  \(Int(d.frame.width)) × \(Int(d.frame.height))")
                }
            }
            Divider()
            Button("Refresh List") { Task { await model.refreshSources() } }
        } label: {
            MenuRowLabel(symbol: "display", title: display?.name ?? "Choose a display",
                         detail: display.map { "\(Int($0.frame.width)) × \(Int($0.frame.height)) pt" })
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var windowMenu: some View {
        let window = model.selectedWindow
        return Menu {
            if model.catalog.windows.isEmpty { Text("No windows found") }
            ForEach(model.catalog.windows) { w in
                Toggle(w.label, isOn: Binding(get: { model.windowID == w.id }, set: { if $0 { model.windowID = w.id } }))
            }
            Divider()
            Button("Refresh List") { Task { await model.refreshSources() } }
        } label: {
            MenuRowLabel(symbol: "macwindow", title: window?.appName ?? "Choose a window",
                         detail: window.map { $0.title.isEmpty ? "\(Int($0.frame.width)) × \(Int($0.frame.height)) pt" : $0.title })
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var areaRow: some View {
        HStack(spacing: 10) {
            RowIcon(symbol: "rectangle.dashed")
            VStack(alignment: .leading, spacing: 1) {
                Text("Area").font(.system(size: 13, weight: .medium))
                Group {
                    if let a = model.area {
                        Text(verbatim: "\(Int(a.width)) × \(Int(a.height)) pt at \(Int(a.minX)), \(Int(a.minY))").monospacedDigit()
                    } else {
                        Text("None selected")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.area == nil ? "Select…" : "Change…") { Task { await model.pickArea() } }
                .buttonStyle(PillButtonStyle())
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    // MARK: Tracks (REC-02)

    private var tracksCard: some View {
        _ = model.deviceListVersion            // redraw when devices come and go
        let microphones = AppModel.microphones
        let cameras = AppModel.cameras
        return Card {
            TrackRow(symbol: "mic.fill", offSymbol: "mic.slash.fill", title: "Microphone",
                     isOn: $model.recordMicrophone, available: !microphones.isEmpty,
                     unavailableText: "Not connected",
                     devices: microphones, deviceID: $model.microphoneID)
                .help(microphones.isEmpty ? "No microphone is connected to this Mac. Connect a USB microphone, headset or AirPods to record your voice." : "")
            Hairline()
            TrackRow(symbol: "speaker.wave.2.fill", offSymbol: "speaker.slash.fill", title: "System audio",
                     isOn: $model.recordSystemAudio, available: true, unavailableText: "",
                     devices: [], deviceID: .constant(nil))
            Hairline()
            TrackRow(symbol: "video.fill", offSymbol: "video.slash.fill", title: "Camera",
                     isOn: $model.recordCamera, available: !cameras.isEmpty,
                     unavailableText: "Not connected",
                     devices: cameras, deviceID: $model.cameraID,
                     footnote: "Saved as a separate track. Drag the live bubble to the corner you want; it is not recorded on screen.")
        }
    }

    // MARK: Record

    private var recordButton: some View {
        let recording = model.isRecording
        let starting = model.isCountingDown || model.session.state == .starting
        return Button {
            Task { await model.toggleRecording() }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    if recording {
                        RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 11, height: 11)
                    } else {
                        Circle().fill(.white).frame(width: 12, height: 12)
                    }
                }
                .frame(width: 14)
                Text(recording ? "Stop Recording" : (starting ? "Starting…" : "Start Recording"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(model.hotKey.display)
                    .font(.system(size: 12, weight: .medium))
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(RecordButtonStyle(recording: recording))
        .disabled(starting || model.session.state == .finishing)
    }

    @ViewBuilder
    private var messages: some View {
        let lines = [model.catalogError, model.lastError].compactMap { $0 }
        if !lines.isEmpty || !model.lastWarnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { Text($0).foregroundStyle(.red) }
                ForEach(model.lastWarnings, id: \.self) { Text($0).foregroundStyle(.orange) }
            }
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Recent recordings

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show All") { Self.openRecordingsFolder() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("Each recording is a .screc package in Movies › Screc.")
            }
            .padding(.horizontal, 4)
            if model.recentRecordings.isEmpty {
                Text("No recordings yet")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                VStack(spacing: 1) {
                    ForEach(model.recentRecordings.prefix(4), id: \.self) { url in
                        RecentRow(url: url, highlighted: url == model.lastRecording) { openWindow(value: url) }
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    static func openRecordingsFolder() {
        let dir = AppModel.recordingsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}

// MARK: - Options popover

/// Countdown (REC-03), frame rate (REC-12), shortcut (REC-04), desktop icons (REC-08), speaker notes (REC-09).
struct RecorderOptionsView: View {
    @Bindable var model: AppModel
    @State private var recordingShortcut = false
    @State private var shortcutHint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            option("Countdown") {
                Picker("", selection: $model.countdown) {
                    Text("Off").tag(0)
                    Text("3 s").tag(3)
                    Text("5 s").tag(5)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            option("Frame rate") {
                Picker("", selection: $model.fps) {
                    Text("60").tag(60)
                    Text("120").tag(120).disabled(model.maxFPSForSelectedDisplay < 120)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                .help(model.maxFPSForSelectedDisplay < 120 ? "120 fps needs a ProMotion display." : "")
            }
            VStack(alignment: .leading, spacing: 6) {
                option("Shortcut") {
                    HStack(spacing: 6) {
                        Button {
                            shortcutHint = nil
                            recordingShortcut.toggle()
                        } label: {
                            Text(recordingShortcut ? "Type shortcut…" : model.hotKey.display)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(recordingShortcut ? Color.accentColor : .primary)
                                .frame(minWidth: 96)
                        }
                        .buttonStyle(PillButtonStyle(active: recordingShortcut))
                        .help("Click, then press the new start/stop shortcut. Esc cancels.")
                        .background(ShortcutRecorder(isRecording: $recordingShortcut,
                                                     onCapture: { combo in
                                                         model.hotKey = combo
                                                         shortcutHint = nil
                                                     },
                                                     onRejected: { shortcutHint = "That key alone is not allowed: add ⌘, ⌥ or ⌃ (for example ⌥⇧⌘R), or use a function key F1–F20." })
                                        .frame(width: 1, height: 1))
                        if model.hotKey != .default && !recordingShortcut {
                            Button { model.hotKey = .default } label: { Image(systemName: "arrow.uturn.backward") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .help("Reset to \(GlobalHotKey.Combo.default.display)")
                        }
                    }
                }
                if recordingShortcut || model.hotKeyProblem != nil {
                    Text(recordingShortcut ? (shortcutHint ?? "Press a combination with ⌘, ⌥ or ⌃, or a function key F1–F20. Esc cancels.")
                                           : (model.hotKeyProblem ?? ""))
                        .font(.system(size: 11))
                        .foregroundStyle(recordingShortcut && shortcutHint == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            option("Hide desktop icons") {
                Toggle("", isOn: $model.hideDesktopIcons).labelsHidden()
                    .disabled(model.sourceKind == .window)
            }
            .help("Covers the desktop icons while recording, without changing Finder settings.")
            option("Speaker notes") {
                Toggle("", isOn: $model.showSpeakerNotes).labelsHidden()
            }
            .help("A floating notes window that is not visible in the recording.")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 12))
        .padding(16)
        .frame(width: 300)
        .onChange(of: recordingShortcut) { _, recording in
            // Free the current shortcut while recording a new one, so it can be typed again.
            if recording { GlobalHotKey.shared.unregister() } else { model.registerHotKey() }
        }
        .onDisappear {
            if recordingShortcut {
                recordingShortcut = false
                model.registerHotKey()
            }
        }
    }

    private func option(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(title)
            Spacer()
            control()
        }
    }
}

// MARK: - Window resize (REC-07)

private struct WindowResizeRow: View {
    @Bindable var model: AppModel
    @State private var custom = false
    @State private var customW = 1600.0
    @State private var customH = 900.0

    private let presets: [CGSize] = [CGSize(width: 1280, height: 720), CGSize(width: 1440, height: 900), CGSize(width: 1920, height: 1080)]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                RowIcon(symbol: "arrow.up.left.and.arrow.down.right")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Resize window").font(.system(size: 13, weight: .medium))
                    Text("Set an exact size before recording").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(presets, id: \.width) { size in
                        Button("\(Int(size.width)) × \(Int(size.height))") {
                            custom = false
                            model.resizeSelectedWindow(to: size)
                        }
                    }
                    Divider()
                    Button("Custom…") { custom = true }
                } label: {
                    Text("Size")
                }
                .menuStyle(.button)
                .buttonStyle(PillButtonStyle())
                .fixedSize()
                .disabled(model.selectedWindow == nil)
            }
            if custom {
                HStack(spacing: 6) {
                    Spacer()
                    TextField("Width", value: $customW, format: .number).frame(width: 64)
                    Text("×").foregroundStyle(.secondary)
                    TextField("Height", value: $customH, format: .number).frame(width: 64)
                    Text("pt").foregroundStyle(.secondary)
                    Button("Apply") { model.resizeSelectedWindow(to: CGSize(width: customW, height: customH)) }
                        .buttonStyle(PillButtonStyle())
                        .disabled(model.selectedWindow == nil)
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

// MARK: - Building blocks

private struct SourceTile: View {
    let kind: AppModel.SourceKind
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var symbol: String {
        switch kind {
        case .display: "display"
        case .window: "macwindow"
        case .area: "rectangle.dashed"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 19, weight: .regular))
                    .frame(height: 22)
                Text(kind.rawValue).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? Color.accentColor : (hovering ? .primary : .secondary))
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(hovering ? 0.07 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.07), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct TrackRow: View {
    let symbol: String
    let offSymbol: String
    let title: String
    @Binding var isOn: Bool
    let available: Bool
    let unavailableText: String
    let devices: [AVCaptureDevice]
    @Binding var deviceID: String?
    var footnote: String?

    /// A switch left on for a device that is gone shows as off; recording ignores it too (AppModel.makeOptions).
    private var shownOn: Bool { isOn && available }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                RowIcon(symbol: shownOn ? symbol : offSymbol, active: shownOn)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    subtitle
                }
                Spacer()
                Toggle("", isOn: available ? $isOn.animation(.snappy(duration: 0.2)) : .constant(false))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!available)
            }
            if shownOn {
                if let footnote {
                    Text(footnote)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 38)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    @ViewBuilder
    private var subtitle: some View {
        if !available {
            Text(unavailableText).font(.system(size: 11)).foregroundStyle(.tertiary)
        } else if isOn && !devices.isEmpty {
            // Device choice lives in the subtitle: "System default ⌄".
            Menu {
                Toggle("System default", isOn: Binding(get: { deviceID == nil }, set: { if $0 { deviceID = nil } }))
                Divider()
                ForEach(devices, id: \.uniqueID) { d in
                    Toggle(d.localizedName, isOn: Binding(get: { deviceID == d.uniqueID }, set: { if $0 { deviceID = d.uniqueID } }))
                }
            } label: {
                HStack(spacing: 3) {
                    Text(devices.first { $0.uniqueID == deviceID }?.localizedName ?? "System default").lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            Text(isOn ? "On" : "Off").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct RecentRow: View {
    let url: URL
    let highlighted: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 12, weight: highlighted ? .semibold : .regular))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if hovering {
                // Selects screen.mov inside the .screc package, which Finder otherwise shows as one file.
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url.appendingPathComponent(BundleLayout.screen)])
                } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Show in Finder")
                Text("Open").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .help("Open in the editor")
    }
}

private struct MenuRowLabel: View {
    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 10) {
            RowIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

private struct RowIcon: View {
    let symbol: String
    var active = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? Color.white : .secondary)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Color.accentColor : Color.primary.opacity(0.07))
            )
            .contentTransition(.symbolEffect(.replace))
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

private struct Hairline: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1).padding(.leading, 50)
    }
}

private struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct PillButtonStyle: ButtonStyle {
    var active = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Color.accentColor.opacity(0.15) : Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08))
            )
            .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct RecordButtonStyle: ButtonStyle {
    let recording: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let top = recording ? Color(white: 0.32) : Color(red: 1.0, green: 0.27, blue: 0.23)
        let bottom = recording ? Color(white: 0.22) : Color(red: 0.86, green: 0.13, blue: 0.13)
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: (recording ? Color.black : Color.red).opacity(0.25), radius: 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.55)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// The frosted window background (behind-window blur, like a sidebar).
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
