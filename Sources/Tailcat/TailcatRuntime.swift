import Dependencies
import Foundation
@preconcurrency import TailcatCore

/// Owns a Go runtime. Different resources may operate concurrently.
/// Explicitly close it when the host finishes; closure invalidates all descendants.
extension Tailcat {
// The Go runtime serializes its registry and operations with Go mutexes. Swift
// ownership and callback state live in separately synchronized private objects.
public final class Session: @unchecked Sendable {
    private let cacheProvider: (@Sendable ((any Tailcat.Cache.Storage)?) async throws -> Tailcat.Cache)?
    private let clientProvider: (@Sendable (Tailcat.Address, Tailcat.Client.Configuration) async throws -> Tailcat.Client)?
    private let core: MobileRuntime?
    let keySourcesProvider: (@Sendable ([Tailcat.SSH.AuthorizedKeySource]) async throws -> [String])?
    private let live: LiveSession?
    let ownership: Ownership
    private let serverProvider: (@Sendable (Tailcat.Server.Configuration) async throws -> Tailcat.Server)?

    init() throws {
        guard let core = MobileNewRuntime() else { throw Tailcat.Failure.operationFailed("cannot create Tailcat runtime") }
        self.core = core
        let live = LiveSession(core: core)
        self.live = live
        ownership = Ownership(abort: { live.abort() }, close: { try await live.close() })
        keySourcesProvider = nil
        cacheProvider = nil
        clientProvider = nil
        serverProvider = nil
    }

    public init(
        abort: @escaping @Sendable () -> Void,
        close: @escaping @Sendable () async throws -> Void,
        loadSSHAuthorizedKeys: @escaping @Sendable ([Tailcat.SSH.AuthorizedKeySource]) async throws -> [String] = { _ in throw Tailcat.Failure.unimplemented("Session.loadSSHAuthorizedKeys") },
        makeCache: @escaping @Sendable ((any Tailcat.Cache.Storage)?) async throws -> Tailcat.Cache = { _ in throw Tailcat.Failure.unimplemented("Session.makeCache") },
        makeClient: @escaping @Sendable (Tailcat.Address, Tailcat.Client.Configuration) async throws -> Tailcat.Client = { _, _ in throw Tailcat.Failure.unimplemented("Session.makeClient") },
        makeServer: @escaping @Sendable (Tailcat.Server.Configuration) async throws -> Tailcat.Server = { _ in throw Tailcat.Failure.unimplemented("Session.makeServer") }
    ) {
        core = nil
        live = nil
        ownership = Ownership(abort: abort, close: close)
        keySourcesProvider = loadSSHAuthorizedKeys
        cacheProvider = makeCache
        clientProvider = makeClient
        serverProvider = makeServer
    }

    deinit { ownership.requestShutdown() }

    public func makeCache(storage: (any Tailcat.Cache.Storage)? = nil) async throws -> Tailcat.Cache {
        try await acquire(parent: ownership, ownership: { $0.ownership }) {
            if let cacheProvider { return try await cacheProvider(storage) }
            return try await liveMakeCache(storage: storage)
        }
    }

    func createCache(storage: (any Tailcat.Cache.Storage)? = nil) async throws -> Tailcat.Cache {
        try await makeCache(storage: storage)
    }

    public func makeClient(address: Tailcat.Address, configuration: Tailcat.Client.Configuration = .init()) async throws -> Tailcat.Client {
        try configuration.validate()
        if let cache = configuration.cache { try checkOwner(cache) }
        return try await acquire(parent: ownership, ownership: { $0.ownership }) {
            if let clientProvider { return try await clientProvider(address, configuration) }
            return try await liveMakeClient(address: address, configuration: configuration)
        }
    }

    public func makeServer(configuration: Tailcat.Server.Configuration = .init()) async throws -> Tailcat.Server {
        try configuration.validate()
        if let cache = configuration.cache { try checkOwner(cache) }
        return try await acquire(parent: ownership, ownership: { $0.ownership }) {
            if let serverProvider { return try await serverProvider(configuration) }
            return try await liveMakeServer(configuration: configuration, handlers: configuration.handlers, policy: configuration.policy)
        }
    }

    func createClient(configuration: Tailcat.Client.Configuration) async throws -> Tailcat.Client {
        guard let address = configuration.legacyAddress else { throw Tailcat.Failure.invalidInput("client address is required") }
        return try await makeClient(address: address, configuration: configuration)
    }

