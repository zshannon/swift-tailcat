import CryptoKit
import Foundation
@testable import Tailcat
import Testing

extension LoopbackTests {
    @Test func authenticatedSSHInputEOFAndPTY() async throws {
        let context = try await LoopbackContext.create()
        let key = Curve25519.Signing.PrivateKey()
        var wire = Data([0, 0, 0, 11])
        wire.append(Data("ssh-ed25519".utf8)); wire.append(Data([0, 0, 0, 32])); wire.append(key.publicKey.rawRepresentation)
        let authorized = "ssh-ed25519 " + wire.base64EncodedString()
        var der = Data([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20])
        der.append(key.rawRepresentation)
        let privateKey = "-----BEGIN PRIVATE KEY-----\n" + der.base64EncodedString() + "\n-----END PRIVATE KEY-----\n"
        let service = try await context.server.serveSSH(configuration: .init(authentication: .publicKeys([authorized]), exec: ["/bin/cat"]), port: 2222)
        let configuration = SSHClientConfiguration(hostKey: try #require(service.hostKey), port: 2222, privateKeys: [privateKey], user: "owned-test")
        #expect(try await !context.client.probeAnonymousSSH(configuration: configuration))
        let ssh = try await context.client.openSSH(configuration: configuration)
        let session = try await ssh.openSession()
        try await session.start(command: "original")
        try await session.write(Data("input EOF".utf8))
        try await session.closeInput()
        var output = Data()
        while let data = try await session.read() { output.append(data) }
        #expect(output == Data("input EOF".utf8))
        let completed = try await session.wait()
        #expect(completed.exitCode == 0)
        async let firstWait = session.wait()
        async let secondWait = session.wait()
        #expect(try await firstWait == completed)
        #expect(try await secondWait == completed)
        let terminalService = try await context.server.serveSSH(configuration: .init(authentication: .publicKeys([authorized]),
            exec: ["/bin/sh", "-c", "sleep 0.05; stty size"]), port: 2223)
        let terminalSSH = try await context.client.openSSH(configuration: .init(hostKey: #require(terminalService.hostKey), port: 2223,
            privateKeys: [privateKey], user: "owned-test"))
        let terminal = try await terminalSSH.openSession(terminal: .init(height: 12, width: 30))
        try await terminal.resize(height: 40, width: 100)
        try await terminal.start(command: "size")
        var dimensions = Data()
        while let data = try await terminal.read() { dimensions.append(data) }
        #expect(String(decoding: dimensions, as: UTF8.self).contains("40 100"))
        #expect(try await terminal.wait().exitCode == 0)
        try await context.runtime.close()
    }

    @Test func stockCLIStreamInteroperability() async throws {
        let binary = try #require(ProcessInfo.processInfo.environment["TAILCAT_CLI_BIN"])
        let context = try await LoopbackContext.create()
        let listener = try await context.server.listen(address: ":0")
        let port = try #require(Int(listener.address.split(separator: ":").last ?? ""))
        let echo = Task {
            let connection = try await listener.accept()
            var received = Data()
            while let data = try await connection.read() { received.append(data) }
            try await connection.write(received)
            try await connection.closeWrite()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [try await context.server.address().rawValue, String(port)]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.standardError
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        try input.fileHandleForWriting.write(contentsOf: Data("stock CLI".utf8))
        try input.fileHandleForWriting.close()
        let result = try output.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        try await echo.value
        #expect(result == Data("stock CLI".utf8) && process.terminationStatus == 0)
        try await context.runtime.close()
    }
}
