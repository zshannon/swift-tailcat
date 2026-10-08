import Foundation
@testable import Tailcat
import Testing

@Test func lookupAddressDoesNotUseDNS() async throws {
    let runtime = try TailcatRuntime()
    var identity = try await runtime.generateIdentity()
    identity.connectionInfo.regionID = 1
    let address = try await runtime.address(from: identity.connectionInfo)
    let result = try await runtime.lookup(name: address.rawValue, resolver: "127.0.0.1:1")
    #expect(result.address == address && result.dnsName == nil)
    await #expect(throws: TailcatError.self) { try await runtime.lookup(name: "invalid") }
    try await runtime.close()
}

extension LoopbackTests {
    @Test func anonymousProbeAndDNSConnectionSafety() async throws {
        let context = try await LoopbackContext.create()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try await context.server.serveSSH(configuration: .init(authentication: .none,
            files: .init(directory: directory, mode: .readWrite)), port: 2222)
        let configuration = SSHClientConfiguration(hostKey: try #require(service.hostKey), port: 2222, user: "owned-test")
        #expect(try await context.client.probeAnonymousSSH(configuration: configuration))
        let destination = ResolvedDestination(address: try await context.server.address(), dnsName: "owned.invalid")
        await #expect(throws: TailcatError.self) {
            try await context.runtime.openSSH(configuration: configuration, destination: destination)
        }
        let ssh = try await context.runtime.openSSH(configuration: configuration, destination: destination,
                                                   permitPublicNoAuthentication: true)
        #expect(try await ssh.openSFTP().list(path: ".").isEmpty)
        try await context.runtime.close()
    }

    @Test func localSOCKSCommandEnvironmentAndCancellation() async throws {
        let runtime = try TailcatRuntime()
        let service = try await runtime.startSOCKS()
        let result = try await service.runLocalCommand(arguments: ["/usr/bin/env"], environment: ["OWNED_TEST": "present"])
        #expect(result.exitCode == 0)
        let output = String(decoding: result.stdout, as: UTF8.self)
        #expect(output.contains("ALL_PROXY=socks5h://" + service.address))
        #expect(output.contains("OWNED_TEST=present"))
        let command = Task { try await service.runLocalCommand(arguments: ["/bin/sh", "-c", "sleep 60 & wait"]) }
        try await Task.sleep(for: .milliseconds(50))
        command.cancel()
        await #expect(throws: CancellationError.self) { try await command.value }
        try await runtime.close()
    }
}
