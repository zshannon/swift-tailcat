import Darwin
import Foundation

/// An opt-in host-owned directory containing official Tailcat identity JSON.
/// This store never discovers or changes another application's default key directory.
extension Tailcat.Identity {
public actor FileStore {
    public let directory: URL

    public init(directory: URL) throws {
        guard directory.isFileURL else { throw Tailcat.Failure.invalidInput("identity store requires a file URL") }
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    public func identity(named name: String) throws -> Tailcat.Identity {
        let url = try file(named: name)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw Tailcat.Failure.invalidInput("identity file is too large") }
        return try JSONDecoder().decode(Tailcat.Identity.self, from: data)
    }

    public func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    public func remove(named name: String) throws { try FileManager.default.removeItem(at: file(named: name)) }

    public func save(_ identity: Tailcat.Identity, named name: String) throws {
        let destination = try file(named: name)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else { throw posixFailure() }
        defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        let data = try JSONEncoder().encode(identity)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw posixFailure() }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0, Darwin.rename(temporary.path, destination.path) == 0 else { throw posixFailure() }
    }

    private func file(named name: String) throws -> URL {
        guard !name.isEmpty, name.utf8.count <= 128,
              name.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }) else {
            throw Tailcat.Failure.invalidInput("identity names contain only letters, numbers, underscores and hyphens")
        }
        return directory.appendingPathComponent(name + ".json")
    }
}
}

private func posixFailure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
