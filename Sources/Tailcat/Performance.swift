import Foundation

extension Tailcat.Performance {
public enum Direction: String, Codable, Sendable {
    case bidirectional = "both"
    case download = "down"
    case upload = "up"
}
}

extension Tailcat.Performance {
public struct Parameters: Sendable {
    public var bitrate: Int64
    public var bytes: Int64
    public var direction: Tailcat.Performance.Direction
    public var duration: Duration
    public var interval: Duration
    public var length: Int
    public var streams: Int
    public var transport: Tailcat.Transport
    public init(bitrate: Int64 = 0, bytes: Int64 = 0, direction: Tailcat.Performance.Direction = .upload,
                duration: Duration = .seconds(1), interval: Duration = .zero,
                length: Int = 1024, streams: Int = 1, transport: Tailcat.Transport = .tcp) {
        self.bitrate = bitrate
        self.bytes = bytes
        self.direction = direction
        self.duration = duration
        self.interval = interval
        self.length = length
        self.streams = streams
        self.transport = transport
    }
    func fields() throws -> Tailcat.JSONValue {
        .object(["bitrate": .integer(bitrate), "bytes": .integer(bytes), "dir": .string(direction.rawValue),
                 "duration": .integer(try nanoseconds(duration)), "interval": .integer(try nanoseconds(interval)),
                 "length": .integer(Int64(length)), "proto": .string(transport.rawValue), "streams": .integer(Int64(streams))])
    }
}
}

extension Tailcat.Performance {
public struct Interval: Codable, Equatable, Sendable {
    public let bytes: Int64
    public let datagrams: Int64?
}
}

extension Tailcat.Performance {
public struct Statistics: Codable, Equatable, Sendable {
    public let bytes: Int64
    public let datagrams: Int64?
    public let duration: Int64
    public let intervals: [Tailcat.Performance.Interval]?
    public let jitter: Int64?
    public let reordered: Int64?
}
}

extension Tailcat.Performance {
public struct RoundTrip: Codable, Equatable, Sendable {
    public let avg: Int64
    public let count: Int
    public let max: Int64
    public let min: Int64
}
}

extension Tailcat.Performance {
public struct Progress: Codable, Equatable, Sendable {
    public let elapsed: Int64
    public let received: Tailcat.Performance.Interval
    public let rtt: Int64
    public let sent: Tailcat.Performance.Interval
    enum CodingKeys: String, CodingKey {
        case elapsed = "Elapsed"
        case received = "Received"
        case rtt = "RTT"
        case sent = "Sent"
    }
}
}

extension Tailcat.Performance {
public struct Result: Codable, Equatable, Sendable {
    public let clientReceived: Tailcat.Performance.Statistics?
    public let clientSent: Tailcat.Performance.Statistics?
    public let params: Tailcat.Metadata
    public let progress: [Tailcat.Performance.Progress]
    public let progressDropped: Int?
    public let rtt: Tailcat.Performance.RoundTrip?
    public let serverReceived: Tailcat.Performance.Statistics?
    public let serverSent: Tailcat.Performance.Statistics?
    enum CodingKeys: String, CodingKey {
        case clientReceived; case clientSent; case params; case progress; case progressDropped
        case rtt; case serverReceived; case serverSent
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientReceived = try container.decodeIfPresent(Tailcat.Performance.Statistics.self, forKey: .clientReceived)
        clientSent = try container.decodeIfPresent(Tailcat.Performance.Statistics.self, forKey: .clientSent)
        params = try container.decode(Tailcat.Metadata.self, forKey: .params)
        progress = try container.decodeIfPresent([Tailcat.Performance.Progress].self, forKey: .progress) ?? []
        progressDropped = try container.decodeIfPresent(Int.self, forKey: .progressDropped)
        rtt = try container.decodeIfPresent(Tailcat.Performance.RoundTrip.self, forKey: .rtt)
        serverReceived = try container.decodeIfPresent(Tailcat.Performance.Statistics.self, forKey: .serverReceived)
        serverSent = try container.decodeIfPresent(Tailcat.Performance.Statistics.self, forKey: .serverSent)
    }
}
}

extension Tailcat.Client {
    /// Throughput uses direct paths by default. Explicit relay opt-in is for an owned custom relay.
    public func measurePerformance(allowOwnedRelay: Bool = false, parameters: Tailcat.Performance.Parameters,
                                   requireDirect: Bool = false,
                                   onProgress: (@Sendable (Tailcat.Performance.Progress) -> Void)? = nil) async throws -> Tailcat.Performance.Result {
        let input: Tailcat.Metadata = ["allowSharedRelay": .bool(allowOwnedRelay),
                                     "handle": .integer(handle), "params": try parameters.fields(),
                                     "requireDirect": .bool(requireDirect)]
        let progress: (@Sendable (Tailcat.JSONValue) -> Void)?
        if let handler = onProgress {
            progress = { value in
                if let snapshot = try? value.decode(Tailcat.Performance.Progress.self) { handler(snapshot) }
            }
        } else { progress = nil }
        try ownership.checkOpen()
        guard let runtime = storage.runtime else { throw Tailcat.Failure.unimplemented("Client.measurePerformance") }
        return try await runtime.request("perf.run", input, onProgress: progress)
    }
}
