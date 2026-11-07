import CoreGraphics
import Foundation
import Testing
@testable import ScrecCore

@Suite("Spring maths (SPEC §3.3)")
struct SpringTests {
    @Test(arguments: [12.0, 6.7, 22.0])
    func stepResponseMatchesMeasuredShape(omega: Double) {
        let s = CriticalSpring(omega: omega)
        #expect(abs(s.progress(after: 3.89 / omega) - 0.90) < 0.001)
        #expect(abs(s.progress(after: 6.64 / omega) - 0.99) < 0.001)
        // Never overshoots.
        let samples = stride(from: 0.0, through: 3.0, by: 0.001).map { s.progress(after: $0) }
        #expect(samples.allSatisfy { $0 <= 1 })
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func focusedAndSmoothSettleTimes() {
        #expect(abs(CriticalSpring(omega: AnimationLook.Screen.focused.zoomOmega).settleTime - 0.553) < 0.001)
        #expect(abs(CriticalSpring(omega: AnimationLook.Screen.smooth.zoomOmega).settleTime - 0.991) < 0.001)
    }

    @Test func cursorPresetLags() {
        // Owner-tuned (2026-10-24): Smooth 250 ms, Medium 150 ms, Rapid 90 ms.
        #expect(abs(CriticalSpring(omega: AnimationLook.Cursor.smooth.omega!).lag - 0.250) < 0.001)
        #expect(abs(CriticalSpring(omega: AnimationLook.Cursor.medium.omega!).lag - 0.154) < 0.001)
        #expect(abs(CriticalSpring(omega: AnimationLook.Cursor.rapid.omega!).lag - 0.091) < 0.001)
    }

    @Test func stepCarriesVelocity() {
        let s = CriticalSpring(omega: 12)
        let mid = s.step(from: 0, velocity: 0, to: 1, after: 0.1)
        // Splitting a step in two gives the same result as one long step.
        let a = s.step(from: mid.x, velocity: mid.v, to: 1, after: 0.2)
        let b = s.step(from: 0, velocity: 0, to: 1, after: 0.3)
        #expect(abs(a.x - b.x) < 1e-12 && abs(a.v - b.v) < 1e-12)
    }

    @Test(arguments: [AnimationLook.Cursor.smooth, .medium, .rapid])
    func cursorLagIsTwoOverOmega(style: AnimationLook.Cursor) throws {
        // A target moving at constant speed: after settling, the follower lags by 2/ω seconds.
        let omega = try #require(style.omega)
        var f = SpringFollower2D(omega: omega, x: 0, y: 0)
        let speed = 1000.0, dt = 1 / 240.0
        var t = 0.0
        for _ in 0..<(240 * 3) {
            t += dt
            f.advance(towardX: speed * t, y: 0, dt: dt)
        }
        let lag = (speed * t - f.x) / speed
        // Each 1/240 s step holds the target at its end value (half a step ahead), so the lag is 2/ω − dt/2.
        #expect(abs(lag - (2 / omega - dt / 2)) < 1e-6, "lag \(lag) s")
        #expect(abs(lag - 2 / omega) < 0.0025)       // within 2.5 ms of the continuous spring
    }
}

@Suite("Layout (padding, aspect, coordinates)")
struct LayoutTests {
    @Test func autoAspectAddsEqualPadding() {
        var look = Look()
        look.frame.padding = 0.1
        let l = Layout(recordingSize: CGSize(width: 2000, height: 1000), look: look)
        // Short side of the canvas = 1000 / 0.8 = 1250, padding = 125 on every side.
        #expect(abs(l.canvasAspect - 2250.0 / 1250.0) < 1e-9)
        #expect(abs(l.screenRect.minX - 125.0 / 2250.0) < 1e-9)
        #expect(abs(l.screenRect.minY - 0.1) < 1e-9)
    }

    @Test func fixedAspectFitsAndCentres() {
        var look = Look()
        look.aspect = .square
        look.frame.padding = 0.1
        let l = Layout(recordingSize: CGSize(width: 1920, height: 1080), look: look)
        #expect(l.canvasAspect == 1)
        #expect(abs(l.screenRect.width - 0.8) < 1e-9)            // limited by width
        #expect(abs(l.screenRect.midY - 0.5) < 1e-9)
        #expect(abs(l.screenRect.height - 0.8 * 1080 / 1920) < 1e-9)
    }

