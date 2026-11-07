import Foundation

/// Appends telemetry lines to `events.jsonl` and flushes them to disk every 2 s (crash safety, REC-06).
///
/// Thread-safe: `append` can be called from any thread (event tap thread, display link, window poller).
/// All file work happens on one private serial queue.
/// Lines are buffered until the header is known (the header needs `t0`, the host time of the first frame).
public final class TelemetryWriter: @unchecked Sendable {
    // Confined to `queue`.
    private let queue = DispatchQueue(label: "screc.telemetry.writer")
    private let handle: FileHandle
    private var header: TelemetryHeader?
    private var headerWritten = false
    private var pending: [TelemetryEvent] = []
    private var timer: DispatchSourceTimer?
    private var closed = false
    private var linesWritten = 0

    public let url: URL

    public init(url: URL, flushInterval: TimeInterval = 2.0) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        timer.setEventHandler { [weak self] in self?.flushLocked() }
        timer.resume()
        self.timer = timer
    }

    public func setHeader(_ header: TelemetryHeader) {
        queue.async { self.header = header }
    }

    public func append(_ event: TelemetryEvent) {
        queue.async {
            guard !self.closed else { return }
            self.pending.append(event)
        }
    }

    /// Writes everything buffered and calls `fsync`.
    public func flush() {
        queue.sync { flushLocked() }
    }

    /// Final flush; returns the number of event lines written.
    @discardableResult
    public func close() -> Int {
        queue.sync {
            flushLocked()
            timer?.cancel()
            timer = nil
            closed = true
            try? handle.close()
            return linesWritten
        }
    }

    private func flushLocked() {
        guard !closed, let header else { return }
        var text = ""
        if !headerWritten {
            text += TelemetryCodec.encode(header) + "\n"
            headerWritten = true
        }
        // Different sources (tap thread, display link) can deliver slightly out of order.
        // Sort each chunk; readers sort the whole file again.
        let chunk = pending.enumerated().sorted { a, b in
            a.element.t == b.element.t ? a.offset < b.offset : a.element.t < b.element.t
        }.map(\.element)
        pending.removeAll(keepingCapacity: true)
        for event in chunk { text += TelemetryCodec.encode(event) + "\n" }
        linesWritten += chunk.count
        guard !text.isEmpty else { return }
        do {
            try handle.write(contentsOf: Data(text.utf8))
            try handle.synchronize()
        } catch {
            NSLog("Screc: writing events.jsonl failed: \(error)")
        }
    }
}
