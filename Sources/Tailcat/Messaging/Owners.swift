import Dependencies
import Foundation

extension Tailcat {
    public final class Connection: Sendable {
        public struct Configuration: Sendable {
            public var client: Client.Configuration
            public var maxConcurrentRequests: Int
            public var messaging: Messaging.Configuration
            public init(client: Client.Configuration = .init(), maxConcurrentRequests: Int = 16, messaging: Messaging.Configuration = .init()) {
                self.client = client; self.maxConcurrentRequests = maxConcurrentRequests; self.messaging = messaging
            }
            func validate() throws {
                try client.validate(); try messaging.validate()
                guard (1...65535).contains(maxConcurrentRequests) else { throw MessageFailure.invalidConfiguration }
            }
        }
        public let address: Address
        public let port: Int
        public let statuses: AsyncStream<Messaging.Status>
        let capacity: MessageCapacity
        let client: Client
        let configuration: Configuration
        let ownership: Ownership
        init(address: Address, client: Client, configuration: Configuration, port: Int, session: Session) {
            self.address = address; self.client = client; self.configuration = configuration; self.port = port
            let capacity = MessageCapacity(limit: configuration.maxConcurrentRequests)
            self.capacity = capacity
            let (statuses, status) = AsyncStream<Messaging.Status>.makeStream(bufferingPolicy: .bufferingNewest(3))
            self.statuses = statuses
            status.yield(.ready)
            ownership = Ownership(abort: {
                status.yield(.closing)
                capacity.stop()
                session.requestShutdown()
            }, close: {
                await capacity.join()
                defer { status.yield(.closed); status.finish() }
                try await session.close()
            })
        }
        deinit { ownership.requestShutdown() }
        public func close() async throws { try await ownership.close() }
        public func discoPing() async throws -> Discovery.Result { try ownership.checkOpen(); return try await client.discoPing() }
        public func ping() async throws -> Duration { try ownership.checkOpen(); return try await client.ping() }
        public func requestShutdown() { ownership.requestShutdown() }
        func open<R>(_ bindings: RequestBindings<R>, input: R.Input) async throws -> RequestStream<R.Yield, R.Inbound, R.Output> {
            let route = MessageRoute(event: R.event, version: R.version)
            try route.validate()
            try ownership.checkOpen()
            try capacity.enter()
            var transferred = false
            defer { if !transferred { capacity.leave() } }
            // Input encoding occurs only after request admission and before dialing.
            let inputData = try bindings.input.encode(input)
            guard inputData.count <= configuration.messaging.maxEncodedMessageBytes else { throw MessageFailure.oversizedMessage }
            let raw = try await client.connectTCP(to: .tunnelPort(port))
            let flow = MessageFlow(configuration: configuration.messaging, onClose: { [capacity] in capacity.leave() }, raw: raw, route: route)
            transferred = true
            do {
                try ownership.attach(flow.ownership)
                try await flow.operation {
                    try Task.checkCancellation()
                    try await flow.state.begin(route: route, input: inputData)
                    flow.state.startReadingClient(absent: bindings.yield.absent) { [ownership = flow.ownership] in
                        ownership.requestShutdown()
                    }
                }
                return RequestStream(connection: self, incoming: Incoming(codec: bindings.yield, flow: flow),
                                     flow: flow, inboundCodec: bindings.inbound, outputCodec: bindings.output)
            } catch { await flow.close(); throw error }
        }
        func call<R>(_ bindings: RequestBindings<R>, input: R.Input) async throws -> R.Output {
            let stream = try await open(bindings, input: input)
            do {
                try await stream.finishSending()
                let output = try await stream.result()
                try await stream.flow.ownership.close()
                return output
            } catch { await stream.resetAndWait(); throw error }
        }
    }
    public final class Listener: Sendable {
        public struct Configuration: Sendable {
            /// Absolute I/O budget from acceptance, including framing and response writes.
            /// nil leaves I/O unbounded; this does not time out application handler execution.
            public var ioTimeout: Duration?
            public var maxConnections: Int
            public var messaging: Messaging.Configuration
            public var server: Server.Configuration
            public init(ioTimeout: Duration? = nil, maxConnections: Int = 16, messaging: Messaging.Configuration = .init(), server: Server.Configuration = .init(allowedProxies: [])) {
                self.ioTimeout = ioTimeout; self.maxConnections = maxConnections; self.messaging = messaging; self.server = server
            }
            func validate() throws {
                try messaging.validate(); try server.validate()
                guard (1...65535).contains(maxConnections) else { throw MessageFailure.invalidConfiguration }
                if let ioTimeout {
                    let nanos = try nanoseconds(ioTimeout)
                    guard nanos > 0 else { throw MessageFailure.invalidConfiguration }
                    _ = try unixNanoseconds(Date.now.addingTimeInterval(Double(nanos) / 1_000_000_000))
                }
            }
        }
        public let address: Address
        public let port: Int
        public let statuses: AsyncStream<Messaging.Status>
        private let ownership: Ownership
        private let taskID: UUID
        private let server: Server
        init(address: Address, configuration: Configuration, handlers: [MessageRoute: Handler], raw: TCPListener, server: Server, session: Session) {
            self.address = address; port = raw.boundEndpoint.port
            self.server = server
            let taskID = UUID()
            self.taskID = taskID
            let acceptTask = MessageTasks(), handlerTasks = MessageTasks()
            let (statuses, status) = AsyncStream<Messaging.Status>.makeStream(bufferingPolicy: .bufferingNewest(3))
            self.statuses = statuses
            status.yield(.ready)
            ownership = Ownership(abort: {
                status.yield(.closing)
                session.requestShutdown()
                acceptTask.stop(); handlerTasks.stop()
            }, close: {
                await acceptTask.join(); await handlerTasks.join()
                defer { status.yield(.closed); status.finish() }
                try await session.close()
            })
            acceptTask.start { [weak owner = ownership] in
                do {
                    while !Task.isCancelled {
                        let connection = try await raw.accept()
                        let deadline = configuration.ioTimeout.map {
                            Date.now.addingTimeInterval(Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18)
                        }
                        if !handlerTasks.start(limit: configuration.maxConnections, {
                            await MessageTaskScope.$owners.withValue(MessageTaskScope.owners.union([taskID])) {
                                await serveMessage(configuration: configuration.messaging, deadline: deadline, handlers: handlers, raw: connection)
                            }
                        }) { try? await connection.close() }
                    }
                } catch { owner?.requestShutdown() }
            }
        }
        deinit { ownership.requestShutdown() }
        public func close() async throws {
            guard !MessageTaskScope.owners.contains(taskID) else { throw Tailcat.Failure.ownershipConflict }
            try await ownership.close()
        }
        public func requestShutdown() { ownership.requestShutdown() }
    }
    public func connect(address: Address, configuration: Connection.Configuration = .init(), port: Int = 1) async throws -> Connection {
        try configuration.validate(); try Ports.validate(port, as: .remote)
        let session = try await makeSession()
        return try await withTaskCancellationHandler {
            do {
                let client = try await session.makeClient(address: address, configuration: configuration.client)
                try Task.checkCancellation()
                return Connection(address: address, client: client, configuration: configuration, port: port, session: session)
            } catch { try? await session.close(); throw error }
        } onCancel: { session.requestShutdown() }
    }
    public func listen(configuration: Listener.Configuration = .init(), isolation: isolated (any Actor)? = #isolation,
                       port: Int = 1, @HandlerBuilder handlers: () -> [Handler]) async throws -> Listener {
        try configuration.validate(); try Ports.validate(port, as: .local)
        var registrations: [MessageRoute: Handler] = [:]
        for handler in handlers() {
            try handler.route.validate()
            guard registrations.updateValue(handler, forKey: handler.route) == nil else { throw MessageFailure.invalidRequest }
        }
        let snapshot = registrations
        let session = try await makeSession()
        return try await withTaskCancellationHandler {
            do {
                let server = try await session.makeServer(configuration: configuration.server)
                try await server.start()
                let raw = try await server.listenTCP(address: .init(service: .port(port)))
                let address = try await server.address()
                try Task.checkCancellation()
                return Listener(address: address, configuration: configuration, handlers: snapshot, raw: raw, server: server, session: session)
            } catch { try? await session.close(); throw error }
        } onCancel: { session.requestShutdown() }
    }
}

