import AppKit
@preconcurrency import AVFoundation
import ScrecCore
import ScrecExport
import ScrecRender
import Observation

/// One editor window (Phase 3): the project, its undo history and autosave, the AVPlayer that provides
/// sound and the clock, the prepared tracks the compositor draws from, and the UI state (selection, tools).
@MainActor
@Observable
final class EditorModel {
    enum Panel: String, CaseIterable, Identifiable {
        case background, cursor, camera, layout, captions, transcript, audio, keyboard, animation
        var id: String { rawValue }
        var title: String {
            switch self {
            case .background: "Background"
            case .cursor: "Cursor"
            case .camera: "Camera"
            case .layout: "Layout"
            case .captions: "Captions"
            case .transcript: "Transcript"
            case .audio: "Audio"
            case .keyboard: "Keyboard shortcuts"
            case .animation: "Animation"
            }
        }
        var symbol: String {
            switch self {
            case .background: "photo"
            case .cursor: "cursorarrow"
            case .camera: "video"
            case .layout: "rectangle.split.2x1"
            case .captions: "captions.bubble"
            case .transcript: "text.quote"
            case .audio: "speaker.wave.2"
            case .keyboard: "keyboard"
            case .animation: "wand.and.stars"
            }
        }
    }

    enum Selection: Equatable {
        case slice(String), zoom(String), mask(String), audio(String), layout(String)
    }

    enum Quality: Double, CaseIterable, Identifiable {
        case full = 1, half = 0.5, quarter = 0.25
        var id: Double { rawValue }
        var title: String { self == .full ? "Full" : self == .half ? "Half" : "Quarter" }
    }

    let bundle: URL
    let info: RecordingInfo
    let recordingDuration: Double
    let events: [TelemetryEvent]
    let hasCamera: Bool
    /// Long typing stretches found in the recording (Phase 5: speed-up typing).
    let typingStretches: [TypingSpeedUp.Stretch]

    private(set) var project: Project
    private(set) var prepared: PreparedProject
    /// Words of the voice (Phase 5: captions), saved in the bundle as transcript.json.
    private(set) var transcript: Transcript?
    /// What the Captions panel is doing right now.
    enum SpeechJob: Equatable { case idle, checking, downloading(Double), transcribing }
    private(set) var speechJob: SpeechJob = .idle
    /// Locale identifier chosen in the Captions panel, and whether its speech model is installed.
    var captionLanguage = "" { didSet { if oldValue != captionLanguage { Task { await refreshModelStatus() } } } }
    private(set) var captionLanguages: [(id: String, name: String)] = []
    private(set) var captionModelInstalled = false
    /// While cropping, the preview shows the whole recording (no crop, no zoom).
    private(set) var cropPreview: PreparedProject?

    // UI state
    var panel: Panel = .background
    var selection: Selection?
    /// Selected words in the Transcript panel (transcript indices).
    var wordSelection: Range<Int>?
    var maskTool: Mask.Kind?
    var pickingZoomPointFor: String?
    var isCropping = false { didSet { updateCropPreview() } }
    var quality: Quality = .full
    var canvasZoom: Double = 1
    var timelineZoom: Double = 1
    var showWaveform = true
    var playbackRate: Float = 1 { didSet { if player.rate != 0 { player.rate = playbackRate } } }
    var showPalette = false
    /// Safe-area guides for vertical social video (editor only).
    var showReelGuides = false
    var highlightedSetting: String?
    var message: String?

