import Foundation
@testable import Tailcat
import Testing

@Test func regionCodePrecedesNameAndAmbiguityIsStable() throws {
    let map = try DERPMap(regions: [
        .init(code: "ams", id: 3, name: "London West", nodes: []),
        .init(code: "lon", id: 8, name: "London", nodes: []),
        .init(code: "sea", id: 1, name: "Seattle", nodes: [])
    ])
    #expect(map.region(matching: "LON")?.id == 8)
    #expect(map.region(matching: "LoNdOn")?.id == 3)
    #expect(map.region(matching: "seatt")?.id == 1)
    #expect(map.region(matching: "list") == nil)
    #expect(map.region(matching: "missing") == nil)
}

@Test func sharedClientKeySetIsThreadSafeAndStartsEmpty() async {
    let keys = ClientKeySet()
    #expect(!keys.contains(clientKey: "nodekey:owned"))
    await withTaskGroup(of: Void.self) { group in
        for number in 0..<100 {
            group.addTask { keys.add(clientKey: "nodekey:\(number)") }
        }
    }
    for number in 0..<100 { #expect(keys.contains(clientKey: "nodekey:\(number)")) }
    keys.remove(clientKey: "nodekey:42")
    #expect(!keys.contains(clientKey: "nodekey:42"))
    #expect(keys.contains(clientKey: "nodekey:43"))
}

extension LoopbackTests {
    // Rechecking AllowClient on an established stream incorrectly makes Remove act like revoke.
    @Test func keySetRemovalPreservesEstablishedConnection() async throws {
        let relay = try OwnedRelay()
        let runtime = try TailcatRuntime()
        let identity = try await runtime.generateIdentity()
        let keys = ClientKeySet()
        keys.add(clientKey: identity.connectionInfo.publicKey)
        let server = try await runtime.createServer(configuration: .init(region: relay.map.regions.first),
            policy: .init(allowClient: { keys.contains(clientKey: $0) }))
        let client = try await runtime.createClient(configuration: .init(address: server.address(),
            privateKey: identity.privateKey))
        let listener = try await server.listen(address: ":0")
        let accepted = Task { try await listener.accept() }
        let remote = try await client.dialTCP(port: #require(Int(listener.address.split(separator: ":").last ?? "")))
        let local = try await accepted.value
        try await local.setDeadlines(read: .now.addingTimeInterval(5))
        try await remote.setDeadlines(read: .now.addingTimeInterval(5))
        keys.remove(clientKey: identity.connectionInfo.publicKey)
        #expect(try await !server.contains(clientKey: identity.connectionInfo.publicKey))
        try await remote.write(Data("retained".utf8))
        #expect(try await local.read() == Data("retained".utf8))
        try await local.write(Data("reply".utf8))
        #expect(try await remote.read() == Data("reply".utf8))
        try await runtime.close()
    }
}
