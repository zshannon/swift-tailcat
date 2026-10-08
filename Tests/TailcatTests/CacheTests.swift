import Darwin
import Foundation
@testable import Tailcat
import Testing

// Wrong escaping, missing ETag removal, or replacing file mtime with read time
// would each break these real temporary-directory checks.
@Test func diskCachePreservesCLIFormatTimestampAndPrivatePermissions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = try FileDERPMapCacheStorage(directory: directory)
    let url = try #require(URL(string: "https://owned.invalid/map?q=a+b&utf=%C3%A9"))
    let base = "derpmap-https%3A%2F%2Fowned.invalid%2Fmap%3Fq%3Da%2Bb%26utf%3D%25C3%25A9"
    let json = directory.appendingPathComponent(base + ".json")
    let etag = directory.appendingPathComponent(base + ".etag")
    let stamp = Date(timeIntervalSince1970: 1_234_567)
    try storage.put(data: Data("map".utf8), etag: "  opaque\n", storedAt: stamp, url: url)
    #expect(try Data(contentsOf: json) == Data("map".utf8))
    #expect(try String(contentsOf: etag, encoding: .utf8) == "  opaque\n")
    let entry = try #require(storage.get(url: url))
    #expect(entry.data == Data("map".utf8) && entry.etag == "opaque" && entry.ok)
    #expect(abs(entry.storageDate.timeIntervalSince(stamp)) < 0.001)
    for path in [json, etag] {
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    try FileManager.default.removeItem(at: etag)
    #expect(storage.get(url: url)?.etag == "")
    try storage.put(data: Data("map".utf8), etag: "new", storedAt: stamp, url: url)
    let refreshed = stamp.addingTimeInterval(30)
    try storage.put(data: Data("map".utf8), etag: "", storedAt: refreshed, url: url)
    #expect(!FileManager.default.fileExists(atPath: etag.path))
    #expect(abs(try #require(storage.get(url: url)).storageDate.timeIntervalSince(refreshed)) < 0.001)
    try FileManager.default.removeItem(at: json)
    #expect(storage.get(url: url) == nil)
}

@Test func diskCacheRejectsNonFileDirectoryAndPropagatesWriteFailure() throws {
    #expect(throws: TailcatError.self) { try FileDERPMapCacheStorage(directory: #require(URL(string: "https://owned.invalid"))) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = try FileDERPMapCacheStorage(directory: directory)
    try FileManager.default.removeItem(at: directory)
    try Data("block".utf8).write(to: directory)
    #expect(throws: (any Error).self) { try storage.put(data: Data(), etag: "", storedAt: .now, url: #require(URL(string: "https://owned.invalid"))) }
}

@Test func injectedCacheRoundTripAndWriteErrors() async throws {
    let storage = RecordingCacheStorage()
    let runtime = try TailcatRuntime()
    let cache = try await runtime.createCache(storage: storage)
    let url = try #require(URL(string: "https://owned.invalid/map"))
    let stamp = Date(timeIntervalSince1970: 123.25)
    try await cache.store(data: Data([0, 1, 2, 255]), etag: "opaque", storedAt: stamp, url: url)
    let entry = try await cache.entry(for: url)
    #expect(entry.data == Data([0, 1, 2, 255]) && entry.etag == "opaque")
    #expect(entry.storageDate == stamp && entry.ok)
    storage.failWrites = true
    await #expect(throws: TailcatError.self) { try await cache.store(data: Data(), etag: "", url: url) }
    try await cache.close()
    await #expect(throws: TailcatError.closed) { try await cache.entry(for: url) }
    try await runtime.close()
}

