import Dependencies
import Foundation
@preconcurrency import TailcatCore

/// The public capabilities share private storage instead of exposing a base class.
protocol TailcatResource: AnyObject, Sendable {
    var storage: ResourceStorage { get }
}

final class ResourceStorage: Sendable {
    let handle: Int64
    let ownership: Ownership
    let parent: (any TailcatResource)?
    let runtime: Tailcat.Session?

    init(abort: @escaping @Sendable () -> Void, close: @escaping @Sendable () async throws -> Void) {
        handle = 0
        ownership = Ownership(abort: abort, close: close)
        parent = nil
        runtime = nil
    }
    init(handle: Int64, parent: (any TailcatResource)? = nil, runtime: Tailcat.Session) {
        self.handle = handle
        self.parent = parent
        self.runtime = runtime
        ownership = Ownership(abort: { [weak runtime] in runtime?.abortResource(handle) },
                              close: { [weak runtime] in try await runtime?.closeResource(handle) })
    }
    deinit { ownership.requestShutdown() }
}

extension TailcatResource {
    var handle: Int64 { storage.handle }
    var ownership: Ownership { storage.ownership }
    var parent: (any TailcatResource)? { storage.parent }
    // Only bridge adapters reach this after a successful request. Fake operations
    // fail at the request gate before accessing an absent live runtime.
    var runtime: Tailcat.Session { storage.runtime! }

    func closeOwned() async throws {
        if let server = HandlerScope.server, server === self { throw Tailcat.Failure.ownershipConflict }
        try await ownership.close()
        if let runtime = storage.runtime, HandlerScope.server?.runtime !== runtime {
            var ancestor = parent
            while let current = ancestor {
                if current.ownership.isShuttingDown { try await current.ownership.close() }
                ancestor = current.parent
            }
            if runtime.ownership.isShuttingDown { try await runtime.ownership.close() }
        }
    }
    func request<T: Decodable>(_ method: String, _ input: Tailcat.Metadata = [:]) async throws -> T {
        try await requestValue(method, input).decode()
    }
    func requestValue(_ method: String, _ input: Tailcat.Metadata = [:]) async throws -> Tailcat.JSONValue {
        try Task.checkCancellation()
        try ownership.checkOpen()
        guard let runtime = storage.runtime else { throw Tailcat.Failure.unimplemented(method) }
        var input = input
        input["handle"] = .integer(handle)
        return try await runtime.requestValue(method, input)
    }
    func requestVoid(_ method: String, _ input: Tailcat.Metadata = [:]) async throws {
        _ = try await requestValue(method, input)
    }
}

extension Tailcat.Cache {
public struct Entry: Codable, Equatable, Sendable {
    public let data: Data
    public let etag: String
    public let ok: Bool
    public let storedAt: Int64
    public init(data: Data, etag: String, ok: Bool = true, storedAt: Date = .now) throws {
        self.data = data
        self.etag = etag
        self.ok = ok
        self.storedAt = try unixNanoseconds(storedAt)
    }
    public var storageDate: Date { Date(timeIntervalSince1970: Double(storedAt) / 1_000_000_000) }
    enum CodingKeys: String, CodingKey { case data; case etag; case ok; case storedAt }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decodeIfPresent(Data.self, forKey: .data) ?? Data()
        etag = try container.decode(String.self, forKey: .etag)
        ok = try container.decode(Bool.self, forKey: .ok)
        storedAt = try container.decode(Int64.self, forKey: .storedAt)
    }
}
}

extension Tailcat {
public final class Cache: TailcatResource, @unchecked Sendable {
    private let entryProvider: (@Sendable (URL) async throws -> Entry)?
    private let storeProvider: (@Sendable (Data, String, Date, URL) async throws -> Void)?
    public init(abort: @escaping @Sendable () -> Void,
                close: @escaping @Sendable () async throws -> Void,
                entry: @escaping @Sendable (URL) async throws -> Entry = { _ in throw Tailcat.Failure.unimplemented("Cache.entry") },
                store: @escaping @Sendable (Data, String, Date, URL) async throws -> Void = { _, _, _, _ in throw Tailcat.Failure.unimplemented("Cache.store") }) {
        storage = ResourceStorage(abort: abort, close: close)
        storageBridge = nil
        entryProvider = entry
        storeProvider = store
    }

