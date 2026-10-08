import Dependencies
import Foundation
@testable import Tailcat
import Testing

private enum Echo: Request { typealias Input = Int; typealias Output = Int; static let event = "echo" }
private enum EmptyRequest: Request { static let event = "empty" }
private enum DuplexTest: Request { typealias Inbound = Int; typealias Yield = Int; static let event = "duplex" }

@Suite(.timeLimit(.minutes(1))) struct MessagingBoundaryTests {
    @Test func retainedAcquisitionAndCompletePartialWrites() async throws {
        let sessions = EventCounter(), clients = EventCounter(), dials = EventCounter(), closes = EventCounter()
        let dependency = Tailcat(makeSession: { _ in
            sessions.increment()
            return Tailcat.Session(abort: {}, close: {}, makeClient: { _, _ in
                clients.increment()
                return Tailcat.Client(abort: {}, close: {}, connectTCP: { _ in
                    dials.increment()
                    let bytes = try TestWireBytes(MessageFrame(kind: .output, payload: Data("42".utf8)).encoded(limit: 1024) + MessageFrame(kind: .end).encoded(limit: 1024), chunk: 1)
                    return Tailcat.TCPConnection(abort: {}, close: { closes.increment() }, closeWrite: {}, read: { bytes.read($0) }, writeSome: { min(2, $0.count) })
                })
            })
        })
        let connection = try await dependency.connect(address: .init(rawValue: "peer"))
        for i in 0..<4 { #expect(try await connection.call(Echo.self, input: i) == 42) }
        #expect(sessions.count == 1 && clients.count == 1 && dials.count == 4 && closes.count == 4)
        try await connection.close()
    }
    @Test func terminalMustBeCanonicalAndVoidIsZeroBytes() async throws {
        let out = MessageFrame(kind: .output, payload: Data("42".utf8)), end = MessageFrame(kind: .end)
        let wrong: [[MessageFrame]] = [[out], [end], [out, out, end], [out, end, end], [.init(kind: .data, payload: Data("1".utf8)), out, end], [.init(kind: .input), end]]
        for frames in wrong {
            let connection = try await scripted(frames)
            await #expect(throws: (any Error).self) { try await connection.call(Echo.self, input: 1) }
            try await connection.close()
        }
        let empty = try await scripted([.init(kind: .output), end])
        try await empty.call(EmptyRequest.self)
        try await empty.close()
        let nonempty = try await scripted([.init(kind: .output, payload: Data("null".utf8)), end])
        await #expect(throws: (any Error).self) { try await nonempty.call(EmptyRequest.self) }
        try await nonempty.close()
    }
    @Test func resultAndIncomingHaveOneConsumerAndSlowConsumerStallsOnlyItsFlow() async throws {
        let frames: [MessageFrame] = (1...5).map { .init(kind: .data, payload: Data(String($0).utf8)) } + [.init(kind: .output), .init(kind: .end)]
        let connection = try await scripted(frames)
        let stream = try await connection.open(DuplexTest.self)
        // Reader can buffer only two plus its one suspended frame; drain in order.
        var first = stream.incoming.makeAsyncIterator()
        #expect(try await first.next() == 1)
        var second = stream.incoming.makeAsyncIterator()
        await #expect(throws: MessageFailure.consumerConflict) { try await second.next() }
        var values: [Int] = [1]
        while let value = try await first.next() { values.append(value) }
        #expect(values == [1,2,3,4,5])
        try await stream.result()
        await #expect(throws: MessageFailure.consumerConflict) { try await stream.result() }
        await stream.resetAndWait()
        try await connection.close()
    }
    @Test func inboxActuallySuspendsProducerAndCancelSettlesWaits() async throws {
        let inbox = MessageInbox(capacity: 2)
        try await inbox.put(Data([1])); try await inbox.put(Data([2]))
        let started = FoundationSignal(), completed = EventCounter()
        let producer = Task { started.signal(); try await inbox.put(Data([3])); completed.increment() }
        await started.wait()
        #expect(completed.count == 0)
        let id = UUID()
        #expect(try await inbox.next(id) == Data([1]))
        try await producer.value
        #expect(completed.count == 1)
        #expect(try await inbox.next(id) == Data([2]))
        #expect(try await inbox.next(id) == Data([3]))
        inbox.finish()
        #expect(try await inbox.next(id) == nil)
    }
    @Test func concurrentSendsAreWholeFramesAndBoundedBeforeEncoding() async throws {
        let entered = FoundationSignal(), release = FoundationSignal(), encodes = EventCounter()
        let written = MessageTestData()
        let raw = Tailcat.TCPConnection(abort: { release.signal() }, close: {}, closeWrite: {}, writeSome: { data in
            entered.signal(); await release.wait(); written.append(data); return data.count
        })
        let flow = MessageFlow(configuration: .init(maxPendingSends: 1), raw: raw, route: .init(event: "test", version: 1))
        let codec = MessageCodec<Int>(decode: { _ in 0 }, encode: { number in encodes.increment(); return Data(String(number).utf8) })
        let first = Task { try await flow.state.write(1, codec: codec, kind: .data) }
        await entered.wait()
        let gate = flow.state.writer
        // Hold a second admitted operation without invoking its encoder yet.
        let secondEntered = FoundationSignal()
        let second = Task { secondEntered.signal(); try await flow.state.write(2, codec: codec, kind: .data) }
        await secondEntered.wait()
        // Synchronize on actual queue admission, never scheduling delay.
        while gate.pendingCount == 0 { await Task.yield() }
        await #expect(throws: MessageFailure.capacity) { try await flow.state.write(3, codec: codec, kind: .data) }
        #expect(encodes.count == 1)
        release.signal()
        try await first.value; try await second.value
        let bytes = TestWireBytes(written.data)
        let readRaw = Tailcat.TCPConnection(abort: {}, close: {}, closeWrite: {}, read: { bytes.read($0) })
        let reader = MessageReader(raw: readRaw, limit: 1024)
        #expect(try await reader.read()?.payload == Data("1".utf8))
        #expect(try await reader.read()?.payload == Data("2".utf8))
        #expect(try await reader.read() == nil)
        await flow.close()
    }
    @Test func canceledIncomingAndResultJoinFlowAndPreserveConnection() async throws {
        for operation in 0..<2 {
            let waiting = FoundationSignal(), released = FoundationSignal(), closed = EventCounter()
            let dependency = Tailcat(makeSession: { _ in Tailcat.Session(abort: {}, close: {}, makeClient: { _, _ in
                Tailcat.Client(abort: {}, close: {}, connectTCP: { _ in
                    Tailcat.TCPConnection(abort: { released.signal() }, close: { closed.increment() }, closeWrite: {}, read: { _ in
                        waiting.signal(); await released.wait(); throw MessageFailure.closed
                    }, writeSome: { $0.count })
                })
            }) })
            let connection = try await dependency.connect(address: .init(rawValue: "peer"))
            let stream = try await connection.open(DuplexTest.self)
            let task = Task {
                if operation == 0 { var iterator = stream.incoming.makeAsyncIterator(); _ = try await iterator.next() }
                else { try await stream.result() }
            }
            await waiting.wait()
            task.cancel()
            await #expect(throws: (any Error).self) { try await task.value }
            #expect(closed.count == 1)
            await stream.resetAndWait()
            try await connection.close()
        }
    }
    @Test func cancelingBlockedSendInterruptsTransportBeforeJoining() async throws {
        let entered = FoundationSignal(), release = FoundationSignal(), closed = EventCounter()
        let raw = Tailcat.TCPConnection(abort: { release.signal() }, close: { closed.increment() }, closeWrite: {}, writeSome: { data in
            entered.signal(); await release.wait(); try Task.checkCancellation(); return data.count
        })
        let flow = MessageFlow(configuration: .init(), raw: raw, route: .init(event: "send", version: 1))
        let task = Task { try await flow.operation { try await flow.state.write(1, codec: MessageCodec<Int>.codable, kind: .data) } }
        await entered.wait(); task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(closed.count == 1)
        await flow.close()
    }
    @Test func partialWriteFailureRevokesFutureSendsWithoutReplay() async throws {
        let attempts = EventCounter()
        let raw = Tailcat.TCPConnection(abort: {}, close: {}, closeWrite: {}, writeSome: { _ in
            attempts.increment()
            if attempts.count == 1 { return 2 }
            throw Tailcat.Failure.operationFailed("broken pipe")
        })
        let flow = MessageFlow(configuration: .init(), raw: raw, route: .init(event: "test", version: 1))
        await #expect(throws: Tailcat.TCPConnection.WriteFailure.self) {
            try await flow.state.write(1, codec: MessageCodec<Int>.codable, kind: .data)
        }
        await #expect(throws: MessageFailure.closed) {
            try await flow.state.write(2, codec: MessageCodec<Int>.codable, kind: .data)
        }
        #expect(attempts.count == 2)
        await flow.close()
    }
    @Test func requestCapacityIsReleasedAutomaticallyAfterCompletion() async throws {
        let end = try MessageFrame(kind: .output).encoded(limit: 1024) + MessageFrame(kind: .end).encoded(limit: 1024)
        let dependency = Tailcat(makeSession: { _ in Tailcat.Session(abort: {}, close: {}, makeClient: { _, _ in
            Tailcat.Client(abort: {}, close: {}, connectTCP: { _ in
                let bytes = TestWireBytes(end)
                return Tailcat.TCPConnection(abort: {}, close: {}, closeWrite: {}, read: { bytes.read($0) }, writeSome: { $0.count })
            })
        }) })
        let connection = try await dependency.connect(address: .init(rawValue: "peer"), configuration: .init(maxConcurrentRequests: 1))
        let first = try await connection.open(EmptyRequest.self)
        try await first.result()
        let next = try await connection.open(EmptyRequest.self)
        try await next.result()
        withExtendedLifetime((first, next)) {}
        try await connection.close()
    }
    @Test func invalidConfigurationAndDuplicateRoutesNeverAcquire() async throws {
        let count = EventCounter()
        let dependency = Tailcat(makeSession: { _ in count.increment(); return Tailcat.Session(abort: {}, close: {}) })
        await #expect(throws: (any Error).self) { try await dependency.connect(address: .init(rawValue: "peer"), configuration: .init(maxConcurrentRequests: 0)) }
        await #expect(throws: (any Error).self) { try await dependency.listen(configuration: .init(messaging: .init(maxEncodedMessageBytes: 0))) {} }
        await #expect(throws: (any Error).self) { try await dependency.listen {
            Handle(EmptyRequest.self) { _ in }
            Handle(EmptyRequest.self) { _ in }
        } }
        #expect(count.count == 0)
    }
}

private func scripted(_ frames: [MessageFrame]) async throws -> Tailcat.Connection {
    let bytes = try frames.reduce(into: Data()) { try $0.append($1.encoded(limit: 8 * 1024 * 1024)) }
    let dependency = Tailcat(makeSession: { _ in Tailcat.Session(abort: {}, close: {}, makeClient: { _, _ in
        Tailcat.Client(abort: {}, close: {}, connectTCP: { _ in
            let input = TestWireBytes(bytes)
            return Tailcat.TCPConnection(abort: {}, close: {}, closeWrite: {}, read: { input.read($0) }, writeSome: { $0.count })
        })
    }) })
    return try await dependency.connect(address: .init(rawValue: "peer"))
}
private final class MessageTestData: @unchecked Sendable {
    private var value = Data()
    private let lock = NSLock()
    var data: Data { lock.withLock { value } }
    func append(_ bytes: Data) { lock.withLock { value.append(bytes) } }
}