@Test func injectedCacheFetchUsesFresh304StaleAndIgnoresWriteErrors() async throws {
    let fixture = try CacheHTTPFixture()
    defer { fixture.close() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = try FileDERPMapCacheStorage(directory: directory)
    let runtime = try TailcatRuntime()
    let cache = try await runtime.createCache(storage: storage)
    #expect(try await runtime.fetchDERPMap(cache: cache, url: fixture.url).regions.first?.id == 1)
    _ = try await runtime.fetchDERPMap(cache: cache, url: fixture.url)
    #expect(fixture.count == 1)
    func stale() throws { try storage.put(data: CacheHTTPFixture.body, etag: "opaque", storedAt: .now.addingTimeInterval(-7_200), url: fixture.url) }
    try stale()
    fixture.mode = 304
    _ = try await runtime.fetchDERPMap(cache: cache, forServer: true, url: fixture.url)
    #expect(fixture.lastRequest.contains("If-None-Match: opaque"))
    #expect(fixture.lastRequest.contains("Tailcat-Mode: server"))
    #expect(try #require(storage.get(url: fixture.url)).storageDate > .now.addingTimeInterval(-60))
    try stale()
    fixture.mode = 503
    #expect(try await runtime.fetchDERPMap(cache: cache, url: fixture.url).regions.first?.id == 1)
    let failing = RecordingCacheStorage()
    failing.failWrites = true
    let failedCache = try await runtime.createCache(storage: failing)
    fixture.mode = 200
    #expect(try await runtime.fetchDERPMap(cache: failedCache, url: fixture.url).regions.first?.id == 1)
    try await runtime.close()
}

@Test func cacheCloseAndRuntimeCloseJoinAdmittedStorageCallbacks() async throws {
    for closeRuntime in [false, true] {
        let runtime = try TailcatRuntime()
        let storage = BlockingCacheStorage()
        let cache = try await runtime.createCache(storage: storage)
        let read = Task { try await cache.entry(for: #require(URL(string: "https://owned.invalid/map"))) }
        for _ in 0..<200 where !storage.entered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(storage.entered)
        let completion = EventCounter()
        let close = Task {
            if closeRuntime { try await runtime.close() } else { try await cache.close() }
            completion.increment()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(completion.count == 0)
        storage.release.signal()
        try await close.value
        _ = try? await read.value
        #expect(completion.count == 1)
        try await runtime.close()
    }
}

extension LoopbackTests {
    @Test func clientAndServerRetainConfiguredCache() async throws {
        let relay = try OwnedRelay()
        let runtime = try TailcatRuntime()
        var cache: DERPMapCache? = try await runtime.createCache(storage: RecordingCacheStorage())
        weak var observed = cache
        let server = try await runtime.createServer(configuration: .init(cache: cache, region: relay.map.regions.first))
        let client = try await runtime.createClient(configuration: .init(address: server.address(), cache: cache))
        cache = nil
        #expect(observed != nil)
        try await observed?.store(data: Data("retained".utf8), etag: "", url: #require(URL(string: "https://owned.invalid/map")))
        try await server.close()
        #expect(observed != nil)
        try await client.close()
        try await runtime.close()
    }

    @Test func genericUDP6AndExplicitResolveMapOptions() async throws {
        let context = try await LoopbackContext.create()
        let listener = try await context.server.listen(address: ":0", family: .ipv6, transport: .udp)
        let port = try #require(Int(listener.address.split(separator: ":").last ?? ""))
        let accepted = Task { try await listener.acceptDatagram() }
        let ip = try await context.server.tunnelIP().rawValue
        let remote = try await context.client.dialUDP(address: "[\(ip)]:\(port)", family: .ipv6)
        try await remote.send(Data("UDP6".utf8))
        let local = try await accepted.value
        try await local.setDeadlines(read: .now.addingTimeInterval(5))
        #expect(try await local.receive().data == Data("UDP6".utf8))
        var identity = try await context.runtime.generateIdentity()
        identity.connectionInfo.regionID = 1
        let address = try await context.runtime.address(from: identity.connectionInfo)
        let expanded = try await context.runtime.resolve(address, map: context.relay.map, url: #require(URL(string: "http://127.0.0.1:1/unreachable")))
        #expect(try await context.runtime.connectionInfo(for: expanded).regions?.first?.id == 1)
        try await context.runtime.close()
    }
}

private final class RecordingCacheStorage: DERPMapCacheStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [URL: DERPMapCacheEntry] = [:]
    private var failed = false
    var failWrites: Bool { get { lock.withLock { failed } } set { lock.withLock { failed = newValue } } }
    func get(url: URL) -> DERPMapCacheEntry? { lock.withLock { entries[url] } }
    func put(data: Data, etag: String, storedAt: Date, url: URL) throws {
        try lock.withLock {
            if failed { throw TailcatError.operationFailed("owned write failure") }
            entries[url] = try DERPMapCacheEntry(data: data, etag: etag, storedAt: storedAt)
        }
    }
}

private final class BlockingCacheStorage: DERPMapCacheStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    var entered: Bool { lock.withLock { started } }
    let release = DispatchSemaphore(value: 0)
    func get(url: URL) -> DERPMapCacheEntry? { lock.withLock { started = true }; release.wait(); return nil }
    func put(data: Data, etag: String, storedAt: Date, url: URL) throws {}
}

private final class CacheHTTPFixture: @unchecked Sendable {
    static let body = Data("{\"Regions\":{\"1\":{\"RegionID\":1,\"RegionCode\":\"owned\",\"Nodes\":[]}}}".utf8)
    private let descriptor: Int32
    private let lock = NSLock()
    private var closed = false
    private var request = ""
    private var requests = 0
    private var status = 200
    let url: URL
    var mode: Int { get { lock.withLock { status } } set { lock.withLock { status = newValue } } }
    var count: Int { lock.withLock { requests } }
    var lastRequest: String { lock.withLock { request } }
    init() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = sockaddr_in()
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(socket, 8) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            Darwin.close(socket)
            throw error
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        guard named == 0 else { Darwin.close(socket); throw TailcatError.operationFailed("owned HTTP fixture cannot discover its port") }
        descriptor = socket
        url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/map")!
        DispatchQueue.global().async { [weak self] in self?.serve() }
    }
    private func serve() {
        while !lock.withLock({ closed }) {
            let connection = Darwin.accept(descriptor, nil, nil)
            guard connection >= 0 else { return }
            respond(connection)
            Darwin.close(connection)
        }
    }
    private func respond(_ connection: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        withUnsafePointer(to: &timeout) { _ = setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
        var noSignal: Int32 = 1
        withUnsafePointer(to: &noSignal) { _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size)) }
        var accumulated = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !String(decoding: accumulated, as: UTF8.self).contains("\r\n\r\n") {
            let count = Darwin.recv(connection, &buffer, buffer.count, 0)
            guard count > 0, accumulated.count < 65_536 else { return }
            accumulated.append(contentsOf: buffer.prefix(count))
        }
        let status = lock.withLock { requests += 1; request = String(decoding: accumulated, as: UTF8.self); return self.status }
        let body = status == 200 ? Self.body : Data()
        var response = Data("HTTP/1.1 \(status) Owned\r\nContent-Length: \(body.count)\r\nETag: opaque\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        response.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.send(connection, base.advanced(by: offset), bytes.count - offset, 0)
                guard sent > 0 else { return }
                offset += sent
            }
        }
    }
    func close() {
        let first = lock.withLock { if closed { return false }; closed = true; return true }
        if first { Darwin.shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor) }
    }
}