    let storage: ResourceStorage
    public func close() async throws { try await closeOwned() }
    public func requestShutdown() { ownership.requestShutdown() }

    let storageBridge: CacheStorageBridge?
    init(handle: Int64, runtime: Tailcat.Session, storage: (any Tailcat.Cache.Storage)? = nil) {
        entryProvider = nil
        storeProvider = nil
        storageBridge = storage.map(CacheStorageBridge.init)
        self.storage = ResourceStorage(handle: handle, runtime: runtime)
    }
    public func entry(for url: URL) async throws -> Tailcat.Cache.Entry {
        try Task.checkCancellation()
        try ownership.checkOpen()
        if let entryProvider { return try await entryProvider(url) }
        return try await request("cache.get", ["url": .string(url.absoluteString)])
    }
    public func store(data: Data, etag: String, storedAt: Date = .now, url: URL) async throws {
        try Task.checkCancellation()
        try ownership.checkOpen()
        if let storeProvider { return try await storeProvider(data, etag, storedAt, url) }
        try await requestVoid("cache.put", ["data": data.jsonValue(), "etag": .string(etag),
                                           "storedAt": .integer(unixNanoseconds(storedAt)),
                                           "url": .string(url.absoluteString)])
    }
}
}

final class CacheStorageBridge: NSObject, MobileCacheStorageProtocol {
    private let dependencies = withEscapedDependencies { $0 }
    private let storage: any Tailcat.Cache.Storage
    init(_ storage: any Tailcat.Cache.Storage) { self.storage = storage }
    func get(_ rawURL: String?) -> String {
        guard let rawURL, let url = URL(string: rawURL), let entry = dependencies.yield({ storage.get(url: url) }),
              let json = try? JSONEncoder().encode(entry) else { return "" }
        return String(decoding: json, as: UTF8.self)
    }
    func put(_ rawURL: String?, entry: String?) -> String {
        guard let rawURL, let url = URL(string: rawURL), let entry,
              let decoded = try? JSONDecoder().decode(Tailcat.Cache.Entry.self, from: Data(entry.utf8)), decoded.ok else {
            return "invalid cache entry"
        }
        do {
            try dependencies.yield { try storage.put(data: decoded.data, etag: decoded.etag, storedAt: decoded.storageDate, url: url) }
            return ""
        } catch { return String(describing: error) }
    }
}

extension Tailcat.Server {
public struct Policy: Sendable {
    public var allowClient: @Sendable (String) -> Bool
    public var allowProxy: @Sendable (String) -> Bool
    public init(allowClient: @escaping @Sendable (String) -> Bool = { _ in true },
                allowProxy: @escaping @Sendable (String) -> Bool = { _ in true }) {
        self.allowClient = allowClient
        self.allowProxy = allowProxy
    }
}
}

final class PolicyBridge: NSObject, MobilePolicyProtocol {
    private let dependencies = withEscapedDependencies { $0 }
    private let policy: Tailcat.Server.Policy
    init(_ policy: Tailcat.Server.Policy) { self.policy = policy }
    func allowClient(_ key: String?) -> Bool { dependencies.yield { policy.allowClient(key ?? "") } }
    func allowProxy(_ endpoint: String?) -> Bool { dependencies.yield { policy.allowProxy(endpoint ?? "") } }
}

extension Tailcat.Server {
public struct AddressInfo: Codable, Equatable, Sendable {
    public let address: Tailcat.Address
    public let ip: String
}
}

