import Foundation
import Tailcat
import Testing

@Suite struct PublicFoundationTests {
    @Test func ordinaryImportConstructsCoreGraphsAndDatagram() async throws {
        let session = Tailcat.Session(abort: {}, close: {}, makeClient: { _, _ in
            Tailcat.Client(abort: {}, close: {}, connectTCP: { _ in
                Tailcat.TCPConnection(abort: {}, close: {}, read: { _ in Data([1]) }, writeSome: { $0.count })
            })
        }, makeServer: { _ in
            Tailcat.Server(abort: {}, close: {}, listenTCP: { _ in
                try Tailcat.TCPListener(abort: {}, accept: { Tailcat.TCPConnection(abort: {}, close: {}) }, close: {})
            })
        })
        let client = try await session.makeClient(address: .init(rawValue: "fake"))
        let connection = try await client.connectTCP()
        #expect(try await connection.read() == Data([1]))
        let server = try await session.makeServer()
        let listener = try await server.listenTCP()
        let accepted = try await listener.accept()
        try await listener.close()
        // Transferred flow survives listener closure.
        await #expect(throws: Tailcat.Failure.unimplemented("TCPConnection.read")) { try await accepted.read() }
        let packet = Tailcat.Datagram(address: "[::1]:1", data: Data([3]))
        let udp = Tailcat.UDPConnection(abort: {}, close: {}, receive: { _ in packet })
        #expect(try await udp.receive().data == Data([3]))
        try await udp.close()
        try await session.close()
    }
}
