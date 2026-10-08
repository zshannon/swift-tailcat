import Foundation

extension Tailcat.SSHService.FileService {
public enum Mode: UInt8, Codable, Sendable {
    case readOnly = 0
    case readWrite = 1
    case writeOnly = 2
    case writeOnlyRecursive = 3
}
}

extension Tailcat.SSHService {
public struct FileService: Codable, Sendable {
    public var directory: URL
    public var mode: Tailcat.SSHService.FileService.Mode
    public init(directory: URL, mode: Tailcat.SSHService.FileService.Mode) {
        self.directory = directory
        self.mode = mode
    }
    enum CodingKeys: String, CodingKey { case directory = "dir"; case mode }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        directory = URL(fileURLWithPath: try container.decode(String.self, forKey: .directory))
        mode = try container.decode(Tailcat.SSHService.FileService.Mode.self, forKey: .mode)
    }
    public func encode(to encoder: any Encoder) throws {
        guard directory.isFileURL else { throw Tailcat.Failure.invalidInput("file service requires a local file URL") }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(directory.path, forKey: .directory)
        try container.encode(mode, forKey: .mode)
    }
}
}

extension Tailcat.SSHService {
public enum Authentication: Equatable, Sendable {
    /// Explicitly permit unauthenticated SSH access. Tailcat admission still applies.
    case none
    case publicKeys([String])
}
}

extension Tailcat.SSHService {
public struct Configuration: Encodable, Sendable {
    public var authentication: Tailcat.SSHService.Authentication
    public var exec: [String]?
    public var files: Tailcat.SSHService.FileService?
    public var shell: Bool
    public init(authentication: Tailcat.SSHService.Authentication = .publicKeys([]), exec: [String]? = nil,
                files: Tailcat.SSHService.FileService? = nil, shell: Bool = false) {
        self.authentication = authentication
        self.exec = exec
        self.files = files
        self.shell = shell
    }
    enum CodingKeys: String, CodingKey { case authorizedKeys; case exec; case files; case shell }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch authentication {
        case .none: break
        case .publicKeys(let keys): try container.encode(keys, forKey: .authorizedKeys)
        }
        try container.encodeIfPresent(exec, forKey: .exec)
        try container.encodeIfPresent(files, forKey: .files)
        try container.encode(shell, forKey: .shell)
    }
}
}

extension Tailcat.SSH {
public struct Configuration: Sendable {
    public var endpoint: String?
    public var hostKey: String
    public var port: Int
    public var privateKeys: [String]
    public var user: String
    public init(endpoint: String? = nil, hostKey: String, port: Int = 22, privateKeys: [String] = [], user: String) {
        self.endpoint = endpoint
        self.hostKey = hostKey
        self.port = port
        self.privateKeys = privateKeys
        self.user = user
    }
    func validate() throws {
        try Ports.validate(port, as: .remote)
        if let endpoint { try Ports.validateEndpoint(endpoint, as: .remote, transport: .tcp) }
    }

}
}

extension Tailcat.SSH.Session {
public struct Terminal: Codable, Sendable {
    public var height: Int
    public var term: String
    public var width: Int
    public init(height: Int = 24, term: String = "xterm-256color", width: Int = 80) {
        self.height = height
        self.term = term
        self.width = width
    }
}
}

extension Tailcat.SSH {
public struct CommandResult: Codable, Equatable, Sendable {
    public let exitCode: Int
    public let stderr: Data
    public let stdout: Data
    enum CodingKeys: String, CodingKey { case exitCode; case stderr; case stdout }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exitCode = try container.decode(Int.self, forKey: .exitCode)
        stderr = try container.decodeIfPresent(Data.self, forKey: .stderr) ?? Data()
        stdout = try container.decodeIfPresent(Data.self, forKey: .stdout) ?? Data()
    }
}
}

