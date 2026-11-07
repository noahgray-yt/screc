import Foundation
import os

/// Pure maths of the recording clock (ARCHITECTURE §6.2):
/// `source = host − t0 − (paused time before host)`.
///
/// Pauses are stored as **host-time intervals**, not as a "paused now" flag. Samples often arrive later
/// than their timestamp (audio buffers, event taps), so each sample is judged by its own timestamp:
/// a late sample from before the pause is kept, a sample from inside the pause is dropped.
public struct ClockState: Equatable, Sendable {
    public struct Pause: Equatable, Sendable {
        public var startHost: Double
        public var endHost: Double?   // nil while paused
    }

    /// Host time (seconds) of the first screen frame.
    public private(set) var t0Host: Double?
    public private(set) var pauses: [Pause] = []
    /// Host time of the Stop press. Samples stamped later are dropped, so every track ends exactly here.
    public private(set) var stopHost: Double?

    public init() {}

    public var isPaused: Bool { pauses.last.map { $0.endHost == nil } ?? false }

    /// Sets `t0` once; later calls are ignored.
    public mutating func start(atHost host: Double) {
        if t0Host == nil { t0Host = host }
    }

    /// Ends the take: closes an open pause and drops everything stamped after `host`.
    public mutating func stop(atHost host: Double) {
        guard t0Host != nil, stopHost == nil else { return }
        if isPaused { resume(atHost: host) }
        stopHost = host
    }

    public mutating func pause(atHost host: Double) {
        guard t0Host != nil, !isPaused else { return }
        pauses.append(Pause(startHost: host, endHost: nil))
    }

    public mutating func resume(atHost host: Double) {
        guard isPaused, let last = pauses.indices.last else { return }
        pauses[last].endHost = max(host, pauses[last].startHost)
    }

    /// Source time for a host timestamp, or `nil` if it lies before `t0` or inside a pause.
    public func sourceTime(host: Double) -> Double? {
        guard let t0Host, host >= t0Host else { return nil }
        if let stopHost, host > stopHost { return nil }
        var pausedBefore = 0.0
        for p in pauses {
            if host < p.startHost { break }
            guard let end = p.endHost else { return nil }      // inside the open pause
            if host < end { return nil }                        // inside a closed pause
            pausedBefore += end - p.startHost
        }
        return host - t0Host - pausedBefore
    }

    /// Pauses as written to `recording.json`: source time of the pause and its length.
    public var pausesForRecordingInfo: [RecordingInfo.PauseRecord] {
        guard let t0Host else { return [] }
        var removed = 0.0
        var result: [RecordingInfo.PauseRecord] = []
        for p in pauses {
            guard let end = p.endHost else { continue }
            let length = end - p.startHost
            result.append(.init(atSource: p.startHost - t0Host - removed, pausedFor: length))
            removed += length
        }
        return result
    }
}

/// Thread-safe wrapper shared by the screen, audio, webcam and telemetry paths.
/// **Every** timestamp goes through `sourceTime(host:)`, so the tracks cannot drift apart.
public final class RecordingClock: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: ClockState())

    public init() {}

    public func start(atHost host: Double) { state.withLock { $0.start(atHost: host) } }
    public func pause(atHost host: Double) { state.withLock { $0.pause(atHost: host) } }
    public func resume(atHost host: Double) { state.withLock { $0.resume(atHost: host) } }
    /// Stops the take at `host` and returns its source time (the take duration).
    public func stop(atHost host: Double) -> Double? {
        state.withLock { clock in
            clock.stop(atHost: host)
            return clock.stopHost.flatMap { clock.sourceTime(host: $0) }
        }
    }
    public func sourceTime(host: Double) -> Double? { state.withLock { $0.sourceTime(host: host) } }
    public var snapshot: ClockState { state.withLock { $0 } }
    public var isStarted: Bool { snapshot.t0Host != nil }
    public var isPaused: Bool { snapshot.isPaused }
}

/// Host time helpers. "Host time" = `mach_absolute_time` converted to seconds
/// (the same clock as `CMClockGetHostTimeClock()`, `CACurrentMediaTime()` and display link timestamps).
public enum HostTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func seconds(fromMachTicks ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    public static var now: Double { seconds(fromMachTicks: mach_absolute_time()) }
}