private func serveMessage(configuration: Tailcat.Messaging.Configuration, deadline: Date?, handlers: [MessageRoute: Tailcat.Handler], raw: Tailcat.TCPConnection) async {
    if let deadline {
        do { try await raw.setDeadlines(read: deadline, write: deadline) }
        catch { try? await raw.close(); return }
    }
    let reader = MessageReader(raw: raw, limit: configuration.maxEncodedMessageBytes)
    var flow: MessageFlow?
    await withTaskCancellationHandler {
        do {
            guard let open = try await reader.read(), open.kind == .open else { throw MessageFailure.malformedFrame }
            let route = try JSONDecoder().decode(MessageRoute.self, from: open.payload)
            try route.validate()
            guard let input = try await reader.read(), input.kind == .input else { throw MessageFailure.malformedFrame }
            let request = MessageFlow(configuration: configuration, raw: raw, route: route)
            flow = request
            guard let handler = handlers[route] else { throw MessageFailure.invalidRequest }
            try await handler.invoke(input.payload, request)
        } catch {
            // A finite vocabulary avoids exposing arbitrary application error strings.
            let error = MessageRemoteError(code: "request_failed", message: "Request could not be completed")
            if let payload = try? JSONEncoder().encode(error) {
                if let flow { try? await flow.state.terminal(MessageFrame(kind: .error, payload: payload)) }
                else {
                    try? await raw.write(MessageFrame(kind: .error, payload: payload).encoded(limit: configuration.maxEncodedMessageBytes))
                    try? await raw.write(MessageFrame(kind: .end).encoded(limit: configuration.maxEncodedMessageBytes))
                    try? await raw.closeWrite()
                }
            }
        }
        if let flow { await flow.close() }
        else { try? await raw.close() }
    } onCancel: { raw.requestShutdown() }
}

final class MessageCapacity: @unchecked Sendable {
    private var closed = false
    private var count = 0
    private let limit: Int
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { self.limit = limit }
    func enter() throws { try lock.withLock {
        if closed { throw MessageFailure.closed }
        guard count < limit else { throw MessageFailure.capacity }
        count += 1
    } }
    func leave() {
        let done = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            count -= 1
            guard count == 0 else { return [] }
            let done = waiters; waiters.removeAll(); return done
        }
        done.forEach { $0.resume() }
    }
    func stop() { lock.withLock { closed = true } }
    func join() async { await withCheckedContinuation { continuation in
        let ready = lock.withLock { if count == 0 { return true }; waiters.append(continuation); return false }
        if ready { continuation.resume() }
    } }
}

private enum MessageTaskScope {
    @TaskLocal static var owners: Set<UUID> = []
}
