import Foundation
@testable import Tailcat
import Testing

private enum ServerUnary: Request { typealias Output = Int; static let event = "server-unary" }
private enum ServerDuplex: Request { typealias Inbound = Int; typealias Yield = Int; static let event = "server-duplex" }
private struct PrivateHandlerError: Error { let secret = "private handler details" }

@Suite(.timeLimit(.minutes(1))) struct MessagingServerTests {
    @Test func invalidIOTimeoutRejectsBeforeCreatingSession() async throws {
        let sessions = EventCounter()
        let dependency = Tailcat(makeSession: { _ in
            sessions.increment()
            return Tailcat.Session(abort: {}, close: {})
        })
        for timeout in [Duration.zero, .seconds(-1), Duration(secondsComponent: 0, attosecondsComponent: 1), .seconds(Int64.max)] {
            await #expect(throws: (any Error).self) {
                try await dependency.listen(configuration: .init(ioTimeout: timeout)) {}
            }
        }
        #expect(sessions.count == 0)
    }

    @Test func deadlineInstallationFailureClosesBeforeReadingOrWriting() async throws {
        let reads = EventCounter(), calls = EventCounter()
        let handler = Handle(ServerUnary.self) { _ in calls.increment(); return 42 }
        // This provider has no native deadline operation. Failure must close/join the
        // accepted flow without trying to read framing or write an unbounded error reply.
        let bytes = try await serveTranscript(configuration: .init(ioTimeout: .seconds(1)), handler: handler,
            onRead: { _ in reads.increment() }, tail: [.init(kind: .end)])
        #expect(bytes.isEmpty && reads.count == 0 && calls.count == 0)
    }

    @Test func neverInboundRequiresCanonicalEndBeforeInvokingHandler() async throws {
        for tail: [MessageFrame] in [[.init(kind: .data, payload: Data("1".utf8)), .init(kind: .end)], [.init(kind: .input), .init(kind: .end)], []] {
            let calls = EventCounter()
            let handler = Handle(ServerUnary.self) { _ in calls.increment(); return 42 }
            _ = try await serveTranscript(handler: handler, tail: tail)
            #expect(calls.count == 0)
        }
    }
    @Test func handlerErrorsAreSanitizedAndBounded() async throws {
        let handler = Handle(ServerUnary.self) { _ -> Int in throw PrivateHandlerError() }
        let bytes = try await serveTranscript(handler: handler, tail: [.init(kind: .end)])
        let input = TestWireBytes(bytes)
        let raw = Tailcat.TCPConnection(abort: {}, close: {}, closeWrite: {}, read: { input.read($0) })
        let reader = MessageReader(raw: raw, limit: 1024)
        let failure = try #require(try await reader.read())
        #expect(failure.kind == .error && failure.payload.count <= 1024)
        let error = try JSONDecoder().decode(MessageRemoteError.self, from: failure.payload)
        #expect(error.code == "request_failed" && error.message == "Request could not be completed")
        #expect(!String(decoding: bytes, as: UTF8.self).contains("private handler"))
        #expect(try await reader.read()?.kind == .end)
    }
    @Test func handlerCompletionDisposesReaderStalledOnUnconsumedInbound() async throws {
        let readThird = FoundationSignal()
        let handler = Handle(ServerDuplex.self) { _, _ in await readThird.wait() }
        let tail = (0..<10).map { MessageFrame(kind: .data, payload: Data(String($0).utf8)) } + [.init(kind: .end)]
        let bytes = try await serveTranscript(handler: handler, onRead: { count in if count == 9 { readThird.signal() } }, tail: tail)
        let input = TestWireBytes(bytes)
        let raw = Tailcat.TCPConnection(abort: {}, close: {}, closeWrite: {}, read: { input.read($0) })
        #expect(try await MessageReader(raw: raw, limit: 1024).read()?.kind == .output)
    }
    @Test func listenerHandlerCannotJoinItself() async throws {
        let slot = ListenerSlot()
        let handler = Handle(ServerUnary.self) { _ in
            let listener = await slot.get()
            await #expect(throws: Tailcat.Failure.ownershipConflict) { try await listener.close() }
            return 42
        }
        let output = try await serveTranscript(handler: handler, onListener: { await slot.set($0) }, tail: [.init(kind: .end)])
        #expect(!output.isEmpty)
    }
}

private func serveTranscript(configuration: Tailcat.Listener.Configuration = .init(), handler: Tailcat.Handler, onListener: @escaping @Sendable (Tailcat.Listener) async -> Void = { _ in },
                             onRead: @escaping @Sendable (Int) -> Void = { _ in }, tail: [MessageFrame]) async throws -> Data {
    let frames = [MessageFrame(kind: .open, payload: try JSONEncoder().encode(handler.route)), .init(kind: .input)] + tail
    let transcript = try frames.reduce(into: Data()) { try $0.append($1.encoded(limit: 1024)) }
    let input = TestWireBytes(transcript), reads = EventCounter(), accepts = EventCounter()
    let output = ServerBytes(), closed = FoundationSignal(), shutdown = FoundationSignal()
    let raw = Tailcat.TCPConnection(abort: {}, close: { closed.signal() }, closeWrite: {}, read: { maximum in
        reads.increment(); onRead(reads.count); return input.read(maximum)
    }, writeSome: { output.append($0); return $0.count })
    let dependency = Tailcat(makeSession: { _ in Tailcat.Session(abort: {}, close: {}, makeServer: { _ in
        Tailcat.Server(abort: {}, address: { .init(rawValue: "listener") }, close: {}, listenTCP: { _ in
            try Tailcat.TCPListener(abort: { shutdown.signal() }, accept: {
                accepts.increment()
                if accepts.count == 1 { return raw }
                await shutdown.wait(); throw MessageFailure.closed
            }, close: {})
        }, start: {})
    }) })
    let listener = try await dependency.listen(configuration: configuration) { handler }
    await onListener(listener)
    await closed.wait()
    try await listener.close()
    return output.data
}
private final class ServerBytes: @unchecked Sendable {
    private var value = Data()
    private let lock = NSLock()
    var data: Data { lock.withLock { value } }
    func append(_ data: Data) { lock.withLock { value.append(data) } }
}
private actor ListenerSlot {
    private var value: Tailcat.Listener?
    private var waiter: CheckedContinuation<Tailcat.Listener, Never>?
    func set(_ value: Tailcat.Listener) { self.value = value; waiter?.resume(returning: value); waiter = nil }
    func get() async -> Tailcat.Listener {
        if let value { return value }
        return await withCheckedContinuation { waiter = $0 }
    }
}
