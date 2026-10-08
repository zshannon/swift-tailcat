import Dependencies
import Foundation
@testable import Tailcat
import Testing

private enum Registered: Request { typealias Output = String; typealias Yield = Int; static let event = "registered" }
private enum RegistrationMarker: DependencyKey { static let liveValue = "live"; static let testValue = "test" }
private extension DependencyValues {
    var registrationMarker: String {
        get { self[RegistrationMarker.self] }
        set { self[RegistrationMarker.self] = newValue }
    }
}

@Suite(.timeLimit(.minutes(1))) struct MessagingOwnershipTests {
    @Test func dependenciesAreCapturedAndEscapedHandlerStreamIsRevoked() async throws {
        let escaped = EscapedStream()
        let handler = withDependencies { $0.registrationMarker = "registration" } operation: {
            Handle(Registered.self) { _, stream in
                @Dependency(\.registrationMarker) var marker
                await escaped.set(stream)
                return marker
            }
        }
        let output = LockedData()
        let input = try TestWireBytes(MessageFrame(kind: .end).encoded(limit: 1024))
        let raw = Tailcat.TCPConnection(abort: {}, close: {}, closeWrite: {}, read: { input.read($0) }, writeSome: { output.append($0); return $0.count })
        let flow = MessageFlow(configuration: .init(), raw: raw, route: handler.route)
        try await Task.detached { try await handler.invoke(Data(), flow) }.value
        let stream = try #require(await escaped.value)
        await #expect(throws: MessageFailure.closed) { try await stream.yield(1) }
        let bytes = TestWireBytes(output.data)
        let read = Tailcat.TCPConnection(abort: {}, close: {}, closeWrite: {}, read: { bytes.read($0) })
        let reader = MessageReader(raw: read, limit: 1024)
        let frame = try #require(try await reader.read())
        #expect(try JSONDecoder().decode(String.self, from: frame.payload) == "registration")
        #expect(try await reader.read()?.kind == .end)
        await flow.close()
    }
    @Test @MainActor func callerIsolatedBuilderCapturesLocalNonSendableValues() async throws {
        final class Local { var count = 0 }
        let local = Local()
        let accept = FoundationSignal()
        let dependency = Tailcat(makeSession: { _ in Tailcat.Session(abort: {}, close: {}, makeServer: { config in
            #expect(config.allowedProxies == [])
            return Tailcat.Server(abort: {}, address: { .init(rawValue: "actual-address") }, close: {}, listenTCP: { address in
                #expect(try address.endpoint(transport: .tcp) == "[::]:0")
                return try Tailcat.TCPListener(abort: { accept.signal() }, accept: {
                    await accept.wait(); throw MessageFailure.closed
                }, address: "[::]:4321", close: {})
            }, start: {})
        }) })
        let listener = try await dependency.listen(port: 0) {
            let snapshot = { local.count += 1; return local.count }()
            Handle(Registered.self) { _, _ in String(snapshot) }
        }
        #expect(local.count == 1)
        #expect(listener.address.rawValue == "actual-address" && listener.port == 4321)
        try await listener.close()
        var statuses: [Tailcat.Messaging.Status] = []
        for await status in listener.statuses { statuses.append(status) }
        #expect(statuses.count == 3)
    }
    @Test func acquisitionCancellationDisposesLateClientAndJoins() async throws {
        let entered = FoundationSignal(), release = FoundationSignal(), clientCloses = EventCounter(), sessionCloses = EventCounter()
        let dependency = Tailcat(makeSession: { _ in Tailcat.Session(abort: { release.signal() }, close: { sessionCloses.increment() }, makeClient: { _, _ in
            entered.signal(); await release.wait()
            return Tailcat.Client(abort: {}, close: { clientCloses.increment() })
        }) })
        let operation = Task { try await dependency.connect(address: .init(rawValue: "peer")) }
        await entered.wait(); operation.cancel()
        await #expect(throws: (any Error).self) { try await operation.value }
        #expect(clientCloses.count == 1 && sessionCloses.count == 1)
    }
    @Test func closeWhileDialingDisposesLateFlowAndJoins() async throws {
        let entered = FoundationSignal(), release = FoundationSignal(), closes = EventCounter()
        let dependency = Tailcat(makeSession: { _ in Tailcat.Session(abort: { release.signal() }, close: {}, makeClient: { _, _ in
            Tailcat.Client(abort: {}, close: {}, connectTCP: { _ in
                entered.signal(); await release.wait()
                return Tailcat.TCPConnection(abort: {}, close: { closes.increment() }, closeWrite: {}, writeSome: { $0.count })
            })
        }) })
        let connection = try await dependency.connect(address: .init(rawValue: "peer"))
        let operation = Task { try await connection.open(Registered.self) }
        await entered.wait()
        try await connection.close()
        await #expect(throws: (any Error).self) { try await operation.value }
        #expect(closes.count == 1)
    }
    @Test func droppingOwnersReleasesTaskGraphs() async throws {
        let accept = FoundationSignal(), closed = FoundationSignal()
        let dependency = Tailcat(makeSession: { _ in Tailcat.Session(abort: {}, close: { closed.signal() }, makeServer: { _ in
            Tailcat.Server(abort: {}, address: { .init(rawValue: "address") }, close: {}, listenTCP: { _ in
                try Tailcat.TCPListener(abort: { accept.signal() }, accept: { await accept.wait(); throw MessageFailure.closed }, close: {})
            }, start: {})
        }) })
        var listener: Tailcat.Listener? = try await dependency.listen { Handle(Registered.self) { _, _ in "ok" } }
        weak var observed = listener
        listener = nil
        await closed.wait()
        #expect(observed == nil)
    }
}
private actor EscapedStream {
    var value: Tailcat.Stream<Never, Int>?
    func set(_ value: Tailcat.Stream<Never, Int>) { self.value = value }
}
private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    var data: Data { lock.withLock { value } }
    func append(_ data: Data) { lock.withLock { value.append(data) } }
}