    @Test func canvasToRecordingIsTheInverse() {
        var look = Look()
        look.crop = [0.1, 0.2, 0.5, 0.6]
        look.aspect = .square
        let l = Layout(recordingSize: CGSize(width: 1920, height: 1080), look: look)
        let r = CGPoint(x: 0.3, y: 0.55)
        let back = l.recordingPoint(fromCanvas: l.canvasPoint(fromRecordingNormalized: r))
        #expect(abs(back.x - r.x) < 1e-9 && abs(back.y - r.y) < 1e-9)
    }

    @Test func recordingPointsMapIntoTheScreenRect() {
        var look = Look()
        look.crop = [0.5, 0, 0.5, 1]                              // right half only
        let l = Layout(recordingSize: CGSize(width: 1000, height: 500), look: look)
        let p = l.canvasPoint(fromRecordingPixels: CGPoint(x: 750, y: 250))
        #expect(abs(p.x - l.screenRect.midX) < 1e-9 && abs(p.y - l.screenRect.midY) < 1e-9)
        #expect(l.outputSize(shortSide: 1080).height == 1080)
    }
}

@Suite("Cursor track (ARCHITECTURE §7.1)")
struct CursorTrackTests {
    func track(events: [TelemetryEvent], duration: Double = 4, look: Look = Look(), slices: [Slice]? = nil) -> CursorTrack {
        let sl = slices ?? [Slice(id: "S1", sourceStart: 0, sourceEnd: duration)]
        return CursorTrack(events: events, timeMap: TimeMap(slices: sl), slices: sl, look: look)
    }

    /// A jump from x = 0 to x = 1000 at t = 1 s.
    var jump: [TelemetryEvent] {
        stride(from: 0.0, to: 4.0, by: 1 / 120.0).map { .pos(t: $0, x: $0 < 1 ? 0 : 1000, y: 0) }
    }

    @Test func smoothingFollowsWithTheSpring() {
        var look = Look()
        look.animation.cursor = .medium
        let tr = track(events: jump, look: look)
        // The jump starts between two 120 Hz events (≈ 4 ms early) and the step holds its target ≈ 2 ms ahead,
        // so the cursor is where a continuous spring would be after 0.10 … 0.11 s.
        let s = CriticalSpring(omega: AnimationLook.Cursor.medium.omega!)
        let x = tr.sample(at: 1.1).x
        #expect(x > 1000 * s.progress(after: 0.10) && x < 1000 * s.progress(after: 0.11), "x = \(x)")
        #expect(abs(tr.sample(at: 3).x - 1000) < 0.5)
    }

    @Test func noneUsesTheRawPath() {
        var look = Look()
        look.animation.cursor = .none
        let tr = track(events: jump, look: look)
        #expect(tr.sample(at: 1.02).x == 1000)
        #expect(tr.sample(at: 0.5).x == 0)
    }

    @Test func clickLockPutsTheCursorOnTheClick() {
        var events = jump
        events.append(.down(t: 1.05, button: .left, x: 1000, y: 0, clickCount: 1))
        let tr = track(events: events)
        #expect(abs(tr.sample(at: 1.05).x - 1000) < 0.01)     // smoothing alone would still be far behind
        // The blend is gradual: halfway into the lock window the cursor is between the spring and the click.
        let before = tr.sample(at: 1.05 - 0.6 * (2 / AnimationLook.Cursor.medium.omega!)).x
        #expect(before > 0 && before < 1000)
        #expect(tr.clicks.count == 1)
    }