extension Tailcat {
public final class Server: TailcatResource, @unchecked Sendable {
    private let startProvider: (@Sendable () async throws -> Void)?
    private let addressProvider: (@Sendable () async throws -> Tailcat.Address)?
    private let tcpProvider: (@Sendable (Tailcat.TunnelListenAddress) async throws -> Tailcat.TCPListener)?
    private let udpProvider: (@Sendable (Tailcat.TunnelListenAddress) async throws -> Tailcat.UDPListener)?
    public init(abort: @escaping @Sendable () -> Void,
                address: @escaping @Sendable () async throws -> Tailcat.Address = { throw Tailcat.Failure.unimplemented("Server.address") },
                close: @escaping @Sendable () async throws -> Void,
                listenTCP: @escaping @Sendable (Tailcat.TunnelListenAddress) async throws -> Tailcat.TCPListener = { _ in throw Tailcat.Failure.unimplemented("Server.listenTCP") },
                listenUDP: @escaping @Sendable (Tailcat.TunnelListenAddress) async throws -> Tailcat.UDPListener = { _ in throw Tailcat.Failure.unimplemented("Server.listenUDP") },
                start: @escaping @Sendable () async throws -> Void = { throw Tailcat.Failure.unimplemented("Server.start") }) {
        storage = ResourceStorage(abort: abort, close: close)
        cache = nil
        handlerBridge = nil
        policyBridge = nil
        startProvider = start
        addressProvider = address
        tcpProvider = listenTCP
        udpProvider = listenUDP
    }
    public func address() async throws -> Tailcat.Address {
        try Task.checkCancellation()
        try ownership.checkOpen()
        if let addressProvider { return try await addressProvider() }
        return try await addressInfo().address
    }
    public func tunnelIP() async throws -> Tailcat.IPAddress { try await Tailcat.IPAddress(addressInfo().ip) }
    public func listenTCP(address: Tailcat.TunnelListenAddress = .init()) async throws -> Tailcat.TCPListener {
        let endpoint = try address.endpoint(transport: .tcp)
        return try await acquire(parent: ownership, ownership: { $0.ownership }) {
            if let tcpProvider { return try await tcpProvider(address) }
            return try await rawListen(address: endpoint, transport: .tcp)
        }
    }
    public func listenUDP(address: Tailcat.TunnelListenAddress = .init()) async throws -> Tailcat.UDPListener {
        let endpoint = try address.endpoint(transport: .udp)
        return try await acquire(parent: ownership, ownership: { $0.ownership }) {
            if let udpProvider { return try await udpProvider(address) }
            return Tailcat.UDPListener(listener: try await rawListen(address: endpoint, transport: .udp))
        }
    }

    let storage: ResourceStorage
    public func close() async throws { try await closeOwned() }
    public func requestShutdown() { ownership.requestShutdown() }

    let cache: Tailcat.Cache?
    let handlerBridge: HandlerBridge?
    let policyBridge: PolicyBridge?
    init(cache: Tailcat.Cache? = nil, handle: Int64, handlers: Tailcat.Server.Handlers?, policy: Tailcat.Server.Policy?, runtime: Tailcat.Session) {
        startProvider = nil
        addressProvider = nil
        tcpProvider = nil
        udpProvider = nil
        self.cache = cache
        handlerBridge = handlers.map { HandlerBridge(handlers: $0, runtime: runtime) }
        policyBridge = policy.map(PolicyBridge.init)
        storage = ResourceStorage(handle: handle, runtime: runtime)
        handlerBridge?.server = self
    }

