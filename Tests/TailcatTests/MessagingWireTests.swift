import Foundation
@testable import Tailcat
import Testing

@Suite struct MessagingWireTests {
    @Test func headerVectorsAndFragmentation() async throws {
        let expected = Data([84,67,65,84,1,3,0,0,0,3,1,2,3])
        #expect(try MessageFrame(kind: .data, payload: Data([1,2,3])).encoded(limit: 8) == expected)
        for chunk in [1, 2, 7, 65536] {
            let bytes = try TestWireBytes(expected + MessageFrame(kind: .end).encoded(limit: 8), chunk: chunk)
            let raw = Tailcat.TCPConnection(abort: {}, close: {}, closeWrite: {}, read: { bytes.read($0) })
            let reader = MessageReader(raw: raw, limit: 8)
            #expect(try await reader.read()?.payload == Data([1,2,3]))
            #expect(try await reader.read()?.kind == .end)
            #expect(try await reader.read() == nil)
        }
    }
    @Test func rejectsHeaderBeforePayloadAndTruncation() async throws {
        let vectors: [[UInt8]] = [
            [0,67,65,84,1,3,0,0,0,1], [84,67,65,84,2,3,0,0,0,1],
            [84,67,65,84,1,99,0,0,0,1], [84,67,65,84,1,3,0,0,0,9],
            [84,67,65,84,1,3,0,0,0], [84,67,65,84,1,3,0,0,0,2,1],
            [84,67,65,84,1,5,0,0,0,1],
            [84,67,65,84,1,1,0,0,2,1], [84,67,65,84,1,6,0,0,4,1]
        ]
        for vector in vectors {
            let bytes = TestWireBytes(Data(vector), chunk: 1)
            let raw = Tailcat.TCPConnection(abort: {}, close: {}, closeWrite: {}, read: { bytes.read($0) })
            await #expect(throws: (any Error).self) { try await MessageReader(raw: raw, limit: 8).read() }
        }
    }
    @Test func fullFourMiBBase64EnvelopeFitsForSlashHeavyPayload() throws {
        let data = Data(repeating: 255, count: 4 * 1024 * 1024)
        let encoded = try MessageCodec<Data>.codable.encode(data)
        #expect(encoded.count <= Tailcat.Messaging.Configuration().maxEncodedMessageBytes)
        #expect(try MessageCodec<Data>.codable.decode(encoded) == data)
    }
    @Test func codecsRejectEmptyCodableAndNonemptyVoid() throws {
        #expect(throws: (any Error).self) { try MessageCodec<Int>.codable.decode(Data()) }
        #expect(throws: (any Error).self) { try MessageCodec<Void>.empty.decode(Data([0])) }
        #expect(throws: (any Error).self) { try MessageCodec<Never>.absent.decode(Data("null".utf8)) }
        #expect(try MessageCodec<Void>.empty.encode(()).isEmpty)
    }
}

final class TestWireBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data
    private let chunk: Int
    init(_ bytes: Data, chunk: Int = 65536) { self.bytes = bytes; self.chunk = chunk }
    func read(_ maximum: Int) -> Data? { lock.withLock {
        guard !bytes.isEmpty else { return nil }
        let result = Data(bytes.prefix(min(maximum, chunk)))
        bytes.removeFirst(result.count)
        return result
    } }
}
