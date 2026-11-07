# Screc: Architecture

Status: **1.0** (2026-11-07). Describes the app as built; the phase in a heading says when that part was added. Read together with `SPEC.md`.

This document explains *how* Screc is built: which modules exist, what data flows between them,
the on-disk formats, and the maths behind time mapping, smoothing and zoom. It is written for a
developer who is not a Swift expert, so each major decision has a short "why".

---

## 1. Big picture

```
 ┌──────────── Recording ────────────┐        ┌──────────────── Editing / Export ────────────────┐
 │ ScreenCaptureKit ─► screen.mov     │        │ project.json ─► Project (value type)             │
 │ SCStream audio   ─► mic.m4a        │        │        │                                         │
 │                  ─► system.m4a     │  .screc│        ▼                                         │
 │ AVCaptureSession ─► camera.mov     │ ─────► │ Timeline model ─► TimeMap (timeline ⇄ source)    │
 │ CGEventTap + display-rate sampler  │ bundle │        │                                         │
 │                  ─► events.jsonl   │        │        ▼                                         │
 └────────────────────────────────────┘        │ Motion tracks (precomputed, deterministic):      │
                                               │   CursorTrack · CameraTrack · ClickEffects      │
                                               │        │                                         │
                                               │        ▼                                         │
                                               │ Compositor.render(t) ── one function ──┐        │
                                               │        │                               │        │
                                               │   Preview (MTKView)              Export (AVAssetWriter)
                                               └──────────────────────────────────────────────────┘
```

The key design rule: **everything the compositor needs at timeline time `t` is a pure function of
`(project, t)`**. No state carries over from the previous frame, nothing reads the wall clock, and
nothing is random without a seed. That makes preview and export match frame for frame, and makes the
maths unit-testable.

---

## 2. Tech stack (confirmed, with two clarifications)

| Area | Choice | Why |
|---|---|---|
| Language/UI | Swift 6 (language mode 6), SwiftUI, AppKit where SwiftUI lacks control (event taps, floating panels, `MTKView`, window levels) | as specified |
| Min OS | macOS 15 | `SCStreamConfiguration.captureMicrophone` needs macOS 15, so the mic comes through the same stream and clock |
| Capture | ScreenCaptureKit, `showsCursor = false` | as specified |
| Webcam | AVCaptureSession, separate writer | as specified |
| Telemetry | listen-only `CGEventTap` + a display-link sampler | see §6.3 |
| Rendering | **Metal + MetalPerformanceShaders** (no Core Image in the render path) | *Clarification 1:* custom shaders give exact control over SDF corners, shadows, mesh gradients and motion blur. MPS supplies fast Gaussian blur. One code path, no hidden Core Image caching or colour management differences between preview and export. |
| Export | AVAssetWriter + VideoToolbox (H.264/HEVC), ImageIO for GIF | as specified. *Clarification 2:* ImageIO's own GIF palette is weak, so Screc quantises colours itself (median-cut + ordered dither, ~150 lines) before handing frames to ImageIO. No extra dependency. |
| Project | XcodeGen `project.yml` | text-based project, reproducible |
| Tests | Swift Testing (`import Testing`) + XCTest for performance/frame tests | built into Xcode, no dependency |

No third-party Swift packages are planned. See `DEPENDENCIES.md`.

---

## 3. Modules (Xcode targets)

```
project.yml
Screc/                      App target (SwiftUI app, windows, menus)
  App/                      ScrecApp, AppDelegate, window management
  Onboarding/               permission overview (Tools › Permissions…)
  Recorder/                 source picker, countdown, control bar, speaker notes, utilities
  Editor/                   editor window, timeline, inspectors, command palette, presets UI
  Resources/                app icon (original), localisable strings
ScrecCore/                  framework: pure Swift, no AppKit, no Metal
  Model/                    Project, Slice, ZoomSegment, Mask, Look, … (Codable)
  Schema/                   versioning + migrations of project.json
  Time/                     TimeMap, Rational time helpers
  Telemetry/                events.jsonl reader/writer, event types
  Motion/                   smoothing springs, CursorTrack, CameraTrack, AutoZoom generator
  Editing/                  edit operations (split, trim, merge, speed …), undo history
  Presets/                  preset save/load
ScrecCapture/               framework: ScreenCaptureKit, audio, webcam, event tap, bundle writer, recovery
ScrecRender/                framework: Metal compositor, shaders, cursor art, wallpapers, frame sources
  Shaders/*.metal
ScrecExport/                framework: MP4/GIF/clipboard export, AVComposition builder
Tools/screc-check/          command-line tool: verifies telemetry/video alignment, ffprobe checks
Tests/
  ScrecCoreTests/           time mapping, edit ops, smoothing, auto-zoom, schema migration
  ScrecRenderTests/         golden images, preview-vs-export frame diff
  ScrecExportTests/         duration, fps, A/V sync on generated test projects
```

**Why separate frameworks?** `ScrecCore` has no UI or GPU code, so its tests run in milliseconds and
the maths cannot accidentally depend on the screen. The compiler also enforces the direction of
dependencies:

```
Screc (app) ─► ScrecExport ─► ScrecRender ─► ScrecCore
          └──► ScrecCapture ───────────────► ScrecCore
screc-check ─► ScrecCore
```

### Concurrency (Swift 6)

- UI and the `ProjectStore` (holds the current `Project`, the undo history, and publishes changes) run on `@MainActor`.
- Capture callbacks arrive on dedicated serial `DispatchQueue`s. The writer classes are confined to their
  queue and marked `@unchecked Sendable` with that rule written next to them (AVFoundation types are not `Sendable`).
- Motion tracks are computed off the main thread in a `Task` whenever the relevant project parts change.
  They are immutable `Sendable` structs once built.
- The compositor owns one `MTLCommandQueue`. Export runs as a cancellable `Task`.

---

## 4. The `.screc` bundle

A `.screc` folder is registered as a document package (`LSTypeIsPackage`), so Finder shows it as one file.

