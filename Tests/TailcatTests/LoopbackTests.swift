import Foundation
@testable import Tailcat
import Testing

private let hasFixture = ProcessInfo.processInfo.environment["TAILCAT_FIXTURE_BIN"] != nil

final class OwnedRelay: @unchecked Sendable {
    private let exited = DispatchSemaphore(value: 0)
    let map: DERPMap
    private let process: Process
    init() throws {
        let binary = try #require(ProcessInfo.processInfo.environment["TAILCAT_FIXTURE_BIN"])
        process = Process()
        let exited = self.exited
        process.terminationHandler = { _ in exited.signal() }
        process.executableURL = URL(fileURLWithPath: binary)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }
            line.append(byte)
            if line.count > 1_048_576 { throw TailcatError.operationFailed("fixture map exceeds its limit") }
        }
        do { map = try JSONDecoder().decode(DERPMap.self, from: line) }
        catch { process.terminate(); _ = exited.wait(timeout: .now() + 5); throw error }
    }
    deinit {
        if process.isRunning { process.terminate() }
        // Foundation's run-loop wait can strand a cooperative executor during teardown.
        precondition(exited.wait(timeout: .now() + 5) == .success, "Owned relay did not terminate")
    }
}

struct LoopbackContext: Sendable {
    let client: TailcatClient
    let relay: OwnedRelay
    let runtime: TailcatRuntime
    let server: TailcatServer
    static func create(handlers: ServerHandlers? = nil) async throws -> LoopbackContext {
        let relay = try OwnedRelay()
        let runtime = try TailcatRuntime()
        let region = try #require(relay.map.regions.first)
        let server = try await runtime.createServer(configuration: .init(region: region), handlers: handlers)
        try await server.start()
        let client = try await runtime.createClient(configuration: .init(address: server.address()))
        _ = try await client.ping()
        return LoopbackContext(client: client, relay: relay, runtime: runtime, server: server)
    }
}