    func createServer(configuration: Tailcat.Server.Configuration = .init(), handlers: Tailcat.Server.Handlers? = nil,
                      policy: Tailcat.Server.Policy? = nil) async throws -> Tailcat.Server {
        var configuration = configuration
        configuration.handlers = handlers
        configuration.policy = policy
        return try await makeServer(configuration: configuration)
    }

    public func requestShutdown() { ownership.requestShutdown() }

    public func address(from info: Tailcat.ConnectionInfo) async throws -> Tailcat.Address {
        let response: AddressResponse = try await request("address.encode", ["info": info.jsonValue()])
        return Tailcat.Address(rawValue: response.address)
    }

    public func capabilities() async throws -> Tailcat.Capabilities { try await request("capabilities") }

    /// Upstream verbosity is process-wide and freezes when any runtime first uses networking.
    public func configureVerbose(_ enabled: Bool) throws { try requireCore().configureVerbose(enabled) }

    public func close() async throws {
        guard HandlerScope.server?.runtime !== self else { throw Tailcat.Failure.ownershipConflict }
        try await ownership.close()
    }

    public func connectionInfo(for address: Tailcat.Address) async throws -> Tailcat.ConnectionInfo {
        try await request("address.parse", ["address": .string(address.rawValue)])
    }

    private func liveMakeCache(storage: (any Tailcat.Cache.Storage)? = nil) async throws -> Tailcat.Cache {
        try await retained("cache.create") { (response: HandleResponse) in
            let cache = Tailcat.Cache(handle: response.handle, runtime: self, storage: storage)
            try requireCore().setCacheStorage(response.handle, storage: cache.storageBridge)
            return cache
        }
    }

    private func liveMakeClient(address: Tailcat.Address, configuration: Tailcat.Client.Configuration) async throws -> Tailcat.Client {
        var input: Tailcat.Metadata = ["address": .string(address.rawValue)]
        if let cache = configuration.cache { try checkOwner(cache); input["cache"] = .integer(cache.handle) }
        if let url = configuration.derpMapURL { input["derpMapURL"] = .string(url.absoluteString) }
        if let key = configuration.privateKey { input["privateKey"] = .string(key) }
        return try await retained("client.create", input) { (response: HandleResponse) in
            Tailcat.Client(cache: configuration.cache, handle: response.handle, runtime: self)
        }
    }

    private func liveMakeServer(configuration: Tailcat.Server.Configuration = .init(), handlers: Tailcat.Server.Handlers? = nil,
                             policy: Tailcat.Server.Policy? = nil) async throws -> Tailcat.Server {
        var input: Tailcat.Metadata = ["disablePresharedKey": .bool(configuration.disablePresharedKey),
                                     "exitNode": .bool(configuration.exitNode)]
        if let value = configuration.allowedClients { input["allowedClients"] = try value.jsonValue() }
        if let value = configuration.allowedProxies { input["allowedProxies"] = try value.jsonValue() }
        if let value = configuration.cache { try checkOwner(value); input["cache"] = .integer(value.handle) }
        if let value = configuration.derpMapURL { input["derpMapURL"] = .string(value.absoluteString) }
        if let value = configuration.localPortHost { input["localPortHost"] = .string(value) }
        if let value = configuration.presharedKey { input["presharedKey"] = .string(value) }
        if let value = configuration.privateKey { input["privateKey"] = .string(value) }
        if let value = configuration.region { input["region"] = try value.jsonValue() }
        if let value = configuration.regionID { input["regionID"] = .integer(Int64(value)) }
        if let value = configuration.servedTCPPorts { input["servedTCPPorts"] = try value.jsonValue() }
        if let value = configuration.servedUDPPorts { input["servedUDPPorts"] = try value.jsonValue() }
        if let value = configuration.udpIdleTimeout { input["udpIdleTimeout"] = .integer(try nanoseconds(value)) }
        return try await retained("server.create", input) { (response: HandleResponse) in
            let server = Tailcat.Server(cache: configuration.cache, handle: response.handle, handlers: handlers, policy: policy, runtime: self)
            if let handler = server.handlerBridge { try register(handler, handle: response.handle) }
            try requireCore().setPolicy(response.handle, policy: server.policyBridge)
            try requireCore().setHandler(response.handle, handler: server.handlerBridge)
            return server
        }
    }

    public func discoKey(privateKey: String) async throws -> Tailcat.NodePublicKey {
        try await request("key.disco", ["privateKey": .string(privateKey)])
    }