extension Tailcat.SSH.Session {
public struct Result: Codable, Equatable, Sendable {
    public let exitCode: Int
    public let stderr: Data
    enum CodingKeys: String, CodingKey { case exitCode; case stderr }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exitCode = try container.decode(Int.self, forKey: .exitCode)
        stderr = try container.decodeIfPresent(Data.self, forKey: .stderr) ?? Data()
    }
}
}

extension Tailcat.RemoteFile {
public struct Info: Codable, Equatable, Sendable {
    public let isDirectory: Bool
    public let mode: UInt32
    public let modifiedAt: Int64
    public let name: String
    public let size: Int64
    public var modificationDate: Date { Date(timeIntervalSince1970: Double(modifiedAt) / 1_000_000_000) }
}
}

extension Tailcat {
public final class ForwardService: TailcatResource, @unchecked Sendable {
    public init(abort: @escaping @Sendable () -> Void, address: String = "", close: @escaping @Sendable () async throws -> Void, port: Int? = nil, url: URL? = nil) throws {
        if let port { try Ports.validate(port, as: .local) }
        self.address = address
        hostKey = nil
        self.port = port
        self.url = url
        storage = ResourceStorage(abort: abort, close: close)
    }

    let storage: ResourceStorage
    public func close() async throws { try await closeOwned() }
    public func requestShutdown() { ownership.requestShutdown() }

    public let address: String
    public let hostKey: String?
    public let port: Int?
    /// Live Client.forwardTCP supplies an HTTP URL for its host-local listener, following the CLI convention.
    /// Server.forward does not populate this value. A URL does not detect whether the service speaks HTTP.
    public let url: URL?
    init(address: String, handle: Int64, hostKey: String? = nil,
         parent: (any TailcatResource)? = nil, port: Int? = nil, runtime: Tailcat.Session, url: URL? = nil) {
        self.address = address
        self.hostKey = hostKey
        self.port = port
        self.url = url
        storage = ResourceStorage(handle: handle, parent: parent, runtime: runtime)
    }
}
}

extension Tailcat.Client {
    func openSSH(configuration: Tailcat.SSH.Configuration) async throws -> Tailcat.SSH { try await connectSSH(configuration: configuration) }
    /// Each returned listener has independent ownership and cancellation.
    public func forwardTCP(bind: String = "127.0.0.1:0", endpoint: String) async throws -> Tailcat.ForwardService {
        try Ports.validateEndpoint(bind, as: .local, transport: .tcp)
        try Ports.validateEndpoint(endpoint, as: .remote, transport: .tcp)
        return try await acquireLive("forward.start", ["address": .string(endpoint), "bind": .string(bind), "network": .string("tcp")]) { (response: ServiceResponse) in
            return response.service(parent: self, runtime: runtime, webURL: true)
        }
    }

    public func forwardTCP(bind: String = "127.0.0.1:0", port: Int) async throws -> Tailcat.ForwardService {
        try Ports.validate(port, as: .remote)
        try Ports.validateEndpoint(bind, as: .local, transport: .tcp)
        return try await acquireLive("forward.start", ["bind": .string(bind), "network": .string("tcp"), "port": .integer(Int64(port))]) { (response: ServiceResponse) in
            return response.service(parent: self, runtime: runtime, webURL: true)
        }
    }

    public func connectSSH(configuration: Tailcat.SSH.Configuration) async throws -> Tailcat.SSH {
        try configuration.validate()
        var input: Tailcat.Metadata = ["hostKey": .string(configuration.hostKey), "port": .integer(Int64(configuration.port)),
                                     "privateKeys": try configuration.privateKeys.jsonValue(), "user": .string(configuration.user)]
        if let endpoint = configuration.endpoint { input["address"] = .string(endpoint) }
        return try await acquireLive("ssh.connect", input) { (response: SSHResponse) in
            return Tailcat.SSH(handle: response.handle, hostKey: response.hostKey, parent: self, runtime: runtime)
        }
    }

