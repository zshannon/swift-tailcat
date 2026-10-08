import Darwin
import Foundation

/// Synchronous DERP map storage. Implementations must support concurrent calls.
/// Callbacks must return promptly and must not synchronously wait for closure
/// of their own cache or runtime, since closure joins admitted callbacks.
extension Tailcat.Cache {
public protocol Storage: Sendable {
    func get(url: URL) -> Tailcat.Cache.Entry?
    func put(data: Data, etag: String, storedAt: Date, url: URL) throws
}
}

/// The CLI's paired URL-escaped JSON/ETag format in a host-selected directory.
/// Each JSON file's modification time supplies its freshness timestamp.
extension Tailcat.Cache {
public final class FileStorage: Tailcat.Cache.Storage, @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) throws {
        guard directory.isFileURL else { throw Tailcat.Failure.invalidInput("cache directory must be a file URL") }
        self.directory = directory
        try prepareDirectory()
    }

    public func get(url: URL) -> Tailcat.Cache.Entry? {
        lock.withLock {
            let (dataURL, etagURL) = paths(url)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: dataURL.path),
                  let stamp = attributes[.modificationDate] as? Date,
                  let data = try? Data(contentsOf: dataURL) else { return nil }
            let etagData = (try? Data(contentsOf: etagURL)) ?? Data()
            let etag = String(decoding: etagData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return try? Tailcat.Cache.Entry(data: data, etag: etag, storedAt: stamp)
        }
    }

    public func put(data: Data, etag: String, storedAt: Date, url: URL) throws {
        try lock.withLock {
            _ = try unixNanoseconds(storedAt)
            try prepareDirectory()
            let (dataURL, etagURL) = paths(url)
            try replace(data, at: dataURL, storedAt: storedAt)
            if etag.isEmpty {
                do { try FileManager.default.removeItem(at: etagURL) }
                catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {}
            } else {
                try replace(Data(etag.utf8), at: etagURL, storedAt: storedAt)
            }
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func paths(_ url: URL) -> (URL, URL) {
        // Go net/url.QueryEscape: RFC 3986 unreserved ASCII, '+' for spaces,
        // uppercase percent escapes for all other UTF-8 bytes.
        let escaped = url.absoluteString.utf8.map { byte -> String in
            switch byte {
            case 65...90, 97...122, 48...57, 45, 95, 46, 126: return String(UnicodeScalar(byte))
            case 32: return "+"
            default: return String(format: "%%%02X", byte)
            }
        }.joined()
        let base = "derpmap-" + escaped
        return (directory.appendingPathComponent(base + ".json"), directory.appendingPathComponent(base + ".etag"))
    }

    private func replace(_ data: Data, at destination: URL, storedAt: Date) throws {
        let temporary = directory.appendingPathComponent(".derpmap-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close(); try? FileManager.default.removeItem(at: temporary) }
        try file.write(contentsOf: data)
        try file.close()
        try FileManager.default.setAttributes([.modificationDate: storedAt], ofItemAtPath: temporary.path)
        guard rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
}
