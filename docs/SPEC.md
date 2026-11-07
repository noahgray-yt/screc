# Screc: Functional Specification

Status: **1.0** (2026-11-07): phases 0–5 built and tested by the owner. Confidence of timing values in §3.3
and §3.6 is noted as *(high/medium/low)*. Items marked **[unknown]** are assumptions we chose ourselves.

Screc is a personal, local-only macOS screen recorder and editor. All code, assets, strings, sounds,
wallpapers and cursor art are original.

Requirement IDs (`REC-…`, `ED-…`) are referenced from tests and commit messages.

---

## 1. Core principle

The screen is recorded **without** the system cursor. Alongside it Screc logs precise input telemetry
(cursor position, clicks, scrolls, keys, cursor type). The cursor is drawn again during editing and export.
Because of that the cursor can be smoothed, resized, restyled, hidden or looped after recording.

All visual output (preview and export) comes from **one deterministic compositor**. The same project
at the same timeline time always produces the same pixels.

---

## 2. Recording (Phase 1)

| ID | Requirement |
|---|---|
| REC-01 | Sources: whole display, single window, or a custom area of a display. |
| REC-02 | Optional tracks: webcam (separate file), microphone, system audio. Each one can be switched on or off before recording. |
| REC-03 | Countdown before recording starts (default 3 s, can be set to 0/3/5 s). |
| REC-04 | One global shortcut starts and stops recording (default ⌥⇧⌘R, configurable). It works when Screc is not the frontmost app. |
| REC-05 | Pause and resume within one take. Paused time is not in the files, and video and telemetry stay aligned. |
| REC-06 | Crash safety: media and telemetry are flushed to disk at least every 2 s. After a crash, an interrupted take is offered for recovery on the next launch. |
| REC-07 | Utility: resize the target window to an exact size (presets 1280×720, 1440×900, 1920×1080, plus custom) before recording. |
| REC-08 | Utility: hide desktop icons during recording, without changing Finder settings (see ARCHITECTURE §6.5). |
| REC-09 | Floating speaker-notes window. It is excluded from capture. |
| REC-10 | Floating recording control bar (timer, pause, stop, restart, discard). It is excluded from capture. |
| REC-11 | The project name is the source app plus a timestamp, e.g. `Safari 2026-10-16 23:23:42`. For display capture the source app is the frontmost app at start. |
| REC-12 | Screen video is captured with `showsCursor = false` at the display's native pixel size, up to 60 fps (120 fps optional on ProMotion displays). |
| REC-13 | Telemetry is logged at the display refresh rate (≥ 120 Hz on ProMotion, otherwise 60 Hz plus every event): cursor position, mouse down/up (with button), scroll deltas, key down/up with modifiers, the current system cursor type, and window-frame changes for window capture. |
| REC-14 | Telemetry and video use the same clock (host time). The proof is that a 20 s test take aligns within one video frame (Phase 1 check tool). |
| REC-15 | Output is a `.screc` folder bundle (see ARCHITECTURE §4). |
| REC-16 | Permissions are asked by macOS directly, when they are needed: Screen Recording and Input Monitoring at launch, Microphone and Camera when their switch is turned on, Accessibility the first time a window is resized. A permission refused earlier shows an alert that opens the right System Settings pane. *Tools › Permissions…* shows the live status of all five. |

Privacy note: `events.jsonl` contains keystrokes. Password fields are protected automatically,
because macOS Secure Event Input blocks event taps there. Everything stays on the local disk.

---

## 3. Editor window (Phase 3)

### 3.1 Layout

- **Title bar:** open project, delete project (to Trash, with confirmation), centered project name
  (rename on double-click), ⌘K command palette, undo/redo, Presets dropdown, Export button (accent color).
- **Above the canvas:** aspect-ratio dropdown (Auto, Wide 16:9, Square 1:1, Classic 4:3, Vertical 9:16,
  Tall 3:4, Portrait 4:5) and Crop. On the right: preview quality (Full/Half/Quarter) and canvas zoom in/out.
  *Auto* = the aspect ratio of the (cropped) recording plus padding.
