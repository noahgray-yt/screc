import Foundation
import Testing
@testable import ScrecCore

@Suite("events.jsonl format (ARCHITECTURE §4.2)")
struct TelemetryCodecTests {
    let header = TelemetryHeader(t0HostSeconds: 81234.123456, sampleHz: 120, videoPixelSize: [2880, 1800],
                                 eventTimestampUnit: "nanoseconds")

    let events: [TelemetryEvent] = [
        .pos(t: 0, x: 1402.5, y: 633),
        .down(t: 0.512, button: .left, x: 1410, y: 640, clickCount: 2),
        .up(t: 0.6011, button: .left, x: 1410, y: 640),
        .scroll(t: 1.2, dx: 0, dy: -12.5, x: 1410, y: 640),
        .key(t: 2.01, phase: .down, keyCode: 0, chars: "a\"\\é", mods: ["cmd", "shift"]),
        .key(t: 2.02, phase: .down, keyCode: 37, chars: "@", mods: ["opt"], key: "l"),
        .cursor(t: 2.5, shape: .iBeam),
        .frame(t: 3.5, rect: [0, 0, 2880, 1800]),
    ]

    @Test func lineFormatMatchesTheSpec() {
        #expect(TelemetryCodec.encode(.pos(t: 0.0083, x: 1404, y: 634.5))
                == #"{"t":0.008300,"type":"pos","x":1404.0,"y":634.50}"#)
        #expect(TelemetryCodec.encode(.down(t: 0.512, button: .left, x: 1410, y: 640, clickCount: 1))
                == #"{"t":0.512000,"type":"down","button":"left","x":1410.0,"y":640.0,"clickCount":1}"#)
    }

    @Test func roundTrip() throws {
        var text = TelemetryCodec.encode(header) + "\n"
        for e in events { text += TelemetryCodec.encode(e) + "\n" }
        let decoded = try TelemetryCodec.decodeFile(Data(text.utf8))
        #expect(decoded.header == header)
        #expect(decoded.events == events)
    }

    @Test func truncatedLastLineIsIgnored() throws {
        var text = TelemetryCodec.encode(header) + "\n"
        text += TelemetryCodec.encode(events[0]) + "\n"
        text += #"{"t":0.9,"type":"po"#      // crash in the middle of a line
        let decoded = try TelemetryCodec.decodeFile(Data(text.utf8))
        #expect(decoded.events == [events[0]])
    }

    @Test func unknownTypesAreSkippedAndEventsSorted() throws {
        var text = TelemetryCodec.encode(header) + "\n"
        text += TelemetryCodec.encode(.pos(t: 2, x: 1, y: 1)) + "\n"
        text += #"{"t":1.5,"type":"future-thing","value":3}"# + "\n"
        text += TelemetryCodec.encode(.pos(t: 1, x: 0, y: 0)) + "\n"
        let decoded = try TelemetryCodec.decodeFile(Data(text.utf8))
        #expect(decoded.events.map(\.t) == [1, 2])
    }

    @Test func missingHeaderFails() {
        #expect(throws: TelemetryCodec.DecodeError.self) {
            try TelemetryCodec.decodeFile(Data((TelemetryCodec.encode(events[0]) + "\n").utf8))
        }
    }

    @Test func writerBuffersUntilHeaderAndSortsChunks() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("screc-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TelemetryWriter(url: url, flushInterval: 60)
        writer.append(.pos(t: 0.2, x: 1, y: 1))
        writer.append(.pos(t: 0.1, x: 0, y: 0))
        writer.flush()
        #expect(try Data(contentsOf: url).isEmpty)     // no header yet → nothing written
        writer.setHeader(header)
        writer.append(.cursor(t: 0.15, shape: .arrow))
        #expect(writer.close() == 3)
        let decoded = try TelemetryCodec.decodeFile(try Data(contentsOf: url))
        #expect(decoded.events.map(\.t) == [0.1, 0.15, 0.2])
        let raw = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(raw.count == 4)
        #expect(raw[1].contains("\"t\":0.100000"))      // written in time order
    }
}