```
Safari 2026-10-16 23.23.42.screc/   (Finder shows ":" as "/", so the folder uses dots; project.json keeps the real name)
  project.json        all edit state (versioned schema, §5)
  recording.json      immutable facts about the take (written at the start, finalised at stop)
  screen.mov          HEVC, no cursor, fragmented (movieFragmentInterval = 2 s)
  camera.mov          optional, H.264, fragmented
  mic.m4a             optional, AAC 48 kHz mono
  system.m4a          optional, AAC 48 kHz stereo
  events.jsonl        input telemetry, one JSON object per line
  background.<ext>    optional, user background image (copied in)
  cache/              derived data, safe to delete (waveforms, thumbnails, click-sound track)
  .recording          lock file, exists only while recording (used for crash recovery)
```

Default location: `~/Movies/Screc/`.

### 4.1 `recording.json`

```json
{
  "schemaVersion": 1,
  "id": "6E1C…",
  "startedAt": "2026-10-16T23:23:42+02:00",
  "sourceApp": "Safari",
  "capture": {
    "kind": "window",                     // display | window | area
    "displayID": 1,
    "displayPixelSize": [3456, 2234],
    "pointPixelScale": 2.0,
    "contentRectPoints": [120, 80, 1440, 900],  // capture rect in global points at start
    "videoPixelSize": [2880, 1800],
    "fps": 60
  },
  "clock": { "kind": "hostTime", "t0HostSeconds": 81234.123456 },
  "tracks": { "screen": "screen.mov", "camera": null, "mic": "mic.m4a", "system": "system.m4a" },
  "pauses": [ { "atSource": 12.40, "pausedFor": 7.92 } ],
  "duration": 42.317,
  "finalised": true
}
```

`t0HostSeconds` is the host time of the first screen frame. Every timestamp in the bundle is in seconds
relative to `t0`, with paused time removed (§6.2). That value is called **source time**.

### 4.2 `events.jsonl`

The first line is a header. Every following line is one event. `t` is source time in seconds
(microsecond precision). Positions are in **recording pixels** (top-left origin, same pixel grid as
`screen.mov`), so the compositor never has to convert screen coordinates.

```jsonl
{"type":"header","schema":1,"t0HostSeconds":81234.123456,"sampleHz":120,"videoPixelSize":[2880,1800]}
{"t":0.0000,"type":"pos","x":1402.5,"y":633.0}
{"t":0.0083,"type":"pos","x":1404.0,"y":634.5}
{"t":0.5120,"type":"down","button":"left","x":1410.0,"y":640.0,"clickCount":1}
{"t":0.6011,"type":"up","button":"left","x":1410.0,"y":640.0}
{"t":1.2000,"type":"scroll","dx":0,"dy":-12.5,"x":1410.0,"y":640.0}
{"t":2.0100,"type":"key","phase":"down","keyCode":0,"chars":"a","mods":["cmd"]}
{"t":2.0900,"type":"key","phase":"up","keyCode":0,"chars":"a","mods":["cmd"]}
{"t":2.0000,"type":"cursor","shape":"iBeam"}
{"t":3.5000,"type":"frame","rect":[0,0,2880,1800]}
```

- `pos` is written by the display-rate sampler, even when the mouse is still (lets us detect "not moving").
- `cursor` is written only when the shape changes. Shapes: `arrow, iBeam, pointingHand, openHand,
  closedHand, resizeLeftRight, resizeUpDown, crosshair, notAllowed, contextMenu, dragCopy, dragLink, unknown`.
- `frame` is written for window capture when the captured window moves or resizes (polled 10×/s). `rect` is the
  window frame in global points × `pointPixelScale`.
- `scroll` deltas are point deltas converted to recording pixels. Key auto-repeat is not logged (only real presses).
  Modifier keys produce `key` down/up events with empty `chars`.
- Lines are written in time order per 2 s chunk. Different input threads can deliver slightly late, so readers
  sort by `t` (stable).
- Points outside the captured area are kept (the cursor can leave and come back). The compositor clips them.
- Lines are buffered and `fsync`'d every 2 s, together with the video fragments.

---

## 5. `project.json` (edit state)

`project.json` holds only *decisions*. Everything that can be recomputed (motion tracks, waveforms,
generated click-sound track) is derived and cached in `cache/`. Unknown keys are kept when re-saving
(forward compatibility), and missing keys get defaults (backward compatibility).

### 5.1 Schema v1

```jsonc
{
  "schemaVersion": 1,
  "name": "Safari 2026-10-16 23:23:42",
  "timeline": {
    "slices": [
      {
        "id": "S1",
        "sourceStart": 0.0,
        "sourceEnd": 18.5,
        "speed": 1.0,
        "volume": 1.0,           // master for this slice
        "micVolume": 1.0,        // "external-device audio"
        "systemVolume": 1.0,
        "smoothMouse": true,     // false = "Disable smooth mouse movement"
        "hideCursor": false,
        "cursorOverride": null   // or a partial CursorLook, e.g. {"size": 2.0}
      },
      { "id": "S2", "sourceStart": 24.5, "sourceEnd": 42.3, "speed": 1.6, "...": "..." }
    ]
  },
  "zooms": [
    {
      "id": "Z1",
      "sourceStart": 3.1, "sourceEnd": 7.4,   // anchored to recording content (ED-08)
      "scale": 2.0,
      "mode": "auto",                          // auto | manual
      "manualCenter": null,                    // [x, y] in 0…1 recording coords when manual
      "origin": "generated"                    // generated | user  (re-generation keeps "user" zooms)
    }
  ],
  "masks": [
    { "id": "M1", "sourceStart": 0, "sourceEnd": 10, "kind": "blur", "rect": [0.6, 0.05, 0.3, 0.08], "strength": 0.8 }
  ],
  "look": {
    "aspect": "auto",                          // auto | 16:9 | 1:1 | 4:3 | 9:16 | 3:4 | 4:5
    "crop": [0, 0, 1, 1],                      // normalised recording rect
    "background": {
      "kind": "wallpaper",                     // wallpaper | gradient | color | image
      "wallpaper": "ocean-02",
      "gradient": { "type": "linear", "angle": 135, "stops": [["#FF8A5B", 0], ["#7B5CFF", 1]] },
      "color": "#1E1E24",
      "image": "background.jpg",
      "blur": 0
    },
    "frame": {
      "padding": 0.10, "cornerRadius": 12, "inset": false,
      "shadow": { "amount": 0.5, "style": "classic", "angle": 90, "distance": 0.3, "softness": 0.6 }
    },
    "cursor": {
      "style": "standardArrow", "color": "#FF5A36", "size": 1.5,
      "alwaysPointer": false, "hideWhenIdle": false, "loop": false, "hidden": false,
      "clickEffect": "ripple", "clickSound": "none",
      "rotation": { "enabled": false, "maxDegrees": 8 },
      "smoothingOverride": null
    },
    "animation": { "screen": "focused", "cursor": "smooth", "motionBlur": 0 }
  },
  "audio": { "background": null, "voice": "standard" },   // Phase 5 fills these in
  "camera": null, "layouts": [], "captions": null,        // Phase 5
  "export": { "format": "mp4", "resolution": "1080p", "fps": 60, "codec": "hevc" }
}
```