    public func startSOCKS(bind: String = "127.0.0.1:0") async throws -> Tailcat.SOCKSService {
        try Ports.validateEndpoint(bind, as: .local, transport: .tcp)
        return try await acquireLive("socks.start", ["bind": .string(bind)]) { (response: ServiceResponse) in
            return Tailcat.SOCKSService(address: response.address, handle: response.handle, parent: self, runtime: runtime)
        }
    }
}

extension Tailcat.Session {
    /// A default client is unnecessary when SOCKS destinations are Tailcat addresses.
    public func startSOCKS(bind: String = "127.0.0.1:0") async throws -> Tailcat.SOCKSService {
        try Ports.validateEndpoint(bind, as: .local, transport: .tcp)
        return try await acquireLive("socks.start", ["bind": .string(bind)]) { (response: ServiceResponse) in
            return Tailcat.SOCKSService(address: response.address, handle: response.handle, parent: nil, runtime: self)
        }
    }
}

extension Tailcat.Server {
    /// Map one tunnel port to an explicit local/host/IPv6 endpoint. Zero selects an unused Tailcat tunnel port.
    public func forward(endpoint: String, port: Int = 0, transport: Tailcat.Transport = .tcp) async throws -> Tailcat.ForwardService {
        try Ports.validate(port, as: .local)
        try Ports.validateEndpoint(endpoint, as: .remote, transport: transport)
        return try await acquireLive("server.forward", ["address": .string(endpoint),
            "network": .string(transport.rawValue), "port": .integer(Int64(port))]) { (response: ServiceResponse) in
            return response.service(parent: self, runtime: runtime)
        }
    }

    public func serveExec(arguments: [String], port: Int) async throws -> Tailcat.ForwardService {
        try Ports.validate(port, as: .local)
        return try await acquireLive("server.service", ["exec": arguments.jsonValue(), "kind": .string("exec"), "port": .integer(Int64(port))]) { (response: ServiceResponse) in
            return response.service(parent: self, runtime: runtime)
        }
    }

    public func servePerformance(maxDuration: Duration = .seconds(600), maxStreams: Int = 128,
                                 port: Int = 5201) async throws -> Tailcat.PerformanceService {
        try Ports.validate(port, as: .local)
        return try await acquireLive("server.service", ["kind": .string("perf"),
                                                                            "maxDuration": .integer(nanoseconds(maxDuration)),
                                                                            "maxStreams": .integer(Int64(maxStreams)),
                                                                            "port": .integer(Int64(port))]) { (response: ServiceResponse) in
            guard let actualPort = response.port else { throw Tailcat.Failure.operationFailed("performance service returned no port") }
            return Tailcat.PerformanceService(address: response.address, handle: response.handle, parent: self, port: actualPort, runtime: runtime)
        }
    }

    public func serveSSH(configuration: Tailcat.SSHService.Configuration, port: Int = 22) async throws -> Tailcat.SSHService {
        try Ports.validate(port, as: .local)
        return try await acquireLive("server.service", ["kind": .string("ssh"), "port": .integer(Int64(port)), "ssh": configuration.jsonValue()]) { (response: ServiceResponse) in
            guard let hostKey = response.hostKey, let actualPort = response.port else { throw Tailcat.Failure.operationFailed("SSH service returned incomplete metadata") }
            return Tailcat.SSHService(address: response.address, handle: response.handle, hostKey: hostKey, parent: self, port: actualPort, runtime: runtime)
        }
    }
}

extension Tailcat {
public final class SSH: TailcatResource, @unchecked Sendable {
    func openSFTP() async throws -> Tailcat.SFTP { try await makeSFTP() }
    func openSession(terminal: Tailcat.SSH.Session.Terminal? = nil) async throws -> Tailcat.SSH.Session { try await makeSession(terminal: terminal) }
    public init(abort: @escaping @Sendable () -> Void, close: @escaping @Sendable () async throws -> Void, hostKey: String) {
        self.hostKey = hostKey
        storage = ResourceStorage(abort: abort, close: close)
    }