- **Left floating tool palette:** canvas zoom in/out, mask tools: *Blur*, *Hide* (solid fill),
  *Highlight* (region stays, the rest is dimmed). Masks have a time range and a rectangle in recording
  coordinates, so they stay on the content while zoomed.
- **Right icon rail** opening inspector panels: Background, Cursor, Camera, Layout/Webcam, Captions,
  Transcript, Audio, Keyboard shortcuts, Animation.
- **Transport bar:** split (scissors), current time (`m:ss.cc`), previous/play/next, total duration,
  audio waveform toggle, playback speed (0.5×/1×/1.5×/2×, preview only), timeline zoom slider.

### 3.2 Timeline

| ID | Requirement |
|---|---|
| ED-01 | The clip track is an ordered list of **slices**. Each slice shows its timeline duration and speed (e.g. `10s ⊙1.2x`). |
| ED-02 | A gap between two slices (removed source time) shows a badge with the removed duration (e.g. `6s ✂`). |
| ED-03 | Slice edges can be dragged to trim. Trimming never overlaps a neighbour's source range. |
| ED-04 | Split at the playhead (scissors button or `C`). |
| ED-05 | Slice editor panel: speed presets 1× / 1.2× / 1.4× / 1.6× / 1.8× / 2× / 3×, "Apply speed to all slices", per-slice cursor-settings override, Remove slice. |
| ED-06 | Slice context menu: Set slice speed ›, Set slice volume ›, Set system-audio volume ›, Set external-device audio volume › (= microphone), Remove slice (⌫), Split at current time (C), Reset slice trim, Merge with next, Merge with previous, Disable smooth mouse movement, Hide mouse cursor, Reset trims and cuts for all slices, Apply speed to all slices. |
| ED-07 | Zoom track below the clip track: blocks labelled `Zoom 🔍2x 🖱Auto`. Blocks can be dragged and resized, and the scale is editable (1.25×–4×). Target mode *Auto* follows the cursor; *Manual* uses a fixed point picked on the canvas. |
| ED-08 | Zoom blocks are tied to recording content: changing a slice's speed or cutting before a zoom keeps the zoom on the same moment of the recording. |
| ED-09 | Audio speed changes keep the pitch. |

Merge semantics **[unknown]**: merging two slices that have a cut between them restores the cut
content (the merged slice covers both source ranges and the gap). The left slice's speed and overrides win.

### 3.3 Auto-zoom (Phase 3)

Zoom segments are generated from telemetry. The algorithm is in ARCHITECTURE §7.3. All parameters live
in one `AutoZoomConfig` struct with these documented defaults:

| Parameter | Meaning | Default |
|---|---|---|
| `leadTime` | the zoom starts this long before the first action | 0.5 s *(low: one sample, click time inferred from the cursor reaching its target)* |
| `clickHold` | how long one click keeps the zoom open after its mouse-**up** (a drag holds the zoom until it ends) | 1.0 s *(low–medium: one sample, 0.95 s measured)* |
| `typingKeyGap` | max gap between keys inside one typing burst | 1.0 s |
| `typingMinKeys` | keys needed for a typing burst to count | 4 |
| `typingHold` | hold time after the last key of a burst | 1.0 s |
| `mergeGap` | segments closer than this merge into one | 1.5 s *(low: a 1.4 s gap between actions kept the zoom in; only a lower bound)* |
| `minDuration` | shorter segments are extended to this | 2.0 s |
| `defaultScale` | zoom factor of generated segments | 2.0× |
| `ignoreEdges` | ignore actions this close to recording start/end (stop-click etc.) | 0.3 s |
| `followDeadZone` | central fraction of the zoomed view where cursor movement does not pan | 0.4 (40 % of width/height) *(low: two pans, cursor held at 65 % and 74 % of view height → 0.3–0.5)* |
| `followEdgeMargin` | the cursor is always kept at least this far from the view edge | 0.1 of view size |

Zoom animation (Animation panel style, all in **timeline** time). Every measured zoom and pan is a
**critically damped spring step from rest**: `p(t) = 1 − (1 + ωt)·e^(−ωt)`, applied **linearly to the
scale** (and to the center). It starts from rest, reaches peak speed after `1/ω` (≈ 80 ms for Focused),
then settles slowly, with **no overshoot**. Zoom-in and zoom-out use the same ω. "Duration" = time to 99 % (`6.64/ω`), t90 = `3.89/ω`.