In Swift, every object is a `struct` that is `Codable, Equatable, Sendable`. The whole project is one value.

### 5.2 Versioning

- `schemaVersion` is an integer. `ScrecCore/Schema/Migrations.swift` holds one function per step
  (`v1 → v2`, …), applied in order to the raw JSON before decoding.
- Every migration has a test with a stored sample file of the old version.
- A project with a newer version than the app understands opens read-only, with a warning.

### 5.3 Undo/redo

The project is a small value (kilobytes), so undo uses **snapshots**: before each edit the previous
`Project` is pushed onto the undo stack (max 200). Continuous gestures (slider drags, block drags)
open a *coalescing group*, so one drag is one undo step. This is simpler and more robust than writing
an inverse for every operation, and memory use is small.

### 5.4 Presets

Stored in `~/Library/Application Support/Screc/Presets/<name>.json` as
`{ "schemaVersion": 1, "name": "...", "look": { background, frame, cursor, animation } }`.
`aspect` and `crop` are excluded, because they belong to the specific recording.

---

## 6. Recording pipeline (Phase 1)

### 6.1 Streams

- **One `SCStream`** delivers screen frames and system audio (`capturesAudio`).
- **Microphone:** its own `AVCaptureSession` (like the webcam), with timestamps converted to host time by
  `CMSyncConvertTime`. *Changed 2026-10-23:* replaces the planned ScreenCaptureKit microphone output
  (`captureMicrophone`) so a missing or busy device gives a clear error. (The owner's "no sound" turned out
  to be a Mac mini without any microphone; the microphone path is still untested on real hardware.)
  Every writer stores counters
  (received / written / outside the take / first-timestamp offset) in `recording.json › diagnostics`.
- `SCContentFilter` excludes all of Screc's own windows (control bar, speaker notes, countdown).
  *Why not `NSWindow.sharingType = .none`?* On recent macOS versions ScreenCaptureKit does not
  reliably respect it, while filter exclusion is explicit.
- Window capture uses `SCContentFilter(desktopIndependentWindow:)`. Area capture uses display capture with
  `sourceRect`.
- ScreenCaptureKit only sends a new frame when the screen changes (variable frame rate). Frames with
  status `.idle` carry no image and are skipped. The writer stores real timestamps, so the file is VFR. That's fine (see §8.2).
- The webcam runs in its own `AVCaptureSession`. Its sample timestamps are converted to host time with
  `CMSyncConvertTime(…, session.synchronizationClock, CMClockGetHostTimeClock())`.
  One `CameraSource` (the session) is shared by the live preview bubble and the recorder, so the camera is
  opened once. An iPhone as Continuity Camera can change its picture size or repeat a timestamp mid-stream,
  which made `AVAssetWriter` fail after a few frames; the recorder now scales frames to the first frame's size
  (`VTPixelTransferSession`, letterbox) and skips frames that are not newer than the last one. Writer errors
  are logged with domain and code (`errorCode` in the diagnostics).
- **Live camera preview:** while the camera is on (recorder open, countdown or recording), a round, mirrored
  `AVCaptureVideoPreviewLayer` panel floats on screen (`sharingType = .none`, and excluded like every Screc
  window). It snaps to the nearest corner after a drag; that corner is written into the new recording's
  `look.webcam.corner`.

### 6.2 Writing, pause and crash safety

- One `AVAssetWriter` per file, `movieFragmentInterval = 2 s`. If the app crashes, the file is still
  readable up to the last fragment.
- A shared `RecordingClock` turns host time into source time: `source = host − t0 − pausedSoFar`.
  While paused, samples and events are dropped. **Video, audio and telemetry all go through this one
  function**, so they cannot drift apart.
- The telemetry writer `fsync`s on the same 2 s timer.
- `.recording` lock file: created at start, removed after a clean stop. At launch, Screc looks for
  bundles that still have a lock file. It offers to recover them: rewrite the fragmented file into a normal
  one (AVAssetExportSession passthrough), truncate `events.jsonl` to the video duration, and finalise
  `recording.json`.

### 6.3 Telemetry

- **Listen-only `CGEventTap`** (`.listenOnly`) for mouse down/up/drag, scroll, key down/up and flags
  changed. It needs **Input Monitoring** permission (not Accessibility).
- **Position sampler** on the display link of the captured screen (`NSScreen.displayLink`, macOS 14+).
  It runs at the display refresh rate (120 Hz on ProMotion) and reads `NSEvent.mouseLocation` plus
  `NSCursor.currentSystem`. The cursor shape is identified by comparing the image and hotspot with the
  standard `NSCursor` constants (cached hash).