    let storage: ResourceStorage
    public func close() async throws { try await closeOwned() }
    public func requestShutdown() { ownership.requestShutdown() }

    public let hostKey: String
    init(handle: Int64, hostKey: String, parent: Tailcat.Client, runtime: Tailcat.Session) {
        self.hostKey = hostKey
        storage = ResourceStorage(handle: handle, parent: parent, runtime: runtime)
    }
    /// Cancellation closes this SSH transport and its sessions.
    public func makeSFTP() async throws -> Tailcat.SFTP {
        return try await acquireLive("sftp.connect") { (response: HandleResponse) in
            return Tailcat.SFTP(handle: response.handle, parent: self, runtime: runtime)
        }
    }
    /// Cancelling channel creation or its PTY request closes this SSH transport.
    public func makeSession(terminal: Tailcat.SSH.Session.Terminal? = nil) async throws -> Tailcat.SSH.Session {
        var input: Tailcat.Metadata = [:]
        if let terminal { input["pty"] = try terminal.jsonValue() }
        return try await acquireLive("ssh.session", input) { (response: HandleResponse) in
            return Tailcat.SSH.Session(handle: response.handle, parent: self, runtime: runtime)
        }
    }
    /// Cancellation closes this SSH transport and its sessions.
    public func run(command: String, input: Data = Data()) async throws -> Tailcat.SSH.CommandResult {
        try await request("ssh.run", ["command": .string(command), "input": input.jsonValue()])
    }
}
}

/// Cancelling any session operation closes its owning SSH transport and sibling sessions.
extension Tailcat.SSH {
public final class Session: TailcatResource, @unchecked Sendable {
    public init(abort: @escaping @Sendable () -> Void, close: @escaping @Sendable () async throws -> Void) {
        storage = ResourceStorage(abort: abort, close: close)
    }

    init(handle: Int64, parent: (any TailcatResource)? = nil, runtime: Tailcat.Session) {
        storage = ResourceStorage(handle: handle, parent: parent, runtime: runtime)
    }

    let storage: ResourceStorage
    public func close() async throws { try await closeOwned() }
    public func requestShutdown() { ownership.requestShutdown() }

    public func closeInput() async throws { try await requestVoid("ssh.session.closeInput") }
    public func read(maxBytes: Int = 65_536) async throws -> Data? {
        let response: ReadResponse = try await request("ssh.session.read", ["count": .integer(Int64(maxBytes))])
        return response.eof && response.data.isEmpty ? nil : response.data
    }
    public func resize(height: Int, width: Int) async throws {
        try await requestVoid("ssh.session.resize", ["height": .integer(Int64(height)), "width": .integer(Int64(width))])
    }
    public func start(command: String? = nil) async throws {
        var input: Tailcat.Metadata = [:]
        if let command { input["command"] = .string(command) }
        try await requestVoid("ssh.session.start", input)
    }
    /// Repeated and concurrent waits share the command's cached result.
    public func wait() async throws -> Tailcat.SSH.Session.Result { try await request("ssh.session.wait") }
    @discardableResult public func write(_ data: Data) async throws -> Int {
        let response: CountResponse = try await request("ssh.session.write", ["data": data.jsonValue()])
        return response.count
    }
}
}

/// Cancellation and close terminate the owning SSH transport, including sibling sessions.
extension Tailcat {
public final class SFTP: TailcatResource, @unchecked Sendable {
    public init(abort: @escaping @Sendable () -> Void, close: @escaping @Sendable () async throws -> Void) {
        storage = ResourceStorage(abort: abort, close: close)
    }

    init(handle: Int64, parent: (any TailcatResource)? = nil, runtime: Tailcat.Session) {
        storage = ResourceStorage(handle: handle, parent: parent, runtime: runtime)
    }

    let storage: ResourceStorage
    public func close() async throws { try await closeOwned() }
    public func requestShutdown() { ownership.requestShutdown() }

