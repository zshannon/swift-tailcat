import Foundation
import CryptoKit
@testable import Tailcat
import Testing

@Test func identityAndAddressRoundTrip() async throws {
    let runtime = try TailcatRuntime()
    var identity = try await runtime.generateIdentity()
    identity.connectionInfo.regionID = 1
    let encoded = try JSONEncoder().encode(identity)
    let restored = try JSONDecoder().decode(Identity.self, from: encoded)
    #expect(try await runtime.importIdentity(restored) == identity)
    let address = try await runtime.address(from: identity.connectionInfo)
    let info = try await runtime.connectionInfo(for: address)
    #expect(info.publicKey == identity.connectionInfo.publicKey)
    #expect(info.presharedKey == identity.connectionInfo.presharedKey)
    let publicKey = try await runtime.publicKey(privateKey: identity.privateKey)
    #expect(try await runtime.importNodeKey(data: publicKey.data) == publicKey)
    let discoveryKey = try await runtime.discoKey(privateKey: identity.privateKey)
    let ping = try await runtime.discoveryPing(discoKey: discoveryKey.key, nodeKey: publicKey.key)
    let parsed = try await runtime.parseDiscoveryPing(ping)
    #expect(parsed.ok && parsed.key == publicKey.key && parsed.discoKey == discoveryKey.key)
    #expect(try await runtime.inspectDiscoveryPacket(ping).isMeow)
    #expect(try await runtime.inspectDiscoveryPacket(runtime.discoveryPong()).isMeowed)
    try await runtime.close()
}

@Test func runtimeCloseAndCancellationBeforeBegin() async throws {
    let runtime = try TailcatRuntime()
    let operation = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await runtime.generateIdentity()
    }
    await #expect(throws: CancellationError.self) { try await operation.value }
    try await runtime.close()
    try await runtime.close()
    await #expect(throws: TailcatError.closed) { try await runtime.generateIdentity() }
}

@Test func futureDERPFieldsSurviveSerialization() throws {
    let map = try DERPMap(fields: ["Future": .object(["counter": .integer(9_007_199_254_740_993)]),
                              "Regions": .object([:])])
    #expect(try JSONDecoder().decode(DERPMap.self, from: JSONEncoder().encode(map)) == map)
}

@Test func continuationFinishesOnlyOnce() async throws {
    let state = CompletionState()
    let first = Data("first".utf8)
    state.finish(.success(first))
    state.finish(.failure(TailcatError.closed))
    let result = try await withCheckedThrowingContinuation { state.install($0) }
    #expect(result == first)
}

@Test func continuationConcurrentCompletion() async throws {
    for _ in 0..<100 {
        let state = CompletionState()
        let result = try await withCheckedThrowingContinuation { continuation in
            state.install(continuation)
            DispatchQueue.global().async { state.finish(.success(Data([1]))) }
            DispatchQueue.global().async { state.finish(.success(Data([2]))) }
        }
        #expect(result == Data([1]) || result == Data([2]))
    }
}

@Test func checkedDurationConversion() throws {
    #expect(try nanoseconds(.milliseconds(125)) == 125_000_000)
    #expect(throws: TailcatError.self) { try nanoseconds(.seconds(Int64.max)) }
}

@Test func explicitNoAuthAndDenyAllAreDifferent() throws {
    let noAuth = try SSHServerConfiguration(authentication: .none).jsonValue()
    let deny = try SSHServerConfiguration(authentication: .publicKeys([])).jsonValue()
    #expect(noAuth["authorizedKeys"] == nil)
    #expect(deny["authorizedKeys"] == .array([]))
}

@Test func identityStoreUsesOfficialJSONAndPrivatePermissions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try FileIdentityStore(directory: directory)
    let runtime = try TailcatRuntime()
    let identity = try await runtime.generateIdentity()
    try await store.save(identity, named: "example")
    #expect(try await store.identity(named: "example") == identity)
    #expect(try await store.names() == ["example"])
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("example.json").path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    await #expect(throws: TailcatError.self) { try await store.save(identity, named: "../outside") }
    try await store.remove(named: "example")
    #expect(try await store.names().isEmpty)
    try await runtime.close()
}

@Test func keySourcesUseInjectedResponseAndOfficialValidation() async throws {
    let runtime = try TailcatRuntime()
    let publicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    var wire = Data([0, 0, 0, 11])
    wire.append(Data("ssh-ed25519".utf8))
    wire.append(Data([0, 0, 0, 32]))
    wire.append(publicKey)
    let line = "ssh-ed25519 \(wire.base64EncodedString()) test"
    let lines = try await runtime.loadSSHAuthorizedKeys(sources: [.text(line), .github("example")]) { url in
        #expect(url.absoluteString == "https://github.com/example.keys")
        return Data(line.utf8)
    }
    #expect(lines == [line, line])
    await #expect(throws: (any Error).self) {
        try await runtime.loadSSHAuthorizedKeys(sources: [.text("command=\"sh\" " + line)])
    }
    try await runtime.close()
}

@Test func nilByteFieldsRepresentEmptyBytes() throws {
    let command = try JSONDecoder().decode(SSHCommandResult.self, from: Data("{\"stdout\":null,\"stderr\":null,\"exitCode\":0}".utf8))
    #expect(command.stderr.isEmpty && command.stdout.isEmpty)
    let entry = try JSONDecoder().decode(DERPMapCacheEntry.self, from: Data("{\"data\":null,\"etag\":\"\",\"storedAt\":0,\"ok\":false}".utf8))
    #expect(entry.data.isEmpty && !entry.ok)
}