    @Test func hideWhenIdleFadesOutAndBackIn() {
        var look = Look()
        look.cursor.hideWhenIdle = true
        var events: [TelemetryEvent] = stride(from: 0.0, to: 3.0, by: 1 / 120.0).map { .pos(t: $0, x: 0, y: 0) }
        events += stride(from: 3.0, to: 4.0, by: 1 / 120.0).map { .pos(t: $0, x: ($0 - 3) * 500, y: 0) }
        let tr = track(events: events, look: look)
        #expect(tr.sample(at: 1.0).opacity == 1)
        #expect(tr.sample(at: 2.0).opacity == 0)                // idle > 1.5 s + 0.3 s fade
        #expect(tr.sample(at: 3.3).opacity == 1)                // moving again
    }

    @Test func loopReturnsToTheStart() {
        var look = Look()
        look.cursor.loop = true
        look.animation.cursor = .none
        let events: [TelemetryEvent] = stride(from: 0.0, to: 4.0, by: 1 / 120.0).map { .pos(t: $0, x: $0 * 100, y: 0) }
        let tr = track(events: events, look: look)
        #expect(abs(tr.sample(at: 4).x - tr.sample(at: 0).x) < 0.5)
        #expect(abs(tr.sample(at: 2).x - 200) < 0.5)          // untouched before the last second
    }

    @Test func cutsUseTimelineTime() {
        let slices = [Slice(id: "A", sourceStart: 0, sourceEnd: 1), Slice(id: "B", sourceStart: 3, sourceEnd: 4)]
        var look = Look()
        look.animation.cursor = .none
        let events: [TelemetryEvent] = stride(from: 0.0, to: 4.0, by: 1 / 120.0).map { .pos(t: $0, x: $0 * 100, y: 0) }
        let tr = track(events: events, duration: 4, look: look, slices: slices)
        #expect(tr.duration == 2)
        #expect(abs(tr.sample(at: 1.5).x - 350) < 1)          // timeline 1.5 = source 3.5
    }
}

@Suite("Camera track (ARCHITECTURE §7.2)")
struct CameraTrackTests {
    let layout = Layout(recordingSize: CGSize(width: 1920, height: 1080), look: {
        var l = Look()
        l.frame.padding = 0
        return l
    }())

    func cursor(at x: Double, _ y: Double, duration: Double) -> CursorTrack {
        let s = [Slice(id: "S1", sourceStart: 0, sourceEnd: duration)]
        let events: [TelemetryEvent] = stride(from: 0.0, to: duration, by: 1 / 60.0).map { .pos(t: $0, x: x, y: y) }
        return CursorTrack(events: events, timeMap: TimeMap(slices: s), slices: s, look: Look())
    }

    func camera(_ zooms: [ZoomSegment], cursor c: CursorTrack, duration: Double = 10,
                style: AnimationLook.Screen = .focused) -> CameraTrack {
        let s = [Slice(id: "S1", sourceStart: 0, sourceEnd: duration)]
        return CameraTrack(zooms: zooms, timeMap: TimeMap(slices: s), cursor: c, layout: layout, style: style)
    }

    @Test func zoomInAndOutFollowTheSpring() {
        let cam = camera([ZoomSegment(id: "Z", sourceStart: 2, sourceEnd: 6, scale: 2)], cursor: cursor(at: 960, 540, duration: 10))
        #expect(cam.scale(at: 1.9) == 1)
        let s = CriticalSpring(omega: 12)
        #expect(abs(cam.scale(at: 2 + 3.89 / 12) - (1 + s.progress(after: 3.89 / 12))) < 1e-9)   // 90 % at 0.32 s
        #expect(abs(cam.scale(at: 5.9) - 2) < 1e-3)
        #expect(abs(cam.scale(at: 6 + 0.553) - 1.01) < 0.001)                                     // 99 % back
    }

    @Test func smoothIsSlower() {
        let c = cursor(at: 960, 540, duration: 10)
        let z = [ZoomSegment(id: "Z", sourceStart: 2, sourceEnd: 6, scale: 2)]
        #expect(camera(z, cursor: c, style: .smooth).scale(at: 2.3) < camera(z, cursor: c, style: .focused).scale(at: 2.3))
    }

