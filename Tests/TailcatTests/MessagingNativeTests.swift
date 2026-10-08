import CryptoKit
import Foundation
import Tailcat
import Testing

private enum SignedDiff: Request {
    typealias Input = Envelope
    typealias Output = Data
    static let event = "quantum.signed-diff"
}
private struct Envelope: Codable, Sendable {
    let bytes: Data
    let publicKey: Data
    let signature: Data
    init(_ count: Int, fill: UInt8? = nil) throws {
        bytes = fill.map { Data(repeating: $0, count: count) } ?? Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let key = Curve25519.Signing.PrivateKey()
        publicKey = key.publicKey.rawRepresentation
        signature = try key.signature(for: bytes)
    }
}
private enum Duplex: Request {
    typealias Inbound = Int
    typealias Input = String
    typealias Output = Int
    typealias Yield = String
    static let event = "duplex"
}
private enum Blocked: Request {
    typealias Inbound = Int
    static let event = "blocked"
}
private enum Count: Request {
    static let event = "count"
    typealias Inbound = Int
    typealias Yield = Int
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["TAILCAT_FIXTURE_BIN"] != nil), .serialized, .timeLimit(.minutes(1)))
struct MessagingNativeTests {
    @Test func completedCountStreamsReleaseOneRequestSlotWithoutReset() async throws {
        let relay = try OwnedRelay()
        let region = try #require(relay.map.regions.first)
        let listener = try await Tailcat.liveValue.listen(configuration: .init(server: .init(allowedProxies: [], region: region)), port: 0) {
            Handle(Count.self) { _, stream in
                var sum = 0
                for try await number in stream.incoming { sum += number }
                if sum > 0 {
                    for number in 1...sum { try await stream.yield(number) }
                }
            }
        }
        let connection = try await Tailcat.liveValue.connect(address: listener.address,
            configuration: .init(maxConcurrentRequests: 1), port: listener.port)
        do {
            var retained: [Tailcat.RequestStream<Int, Int, Void>] = []
            for _ in 0..<24 {
                let stream = try await connection.open(Count.self)
                retained.append(stream)
                try await stream.send(1)
                try await stream.send(2)
                try await stream.finishSending()
                var values: [Int] = []
                for try await number in stream.incoming { values.append(number) }
                #expect(values == [1, 2, 3])
            }
            withExtendedLifetime(retained) {}
        } catch { try? await connection.close(); try? await listener.close(); throw error }
        try await connection.close()
        try await listener.close()
        withExtendedLifetime(relay) {}
    }

    @Test func coldSignedEnvelopesRepeatAndOverlapOnOneClient() async throws {
        try await withTypedDocument { connection, _ in
            for count in [1, 65537, 4 * 1024 * 1024, 1] {
                let envelope = try Envelope(count)
                #expect(try await connection.call(SignedDiff.self, input: envelope) == Data(SHA256.hash(data: envelope.bytes)))
            }
            let slashHeavy = try Envelope(4 * 1024 * 1024, fill: 255)
            #expect(try await connection.call(SignedDiff.self, input: slashHeavy) == Data(SHA256.hash(data: slashHeavy.bytes)))
            try await withThrowingTaskGroup(of: Void.self) { group in
                for count in [65537, 4 * 1024 * 1024, 1] {
                    group.addTask {
                        let envelope = try Envelope(count)
                        #expect(try await connection.call(SignedDiff.self, input: envelope) == Data(SHA256.hash(data: envelope.bytes)))
                    }
                }
                try await group.waitForAll()
            }
        }
    }
    @Test func duplexSeparateResultAndCancellationPreserveSiblingAndLaterRequest() async throws {
        try await withTypedDocument { connection, _ in
            let blocked = try await connection.open(Blocked.self)
            let waiting = Task { try await blocked.result() }
            let stream = try await connection.open(Duplex.self, input: "value")
            let received = Task { () throws -> [String] in
                var result: [String] = []
                for try await value in stream.incoming { result.append(value) }
                return result
            }
            try await stream.send(2)
            waiting.cancel()
            await #expect(throws: (any Error).self) { try await waiting.value }
            await blocked.resetAndWait()
            try await stream.send(3)
            try await stream.finishSending()
            #expect(try await stream.result() == 5)
            #expect(try await received.value == ["value2", "value3"])
            await #expect(throws: Tailcat.Messaging.Failure.consumerConflict) { try await stream.result() }
            await stream.resetAndWait()
            let envelope = try Envelope(1)
            #expect(try await connection.call(SignedDiff.self, input: envelope) == Data(SHA256.hash(data: envelope.bytes)))
        }
    }
    @Test func unconsumedYieldLaneDoesNotBlockSiblingRequests() async throws {
        try await withTypedDocument { connection, _ in
            let slow = try await connection.open(Duplex.self, input: "slow")
            for value in 0..<6 { try await slow.send(value) }
            try await slow.finishSending()
            // Six yields exceed this flow's two-message inbox. A sibling can
            // complete even while nobody consumes the stalled flow's messages.
            let envelope = try Envelope(65537)
            #expect(try await connection.call(SignedDiff.self, input: envelope) == Data(SHA256.hash(data: envelope.bytes)))
            let result = Task { try await slow.result() }
            result.cancel()
            await #expect(throws: (any Error).self) { try await result.value }
            await slow.resetAndWait()
            #expect(try await connection.call(SignedDiff.self, input: envelope) == Data(SHA256.hash(data: envelope.bytes)))
        }
    }
    @Test func closeInterruptsBlockedFlowsAndAcceptAndJoins() async throws {
        try await withTypedDocument { connection, listener in
            let stream = try await connection.open(Blocked.self)
            let result = Task { try await stream.result() }
            async let closingConnection: Void = connection.close()
            async let closingListener: Void = listener.close()
            try await closingConnection
            try await closingListener
            await #expect(throws: (any Error).self) { try await result.value }
            await #expect(throws: (any Error).self) { try await connection.open(Blocked.self) }
            await stream.resetAndWait()
            try await connection.close()
            try await listener.close()
        }
    }
}

private func withTypedDocument(_ body: @escaping @Sendable (Tailcat.Connection, Tailcat.Listener) async throws -> Void) async throws {
    let relay = try OwnedRelay()
    let region = try #require(relay.map.regions.first)
    let listener = try await Tailcat.liveValue.listen(configuration: .init(server: .init(allowedProxies: [], region: region)), port: 7000) {
        Handle(SignedDiff.self) { envelope in
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: envelope.publicKey)
            guard key.isValidSignature(envelope.signature, for: envelope.bytes) else { throw URLError(.cannotDecodeContentData) }
            return Data(SHA256.hash(data: envelope.bytes))
        }
        Handle(Duplex.self) { prefix, stream in
            var sum = 0
            for try await number in stream.incoming {
                sum += number
                try await stream.yield(prefix + String(number))
            }
            return sum
        }
        Handle(Blocked.self) { _, stream in
            for try await _ in stream.incoming {}
        }
    }
    let connection: Tailcat.Connection
    do { connection = try await Tailcat.liveValue.connect(address: listener.address, port: listener.port) }
    catch { try? await listener.close(); throw error }
    do { try await body(connection, listener) }
    catch { try? await connection.close(); try? await listener.close(); throw error }
    try await connection.close()
    try await listener.close()
    withExtendedLifetime(relay) {}
}