    func addressInfo() async throws -> Tailcat.Server.AddressInfo { try await request("server.address") }
    public func admit(clientKey: String) async throws -> Bool {
        let response: AllowedResponse = try await request("server.admit", ["key": .string(clientKey)])
        return response.allowed
    }
    public func contains(clientKey: String) async throws -> Bool {
        let response: AllowedResponse = try await request("server.contains", ["key": .string(clientKey)])
        return response.allowed
    }
    public func disconnect(clientKey: String) async throws -> Bool {
        let response: DisconnectedResponse = try await request("server.disconnect", ["key": .string(clientKey)])
        return response.disconnected
    }
    public func drainTCP() async throws { try await requestVoid("server.drain") }
    func listen(address: String, family: Tailcat.IPFamily = .any, transport: Tailcat.Transport = .tcp) async throws -> Tailcat.TCPListener {
        try Ports.validateEndpoint(address, as: .local, transport: transport)
        return try await acquire(parent: ownership, ownership: { $0.ownership }) {
            try await rawListen(address: address, family: family, transport: transport)
        }
    }
    private func rawListen(address: String, family: Tailcat.IPFamily = .any, transport: Tailcat.Transport = .tcp) async throws -> Tailcat.TCPListener {
        try await retained("server.listen", ["address": .string(address), "network": .string(transport.network(family: family))]) { (response: ListenerResponse) in
            try Tailcat.TCPListener(address: response.address, handle: response.handle, parent: self, runtime: runtime, transport: transport)
        }
    }
    public func peerEnvironment(local: String, remote: String) async throws -> [String] {
        let response: EnvironmentResponse = try await request("server.peerEnvironment", ["local": .string(local), "remote": .string(remote)])
        return response.environment
    }
    public func peerKey(address: String) async throws -> String? {
        let response: PeerResponse = try await request("server.peer", ["address": .string(address)])
        return response.ok ? response.key : nil
    }
    public func revoke(clientKey: String) async throws {
        try await requestVoid("server.revoke", ["key": .string(clientKey)])
    }
    public func start() async throws {
        try Task.checkCancellation(); try ownership.checkOpen()
        if let startProvider { try await startProvider() }
        else { try await requestVoid("server.start") }
    }
    public func status() async throws -> Tailcat.Status { try await request("server.status") }
}
}

extension Tailcat {
public final class Client: TailcatResource, @unchecked Sendable {
    private let tcpProvider: (@Sendable (Tailcat.Destination) async throws -> Tailcat.TCPConnection)?
    private let udpProvider: (@Sendable (Tailcat.Destination) async throws -> Tailcat.UDPConnection)?
    public init(abort: @escaping @Sendable () -> Void,
                close: @escaping @Sendable () async throws -> Void,
                connectTCP: @escaping @Sendable (Tailcat.Destination) async throws -> Tailcat.TCPConnection = { _ in throw Tailcat.Failure.unimplemented("Client.connectTCP") },
                connectUDP: @escaping @Sendable (Tailcat.Destination) async throws -> Tailcat.UDPConnection = { _ in throw Tailcat.Failure.unimplemented("Client.connectUDP") }) {
        storage = ResourceStorage(abort: abort, close: close)
        cache = nil
        tcpProvider = connectTCP
        udpProvider = connectUDP
    }
    public func connectTCP(to destination: Tailcat.Destination = .tunnelPort(Tailcat.Defaults.tunnelPort)) async throws -> Tailcat.TCPConnection {
        try destination.validate(transport: .tcp)
        return try await acquire(parent: ownership, ownership: { $0.ownership }) {
            if let tcpProvider { return try await tcpProvider(destination) }
            return try await rawConnect(destination, transport: .tcp)
        }
    }
    public func connectUDP(to destination: Tailcat.Destination = .tunnelPort(Tailcat.Defaults.tunnelPort)) async throws -> Tailcat.UDPConnection {
        try destination.validate(transport: .udp)
        return try await acquire(parent: ownership, ownership: { $0.ownership }) {
            if let udpProvider { return try await udpProvider(destination) }
            return Tailcat.UDPConnection(connection: try await rawConnect(destination, transport: .udp))
        }
    }
    private func rawConnect(_ destination: Tailcat.Destination, transport: Tailcat.Transport) async throws -> Tailcat.TCPConnection {
        let input: Tailcat.Metadata
        let method: String
        switch destination {
        case .endpoint(let endpoint):
            input = ["address": .string(endpoint.text), "network": .string(transport.rawValue)]
            method = "client.dialEndpoint"
        case .host(let family, let name, let service):
            let port = try service.resolve(transport: transport)
            let address = name.contains(":") ? "[\(name)]:\(port)" : "\(name):\(port)"
            input = ["address": .string(address), "network": .string(transport.network(family: family))]
            method = "client.dial"
        case .tunnelPort(let port):
            input = ["network": .string(transport.rawValue), "port": .integer(Int64(port))]
            method = "client.dialPort"
        }
        return try await retained(method, input) { (response: ConnectionResponse) in
            Tailcat.TCPConnection(addresses: response.addresses, handle: response.handle, parent: self, runtime: runtime)
        }
    }