    public func fetchDERPMap(cache: Tailcat.Cache? = nil, forServer: Bool = false, url: URL? = nil) async throws -> Tailcat.DERPMap {
        var input: Tailcat.Metadata = ["forServer": .bool(forServer)]
        if let cache { try checkOwner(cache); input["cache"] = .integer(cache.handle) }
        if let url { input["derpMapURL"] = .string(url.absoluteString) }
        return try await request("derp.fetch", input)
    }

    public func generateIdentity() async throws -> Tailcat.Identity { try await request("identity.generate") }

    public func importIdentity(_ identity: Tailcat.Identity) async throws -> Tailcat.Identity {
        try await request("identity.import", ["identity": identity.jsonValue()])
    }

    public func pickBestRegion(in map: Tailcat.DERPMap) async throws -> Int {
        let response: RegionIDResponse = try await request("derp.pick", ["map": map.jsonValue()])
        return response.region
    }

    public func presharedKey(data: Data? = nil, key: String? = nil) async throws -> Tailcat.PresharedKey {
        guard data == nil || key == nil else { throw Tailcat.Failure.invalidInput("provide data or text for a preshared key") }
        var input: Tailcat.Metadata = [:]
        if let data { input["data"] = try data.jsonValue() }
        if let key { input["key"] = .string(key) }
        return try await request("key.preshared", input)
    }

    public func publicKey(privateKey: String) async throws -> Tailcat.NodePublicKey {
        try await request("key.public", ["privateKey": .string(privateKey)])
    }

    public func rawAddressFields(_ address: Tailcat.Address) async throws -> Tailcat.JSONValue {
        try await requestValue("address.raw", ["address": .string(address.rawValue)])
    }

    public func resolve(_ address: Tailcat.Address, cache: Tailcat.Cache? = nil,
                        forServer: Bool = false, map: Tailcat.DERPMap? = nil, url: URL? = nil) async throws -> Tailcat.Address {
        var input: Tailcat.Metadata = ["address": .string(address.rawValue), "forServer": .bool(forServer)]
        if let cache { try checkOwner(cache); input["cache"] = .integer(cache.handle) }
        if let url { input["derpMapURL"] = .string(url.absoluteString) }
        if let map { input["map"] = try map.jsonValue() }
        let response: AddressResponse = try await request("address.resolve", input)
        return Tailcat.Address(rawValue: response.address)
    }

    public func validateSSHAuthorizedKeys(_ keys: [String]) async throws {
        try await requestVoid("ssh.validateKeys", ["keys": keys.jsonValue()])
    }


    func checkOwner(_ resource: any TailcatResource) throws {
        try resource.ownership.checkOpen()
        guard resource.ownership.belongs(to: ownership) else { throw Tailcat.Failure.ownershipConflict }
    }

    func setLogger(handle: Int64, logger: LoggerBridge?) throws { try ownership.checkOpen(); try requireCore().setLogger(handle, sink: logger) }

    private func register(_ handler: HandlerBridge, handle: Int64) throws { try live?.register(handler, handle: handle) }

    private func requireCore() throws -> MobileRuntime {
        guard let core else { throw Tailcat.Failure.unimplemented("Session.bridge") }
        return core
    }

    func closeResource(_ handle: Int64) async throws {
        let bridge = live?.removeHandler(handle)
        let pending = bridge?.cancelTasks() ?? []
        var failure: (any Error)?
        do { try await requestVoid("resource.close", ["handle": .integer(handle)]) }
        catch Tailcat.Failure.closed {}
        catch { failure = error }
        for handler in pending { await handler.value }
        if let failure { throw failure }
    }

    private func newOperation(allowClosing: Bool = false) throws -> MobileOperation {
        if !allowClosing { try ownership.checkOpen() }
        guard let operation = try requireCore().newOperation() else { throw Tailcat.Failure.closed }
        return operation
    }

    func abortResource(_ handle: Int64) { core?.abortResource(handle) }

    func release(_ handle: Int64) {
        let bridge = live?.removeHandler(handle)
        _ = bridge?.cancelTasks()
        guard let operation = try? newOperation(allowClosing: true) else { return }
        let input = "{\"handle\":\(handle)}"
        operation.begin("resource.close", input: input, completion: IgnoredCompletion())
    }

