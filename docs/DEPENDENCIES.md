# Screc: Dependencies

Principle: use Apple frameworks only inside the app. Only add something external when it saves a lot of
work and is easy to remove. Anything new needs the owner's approval first.

## Already approved and installed

| Dependency | Version | Kind | Why |
|---|---|---|---|
| Xcode | 27.1 (27A9275) | build toolchain | Swift 6, SwiftUI, `xcodebuild`, Instruments. The separate *Metal Toolchain* download is **not** needed: shaders compile at runtime (ARCHITECTURE §9) |
| XcodeGen | 2.46.0 (Homebrew) | dev tool, not shipped | generates `Screc.xcodeproj` from the text file `project.yml` |
| ffmpeg / ffprobe | 9.0.2 (Homebrew) | dev tool, not shipped | Phase 4 output checks |

## Apple frameworks used (part of macOS, nothing to install)

SwiftUI, AppKit, ScreenCaptureKit, AVFoundation, CoreMedia, CoreVideo, VideoToolbox, Metal, MetalKit,
MetalPerformanceShaders, ImageIO, UniformTypeIdentifiers, ApplicationServices (CGEventTap, Accessibility),
Carbon (global hotkey only), Speech (Phase 5), Accelerate (waveforms, GIF quantiser, audio analysis),
Swift Testing / XCTest.

## Third-party Swift packages

**None planned.** Things we considered and are building ourselves instead:

| Candidate | What it would do | Why not |
|---|---|---|
| KeyboardShortcuts (sindresorhus) | global hotkey + recorder UI | Carbon `RegisterEventHotKey` is ~60 lines |
| gifski | high-quality GIF encoder (Rust) | adds a Rust toolchain. Own median-cut quantiser + ImageIO first. Revisit only if GIF quality disappoints |
| Sparkle | auto-update | personal app, not needed |
| swift-collections | deque/ordered dict | standard library is enough |

## Possible later requests (not now)

- **Noise reduction (Phase 5):** done with Apple's built-in Voice Isolation audio unit (`AUSoundIsolation`), which
  works offline on this Mac; no open-source denoiser needed. On Macs without the unit the option is hidden.