| Style | ω (1/s) | Zoom-in | Zoom-out | Curve | Follow pan |
|---|---|---|---|---|---|
| Focused | 12 | 0.55 s (t90 0.32 s) | 0.55 s | critically damped spring, no overshoot *(high: 12 transitions fitted linearly, ω 10.9–13.1; 11 more agree)* | same spring, ω 12 *(medium: 4 pans, ω 11.5–13)* |
| Smooth | 6.7 | 1.0 s (t90 0.58 s) | 1.0 s | critically damped spring, no overshoot *(medium: 4 transitions, ω 6.1–7.1)* | same spring, ω 6.5 *(low: 2 pans, ω 5.5–7.5)* |

The two measured timing families are clearly separate. Owner decision (2026-10-23): the fast family is
*Focused* and the slow family is *Smooth*. This matches the app's own description of Smooth ("more fluid,
not focused on reading"). The zoom covers the **whole composition**
(background, padding, shadow and screen scale together) *(high)*.

If a zoom ends and the next one starts before the zoom-out could finish, the camera pans directly
from one to the other without zooming out.

### 3.4 Background panel

- Tabs: **Wallpaper, Gradient, Color, Image**.
- Wallpapers: 16 original, procedurally generated mesh-gradient wallpapers in 4 categories
  (e.g. *Dawn*, *Ocean*, *Forest*, *Night*: names are ours), plus a favourites ★ row and **Pick random**.
  They are generated by a shader from parameters, so they are sharp at any resolution.
- Gradient: linear/radial, 2–4 stops, angle. Color: any solid color. Image: a user-chosen image file
  (copied into the bundle as `background.<ext>`).
- Sliders, each with Reset: **Background blur** (0–100), **Padding** (0–40 % of the short side, default 10 %),
  **Screen rounded corners** (0–48 px at 1080p reference, default 12), **Shadow** (0–100, default 50).
- Shadow style: **Classic** (soft, centered, slightly downward) or **Directional** (angle, distance, softness).
- **Inset** toggle: thin inset border (1 px at 1080p reference, light, semi-transparent) inside the screen edge.

### 3.5 Cursor panel

- **Size** slider (0.5×–4×, default 1.5×) with Reset.
- Six original cursor styles drawn as vector art: *Standard arrow*, *Outline arrow*, *Dot*,
  *Filled color arrow* (color picker), *Bold white arrow*, *Thin arrow*. Each style also defines matching
  shapes for I-beam, pointing hand, open/closed hand, resize and crosshair cursor types.
- Vector art is rasterised at the exact on-screen pixel size (cached per size bucket), so it stays sharp at
  any size and zoom.
- Toggles: **Always use pointer cursor** (draw the arrow whatever the recorded cursor type is);
  **Hide cursor if not moving** (fade out after 1.5 s idle, fade in on movement); **Loop cursor
  position** (in the last 1.0 s the cursor glides back to its start position, for seamless loops);
  **Hide cursor**.
