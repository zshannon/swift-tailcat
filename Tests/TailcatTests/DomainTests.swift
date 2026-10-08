import Foundation
@testable import Tailcat
import Testing

@Suite struct DomainTests {
    @Test(arguments: [Int.min, -1, 65_536, Int.max])
    func localIntPortsFailBeforeProvider(_ port: Int) async {
        let server = Tailcat.Server(abort: {}, close: {}, listenTCP: { _ in
            Issue.record("invalid local port reached provider")
            throw Tailcat.Failure.operationFailed("provider")
        })
        await #expect(throws: Tailcat.Failure.invalidInput("port must be in 0...65535")) {
            try await server.listenTCP(address: .init(service: .port(port)))
        }
        try? await server.close()
    }

    @Test func validatedConstructorsPreserveLocalAndSTUNSentinels() throws {
        #expect(try Tailcat.PortRange(first: 0, last: 65_535).first == 0)
        let node = try Tailcat.DERPNode(derpPort: 0, hostName: "owned.invalid", name: "owned", regionID: 1, stunPort: -1)
        #expect(try JSONDecoder().decode(Tailcat.DERPNode.self, from: JSONEncoder().encode(node)) == node)
        #expect(throws: Tailcat.Failure.self) { try Tailcat.PortRange(first: Int.min, last: 0) }
        #expect(throws: Tailcat.Failure.self) { try Tailcat.PortRange(first: 0, last: Int.max) }
    }

    @Test func resolvedServiceAddressCannotBypassPortValidation() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ServiceResponse.self, from: Data(#"{"address":"[::]:65536","handle":1}"#.utf8))
        }
    }

    @Test func serviceAndSSHPortsValidateBeforeBackend() async {
        let server = Tailcat.Server(abort: {}, close: {})
        let client = Tailcat.Client(abort: {}, close: {})
        await #expect(throws: Tailcat.Failure.invalidInput("port must be in 0...65535")) {
            try await server.serveExec(arguments: [], port: Int.max)
        }
        await #expect(throws: Tailcat.Failure.invalidInput("port must be in 1...65535")) {
            try await client.openSSH(configuration: .init(hostKey: "", port: 0, user: ""))
        }
        try? await client.close()
        try? await server.close()
    }

    @Test(arguments: [Int.min, -1, 65_536, Int.max])
    func serviceResultDecoderRejectsInvalidPorts(_ port: Int) {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ServiceResponse.self, from: Data("{\"address\":\"\",\"handle\":1,\"port\":\(port)}".utf8))
        }
    }

    @Test(arguments: [Int.min, -1, 0, 65_536, Int.max])
    func remoteIntPortsFailBeforeProvider(_ port: Int) async {
        let client = Tailcat.Client(abort: {}, close: {}, connectTCP: { _ in
            Issue.record("invalid port reached provider")
            throw Tailcat.Failure.operationFailed("provider")
        })
        await #expect(throws: Tailcat.Failure.invalidInput("port must be in 1...65535")) {
            try await client.connectTCP(to: .tunnelPort(port))
        }
        try? await client.close()
    }

    @Test func invalidConfigurationFailsBeforeProvider() async {
        let session = Tailcat.Session(abort: {}, close: {}, makeServer: { _ in
            Issue.record("invalid configuration reached provider")
            throw Tailcat.Failure.operationFailed("provider")
        })
        await #expect(throws: Tailcat.Failure.invalidInput("UDP idle timeout must be positive")) {
            try await session.makeServer(configuration: .init(udpIdleTimeout: .zero))
        }
        try? await session.close()
    }

    @Test func defaultPortsAndLocalZeroReachProviders() async throws {
        let client = Tailcat.Client(abort: {}, close: {}, connectTCP: { destination in
            guard case .tunnelPort(let port) = destination else { throw Tailcat.Failure.invalidInput("wrong destination") }
            #expect(port == 1)
            return Tailcat.TCPConnection(abort: {}, close: {})
        })
        let server = Tailcat.Server(abort: {}, close: {}, listenTCP: { address in
            let port = try address.service.resolve(transport: .tcp)
            #expect(port == 0)
            return try Tailcat.TCPListener(abort: {}, address: "[::]:12345", close: {})
        })
        _ = try await client.connectTCP()
        _ = try await server.listenTCP(address: .init(service: .port(0)))
        try await client.close()
        try await server.close()
    }

    @Test func portRangeDecoderRejectsReversedRange() throws {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PortRange.self, from: Data(#"{"first":10,"last":9}"#.utf8))
        }
    }

    @Test(arguments: [Int.min, -2, 65_536, Int.max])
    func derpNodeDecoderRejectsInvalidSTUNPorts(_ port: Int) throws {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(DERPNode.self, from: Data("{\"STUNPort\":\(port)}".utf8))
        }
    }

    @Test(arguments: [Int.min, -1, 65_536, Int.max])
    func derpMapDecoderRejectsInvalidNestedDERPPorts(_ port: Int) throws {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(DERPMap.self, from: Data("{\"Regions\":{\"1\":{\"Nodes\":[{\"DERPPort\":\(port)}]}}}".utf8))
        }
    }
}