    @Test func shortGapGoesStraightToTheNextZoom() {
        let zooms = [ZoomSegment(id: "A", sourceStart: 1, sourceEnd: 4, scale: 2),
                     ZoomSegment(id: "B", sourceStart: 4.3, sourceEnd: 8, scale: 3)]
        let cam = camera(zooms, cursor: cursor(at: 960, 540, duration: 10))
        // No dip towards 1 inside the 0.3 s gap.
        #expect(cam.scale(at: 4.2) > 1.99)
        #expect(abs(cam.scale(at: 7.9) - 3) < 1e-3)
    }

    @Test func centerStaysInsideTheCanvas() {
        // Cursor in the far top-left corner: the 2× view is clamped to [0.25, 0.75].
        let cam = camera([ZoomSegment(id: "Z", sourceStart: 1, sourceEnd: 8, scale: 2)], cursor: cursor(at: 0, 0, duration: 10))
        let st = cam.state(at: 6)
        #expect(st.scale > 1.99)
        #expect(abs(st.center.x - 0.25) < 0.01 && abs(st.center.y - 0.25) < 0.01)
    }

    @Test func manualZoomAimsAtItsPoint() {
        let z = ZoomSegment(id: "Z", sourceStart: 1, sourceEnd: 8, scale: 2, mode: .manual, manualCenter: [0.6, 0.4])
        let st = camera([z], cursor: cursor(at: 0, 0, duration: 10)).state(at: 6)
        #expect(abs(st.center.x - 0.6) < 0.01 && abs(st.center.y - 0.4) < 0.01)
    }

    @Test func deadZoneIgnoresSmallMoves() {
        // Cursor wiggles by 2 % of the canvas around the middle: inside the dead zone of a 2× view (± 0.1).
        let s = [Slice(id: "S1", sourceStart: 0, sourceEnd: 10)]
        let events: [TelemetryEvent] = stride(from: 0.0, to: 10.0, by: 1 / 60.0).map {
            .pos(t: $0, x: 960 + 38 * sin($0 * 3), y: 540)
        }
        let c = CursorTrack(events: events, timeMap: TimeMap(slices: s), slices: s, look: Look())
        let cam = camera([ZoomSegment(id: "Z", sourceStart: 1, sourceEnd: 9, scale: 2)], cursor: c)
        let xs = stride(from: 3.0, to: 8.0, by: 0.1).map { Double(cam.state(at: $0).center.x) }
        #expect((xs.max()! - xs.min()!) < 0.001)
    }
}

@Suite("Look decoding")
struct LookTests {
    @Test func missingKeysGetDefaults() throws {
        let json = #"{"name":"x","timeline":{"slices":[]},"look":{"frame":{"padding":0.2},"cursor":{"size":3}}}"#
        let p = try Project.decode(from: Data(json.utf8))
        #expect(p.look.frame.padding == 0.2)
        #expect(p.look.frame.cornerRadius == 12)
        #expect(p.look.cursor.size == 3)
        #expect(p.look.cursor.clickEffect == .ripple)
        #expect(p.look.animation.screen == .focused)
        #expect(try Project.decode(from: p.encoded()) == p)
    }

    @Test func wallpapersAreSixteenInFourCategories() {
        #expect(Wallpapers.all.count == 16)
        #expect(Set(Wallpapers.all.map(\.id)).count == 16)
        for c in Wallpaper.Category.allCases { #expect(Wallpapers.all.filter { $0.category == c }.count == 4) }
    }
}

@Suite("Keyboard-shortcut overlay (Phase 5)")
struct KeyOverlayTests {
    func key(_ t: Double, _ code: Int, _ chars: String, _ mods: [String] = [], up: Double? = nil) -> [TelemetryEvent] {
        [.key(t: t, phase: .down, keyCode: code, chars: chars, mods: mods),
         .key(t: up ?? t + 0.1, phase: .up, keyCode: code, chars: chars, mods: mods)]
    }
    func track(_ events: [TelemetryEvent], slices: [Slice] = [Slice(id: "S1", sourceStart: 0, sourceEnd: 20)]) -> KeyOverlayTrack {
        KeyOverlayTrack(events: events, timeMap: TimeMap(slices: slices))
    }

