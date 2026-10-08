import Foundation

/// An address contains a preshared secret. Store and exchange it as a credential.
extension Tailcat {
public struct Address: Codable, Hashable, RawRepresentable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
}

/// Full upstream DERP configuration retaining unknown fields as JSONValue.
/// Numbers use Int64/Double; original JSON bytes and arbitrary numeric precision are not preserved.
extension Tailcat {
public struct DERPMap: Codable, Equatable, Sendable {
    public var fields: Tailcat.Metadata
    public init(fields: Tailcat.Metadata) throws { try Ports.validateDERP(fields); self.fields = fields }
    public init(regions: [Tailcat.DERPRegion]) throws {
        for region in regions { try Ports.validateDERP(region.fields) }
        guard Set(regions.map(\.id)).count == regions.count else {
            throw Tailcat.Failure.invalidInput("duplicate DERP region ID")
        }
        fields = ["Regions": .object(Dictionary(uniqueKeysWithValues: regions.map {
            (String($0.id), .object($0.fields))
        }))]
    }
    public init(from decoder: any Decoder) throws { try self.init(fields: Tailcat.Metadata(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { try Ports.validateDERP(fields); try fields.encode(to: encoder) }
    public var regions: [Tailcat.DERPRegion] {
        guard case .object(let regions) = fields["Regions"] else { return [] }
        return regions.values.compactMap {
            guard case .object(let fields) = $0 else { return nil }
            return try? Tailcat.DERPRegion(fields: fields)
        }.sorted { $0.id < $1.id }
    }

    /// CLI-style code/name lookup. Ambiguous names use the lowest region ID.
    /// `list` is a CLI presentation request, so it has no selected region.
    public func region(matching query: String) -> Tailcat.DERPRegion? {
        guard query != "list" else { return nil }
        let locale = Locale(identifier: "en_US_POSIX")
        if let exact = regions.first(where: {
            ($0.fields["RegionCode"]?.stringValue ?? "").compare(query, options: .caseInsensitive, locale: locale) == .orderedSame
        }) { return exact }
        return regions.first {
            ($0.fields["RegionName"]?.stringValue ?? "").range(of: query, options: .caseInsensitive, locale: locale) != nil
        }
    }
}
}

extension Tailcat {
public struct DERPRegion: Codable, Equatable, Sendable {
    public var fields: Tailcat.Metadata
    public init(fields: Tailcat.Metadata) throws { try Ports.validateDERP(fields); self.fields = fields }
    public init(code: String, id: Int, name: String, nodes: [Tailcat.DERPNode]) throws {
        for node in nodes { try Ports.validateDERP(node.fields) }
        fields = ["Nodes": .array(nodes.map { .object($0.fields) }), "RegionCode": .string(code),
                  "RegionID": .integer(Int64(id)), "RegionName": .string(name)]
    }
    public init(from decoder: any Decoder) throws { try self.init(fields: Tailcat.Metadata(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { try Ports.validateDERP(fields); try fields.encode(to: encoder) }
    public var id: Int { Int(fields["RegionID"]?.integerValue ?? 0) }
    public var nodes: [Tailcat.DERPNode] {
        guard case .array(let nodes) = fields["Nodes"] else { return [] }
        return nodes.compactMap {
            guard case .object(let fields) = $0 else { return nil }
            return try? Tailcat.DERPNode(fields: fields)
        }
    }
}
}

extension Tailcat {
public struct DERPNode: Codable, Equatable, Sendable {
    public var fields: Tailcat.Metadata
    public init(fields: Tailcat.Metadata) throws { try Ports.validateDERP(fields); self.fields = fields }
    public init(derpPort: Int, hostName: String, ipv4: String? = nil, ipv6: String? = nil,
                name: String, regionID: Int, stunPort: Int = 3478) throws {
        try Ports.validate(derpPort, as: .local)
        try Ports.validate(stunPort, as: .stun)
        fields = ["DERPPort": .integer(Int64(derpPort)), "HostName": .string(hostName),
                  "Name": .string(name), "RegionID": .integer(Int64(regionID)),
                  "STUNPort": .integer(Int64(stunPort))]
        if let ipv4 { fields["IPv4"] = .string(ipv4) }
        if let ipv6 { fields["IPv6"] = .string(ipv6) }
    }
    public init(from decoder: any Decoder) throws { try self.init(fields: Tailcat.Metadata(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { try Ports.validateDERP(fields); try fields.encode(to: encoder) }
}
}

extension Tailcat {
public struct ConnectionInfo: Codable, Equatable, Sendable {
    public var discoPublicKey: String
    public var presharedKey: String
    public var publicKey: String
    public var regionID: Int?
    public var regions: [Tailcat.DERPRegion]?

    public init(discoPublicKey: String, presharedKey: String, publicKey: String,
                regionID: Int? = nil, regions: [Tailcat.DERPRegion]? = nil) {
        self.discoPublicKey = discoPublicKey
        self.presharedKey = presharedKey
        self.publicKey = publicKey
        self.regionID = regionID
        self.regions = regions
    }

    enum CodingKeys: String, CodingKey {
        case discoPublicKey = "ServerDiscoPublic"
        case presharedKey = "PresharedKey"
        case publicKey = "ServerPublic"
        case regionID = "RegionID"
        case regions = "Region"
    }
}
}

/// Persist explicitly in host-owned secure storage; this value contains private keys.
extension Tailcat {
public struct Identity: Codable, Equatable, Sendable {
    public var connectionInfo: Tailcat.ConnectionInfo
    public var privateKey: String
    public init(connectionInfo: Tailcat.ConnectionInfo, privateKey: String) {
        self.connectionInfo = connectionInfo
        self.privateKey = privateKey
    }
    enum CodingKeys: String, CodingKey {
        case connectionInfo = "Public"
        case privateKey = "Private"
    }
}
}

extension Tailcat {
public struct NodePublicKey: Codable, Equatable, Sendable {
    public let data: Data
    public let key: String
}
}

extension Tailcat {
public struct PresharedKey: Codable, Equatable, Sendable {
    public let data: Data
    public let isZero: Bool
    public let key: String
    public static func == (lhs: Tailcat.PresharedKey, rhs: Tailcat.PresharedKey) -> Bool {
        guard lhs.data.count == rhs.data.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs.data, rhs.data) { difference |= left ^ right }
        return difference == 0
    }
}
}

extension Tailcat {
public struct PortRange: Codable, Equatable, Sendable {
    public let first: Int
    public let last: Int
    public init(first: Int, last: Int) throws {
        try Ports.validate(first, as: .local)
        try Ports.validate(last, as: .local)
        guard first <= last else { throw Tailcat.Failure.invalidInput("port range is reversed") }
        self.first = first
        self.last = last
    }
    enum CodingKeys: String, CodingKey { case first; case last }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(first: values.decode(Int.self, forKey: .first), last: values.decode(Int.self, forKey: .last))
    }
}
}

extension Tailcat {
public struct Capabilities: Codable, Equatable, Sendable {
    public let defaultUDPIdleTimeout: Int64
    public let maxUDPPayload: Int
    public let processExecution: Bool
    public let sshServer: Bool
    public let upstreamRevision: String
}
}

extension Tailcat {
public struct ConnectionAddresses: Codable, Equatable, Sendable {
    public let local: String
    public let remote: String
    public init(local: String = "", remote: String = "") { self.local = local; self.remote = remote }
}
}

extension Tailcat {
public struct Datagram: Equatable, Sendable {
    public let address: String?
    public let data: Data
    public init(address: String? = nil, data: Data) {
        self.address = address
        self.data = data
    }
}
}

extension Tailcat {
public enum Transport: String, Codable, Sendable {
    case tcp
    case udp

    func network(family: Tailcat.IPFamily) -> String {
        switch family {
        case .any: rawValue
        case .ipv4: rawValue + "4"
        case .ipv6: rawValue + "6"
        }
    }
}
}

extension Tailcat {
public enum IPFamily: Sendable { case any; case ipv4; case ipv6 }
}

extension Tailcat.Server {
public struct Configuration: Sendable {
    /// nil preserves upstream defaults; [] denies every client/destination.
    public var allowedClients: [String]?
    public var allowedProxies: [String]?
    public var cache: Tailcat.Cache?
    public var derpMapURL: URL?
    public var disablePresharedKey: Bool
    public var exitNode: Bool
    public var handlers: Tailcat.Server.Handlers?
    /// Opt in to mapping direct TCP/UDP ports to this local host at the same port.
    public var localPortHost: String?
    public var policy: Tailcat.Server.Policy?
    public var presharedKey: String?
    public var privateKey: String?
    public var region: Tailcat.DERPRegion?
    public var regionID: Int?
    public var servedTCPPorts: [Tailcat.PortRange]?
    public var servedUDPPorts: [Tailcat.PortRange]?
    public var udpIdleTimeout: Duration?

    public init(allowedClients: [String]? = nil, allowedProxies: [String]? = nil,
                cache: Tailcat.Cache? = nil, derpMapURL: URL? = nil,
                disablePresharedKey: Bool = false, exitNode: Bool = false, localPortHost: String? = nil,
                presharedKey: String? = nil, privateKey: String? = nil,
                region: Tailcat.DERPRegion? = nil, regionID: Int? = nil,
                servedTCPPorts: [Tailcat.PortRange]? = nil, servedUDPPorts: [Tailcat.PortRange]? = nil,
                udpIdleTimeout: Duration? = nil) {
        self.allowedClients = allowedClients
        self.allowedProxies = allowedProxies
        self.cache = cache
        self.derpMapURL = derpMapURL
        self.disablePresharedKey = disablePresharedKey
        self.exitNode = exitNode
        self.localPortHost = localPortHost
        self.presharedKey = presharedKey
        self.privateKey = privateKey
        self.region = region
        self.regionID = regionID
        self.servedTCPPorts = servedTCPPorts
        self.servedUDPPorts = servedUDPPorts
        self.udpIdleTimeout = udpIdleTimeout
    }
    func validate() throws {
        if let url = derpMapURL, !["http", "https"].contains(url.scheme) {
            throw Tailcat.Failure.invalidInput("DERP map URL must use HTTP or HTTPS")
        }
        if let region { try Ports.validateDERP(region.fields) }
        if let udpIdleTimeout, udpIdleTimeout <= .zero {
            throw Tailcat.Failure.invalidInput("UDP idle timeout must be positive")
        }
    }

}
}

extension Tailcat.Client {
public struct Configuration: Sendable {
    var legacyAddress: Tailcat.Address?
    public var cache: Tailcat.Cache?
    public var derpMapURL: URL?
    public var privateKey: String?
    init(address: Tailcat.Address, cache: Tailcat.Cache? = nil,
                derpMapURL: URL? = nil, privateKey: String? = nil) {
        self.legacyAddress = address
        self.cache = cache
        self.derpMapURL = derpMapURL
        self.privateKey = privateKey
    }
    public init(cache: Tailcat.Cache? = nil, derpMapURL: URL? = nil, privateKey: String? = nil) {
        self.cache = cache
        self.derpMapURL = derpMapURL
        self.privateKey = privateKey
    }
    func validate() throws {
        if let url = derpMapURL, !["http", "https"].contains(url.scheme) {
            throw Tailcat.Failure.invalidInput("DERP map URL must use HTTP or HTTPS")
        }
    }

}
}
