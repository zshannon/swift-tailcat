import Dependencies
import Foundation
@preconcurrency import TailcatCore

extension Tailcat.Server {
public struct Offer: Sendable {
    public let destination: String
    public let forwarded: Bool
    public let transport: Tailcat.Transport
}
}

/// Selection returns promptly. Async handlers own a connection until they return.
extension Tailcat.Server {
public struct Handlers: Sendable {
    public typealias DatagramHandler = @Sendable (Tailcat.UDPConnection) async -> Void
    public typealias StreamHandler = @Sendable (Tailcat.TCPConnection) async -> Void
    public var select: @Sendable (Tailcat.Server.Offer) -> Bool
    public var tcp: StreamHandler?
    public var tcpForward: StreamHandler?
    public var udp: DatagramHandler?
    public var udpForward: DatagramHandler?
    public init(select: @escaping @Sendable (Tailcat.Server.Offer) -> Bool = { _ in true },
                tcp: StreamHandler? = nil, tcpForward: StreamHandler? = nil,
                udp: DatagramHandler? = nil, udpForward: DatagramHandler? = nil) {
        self.select = select
        self.tcp = tcp
        self.tcpForward = tcpForward
        self.udp = udp
        self.udpForward = udpForward
    }
}
}

final class HandlerBridge: NSObject, MobileHandlerProtocol, @unchecked Sendable {
    private let dependencies = withEscapedDependencies { $0 }
    private var closed = false
    private let handlers: Tailcat.Server.Handlers
    private let lock = NSLock()
    private weak var runtime: Tailcat.Session?
    weak var server: Tailcat.Server?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    init(handlers: Tailcat.Server.Handlers, runtime: Tailcat.Session) {
        self.handlers = handlers
        self.runtime = runtime
    }
    func select(_ network: String?, destination: String?, forwarded: Bool) -> Bool {
        guard let network, let transport = Tailcat.Transport(rawValue: network) else { return false }
        let available: Bool
        switch transport {
        case .tcp: available = (forwarded ? handlers.tcpForward : handlers.tcp) != nil
        case .udp: available = (forwarded ? handlers.udpForward : handlers.udp) != nil
        }
        return available && dependencies.yield { handlers.select(Tailcat.Server.Offer(destination: destination ?? "", forwarded: forwarded, transport: transport)) }
    }
    func connection(_ handle: Int64, network: String?, local: String?, remote: String?, forwarded: Bool) -> Bool {
        guard let runtime, let server, let network, let transport = Tailcat.Transport(rawValue: network) else { return false }
        let connection = Tailcat.TCPConnection(addresses: .init(local: local ?? "", remote: remote ?? ""), handle: handle, parent: server, runtime: runtime)
        do { try server.ownership.attach(connection.ownership) } catch { connection.requestShutdown(); return false }
        switch transport {
        case .tcp:
            guard let handler = forwarded ? handlers.tcpForward : handlers.tcp else { return false }
            return start(server: server) { await handler(connection); try? await connection.close() }
        case .udp:
            guard let handler = forwarded ? handlers.udpForward : handlers.udp else { return false }
            let datagram = Tailcat.UDPConnection(connection: connection)
            return start(server: server) { await handler(datagram); try? await datagram.close() }
        }
    }

    func cancelTasks() -> [Task<Void, Never>] {
        let pending = lock.withLock {
            closed = true
            return Array(tasks.values)
        }
        for task in pending { task.cancel() }
        return pending
    }

    private func start(server: Tailcat.Server, _ work: @escaping @Sendable () async -> Void) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            let id = UUID()
            let dependencies = dependencies
            tasks[id] = Task.detached { [weak self] in
                await dependencies.yield { await HandlerScope.$server.withValue(server) { await work() } }
                self?.finished(id)
            }
            return true
        }
    }

    private func finished(_ id: UUID) {
        _ = lock.withLock { tasks.removeValue(forKey: id) }
    }
}

enum HandlerScope { @TaskLocal static var server: Tailcat.Server? }

extension Tailcat {
public struct LogMessage: Sendable { public let message: String }
}

final class LoggerBridge: NSObject, MobileLoggerProtocol {
    private let dependencies = withEscapedDependencies { $0 }
    private let handler: @Sendable (Tailcat.LogMessage) -> Void
    init(handler: @escaping @Sendable (Tailcat.LogMessage) -> Void) { self.handler = handler }
    func log(_ handle: Int64, message: String?) { dependencies.yield { handler(.init(message: message ?? "")) } }
}

extension Tailcat.Client {
    public func setLogHandler(_ handler: (@Sendable (Tailcat.LogMessage) -> Void)?) throws {
        try ownership.checkOpen()
        guard let runtime = storage.runtime else { throw Tailcat.Failure.unimplemented("setLogHandler") }
        try runtime.setLogger(handle: handle, logger: handler.map { LoggerBridge(handler: $0) })
    }
}

extension Tailcat.Server {
    public func setLogHandler(_ handler: (@Sendable (Tailcat.LogMessage) -> Void)?) throws {
        try ownership.checkOpen()
        guard let runtime = storage.runtime else { throw Tailcat.Failure.unimplemented("setLogHandler") }
        try runtime.setLogger(handle: handle, logger: handler.map { LoggerBridge(handler: $0) })
    }
}
