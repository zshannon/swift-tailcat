import Foundation

extension Tailcat.RemoteFile {
public struct OpenOptions: Codable, Sendable {
    public var create: Bool
    public var truncate: Bool
    public var write: Bool
    public init(create: Bool = false, truncate: Bool = false, write: Bool = false) {
        self.create = create
        self.truncate = truncate
        self.write = write
    }
}
}

extension Tailcat.SFTP {
    /// One persistent remote file handle is essential for multi-chunk drop-box uploads.
    public func openFile(options: Tailcat.RemoteFile.OpenOptions = .init(), path: String) async throws -> Tailcat.RemoteFile {
        return try await acquireLive("sftp.open", ["create": .bool(options.create),
                                                                    "path": .string(path), "truncate": .bool(options.truncate),
                                                                    "write": .bool(options.write)]) { (response: HandleResponse) in
            return Tailcat.RemoteFile(handle: response.handle, parent: self, runtime: runtime)
        }
    }
}

extension Tailcat {
public final class RemoteFile: TailcatResource, @unchecked Sendable {
    public init(abort: @escaping @Sendable () -> Void, close: @escaping @Sendable () async throws -> Void) {
        storage = ResourceStorage(abort: abort, close: close)
    }

    init(handle: Int64, parent: (any TailcatResource)? = nil, runtime: Tailcat.Session) {
        storage = ResourceStorage(handle: handle, parent: parent, runtime: runtime)
    }

    let storage: ResourceStorage
    public func close() async throws { try await closeOwned() }
    public func requestShutdown() { ownership.requestShutdown() }

    /// Cancelling a file operation closes its owning SSH transport and its SFTP/session resources.
    public func read(maxBytes: Int = 65_536, offset: Int64 = 0) async throws -> Data? {
        let result: ReadResponse = try await request("sftp.file.read", ["count": .integer(Int64(maxBytes)), "offset": .integer(offset)])
        return result.eof && result.data.isEmpty ? nil : result.data
    }
    public func stat() async throws -> Tailcat.RemoteFile.Info { try await request("sftp.file.stat") }
    @discardableResult public func write(_ data: Data, offset: Int64 = 0) async throws -> Int {
        let result: CountResponse = try await request("sftp.file.write", ["data": data.jsonValue(), "offset": .integer(offset)])
        return result.count
    }
}
}
