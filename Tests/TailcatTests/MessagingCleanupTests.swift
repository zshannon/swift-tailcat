import Foundation
@testable import Tailcat
import Testing

private enum CleanupEcho: Request { typealias Output = Int; static let event = "cleanup.echo" }
private enum CleanupFailure: Error { case genuine }

@Suite(.timeLimit(.minutes(1))) struct MessagingCleanupProviderTests {
    @Test func arbitraryProviderCleanupErrorsAreNotSuppressedByOwnerShutdown() async throws {
        for error: any Error in [CleanupFailure.genuine, CancellationError()] {
            let entered = FoundationSignal(), aborted = FoundationSignal()
            let dependency = Tailcat(makeSession: { _ in
                Tailcat.Session(abort: { aborted.signal() }, close: {}, makeClient: { _, _ in
                    Tailcat.Client(abort: {}, close: {}, connectTCP: { _ in
                        let bytes = try TestWireBytes(MessageFrame(kind: .output, payload: Data("42".utf8)).encoded(limit: 1024) + MessageFrame(kind: .end).encoded(limit: 1024))
                        return Tailcat.TCPConnection(abort: {}, close: {
                            entered.signal(); await aborted.wait(); throw error
                        }, closeWrite: {}, read: { bytes.read($0) }, writeSome: { $0.count })
                    })
                })
            })
            let connection = try await dependency.connect(address: .init(rawValue: "provider"))
            let call = Task { try await connection.call(CleanupEcho.self) }
            await entered.wait()
            for _ in 0..<2 {
                do { try await connection.close(); Issue.record("provider cleanup failure was suppressed") }
                catch let actual { #expect(String(reflecting: type(of: actual)) == String(reflecting: type(of: error))) }
            }
            do { _ = try await call.value; Issue.record("call cleanup failure was suppressed") }
            catch let actual { #expect(String(reflecting: type(of: actual)) == String(reflecting: type(of: error))) }
        }
    }
}

/// The wrappers only signal entry into owned cleanup; all bytes, half-close,
/// dial/accept, resource cleanup and Session shutdown use the native bridge.
/// Exact native cancellation ordering is separately barrier-tested in Go.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TAILCAT_FIXTURE_BIN"] != nil), .serialized, .timeLimit(.minutes(1)))
struct MessagingNativeCleanupTests {
    @Test func retainedConnectionCloseOverlapsCallAndResetCleanup() async throws {
        let relay = try OwnedRelay()
        let region = try #require(relay.map.regions.first)
        let listener = try await Tailcat.liveValue.listen(configuration: .init(server: .init(allowedProxies: [], region: region)), port: 0) {
            Handle(CleanupEcho.self) { _ in 42 }
        }
        do {
            for reset in [false, true] {
                for _ in 0..<12 {
                    let entered = FoundationSignal()
                    let session = try await Tailcat.liveValue.makeSession()
                    let nativeClient = try await session.makeClient(address: listener.address)
                    let client = Tailcat.Client(abort: { nativeClient.requestShutdown() }, close: { try await nativeClient.close() }, connectTCP: { destination in
                        observingCleanup(try await nativeClient.connectTCP(to: destination), entered: entered)
                    })
                    let connection = Tailcat.Connection(address: listener.address, client: client, configuration: .init(), port: listener.port, session: session)
                    let operation: Task<Int, any Error>
                    if reset {
                        let stream = try await connection.open(CleanupEcho.self)
                        try await stream.finishSending()
                        #expect(try await stream.result() == 42)
                        operation = Task { await stream.resetAndWait(); return 42 }
                    } else {
                        operation = Task { try await connection.call(CleanupEcho.self) }
                    }
                    await entered.wait()
                    connection.requestShutdown()
                    try await connection.close()
                    #expect(try await operation.value == 42)
                    try await connection.close()
                    withExtendedLifetime((connection, nativeClient, session)) {}
                }
            }
        } catch { try? await listener.close(); throw error }
        try await listener.close()
        withExtendedLifetime(relay) {}
    }

    @Test func retainedListenerCloseOverlapsHandlerCleanup() async throws {
        let relay = try OwnedRelay()
        let region = try #require(relay.map.regions.first)
        for _ in 0..<12 {
            let entered = FoundationSignal()
            let session = try await Tailcat.liveValue.makeSession()
            let server = try await session.makeServer(configuration: .init(allowedProxies: [], region: region))
            try await server.start()
            let nativeListener = try await server.listenTCP(address: .init(service: .port(0)))
            let raw = try Tailcat.TCPListener(abort: { nativeListener.requestShutdown() }, accept: {
                observingCleanup(try await nativeListener.accept(), entered: entered)
            }, address: nativeListener.address, close: { try await nativeListener.close() })
            let address = try await server.address()
            let handler = Handle(CleanupEcho.self) { _ in 42 }
            let listener = Tailcat.Listener(address: address, configuration: .init(), handlers: [handler.route: handler], raw: raw, server: server, session: session)
            let connection = try await Tailcat.liveValue.connect(address: address, port: listener.port)
            let call = Task { try await connection.call(CleanupEcho.self) }
            await entered.wait()
            listener.requestShutdown()
            try await listener.close()
            #expect(try await call.value == 42)
            try await listener.close()
            try await connection.close()
            withExtendedLifetime((listener, nativeListener, server, session)) {}
        }
        withExtendedLifetime(relay) {}
    }
}

private func observingCleanup(_ native: Tailcat.TCPConnection, entered: FoundationSignal) -> Tailcat.TCPConnection {
    Tailcat.TCPConnection(abort: { native.requestShutdown() }, addresses: native.addresses, close: {
        entered.signal()
        try await native.close()
    }, closeWrite: { try await native.closeWrite() }, read: { try await native.read(maxBytes: $0) }, writeSome: { try await native.writeSome($0) })
}
