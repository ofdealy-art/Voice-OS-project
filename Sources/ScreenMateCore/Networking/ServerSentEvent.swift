import Foundation

public struct ServerSentEvent: Sendable, Equatable {
    public let event: String?
    public let data: String

    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }

    /// `data: [DONE]` — OpenAI's end-of-stream sentinel.
    public var isDoneSentinel: Bool {
        data.trimmingCharacters(in: .whitespaces) == "[DONE]"
    }
}

/// Incremental `text/event-stream` parser.
///
/// Fed one line at a time so it works with `URLSession.bytes(for:).lines` and
/// with a canned array of lines in tests.
public struct ServerSentEventParser: Sendable {
    private var eventName: String?
    private var dataLines: [String] = []

    public init() {}

    /// Returns a complete event once a blank line terminates the block.
    public mutating func consume(line: String) -> ServerSentEvent? {
        // A completely empty line dispatches the buffered event.
        if line.isEmpty {
            return flush()
        }
        // Comment / heartbeat.
        if line.hasPrefix(":") {
            return nil
        }
        guard let colon = line.firstIndex(of: ":") else {
            // A field with no value; SSE treats it as the field name with "".
            return nil
        }
        let field = String(line[line.startIndex..<colon])
        var value = String(line[line.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }

        switch field {
        case "event": eventName = value
        case "data": dataLines.append(value)
        default: break // id / retry are not used here
        }
        return nil
    }

    /// Dispatches anything still buffered when the connection closes without a
    /// trailing blank line.
    public mutating func flush() -> ServerSentEvent? {
        guard !dataLines.isEmpty else {
            eventName = nil
            return nil
        }
        let event = ServerSentEvent(event: eventName, data: dataLines.joined(separator: "\n"))
        eventName = nil
        dataLines.removeAll(keepingCapacity: true)
        return event
    }

    /// Convenience for tests: parse a whole stream of lines at once.
    public static func parseAll(lines: [String]) -> [ServerSentEvent] {
        var parser = ServerSentEventParser()
        var events: [ServerSentEvent] = []
        for line in lines {
            if let event = parser.consume(line: line) { events.append(event) }
        }
        if let event = parser.flush() { events.append(event) }
        return events
    }
}
