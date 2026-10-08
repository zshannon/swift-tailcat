import Foundation

extension Tailcat {
public enum Defaults {
    public static let derpMapURL = URL(string: "https://tailcat.dev/derpmap.json")!
    public static let maximumUDPPayload = 1232
    public static let tunnelPort: Int = 1
    public static let udpPayloadWithoutFragmentation = 1232
    public static let udpIdleTimeout: Duration = .seconds(120)
}
}

extension Tailcat {
public struct ResolvedDestination: Codable, Equatable, Sendable {
    public let address: Tailcat.Address
    public let dnsName: String?
    public init(address: Tailcat.Address, dnsName: String? = nil) {
        self.address = address
        self.dnsName = dnsName?.isEmpty == false ? dnsName : nil
    }
    enum CodingKeys: String, CodingKey { case address; case dnsName }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(address: try container.decode(Tailcat.Address.self, forKey: .address),
                  dnsName: try container.decodeIfPresent(String.self, forKey: .dnsName))
    }
}
}

extension Tailcat.Session {
    /// Resolves validated tailcat= TXT records; a Tailcat address bypasses DNS entirely.
    public func lookup(name: String, resolver: String? = nil) async throws -> Tailcat.ResolvedDestination {
        var input: Tailcat.Metadata = ["name": .string(name)]
        if let resolver { input["resolver"] = .string(resolver) }
        return try await request("address.lookup", input)
    }

    /// DNS destinations get the CLI's bounded stranger probe before the real connection.
    /// Probe failures are nonfatal; host-key validation also applies to the real connection.
    public func openSSH(cache: Tailcat.Cache? = nil, configuration: Tailcat.SSH.Configuration,
                        derpMapURL: URL? = nil, destination: Tailcat.ResolvedDestination,
                        permitPublicNoAuthentication: Bool = false, privateKey: String? = nil) async throws -> Tailcat.SSH {
        try configuration.validate()
        let client = try await createClient(configuration: .init(address: destination.address,
            cache: cache, derpMapURL: derpMapURL, privateKey: privateKey))
        do {
            if destination.dnsName != nil && !permitPublicNoAuthentication {
                let accessible: Bool
                do { accessible = try await boundedProbe(client: client, configuration: configuration) }
                catch is CancellationError { throw CancellationError() }
                catch { accessible = false }
                if accessible {
                    throw Tailcat.Failure.invalidInput("DNS destination permits SSH access without tunnel or SSH authentication")
                }
            }
            return try await client.openSSH(configuration: configuration)
        } catch {
            try? await client.close()
            throw error
        }
    }
}

extension Tailcat.Client {
    /// Uses a fresh node key, no SSH credentials and the supplied pinned host key.
    public func probeAnonymousSSH(configuration: Tailcat.SSH.Configuration) async throws -> Bool {
        try configuration.validate()
        var input: Tailcat.Metadata = ["hostKey": .string(configuration.hostKey),
            "port": .integer(Int64(configuration.port)), "user": .string(configuration.user)]
        if let endpoint = configuration.endpoint { input["address"] = .string(endpoint) }
        let response: AnonymousResponse = try await request("ssh.probeAnonymous", input)
        return response.accessible
    }
}

extension Tailcat.SOCKSService {
    /// macOS only. Cancellation terminates the owned process group; arguments bypass a shell.
    public func runLocalCommand(arguments: [String], environment: [String: String] = [:]) async throws -> Tailcat.SSH.CommandResult {
        try await request("socks.command", ["environment": environment.jsonValue(), "exec": arguments.jsonValue()])
    }
}

private struct AnonymousResponse: Decodable { let accessible: Bool }

private func boundedProbe(client: Tailcat.Client, configuration: Tailcat.SSH.Configuration) async throws -> Bool {
    try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask { try await client.probeAnonymousSSH(configuration: configuration) }
        group.addTask {
            try await Task.sleep(for: .seconds(10))
            throw Tailcat.Failure.operationFailed("anonymous SSH probe timed out")
        }
        defer { group.cancelAll() }
        return try await group.next() ?? false
    }
}