    let storage: ResourceStorage
    public func close() async throws { try await closeOwned() }
    public func requestShutdown() { ownership.requestShutdown() }

    let cache: Tailcat.Cache?
    init(cache: Tailcat.Cache? = nil, handle: Int64, runtime: Tailcat.Session) {
        tcpProvider = nil
        udpProvider = nil
        self.cache = cache
        storage = ResourceStorage(handle: handle, runtime: runtime)
    }
    public func dialTCP(address: String, family: Tailcat.IPFamily = .any) async throws -> Tailcat.TCPConnection {
        try await dial(address: address, family: family, method: "client.dial", transport: .tcp)
    }
    public func dialTCP(endpoint: String) async throws -> Tailcat.TCPConnection {
        try await dial(address: endpoint, method: "client.dialEndpoint", transport: .tcp)
    }
    func dialTCP(port: Int) async throws -> Tailcat.TCPConnection { try await connectTCP(to: .tunnelPort(port)) }
    public func dialUDP(address: String, family: Tailcat.IPFamily = .any) async throws -> Tailcat.UDPConnection {
        let connection = try await dial(address: address, family: family, method: "client.dial", transport: .udp)
        return Tailcat.UDPConnection(connection: connection)
    }
    public func dialUDP(endpoint: String) async throws -> Tailcat.UDPConnection {
        let connection = try await dial(address: endpoint, method: "client.dialEndpoint", transport: .udp)
        return Tailcat.UDPConnection(connection: connection)
    }
    func dialUDP(port: Int) async throws -> Tailcat.UDPConnection { try await connectUDP(to: .tunnelPort(port)) }
    public func discoPing() async throws -> Tailcat.Discovery.Result { try await request("client.discoPing") }
    public func drainTCP() async throws { try await requestVoid("client.drain") }
    public func ping() async throws -> Duration {
        let response: PingResponse = try await request("client.ping")
        return .nanoseconds(response.latency)
    }
    public func publicKey() async throws -> String {
        let response: KeyResponse = try await request("client.key")
        return response.key
    }
    public func region() async throws -> Tailcat.DERPRegion { try await request("client.region") }

    private func dial(address: String, family: Tailcat.IPFamily = .any, method: String, transport: Tailcat.Transport) async throws -> Tailcat.TCPConnection {
        try Ports.validateEndpoint(address, as: .remote, transport: transport)
        return try await acquireLive(method, ["address": .string(address), "network": .string(transport.network(family: family))]) { (response: ConnectionResponse) in
            Tailcat.TCPConnection(addresses: response.addresses, handle: response.handle, parent: self, runtime: runtime)
        }
    }
}
}

extension Tailcat {
public final class TCPListener: TailcatResource, @unchecked Sendable {
    private let acceptProvider: (@Sendable () async throws -> Tailcat.TCPConnection)?
    public init(abort: @escaping @Sendable () -> Void,
                accept: @escaping @Sendable () async throws -> Tailcat.TCPConnection = { throw Tailcat.Failure.unimplemented("TCPListener.accept") },
                address: String = "[::]:1",
                close: @escaping @Sendable () async throws -> Void) throws {
        boundEndpoint = try Tailcat.IPEndpoint(parsing: address)
        storage = ResourceStorage(abort: abort, close: close)
        acceptProvider = accept
        self.address = address
        transport = .tcp
    }

    let storage: ResourceStorage
    public func close() async throws { try await closeOwned() }
    public func requestShutdown() { ownership.requestShutdown() }