- **Click effect:** None / Circle / Ripple. **Click sound:** None / *Soft* / *Crisp* (two original synthesised sounds).
- **Rotation** (collapsible): the cursor tilts up to ±N° (default 8°) towards the horizontal movement direction, with spring smoothing.
- **Advanced** (collapsible): smoothing strength (fine-tunes the Animation panel's cursor style).

### 3.6 Animation panel

- **Screen animation style:** Focused vs Smooth (see §3.3), with Reset.
- **Cursor animation style:** Smooth / Medium / Rapid / None. These are spring presets on the raw path;
  *None* = raw path. Lag at 1× speed (lag of a critically damped spring = `2/ω`): Smooth ≈ 250 ms (ω 8),
  Medium ≈ 150 ms (ω 13, default), Rapid ≈ 90 ms (ω 22). *Tuned by the owner on 2026-10-24* (first values
  150 / 90 / 45 ms felt not smooth enough). The click lock blends over the same lag, so the cursor glides onto clicks. [unknown] Upper bound: a final approach
  that halves the remaining distance every ≈ 50 ms means a lag ≤ ≈ 110 ms *(low)*. After trying them on real recordings, the owner chose softer presets than that bound.
  Owner decision (2026-10-23): tune in Phase 2 against the owner's recordings. Done 2026-10-24 (values above).
- **Motion blur** slider (0–100, 0 = off): blur along the motion vector of the screen transform and the cursor.
  100 = a 180° shutter (half the frame interval).

### 3.7 Other panels (filled in Phase 5)

Audio, Camera, Layout/Webcam, Captions, Transcript and Keyboard shortcuts. See §5.

Owner decision (2026-10-23): in Phase 3 these panels exist in the icon rail but show **only controls that
already work** (e.g. audio volumes for mic and system audio). Each unfinished part is shown as a
labelled "Phase 5" note. **No controls that do nothing.**

### 3.8 Cross-cutting editor features

- Undo/redo for every edit. Slider drags combine into one undo step.
- ⌘K command palette: fuzzy search over every setting and action by label and synonyms. Choosing an entry
  opens the right panel and focuses the control, or runs the action.
- Presets: save the current look (background, padding, corners, shadow, inset, cursor, animation) as a
  named JSON preset. Apply, rename and delete from the Presets dropdown.
- Crop: a rectangle on the recording, applied before framing.

---

## 4. Export (Phase 4)

| ID | Requirement |
|---|---|
| EX-01 | MP4 in 720p, 1080p or 4K (short side for vertical ratios), at 30 or 60 fps, H.264 or HEVC, hardware encoded. |
| EX-02 | GIF up to 1080p, palette-optimised, looping forever. Default 15 fps for GIF. |
| EX-03 | Copy the finished video to the clipboard (as a file reference). |
| EX-04 | Progress display with frames done, estimated time left, and Cancel. |
| EX-05 | The exported duration equals the edited timeline duration (± 1 frame). Audio and video stay in sync (± 1 frame). |
| EX-06 | Preview and export of the same frame are visually identical (automated frame-diff on 3 timestamps). |

---

## 5. Phase 5 extras (order decided by the owner)

Build order (owner decision 2026-10-30): 1 keyboard-shortcut overlay, 2 speed-up typing, 3 captions + .srt,
4 transcript editing, 5 background audio, 6 noise reduction, 7 camera layouts. The Loupe zoom is dropped.
Status 2026-10-31: all built, plus reframing (Fill the frame) and reel guides from the brief's Phase 5 list.

- **Camera layouts** per time range with animated transitions: Fullscreen camera, Split screen, Camera
  overlay (corner, size, shape: circle/rounded square), Screen only. Zoom framing keeps the webcam from
  covering the cursor.
- **Keyboard-shortcut overlay:** shows pressed key combos (with at least one modifier, or special keys) on screen.
- **Speed-up typing:** detect long typing stretches and suggest a faster speed for them.
- **Captions:** on-device transcription (Apple Speech) with a few caption styles. **Export .srt** that matches the edited timeline.
- **Transcript editing:** deleting words cuts the video. One pass removes filler words and long pauses.
- **Background audio:** tracks from `~/Music/ScrecTracks` (the owner's own files, with genre from a
  subfolder or sidecar tag: Lo-Fi, Commercial, Electronic, Instrumental), loop to fit, volume, auto-duck under voice.
- **Voice:** Standard / Noise reduction, processed on-device.
- **Reframing:** when the aspect ratio changes, zooms re-aim and layouts rearrange automatically.
- **Reel-mode overlay:** rough safe-area guides for vertical social video (our own simple shapes).


## 6. Out of scope

Shareable links, cloud, accounts, telemetry, licensing, shared projects, comments, view counts,
AI voiceover, ML upscaler, iPhone/iPad USB recording, camera background removal.

## 7. Acceptance criteria (whole project)

- `xcodebuild` builds with zero errors, and the app runs from Xcode with ad-hoc signing.
- Preview and export of the same frame are visually identical (automated frame-diff test on 3 timestamps).
- Record → auto-zoom → edit → export 1080p60 MP4 works end to end without touching the code.
- All assets, strings and code are original.
