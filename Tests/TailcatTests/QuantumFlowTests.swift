import Foundation
@testable import Tailcat
import Testing

/// Quantum sends one encoded envelope per TCP flow, then half-closes and reads [1].
/// The owned relay keeps this native transport check independent of public discovery.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TAILCAT_FIXTURE_BIN"] != nil), .serialized,
       .timeLimit(.minutes(1)))
struct QuantumFlowTests {
    @Test func cancellationLeavesSiblingAndNewFlowsUsable() async throws {
        try await withDocument { context, listener in
            let firstAccept = Task { try await listener.accept() }
            let cancelled = try await context.client.connectTCP(to: .tunnelPort(7000))
            let first = try await firstAccept.value
            let secondAccept = Task { try await listener.accept() }
            let sibling = try await context.client.connectTCP(to: .tunnelPort(7000))
            let second = try await secondAccept.value

            // Like a stalled candidate receipt, this read has no bytes or EOF available.
            let waitingForReceipt = Task { try await cancelled.read(maxBytes: 1) }
            try await Task.sleep(for: .milliseconds(30))
            waitingForReceipt.cancel()
            await #expect(throws: CancellationError.self) { try await waitingForReceipt.value }
            try await cancelled.close()
            #expect(try await first.read() == nil)
            try await first.close()

            try await exchange(data: payload(count: 65537, seed: 7), local: second, remote: sibling)
            let nextAccept = Task { try await listener.accept() }
            let next = try await context.client.connectTCP(to: .tunnelPort(7000))
            try await exchange(data: payload(count: 65537, seed: 9), local: nextAccept.value, remote: next)
        }
    }

    @Test func concurrentIndependentFlowsShareRetainedClient() async throws {
        try await withDocument { context, listener in
            let messages = [payload(count: 65537, seed: 11), payload(count: 4 * 1024 * 1024, seed: 13),
                            payload(count: 65537, seed: 17)]
            // Keep all flows open before transferring, so concurrent work cannot reuse one stream.
            var pairs: [(Tailcat.TCPConnection, Tailcat.TCPConnection)] = []
            for _ in messages {
                let accepted = Task { try await listener.accept() }
                let remote = try await context.client.connectTCP(to: .tunnelPort(7000))
                pairs.append((try await accepted.value, remote))
            }
            #expect(Set(pairs.map { $0.1.addresses.local }).count == messages.count)
            let key = try await context.client.publicKey()
            for pair in pairs {
                #expect(try await context.server.peerKey(address: pair.0.addresses.remote) == key)
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (data, pair) in zip(messages, pairs) {
                    group.addTask { try await exchange(data: data, local: pair.0, remote: pair.1) }
                }
                try await group.waitForAll()
            }
        }
    }

    @Test func documentCloseInterruptsBlockedAcceptAndReadAndJoinsCleanup() async throws {
        try await withDocument { context, listener in
            let accepted = Task { try await listener.accept() }
            let remote = try await context.client.connectTCP(to: .tunnelPort(7000))
            let local = try await accepted.value
            let blockedAccept = Task { try await listener.accept() }
            let blockedRead = Task { try await local.read(maxBytes: 65536) }
            try await Task.sleep(for: .milliseconds(30))

            // Quantum document shutdown closes its runtime, then joins receiver and handlers.
            try await context.runtime.close()
            await #expect(throws: (any Error).self) { try await blockedAccept.value }
            await #expect(throws: (any Error).self) { try await blockedRead.value }
            await #expect(throws: Tailcat.Failure.closed) { try await remote.read(maxBytes: 1) }
            await #expect(throws: Tailcat.Failure.closed) { try await context.client.connectTCP(to: .tunnelPort(7000)) }
            try await local.close()
            try await remote.close()
            try await context.runtime.close()
        }
    }

    @Test func repeatedFragmentedEnvelopesAndMaximumSizeUseSameClient() async throws {
        try await withDocument { context, listener in
            let key = try await context.client.publicKey()
            for (index, count) in [1, 65537, 4 * 1024 * 1024, 65537].enumerated() {
                let accepted = Task { try await listener.accept() }
                // The first dial performs cold local admission: no ping/prewarm in the fixture.
                let remote = try await context.client.connectTCP(to: .tunnelPort(7000))
                let local = try await accepted.value
                #expect(try await context.server.peerKey(address: local.addresses.remote) == key)
                try await exchange(data: payload(count: count, seed: UInt8(index)), local: local, remote: remote)
                #expect(try await context.client.publicKey() == key)
            }
        }
    }
}

/// Test-only byte handling mirrors the adapter without adding a library message protocol.
private func exchange(data: Data, local: Tailcat.TCPConnection, remote: Tailcat.TCPConnection) async throws {
    try await local.setDeadlines(read: .now.addingTimeInterval(2), write: .now.addingTimeInterval(2))
    try await remote.setDeadlines(read: .now.addingTimeInterval(2), write: .now.addingTimeInterval(2))
    async let received: Void = {
        var bytes = Data()
        while let chunk = try await local.read(maxBytes: 65536) {
            #expect(!chunk.isEmpty && chunk.count <= 65536)
            bytes.append(chunk)
        }
        #expect(bytes == data)
        try await local.write(Data([1]))
        try await local.closeWrite()
    }()
    var offset = 0
    while offset < data.count {
        try Task.checkCancellation()
        // An odd fragment size crosses the 65536 read boundary and exposes truncation/reordering.
        let chunk = data.subdata(in: offset..<min(offset + 16381, data.count))
        try await remote.write(chunk)
        offset += chunk.count
    }
    try await remote.closeWrite()
    #expect(try await remote.read(maxBytes: 1) == Data([1]))
    #expect(try await remote.read(maxBytes: 1) == nil)
    try await received
    try await local.close()
    try await remote.close()
}

private func payload(count: Int, seed: UInt8) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) &+ seed })
}

/// Follow the existing fixture's cooperative suite limits and joined runtime cleanup.
private func withDocument(_ body: @escaping @Sendable (LoopbackContext, Tailcat.TCPListener) async throws -> Void) async throws {
    let relay = try OwnedRelay()
    let runtime = try await Tailcat.liveValue.makeSession()
    do {
        let region = try #require(relay.map.regions.first)
        let server = try await runtime.makeServer(configuration: .init(allowedProxies: [], region: region))
        try await server.start()
        let listener = try await server.listenTCP(address: .init(service: .port(7000)))
        let client = try await runtime.makeClient(address: server.address())
        let context = LoopbackContext(client: client, relay: relay, runtime: runtime, server: server)
        try await body(context, listener)
    } catch {
        try? await runtime.close()
        throw error
    }
    try await runtime.close()
}