    public let address: String
    public let boundEndpoint: Tailcat.IPEndpoint
    public let transport: Tailcat.Transport
    init(address: String, handle: Int64, parent: Tailcat.Server, runtime: Tailcat.Session, transport: Tailcat.Transport) throws {
        boundEndpoint = try Tailcat.IPEndpoint(parsing: address)
        acceptProvider = nil
        self.address = address
        self.transport = transport
        storage = ResourceStorage(handle: handle, parent: parent, runtime: runtime)
    }
    /// Cancelling accept closes this listener. Accepted connections remain explicit resources.
    public func accept() async throws -> Tailcat.TCPConnection {
        try ownership.checkOpen()
        return try await acquire(onCancel: { self.requestShutdown() }, parent: ownership.transferOwner, ownership: { $0.ownership }) {
            if let acceptProvider { return try await acceptProvider() }
            return try await retained("listener.accept") { (response: ConnectionResponse) in
                Tailcat.TCPConnection(addresses: response.addresses, handle: response.handle, parent: parent, runtime: runtime)
            }
        }
    }

    public func acceptDatagram() async throws -> Tailcat.UDPConnection {
        guard transport == .udp else { throw Tailcat.Failure.invalidInput("datagram acceptance requires a UDP listener") }
        return Tailcat.UDPConnection(connection: try await accept())
    }

    /// Pull-based iteration has no unbounded prefetch buffer.
    public var connections: Connections { Connections(listener: self) }
    public struct Connections: AsyncSequence, Sendable {
        public typealias Element = Tailcat.TCPConnection
        let listener: Tailcat.TCPListener
        public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(listener: listener) }
        public struct AsyncIterator: AsyncIteratorProtocol {
            let listener: Tailcat.TCPListener
            public mutating func next() async throws -> Tailcat.TCPConnection? { try await listener.accept() }
        }
    }
}
}

extension Tailcat {
// Storage is immutable; directional admission is serialized by DirectionLease.
public final class TCPConnection: TailcatResource, Sendable {
    private let closeWriteProvider: (@Sendable () async throws -> Void)?
    private let readLease = DirectionLease()
    private let readProvider: (@Sendable (Int) async throws -> Data?)?
    private let writeLease = DirectionLease()
    private let writeProvider: (@Sendable (Data) async throws -> Int)?
    public init(abort: @escaping @Sendable () -> Void,
                addresses: Tailcat.ConnectionAddresses = .init(),
                close: @escaping @Sendable () async throws -> Void,
                closeWrite: @escaping @Sendable () async throws -> Void = { throw Tailcat.Failure.unimplemented("TCPConnection.closeWrite") },
                read: @escaping @Sendable (Int) async throws -> Data? = { _ in throw Tailcat.Failure.unimplemented("TCPConnection.read") },
                writeSome: @escaping @Sendable (Data) async throws -> Int = { _ in throw Tailcat.Failure.unimplemented("TCPConnection.writeSome") }) {
        storage = ResourceStorage(abort: abort, close: close)
        self.addresses = addresses
        closeWriteProvider = closeWrite
        readProvider = read
        writeProvider = writeSome
    }

    let storage: ResourceStorage
    public func close() async throws { try await closeOwned() }
    public func requestShutdown() { ownership.requestShutdown() }

