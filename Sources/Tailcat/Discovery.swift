import Foundation

extension Tailcat.Discovery {
public struct Packet: Codable, Equatable, Sendable {
    public let isMeow: Bool
    public let isMeowed: Bool
}
}

extension Tailcat.Discovery {
public struct Ping: Codable, Equatable, Sendable {
    public let discoKey: String
    public let key: String
    public let ok: Bool
}
}

extension Tailcat.Session {
    public func discoveryPing(discoKey: String, nodeKey: String) async throws -> Data {
        let response: DataResponse = try await request("disco.encodePing", ["discoKey": .string(discoKey), "key": .string(nodeKey)])
        return response.data
    }
    public func discoveryPong() async throws -> Data {
        let response: DataResponse = try await request("disco.encodePong")
        return response.data
    }
    public func expand(_ info: Tailcat.ConnectionInfo, cache: Tailcat.Cache? = nil, forServer: Bool = false,
                       map: Tailcat.DERPMap? = nil, url: URL? = nil) async throws -> Tailcat.ConnectionInfo {
        var input: Tailcat.Metadata = ["forServer": .bool(forServer), "info": try info.jsonValue()]
        if let cache { try checkOwner(cache); input["cache"] = .integer(cache.handle) }
        if let map { input["map"] = try map.jsonValue() }
        if let url { input["derpMapURL"] = .string(url.absoluteString) }
        return try await request("address.expand", input)
    }
    public func importDiscoveryKey(data: Data) async throws -> Tailcat.NodePublicKey {
        try await request("key.discovery", ["data": data.jsonValue()])
    }
    public func importDiscoveryKey(text: String) async throws -> Tailcat.NodePublicKey {
        try await request("key.discovery", ["key": .string(text)])
    }
    public func importNodeKey(data: Data) async throws -> Tailcat.NodePublicKey {
        try await request("key.node", ["data": data.jsonValue()])
    }
    public func importNodeKey(text: String) async throws -> Tailcat.NodePublicKey {
        try await request("key.node", ["key": .string(text)])
    }
    public func inspectDiscoveryPacket(_ data: Data) async throws -> Tailcat.Discovery.Packet {
        try await request("disco.inspect", ["data": data.jsonValue()])
    }
    public func parseDiscoveryPing(_ data: Data) async throws -> Tailcat.Discovery.Ping {
        try await request("disco.parsePing", ["data": data.jsonValue()])
    }
}