@Suite(.enabled(if: hasFixture), .serialized, .timeLimit(.minutes(1)))
struct LoopbackTests {
    @Test func childRetainsSSHParent() async throws {
        let context = try await LoopbackContext.create()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try await context.server.serveSSH(configuration: .init(authentication: .none,
            files: .init(directory: directory, mode: .readWrite)), port: 2222)
        func openFiles() async throws -> TailcatSFTPClient {
            try await context.client.openSSH(configuration: .init(hostKey: #require(service.hostKey), port: 2222,
                user: "owned-test")).openSFTP()
        }
        let files = try await openFiles()
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await files.write(data: Data("parent".utf8), path: "hello") == 6)
        #expect(try await files.read(path: "hello") == Data("parent".utf8))
        try await context.runtime.close()
    }
    @Test func handlerCancellationOnServerAndRuntimeClose() async throws {
        for closeRuntime in [false, true] {
            let events = HandlerEvents()
            let context = try await LoopbackContext.create(handlers: .init(tcp: { _ in
                events.markStarted()
                do { try await Task.sleep(for: .seconds(3_600)) }
                catch is CancellationError { events.markCancelled() }
                catch {}
            }))
            let connection = try await context.client.dialTCP(port: 8090)
            for _ in 0..<200 where !events.started { try await Task.sleep(for: .milliseconds(10)) }
            #expect(events.started)
            if closeRuntime { try await context.runtime.close() }
            else { try await context.server.close() }
            #expect(events.cancelled)
            try await connection.close()
            try await context.runtime.close()
        }
    }
    @Test func encryptedTCPHalfCloseAndPeerIdentity() async throws {
        let context = try await LoopbackContext.create()
        let listener = try await context.server.listen(address: ":0")
        let port = try #require(Int(listener.address.split(separator: ":").last ?? ""))
        let accepted = Task { try await listener.accept() }
        let remote = try await context.client.dialTCP(port: port)
        let local = try await accepted.value
        try await local.setDeadlines(read: .now.addingTimeInterval(10), write: .now.addingTimeInterval(10))
        try await remote.setDeadlines(read: .now.addingTimeInterval(10), write: .now.addingTimeInterval(10))
        #expect(try await context.server.peerKey(address: local.addresses.remote) == context.client.publicKey())
        #expect(try await context.server.peerEnvironment(local: local.addresses.local, remote: local.addresses.remote).contains {
            $0.hasPrefix("TAILCAT_PEER_KEY=")
        })
        try await remote.write(Data("request".utf8))
        try await remote.closeWrite()
        #expect(try await local.read() == Data("request".utf8))
        #expect(try await local.read() == nil)
        try await local.write(Data("reply".utf8))
        #expect(try await remote.read() == Data("reply".utf8))
        try await context.server.close()
        await #expect(throws: TailcatError.closed) { try await local.read() }
        try await context.runtime.close()
    }

    @Test func encryptedUDPDatagramAddresses() async throws {
        let context = try await LoopbackContext.create()
        let listener = try await context.server.listen(address: ":0", transport: .udp)
        let port = try #require(Int(listener.address.split(separator: ":").last ?? ""))
        let accepted = Task { try await listener.acceptDatagram() }
        let remote = try await context.client.dialUDP(port: port)
        try await remote.setDeadlines(read: .now.addingTimeInterval(10), write: .now.addingTimeInterval(10))
        try await remote.send(Data("one".utf8))
        let local = try await accepted.value
        try await local.setDeadlines(read: .now.addingTimeInterval(10), write: .now.addingTimeInterval(10))
        let first = try await local.receive()
        #expect(first.data == Data("one".utf8))
        try await local.send(first.data, to: first.address)
        #expect(try await remote.receive().data == first.data)
        try await remote.send(Data("second".utf8))
        #expect(try await local.receive().data == Data("second".utf8))
        try await remote.send(Data())
        let empty = try await local.receive()
        #expect(empty.data.isEmpty && empty.address != nil)
        try await local.send(empty.data, to: empty.address)
        #expect(try await remote.receive().data.isEmpty)
        try await context.runtime.close()
    }

    @Test func cancelReadPreservesConnectionAndRuntimeClosesPendingAccept() async throws {
        let context = try await LoopbackContext.create()
        let listener = try await context.server.listen(address: ":0")
        let port = try #require(Int(listener.address.split(separator: ":").last ?? ""))
        let accepted = Task { try await listener.accept() }
        let remote = try await context.client.dialTCP(port: port)
        let local = try await accepted.value
        let blocked = Task { try await remote.read() }
        try await Task.sleep(for: .milliseconds(30))
        blocked.cancel()
        await #expect(throws: CancellationError.self) { try await blocked.value }
        try await remote.setDeadlines(read: .now.addingTimeInterval(10))
        try await local.write(Data("next".utf8))
        #expect(try await remote.read() == Data("next".utf8))
        let pendingAccept = Task { try await listener.accept() }
        try await Task.sleep(for: .milliseconds(30))
        try await context.runtime.close()
        await #expect(throws: (any Error).self) { try await pendingAccept.value }
        try await local.close()
    }

    @Test func policyNilAndEmptyAndCacheIsolation() async throws {
        let runtime = try TailcatRuntime()
        let identity = try await runtime.generateIdentity()
        let key = identity.connectionInfo.publicKey
        let open = try await runtime.createServer()
        let denied = try await runtime.createServer(configuration: .init(allowedClients: []))
        #expect(try await open.contains(clientKey: key))
        #expect(try await !denied.contains(clientKey: key))
        #expect(try await denied.admit(clientKey: key))
        try await denied.revoke(clientKey: key)
        #expect(try await !denied.contains(clientKey: key))
        let cache = try await runtime.createCache()
        let url = try #require(URL(string: "https://invalid.example/owned-map"))
        try await cache.store(data: Data("map".utf8), etag: "test", url: url)
        #expect(try await cache.entry(for: url).data == Data("map".utf8))
        let other = try TailcatRuntime()
        await #expect(throws: TailcatError.self) {
            try await other.createServer(configuration: .init(cache: cache))
        }
        try await runtime.close()
        try await other.close()
    }

    @Test func nativeSSHRootedFilesAndPerformance() async throws {
        let context = try await LoopbackContext.create()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try await context.server.serveSSH(configuration: .init(authentication: .none, files: .init(directory: directory, mode: .readWrite)), port: 2222)
        let hostKey = try #require(service.hostKey)
        let ssh = try await context.client.openSSH(configuration: .init(hostKey: hostKey, port: 2222, user: "owned-test"))
        let files = try await ssh.openSFTP()
        #expect(try await files.write(data: Data("Swift SFTP".utf8), path: "hello", truncate: true) == 10)
        #expect(try await files.read(path: "hello") == Data("Swift SFTP".utf8))
        #expect(try await files.list(path: ".").contains { $0.name == "hello" })
        await #expect(throws: (any Error).self) { try await files.read(path: "../outside") }
        let perf = try await context.server.servePerformance(maxDuration: .seconds(2), maxStreams: 2)
        let result = try await context.client.measurePerformance(allowOwnedRelay: true,
            parameters: .init(bytes: 16_384, direction: .bidirectional, transport: .tcp))
        #expect(result.clientSent?.bytes == 16_384)
        #expect(result.serverSent?.bytes == 16_384)
        try await perf.close()
        try await context.runtime.close()
    }
}

final class HandlerEvents: @unchecked Sendable {
    private var didCancel = false
    private var didStart = false
    private let lock = NSLock()
    var cancelled: Bool { lock.withLock { didCancel } }
    var started: Bool { lock.withLock { didStart } }
    func markCancelled() { lock.withLock { didCancel = true } }
    func markStarted() { lock.withLock { didStart = true } }
}