    public let addresses: Tailcat.ConnectionAddresses
    init(addresses: Tailcat.ConnectionAddresses, handle: Int64, parent: TailcatResource? = nil, runtime: Tailcat.Session) {
        closeWriteProvider = nil
        readProvider = nil
        writeProvider = nil
        self.addresses = addresses
        storage = ResourceStorage(handle: handle, parent: parent, runtime: runtime)
    }
    public func closeWrite() async throws {
        try writeLease.begin()
        defer { writeLease.end() }
        try Task.checkCancellation(); try ownership.checkOpen()
        if let closeWriteProvider { try await closeWriteProvider() }
        else { try await requestVoid("connection.closeWrite") }
    }
    public func proxy(to other: Tailcat.TCPConnection) async throws {
        try ownership.checkOpen()
        guard let runtime = storage.runtime, other.storage.runtime === runtime else { throw Tailcat.Failure.ownershipConflict }
        try runtime.checkOwner(other)
        try await requestVoid("connection.proxy", ["other": .integer(other.handle), "packet": .bool(false)])
    }
    /// nil represents EOF. One read and one write may run concurrently.
    public func read(maxBytes: Int = 65_536) async throws -> Data? {
        guard maxBytes > 0 else { throw Tailcat.Failure.invalidInput("maxBytes must be positive") }
        try Task.checkCancellation()
        try ownership.checkOpen()
        try readLease.begin()
        defer { readLease.end() }
        if let readProvider { return try await readProvider(maxBytes) }
        let response: ReadResponse = try await request("connection.read", ["count": .integer(Int64(maxBytes))])
        return response.eof && response.data.isEmpty ? nil : response.data
    }
    public func setDeadlines(read: Date? = nil, write: Date? = nil) async throws {
        try await requestVoid("connection.deadline", ["readDeadline": .integer(read.map { try unixNanoseconds($0) } ?? 0),
                                                      "writeDeadline": .integer(write.map { try unixNanoseconds($0) } ?? 0)])
    }
    /// Writes the entire payload under one direction lease. Empty writes are
    /// no-ops after lifecycle/cancellation checks. Providers must cooperate with
    /// task cancellation and report partial failures with WriteFailure.
    public func write(_ data: Data) async throws {
        try Task.checkCancellation()
        try ownership.checkOpen()
        try writeLease.begin()
        defer { writeLease.end() }
        var written = 0
        do {
            while written < data.count {
                try Task.checkCancellation()
                try ownership.checkOpen()
                written += try await performWriteSome(Data(data.dropFirst(written)))
            }
        } catch let failure as WriteFailure {
            throw WriteFailure(bytesWritten: written + failure.bytesWritten, cause: failure.cause)
        } catch {
            if written > 0 { throw WriteFailure(bytesWritten: written, cause: error) }
            throw error
        }
    }

    /// A single primitive write. Empty data returns zero without provider entry.
    @discardableResult public func writeSome(_ data: Data) async throws -> Int {
        try Task.checkCancellation()
        try ownership.checkOpen()
        try writeLease.begin()
        defer { writeLease.end() }
        return data.isEmpty ? 0 : try await performWriteSome(data)
    }

    private func performWriteSome(_ data: Data) async throws -> Int {
        let count: Int
        if let writeProvider { count = try await writeProvider(data) }
        else {
            let response: WriteResponse = try await request("connection.write", ["data": data.jsonValue()])
            if let code = response.writeErrorCode {
                let cause: any Error = code == 2 ? CancellationError() : Tailcat.Failure.operationFailed(response.writeErrorMessage ?? "write failed")
                throw WriteFailure(bytesWritten: response.count, cause: cause)
            }
            count = response.count
        }
        guard count > 0, count <= data.count else {
            throw Tailcat.Failure.operationFailed("write provider returned invalid progress")
        }
        return count
    }
}
}

