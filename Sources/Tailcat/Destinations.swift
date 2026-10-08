import Darwin
import Foundation

extension Tailcat {
    public enum Destination: Sendable {
        case endpoint(IPEndpoint)
        case host(family: IPFamily = .any, name: String, service: NetworkService)
        case tunnelPort(Int)

        func validate(transport: Transport) throws {
            switch self {
            case .endpoint(let endpoint): try Ports.validate(endpoint.port, as: .remote)
            case .host(_, let name, let service):
                guard !name.isEmpty else { throw Failure.invalidInput("host is empty") }
                try Ports.validate(service.resolve(transport: transport), as: .remote)
            case .tunnelPort(let port): try Ports.validate(port, as: .remote)
            }
        }
    }

    public struct IPAddress: Codable, Hashable, Sendable {
        public let rawValue: String
        public init(_ value: String) throws {
            var ipv4 = in_addr()
            var ipv6 = in6_addr()
            guard inet_pton(AF_INET, value, &ipv4) == 1 || inet_pton(AF_INET6, value, &ipv6) == 1 else {
                throw Failure.invalidInput("IP address must be numeric")
            }
            rawValue = value
        }
        public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public struct IPEndpoint: Codable, Hashable, Sendable {
        public let address: IPAddress
        public let port: Int
        public init(address: IPAddress, port: Int) throws {
            try Ports.validate(port, as: .local)
            self.address = address
            self.port = port
        }
        enum CodingKeys: String, CodingKey { case address; case port }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(address: values.decode(IPAddress.self, forKey: .address), port: values.decode(Int.self, forKey: .port))
        }
        init(parsing text: String) throws {
            guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) else {
                throw Failure.invalidInput("bound endpoint requires a numeric port")
            }
            var host = String(text[..<colon])
            if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            if host.isEmpty { host = "::" }
            try self.init(address: IPAddress(host), port: port)
        }
        var text: String { address.rawValue.contains(":") ? "[\(address.rawValue)]:\(port)" : "\(address.rawValue):\(port)" }
    }

    public enum NetworkService: Sendable {
        case name(String)
        case port(Int)

        func resolve(transport: Transport) throws -> Int {
            switch self {
            case .name(let name):
                return try serviceLock.withLock {
                    guard !name.isEmpty, !name.contains("\0"), let service = getservbyname(name, transport.rawValue) else {
                        throw Failure.invalidInput("unknown network service")
                    }
                    return Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: service.pointee.s_port)))
                }
            case .port(let port): return port
            }
        }
    }

    public struct TunnelListenAddress: Sendable {
        public var host: IPAddress?
        public var service: NetworkService
        public init(host: IPAddress? = nil, service: NetworkService = .port(Defaults.tunnelPort)) {
            self.host = host
            self.service = service
        }
        func endpoint(transport: Transport) throws -> String {
            let port = try service.resolve(transport: transport)
            try Ports.validate(port, as: .local)
            return "[\(host?.rawValue ?? "::")]:\(port)"
        }
    }
}

// getservbyname returns process-shared storage. Copy the integer under this lock.
private let serviceLock = NSLock()

extension Ports {
    static func validateEndpoint(_ endpoint: String, as context: Context, transport: Tailcat.Transport) throws {
        guard let colon = endpoint.lastIndex(of: ":") else { throw Tailcat.Failure.invalidInput("endpoint requires a port") }
        let service = String(endpoint[endpoint.index(after: colon)...])
        if let port = Int(service) { try validate(port, as: context) }
        else {
            if service.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "+" }) {
                throw Tailcat.Failure.invalidInput("port is outside the supported range")
            }
            try validate(Tailcat.NetworkService.name(service).resolve(transport: transport), as: context)
        }
    }
}
