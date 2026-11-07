@preconcurrency import AVFoundation
import Foundation

/// `screc-check make-music <folder>`: composes and synthesises Screc's example tracks (Phase 5). Everything is
/// generated here from oscillators and noise, so the files are original and free of third-party rights.
enum MusicSynth {
    static let sr = 44_100.0

    // MARK: Building blocks

    static func midi(_ n: Double) -> Double { 440 * pow(2, (n - 69) / 12) }

    /// One cycle of a band-limited wave: harmonic h gets amplitude `amp(h)`.
    static func table(_ harmonics: Int, _ amp: (Int) -> Double) -> [Float] {
        let n = 2048
        var t = [Float](repeating: 0, count: n)
        for h in 1...harmonics {
            let a = amp(h)
            guard a != 0 else { continue }
            for i in 0..<n { t[i] += Float(a * sin(2 * .pi * Double(h * i) / Double(n))) }
        }
        let peak = t.map(abs).max() ?? 1
        return t.map { $0 / peak }
    }

    static let sine = table(1) { _ in 1 }
    static let warmSaw = table(24) { 1 / pow(Double($0), 1.25) }
    static let hollow = table(15) { $0 % 2 == 1 ? 1 / Double($0) : 0.15 / Double($0) }

    /// Wavetable oscillator with optional vibrato.
    static func osc(_ wave: [Float], _ f: Double, _ n: Int, detune: Double = 1, vibrato: Double = 0) -> [Float] {
        var out = [Float](repeating: 0, count: n)
        var phase = Double.random(in: 0..<1)
        let size = Double(wave.count)
        for i in 0..<n {
            let v = vibrato > 0 ? 1 + vibrato * sin(2 * .pi * 5 * Double(i) / sr) : 1
            phase += f * detune * v / sr
            phase -= phase.rounded(.down)
            let x = phase * size, k = Int(x), frac = Float(x - Double(k))
            out[i] = wave[k] * (1 - frac) + wave[(k + 1) % wave.count] * frac
        }
        return out
    }

    static func lowpass(_ x: inout [Float], cutoff: Double) {
        let a = Float(1 - exp(-2 * .pi * cutoff / sr))
        var y: Float = 0
        for i in x.indices { y += a * (x[i] - y); x[i] = y }
    }

    static func highpass(_ x: inout [Float], cutoff: Double) {
        var low = x
        lowpass(&low, cutoff: cutoff)
        for i in x.indices { x[i] -= low[i] }
    }

    static func envelope(_ x: inout [Float], attack: Double, hold: Double, decay: Double, release: Double) {
        for i in x.indices {
            let t = Double(i) / sr
            var e = t < attack ? t / attack : exp(-(t - attack) * decay)
            if t > hold { e *= exp(-(t - hold) * release) }
            x[i] *= Float(e)
        }
    }

    static func noise(_ n: Int) -> [Float] { (0..<n).map { _ in Float.random(in: -1...1) } }

    // MARK: Instruments (mono buffers)