    func request<T: Decodable>(_ method: String, _ input: Tailcat.Metadata = [:],
                              onProgress: (@Sendable (Tailcat.JSONValue) -> Void)? = nil) async throws -> T {
        try await requestValue(method, input, onProgress: onProgress).decode()
    }

    func requestValue(_ method: String, _ input: Tailcat.Metadata = [:],
                      onProgress: (@Sendable (Tailcat.JSONValue) -> Void)? = nil) async throws -> Tailcat.JSONValue {
        try Task.checkCancellation()
        let operation = try newOperation(allowClosing: method == "resource.close")
        let operationBox = OperationBox(operation)
        if let onProgress { try operation.setProgress(ProgressBridge(onProgress)) }
        let encoded = try JSONEncoder().encode(input)
        guard let json = String(data: encoded, encoding: .utf8) else {
            throw Tailcat.Failure.invalidInput("input is not UTF-8")
        }
        let state = CompletionState()
        let callback = BridgeCompletion(state: state)
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                operationBox.operation.begin(method, input: json, completion: callback)
            }
        } onCancel: {
            operationBox.operation.cancel()
        }
        // Resource-returning methods still perform atomic ownership handoff after decoding.
        return try JSONDecoder().decode(Tailcat.JSONValue.self, from: data)
    }

    func requestVoid(_ method: String, _ input: Tailcat.Metadata = [:]) async throws {
        _ = try await requestValue(method, input)
    }
}
}

// Go Operation methods synchronize cancellation/completion with their own mutex.
private final class OperationBox: @unchecked Sendable {
    let operation: MobileOperation
    init(_ operation: MobileOperation) { self.operation = operation }
}

private final class BridgeCompletion: NSObject, MobileCompletionProtocol {
    let state: CompletionState
    init(state: CompletionState) { self.state = state }
    func complete(_ result: String?, code: Int, message: String?) {
        let error: (any Error)?
        switch code {
        case 0: error = nil
        case 1: error = Tailcat.Failure.invalidInput(message ?? "invalid input")
        case 2: error = CancellationError()
        case 3: error = Tailcat.Failure.closed
        case 4: error = Tailcat.Failure.unsupported(message ?? "unsupported capability")
        default: error = Tailcat.Failure.operationFailed(message ?? "upstream operation failed")
        }
        if let error { state.finish(.failure(error)) }
        else { state.finish(.success(Data((result ?? "{}").utf8))) }
    }
}

private final class IgnoredCompletion: NSObject, MobileCompletionProtocol {
    func complete(_ result: String?, code: Int, message: String?) {}
}

private final class ProgressBridge: NSObject, MobileProgressProtocol {
    private let dependencies = withEscapedDependencies { $0 }
    private let handler: @Sendable (Tailcat.JSONValue) -> Void
    init(_ handler: @escaping @Sendable (Tailcat.JSONValue) -> Void) { self.handler = handler }
    func update(_ result: String?) {
        guard let result, let value = try? JSONDecoder().decode(Tailcat.JSONValue.self, from: Data(result.utf8)) else { return }
        dependencies.yield { handler(value) }
    }
}

struct AddressResponse: Decodable { let address: String }
struct HandleResponse: Decodable { let handle: Int64 }
struct RegionIDResponse: Decodable { let region: Int }

/// The lock guards callback registration/removal; callbacks and joins stay outside it.
private final class LiveSession: @unchecked Sendable {
    private var closed = false
    private let core: MobileRuntime
    private var handlers: [Int64: HandlerBridge] = [:]
    private let lock = NSLock()
    private var pending: [Task<Void, Never>] = []
    init(core: MobileRuntime) { self.core = core }
    func register(_ handler: HandlerBridge, handle: Int64) throws {
        try lock.withLock {
            guard !closed else { throw Tailcat.Failure.closed }
            handlers[handle] = handler
        }
    }
    func removeHandler(_ handle: Int64) -> HandlerBridge? { lock.withLock { handlers.removeValue(forKey: handle) } }
    func abort() {
        let handlers = lock.withLock {
            closed = true
            let snapshot = Array(self.handlers.values)
            self.handlers.removeAll()
            return snapshot
        }
        let pending = handlers.flatMap { $0.cancelTasks() }
        lock.withLock { self.pending.append(contentsOf: pending) }
        core.requestShutdown()
    }
    func close() async throws {
        let result = Result { try core.close() }
        let tasks = lock.withLock { pending }
        for task in tasks { await task.value }
        try result.get()
    }
}