    @Test func whatIsShownAndHowItIsLabelled() {
        #expect(KeyOverlayTrack.tokens(keyCode: 8, chars: "c", mods: ["cmd"]) == ["⌘", "C"])
        #expect(KeyOverlayTrack.tokens(keyCode: 6, chars: "z", mods: ["shift", "cmd"]) == ["⇧", "⌘", "Z"])
        #expect(KeyOverlayTrack.tokens(keyCode: 0, chars: "å", mods: ["opt"]) == ["⌥", "A"])      // the key, not the symbol
        // German QWERTZ: the key with US code 16 ("Y" position) types "z" → ⌘Z, not ⌘Y.
        #expect(KeyOverlayTrack.tokens(keyCode: 16, chars: "z", mods: ["cmd"]) == ["⌘", "Z"])
        #expect(KeyOverlayTrack.tokens(keyCode: 16, chars: "Z", mods: ["shift", "cmd"]) == ["⇧", "⌘", "Z"])
        // ⌥L on German types "@"; the recorded plain key gives the right label.
        #expect(KeyOverlayTrack.tokens(keyCode: 37, chars: "@", mods: ["opt"], key: "l") == ["⌥", "L"])
        // ⌃ produces control characters; the plain key or the US name is used instead.
        #expect(KeyOverlayTrack.tokens(keyCode: 8, chars: "\u{03}", mods: ["ctrl"], key: "c") == ["⌃", "C"])
        #expect(KeyOverlayTrack.tokens(keyCode: 36, chars: "\r", mods: []) == ["↩"])
        #expect(KeyOverlayTrack.tokens(keyCode: 123, chars: "", mods: ["shift"]) == ["⇧", "←"])
        // Not shown: typing, Shift + letter, Space alone, modifier keys alone.
        #expect(KeyOverlayTrack.tokens(keyCode: 0, chars: "a", mods: []) == nil)
        #expect(KeyOverlayTrack.tokens(keyCode: 0, chars: "A", mods: ["shift"]) == nil)
        #expect(KeyOverlayTrack.tokens(keyCode: 49, chars: " ", mods: []) == nil)
        #expect(KeyOverlayTrack.tokens(keyCode: 55, chars: "", mods: ["cmd"]) == nil)
        #expect(KeyOverlayTrack.tokens(keyCode: 49, chars: " ", mods: ["cmd"]) == ["⌘", "Space"])
    }

    @Test func timingFadeAndHold() throws {
        let tr = track(key(2, 8, "c", ["cmd"]) + key(5, 9, "v", ["cmd"], up: 7))     // ⌘V held for 2 s
        #expect(tr.items.count == 2)
        #expect(tr.active(at: 1.9) == nil)
        let a = try #require(tr.active(at: 2.04))
        #expect(a.item.tokens == ["⌘", "C"] && abs(a.opacity - 0.5) < 1e-9)    // halfway through the fade-in
        #expect(try #require(tr.active(at: 2.5)).opacity == 1)
        #expect(tr.active(at: 3.1) == nil)                                      // shown for 1 s
        #expect(abs(tr.items[1].end - 7.4) < 1e-9)                              // held 2 s + 0.4 s
    }

    @Test func repeatsMergeAndANewComboReplacesTheOld() {
        let z = key(1, 6, "z", ["cmd"]) + key(1.4, 6, "z", ["cmd"]) + key(1.8, 6, "z", ["cmd"])
        let tr = track(z + key(2.2, 8, "c", ["cmd"]))
        #expect(tr.items.count == 2)
        #expect(tr.items[0].repeatCount == 3)
        #expect(tr.items[0].end == 2.2)                                         // ⌘C takes over
    }

    @Test func pressesInACutAreDroppedAndTimesFollowSpeed() {
        var fast = Slice(id: "B", sourceStart: 10, sourceEnd: 20)
        fast.speed = 2
        let tr = track(key(5, 8, "c", ["cmd"]) + key(14, 9, "v", ["cmd"]),
                       slices: [Slice(id: "A", sourceStart: 0, sourceEnd: 4), fast])
        #expect(tr.items.map(\.tokens) == [["⌘", "V"]])                         // ⌘C at 5 s lies in the cut
        #expect(abs(tr.items[0].start - 6) < 1e-9)                              // 4 + (14 − 10) / 2
    }
}
