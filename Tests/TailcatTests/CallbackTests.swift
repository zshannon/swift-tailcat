import Foundation
@testable import Tailcat
import Testing

extension LoopbackTests {
    @Test func childCloseJoinsParentAndRuntimeCleanup() async throws {
        for closeRuntime in [false, true] {
            let phases = EventCounter()
            let context = try await LoopbackContext.create(handlers: .init(tcp: { _ in
                phases.increment()
                do { try await Task.sleep(for: .seconds(3_600)) }
                catch {
                    phases.increment()
                    try? await Task.detached { try await Task.sleep(for: .milliseconds(100)) }.value
                    phases.increment()
                }
            }))
            let callback = try await context.client.dialTCP(port: 8090)
            for _ in 0..<200 where phases.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
            let listener = try await context.server.listen(address: ":0")
            let accepted = Task { try await listener.accept() }
            let remote = try await context.client.dialTCP(port: #require(Int(listener.address.split(separator: ":").last ?? "")))
            let child = try await accepted.value
            let closing = Task {
                if closeRuntime { try await context.runtime.close() }
                else { try await context.server.close() }
            }
            for _ in 0..<200 where phases.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
            try await child.close()
            #expect(phases.count == 3)
            try await closing.value
            try await callback.close()
            try await remote.close()
            try await context.runtime.close()
        }
    }

    @Test func concurrentServerClosesAwaitHandlerCleanup() async throws {
        let phases = EventCounter()
        let context = try await LoopbackContext.create(handlers: .init(tcp: { _ in
            phases.increment()
            do { try await Task.sleep(for: .seconds(3_600)) }
            catch {
                phases.increment()
                try? await Task.detached { try await Task.sleep(for: .milliseconds(100)) }.value
                phases.increment()
            }
        }))
        let connection = try await context.client.dialTCP(port: 8090)
        for _ in 0..<200 where phases.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let first = Task { try await context.server.close() }
        for _ in 0..<200 where phases.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        try await context.server.close()
        #expect(phases.count == 3)
        try await first.value
        try await connection.close()
        try await context.runtime.close()
    }

    @Test func handlerConnectionRetainsServer() async throws {
        let events = HandlerEvents()
        let relay = try OwnedRelay()
        let runtime = try TailcatRuntime()
        var server: TailcatServer? = try await runtime.createServer(configuration: .init(region: relay.map.regions.first),
            handlers: .init(tcp: { connection in
                events.markStarted()
                do { _ = try await connection.read() } catch {}
            }))
        weak var observed = server
        let address = try await #require(server).address()
        let client = try await runtime.createClient(configuration: .init(address: address))
        let connection = try await client.dialTCP(port: 8090)
        for _ in 0..<200 where !events.started { try await Task.sleep(for: .milliseconds(10)) }
        server = nil
        #expect(observed != nil)
        try await observed?.close()
        observed = nil
        try await connection.close()
        try await runtime.close()
    }

    @Test func callbacksLogsAndLivePerformance() async throws {
        let logs = EventCounter()
        let relay = try OwnedRelay()
        let runtime = try TailcatRuntime()
        let handlers = ServerHandlers(select: { $0.destination == ":8090" }, tcp: { connection in
            do { if let data = try await connection.read() { try await connection.write(data) } } catch {}
        }, udp: { connection in
            do { let packet = try await connection.receive(); try await connection.send(packet.data, to: packet.address) } catch {}
        })
        let region = try #require(relay.map.regions.first)
        let server = try await runtime.createServer(configuration: .init(region: region), handlers: handlers)
        try server.setLogHandler { _ in logs.increment() }
        try await server.start()
        let client = try await runtime.createClient(configuration: .init(address: server.address()))
        _ = try await client.ping()
        let stream = try await client.dialTCP(port: 8090)
        try await stream.setDeadlines(read: .now.addingTimeInterval(5))
        try await stream.write(Data("callback".utf8))
        #expect(try await stream.read() == Data("callback".utf8))
        let datagram = try await client.dialUDP(port: 8090)
        try await datagram.setDeadlines(read: .now.addingTimeInterval(5))
        try await datagram.send(Data("packet".utf8))
        #expect(try await datagram.receive().data == Data("packet".utf8))
        #expect(logs.count > 0)
        let perf = try await server.servePerformance(maxDuration: .seconds(2), maxStreams: 2)
        let progress = EventCounter()
        let result = try await client.measurePerformance(allowOwnedRelay: true,
            parameters: .init(direction: .bidirectional, duration: .milliseconds(300), interval: .milliseconds(100)),
            onProgress: { _ in progress.increment() })
        #expect(progress.count > 0 && progress.count == result.progress.count)
        #expect((result.clientSent?.bytes ?? 0) > 0 && (result.serverSent?.bytes ?? 0) > 0)
        try await perf.close()
        try await runtime.close()
    }

    @Test func ipv6ListenerAndGenericTCPDial() async throws {
        let context = try await LoopbackContext.create()
        let listener = try await context.server.listen(address: ":0", family: .ipv6)
        let port = try #require(Int(listener.address.split(separator: ":").last ?? ""))
        let accept = Task { try await listener.accept() }
        let ip = try await context.server.tunnelIP().rawValue
        let remote = try await context.client.dialTCP(address: "[\(ip)]:\(port)", family: .ipv6)
        let local = try await accept.value
        try await remote.setDeadlines(read: .now.addingTimeInterval(5))
        try await local.write(Data("IPv6".utf8))
        #expect(try await remote.read() == Data("IPv6".utf8))
        try await listener.close()
        try await local.write(Data("retained".utf8))
        #expect(try await remote.read() == Data("retained".utf8))
        try await context.runtime.close()
    }
}

final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