    static func epiano(_ note: Double, _ dur: Double, bright: Double = 0.25) -> [Float] {
        let f = midi(note), n = Int((dur + 1.5) * sr)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            var v = sin(2 * .pi * f * t) + bright * sin(2 * .pi * 2 * f * t) * exp(-2.5 * t)
            if 7 * f < 16_000 { v += 0.07 * sin(2 * .pi * 7 * f * t) * exp(-16 * t) }
            var e = min(t / 0.004, 1) * exp(-1.1 * t)
            if t > dur { e *= exp(-(t - dur) * 7) }
            out[i] = Float(v * e * (1 + 0.08 * sin(2 * .pi * 4.5 * t)))
        }
        return out
    }

    static func pluck(_ note: Double, _ dur: Double, bright: Double = 0.5) -> [Float] {
        let f = midi(note), period = max(Int(sr / f), 2), n = Int((dur + 0.8) * sr)
        var buf = noise(period)
        var smoothed = buf
        lowpass(&smoothed, cutoff: 1500 + 6000 * bright)
        buf = smoothed
        var out = [Float](repeating: 0, count: n)
        var idx = 0
        for i in 0..<n {
            let next = (idx + 1) % period
            let decay: Float = Double(i) / sr > dur ? 0.97 : 0.9965
            let v = buf[idx]
            buf[idx] = decay * 0.5 * (buf[idx] + buf[next])
            out[i] = v
            idx = next
        }
        envelope(&out, attack: 0.002, hold: dur, decay: 0.3, release: 8)
        return out
    }

    static func pad(_ notes: [Double], _ dur: Double, cutoff: Double = 2200) -> [Float] {
        let n = Int((dur + 1.2) * sr)
        var out = [Float](repeating: 0, count: n)
        for note in notes {
            for d in [0.9985, 1.0, 1.0015] {
                let o = osc(warmSaw, midi(note), n, detune: d)
                for i in 0..<n { out[i] += o[i] }
            }
        }
        lowpass(&out, cutoff: cutoff)
        lowpass(&out, cutoff: cutoff * 1.5)
        let scale = Float(1 / Double(max(notes.count * 3, 1)))
        for i in 0..<n {
            let t = Double(i) / sr
            var e = min(t / 0.5, 1)
            if t > dur { e *= exp(-(t - dur) * 3.5) }
            out[i] *= Float(e) * scale
        }
        return out
    }

    static func bass(_ note: Double, _ dur: Double, wave: [Float] = hollow, cutoff: Double = 700) -> [Float] {
        let n = Int((dur + 0.2) * sr)
        var out = osc(wave, midi(note), n)
        let sub = osc(sine, midi(note), n)
        for i in 0..<n { out[i] = 0.55 * out[i] + 0.6 * sub[i] }
        lowpass(&out, cutoff: cutoff)
        envelope(&out, attack: 0.006, hold: dur, decay: 0.8, release: 25)
        return out
    }

    static func kick(punch: Double = 1) -> [Float] {
        let n = Int(0.5 * sr)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / sr
            phase += (44 + 80 * punch * exp(-t * 32)) / sr
            out[i] = Float(sin(2 * .pi * phase) * exp(-t * 7.5))
            if i < 90 { out[i] += Float.random(in: -0.25...0.25) * Float(1 - Double(i) / 90) }
        }
        return out
    }

    static func snare(tone: Double = 185, decay: Double = 17) -> [Float] {
        let n = Int(0.32 * sr)
        var body = noise(n)
        highpass(&body, cutoff: 900)
        lowpass(&body, cutoff: 7000)
        for i in 0..<n {
            let t = Double(i) / sr
            body[i] = Float(Double(body[i]) * exp(-t * decay) + 0.45 * sin(2 * .pi * tone * t) * exp(-t * 22))
        }
        return body
    }

    static func clap() -> [Float] {
        let n = Int(0.35 * sr)
        var x = noise(n)
        highpass(&x, cutoff: 1000)
        lowpass(&x, cutoff: 3500)
        for i in 0..<n {
            let t = Double(i) / sr
            let bursts = [0.0, 0.011, 0.022].map { t >= $0 ? exp(-(t - $0) * 180) : 0 }.reduce(0, +)
            x[i] *= Float(bursts * 0.7 + (t > 0.022 ? exp(-(t - 0.022) * 14) : 0))
        }
        return x
    }

    static func hat(open: Bool = false) -> [Float] {
        let n = Int((open ? 0.4 : 0.09) * sr)
        var x = noise(n)
        highpass(&x, cutoff: 7000)
        highpass(&x, cutoff: 7000)
        for i in 0..<n { x[i] *= Float(exp(-Double(i) / sr * (open ? 9 : 55))) }
        return x
    }

    static func shaker() -> [Float] {
        let n = Int(0.07 * sr)
        var x = noise(n)
        highpass(&x, cutoff: 5000)
        for i in 0..<n { let t = Double(i) / Double(n); x[i] *= Float(sin(.pi * t) * sin(.pi * t)) }
        return x
    }

    // MARK: Mixing

    struct Mix {
        var l: [Float], r: [Float], send: [Float]
        init(seconds: Double) {
            let n = Int(seconds * sr)
            l = [Float](repeating: 0, count: n)
            r = l
            send = l
        }

        /// Adds a mono part at `t` seconds; pan -1…1; `reverb` = how much goes to the reverb send.
        mutating func add(_ x: [Float], at t: Double, gain: Double, pan: Double = 0, reverb: Double = 0.2) {
            let start = Int(t * sr)
            let gl = Float(gain * cos((pan + 1) * .pi / 4)), gr = Float(gain * sin((pan + 1) * .pi / 4))
            for (k, v) in x.enumerated() {
                let i = start + k
                guard i >= 0, i < l.count else { continue }
                l[i] += v * gl
                r[i] += v * gr
                send[i] += v * Float(gain * reverb)
            }
        }
    }

    /// Schroeder reverb: four combs and two all-passes per side.
    static func reverb(_ x: [Float], offset: Int) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        for d in [1557, 1617, 1491, 1422] {
            let delay = d + offset
            var buf = [Float](repeating: 0, count: delay)
            var low: Float = 0
            var k = 0
            for i in x.indices {
                let y = buf[k]
                low = y * 0.6 + low * 0.4
                buf[k] = x[i] + low * 0.8
                out[i] += y
                k = (k + 1) % delay
            }
        }
        for d in [556, 441] {
            let delay = d + offset / 2
            var buf = [Float](repeating: 0, count: delay)
            var k = 0
            for i in out.indices {
                let b = buf[k]
                let y = -out[i] + b
                buf[k] = out[i] + b * 0.5
                out[i] = y
                k = (k + 1) % delay
            }
        }
        return out.map { $0 * 0.18 }
    }

    /// Reverb, optional tone filter, a loop-friendly wrap of the tail onto the start, soft limiting.
    static func master(_ m: Mix, length: Double, lowpass cutoff: Double? = nil, extra: [Float] = []) -> [[Float]] {
        var l = m.l, r = m.r
        let wl = reverb(m.send, offset: 0), wr = reverb(m.send, offset: 23)
        for i in l.indices { l[i] += wl[i]; r[i] += wr[i] }
        if !extra.isEmpty { for i in l.indices where i < extra.count { l[i] += extra[i]; r[i] += extra[i] } }
        if let cutoff { lowpass(&l, cutoff: cutoff); lowpass(&r, cutoff: cutoff) }
        // The tail past the loop length rings over into the start, so the file loops without a gap.
        let n = Int(length * sr)
        for i in n..<l.count where i - n < n { l[i - n] += l[i]; r[i - n] += r[i] }
        l = Array(l.prefix(n))
        r = Array(r.prefix(n))
        let peak = max(l.map(abs).max() ?? 1, r.map(abs).max() ?? 1)
        let drive = Float(1.4) / max(peak, 0.0001)
        return [l, r].map { ch in ch.map { tanhf($0 * drive) * 0.84 } }
    }

    static func write(_ channels: [[Float]], to url: URL) throws {
        let n = channels[0].count
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
        buffer.frameLength = AVAudioFrameCount(n)
        for c in 0..<2 { channels[c].withUnsafeBufferPointer { buffer.floatChannelData![c].update(from: $0.baseAddress!, count: n) } }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr,
                                                               AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000],
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    // MARK: Songs

    /// Lo-Fi: 78 BPM, swung, warm electric piano, soft drums, vinyl noise, rolled-off highs.
    static func lateCoffee() -> [[Float]] {
        let bpm = 78.0, bars = 16, step = 60 / bpm / 4, bar = step * 16
        let length = Double(bars) * bar
        var m = Mix(seconds: length + 3)
        let chords: [[Double]] = [[53, 57, 60, 64], [52, 55, 59, 62], [50, 53, 57, 60], [48, 52, 55, 59]]
        let roots: [Double] = [41, 40, 38, 36]
        func at(_ b: Int, _ s: Double) -> Double { Double(b) * bar + (s + (Int(s) % 2 == 1 ? 0.18 : 0)) * step + Double.random(in: -0.004...0.004) }
        let k = kick(punch: 0.7), sn = snare(tone: 170, decay: 14), h = hat()
        for b in 0..<bars {
            let c = chords[b % 4]
            for (j, note) in c.enumerated() {
                m.add(epiano(note, step * 6), at: at(b, 0) + Double(j) * 0.012, gain: 0.16, pan: -0.25 + 0.15 * Double(j), reverb: 0.35)
                m.add(epiano(note, step * 4), at: at(b, 10) + Double(j) * 0.01, gain: 0.11, pan: -0.2 + 0.15 * Double(j), reverb: 0.35)
            }
            for (s, len) in [(0.0, 6.0), (7.0, 2.0), (10.0, 5.0)] { m.add(bass(roots[b % 4], step * len), at: at(b, s), gain: 0.42, reverb: 0) }
            for s in [0.0, 7.0, 10.0] { m.add(k, at: at(b, s), gain: 0.55, reverb: 0.02) }
            for s in [4.0, 12.0] { m.add(sn, at: at(b, s), gain: 0.22, reverb: 0.25) }
            for s in stride(from: 0.0, to: 16, by: 2) { m.add(h, at: at(b, s), gain: s.truncatingRemainder(dividingBy: 4) == 0 ? 0.07 : 0.045, pan: 0.3, reverb: 0.05) }
            if b % 2 == 1 {
                let melody: [(Double, Double, Double)] = b % 4 == 1 ? [(2, 72, 2), (4, 69, 2), (8, 67, 4)] : [(0, 76, 3), (4, 74, 2), (6, 72, 6)]
                for (s, n, len) in melody { m.add(epiano(n, step * len, bright: 0.5), at: at(b, s), gain: 0.1, pan: 0.2, reverb: 0.5) }
            }
        }
        // Vinyl: quiet noise and sparse crackle.
        var vinyl = noise(Int((length + 3) * sr)).map { $0 * 0.004 }
        lowpass(&vinyl, cutoff: 3000)
        for i in vinyl.indices where Double.random(in: 0..<1) < 0.00025 { vinyl[i] += Float.random(in: -0.06...0.06) }
        return master(m, length: length, lowpass: 3400, extra: vinyl)
    }

    /// Commercial: 112 BPM pop, bright piano stabs, claps, a bell melody.
    static func brightMorning() -> [[Float]] {
        let bpm = 112.0, bars = 24, step = 60 / bpm / 4, bar = step * 16
        let length = Double(bars) * bar
        var m = Mix(seconds: length + 3)
        let chords: [[Double]] = [[62, 66, 69], [61, 64, 69], [62, 66, 71], [62, 67, 71]]
        let roots: [Double] = [38, 33, 35, 31]
        let scale: [[Double]] = [[74, 78, 81, 78], [73, 76, 81, 76], [74, 78, 83, 81], [74, 79, 83, 79]]
        let k = kick(), cl = clap(), h = hat(), sh = shaker()
        for b in 0..<bars {
            let t0 = Double(b) * bar, c = chords[b % 4]
            for s in [0.0, 3, 6, 8, 11, 14] {
                for (j, note) in c.enumerated() { m.add(epiano(note, step * 2, bright: 0.7), at: t0 + s * step, gain: 0.11, pan: -0.3 + 0.3 * Double(j), reverb: 0.25) }
            }
            m.add(pad(c.map { $0 - 12 }, bar), at: t0, gain: 0.18, reverb: 0.3)
            for s in stride(from: 0.0, to: 16, by: 2) { m.add(bass(roots[b % 4], step * 1.6, wave: warmSaw, cutoff: 900), at: t0 + s * step, gain: 0.32, reverb: 0) }
            if b >= 2 {
                for s in [0.0, 6, 8] { m.add(k, at: t0 + s * step, gain: 0.6, reverb: 0.02) }
                for s in [4.0, 12] { m.add(cl, at: t0 + s * step, gain: 0.3, reverb: 0.3) }
                for s in stride(from: 0.0, to: 16, by: 2) { m.add(h, at: t0 + s * step, gain: 0.06, pan: 0.35, reverb: 0.05) }
            }
            if b >= 8 { for s in stride(from: 1.0, to: 16, by: 2) { m.add(sh, at: t0 + s * step, gain: 0.05, pan: -0.4, reverb: 0.05) } }
            if b >= 4 {
                for (j, n) in scale[b % 4].enumerated() { m.add(epiano(n, step * 3, bright: 0.9), at: t0 + Double(j) * 4 * step, gain: 0.08, pan: 0.15, reverb: 0.45) }
            }
        }
        return master(m, length: length, lowpass: 12_000)
    }

    /// Electronic: 122 BPM, four-on-the-floor, pumping pad, 16th arpeggio, off-beat bass.
    static func nightDrive() -> [[Float]] {
        let bpm = 122.0, bars = 32, step = 60 / bpm / 4, bar = step * 16
        let length = Double(bars) * bar
        var m = Mix(seconds: length + 3)
        let chords: [[Double]] = [[57, 60, 64], [53, 57, 60], [55, 60, 64], [55, 59, 62]]
        let roots: [Double] = [33, 29, 36, 31]
        let order = [0, 1, 2, 1, 0, 2, 1, 2]
        let k = kick(punch: 1.1), cl = clap(), oh = hat(open: true), h = hat()
        for b in 0..<bars {
            let t0 = Double(b) * bar, c = chords[b % 4]
            // Pad with a sidechain-like pump on every beat.
            var p = pad(c, bar, cutoff: 1800 + 1200 * Double(b % 8) / 8)
            for i in p.indices { let beat = Double(i) / sr / (step * 4); p[i] *= Float(1 - 0.65 * exp(-(beat - beat.rounded(.down)) * 7)) }
            m.add(p, at: t0, gain: 0.32, reverb: 0.3)
            if b >= 4 { for s in 0..<16 { m.add(pluck(c[order[s % 8]] + 12, step * 0.8, bright: 0.8), at: t0 + Double(s) * step, gain: 0.1, pan: s % 2 == 0 ? -0.35 : 0.35, reverb: 0.3) } }
            for s in [2.0, 6, 10, 14] { m.add(bass(roots[b % 4], step * 1.5, wave: warmSaw, cutoff: 600 + 100 * Double(b % 4)), at: t0 + s * step, gain: 0.36, reverb: 0) }
            for s in [0.0, 4, 8, 12] { m.add(k, at: t0 + s * step, gain: 0.7, reverb: 0.02) }
            if b >= 4 { for s in [4.0, 12] { m.add(cl, at: t0 + s * step, gain: 0.25, reverb: 0.25) } }
            for s in [2.0, 6, 10, 14] { m.add(oh, at: t0 + s * step, gain: 0.07, pan: 0.3, reverb: 0.1) }
            if b >= 8 { for s in 0..<16 where s % 2 == 1 { m.add(h, at: t0 + Double(s) * step, gain: 0.035, pan: -0.3, reverb: 0.05) } }
        }
        return master(m, length: length, lowpass: 14_000)
    }

    /// Instrumental: 92 BPM, plucked guitar arpeggios, soft pad and piano, a light shaker.
    static func paperPlanes() -> [[Float]] {
        let bpm = 92.0, bars = 24, step = 60 / bpm / 4, bar = step * 16
        let length = Double(bars) * bar
        var m = Mix(seconds: length + 3)
        let arps: [[Double]] = [[48, 55, 60, 64, 67, 64, 60, 55], [45, 52, 57, 60, 64, 60, 57, 52],
                                [41, 48, 53, 57, 60, 57, 53, 48], [43, 50, 55, 59, 62, 59, 55, 50]]
        let melody: [[(Double, Double, Double)]] = [[(0, 76, 6), (8, 74, 4), (12, 72, 4)], [(0, 72, 8), (8, 76, 8)],
                                                   [(0, 77, 6), (8, 76, 4), (12, 72, 4)], [(0, 74, 12), (12, 71, 4)]]
        let sh = shaker()
        for b in 0..<bars {
            let t0 = Double(b) * bar, arp = arps[b % 4]
            for (j, n) in arp.enumerated() {
                m.add(pluck(n, step * 2.5, bright: 0.45), at: t0 + Double(j) * 2 * step + Double.random(in: 0...0.006), gain: 0.2,
                      pan: -0.4 + 0.1 * Double(j), reverb: 0.3)
            }
            m.add(pad([arp[1], arp[3], arp[4]], bar, cutoff: 1400), at: t0, gain: 0.16, reverb: 0.4)
            if b >= 8 { for (s, n, len) in melody[b % 4] { m.add(epiano(n, step * len, bright: 0.3), at: t0 + s * step, gain: 0.1, pan: 0.25, reverb: 0.5) } }
            if b >= 4 { for s in stride(from: 2.0, to: 16, by: 4) { m.add(sh, at: t0 + s * step, gain: 0.05, pan: 0.4, reverb: 0.1) } }
        }
        return master(m, length: length, lowpass: 9000)
    }

    // MARK: Sounds

    static func whoosh() -> [[Float]] {
        let n = Int(0.9 * sr)
        var x = noise(n)
        var out = [Float](repeating: 0, count: n)
        var y: Float = 0
        for i in 0..<n {
            let t = Double(i) / Double(n)
            let a = Float(1 - exp(-2 * .pi * (300 + 5000 * sin(.pi * t)) / sr))
            y += a * (x[i] - y)
            out[i] = y * Float(sin(.pi * t) * sin(.pi * t))
        }
        x = out
        let peak = x.map(abs).max() ?? 1
        return [x.map { $0 / peak * 0.8 }, x.map { $0 / peak * 0.8 }]
    }

    static func pop() -> [[Float]] {
        let n = Int(0.18 * sr)
        var phase = 0.0
        let x: [Float] = (0..<n).map { i in
            let t = Double(i) / sr
            phase += (380 + 900 * exp(-t * 60)) / sr
            return Float(sin(2 * .pi * phase) * exp(-t * 28) * 0.8)
        }
        return [x, x]
    }

    static func ding() -> [[Float]] {
        var x = epiano(88, 0.6, bright: 0.6)
        let y = epiano(95, 0.6, bright: 0.3)
        for i in x.indices where i < y.count { x[i] = 0.6 * x[i] + 0.3 * y[i] }
        var m = Mix(seconds: 2.2)
        m.add(x, at: 0, gain: 0.8, reverb: 0.4)
        let wl = reverb(m.send, offset: 0), wr = reverb(m.send, offset: 23)
        return [zip(m.l, wl).map { $0 + $1 }, zip(m.r, wr).map { $0 + $1 }]
    }

    static func run(folder: URL) throws {
        let songs: [(String, String, () -> [[Float]])] = [
            ("Lo-Fi", "Late Coffee", lateCoffee), ("Commercial", "Bright Morning", brightMorning),
            ("Electronic", "Night Drive", nightDrive), ("Instrumental", "Paper Planes", paperPlanes),
            ("Sounds", "Whoosh", whoosh), ("Sounds", "Pop", pop), ("Sounds", "Ding", ding),
        ]
        for (genre, title, make) in songs {
            let dir = folder.appendingPathComponent(genre, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(title + ".m4a")
            let start = Date()
            let audio = make()
            try write(audio, to: url)
            print(String(format: "%@/%@.m4a  %.1f s  (made in %.1f s)", genre, title, Double(audio[0].count) / sr, Date().timeIntervalSince(start)))
        }
    }
}
