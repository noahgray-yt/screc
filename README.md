# Screc

<img width="1168" height="720" alt="sample recording" src="https://github.com/user-attachments/assets/81809af2-4c64-4ad3-bd0f-b8537b346597" />


Screc is a personal, local-only screen recorder and editor for macOS. It records the screen, camera,
microphone and system audio together with every click and key press, then turns the take into a polished
video: automatic zooms that follow the cursor, a smooth cursor, backgrounds, camera layouts, captions,
transcript editing, music and export to MP4 or GIF. Everything stays on your Mac.

Requires macOS 15 or newer (captions need macOS 26).

## Screenshots

<img width="100%" alt="camera overlay" src="https://github.com/user-attachments/assets/a4dda36d-fb71-4474-84cc-d8229594b28e" />

<p>
  <img width="300" alt="settings recorder" src="https://github.com/user-attachments/assets/128c0087-8eaf-416f-9c01-b14c46135e2b" />
  <img width="300" alt="audio settings" src="https://github.com/user-attachments/assets/4a3f19d1-dbcb-462a-b11f-cd7cf77af8a7" />
</p>

<img width="100%" alt="timeline editor" src="https://github.com/user-attachments/assets/03d31128-0ac5-4204-b26b-4fe3337d6e74" />

## Build

Needs Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate
xcodebuild -project Screc.xcodeproj -scheme Screc -configuration Release -derivedDataPath build/Release build
```

The app is at `build/Release/Build/Products/Release/Screc.app`. Tests:
`xcodebuild test -project Screc.xcodeproj -scheme Screc -derivedDataPath build/DD`.

## Install

Copy `Screc.app` to `/Applications` and open it from there. Keep only that one copy: macOS identifies the app by
its ID (`local.screc.Screc`), so a second build elsewhere can be opened instead.

Screc is signed ad-hoc (for this Mac only). After installing a new build, macOS forgets the Screen Recording
and Input Monitoring permissions: remove Screc from both lists in System Settings › Privacy & Security and
allow it again when Screc asks.

## Use

- **Record:** pick Display, Window or Area, switch on the tracks you want and press *Start Recording* or the
  shortcut (default ⌥⇧⌘R, works from any app). The control bar pauses, stops, restarts or discards the take.
- **Edit:** a finished take opens from *Recent*. Recordings are `.screc` packages in `~/Movies/Screc`.
- **Music:** put your own tracks into `~/Music/ScrecTracks`, one subfolder per genre.

## Docs

- `docs/SPEC.md`: what Screc does (requirements).
- `docs/ARCHITECTURE.md`: how it is built.
- `docs/DEPENDENCIES.md`: tools and frameworks.
- `Tools/screc-check`: command-line checks (alignment, export, frame diff, music, cleanup).
