import Foundation

extension Tailcat {
    public final class UDPListener: Sendable {
        private let acceptProvider: (@Sendable () async throws -> UDPConnection)?
        private let listener: TCPListener
        var ownership: Ownership { listener.ownership }
        public var address: String { listener.address }
        public var boundEndpoint: IPEndpoint { listener.boundEndpoint }

        public init(abort: @escaping @Sendable () -> Void,
                    accept: @escaping @Sendable () async throws -> UDPConnection = { throw Failure.unimplemented("UDPListener.accept") },
                    address: String = "[::]:1",
                    close: @escaping @Sendable () async throws -> Void) throws {
            acceptProvider = accept
            listener = try TCPListener(abort: abort, address: address, close: close)
        }
        init(listener: TCPListener) { self.listener = listener; acceptProvider = nil }

        public func accept() async throws -> UDPConnection {
            try ownership.checkOpen()
            if let acceptProvider {
                return try await acquire(onCancel: { self.requestShutdown() }, parent: ownership.transferOwner, ownership: { $0.ownership }, provider: acceptProvider)
            }
            return try await listener.acceptDatagram()
        }
        public func close() async throws { try await listener.close() }
        public var connections: Connections { Connections(listener: self) }
        public func requestShutdown() { listener.requestShutdown() }

        public struct Connections: AsyncSequence, Sendable {
            public typealias Element = UDPConnection
            let listener: UDPListener
            public func makeAsyncIterator() -> AsyncIterator { .init(listener: listener) }
            public struct AsyncIterator: AsyncIteratorProtocol {
                let listener: UDPListener
                public mutating func next() async throws -> UDPConnection? { try await listener.accept() }
            }
        }
    }

    public final class SSHService: TailcatResource, Sendable {
        public let address: String
        public let hostKey: String
        public let port: Int
        let storage: ResourceStorage
        init(address: String, handle: Int64, hostKey: String, parent: any TailcatResource, port: Int, runtime: Session) {
            self.address = address
            self.hostKey = hostKey
            self.port = port
            storage = ResourceStorage(handle: handle, parent: parent, runtime: runtime)
        }
        public init(abort: @escaping @Sendable () -> Void, address: String = "", close: @escaping @Sendable () async throws -> Void,
                    hostKey: String, port: Int = 22) throws {
            try Ports.validate(port, as: .local)
            self.address = address
            self.hostKey = hostKey
            self.port = port
            storage = ResourceStorage(abort: abort, close: close)
        }
        public func close() async throws { try await closeOwned() }
        public func requestShutdown() { ownership.requestShutdown() }
    }

    public final class SOCKSService: TailcatResource, Sendable {
        public let address: String
        let storage: ResourceStorage
        init(address: String, handle: Int64, parent: (any TailcatResource)?, runtime: Session) {
            self.address = address
            storage = ResourceStorage(handle: handle, parent: parent, runtime: runtime)
        }
        public init(abort: @escaping @Sendable () -> Void, address: String = "", close: @escaping @Sendable () async throws -> Void) {
            self.address = address
            storage = ResourceStorage(abort: abort, close: close)
        }
        public func close() async throws { try await closeOwned() }
        public func requestShutdown() { ownership.requestShutdown() }
    }

    public final class PerformanceService: TailcatResource, Sendable {
        public let address: String
        public let port: Int
        let storage: ResourceStorage
        init(address: String, handle: Int64, parent: any TailcatResource, port: Int, runtime: Session) {
            self.address = address
            self.port = port
            storage = ResourceStorage(handle: handle, parent: parent, runtime: runtime)
        }
        public init(abort: @escaping @Sendable () -> Void, address: String = "", close: @escaping @Sendable () async throws -> Void, port: Int = 5201) throws {
            try Ports.validate(port, as: .local)
            self.address = address
            self.port = port
            storage = ResourceStorage(abort: abort, close: close)
        }
        public func close() async throws { try await closeOwned() }
        public func requestShutdown() { ownership.requestShutdown() }
    }
}