    public func chmod(path: String, permissions: UInt32) async throws {
        try await requestVoid("sftp.chmod", ["mode": .integer(Int64(permissions)), "path": .string(path)])
    }
    public func list(path: String) async throws -> [Tailcat.RemoteFile.Info] {
        let response: FilesResponse = try await request("sftp.list", ["path": .string(path)])
        return response.files
    }
    /// Metadata for the link itself; never follows a remote symbolic link.
    public func lstat(path: String) async throws -> Tailcat.RemoteFile.Info { try await request("sftp.lstat", ["path": .string(path)]) }
    public func makeDirectory(path: String) async throws { try await requestVoid("sftp.mkdir", ["path": .string(path)]) }
    public func read(maxBytes: Int = 65_536, offset: Int64 = 0, path: String) async throws -> Data {
        let response: DataResponse = try await request("sftp.read", ["count": .integer(Int64(maxBytes)), "offset": .integer(offset), "path": .string(path)])
        return response.data
    }
    public func remove(path: String) async throws { try await requestVoid("sftp.remove", ["path": .string(path)]) }
    public func rename(destination: String, path: String) async throws {
        try await requestVoid("sftp.rename", ["destination": .string(destination), "path": .string(path)])
    }
    public func setTimes(access: Date, modification: Date, path: String) async throws {
        try await requestVoid("sftp.times", ["accessTime": .integer(unixNanoseconds(access)),
                                            "modifyTime": .integer(unixNanoseconds(modification)), "path": .string(path)])
    }
    public func stat(path: String) async throws -> Tailcat.RemoteFile.Info { try await request("sftp.stat", ["path": .string(path)]) }
    @discardableResult public func write(create: Bool = true, data: Data, offset: Int64 = 0,
                                        path: String, truncate: Bool = false) async throws -> Int {
        let response: CountResponse = try await request("sftp.write", ["create": .bool(create), "data": data.jsonValue(),
                                                                      "offset": .integer(offset), "path": .string(path),
                                                                      "truncate": .bool(truncate)])
        return response.count
    }
}
}

struct DataResponse: Decodable {
    let data: Data
    enum CodingKeys: String, CodingKey { case data }
    init(from decoder: any Decoder) throws {
        data = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Data.self, forKey: .data) ?? Data()
    }
}
struct FilesResponse: Decodable { let files: [Tailcat.RemoteFile.Info] }
struct ServiceResponse: Decodable {
    let address: String
    let handle: Int64
    let hostKey: String?
    let port: Int?
    let url: String?
    enum CodingKeys: String, CodingKey { case address; case handle; case hostKey; case port; case url }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        address = try values.decode(String.self, forKey: .address)
        handle = try values.decode(Int64.self, forKey: .handle)
        hostKey = try values.decodeIfPresent(String.self, forKey: .hostKey)
        let explicitPort = try values.decodeIfPresent(Int.self, forKey: .port)
        let resolvedPort = address.isEmpty ? nil : try Tailcat.IPEndpoint(parsing: address).port
        port = explicitPort ?? resolvedPort
        url = try values.decodeIfPresent(String.self, forKey: .url)
        if let port { try Ports.validate(port, as: .local) }
    }
    func service(parent: (any TailcatResource)? = nil, runtime: Tailcat.Session, webURL: Bool = false) -> Tailcat.ForwardService {
        let readyURL = webURL ? browserURL(address: address) : url.flatMap(URL.init(string:))
        return Tailcat.ForwardService(address: address, handle: handle, hostKey: hostKey, parent: parent, port: port, runtime: runtime, url: readyURL)
    }
}
struct SSHResponse: Decodable { let handle: Int64; let hostKey: String }

private func browserURL(address: String) -> URL? {
    guard var components = URLComponents(string: "http://\(address)/"),
          components.host != nil, components.port != nil else { return nil }
    if ["0.0.0.0", "::", "[::]"].contains(components.host!) {
        components.host = "127.0.0.1"
    }
    return components.url
}
