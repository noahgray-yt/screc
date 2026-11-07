import Foundation
import Testing
@testable import ScrecCore

@Suite("Audio lanes (Phase 5)")
struct MusicTests {
    func project(_ d: Double = 30) -> Project { Project.fresh(name: "t", duration: d) }

    @Test func musicFillsTheRoomAndSoundsPlayOnce() throws {
        var p = project()
        let m = try p.addAudio(file: "/m.mp3", fileDuration: 8, lane: .music, at: 0)
        let s = try p.addAudio(file: "/s.wav", fileDuration: 1.2, lane: .sound, at: 5)
        let music = try #require(p.music.clips.first { $0.id == m }), sound = try #require(p.music.clips.first { $0.id == s })
        #expect(music.start == 0 && music.duration == 30 && music.loop)
        #expect(sound.start == 5 && sound.duration == 1.2 && !sound.loop)
        #expect(throws: EditError.noRoom) { try p.addAudio(file: "/x.mp3", fileDuration: 8, lane: .music, at: 10) }   // lane full
    }

    @Test func clipsOnALaneNeverOverlap() throws {
        var p = project()
        let a = try p.addAudio(file: "/s.wav", fileDuration: 2, lane: .sound, at: 2)
        let b = try p.addAudio(file: "/s.wav", fileDuration: 2, lane: .sound, at: 10)
        try p.moveAudio(a, toStart: 9)                                   // stops at b
        #expect(p.music.clips.first { $0.id == a }?.start == 8)
        try p.resizeAudio(b, start: true, to: 1)                         // stops at a (and the file start)
        #expect(p.music.clips.first { $0.id == b }?.start == 10)
    }

    @Test func splitContinuesSeamlessly() throws {
        var p = project()
        let a = try p.addAudio(file: "/m.mp3", fileDuration: 8, lane: .music, at: 0)
        let b = try p.splitAudio(a, at: 12)
        let l = try #require(p.music.clips.first { $0.id == a }), r = try #require(p.music.clips.first { $0.id == b })
        #expect(l.duration == 12 && r.start == 12 && r.offset == 12 && r.duration == 18)
        #expect(MusicMix.continues(l, r))
    }

    @Test func trimmingTheStartKeepsTheMusicInPlace() throws {
        var p = project()
        let a = try p.addAudio(file: "/m.mp3", fileDuration: 8, lane: .music, at: 0)
        try p.resizeAudio(a, start: true, to: 4)
        let c = try #require(p.music.clips.first)
        #expect(c.start == 4 && c.offset == 4 && c.duration == 26)
        _ = a
    }

    @Test func duckingFollowsTheVoice() {
        let d = MusicMix.duck(duration: 10, voice: [4..<6], level: 0.2)
        #expect(d.count == 1000)
        #expect(d[200] == 1)
        #expect(abs(d[500] - 0.2) < 1e-6)
        #expect(d[395] < 1)                                // starts before the first word
        #expect(d[620] > 0.2 && d[620] < 1)               // comes back up slowly
        #expect(d[750] == 1)
    }

    @Test func renderLoopsFadesAndSkipsSeams() throws {
        var p = project(3)
        let a = try p.addAudio(file: "/dc", fileDuration: 1, lane: .music, at: 0)
        p.music.clips[0].volume = 0.5
        p.music.clips[0].fadeIn = 0.5
        p.music.clips[0].fadeOut = 0.5
        _ = try p.splitAudio(a, at: 1.5)
        let rate = 1000.0
        let src: [[Float]] = [[Float](repeating: 1, count: 1000)]       // 1 s of DC
        let out = MusicMix.render(clips: p.music.clips, sources: ["/dc": src], channels: 1, length: 3000, sampleRate: rate, duck: [])
        #expect(out[0][0] == 0)                                          // fade in
        #expect(abs(out[0][1000] - 0.5) < 1e-4)                         // loops (DC stays constant)
        #expect(abs(out[0][1500] - 0.5) < 1e-4)                         // no dip at the split
        #expect(out[0][2999] < 0.01)                                     // fade out at the end
    }

    @Test func soundsStopAtTheEndOfTheirFile() {
        var c = AudioClip(id: "A1", lane: .sound, file: "/s", fileDuration: 0.5, start: 1, duration: 2)
        c.fadeIn = 0
        c.fadeOut = 0
        let out = MusicMix.render(clips: [c], sources: ["/s": [[Float](repeating: 1, count: 500)]], channels: 1, length: 4000,
                                  sampleRate: 1000, duck: [])
        #expect(out[0][1200] > 0.7 && out[0][1700] == 0)
    }

    @Test func libraryUsesSubfoldersAndSidecars() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screc-music-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Lo-Fi"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("Lo-Fi/Rain.mp3"))
        try Data().write(to: dir.appendingPathComponent("Loose.m4a"))
        try Data().write(to: dir.appendingPathComponent("Tagged.wav"))
        try "Electronic\n".write(to: dir.appendingPathComponent("Tagged.wav.genre"), atomically: true, encoding: .utf8)
        try Data().write(to: dir.appendingPathComponent("notes.txt"))
        let tracks = MusicLibrary.scan(dir)
        #expect(tracks.map(\.title) == ["Rain", "Tagged", "Loose"])
        #expect(tracks.map(\.genre) == ["Lo-Fi", "Electronic", "Other"])
    }

    @Test func singleTrackProjectsBecomeAClip() throws {
        let p = project(20)
        var json = String(decoding: try p.encoded(), as: UTF8.self)
        json = json.replacingOccurrences(of: #""music" : {"#, with: #""music" : { "track" : "/old.mp3", "volume" : 0.6,"#)
        let decoded = try Project.decode(from: Data(json.utf8))
        #expect(decoded.music.clips.count == 1)
        #expect(decoded.music.clips[0].file == "/old.mp3" && decoded.music.clips[0].volume == 0.6 && decoded.music.clips[0].duration == 20)
    }
}

@Suite("Voice settings (Phase 5)")
struct VoiceSettingsTests {
    @Test func defaultsAndRoundTrip() throws {
        var p = Project.fresh(name: "t", duration: 3)
        #expect(!p.voice.noiseReduction && p.voice.amount == 1)
        p.voice.noiseReduction = true
        p.voice.amount = 0.7
        #expect(try Project.decode(from: p.encoded()).voice == p.voice)
    }
}
