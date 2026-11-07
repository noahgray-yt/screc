import Foundation

/// Critically damped spring (SPEC §3.3: every zoom and pan follows one).
///
/// For a fixed target `x₁`, starting at position `x₀` with velocity `v₀`, the exact solution is
///
///     x(t) = x₁ + (A + B·t)·e^(−ωt)      with  A = x₀ − x₁,  B = v₀ + ω·A
///     v(t) = (B − ω·(A + B·t))·e^(−ωt)
///
/// From rest (`v₀ = 0`) this is the step response `p(t) = 1 − (1 + ωt)·e^(−ωt)`: it reaches 90 % after
/// `3.89/ω`, 99 % after `6.64/ω`, peaks in speed after `1/ω`, and never overshoots.
/// Following a target that moves at constant speed, it lags by exactly `2/ω` seconds.
public struct CriticalSpring: Equatable, Sendable {
    public var omega: Double

    public init(omega: Double) { self.omega = omega }

    /// Position and velocity after `t` seconds, for a target held at `target`.
    public func step(from x0: Double, velocity v0: Double, to target: Double, after t: Double) -> (x: Double, v: Double) {
        guard t > 0 else { return (x0, v0) }
        let a = x0 - target
        let b = v0 + omega * a
        let e = exp(-omega * t)
        return (target + (a + b * t) * e, (b - omega * (a + b * t)) * e)
    }

    /// Normalised step response from rest: 0 at t = 0, → 1.
    public func progress(after t: Double) -> Double {
        guard t > 0 else { return 0 }
        return 1 - (1 + omega * t) * exp(-omega * t)
    }

    /// Time to reach 99 % of a step from rest.
    public var settleTime: Double { 6.64 / omega }

    /// Lag behind a target moving at constant speed.
    public var lag: Double { 2 / omega }
}

/// A 2-D point following a target with the same spring on each axis.
public struct SpringFollower2D: Sendable {
    public var spring: CriticalSpring
    public private(set) var x: Double
    public private(set) var y: Double
    public private(set) var vx: Double = 0
    public private(set) var vy: Double = 0

    public init(omega: Double, x: Double, y: Double) {
        spring = CriticalSpring(omega: omega)
        self.x = x
        self.y = y
    }

    /// Advances by `dt` towards a target that is held constant during the step (exact, stable for any dt).
    public mutating func advance(towardX tx: Double, y ty: Double, dt: Double) {
        let nx = spring.step(from: x, velocity: vx, to: tx, after: dt)
        let ny = spring.step(from: y, velocity: vy, to: ty, after: dt)
        (x, vx) = nx
        (y, vy) = ny
    }

    public mutating func reset(x: Double, y: Double) {
        self.x = x
        self.y = y
        vx = 0
        vy = 0
    }
}