    // Playback
    let player = AVPlayer()
    let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ])
    var currentTime: Double = 0
    var isPlaying = false
    var duration: Double { prepared.timeMap.duration }
    /// Peak level per 20 ms of recording (source time), microphone and system audio combined.
    private(set) var waveform: [Float] = []
    static let waveformStep = 0.02

    @ObservationIgnored private var history = UndoHistory<Project>()
    private(set) var canUndo = false
    private(set) var canRedo = false
    @ObservationIgnored private var sources: [AVURLAsset] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var compositionTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?

    init(bundle: URL) throws {
        self.bundle = bundle
        info = try RecordingInfo.decode(from: Data(contentsOf: bundle.appendingPathComponent(BundleLayout.recording)))
        recordingDuration = info.duration ?? 0
        var project = try Project.decode(from: Data(contentsOf: bundle.appendingPathComponent(BundleLayout.project)))
        events = (try? TelemetryCodec.decodeFile(Data(contentsOf: bundle.appendingPathComponent(BundleLayout.events))).events) ?? []
        hasCamera = info.tracks.camera != nil
        typingStretches = TypingSpeedUp.stretches(events: events, recordingDuration: info.duration ?? 0)
        // First open: generate zooms from clicks and typing (SPEC §3.3).
        if !project.autoZoomDone {
            project.zooms = AutoZoom.generate(events: events, recordingDuration: info.duration ?? 0, existing: project.zooms)
            project.autoZoomDone = true
        }
        self.project = project
        let transcript = Transcript.load(bundle: bundle)
        self.transcript = transcript
        prepared = PreparedProject(project: project,
                                   recordingSize: CGSize(width: info.capture.videoPixelSize[0], height: info.capture.videoPixelSize[1]),
                                   pointPixelScale: info.capture.pointPixelScale, events: events, transcript: transcript,
                                   hasCamera: info.tracks.camera != nil)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = min(max(time.seconds, 0), self.duration)
                self.isPlaying = self.player.rate != 0
            }
        }
        scheduleSave()
    }

    /// What the canvas shows right now.
    var displayed: PreparedProject { cropPreview ?? prepared }

    func load() async {
        await rebuildComposition(keepingSourceTime: nil)
        await loadWaveform()
        await refineTranscriptIfNeeded()
    }

    /// Transcripts made before word times were matched to the audio get matched once, on open.
    private func refineTranscriptIfNeeded() async {
        guard let t = transcript, t.refined != true else { return }
        do {
            let r = try await AudioLevels.refine(t, bundle: bundle)
            try r.save(bundle: bundle)
            setTranscript(r)
        } catch {
            show("The transcript could not be matched to the audio: \(error.localizedDescription)")
        }
    }

    func close() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        saveNow()
    }

    // MARK: Editing

    /// Applies an edit with undo. Errors are shown as a short message; the project stays unchanged.
    func edit(_ change: (inout Project) throws -> Void) {
        var p = project
        do {
            try change(&p)
        } catch {
            show(error.localizedDescription)
            return
        }
        guard p != project else { return }
        history.willChange(from: project)
        apply(p)
    }

    /// Slider drags and block drags are one undo step.
    func beginGesture() { history.beginGroup() }
    func endGesture() { history.endGroup() }

    func undo() {
        guard let p = history.undo(current: project) else { return }
        apply(p)
    }

    func redo() {
        guard let p = history.redo(current: project) else { return }
        apply(p)
    }

    private func apply(_ p: Project) {
        let old = project
        project = p
        canUndo = history.canUndo
        canRedo = history.canRedo
        validateSelection()
        rebuildPrepared()
        if old.timeline.slices != p.timeline.slices || old.look.cursor.clickSound != p.look.cursor.clickSound {
            let keep = old.timeline.slices != p.timeline.slices ? TimeMap(slices: old.timeline.slices).toSource(currentTime) : nil
            compositionTask?.cancel()
            compositionTask = Task { await rebuildComposition(keepingSourceTime: keep) }
        } else if old.music != p.music || old.voice != p.voice {
            // Music is rendered to a file: wait until a slider stops moving.
            compositionTask?.cancel()
            compositionTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await rebuildComposition(keepingSourceTime: nil)
            }
        }
        scheduleSave()
    }

    private func validateSelection() {
        switch selection {
        case let .slice(id)? where !project.timeline.slices.contains { $0.id == id }: selection = nil
        case let .zoom(id)? where !project.zooms.contains { $0.id == id }: selection = nil
        case let .mask(id)? where !project.masks.contains { $0.id == id }: selection = nil
        case let .audio(id)? where !project.music.clips.contains { $0.id == id }: selection = nil
        case let .layout(id)? where !project.layouts.contains { $0.id == id }: selection = nil
        default: break
        }
    }

    private func rebuildPrepared() {
        rebuildTask?.cancel()
        let base = prepared, project = project, events = events, transcript = transcript
        rebuildTask = Task {
            let next = await Task.detached(priority: .userInitiated) { base.with(project: project, events: events, transcript: .some(transcript)) }.value
            guard !Task.isCancelled else { return }
            prepared = next
            updateCropPreview()
        }
    }

    private func updateCropPreview() {
        guard isCropping else {
            cropPreview = nil
            return
        }
        var p = project
        p.look.crop = [0, 0, 1, 1]
        p.zooms = []
        p.masks = []
        cropPreview = prepared.with(project: p, events: [])
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        do {
            try project.encoded().write(to: bundle.appendingPathComponent(BundleLayout.project), options: .atomic)
        } catch {
            show("Saving failed: \(error.localizedDescription)")
        }
    }

    // MARK: Playback

    private func rebuildComposition(keepingSourceTime s: Double?) async {
        do {
            let map = TimeMap(slices: project.timeline.slices)
            let preparedNow = PreparedProject(project: project, recordingSize: prepared.layout.recordingSize,
                                              pointPixelScale: prepared.pointPixelScale, events: events)
            let clicks = try ClickTrackWriter.file(for: preparedNow, bundle: bundle)
            let music: URL?
            do {
                music = try await MusicTrackWriter.file(for: preparedNow, bundle: bundle)
            } catch is CancellationError {
                return
            } catch {
                music = nil
                show("The music file could not be read: \(error.localizedDescription)")
            }
            let cleanMic: URL?
            do {
                cleanMic = try await VoiceCleaner.file(bundle: bundle, settings: project.voice)
            } catch is CancellationError {
                return
            } catch {
                cleanMic = nil
                show("Noise reduction failed: \(error.localizedDescription)")
            }
            guard !Task.isCancelled else { return }
            let result = try await CompositionBuilder.build(bundle: bundle, timeMap: map, slices: project.timeline.slices,
                                                            clickTrack: clicks, musicTrack: music, cleanMic: cleanMic)
            guard !Task.isCancelled else { return }
            sources = result.sources
            let wasPlaying = player.rate != 0
            let item = AVPlayerItem(asset: result.composition)
            item.audioTimePitchAlgorithm = .spectral          // speed changes keep the pitch (ED-09)
            item.audioMix = result.audioMix
            if let old = player.currentItem { old.remove(videoOutput) }
            item.add(videoOutput)
            player.replaceCurrentItem(with: item)
            let target = s.flatMap { map.toTimeline($0) ?? map.timelineAtOrAfter(source: $0) } ?? currentTime
            await seek(to: target)
            if wasPlaying { player.rate = playbackRate }
        } catch {
            show("The recording could not be prepared: \(error.localizedDescription)")
        }
    }

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
        } else if currentTime >= duration - 0.05 {
            Task {
                await seek(to: 0)
                player.rate = playbackRate
            }
        } else {
            player.rate = playbackRate
        }
        isPlaying = player.rate != 0
    }

    func seek(to t: Double) async {
        let target = CMTime(seconds: min(max(t, 0), duration), preferredTimescale: CMTimeScale(TimeMap.ticksPerSecond))
        currentTime = target.seconds
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Previous/next edit point: slice boundaries and zoom starts.
    func jump(forward: Bool) {
        var points = Set(prepared.timeMap.entries.flatMap { [$0.timelineStart, $0.timelineEnd] })
        for z in project.zooms {
            for r in prepared.timeMap.timelineIntervals(sourceStart: z.sourceStart, sourceEnd: z.sourceEnd) { points.insert(r.lowerBound) }
        }
        points.insert(0)
        points.insert(duration)
        let sorted = points.sorted()
        let target = forward ? sorted.first { $0 > currentTime + 0.01 } : sorted.last { $0 < currentTime - 0.01 }
        Task { await seek(to: target ?? (forward ? duration : 0)) }
    }

    // MARK: Actions used by the toolbar, timeline, menus and ⌘K

    func splitAtPlayhead() {
        if case let .audio(id)? = selection {
            let t = currentTime
            edit { try $0.splitAudio(id, at: t) }
            return
        }
        edit { try $0.split(atTimeline: currentTime) }
    }

    // MARK: Camera layouts (Phase 5)

    /// Adds a layout block of 4 s at the playhead (fitted between other blocks) and selects it.
    func addLayout(_ kind: LayoutKind) {
        let t = currentTime
        var id: String?
        edit { id = try $0.addLayout(kind, atTimeline: t) }
        if let id { selection = .layout(id) }
    }

    // MARK: Audio lanes (Phase 5)

    /// Adds a file to the Music lane (the whole video if the lane is empty, else from the playhead) or as a
    /// sound at the playhead, and selects it.
    func addAudio(path: String, lane: AudioClip.Lane) {
        let length = MusicTrackWriter.duration(of: path)
        guard length > 0 else { show("That file could not be read as audio."); return }
        let t = lane == .music && project.music.clips(on: .music).isEmpty ? 0 : currentTime
        var id: String?
        edit { id = try $0.addAudio(file: path, fileDuration: length, lane: lane, at: t) }
        if let id { selection = .audio(id) }
    }

    /// Puts another file into a clip (same place and length).
    func replaceAudioFile(_ id: String, path: String) {
        let length = MusicTrackWriter.duration(of: path)
        guard length > 0 else { show("That file could not be read as audio."); return }
        edit { try $0.updateAudio(id) { c in c.file = path; c.fileDuration = length; c.offset = 0 } }
    }

    func deleteSelection() {
        if selection == nil, panel == .transcript, wordSelection != nil {
            deleteSelectedWords()
            return
        }
        switch selection {
        case let .slice(id): edit { try $0.removeSlice(id) }
        case let .zoom(id): edit { p in p.zooms.removeAll { $0.id == id } }
        case let .mask(id): edit { p in p.masks.removeAll { $0.id == id } }
        case let .audio(id): edit { p in p.music.clips.removeAll { $0.id == id } }
        case let .layout(id): edit { p in p.layouts.removeAll { $0.id == id } }
        case nil: break
        }
    }

    func regenerateZooms() {
        edit { p in
            p.zooms = AutoZoom.generate(events: events, recordingDuration: recordingDuration, existing: p.zooms)
        }
        show("\(project.zooms.filter { $0.origin == .generated }.count) zooms generated from clicks and typing.")
    }

    /// Adds a zoom block at timeline time `t` (2 s, 2×, following the cursor).
    /// Adds a 2 s zoom at `t`, fitted into the free room between zooms (zooms never overlap).
    func addZoom(atTimeline t: Double) {
        let map = prepared.timeMap
        let at = min(max(t, 0), duration)
        guard let gap = project.zoomGap(at: at, map: map), gap.upperBound - gap.lowerBound >= 0.25 else {
            show("There is already a zoom here.")
            return
        }
        let start = min(max(at, gap.lowerBound), max(gap.upperBound - 2, gap.lowerBound))
        let s0 = map.toSource(start), s1 = map.toSource(min(start + 2, gap.upperBound))
        var newID = ""
        edit { p in
            newID = p.newID("Z")
            p.zooms.append(ZoomSegment(id: newID, sourceStart: s0, sourceEnd: max(s1, s0 + 0.25), scale: 2, mode: .auto, origin: .user))
        }
        selection = .zoom(newID)
    }

    /// Adds a mask over `rect` (normalised recording coordinates) for 3 s from the playhead.
    func addMask(kind: Mask.Kind, rect: CGRect) {
        let map = prepared.timeMap
        let s0 = map.toSource(currentTime), s1 = map.toSource(min(currentTime + 3, duration))
        var newID = ""
        edit { p in
            newID = p.newID("M")
            p.masks.append(Mask(id: newID, sourceStart: s0, sourceEnd: max(s1, s0 + 0.25), kind: kind,
                                rect: [rect.minX, rect.minY, rect.width, rect.height], strength: kind == .highlight ? 0.6 : 0.7))
        }
        selection = .mask(newID)
        maskTool = nil
    }

    /// The speed a typing stretch currently plays at (1 = not sped up).
    func currentSpeed(of stretch: TypingSpeedUp.Stretch) -> Double {
        let mid = (stretch.sourceStart + stretch.sourceEnd) / 2
        return project.timeline.slices.first { $0.sourceStart <= mid && mid < $0.sourceEnd }?.speed ?? 1
    }

    func speedUp(_ stretch: TypingSpeedUp.Stretch, speed: Double? = nil) {
        edit { try $0.applySpeed(sourceStart: stretch.sourceStart, sourceEnd: stretch.sourceEnd, speed: speed ?? stretch.suggestedSpeed) }
    }

    /// All suggestions in one undo step.
    func speedUpAllTyping() {
        let todo = typingStretches.filter { currentSpeed(of: $0) == 1 }
        guard !todo.isEmpty else { show("No typing left to speed up."); return }
        edit { p in for s in todo { try p.applySpeed(sourceStart: s.sourceStart, sourceEnd: s.sourceEnd, speed: s.suggestedSpeed) } }
        show("Sped up \(todo.count) typing stretch\(todo.count == 1 ? "" : "es").")
    }

    // MARK: Captions (Phase 5)

    /// Fills the language list once (the panel calls this when it opens). Default: the transcript's language,
    /// else the system language.
    func loadCaptionLanguages() async {
        guard captionLanguages.isEmpty, #available(macOS 26, *) else { return }
        speechJob = .checking
        let locales = await Transcriber.supportedLanguages()
        let current = Locale.current
        captionLanguages = locales.map { ($0.identifier, current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
            .sorted { $0.name < $1.name }
        if captionLanguage.isEmpty {
            if let t = transcript?.language {
                captionLanguage = t
            } else {
                captionLanguage = await Transcriber.supported(current)?.identifier ?? locales.first?.identifier ?? ""
            }
        }
        speechJob = .idle
        await refreshModelStatus()
    }

    private func refreshModelStatus() async {
        guard #available(macOS 26, *), !captionLanguage.isEmpty else { return }
        captionModelInstalled = await Transcriber.isInstalled(Locale(identifier: captionLanguage))
    }

    /// Downloads Apple's speech model for the chosen language (only when the user presses Download).
    func downloadCaptionModel() {
        guard #available(macOS 26, *), speechJob == .idle else { return }
        let locale = Locale(identifier: captionLanguage)
        speechJob = .downloading(0)
        Task {
            do {
                try await Transcriber.downloadModel(for: locale) { p in
                    Task { @MainActor in
                        if case .downloading = self.speechJob { self.speechJob = .downloading(p) }
                    }
                }
                speechJob = .idle
                await refreshModelStatus()
                show(captionModelInstalled ? "Speech model installed." : "The speech model could not be installed.")
            } catch {
                speechJob = .idle
                show("Download failed: \(error.localizedDescription)")
            }
        }
    }

    /// Transcribes the voice on this Mac and turns captions on.
    func transcribe() {
        guard #available(macOS 26, *), speechJob == .idle else { return }
        let locale = Locale(identifier: captionLanguage), bundle = bundle
        speechJob = .transcribing
        Task {
            do {
                let t = try await Transcriber.transcribe(bundle: bundle, locale: locale)
                try t.save(bundle: bundle)
                speechJob = .idle
                setTranscript(t)
                if !project.look.captions.enabled { edit { $0.look.captions.enabled = true } }
                show(t.words.isEmpty ? "No speech found." : "Transcribed \(t.words.count) words.")
            } catch {
                speechJob = .idle
                show(error.localizedDescription)
            }
        }
    }

    /// Replaces the text of one caption line (its words keep their time span). Saved right away.
    func correctCaption(line: CaptionTrack.Line, text: String) {
        guard var t = transcript, let first = line.words.first?.index, let last = line.words.last?.index else { return }
        let new = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard new != line.text else { return }
        t.replace(words: first..<(last + 1), with: new)
        do {
            try t.save(bundle: bundle)
            setTranscript(t)
        } catch {
            show("Saving the transcript failed: \(error.localizedDescription)")
        }
    }

    private func setTranscript(_ t: Transcript) {
        if t.words.count != transcript?.words.count { wordSelection = nil }
        transcript = t
        prepared = prepared.with(project: project, events: events, transcript: .some(t))
        updateCropPreview()
    }

    // MARK: Transcript editing (Phase 5)

    /// Click selects one word, Shift-click extends the selection. Both jump to the word.
    func selectWord(_ i: Int, extend: Bool) {
        guard let t = transcript, t.words.indices.contains(i) else { return }
        if extend, let s = wordSelection {
            wordSelection = min(s.lowerBound, i)..<max(s.upperBound, i + 1)
        } else {
            wordSelection = i..<(i + 1)
        }
        let w = t.words[i]
        if let time = prepared.timeMap.toTimeline(w.start) ?? prepared.timeMap.toTimeline((w.start + w.end) / 2) {
            Task { await seek(to: time) }
        }
    }

    /// Cuts the selected words (and half the silence around them) out of the video. One undo step.
    func deleteSelectedWords() {
        guard let t = transcript, let r = wordSelection else { return }
        let map = prepared.timeMap
        // Only the words that still play; already cut ones in the middle of the selection change nothing.
        let ranges = runs(in: r) { TranscriptEdit.isVisible(t.words[$0], timeMap: map) }
            .map { TranscriptEdit.cutRange(words: $0, in: t, recordingDuration: recordingDuration) }
        edit { try $0.cut(source: ranges) }
        wordSelection = nil
    }

    /// Brings back the cut words around word `i` (the whole run of consecutive cut words).
    func restoreWords(around i: Int) {
        guard let t = transcript else { return }
        let map = prepared.timeMap
        var lo = i, hi = i + 1
        while lo > 0, !TranscriptEdit.isVisible(t.words[lo - 1], timeMap: map) { lo -= 1 }
        while hi < t.words.count, !TranscriptEdit.isVisible(t.words[hi], timeMap: map) { hi += 1 }
        let r = TranscriptEdit.cutRange(words: lo..<hi, in: t, recordingDuration: recordingDuration)
        edit { $0.restore(source: r, recordingDuration: recordingDuration) }
    }

    /// Removes filler words and sounds, and shortens every pause longer than `longestPause` to that length,
    /// in one undo step.
    func cleanUpTranscript(fillers: Bool, pauses: Bool, longestPause: Double) {
        guard let t = transcript else { return }
        let map = prepared.timeMap
        let fillerRanges = fillers ? TranscriptEdit.fillerRuns(in: t, timeMap: map)
            .map { TranscriptEdit.cutRange(words: $0, in: t, recordingDuration: recordingDuration) } : []
        let pauseList = pauses ? TranscriptEdit.longPauses(in: t, timeMap: map, events: events, minimum: longestPause + 0.1, keep: longestPause) : []
        guard !fillerRanges.isEmpty || !pauseList.isEmpty else {
            show("Nothing to clean up.")
            return
        }
        let before = duration
        edit { try $0.cut(source: fillerRanges + pauseList.map(\.cut)) }
        wordSelection = nil
        let saved = before - TimeMap(slices: project.timeline.slices).duration
        show(String(format: "Removed %d filler%@ and %d pause%@ (%.1f s shorter).", fillerRanges.count, fillerRanges.count == 1 ? "" : "s",
                    pauseList.count, pauseList.count == 1 ? "" : "s", saved))
    }

    private func runs(in r: Range<Int>, where keep: (Int) -> Bool) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start: Int?
        for i in r {
            if keep(i) { if start == nil { start = i } } else if let s = start { out.append(s..<i); start = nil }
        }
        if let s = start { out.append(s..<r.upperBound) }
        return out
    }

    /// Writes the captions of the edited timeline as SubRip.
    func exportSRT() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = project.name + ".srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try prepared.captions.srt().write(to: url, atomically: true, encoding: .utf8)
            show("Saved \(url.lastPathComponent).")
        } catch {
            show("Saving failed: \(error.localizedDescription)")
        }
    }

    func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { message = nil }
        }
    }

    // MARK: Coordinates (canvas overlays)

    /// A point in the preview (0…1 of the visible canvas) → normalised recording coordinates, through the
    /// current camera (zoom) and layout.
    func recordingPoint(fromView uv: CGPoint) -> CGPoint {
        let p = displayed
        let cam = p.adjusted(p.camera.state(at: currentTime), at: currentTime)
        let canvas = CGPoint(x: cam.center.x + (uv.x - 0.5) / cam.scale, y: cam.center.y + (uv.y - 0.5) / cam.scale)
        return p.effectiveLayout(at: currentTime).recordingPoint(fromCanvas: canvas)
    }

    /// Normalised recording coordinates → 0…1 of the visible canvas.
    func viewPoint(fromRecording r: CGPoint) -> CGPoint {
        let p = displayed
        let cam = p.adjusted(p.camera.state(at: currentTime), at: currentTime)
        let c = p.effectiveLayout(at: currentTime).canvasPoint(fromRecordingNormalized: r)
        return CGPoint(x: (c.x - cam.center.x) * cam.scale + 0.5, y: (c.y - cam.center.y) * cam.scale + 0.5)
    }

    // MARK: Waveform

    private func loadWaveform() async {
        let bundle = bundle
        let files = [BundleLayout.mic, BundleLayout.system].map { bundle.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }
        let peaks = await Task.detached(priority: .utility) { () -> [Float] in
            var combined: [Float] = []
            for url in files {
                let p = (try? await Self.peaks(url: url, step: Self.waveformStep)) ?? []
                if combined.count < p.count { combined += [Float](repeating: 0, count: p.count - combined.count) }
                for i in p.indices { combined[i] = max(combined[i], p[i]) }
            }
            return combined
        }.value
        waveform = peaks
    }

    nonisolated private static func peaks(url: URL, step: Double) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 8000,
        ])
        reader.add(output)
        reader.startReading()
        let per = Int(8000 * step)
        var result: [Float] = []
        var current: Float = 0, count = 0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / 4)
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            for v in data {
                current = max(current, abs(v))
                count += 1
                if count == per {
                    result.append(current)
                    current = 0
                    count = 0
                }
            }
        }
        return result
    }

    // MARK: Favourite wallpapers

    var favouriteWallpapers: [String] {
        get { access(keyPath: \.favouriteWallpapers); return UserDefaults.standard.stringArray(forKey: "favouriteWallpapers") ?? [] }
        set {
            withMutation(keyPath: \.favouriteWallpapers) { UserDefaults.standard.set(newValue, forKey: "favouriteWallpapers") }
        }
    }
}