- **Timestamps:** event-tap events carry `CGEventGetTimestamp`. Its unit (nanoseconds or mach ticks) is detected
  at tap start from a fresh `CGEvent` (whichever reading is closest to "now") and stored in the `events.jsonl`
  header as `eventTimestampUnit`. Sampler ticks are stamped with the host time **at the moment
  `NSEvent.mouseLocation` is read** (the display link's own timestamp describes the previous frame). Both go
  through `RecordingClock`.
- Coordinates: global points (bottom-left origin from AppKit / top-left from CG) are converted at write
  time into recording pixels, using the capture rect at that moment.

### 6.4 Alignment proof (`screc-check`)

A flash-based test (click → window changes colour) would also measure the app's own drawing delay,
so it is not a fair test. Instead:

1. `screc record --calibrate` records 20 s with `showsCursor = true` (calibration mode only). Meanwhile a
   helper posts synthetic mouse moves along a known Lissajous path.
2. `screc-check align <bundle>` finds the system cursor in each video frame (difference against a
   cursor-free reference frame, then the centroid). It cross-correlates that track with the `pos` events and
   reports the time offset and the RMS position error.
3. **Pass:** |offset| ≤ 1 frame (16.7 ms at 60 fps), and the RMS error is a few pixels.

### 6.5 Utilities

- **Window resize:** Accessibility API (`AXUIElementSetAttributeValue` with `kAXSizeAttribute`). It needs
  Accessibility permission, which is only asked for when this feature is used.
- **Hide desktop icons:** a borderless window at desktop-icon level + 1 showing the current desktop
  picture (`NSWorkspace.desktopImageURL`). It covers the icons, and it *is* captured, so the recording
  looks clean. Finder settings are never changed, so nothing needs undoing after a crash.
- **Global shortcut:** Carbon `RegisterEventHotKey`. It needs no permission and no dependency.

---

## 7. Motion: cursor, camera, auto-zoom (Phases 2–3)

All motion is computed **once per project change** into tracks sampled at a fixed internal rate
(`simHz = 240`). Rendering reads a track by linear interpolation between samples. The result never
depends on the preview frame rate, on scrubbing order, or on dropped frames.

### 7.1 Cursor track

1. **Raw path in timeline time.** Each `pos`/`down`/`up` event at source time `s` is mapped to timeline time
   `t = toTimeline(s)` (§8). Events inside cuts are dropped. At a cut boundary the raw path jumps.
2. **Smoothing:** a critically damped spring follows the raw path, simulated at `simHz` over timeline time.
   The presets set the spring's response (Smooth/Medium/Rapid; None = raw). In slices with
   `smoothMouse = false` the output is the raw path.
   *Why timeline time and not source time?* At 2× speed the cursor should still look calm on screen.
   Also, across a cut the cursor glides smoothly to its new position instead of teleporting.
3. **Click lock:** around each mouse-down the smoothed position is blended to the true click point
   (±60 ms), so clicks always land exactly on the clicked element.
4. **Shape:** the latest `cursor` event at or before `s` (or `arrow` when `alwaysPointer`).
5. **Visibility/opacity:** `hideCursor` slices → 0. `hideWhenIdle` → fade out after 1.5 s without movement, fade in over 0.15 s.
6. **Loop:** if enabled, during the last 1.0 s the position eases (cubic) from the smoothed path to the position at `t = 0`.
7. **Rotation:** the angle follows the horizontal velocity (clamped to ±maxDegrees) through its own spring.

### 7.2 Camera track (zoom transform)

The camera is `(scale z, center c)` in normalised recording coordinates.

- **Target scale:** 1 outside zoom segments, `zoom.scale` inside. Segments are mapped from source to
  timeline time. Scale transitions are **spring steps in timeline time**: zoom-in starts at the segment's
  timeline start, zoom-out starts at its timeline end. Each step is the closed-form critically damped
  spring `z(t) = z₀ + (z₁ − z₀)·(1 − (1 + ωt)·e^(−ωt))`, linear in `z`, with ω from the Animation style
  (SPEC §3.3: Focused 12/s, Smooth 6.7/s). If a new step starts before the previous one has settled,
  the step starts from the current value **and velocity** (closed form:
  `x(t) = x₁ + (A + Bt)·e^(−ωt)` with `A = x₀ − x₁`, `B = v₀ + ωA`). So it is still evaluated
  analytically, without simulation. This model fits 16 sample transitions with an
  RMS error of 0.5–3.6 % of the transition. The best cubic ease-in-out fits 2–20× worse.
- **Target center:** Manual = `manualCenter`. Auto = follow the smoothed cursor with a **dead zone**: the
  view center moves only when the cursor leaves the central `followDeadZone` part of the current view.
  Then it moves just enough to bring the cursor back, and it always keeps `followEdgeMargin`.
  Measured: the cursor sits at 65–74 % of the view height while the camera follows, so `followDeadZone`
  ≈ 0.3–0.5 (default 0.4, SPEC §3.3).
- **Smoothing the center:** the same critically damped spring as the scale (ω from the style), simulated
  at `simHz` because the target moves continuously. The center moves **together with** the zoom-in, not
  after it (measured: the pan towards the target finishes with the scale).
- **Clamping:** the visible region `1/z` wide is always kept inside the content (`c ∈ [1/(2z), 1 − 1/(2z)]`),
  so the zoom never shows past the recording edge.
- **Whole composition** *(high confidence)*: the zoom scales the whole composition
  (wallpaper, padding, shadow and screen together) around the zoom point. A single similarity transform
  explains every pixel of the frame during the zoom, including the wallpaper at the edges, so the
  background really is scaled, not fixed. So the compositor applies the camera transform to the whole
  composited canvas, and at high zoom the background moves out of view.

### 7.3 Auto-zoom generation

Input: telemetry (source time) and `AutoZoomConfig` (SPEC §3.3). Output: `[ZoomSegment]` with `origin = generated`.

```
1. actions  = clicks (mouse-down, any button)
            + typing bursts (key-downs with gaps ≤ typingKeyGap, count ≥ typingMinKeys)
   drop actions within ignoreEdges of recording start/end
2. intervals: click  → [down − leadTime, up + clickHold]   (a drag holds the zoom until mouse-up)
              burst  → [first − leadTime, last + typingHold]
3. sort, merge intervals whose gap < mergeGap
4. extend each interval shorter than minDuration (to the right, else to the left)
5. clamp to [0, recordingDuration]; scale = defaultScale; mode = auto
6. keep existing zooms with origin = user; drop generated ones that overlap them
```

It is a pure function, `generateZooms(events, config, existingZooms) -> [ZoomSegment]`, with unit tests for
each rule.

---

## 8. Time mapping (timeline ⇄ source)

### 8.1 Definitions

- **Source time `s`:** seconds into the recording (paused time already removed). `0 ≤ s ≤ D`.
- **Timeline time `t`:** seconds into the edited result. `0 ≤ t ≤ T`.
- Slices `S₀ … Sₙ₋₁`, each with `aᵢ = sourceStart`, `bᵢ = sourceEnd`, `vᵢ = speed`.

**Invariants** (checked after every edit):

```
0 ≤ a₀,   aᵢ < bᵢ,   bᵢ ≤ aᵢ₊₁,   bₙ₋₁ ≤ D,   vᵢ ∈ [0.25, 16]
```

Slices are ordered by source time and never overlap. Screc does not reorder clips.

**Derived:**

```
dᵢ  = (bᵢ − aᵢ) / vᵢ            timeline duration of slice i
T₀  = 0,  Tᵢ₊₁ = Tᵢ + dᵢ         timeline start of slice i  (prefix sum)
T   = Tₙ                         total timeline duration
gᵢ  = aᵢ₊₁ − bᵢ                  cut between slice i and i+1  (badge "gᵢ s ✂" if gᵢ > 1 frame)
```

**Timeline → source:** find `i` with `Tᵢ ≤ t < Tᵢ₊₁` (binary search). Then
`s = aᵢ + (t − Tᵢ) · vᵢ`. For `t = T`, use the last slice's `bₙ₋₁`.

**Source → timeline:** find `i` with `aᵢ ≤ s < bᵢ`. Then `t = Tᵢ + (s − aᵢ) / vᵢ`.
If `s` lies in a cut or trim, the result is `nil`. Snapping variants (`nextVisible`, `previousVisible`) return the nearest slice edge.

**Mapping an interval** (zooms, masks, captions) from source to timeline gives a list of timeline
intervals, one per slice it overlaps. A zoom across a cut shows as two blocks that are still one object.
If you drag one of them, the whole object moves.

### 8.2 Frames and rounding

- All timeline maths uses `Double` seconds for editing. One function, `TimeMap.build(slices) -> TimeMap`,
  turns each `dᵢ` into a `CMTime` with timescale 60 000 and computes `Tᵢ` from the *rounded* values.
  The AVComposition and the compositor both use this one `TimeMap`, so they can never disagree by a rounding step.
- Output frame `k` is at `tₖ = k / fps`. Frame count `N = round(T · fps)`. Audio is cut to `N / fps`.
- **Frame selection rule** (identical in preview and export): for `tₖ`, use the decoded source frame with the
  largest presentation time `≤ s(tₖ)`. There is no frame blending. This also handles the VFR screen file.

### 8.3 Edit operations (all in `ScrecCore/Editing`, all unit-tested)

| Operation | Effect |
|---|---|
| Split at `t` | `s = toSource(t)`, slice `i` → `[aᵢ, s)` and `[s, bᵢ)`, both keep speed and overrides. Refused within 0.1 s of an edge. |
| Trim left/right | move `aᵢ` within `[bᵢ₋₁ (or 0), bᵢ − 0.1]`, or `bᵢ` within `[aᵢ + 0.1, aᵢ₊₁ (or D)]` |
| Remove slice | delete `Sᵢ`. A cut badge appears automatically. |
| Set speed | change `vᵢ`. Everything after it shifts in timeline time, and content-anchored items stay on their content. |
| Apply speed to all | `vⱼ = vᵢ` for all `j` |
| Reset slice trim | extend `aᵢ` to `bᵢ₋₁` (or 0) and `bᵢ` to `aᵢ₊₁` (or D) |
| Merge with next | `[aᵢ, bᵢ₊₁)` with `Sᵢ`'s speed and overrides (restores any cut between them) |
| Reset trims and cuts for all | `a₀ = 0`, `bₙ₋₁ = D`, and every gap closes by extending `bᵢ` to `aᵢ₊₁`. Splits, speeds and overrides stay. [unknown] |

### 8.4 Audio

The `AVMutableComposition` is built from the `TimeMap`: for each slice, insert `[aᵢ, bᵢ)` of each audio track
and call `scaleTimeRange` to `dᵢ`. Pitch is kept with `audioTimePitchAlgorithm = .spectral`
(on both the player item and the export reader). Volumes go through `AVMutableAudioMix` with short ramps
(10 ms) at slice boundaries to avoid clicks. The click sound and, in Phase 5, background music are
rendered into audio files in `cache/` and added as extra composition tracks, so preview and export hear the same thing.

---

## 9. Compositor (Phase 2)

### 9.1 Interface

```swift
struct RenderRequest: Sendable {
  let t: Double                 // timeline time
  let outputSize: SIMD2<Int>    // export size, or preview size × quality
}
protocol FrameSource { func frame(atSource s: Double) async throws -> SourceFrame }  // pixel buffer + its PTS
final class Compositor {
  init(device: MTLDevice, project: Project, tracks: MotionTracks, sources: FrameSources)
  func render(_ r: RenderRequest, into texture: MTLTexture, commandBuffer: MTLCommandBuffer) async throws
}
```

### 9.2 Passes (per frame)

1. **Layout:** from `aspect`, `crop`, `padding` → output canvas size, screen rect, corner radius in pixels
   (all sizes defined relative to a 1080p reference, then scaled, so every resolution looks the same).
2. **Scene pass** into an offscreen texture of size `output × min(z, sourceDensity)`. That keeps zoomed
   content sharp without rendering more pixels than the source has.
   1. Background: wallpaper shader (mesh gradient from a parameter table, seeded), gradient, color or image.
      Optional MPS Gaussian blur.
   2. Shadow: analytic soft shadow of a rounded rectangle (SDF + Gaussian approximation). Classic or directional offset.
   3. Screen: source frame (YUV → RGB in the shader), crop, rounded-corner mask (SDF with 1 px antialiasing), optional inset border.
   4. Masks: blur (MPS on the masked region), hide (fill), highlight (dim outside the rect).
   5. Cursor: sprite from a vector atlas (CGPath → texture at the needed size bucket), with hotspot, rotation and opacity.
      Motion blur: drawn K times along the path over the shutter interval with equal weights.
   6. Click effects: circle/ripple as SDF rings, driven by time since mouse-down.
3. **Camera pass:** sample the scene with the camera transform (§7.2). With motion blur > 0, take M taps
   (M = 8) along the transform path from `t − shutter/2` to `t + shutter/2` and average them. For a 2D
   scale/translate this matches real motion blur closely.
4. **Overlays (not zoomed):** webcam, captions, keyboard overlay (Phase 5).

**Shaders** (`ScrecRender/Shaders/Compositor.msl`) are shipped as Metal source and compiled by Metal when the
compositor is created (about 0.1 s, once). *Why:* Xcode 27 no longer includes the build-time Metal compiler; it is
a separate download (`xcodebuild -downloadComponent MetalToolchain`), and Screc avoids extra installs. Fast math is
off (`mathMode = .safe`) so preview and export compute identically.

**Sizes** (all relative to the recording, so the result looks the same at every output resolution):
cursor art height = 28 screen points × `pointPixelScale` × cursor size; click effect radius = 16 points × scale × size,
lasting 0.45 s; corner radius and inset are "1080p reference pixels"; shadows are fractions of the canvas' short
side (classic: offset 1.2 %, blur 3.5 %, opacity 0.55 × amount).

**Measured cost** (`screc-check bench`, Apple M6, motion blur 100 + zoom): 1.5 ms per frame at 1080p, 3.4 ms at 4K.

### 9.3 Determinism rules

- No wall clock, no `random()` without a seed stored in the project, no frame-to-frame state in shaders.
- The preview uses the same `Compositor` and the same `TimeMap`. Only `outputSize` differs (Half/Quarter quality).
- Colour: all passes work in linear light in `rgba16Float`. One final conversion to the output colour space
  (Rec. 709 for export, the display's space for preview through `CAMetalLayer.colorspace`). The frame-diff test
  compares in the export space.
- **Frame-diff test:** for 3 timestamps, render the "preview path" (preview frame source, Full quality) and
  decode the exported file. They must match with PSNR ≥ 40 dB (allowing for encoder loss), and must be bit-identical
  before encoding.

### 9.4 Frame sources

- **Export:** `AVAssetReader` on the composition's video track, read in order. That is fast and exact.
- **Preview while playing:** `AVPlayer` on the same composition (it gives audio playback and the master clock),
  with `AVPlayerItemVideoOutput` delivering pixel buffers.
- **Preview while scrubbing/paused:** `AVAssetImageGenerator` with zero time tolerance.
- **Risk:** if `AVPlayerItemVideoOutput` picks frames differently from §8.2, the frame-diff test will show it.
  Fallback: our own `VTDecompressionSession` decoder with a small frame cache, used by both preview and export.

---

## 10. Export (Phase 4)

- **MP4:** loop `k = 0 … N−1`: render `tₖ` into an `IOSurface`-backed pixel buffer from a
  `CVPixelBufferPool` → `AVAssetWriterInputPixelBufferAdaptor` (HEVC or H.264, hardware encoder via
  VideoToolbox, `AVVideoExpectedSourceFrameRateKey`, bitrate by resolution). Audio is read with
  `AVAssetReaderAudioMixOutput` from the same composition and audio mix, then written as AAC.
- **GIF:** render at GIF size/fps → own palette quantiser (per frame, median cut, ordered dither) →
  `CGImageDestination` with loop count 0. Unchanged pixels between frames are written as transparent to shrink the file.
- **Clipboard:** `NSPasteboard` with the file URL (`NSPasteboard.PasteboardType.fileURL`).
- **Progress/cancel:** the export `Task` reports `k / N` and checks `Task.isCancelled` each frame. When cancelled,
  it calls `cancelWriting()` and deletes the partial file.
- **Proof (Phase 4):** `ffprobe` checks resolution, `r_frame_rate`, duration against
  `N / fps`, and A/V start offsets. Sync is tested with a generated project that has a beep + flash at known timeline times.

---

### 10.1 As built in Phase 4

- `ScrecExport/Exporter.swift`: MP4 (H.264/HEVC, the hardware encoder is *required*, export fails rather than
  falling back to software), GIF, progress with time left, cancel deletes the partial file. Sound is read with
  `AVAssetReaderAudioMixOutput` from the same composition and audio mix as the preview (pitch kept at other speeds).
- **Frame source** (`SourceFrameReader`): `AVAssetReader` on the composition, frame-selection rule of §8.2.
- **Colour:** the compositor writes sRGB-encoded BGRA; the file is tagged BT.709 (primaries, transfer, matrix).
  Colour-managed players (QuickTime) therefore show it about 2–3 levels different from the preview; the pixels match.
- **GIF:** own median-cut palette per frame + 8×8 ordered dither (`GIFQuantizer`), loop count 0. Frame delays are whole
  hundredths of a second chosen from rounded running totals (7, 7, 6, …) so the duration stays exact. *Not done:* writing
  unchanged pixels as transparent (ImageIO gives no transparent-index control); GIFs are therefore larger than they
  could be. About 5 frames/s at 720p.
- **Proof tools** (`screc-check`): `make-fixture` (flashes + beeps, a cut and a 1.5× slice), `export` (headless,
  `--cancel-after`), `framediff` (EX-06: preview path = `AVPlayerItemVideoOutput`, export path = `AVAssetReader`; the
  rendered frames must be bit-identical, the decoded export ≥ 40 dB PSNR; decoded with `AVAssetReader`, because
  `AVAssetImageGenerator` colour-manages and shifts levels).
- **Measured** (2026-10-30, Apple M6): 1080p60 export of a 23 s take in 4.6 s, 4K30 in 7.7 s; fixture A/V offset ≤ 7.7 ms,
  flashes on the exact frame; preview vs export bit-identical, export 44–50 dB.

## 11. Editor UI (Phase 3)

- `ProjectStore` (`@MainActor @Observable`): current `Project`, undo history, a debounced autosave (0.5 s)
  to `project.json` (written to a temp file, then atomically replaced).
- Timeline is drawn with SwiftUI `Canvas` for the tracks (fast for long recordings). Gestures map pixels → timeline time
  → source time through the `TimeMap`.
- Inspector panels bind to `Look` key paths. A single `SettingDescriptor` table (key path, label, synonyms,
  panel, control type, default) drives the inspectors, Reset buttons, the ⌘K palette and presets. A setting
  added there shows up everywhere automatically.
- ⌘K: fuzzy match (subsequence scoring with bonuses for word starts), implemented in ~80 lines, no dependency.

---

### 11.1 As built in Phase 3

- **Windows:** one editor window per recording (`WindowGroup` keyed by the bundle URL), opened from *Recent
  recordings* or *Open*. The project name in the title bar is renamed in place.
- **Model:** `EditorModel` holds the project, a snapshot `UndoHistory` (slider and block drags are one step),
  a 0.5 s debounced atomic autosave, the `AVPlayer` (composition rebuilt only when slices or the click sound
  change; the playhead stays on the same recording moment), and the prepared tracks (rebuilt off the main thread).
- **Auto-zoom on first open:** zooms are generated once when a project is first opened; `project.autoZoomDone`
  stops them from coming back after the user deletes them. *Regenerate Auto-Zooms* replaces only generated ones.
- **Timeline:** clip track (slices `8.0s ⊙2x`, cut badges `4.0s ✂`, waveform), zoom track (click an empty spot
  to add a 2 s zoom), and a **mask track** (needed to edit mask time ranges). Block labels
  use SF Symbols instead of emoji (🖱 does not render reliably at small sizes).
- **Canvas overlays** map view points through the current camera and layout (`Layout.recordingPoint(fromCanvas:)`):
  drawing and editing masks, picking a manual zoom point, and cropping (the preview then shows the whole recording).
- **Keys:** Space play/pause, C split, ⌫ delete selection, ←/→ previous/next edit point, Esc cancel — handled by a
  window-local key monitor that ignores them while a text field is being edited. ⌘K, ⌘Z, ⇧⌘Z via the toolbar.
- **Phase 5 panels** (Camera, Layout, Captions, Transcript, Keyboard shortcuts, the Phase 5 half of Audio) show
  only working controls and a labelled "Phase 5" note (owner decision 2026-10-23).
- **Export** button is shown but disabled with the note "Export arrives in Phase 4".

### 11.2 As built in Phase 5

- **Keyboard-shortcut overlay:** `KeyOverlayTrack` (ScrecCore) turns `key` events into badges in timeline time;
  labels use the recorded layout letter (`key`, from `UCKeyTranslate`) so QWERTZ shows ⌘Z, not ⌘Y.
  `KeyBadgeArt` rasterises keycaps with CoreText; the compositor draws them in the overlay pass (not zoomed).
- **Speed-up typing:** `TypingSpeedUp` finds typing stretches (≥ 3 s, ≥ 10 keys) and suggests a speed;
  applying it splits the slice and sets its speed (one undo step).
- **Captions:** `Transcriber` (ScrecExport, macOS 26+) runs Apple's on-device `SpeechAnalyzer` +
  `SpeechTranscriber` on `mic.m4a` (else `system.m4a`) and keeps word times (`.audioTimeRange`). The result is
  saved as `transcript.json` in **source time**, so cuts and speed changes never need a new transcription.
  `CaptionTrack` maps words through the `TimeMap` (words inside cuts are dropped) and breaks lines on pauses
  > 0.6 s, cuts, sentence ends, 64 characters or 5 s. `CaptionArt` rasterises a line (Classic, Bold, Highlight,
  Minimal); the compositor draws it in the overlay pass and moves a bottom key badge above it. `.srt` comes
  from the same lines, so it matches the edited timeline. Speech models are downloaded only when the user
  presses *Download Speech Model*. Line corrections keep the line's time span and are saved immediately
  (not part of undo). Font (system designs or any installed family; missing fonts fall back to the system font), text,
  spoken-word and box colours, and box opacity are part of `CaptionLook`.
- **Transcript editing:** `TranscriptEdit` (ScrecCore) turns word edits into **source ranges**, and
  `Project.cut(source:)` removes them by splitting slices (pieces keep speed, volumes and overrides);
  `Project.restore(source:)` brings cut parts back. Deleting words removes them plus half the silence on each
  side. *Clean Up* removes filler runs (um, uh, äh, ähm, …) and shortens pauses longer than the chosen limit
  (timeline time, so speed counts) to 0.5 s, skipping pauses with a click or key press. Each action is one
  undo step. `screc-check cleanup <bundle>` prints what Clean Up would remove without changing anything.
- **Word timing from the audio:** Apple's word times have no gaps (silence is counted as part of a word) and
  leave out um/äh. `AudioLevels` measures the voice track's loudness (RMS per 10 ms); `SpeechActivity` marks
  speech 40 % of the way from the noise floor to the speech level; `Transcript.refined` tightens each word to
  its speech and adds speech after a clear silence (≥ 0.25 s gap, ≥ 0.2 s long) as a `sound` word, which
  captions skip and Clean Up removes. New transcripts are refined right away, older ones once on open.
- **Music and sounds:** two timeline lanes, Music and Sounds, hold `AudioClip`s (`project.music.clips`) in
  **timeline** time: file path (the owner's file, not copied), start, length, offset into the file, volume,
  loop, fades. Clips on a lane never overlap; they can be moved, trimmed (trimming the start moves the offset,
  so the music stays in place), split (the right part continues the music seamlessly) and deleted. Music loops
  with a 1.5 s crossfade; sounds play once. `MusicTrackWriter` renders all clips to `cache/music-<hash>.caf`
  (48 kHz stereo); the music lane is ducked to `duckLevel` while the microphone has speech (`SpeechActivity`,
  0.15 s look-ahead, 0.6 s release); edges that continue a split do not fade. It is added to the composition
  like the click track, so preview and export match. Projects with the single track of the first 5.5 build get
  one music clip on open.
- **Example tracks:** `screc-check make-music <folder>` composes and synthesises four original songs (one per
  genre) and three sounds (Whoosh, Pop, Ding) from oscillators and noise, so they are free of third-party rights.
- **Noise reduction:** `project.voice` (Standard / Noise reduction, strength). `VoiceCleaner` runs Apple's Voice
  Isolation unit (`AUSoundIsolation`, built into macOS, no new dependency) offline over `mic.m4a` into
  `cache/mic-clean-<hash>.m4a` (about 0.6 s per minute of audio). The unit delays its output by 56.5 ms and reports
  0, so that delay is cut off; the cleaned file has the same length and lines up with the original to the sample.
  The composition then uses it instead of `mic.m4a`; the original file is never changed. Transcription, word timing
  and music ducking keep using the original microphone. `screc-check denoise <bundle>` writes the file.
- **Camera layouts:** `project.layouts` holds blocks (Overlay, Split, Camera, Screen only) anchored in source
  time like zooms (they never overlap); `look.webcam.layout` applies everywhere else. `CameraLayoutTrack` gives,
  per moment, the screen rectangle, the webcam rectangle, its corner radius and opacity, eased over 0.5 s at
  layout changes. Split screen puts the screen and a webcam card of the same height side by side (stacked on
  portrait canvases); the compositor draws the scene with that screen rectangle and moves zoom centres along
  (`PreparedProject.adjusted`), so zooms still aim at the same spot. The overlay bubble moves to another corner
  while the cursor, as seen after zooming, is under it (checked every 0.1 s, at most every 1.5 s, eased 0.4 s)
  and comes back afterwards. The webcam is drawn after the zoom pass (never zoomed), cropped to fill its shape,
  optionally mirrored, with a soft shadow. `CameraFrameReader` reads `camera.mov` by source time for preview and
  export; it must copy frames (`alwaysCopiesSampleData = true`): without that, decoding ahead overwrote a held
  frame and the webcam showed a picture 9 frames (0.3 s) late.
- **Reframing:** zooms and layouts are computed from the layout of the current aspect ratio, so they re-aim and
  rearrange by themselves (split screen stacks on portrait canvases). `look.fillFrame` adds a resting zoom of
  `fillScale = max(1/screenW, 1/screenH)` so the screen covers the canvas, follows the cursor with the zoom
  dead zone, and keeps the view inside the screen (no background); zoom blocks become `fill × (1 + (z − 1)/2)`
  (at most 8×). In split screen the fill fades out as the screen moves aside.
- **Reel guides:** editor-only overlay for canvases taller than wide: top bar, name and caption band, button
  column (our own rough shapes). Never exported.
- **Sharp text when shrinking:** a single bilinear sample per output pixel skips recording pixels when the
  screen is shown smaller than recorded (the editor preview, a 1080p export of a 1440p recording), which broke
  up thin text. The scene pass now averages n×n samples (n = recording pixels per scene pixel, up to 4) and
  the zoom pass m×m scene samples when the scene is shrunk (up to 3). Measured on a 2560×1440 take at a 600 px
  preview: 26.8 → 32.4 dB against a Lanczos reference; text is readable again.
- **Native export size:** `Resolution.native` picks the short side at which the screen, at rest, shows one
  recording pixel per video pixel (3200×1800 for a 2560×1440 take with padding), the sharpest text possible.
  Larger sizes cannot add detail that the recording does not have.
- **Zooms never overlap:** moving or resizing a zoom stops at its neighbours; a new zoom fits into the free room.
- **Cuts:** audio fades out and back in over 15 ms at every cut. Captions can be dragged on the canvas
  (`CaptionLook.center`); a key badge that would overlap a caption moves past it.

### 11.3 Recorder window (1.0)

- One compact column (`RecorderView`): source tiles, a target card (display or window menu, window resize, area),
  track rows with a switch and a device menu, the record button with the shortcut, and the last 4 takes.
  Countdown, frame rate, shortcut, desktop icons and speaker notes are in an options popover.
- **Permissions** are requested where they are needed (REC-16); `PermissionAlert` handles ones refused earlier.
- **Camera bubble** (`CameraPreview`): shown while the camera is on and the recorder is open with no editor
  window, or while a take runs. It hides when the camera session is interrupted, fails or stops, and follows
  devices being plugged in or out.
- **App icon:** `Screc/Resources/AppIcon.icon` (Icon Composer); actool also writes the `.icns` for macOS 15.
- `--snapshot-recorder <png>` saves images of the recorder window and the options popover with sample sources.

## 12. Testing strategy

| Level | What | Where |
|---|---|---|
| Unit | TimeMap round-trips (`toTimeline(toSource(t)) == t`), edit ops keep invariants, spring step response, auto-zoom rules, schema migrations | `ScrecCoreTests` |
| Property | random edit sequences never break invariants | `ScrecCoreTests` |
| Render | golden images for background/frame/cursor; preview-vs-export frame diff on 3 timestamps | `ScrecRenderTests` |
| Export | duration/fps/resolution/A/V sync via `ffprobe` on generated projects | `ScrecExportTests` + `screc-check` |
| Capture | 20 s calibration take, alignment within 1 frame | `screc-check align` (manual run, needs permissions) |

Test fixtures (synthetic `.screc` bundles with generated video and events) are created by code, so no real
screen content is stored in the repo.

---

## 13. Open questions (resolved by measurement or by the owner)

1. ~~Zoom in/out durations, easing curve, lead time, dead zone, cursor lag~~. **Decided 2026-10-23**:
   spring steps ω 12/s (Focused) and 6.7/s (Smooth), no overshoot; lead time 0.5 s,
   hold 1.0 s after mouse-up, dead zone 0.4. Cursor lag is an assumption
   ([unknown], upper bound ≈ 110 ms). Values with low confidence are re-checked against our own
   recordings in Phase 3.
2. ~~Whole composition or only the screen layer?~~ **Measured:** the whole composition (§7.2).
3. [unknown] merge behaviour across a cut (assumed: restores the gap).
4. [verify Phase 1] `CGEventGetTimestamp` unit on Apple silicon; `NSCursor.currentSystem` reliability for other apps' cursors.
5. ~~Phase 3 panels for Phase 5 features~~. **Decided 2026-10-23:** the panels show only working controls,
   plus a "Phase 5" note for unfinished parts, and no controls that do nothing (SPEC §3.7).

### Decisions approved by the owner (2026-10-23)

- Metal + MPS rendering, no Core Image in the render path (§2, §9).
- Own GIF colour quantiser before ImageIO (§2, §10).
- Zooms anchored to recording (source) time, zoom animations in output (timeline) time (§7.2, §8).
- Hide desktop icons with a wallpaper window, never touching Finder settings (§6.5).
- Calibration-based alignment proof with cross-correlation (§6.4).
- Phase 0 review: zoom transitions as analytic spring steps (§7.2), `clickHold` counted from mouse-up
  (§7.3), no overshoot in Smooth, slower Focused follow pan (ω 12). Focused = fast family (~0.55 s),
  Smooth = slow family (~1.0 s). Cursor-lag defaults are tuned in Phase 2 against the owner's recordings.
  Loupe zoom added to Phase 5 as optional, with our own design (SPEC §5); dropped by the owner on 2026-10-30.
