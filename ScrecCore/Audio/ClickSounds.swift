import Foundation

/// Screc's own click sounds (SPEC §3.5), synthesised from formulas: no recorded audio, no third-party samples.
/// Deterministic: the same inputs always give the same samples (the noise comes from a fixed-seed generator).
public enum ClickSounds {
    public static let sampleRate = 48_000.0

    /// One click, mono, peak ≈ 0.5.
    public static func samples(_ sound: CursorLook.ClickSound) -> [Float] {
        switch sound {
        case .none:
            return []
        case .soft:
            // A rounded "tock": a short 1.1 kHz tone with a low 180 Hz body.
            let n = Int(0.06 * sampleRate)
            return (0..<n).map { i in
                let t = Double(i) / sampleRate
                let tone = sin(2 * .pi * 1100 * t) * exp(-t / 0.008)
                let body = sin(2 * .pi * 180 * t) * exp(-t / 0.018)
                let attack = min(t / 0.0015, 1)
                return Float((0.30 * tone + 0.35 * body) * attack)
            }
        case .crisp:
            // A bright "tick": a filtered noise burst plus a 3.2 kHz ping.
            let n = Int(0.035 * sampleRate)
            var state: UInt32 = 0x1234_5678
            var previous = 0.0
            return (0..<n).map { i in
                let t = Double(i) / sampleRate
                state = state &* 1_664_525 &+ 1_013_904_223            // fixed-seed LCG
                let white = Double(state >> 8) / Double(1 << 24) * 2 - 1
                let high = white - previous                              // simple high-pass
                previous = white
                let noise = high * exp(-t / 0.0025)
                let ping = sin(2 * .pi * 3200 * t) * exp(-t / 0.004)
                let attack = min(t / 0.0004, 1)
                return Float((0.22 * noise + 0.30 * ping) * attack)
            }
        }
    }

    /// A mono track of the whole timeline with a click at each time (seconds). Overlaps are added.
    public static func track(clickTimes: [Double], duration: Double, sound: CursorLook.ClickSound, volume: Double = 0.8) -> [Float] {
        let length = max(Int((duration * sampleRate).rounded(.up)), 1)
        var out = [Float](repeating: 0, count: length)
        let click = samples(sound)
        guard !click.isEmpty else { return out }
        let gain = Float(min(max(volume, 0), 1))
        for t in clickTimes where t >= 0 && t < duration {
            let start = Int((t * sampleRate).rounded())
            for (k, v) in click.enumerated() where start + k < length {
                out[start + k] += v * gain
            }
        }
        for i in out.indices { out[i] = min(max(out[i], -1), 1) }
        return out
    }
}
