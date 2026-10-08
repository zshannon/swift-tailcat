import Foundation

extension Tailcat.Discovery {
public struct Result: Codable, Equatable, Sendable {
    public let fields: Tailcat.Metadata
    public init(from decoder: any Decoder) throws { fields = try Tailcat.Metadata(from: decoder) }
    public func encode(to encoder: any Encoder) throws { try fields.encode(to: encoder) }
    public var derpRegionCode: String? { fields["DERPRegionCode"]?.stringValue }
    public var derpRegionID: Int? { fields["DERPRegionID"]?.integerValue.map(Int.init) }
    public var endpoint: String? { fields["Endpoint"]?.stringValue }
    public var error: String? { fields["Err"]?.stringValue }
    public var isDirect: Bool { !(endpoint?.isEmpty ?? true) }
    public var latencySeconds: Double? {
        switch fields["LatencySeconds"] {
        case .integer(let value): Double(value)
        case .number(let value): value
        default: nil
        }
    }
}
}

extension Tailcat {
public struct Status: Codable, Equatable, Sendable {
    public let fields: Tailcat.Metadata
    public init(from decoder: any Decoder) throws { fields = try Tailcat.Metadata(from: decoder) }
    public func encode(to encoder: any Encoder) throws { try fields.encode(to: encoder) }
    public var backendState: String? { fields["BackendState"]?.stringValue }
    public var peers: Tailcat.Metadata? {
        guard case .object(let peers) = fields["Peer"] else { return nil }
        return peers
    }
}
}