/// Connected UDP preserves datagram boundaries and addresses.
extension Tailcat {
public final class UDPConnection: @unchecked Sendable {
    var ownership: Ownership { connection.ownership }
    public func requestShutdown() { ownership.requestShutdown() }
    let connection: Tailcat.TCPConnection
    private let receiveProvider: (@Sendable (Int) async throws -> Tailcat.Datagram)?
    private let sendProvider: (@Sendable (Data, String?) async throws -> Int)?
    init(connection: Tailcat.TCPConnection) { self.connection = connection; receiveProvider = nil; sendProvider = nil }
    public init(abort: @escaping @Sendable () -> Void,
                addresses: Tailcat.ConnectionAddresses = .init(),
                close: @escaping @Sendable () async throws -> Void,
                receive: @escaping @Sendable (Int) async throws -> Tailcat.Datagram = { _ in throw Tailcat.Failure.unimplemented("UDPConnection.receive") },
                send: @escaping @Sendable (Data, String?) async throws -> Int = { _, _ in throw Tailcat.Failure.unimplemented("UDPConnection.send") }) {
        connection = Tailcat.TCPConnection(abort: abort, addresses: addresses, close: close)
        receiveProvider = receive
        sendProvider = send
    }
    public var addresses: Tailcat.ConnectionAddresses { connection.addresses }
    public func close() async throws { try await connection.close() }
    public func proxy(to other: Tailcat.UDPConnection) async throws {
        try ownership.checkOpen()
        guard let runtime = connection.storage.runtime, other.connection.storage.runtime === runtime else { throw Tailcat.Failure.ownershipConflict }
        try runtime.checkOwner(other.connection)
        try await connection.requestVoid("connection.proxy", ["other": .integer(other.connection.handle), "packet": .bool(true)])
    }
    public func receive(maxBytes: Int = 1232) async throws -> Tailcat.Datagram {
        guard maxBytes > 0 else { throw Tailcat.Failure.invalidInput("maxBytes must be positive") }
        try Task.checkCancellation()
        try ownership.checkOpen()
        if let receiveProvider { return try await receiveProvider(maxBytes) }
        let response: ReadResponse = try await connection.request("connection.readPacket", ["count": .integer(Int64(maxBytes))])
        return Tailcat.Datagram(address: response.address, data: response.data)
    }
    @discardableResult public func send(_ data: Data, to address: String? = nil) async throws -> Int {
        try Task.checkCancellation()
        try ownership.checkOpen()
        if let sendProvider { return try await sendProvider(data, address) }
        var input: Tailcat.Metadata = ["data": try data.jsonValue()]
        input["address"] = .string(address ?? addresses.remote)
        let response: CountResponse = try await connection.request("connection.writePacket", input)
        return response.count
    }
    public func setDeadlines(read: Date? = nil, write: Date? = nil) async throws {
        try await connection.setDeadlines(read: read, write: write)
    }
}
}

struct AllowedResponse: Decodable { let allowed: Bool }
struct ConnectionResponse: Decodable {
    let handle: Int64
    let local: String
    let remote: String
    var addresses: Tailcat.ConnectionAddresses { Tailcat.ConnectionAddresses(local: local, remote: remote) }
}
struct CountResponse: Decodable { let count: Int }
struct DisconnectedResponse: Decodable { let disconnected: Bool }
struct EnvironmentResponse: Decodable { let environment: [String] }
struct KeyResponse: Decodable { let key: String }
struct ListenerResponse: Decodable { let address: String; let handle: Int64 }
struct PeerResponse: Decodable { let key: String; let ok: Bool }
struct PingResponse: Decodable { let latency: Int64; enum CodingKeys: String, CodingKey { case latency = "Latency" } }
struct ReadResponse: Decodable {
    let address: String?
    let data: Data
    let eof: Bool
    enum CodingKeys: String, CodingKey { case address; case data; case eof }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        address = try container.decodeIfPresent(String.self, forKey: .address)
        data = try container.decodeIfPresent(Data.self, forKey: .data) ?? Data()
        eof = try container.decodeIfPresent(Bool.self, forKey: .eof) ?? false
    }
}

// Each direction's busy flag is protected by the lock. No provider runs under it.
private final class DirectionLease: @unchecked Sendable {
    private var busy = false
    private let lock = NSLock()
    func begin() throws {
        try lock.withLock {
            guard !busy else { throw Tailcat.Failure.ownershipConflict }
            busy = true
        }
    }
    func end() { lock.withLock { busy = false } }
}

extension Tailcat.TCPConnection {
    public struct WriteFailure: Error, Sendable {
        public let bytesWritten: Int
        public let cause: any Error
        public init(bytesWritten: Int, cause: any Error) {
            self.bytesWritten = bytesWritten
            self.cause = cause
        }
    }
}

private struct WriteResponse: Decodable {
    let count: Int
    let writeErrorCode: Int?
    let writeErrorMessage: String?
}
